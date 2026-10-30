namespace JsBay;

/// <summary>Per-instance native admission budgets. Zero rejects every reservation of that resource.</summary>
public sealed class ResourceLimits
{
    public nuint MaxTimers { get; set; } = 4096;
    public nuint MaxTsfnHandles { get; set; } = 256;
    public nuint MaxPendingCalls { get; set; } = 4096;
    public nuint MaxPendingBytes { get; set; } = 8 * 1024 * 1024;
    public nuint MaxPendingTasks { get; set; } = 4096;
}

/// <summary>Snapshot of one instance's reservations and active Limits.</summary>
public sealed class ResourceUsage
{
    public nuint Timers
    {
        get; init;
    }
    public nuint TsfnHandles
    {
        get; init;
    }
    public nuint PendingCalls
    {
        get; init;
    }
    public nuint NativeTasks
    {
        get; init;
    }
    public nuint ScriptTasks
    {
        get; init;
    }
    public nuint PendingBytes
    {
        get; init;
    }
    public required ResourceLimits Limits
    {
        get; init;
    }
}

/// <summary>Process-wide reservation counts and caps. NativeTasks and ScriptTasks are separate pools.</summary>
public sealed class ResourceGlobalUsage
{
    public nuint Timers
    {
        get; init;
    }
    public nuint TsfnHandles
    {
        get; init;
    }
    public nuint PendingCalls
    {
        get; init;
    }
    public nuint NativeTasks
    {
        get; init;
    }
    public nuint ScriptTasks
    {
        get; init;
    }
    public nuint PendingBytes
    {
        get; init;
    }
    public nuint MaxTimers
    {
        get; init;
    }
    public nuint MaxTsfnHandles
    {
        get; init;
    }
    public nuint MaxPendingCalls
    {
        get; init;
    }
    public nuint MaxNativeTasks
    {
        get; init;
    }
    public nuint MaxScriptTasks
    {
        get; init;
    }
    public nuint MaxPendingBytes
    {
        get; init;
    }
    public nuint FgHeadroomTimers
    {
        get; init;
    }
    public nuint FgHeadroomTsfnHandles
    {
        get; init;
    }
    public nuint FgHeadroomPendingCalls
    {
        get; init;
    }
    public nuint FgHeadroomNativeTasks
    {
        get; init;
    }
    public nuint FgHeadroomScriptTasks
    {
        get; init;
    }
    public nuint FgHeadroomPendingBytes
    {
        get; init;
    }
    public nuint BgEffectiveMaxTimers
    {
        get; init;
    }
    public nuint BgEffectiveMaxTsfnHandles
    {
        get; init;
    }
    public nuint BgEffectiveMaxPendingCalls
    {
        get; init;
    }
    public nuint BgEffectiveMaxNativeTasks
    {
        get; init;
    }
    public nuint BgEffectiveMaxScriptTasks
    {
        get; init;
    }
    public nuint BgEffectiveMaxPendingBytes
    {
        get; init;
    }
}

/// <summary>Any-thread ops view of one live instance. Lengths only; may tear across locks.</summary>
public sealed class InstanceSnapshot
{
    public int InstanceId
    {
        get; init;
    }
    public ulong Generation
    {
        get; init;
    }
    public ulong OwnerThreadId
    {
        get; init;
    }
    public byte LoopMode
    {
        get; init;
    }
    public byte Flags
    {
        get; init;
    }
    public Engine.AdmissionClass AdmissionClass
    {
        get; init;
    }
    public nuint TimersReserved
    {
        get; init;
    }
    public nuint TimersRegistered
    {
        get; init;
    }
    public nuint ScriptTasksQueued
    {
        get; init;
    }
    public nuint NativeTasksQueued
    {
        get; init;
    }
    public nuint PendingBytes
    {
        get; init;
    }
    public nuint MaxTimers
    {
        get; init;
    }
    public nuint MaxPendingTasks
    {
        get; init;
    }
    public nuint MaxPendingBytes
    {
        get; init;
    }
}
