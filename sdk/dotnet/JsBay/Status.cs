using System.Diagnostics.CodeAnalysis;

namespace JsBay;

public enum Status : int
{
    Ok = 0,
    Exception = 1,
    InvalidArgument = 2,
    WrongThread = 3,
    InstanceNotFound = 4,
    StaleValue = 5,
    OutOfMemory = 6,
    Unsupported = 7,
    LoopFailed = 8,
}

public enum ValueKind : int
{
    Undefined,
    Null,
    Bool,
    Number,
    [SuppressMessage("Naming", "CA1720", Justification = "Identifies the JavaScript string type.")]
    String,
    [SuppressMessage("Naming", "CA1720", Justification = "Identifies the JavaScript object type.")]
    Object,
    Array,
    Function,
    Symbol,
    BigInt,
}

/// <summary>A non-JavaScript failure reported by the typed C API.</summary>
public sealed class JsBayException : InvalidOperationException
{
    public Status Status
    {
        get;
    }

    public JsBayException(Status status, string? message = null)
        : base(message ?? $"js-bay: {status}") => Status = status;
}

/// <summary>A JavaScript value that was thrown by an operation.</summary>
public sealed class JsException : Exception
{
    public Value Value
    {
        get;
    }

    internal JsException(Value value) : base("JavaScript threw a value.") => Value = value;

    /// <summary>
    /// Returns a display string when coercing the thrown value succeeds. A second JavaScript throw is released and reported as <c>null</c>; the original <see cref="Value"/> remains owned by the caller.
    /// </summary>
    public string? TryDescribe()
    {
        try
        {
            return Value.String();
        }
        catch (JsException secondary)
        {
            try
            {
                secondary.Value.Dispose();
            }
            catch (JsBayException) { }
            return null;
        }
        catch (JsBayException) { return null; }
    }

    /// <summary>Returns the thrown value's text and closes it. A second JavaScript throw closes both values and returns a fixed fallback.</summary>
    public string DescribeAndClose()
    {
        Value.RequireOwnedForConsume();
        try
        {
            var description = Value.String();
            Value.Dispose();
            return description;
        }
        catch (JsException secondary)
        {
            try
            {
                secondary.Value.Dispose();
            }
            finally { Value.Dispose(); }
            return "JavaScript exception";
        }
    }
}
