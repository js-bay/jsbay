using System.Runtime.InteropServices;

namespace JsBay;

internal static class Native
{
    // Consumers package the platform-specific jsbay library beside their app.
    internal const string Library = "jsbay";

    [StructLayout(LayoutKind.Sequential)]
    internal readonly struct Utf8
    {
        internal readonly IntPtr Data;
        internal readonly nuint Length;
        internal Utf8(IntPtr data, nuint length)
        {
            Data = data;
            Length = length;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Bytes
    {
        internal IntPtr Data; internal nuint Length;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct EvaluateOptions
    {
        internal uint StructSize;
        internal Utf8 CacheDirectory;
        internal Utf8 CacheVersion;
        internal IntPtr CacheHit;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate int HostCallback(int instanceId, IntPtr userData, ulong thisValue,
        nuint argc, IntPtr args, out ulong value, out ulong exception);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void HostFinalize(IntPtr userData);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void LoopTask(IntPtr taskData);
    [return: MarshalAs(UnmanagedType.I1)]
    internal delegate bool LoopSchedule(IntPtr userData, ulong delayMilliseconds, LoopTask task, IntPtr taskData);
    internal delegate void LoopCancel(IntPtr userData);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void SyncStart(int instanceId, IntPtr userData, ulong requestId,
        ulong thisValue, nuint argc, IntPtr args);

    [StructLayout(LayoutKind.Sequential)]
    internal struct ResourceLimitsNative
    {
        internal uint StructSize;
        internal nuint MaxTimers;
        internal nuint MaxTsfnHandles;
        internal nuint MaxPendingCalls;
        internal nuint MaxPendingBytes;
        internal nuint MaxPendingTasks;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct ResourceUsageNative
    {
        internal uint StructSize;
        internal nuint Timers;
        internal nuint TsfnHandles;
        internal nuint PendingCalls;
        internal nuint NativeTasks;
        internal nuint ScriptTasks;
        internal nuint PendingBytes;
        internal nuint MaxTimers;
        internal nuint MaxTsfnHandles;
        internal nuint MaxPendingCalls;
        internal nuint MaxPendingBytes;
        internal nuint MaxPendingTasks;
    }


    [StructLayout(LayoutKind.Sequential)]
    internal struct InstanceSnapshotNative
    {
        internal uint StructSize;
        internal int InstanceId;
        internal ulong Generation;
        internal ulong OwnerThreadId;
        internal byte LoopMode;
        internal byte Flags;
        internal int AdmissionClass;
        internal nuint TimersReserved;
        internal nuint TimersRegistered;
        internal nuint ScriptTasksQueued;
        internal nuint NativeTasksQueued;
        internal nuint PendingBytes;
        internal nuint MaxTimers;
        internal nuint MaxPendingTasks;
        internal nuint MaxPendingBytes;
    }
    [StructLayout(LayoutKind.Sequential)]
    internal struct ResourceGlobalUsageNative
    {
        internal uint StructSize;
        internal nuint Timers;
        internal nuint TsfnHandles;
        internal nuint PendingCalls;
        internal nuint NativeTasks;
        internal nuint ScriptTasks;
        internal nuint PendingBytes;
        internal nuint MaxTimers;
        internal nuint MaxTsfnHandles;
        internal nuint MaxPendingCalls;
        internal nuint MaxNativeTasks;
        internal nuint MaxScriptTasks;
        internal nuint MaxPendingBytes;
        internal nuint FgHeadroomTimers;
        internal nuint FgHeadroomTsfnHandles;
        internal nuint FgHeadroomPendingCalls;
        internal nuint FgHeadroomNativeTasks;
        internal nuint FgHeadroomScriptTasks;
        internal nuint FgHeadroomPendingBytes;
        internal nuint BgEffectiveMaxTimers;
        internal nuint BgEffectiveMaxTsfnHandles;
        internal nuint BgEffectiveMaxPendingCalls;
        internal nuint BgEffectiveMaxNativeTasks;
        internal nuint BgEffectiveMaxScriptTasks;
        internal nuint BgEffectiveMaxPendingBytes;
    }

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_create")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool Create(int id, IntPtr log, IntPtr logData);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_create_with_limits")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool CreateWithLimits(int id, IntPtr log, IntPtr logData, in ResourceLimitsNative limits);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_set_resource_limits")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool SetResourceLimits(int id, in ResourceLimitsNative limits);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_get_resource_usage")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool GetResourceUsage(int id, ref ResourceUsageNative usage);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_resource_global_usage")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool GlobalResourceUsage(ref ResourceGlobalUsageNative usage);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_destroy")]
    internal static extern void Destroy(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_request_interrupt")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool RequestInterrupt(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_clear_interrupt")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool ClearInterrupt(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_set_execution_time_limit")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool SetExecutionTimeLimit(int id, ulong millis);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_set_memory_limit")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool SetMemoryLimit(int id, ulong bytes);


    [StructLayout(LayoutKind.Sequential)]
    internal struct MemoryUsage
    {
        internal uint StructSize;
        internal ulong MallocCount;
        internal ulong MallocSize;
        internal ulong MallocLimit;
        internal ulong MemoryUsedCount;
        internal ulong MemoryUsedSize;
        internal ulong AtomCount;
        internal ulong AtomSize;
        internal ulong ObjCount;
        internal ulong ObjSize;
        internal ulong ShapeCount;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void EngineEventHandler(IntPtr eventPtr, IntPtr userData);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_get_memory_usage")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool GetMemoryUsage(int id, ref MemoryUsage usage);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_run_gc")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool RunGc(int id);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_set_event_handler")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool SetEventHandler(int id, EngineEventHandler? handler, IntPtr userData);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_evaluate")]
    internal static extern Status Evaluate(int id, Utf8 source, Utf8 filename, IntPtr options, out ulong value, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_global")]
    internal static extern Status Global(int id, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_undefined")]
    internal static extern Status Undefined(int id, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_null")]
    internal static extern Status Null(int id, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_new_bool")]
    internal static extern Status NewBool(int id, [MarshalAs(UnmanagedType.I1)] bool input, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_new_number")]
    internal static extern Status NewNumber(int id, double input, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_new_string")]
    internal static extern Status NewString(int id, Utf8 input, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_new_array_buffer")]
    internal static extern Status NewArrayBuffer(int id, IntPtr data, nuint length, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_new_json")]
    internal static extern Status NewJson(int id, Utf8 input, out ulong value, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_new_error")]
    internal static extern Status NewError(int id, Utf8 input, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_new_object")]
    internal static extern Status NewObject(int id, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_new_array")]
    internal static extern Status NewArray(int id, out ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_retain")]
    internal static extern Status Retain(ulong value, out ulong copy);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_release")]
    internal static extern Status Release(ulong value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_type")]
    internal static extern Status Type(ulong value, out ValueKind kind);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_to_bool")]
    internal static extern Status ToBool(ulong value, [MarshalAs(UnmanagedType.I1)] out bool output);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_to_number")]
    internal static extern Status ToNumber(ulong value, out double output);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_to_utf8")]
    internal static extern Status ToUtf8(ulong value, out Bytes output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_to_json")]
    internal static extern Status ToJson(ulong value, out Bytes output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_copy_buffer")]
    internal static extern Status CopyBuffer(ulong value, out Bytes output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_free_bytes")]
    internal static extern void FreeBytes(Bytes bytes);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_get")]
    internal static extern Status Get(ulong value, Utf8 key, out ulong output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_set")]
    internal static extern Status Set(ulong target, Utf8 key, ulong value, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_call")]
    internal static extern Status Call(ulong function, ulong thisValue, IntPtr args, nuint argc, out ulong output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_construct")]
    internal static extern Status Construct(ulong function, IntPtr args, nuint argc, out ulong output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_has")]
    internal static extern Status Has(ulong target, Utf8 key, [MarshalAs(UnmanagedType.I1)] out bool output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_delete")]
    internal static extern Status Delete(ulong target, Utf8 key, [MarshalAs(UnmanagedType.I1)] out bool deleted, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_keys")]
    internal static extern Status Keys(ulong target, out ulong output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_value_instance_of")]
    internal static extern Status InstanceOf(ulong value, ulong constructor, [MarshalAs(UnmanagedType.I1)] out bool output, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_bind")]
    internal static extern Status Bind(int id, Utf8 name, HostCallback callback, IntPtr userData, HostFinalize finalize, out ulong function, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_bind_sync")]
    internal static extern Status BindSync(int id, Utf8 name, SyncStart start, IntPtr userData,
        HostFinalize finalize, ulong timeoutMilliseconds, out ulong function, out ulong exception);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_sync_complete")]
    internal static extern Status SyncComplete(ulong requestId, Status outcome, int kind, Utf8 data);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_attach_loop")]
    internal static extern Status AttachLoop(int id, LoopSchedule schedule, LoopCancel cancel, IntPtr userData);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_detach_loop")]
    internal static extern Status DetachLoop(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_loop_status")]
    internal static extern Status LoopStatus(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_run_loop")]
    internal static extern Status RunLoop(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_stop_loop")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool StopLoop(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_suspend")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool SuspendLoop(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_resume")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool ResumeLoop(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_is_suspended")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool IsSuspended(int id);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_set_admission_class")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool SetAdmissionClass(int id, int cls);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_get_admission_class")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool GetAdmissionClass(int id, out int cls);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_list")]
    internal static extern nuint ListEngines(IntPtr outIds, nuint cap);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_snapshot")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool SnapshotEngine(int id, ref InstanceSnapshotNative snap);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_inspector_start")]
    [return: MarshalAs(UnmanagedType.I1)] internal static extern bool StartInspector(int id, ushort port, out ushort actualPort);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl, EntryPoint = "jsbay_engine_inspector_stop")]
    internal static extern void StopInspector(int id);
}
