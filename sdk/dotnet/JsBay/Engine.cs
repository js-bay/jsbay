using System.Threading.Tasks;
using System.Diagnostics.CodeAnalysis;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace JsBay;

/// <summary>
/// A synchronous js-bay engine. The creating thread owns every operation except
/// <see cref="RequestInterrupt"/>; this class deliberately does not create a thread.
/// </summary>
public sealed class Engine : IDisposable
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly int ownerThreadId = Environment.CurrentManagedThreadId;
    private readonly object lifetime = new();
    private readonly List<CallbackScope> callbackScopes = [];
    private bool open = true;
    private IntPtr loopBinding;
    private static readonly Native.LoopSchedule LoopScheduleEntry = ScheduleLoopTask;
    private static readonly Native.LoopCancel LoopCancelEntry = CancelLoopTask;

#if JSBAY_TEST_HOOKS
    internal static int TestCallbackSetupFailureStep
    {
        get; set;
    }

    [SuppressMessage("Usage", "CA2201", Justification = "Test-only fault injection verifies out-of-memory containment at the C ABI boundary.")]
    private static void TestCallbackSetupStep(ref int step)
    {
        if (TestCallbackSetupFailureStep == ++step)
        {
            throw new OutOfMemoryException("Injected callback setup failure.");
        }
    }

    internal static Action<bool>? TestLoopStatusBeforeNativeQuery
    {
        get; set;
    }
