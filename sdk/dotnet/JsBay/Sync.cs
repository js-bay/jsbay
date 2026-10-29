using System.Text;

namespace JsBay;

/// <summary>Arguments visible only while a synchronous native start callback runs.</summary>
public sealed class SyncCall
{
    public Value ThisValue
    {
        get;
    }
    public IReadOnlyList<Value> Args
    {
        get;
    }
    public SyncCompletion Completion
    {
        get;
    }

    internal SyncCall(Value thisValue, IReadOnlyList<Value> args, SyncCompletion completion)
    {
        ThisValue = thisValue;
        Args = args;
        Completion = completion;
    }
}

public enum SyncPayloadKind : int
{
    Utf8String = 0,
    Bytes = 1,
    Json = 2,
}

/// <summary>
/// A thread-safe, single-use completion token. It copies bytes to native code and deliberately exposes no JavaScript <see cref="Value"/>.
/// Prefer calling <c>jsbay_sync_complete</c> from native workers on the hot path.
/// </summary>
public sealed class SyncCompletion
{
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private readonly object gate = new();
    private readonly ulong requestId;
    private bool terminal;

    internal SyncCompletion(ulong requestId) => this.requestId = requestId;

    public void ResolveString(string value) => RequireCompleted(TryResolveString(value));
    public void ResolveBytes(byte[] bytes) => RequireCompleted(TryResolveBytes(bytes));
    public void Reject(string message) => RequireCompleted(TryReject(message));
    public Status TryResolveString(string value) => Complete(Status.Ok, SyncPayloadKind.Utf8String, EncodeUtf8(value));
    public Status TryResolveBytes(byte[] bytes)
    {
        ArgumentNullException.ThrowIfNull(bytes);
        return Complete(Status.Ok, SyncPayloadKind.Bytes, bytes);
    }
    public Status TryReject(string message) => Complete(Status.Exception, SyncPayloadKind.Utf8String, EncodeUtf8(message));

    private static byte[]? EncodeUtf8(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        try
        {
            return StrictUtf8.GetBytes(text);
        }
        catch (EncoderFallbackException)
        {
            return null;
        }
    }

    private Status Complete(Status outcome, SyncPayloadKind kind, byte[]? bytes)
    {
        if (bytes is null)
        {
            return Status.InvalidArgument;
        }

        unsafe
        {
            fixed (byte* data = bytes)
            {
                lock (gate)
                {
                    if (terminal)
                    {
                        return Status.StaleValue;
                    }

                    var status = Native.SyncComplete(requestId, outcome, (int)kind, new Native.Utf8((IntPtr)data, (nuint)bytes.Length));
                    if (status == Status.Ok || status == Status.StaleValue)
                    {
                        terminal = true;
                    }

                    return status;
                }
            }
        }
    }

    private static void RequireCompleted(Status status)
    {
        if (status != Status.Ok)
        {
            throw new JsBayException(status);
        }
    }
}
