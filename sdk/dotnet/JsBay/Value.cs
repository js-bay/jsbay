using System.Diagnostics.CodeAnalysis;
using System.Runtime.InteropServices;
using System.Text;

namespace JsBay;

internal enum ValueOwnership
{
    Owned, Borrowed, ExpiredBorrowed, Closed
}

/// <summary>An engine-owned JavaScript value. Call <see cref="Dispose"/> explicitly.</summary>
public sealed class Value : IDisposable
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    internal Engine Engine
    {
        get;
    }
    private ulong handle;
    private ValueOwnership ownership;

    internal Value(Engine engine, ulong handle, ValueOwnership ownership)
    {
        Engine = engine;
        this.handle = handle;
        this.ownership = ownership;
    }

    public void Dispose()
    {
        if (ownership == ValueOwnership.Closed)
        {
            return;
        }

        if (ownership == ValueOwnership.Borrowed)
        {
            throw new JsBayException(Status.InvalidArgument);
        }

        if (ownership == ValueOwnership.ExpiredBorrowed)
        {
            throw new JsBayException(Status.StaleValue);
        }

        if (!Engine.IsOpen)
        {
            ownership = ValueOwnership.Closed;
            handle = 0;
            return;
        }
        Engine.RequireOwner();
        var previous = handle;
        handle = 0;
        ownership = ValueOwnership.Closed;
        Engine.RequireOk(Native.Release(previous));
    }

    public Value Retain()
    {
        var source = RequireUsable();
        Engine.RequireOk(Native.Retain(source, out var copy));
        // A retain inside a callback is the explicit escape operation.
        return Engine.Owned(copy, track: false);
    }

    public ValueKind Kind()
    {
        var current = RequireUsable();
        Engine.RequireOk(Native.Type(current, out var kind));
        return kind;
    }
    public bool Bool()
    {
        var current = RequireUsable();
        Engine.RequireOk(Native.ToBool(current, out var value));
        return value;
    }
    public double Number()
    {
        var current = RequireUsable();
        Engine.RequireOk(Native.ToNumber(current, out var value));
        return value;
    }
    [SuppressMessage("Naming", "CA1720", Justification = "Matches the JavaScript type converted by the public API.")]
    public string String() => Text(Native.ToUtf8);
    public string Json() => Text(Native.ToJson);

    public byte[] Bytes()
    {
        var status = Native.CopyBuffer(RequireUsable(), out var bytes, out var exception);
        try
        {
            Engine.VoidResult(status, exception);
            if (bytes.Length > int.MaxValue)
            {
                throw new JsBayException(Status.OutOfMemory);
            }

            var copy = new byte[(int)bytes.Length];
            if (copy.Length != 0)
            {
                Marshal.Copy(bytes.Data, copy, 0, copy.Length);
            }

            return copy;
        }
        finally
        {
            if (bytes.Data != IntPtr.Zero)
            {
                Native.FreeBytes(bytes);
            }
        }
    }

    public Value Get(string key) => Engine.WithUtf8(key, allowNul: false, text =>
    {
        var status = Native.Get(RequireUsable(), text, out var value, out var exception);
        return Engine.ValueResult(status, value, exception);
    });

    public void Set(string key, Value value)
    {
        Engine.RequireSame(value);
        Engine.WithUtf8(key, allowNul: false, text =>
        {
            var status = Native.Set(RequireUsable(), text, value.RequireUsable(), out var exception);
            Engine.VoidResult(status, exception);
            return 0;
        });
    }

    public Value Call(Value? thisValue = null, IReadOnlyList<Value>? args = null)
    {
        var receiver = thisValue ?? Engine.Undefined();
        try
        {
            Engine.RequireSame(receiver);
            args ??= Array.Empty<Value>();
            var handles = new ulong[args.Count];
            for (var index = 0; index < handles.Length; index++)
            {
                Engine.RequireSame(args[index]);
                handles[index] = args[index].RequireUsable();
            }
            unsafe
            {
                fixed (ulong* pointer = handles)
                {
                    var status = Native.Call(RequireUsable(), receiver.RequireUsable(), (IntPtr)pointer, (nuint)handles.Length, out var value, out var exception);
                    return Engine.ValueResult(status, value, exception);
                }
            }
        }
        finally
        {
            if (thisValue is null)
            {
                receiver.Dispose();
            }
        }
    }

    public Value Construct(IReadOnlyList<Value>? args = null)
    {
        args ??= Array.Empty<Value>();
        var handles = new ulong[args.Count];
        for (var index = 0; index < handles.Length; index++)
        {
            Engine.RequireSame(args[index]);
            handles[index] = args[index].RequireUsable();
        }
        unsafe
        {
            fixed (ulong* pointer = handles)
            {
                var status = Native.Construct(RequireUsable(), (IntPtr)pointer, (nuint)handles.Length, out var value, out var exception);
                return Engine.ValueResult(status, value, exception);
            }
        }
    }

    public bool Has(string key) => Engine.WithUtf8(key, allowNul: false, text =>
    {
        var status = Native.Has(RequireUsable(), text, out var found, out var exception);
        Engine.VoidResult(status, exception);
        return found;
    });

    public bool Delete(string key) => Engine.WithUtf8(key, allowNul: false, text =>
    {
        var status = Native.Delete(RequireUsable(), text, out var deleted, out var exception);
        Engine.VoidResult(status, exception);
        return deleted;
    });

    public Value Keys()
    {
        var status = Native.Keys(RequireUsable(), out var value, out var exception);
        return Engine.ValueResult(status, value, exception);
    }

    public bool InstanceOf(Value constructor)
    {
        Engine.RequireSame(constructor);
        var status = Native.InstanceOf(RequireUsable(), constructor.RequireUsable(), out var result, out var exception);
        Engine.VoidResult(status, exception);
        return result;
    }

    internal ulong RequireUsable()
    {
        if (ownership == ValueOwnership.ExpiredBorrowed)
        {
            throw new JsBayException(Status.StaleValue);
        }

        if (ownership == ValueOwnership.Closed || handle == 0)
        {
            throw new JsBayException(Status.StaleValue);
        }

        if (!Engine.IsOpen)
        {
            throw new JsBayException(Status.StaleValue);
        }

        Engine.RequireOpen();
        return handle;
    }
    internal void RequireOwnedForConsume()
    {
        if (ownership == ValueOwnership.Borrowed)
        {
            throw new JsBayException(Status.InvalidArgument);
        }

        if (ownership == ValueOwnership.ExpiredBorrowed || ownership == ValueOwnership.Closed || handle == 0)
        {
            throw new JsBayException(Status.StaleValue);
        }

        if (!Engine.IsOpen)
        {
            throw new JsBayException(Status.StaleValue);
        }

        Engine.RequireOpen();
    }
    internal ulong CopyForCallback()
    {
        var current = RequireUsable();
        Engine.RequireOk(Native.Retain(current, out var copy));
        return copy;
    }
    internal void InvalidateBorrowed()
    {
        if (ownership == ValueOwnership.Borrowed)
        {
            ownership = ValueOwnership.ExpiredBorrowed;
            handle = 0;
        }
    }
    internal void CloseFromScope()
    {
        if (ownership != ValueOwnership.Owned)
        {
            return;
        }

        if (Engine.IsOpen)
        {
            _ = Native.Release(handle);
        }
        handle = 0;
        ownership = ValueOwnership.Closed;
    }

    private delegate Status TextNative(ulong value, out Native.Bytes bytes, out ulong exception);
    private string Text(TextNative native)
    {
        var status = native(RequireUsable(), out var bytes, out var exception);
        try
        {
            Engine.VoidResult(status, exception);
            if (bytes.Length > int.MaxValue)
            {
                throw new JsBayException(Status.OutOfMemory);
            }

            var managed = new byte[(int)bytes.Length];
            if (managed.Length != 0)
            {
                Marshal.Copy(bytes.Data, managed, 0, managed.Length);
            }

            try
            {
                return StrictUtf8.GetString(managed);
            }
            catch (DecoderFallbackException) { throw new JsBayException(Status.InvalidArgument, "js-bay returned invalid UTF-8."); }
        }
        finally
        {
            if (bytes.Data != IntPtr.Zero)
            {
                Native.FreeBytes(bytes);
            }
        }
    }
}