#endif

    public int Id
    {
        get;
    }

    public Engine(int id) : this(id, null)
    {
    }

    public Engine(int id, ResourceLimits? limits)
    {
        Id = id;
        bool created;
        if (limits is null)
        {
            created = Native.Create(id, IntPtr.Zero, IntPtr.Zero);
        }
        else
        {
            var nativeLimits = ToNative(limits);
            created = Native.CreateWithLimits(id, IntPtr.Zero, IntPtr.Zero, in nativeLimits);
        }
        if (!created)
        {
            throw new JsBayException(Status.InvalidArgument);
        }

        var context = SynchronizationContext.Current;
        if (SupportsOwnerDispatch(context))
        {
            var binding = new LoopBinding(Id, context!, ownerThreadId);
            loopBinding = GCHandle.ToIntPtr(GCHandle.Alloc(binding));
            var status = Native.AttachLoop(Id, LoopScheduleEntry, LoopCancelEntry, loopBinding);
            if (status != Status.Ok)
            {
                GCHandle.FromIntPtr(loopBinding).Free();
                loopBinding = IntPtr.Zero;
                Native.Destroy(Id);
                throw new JsBayException(status);
            }
        }
    }

    public void Dispose() => Close();

    public void Close()
    {
        RequireOwner();
        if (!IsOpen)
        {
            return;
        }

        DetachLoop();
        lock (lifetime)
        {
            if (!open)
            {
                return;
            }

            open = false;
            Native.Destroy(Id);
        }
    }

    public Value Evaluate(string source, string filename = "<eval>", CacheOptions? cache = null)
    {
        RequireOpen();
        return WithUtf8(source, allowNul: true, sourceText => WithUtf8(filename, allowNul: false, filenameText =>
        {
            ulong value = 0, exception = 0;
            if (cache is null)
            {
                return ValueResult(Native.Evaluate(Id, sourceText, filenameText, IntPtr.Zero, out value, out exception), value, exception);
            }

            cache.DidHit = false;
            return WithUtf8(cache.Directory, allowNul: false, directory => WithUtf8(cache.Version, allowNul: false, version =>
            {
                unsafe
                {
                    var cacheHit = false;
                    var options = new Native.EvaluateOptions
                    {
                        StructSize = (uint)Marshal.SizeOf<Native.EvaluateOptions>(),
                        CacheDirectory = directory,
                        CacheVersion = version,
                    };
                    options.CacheHit = (IntPtr)(&cacheHit);
                    var status = Native.Evaluate(Id, sourceText, filenameText, (IntPtr)(&options), out value, out exception);
                    cache.DidHit = cacheHit;
                    return ValueResult(status, value, exception);
                }
            }));
        }));
    }

    public Value Global() => Simple(Native.Global);
    public Value Undefined() => Simple(Native.Undefined);
    public Value Null() => Simple(Native.Null);
    public Value Bool(bool input) => Simple((int id, out ulong value) => Native.NewBool(id, input, out value));
    public Value Number(double input) => Simple((int id, out ulong value) => Native.NewNumber(id, input, out value));
    [SuppressMessage("Naming", "CA1720", Justification = "Matches the JavaScript type represented by the public API.")]
    public Value Object() => Simple(Native.NewObject);
    public Value Array() => Simple(Native.NewArray);
    [SuppressMessage("Naming", "CA1720", Justification = "Matches the JavaScript type represented by the public API.")]
    public Value String(string input) => WithUtf8(input, allowNul: true, text => Simple((int id, out ulong value) => Native.NewString(id, text, out value)));
    public Value Error(string message) => WithUtf8(message, allowNul: true, text => Simple((int id, out ulong value) => Native.NewError(id, text, out value)));

    public Value Json(string input)
    {
        RequireOpen();
        return WithUtf8(input, allowNul: true, text =>
        {
            var status = Native.NewJson(Id, text, out var value, out var exception);
            return ValueResult(status, value, exception);
        });
    }

    public Value ArrayBuffer(ReadOnlySpan<byte> input)
    {
        RequireOpen();
        unsafe
        {
            fixed (byte* bytes = input)
            {
                var status = Native.NewArrayBuffer(Id, (IntPtr)bytes, (nuint)input.Length, out var value);
                RequireOk(status);
                return Owned(value);
            }
        }
    }

    public Value Bind(string name, NativeCallback callback)
    {
        ArgumentNullException.ThrowIfNull(callback);
        RequireOpen();
        return WithUtf8(name, allowNul: false, text =>
        {
            var binding = new Binding(this, callback);
            var userData = GCHandle.ToIntPtr(GCHandle.Alloc(binding));
            try
            {
                var status = Native.Bind(Id, text, Binding.CallbackEntry, userData, Binding.FinalizeEntry, out var function, out var exception);
                return ValueResult(status, function, exception);
            }
            catch
            {
                GCHandle.FromIntPtr(userData).Free();
                throw;
            }
        });
    }

    /// <summary>
    /// Publishes a function whose host operation completes on another thread, while JavaScript waits for a typed payload
    /// (<see cref="SyncPayloadKind.Utf8String"/>, <see cref="SyncPayloadKind.Bytes"/>, or explicit <see cref="SyncPayloadKind.Json"/>).
    /// Complete with <see cref="SyncCompletion.ResolveString"/>, <see cref="SyncCompletion.ResolveBytes"/>, or <see cref="SyncCompletion.Reject"/>.
    /// The starter must return promptly and must not keep its <see cref="SyncCall"/> values.
    /// </summary>
    public Value BindSync(string name, TimeSpan timeout, SyncStarter starter)
    {
        ArgumentNullException.ThrowIfNull(starter);
        RequireOpen();
        var timeoutMilliseconds = timeout.Ticks / TimeSpan.TicksPerMillisecond;
        if (timeoutMilliseconds <= 0)
        {
            throw new JsBayException(Status.InvalidArgument);
        }

        return WithUtf8(name, allowNul: false, text =>
        {
            var binding = new SyncBinding(this, starter);
            var userData = GCHandle.ToIntPtr(GCHandle.Alloc(binding));
            try
            {
                var status = Native.BindSync(Id, text, SyncBinding.StartEntry, userData, SyncBinding.FinalizeEntry,
                    checked((ulong)timeoutMilliseconds), out var function, out var exception);
                return ValueResult(status, function, exception);
            }
            catch
            {
                GCHandle.FromIntPtr(userData).Free();
                throw;
            }
        });
    }

    /// <summary>Runs the loop on its creating thread until <see cref="StopLoop"/> is called. Use this when construction did not have a SynchronizationContext.</summary>
    public void RunLoop()
    {
        RequireOpen();
        if (loopBinding != IntPtr.Zero)
        {
            throw new JsBayException(Status.InvalidArgument);
        }
        var status = Native.RunLoop(Id);
        if (status != Status.Ok)
        {
            throw new JsBayException(status);
        }
    }

    /// <summary>May be called from any thread, including a native callback. While a SynchronizationContext drives the loop, this stops that automatic driving until the engine is closed.</summary>
    public bool StopLoop()
    {
        lock (lifetime)
        {
            return open && Native.StopLoop(Id);
        }
    }

    /// <summary>Keep-alive pause for multi-runtime Hide. Cancels pending schedules without detaching or clearing timers/VM state. May be called from any thread.</summary>
    public bool SuspendLoop()
    {
        lock (lifetime)
        {
            return open && Native.SuspendLoop(Id);
        }
    }

    /// <summary>Resume after <see cref="SuspendLoop"/>. Does not recreate the engine. May be called from any thread.</summary>
    public bool ResumeLoop()
    {
        lock (lifetime)
        {
            return open && Native.ResumeLoop(Id);
        }
    }

    public enum AdmissionClass
    {
        Foreground = 0,
        Background = 1,
    }

    /// <summary>Future admissions only. Pair Hide→Background and Show→Foreground with Suspend/Resume.</summary>
    public bool SetAdmissionClass(AdmissionClass cls)
    {
        ThrowIfDisposed();
        return Native.SetAdmissionClass(Id, (int)cls);
    }

    public AdmissionClass GetAdmissionClass()
    {
        ThrowIfDisposed();
        return Native.GetAdmissionClass(Id, out var cls) ? (AdmissionClass)cls : AdmissionClass.Foreground;
    }

    public bool IsSuspended()
    {
        lock (lifetime)
        {
            return open && Native.IsSuspended(Id);
        }
    }

    private static bool SupportsOwnerDispatch(SynchronizationContext? context) =>
        context is not null && context.GetType().GetMethod(nameof(SynchronizationContext.Post), [typeof(SendOrPostCallback), typeof(object)])?.DeclaringType != typeof(SynchronizationContext);

    private void DetachLoop()
    {
        if (loopBinding == IntPtr.Zero)
        {
            return;
        }
        var status = Native.DetachLoop(Id);
        if (status != Status.Ok)
        {
            throw new JsBayException(status);
        }
        var binding = GCHandle.FromIntPtr(loopBinding);
        ((LoopBinding)binding.Target!).Dispose();
        binding.Free();
        loopBinding = IntPtr.Zero;
    }

    private static bool ScheduleLoopTask(IntPtr userData, ulong delayMilliseconds, Native.LoopTask task, IntPtr taskData)
    {
        try
        {
            return ((LoopBinding)GCHandle.FromIntPtr(userData).Target!).Schedule(delayMilliseconds, task, taskData);
        }
        catch
        {
            return false;
        }
    }

    private static void CancelLoopTask(IntPtr userData)
    {
        try
        {
            ((LoopBinding)GCHandle.FromIntPtr(userData).Target!).Cancel();
        }
        catch { }
    }

    private sealed class LoopBinding : IDisposable
    {
        private readonly SynchronizationContext context;
        private readonly int ownerThreadId;
        private readonly object gate = new();
        private Timer? timer;
        private ulong generation;
        private bool active = true;
        private Status? failure;

        private readonly int id;

        internal LoopBinding(int id, SynchronizationContext context, int ownerThreadId)
        {
            this.id = id;
            this.context = context;
            this.ownerThreadId = ownerThreadId;
        }

        internal bool Schedule(ulong delayMilliseconds, Native.LoopTask task, IntPtr taskData)
        {
            lock (gate)
            {
                if (!active || failure is not null || delayMilliseconds > int.MaxValue)
                {
                    return false;
                }
                timer?.Dispose();
                var call = new LoopCall(this, ++generation, task, taskData);
                timer = new Timer(static state => ((LoopCall)state!).Post(), call, checked((int)delayMilliseconds), Timeout.Infinite);
                return true;
            }
        }

        /// <summary>Soft cancel: drop the pending timer only. Binding stays reusable for suspend/resume.</summary>
        internal void Cancel()
        {
            lock (gate)
            {
                ++generation;
                timer?.Dispose();
                timer = null;
            }
        }

        /// <summary>Hard teardown after detach/destroy.</summary>
        public void Dispose()
        {
            lock (gate)
            {
                active = false;
                ++generation;
                timer?.Dispose();
                timer = null;
            }
        }

        internal Status LoopStatus()
        {
            Status? savedFailure;
            lock (gate)
            {
                savedFailure = failure;
            }
            if (savedFailure is not null)
            {
                return savedFailure.Value;
            }
#if JSBAY_TEST_HOOKS
            TestLoopStatusBeforeNativeQuery?.Invoke(Monitor.IsEntered(gate));
#endif
            return Native.LoopStatus(id);
        }

        private void Fail(ulong expectedGeneration)
        {
            lock (gate)
            {
                if (active && generation == expectedGeneration)
                {
                    failure = Status.LoopFailed;
                    ++generation;
                    timer?.Dispose();
                    timer = null;
                }
            }
        }

        private sealed class LoopCall(LoopBinding binding, ulong generation, Native.LoopTask task, IntPtr taskData)
        {
            internal void Post()
            {
                lock (binding.gate)
                {
                    if (!binding.active || binding.failure is not null || binding.generation != generation)
                    {
                        return;
                    }
                }
                try
                {
                    binding.context.Post(static state => ((LoopCall)state!).Run(), this);
                }
                catch
                {
                    binding.Fail(generation);
                }
            }

            internal void Run()
            {
                lock (binding.gate)
                {
                    if (!binding.active || binding.failure is not null || binding.generation != generation)
                    {
                        return;
                    }
                }
                if (Environment.CurrentManagedThreadId != binding.ownerThreadId)
                {
                    binding.Fail(generation);
                    return;
                }
                var status = Native.LoopStatus(binding.id);
                if (status != Status.Ok)
                {
                    binding.Fail(generation);
                    return;
                }
                task(taskData);
                lock (binding.gate)
                {
                    if (!binding.active)
                    {
                        return;
                    }
                }
                status = Native.LoopStatus(binding.id);
                if (status != Status.Ok)
                {
                    binding.Fail(generation);
                }
            }
        }
    }

    /// <summary>May be called from a thread other than the owner thread.</summary>
    public bool RequestInterrupt()
    {
        lock (lifetime)
        {
            return open && Native.RequestInterrupt(Id);
        }
    }

    public bool ClearInterrupt()
    {
        RequireOpen();
        return Native.ClearInterrupt(Id);
    }
    public bool SetExecutionTimeLimit(ulong milliseconds)
    {
        RequireOpen();
        return Native.SetExecutionTimeLimit(Id, milliseconds);
    }
    public bool SetMemoryLimit(ulong bytes)
    {
        RequireOpen();
        return Native.SetMemoryLimit(Id, bytes);
    }

    public bool SetResourceLimits(ResourceLimits limits)
    {
        ArgumentNullException.ThrowIfNull(limits);
        RequireOpen();
        var nativeLimits = ToNative(limits);
        return Native.SetResourceLimits(Id, in nativeLimits);
    }

    public ResourceUsage GetResourceUsage()
    {
        RequireOpen();
        var usage = new Native.ResourceUsageNative { StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.ResourceUsageNative>() };
        if (!Native.GetResourceUsage(Id, ref usage))
        {
            throw new JsBayException(Status.InvalidArgument);
        }
        return new ResourceUsage
        {
            Timers = usage.Timers,
            TsfnHandles = usage.TsfnHandles,
            PendingCalls = usage.PendingCalls,
            NativeTasks = usage.NativeTasks,
            ScriptTasks = usage.ScriptTasks,
            PendingBytes = usage.PendingBytes,
            Limits = new ResourceLimits
            {
                MaxTimers = usage.MaxTimers,
                MaxTsfnHandles = usage.MaxTsfnHandles,
                MaxPendingCalls = usage.MaxPendingCalls,
                MaxPendingBytes = usage.MaxPendingBytes,
                MaxPendingTasks = usage.MaxPendingTasks,
            },
        };
    }

    public static ResourceGlobalUsage GetGlobalResourceUsage()
    {
        var usage = new Native.ResourceGlobalUsageNative { StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.ResourceGlobalUsageNative>() };
        if (!Native.GlobalResourceUsage(ref usage))
        {
            throw new JsBayException(Status.InvalidArgument);
        }
        return new ResourceGlobalUsage
        {
            Timers = usage.Timers,
            TsfnHandles = usage.TsfnHandles,
            PendingCalls = usage.PendingCalls,
            NativeTasks = usage.NativeTasks,
            ScriptTasks = usage.ScriptTasks,
            PendingBytes = usage.PendingBytes,
            MaxTimers = usage.MaxTimers,
            MaxTsfnHandles = usage.MaxTsfnHandles,
            MaxPendingCalls = usage.MaxPendingCalls,
            MaxNativeTasks = usage.MaxNativeTasks,
            MaxScriptTasks = usage.MaxScriptTasks,
            MaxPendingBytes = usage.MaxPendingBytes,
            FgHeadroomTimers = usage.FgHeadroomTimers,
            FgHeadroomTsfnHandles = usage.FgHeadroomTsfnHandles,
            FgHeadroomPendingCalls = usage.FgHeadroomPendingCalls,
            FgHeadroomNativeTasks = usage.FgHeadroomNativeTasks,
            FgHeadroomScriptTasks = usage.FgHeadroomScriptTasks,
            FgHeadroomPendingBytes = usage.FgHeadroomPendingBytes,
            BgEffectiveMaxTimers = usage.BgEffectiveMaxTimers,
            BgEffectiveMaxTsfnHandles = usage.BgEffectiveMaxTsfnHandles,
            BgEffectiveMaxPendingCalls = usage.BgEffectiveMaxPendingCalls,
            BgEffectiveMaxNativeTasks = usage.BgEffectiveMaxNativeTasks,
            BgEffectiveMaxScriptTasks = usage.BgEffectiveMaxScriptTasks,
            BgEffectiveMaxPendingBytes = usage.BgEffectiveMaxPendingBytes,
        };
    }

    /// <summary>Live non-teardown-pending instance ids (arbitrary order). Any thread.</summary>
    public static int[] ListEngines()
    {
        var need = Native.ListEngines(IntPtr.Zero, 0);
        if (need == 0) return Array.Empty<int>();
        var ids = new int[checked((int)need)];
        unsafe
        {
            fixed (int* p = ids)
            {
                var n = Native.ListEngines((IntPtr)p, (nuint)ids.Length);
                if (n < need)
                {
                    Array.Resize(ref ids, checked((int)n));
                }
                else if (n > need)
                {
                    // grew; one retry
                    ids = new int[checked((int)n)];
                    fixed (int* p2 = ids)
                    {
                        n = Native.ListEngines((IntPtr)p2, (nuint)ids.Length);
                        if (n < (nuint)ids.Length) Array.Resize(ref ids, checked((int)n));
                    }
                }
            }
        }
        return ids;
    }

    /// <summary>Any-thread snapshot by id; null if missing or teardown-pending.</summary>
    public static InstanceSnapshot? TrySnapshot(int instanceId)
    {
        var snap = new Native.InstanceSnapshotNative { StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.InstanceSnapshotNative>() };
        if (!Native.SnapshotEngine(instanceId, ref snap)) return null;
        return new InstanceSnapshot
        {
            InstanceId = snap.InstanceId,
            Generation = snap.Generation,
            OwnerThreadId = snap.OwnerThreadId,
            LoopMode = snap.LoopMode,
            Flags = snap.Flags,
            AdmissionClass = (AdmissionClass)snap.AdmissionClass,
            TimersReserved = snap.TimersReserved,
            TimersRegistered = snap.TimersRegistered,
            ScriptTasksQueued = snap.ScriptTasksQueued,
            NativeTasksQueued = snap.NativeTasksQueued,
            PendingBytes = snap.PendingBytes,
            MaxTimers = snap.MaxTimers,
            MaxPendingTasks = snap.MaxPendingTasks,
            MaxPendingBytes = snap.MaxPendingBytes,
        };
    }

    /// <summary>Any-thread snapshot of this engine; null if closed/tearing down.</summary>
    public InstanceSnapshot? TrySnapshot()
    {
        if (!open) return null;
        return TrySnapshot(Id);
    }


    private static Native.ResourceLimitsNative ToNative(ResourceLimits limits) => new()
    {
        StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.ResourceLimitsNative>(),
        MaxTimers = limits.MaxTimers,
        MaxTsfnHandles = limits.MaxTsfnHandles,
        MaxPendingCalls = limits.MaxPendingCalls,
        MaxPendingBytes = limits.MaxPendingBytes,
        MaxPendingTasks = limits.MaxPendingTasks,
    };
    public readonly record struct MemoryUsage(
        ulong MallocCount, ulong MallocSize, ulong MallocLimit,
        ulong MemoryUsedCount, ulong MemoryUsedSize,
        ulong AtomCount, ulong AtomSize,
        ulong ObjCount, ulong ObjSize, ulong ShapeCount);

    public MemoryUsage GetMemoryUsage()
    {
        RequireOpen();
        var raw = new Native.MemoryUsage { StructSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf<Native.MemoryUsage>() };
        if (!Native.GetMemoryUsage(Id, ref raw))
        {
            throw new JsBayException(Status.InstanceNotFound);
        }
        return new MemoryUsage(
            raw.MallocCount, raw.MallocSize, raw.MallocLimit,
            raw.MemoryUsedCount, raw.MemoryUsedSize,
            raw.AtomCount, raw.AtomSize,
            raw.ObjCount, raw.ObjSize, raw.ShapeCount);
    }

    public bool RunGc()
    {
        RequireOpen();
        return Native.RunGc(Id);
    }

    public delegate void EngineEventCallback(IntPtr eventPtr, IntPtr userData);

    private EngineEventCallback? eventHandlerKeepAlive;
    private Native.EngineEventHandler? eventHandlerNative;

    /// <summary>Owner-thread telemetry registration. Pass null to clear. Handler must not call Engine/Value APIs.</summary>
    public bool SetEventHandler(EngineEventCallback? handler, IntPtr userData = default)
    {
        RequireOpen();
        eventHandlerKeepAlive = handler;
        eventHandlerNative = handler == null ? null : new Native.EngineEventHandler(handler);
        return Native.SetEventHandler(Id, eventHandlerNative, userData);
    }

    /// <summary>
    /// Creates the engine on a thread-pool thread. The caller must install a
    /// <see cref="SynchronizationContext"/> (or use <see cref="RunLoop"/>) on that thread
    /// before relying on automatic timer scheduling. Prefer a dedicated owner thread for production.
    /// </summary>
    public static void CreateOnBackground(int id, Action<Engine> ready)
    {
        _ = Task.Run(() =>
        {
            using var engine = new Engine(id);
            ready(engine);
        });
    }

    public ushort? StartInspector(ushort port = 0)
    {
        RequireOpen();
        return Native.StartInspector(Id, port, out var actual) ? actual : null;
    }
    public void StopInspector()
    {
        RequireOpen();
        Native.StopInspector(Id);
    }

    /// <summary>Creates an exception which preserves the original JavaScript value.</summary>
    public JsException Exception(Value value)
    {
        RequireSame(value);
        return new JsException(value);
    }

    public delegate Value NativeCallback(Value thisValue, IReadOnlyList<Value> args);
    public delegate void SyncStarter(SyncCall call);
    private delegate Status SimpleNative(int id, out ulong value);

    public sealed class CacheOptions
    {
        public string Directory
        {
            get;
        }
        public string Version
        {
            get;
        }
        public bool DidHit
        {
            get; internal set;
        }
        public CacheOptions(string directory, string version)
        {
            Directory = directory ?? throw new ArgumentNullException(nameof(directory));
            Version = version ?? throw new ArgumentNullException(nameof(version));
        }
    }

    internal bool IsOpen
    {
        get
        {
            lock (lifetime)
            {
                return open;
            }
        }
    }
    internal void RequireOwner()
    {
        if (Environment.CurrentManagedThreadId != ownerThreadId)
        {
            throw new JsBayException(Status.WrongThread);
        }
    }
    internal void RequireOpen()
    {
        RequireOwner();
        if (!IsOpen)
        {
            throw new JsBayException(Status.InstanceNotFound);
        }
        var loopStatus = loopBinding == IntPtr.Zero ? Native.LoopStatus(Id) : ((LoopBinding)GCHandle.FromIntPtr(loopBinding).Target!).LoopStatus();
        if (loopStatus != Status.Ok)
        {
            throw new JsBayException(loopStatus);
        }
    }
    internal void RequireSame(Value value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (!ReferenceEquals(value.Engine, this))
        {
            throw new JsBayException(Status.StaleValue);
        }

        value.RequireUsable();
    }
    internal static void RequireOk(Status status)
    {
        if (status != Status.Ok)
        {
            throw new JsBayException(status);
        }
    }
    internal Value Owned(ulong handle, bool track = true)
    {
        if (handle == 0)
        {
            throw new JsBayException(Status.InvalidArgument, "js-bay returned an invalid value handle.");
        }

        var value = new Value(this, handle, ValueOwnership.Owned);
        if (track && callbackScopes.Count != 0)
        {
            callbackScopes[^1].Owned.Add(value);
        }

        return value;
    }
    internal Value ValueResult(Status status, ulong value, ulong exception)
    {
        if (status == Status.Ok && value != 0 && exception == 0)
        {
            return Owned(value);
        }

        if (status == Status.Exception && value == 0 && exception != 0)
        {
            throw new JsException(Owned(exception));
        }

        throw new JsBayException(status);
    }
    internal void VoidResult(Status status, ulong exception)
    {
        if (status == Status.Ok && exception == 0)
        {
            return;
        }

        if (status == Status.Exception && exception != 0)
        {
            throw new JsException(Owned(exception));
        }

        throw new JsBayException(status);
    }

    private Value Simple(SimpleNative native)
    {
        RequireOpen();
        var status = native(Id, out var value);
        RequireOk(status);
        return Owned(value);
    }

    internal T WithUtf8<T>(string text, bool allowNul, Func<Native.Utf8, T> action)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (!allowNul && text.Contains('\0'))
        {
            throw new JsBayException(Status.InvalidArgument);
        }

        byte[] bytes;
        try
        {
            bytes = StrictUtf8.GetBytes(text);
        }
        catch (EncoderFallbackException) { throw new JsBayException(Status.InvalidArgument); }
        unsafe
        {
            fixed (byte* data = bytes)
            {
                return action(new Native.Utf8((IntPtr)data, (nuint)bytes.Length));
            }
        }
    }

    private static string SafeMessage(Exception error)
    {
        try
        {
            return error.Message;
        }
        catch { return "Native callback failed"; }
    }

    private sealed class CallbackScope
    {
        internal List<Value> Owned { get; } = [];
        internal List<Value> Borrowed { get; } = [];
        internal void Close()
        {
            foreach (var value in Borrowed)
            {
                value.InvalidateBorrowed();
            }

            for (var index = Owned.Count - 1; index >= 0; index--)
            {
                Owned[index].CloseFromScope();
            }
        }
    }

    private sealed class Binding
    {
        private readonly Engine engine;
        private readonly NativeCallback callback;
        internal Binding(Engine engine, NativeCallback callback)
        {
            this.engine = engine;
            this.callback = callback;
        }
        internal static readonly Native.HostCallback CallbackEntry = Invoke;
        internal static readonly Native.HostFinalize FinalizeEntry = Finalize;

        private static int Invoke(int instanceId, IntPtr userData, ulong thisHandle, nuint argc, IntPtr args, out ulong result, out ulong exception)
        {
            result = 0;
            exception = 0;
            try
            {
                var binding = (Binding)GCHandle.FromIntPtr(userData).Target!;
                if (binding.engine.Id != instanceId || !binding.engine.IsOpen)
                {
                    return (int)Status.InstanceNotFound;
                }
#if JSBAY_TEST_HOOKS
                var setupStep = 0;
                TestCallbackSetupStep(ref setupStep);
#endif
                var scope = new CallbackScope();
                var pushed = false;
                try
                {
#if JSBAY_TEST_HOOKS
                    TestCallbackSetupStep(ref setupStep);
#endif
                    binding.engine.callbackScopes.Add(scope);
                    pushed = true;
                    var thisValue = new Value(binding.engine, thisHandle, ValueOwnership.Borrowed);
                    scope.Borrowed.Add(thisValue);
#if JSBAY_TEST_HOOKS
                    TestCallbackSetupStep(ref setupStep);
#endif
                    var values = new Value[checked((int)argc)];
                    unsafe
                    {
                        var handles = (ulong*)args;
                        for (var index = 0; index < values.Length; index++)
                        {
                            values[index] = new Value(binding.engine, handles[index], ValueOwnership.Borrowed);
                            scope.Borrowed.Add(values[index]);
                        }
                    }
                    result = binding.callback(thisValue, values).CopyForCallback();
                    return (int)Status.Ok;
                }
                catch (JsException error)
                {
                    try
                    {
                        exception = error.Value.CopyForCallback();
                        return (int)Status.Exception;
                    }
                    catch (JsBayException status) { return (int)status.Status; }
                }
                catch (Exception error)
                {
                    try
                    {
                        exception = binding.engine.Error(SafeMessage(error)).CopyForCallback();
                        return (int)Status.Exception;
                    }
                    catch (JsBayException status) { return (int)status.Status; }
                }
                finally
                {
                    if (pushed)
                    {
                        binding.engine.callbackScopes.RemoveAt(binding.engine.callbackScopes.Count - 1);
                    }

                    scope.Close();
                }
            }
            catch (OutOfMemoryException) { result = 0; exception = 0; return (int)Status.OutOfMemory; }
            catch { result = 0; exception = 0; return (int)Status.InvalidArgument; }
        }

        private static void Finalize(IntPtr userData)
        {
            if (userData != IntPtr.Zero)
            {
                GCHandle.FromIntPtr(userData).Free();
            }
        }
    }

    private sealed class SyncBinding
    {
        private readonly Engine engine;
        private readonly SyncStarter starter;
        internal SyncBinding(Engine engine, SyncStarter starter)
        {
            this.engine = engine;
            this.starter = starter;
        }
        internal static readonly Native.SyncStart StartEntry = Start;
        internal static readonly Native.HostFinalize FinalizeEntry = Finalize;

        private static void Start(int instanceId, IntPtr userData, ulong requestId, ulong thisHandle, nuint argc, IntPtr args)
        {
            try
            {
                var binding = (SyncBinding)GCHandle.FromIntPtr(userData).Target!;
                if (binding.engine.Id != instanceId || !binding.engine.IsOpen)
                {
                    return;
                }

                var completion = new SyncCompletion(requestId);
#if JSBAY_TEST_HOOKS
                var setupStep = 0;
                TestCallbackSetupStep(ref setupStep);
#endif
                var scope = new CallbackScope();
                var pushed = false;
                try
                {
#if JSBAY_TEST_HOOKS
                    TestCallbackSetupStep(ref setupStep);
#endif
                    binding.engine.callbackScopes.Add(scope);
                    pushed = true;
                    var thisValue = new Value(binding.engine, thisHandle, ValueOwnership.Borrowed);
                    scope.Borrowed.Add(thisValue);
#if JSBAY_TEST_HOOKS
                    TestCallbackSetupStep(ref setupStep);
#endif
                    var values = new Value[checked((int)argc)];
                    unsafe
                    {
                        var handles = (ulong*)args;
                        for (var index = 0; index < values.Length; index++)
                        {
                            values[index] = new Value(binding.engine, handles[index], ValueOwnership.Borrowed);
                            scope.Borrowed.Add(values[index]);
                        }
                    }
                    binding.starter(new SyncCall(thisValue, values, completion));
                }
                catch (Exception error) { completion.Reject(SafeMessage(error)); }
                finally
                {
                    if (pushed)
                    {
                        binding.engine.callbackScopes.RemoveAt(binding.engine.callbackScopes.Count - 1);
                    }

                    scope.Close();
                }
            }
            catch { try { _ = Native.RequestInterrupt(instanceId); } catch { } }
        }

        private static void Finalize(IntPtr userData)
        {
            if (userData != IntPtr.Zero)
            {
                GCHandle.FromIntPtr(userData).Free();
            }
        }
    }
}
