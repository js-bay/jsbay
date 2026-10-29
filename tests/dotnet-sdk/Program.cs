using System.Diagnostics;
using JsBay;

if (args.Length == 1)
{
    switch (args[0])
    {
        case "--reject-first-post":
            RunRejectedPostChild(0);
            return;
        case "--reject-later-post":
            RunLaterRejectedPostChild();
            return;
        case "--wrong-thread-post":
            RunWrongThreadPostChild();
            return;
        case "--derived-base-context":
            RunDerivedBaseContextChild();
            return;
        case "--null-context":
            RunNullContextChild();
            return;
    }
}

// The runner supplies the shared jsbay library through the normal native loader path.
using var loopContext = new PumpSynchronizationContext();
SynchronizationContext.SetSynchronizationContext(loopContext);
RunLoopDeliveryChild("--reject-first-post");
RunLoopDeliveryChild("--reject-later-post");
RunLoopDeliveryChild("--wrong-thread-post");
RunLoopDeliveryChild("--derived-base-context");
RunLoopDeliveryChild("--null-context");
RunLoopStatusLockOrder();
using (var engine = new Engine(41001))
{
    using var nullCheckObject = engine.Object();
    Check.Throws<ArgumentNullException>(() => engine.Exception(null!), "null exception value identifies invalid argument");
    Check.Throws<ArgumentNullException>(() => nullCheckObject.Set("key", null!), "null property value identifies invalid argument");
    using var nullCheckFunction = engine.Evaluate("value => value", "null-check.js");
    Check.Throws<ArgumentNullException>(() => nullCheckFunction.Call(args: new Value[] { null! }), "null argument element identifies invalid argument");

    using var timerStart = engine.Evaluate("globalThis.__sdkTimer = 0; setTimeout(() => { globalThis.__sdkTimer = 42; }, 1)", "automatic-loop.js");
    loopContext.PumpUntil(() =>
    {
        using var timerValue = engine.Evaluate("globalThis.__sdkTimer", "automatic-loop-result.js");
        return timerValue.Number() == 42;
    }, TimeSpan.FromSeconds(2));
    Check.Equal(42d, engine.Evaluate("globalThis.__sdkTimer", "automatic-loop-check.js").Number(), "automatic loop runs timers without Tick");
    using var nul = engine.String("a\0b");
    Check.Equal("a\0b", nul.String(), "explicit UTF-8 length must preserve NUL");
    Check.Equal(Status.InvalidArgument, Check.Throws<JsBayException>(() => engine.String("\uD800"), "invalid UTF-16").Status, "invalid UTF-16 status");

    using var result = engine.Evaluate("6 * 7", "consumer.js");
    Check.Equal(42d, result.Number(), "evaluate result");
    using var symbolKind = engine.Evaluate("Symbol('kind')", "symbol-kind.js");
    Check.Equal(ValueKind.Symbol, symbolKind.Kind(), "symbol kind");
    using var bigIntKind = engine.Evaluate("1n", "bigint-kind.js");
    Check.Equal(ValueKind.BigInt, bigIntKind.Kind(), "bigint kind");

    using var callback = engine.Bind("nativeDouble", (_, args) =>
    {
        return engine.Number(args[0].Number() * 2);
    });
    using var callbackResult = engine.Evaluate("nativeDouble(21)", "callback.js");
    Check.Equal(42d, callbackResult.Number(), "callback return ownership");

    using var ordinaryMessage = engine.Bind("ordinaryMessage", (_, _) => throw new InvalidOperationException("sentinel"));
    using var ordinaryMessageText = engine.Evaluate("try { ordinaryMessage(); } catch (error) { String(error) }", "ordinary-message.js");
    Check.Contains("sentinel", ordinaryMessageText.String(), "normal callback preserves managed exception message");

    using var ordinarySyncMessage = engine.BindSync("ordinarySyncMessage", TimeSpan.FromSeconds(1), _ => throw new InvalidOperationException("sentinel"));
    using var ordinarySyncMessageText = engine.Evaluate("try { ordinarySyncMessage(); } catch (error) { String(error) }", "ordinary-sync-message.js");
    Check.Contains("sentinel", ordinarySyncMessageText.String(), "sync callback preserves managed exception message");

    using var hostileMessage = engine.Bind("hostileMessage", (_, _) => throw new MessageGetterThrowsException());
    var hostileMessageThrown = Check.Throws<JsException>(() => engine.Evaluate("hostileMessage()", "hostile-message.js"), "hostile managed exception is contained");
    hostileMessageThrown.Value.Dispose();
    using var afterHostileMessage = engine.Evaluate("40 + 2", "after-hostile-message.js");
    Check.Equal(42d, afterHostileMessage.Number(), "normal callback failure leaves engine usable");

    using var hostileSyncMessage = engine.BindSync("hostileSyncMessage", TimeSpan.FromSeconds(1), _ => throw new MessageGetterThrowsException());
    var hostileSyncThrown = Check.Throws<JsException>(() => engine.Evaluate("hostileSyncMessage()", "hostile-sync-message.js"), "hostile sync exception is contained");
    hostileSyncThrown.Value.Dispose();
    engine.ClearInterrupt();
    using var afterHostileSync = engine.Evaluate("40 + 2", "after-hostile-sync-message.js");
    Check.Equal(42d, afterHostileSync.Number(), "sync callback failure leaves engine usable");

#if JSBAY_TEST_HOOKS
    using var setupScopeFailure = engine.Bind("setupScopeFailure", (_, _) => engine.Undefined());
    Engine.TestCallbackSetupFailureStep = 1;
    try
    {
        var injectedScopeFailure = Check.Throws<JsException>(() => engine.Evaluate("setupScopeFailure()", "setup-scope-failure.js"), "callback scope setup failure");
        injectedScopeFailure.Value.Dispose();
    }
    finally { Engine.TestCallbackSetupFailureStep = 0; }
    using var afterScopeFailure = engine.Evaluate("40 + 2", "after-scope-failure.js");
    Check.Equal(42d, afterScopeFailure.Number(), "scope setup failure leaves engine usable");

    using var setupArrayFailure = engine.BindSync("setupArrayFailure", TimeSpan.FromSeconds(1), _ => { });
    Engine.TestCallbackSetupFailureStep = 3;
    try
    {
        var injectedSyncFailure = Check.Throws<JsException>(() => engine.Evaluate("setupArrayFailure()", "setup-array-failure.js"), "sync callback array setup failure");
        injectedSyncFailure.Value.Dispose();
    }
    finally { Engine.TestCallbackSetupFailureStep = 0; }
    engine.ClearInterrupt();
    using var afterArrayFailure = engine.Evaluate("40 + 2", "after-array-failure.js");
    Check.Equal(42d, afterArrayFailure.Number(), "array setup failure leaves engine usable");
#endif

    JsException thrown = Check.Throws<JsException>(() => engine.Evaluate("throw { value: 7 }", "throw.js"), "arbitrary throw");
    using (thrown.Value)
    {
        Check.Equal(ValueKind.Object, thrown.Value.Kind(), "thrown Value is preserved");
    }

    using var throwingText = engine.Evaluate("({ toString() { throw 9 } })", "secondary.js");
    JsException secondary = Check.Throws<JsException>(() => throwingText.String(), "secondary conversion throw");
    secondary.Value.Dispose();

    JsException described = Check.Throws<JsException>(() => engine.Evaluate("throw { toString() { throw 9 } }", "describe.js"), "description source");
    using (described.Value)
    {
        Check.Equal<string?>(null, described.TryDescribe(), "description releases secondary throw");
    }

    JsException consumed = Check.Throws<JsException>(() => engine.Evaluate("throw 'display\\u0000😀'", "describe-and-close.js"), "consuming description source");
    Check.Equal("display\0😀", consumed.DescribeAndClose(), "consuming description preserves NUL and Unicode");
    Check.Equal(Status.StaleValue, Check.Throws<JsBayException>(() => consumed.Value.String(), "consumed exception value is stale").Status, "consuming description closes original value");

    JsException fallback = Check.Throws<JsException>(() => engine.Evaluate("throw { toString() { throw 9 } }", "describe-and-close-secondary.js"), "secondary consuming description source");
    Check.Equal("JavaScript exception", fallback.DescribeAndClose(), "secondary throw uses fallback");
    Check.Equal(Status.StaleValue, Check.Throws<JsBayException>(() => fallback.Value.String(), "secondary consuming original is stale").Status, "secondary consuming description closes original value");

    var borrowed = default(Value);
    using var stash = engine.Bind("stash", (thisValue, _) => { borrowed = thisValue; return engine.Undefined(); });
    using var ignored = engine.Evaluate("stash()", "borrowed.js");
    Check.Throws<JsBayException>(() => borrowed!.Kind(), "borrowed value expires after callback");

    using var borrowedDescription = engine.Bind("borrowedDescription", (thisValue, _) =>
    {
        var exception = engine.Exception(thisValue);
        Check.Equal(Status.InvalidArgument, Check.Throws<JsBayException>(() => exception.DescribeAndClose(), "borrowed description").Status, "borrowed exception text is rejected before conversion");
        return engine.Undefined();
    });
    using var borrowedDescriptionResult = engine.Evaluate("borrowedDescription()", "borrowed-description.js");

    RunObjectOperations(engine);

    var wrongThread = Task.Run(() => Check.Throws<JsBayException>(() => engine.Number(1), "owner thread")).GetAwaiter().GetResult();
    Check.Equal(Status.WrongThread, wrongThread.Status, "wrong thread status");

    var old = engine.Evaluate("1", "old.js");
    engine.Close();
    Check.Equal(Status.StaleValue, Check.Throws<JsBayException>(() => old.Number(), "old value after engine close").Status, "destroyed engine makes old Value stale");
    using var rebuilt = new Engine(41001);
    Check.Throws<JsBayException>(() => old.Number(), "old object never revives after ID reuse");
    old.Dispose();
    using var live = rebuilt.Evaluate("40 + 2", "new.js");
    Check.Equal(42d, live.Number(), "rebuilt engine");
}

using (var engine = new Engine(41006))
{
    var stopped = false;
    var callbackThreadId = 0;
    var ownerThreadId = Environment.CurrentManagedThreadId;
    using var stop = engine.Bind("stopLoop", (_, _) =>
    {
        callbackThreadId = Environment.CurrentManagedThreadId;
        stopped = engine.StopLoop();
        return engine.Undefined();
    });
    using var timer = engine.Evaluate("setTimeout(stopLoop, 1)", "stop-loop.js");
    loopContext.PumpUntil(() => stopped, TimeSpan.FromSeconds(2));
    Check.Equal(true, stopped, "timer callback can stop loop");
    Check.Equal(ownerThreadId, callbackThreadId, "timer callback runs on the SynchronizationContext owner");
}

using (var engine = new Engine(41007))
{
    var closedFromTimer = false;
    var laterCallbackRan = false;
    using var closeFromTimer = engine.Bind("closeFromTimer", (_, _) =>
    {
        closedFromTimer = true;
        engine.Close();
        return engine.Undefined();
    });
    using var laterCallback = engine.Bind("laterCallback", (_, _) =>
    {
        laterCallbackRan = true;
        return engine.Undefined();
    });
    using var timers = engine.Evaluate("setTimeout(closeFromTimer, 1); setTimeout(laterCallback, 2)", "close-timer.js");
    loopContext.PumpUntil(() => closedFromTimer, TimeSpan.FromSeconds(2));
    loopContext.PumpFor(TimeSpan.FromMilliseconds(50));
    Check.Equal(false, laterCallbackRan, "timer close cancels later callbacks");
}

using (var rebuilt = new Engine(41007))
{
    using var value = rebuilt.Evaluate("40 + 2", "rebuilt-after-timer-close.js");
    Check.Equal(42d, value.Number(), "timer close releases the instance ID");
}

var ownerContext = SynchronizationContext.Current;
try
{
    SynchronizationContext.SetSynchronizationContext(new SynchronizationContext());
    using var engine = new Engine(41008);
    var stopped = false;
    var ownerThreadId = Environment.CurrentManagedThreadId;
    var callbackThreadId = 0;
    using var stop = engine.Bind("stopBaseContextLoop", (_, _) =>
    {
        callbackThreadId = Environment.CurrentManagedThreadId;
        stopped = engine.StopLoop();
        return engine.Undefined();
    });
    using var timer = engine.Evaluate("setTimeout(stopBaseContextLoop, 1)", "base-context-loop.js");
    engine.RunLoop();
    Check.Equal(true, stopped, "base SynchronizationContext uses RunLoop");
    Check.Equal(ownerThreadId, callbackThreadId, "base SynchronizationContext keeps JavaScript on the owner thread");
}
finally
{
    SynchronizationContext.SetSynchronizationContext(ownerContext);
}

var closedStopEngine = new Engine(41009);
closedStopEngine.Close();
using (var replacement = new Engine(41009))
{
    Check.Equal(false, closedStopEngine.StopLoop(), "closed Engine cannot stop a replacement loop");
    var replacementStopped = false;
    using var stopReplacement = replacement.Bind("stopReplacementLoop", (_, _) =>
    {
        replacementStopped = replacement.StopLoop();
        return replacement.Undefined();
    });
    using var timer = replacement.Evaluate("setTimeout(stopReplacementLoop, 1)", "replacement-stop-loop.js");
    loopContext.PumpUntil(() => replacementStopped, TimeSpan.FromSeconds(2));
    Check.Equal(true, replacementStopped, "replacement Engine can stop its own loop");
}

using (var engine = new Engine(41002))
{
    using var closing = engine.Bind("closeFromCallback", (_, _) =>
    {
        engine.Close();
        return engine.Undefined();
    });
    Check.Equal(Status.InstanceNotFound,
        Check.Throws<JsBayException>(() => engine.Evaluate("closeFromCallback()", "close-callback.js"), "close from callback").Status,
        "close from callback prevents publication");
}

using (var engine = new Engine(41003))
{
    using var ready = new ManualResetEventSlim(false);
    using var callback = engine.Bind("ready", (_, _) => { ready.Set(); return engine.Undefined(); });
    var interrupter = Task.Run(() =>
    {
        if (!ready.Wait(TimeSpan.FromSeconds(2)))
        {
            throw new InvalidOperationException("script did not enter loop");
        }

        if (!engine.RequestInterrupt())
        {
            throw new InvalidOperationException("cross-thread interrupt failed");
        }
    });
    var interrupted = Check.Throws<JsException>(() => engine.Evaluate("ready(); for (;;) {}", "interrupt.js"), "interrupted execution");
    interrupted.Value.Dispose();
    interrupter.GetAwaiter().GetResult();
}

using (var engine = new Engine(41004))
{
    using var sync = engine.BindSync("nativeFetch", TimeSpan.FromSeconds(2), call =>
    {
        _ = Task.Run(() => call.Completion.ResolveString("41"));
    });
    using var answer = engine.Evaluate("const xxx = nativeFetch(); Number(xxx) + 1", "sync.js");
    Check.Equal(42d, answer.Number(), "native async operation appears synchronous to JS");

    using var rejects = engine.BindSync("nativeReject", TimeSpan.FromSeconds(2), call =>
        Task.Run(() => call.Completion.Reject("no")));
    var rejected = Check.Throws<JsException>(() => engine.Evaluate("nativeReject()", "sync-reject.js"), "sync reject");
    rejected.Value.Dispose();

    SyncCompletion? late = null;
    using var timesOut = engine.BindSync("nativeTimeout", TimeSpan.FromMilliseconds(30), call => late = call.Completion);
    var timeout = Check.Throws<JsException>(() => engine.Evaluate("nativeTimeout()", "sync-timeout.js"), "sync timeout");
    timeout.Value.Dispose();
    Check.Equal(Status.StaleValue, late!.TryResolveString("1"), "late completion is stale");
}

using (var engine = new Engine(41005))
{
    using var entered = new ManualResetEventSlim(false);
    SyncCompletion? cancelled = null;
    using var waits = engine.BindSync("nativeWait", TimeSpan.FromSeconds(2), call =>
    {
        cancelled = call.Completion;
        entered.Set();
    });
    var interrupter = Task.Run(() =>
    {
        if (!entered.Wait(TimeSpan.FromSeconds(2)))
        {
            throw new InvalidOperationException("sync call did not start");
        }

        if (!engine.RequestInterrupt())
        {
            throw new InvalidOperationException("sync wait interrupt failed");
        }
    });
    var interruptedSync = Check.Throws<JsException>(() => engine.Evaluate("nativeWait()", "sync-interrupt.js"), "interrupt sync wait");
    interruptedSync.Value.Dispose();
    interrupter.GetAwaiter().GetResult();
    Check.Equal(Status.StaleValue, cancelled!.TryResolveString("1"), "interrupted completion is stale");
}

Console.WriteLine("DOTNET_SDK_CONSUMER_PASS");
Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { assertions = Check.Assertions, failed = 0, skipped = 0 }));

static void ExpectJsError(Action action, string name, string message)
{
    var error = Check.Throws<JsException>(action, message);
    using (error.Value)
    using (var actual = error.Value.Get("name"))
    {
        Check.Equal(name, actual.String(), message);
    }
}

static void RunObjectOperations(Engine engine)
{
    using (var point = engine.Evaluate("(function P(x){ this.x = x })", "construct.js"))
    using (var answer = engine.Number(42))
    using (var built = point.Construct(new[] { answer }))
    using (var x = built.Get("x"))
    {
        Check.Equal(42d, x.Number(), "construct passes arguments");
        Check.Equal(true, built.InstanceOf(point), "constructed value is instanceOf its constructor");
    }
    using (var counter = engine.Evaluate("(function Q(){ this.n = arguments.length })", "construct-n.js"))
    using (var built = counter.Construct())
    using (var n = built.Get("n"))
    {
        Check.Equal(0d, n.Number(), "construct defaults to no arguments");
    }
    using (var boom = engine.Evaluate("(function B(){ throw new Error('ctor boom') })", "ctor-boom.js"))
    using (var arrow = engine.Evaluate("(() => 1)", "arrow-construct.js"))
    {
        ExpectJsError(() => boom.Construct(), "Error", "construct propagates constructor throw");
        ExpectJsError(() => arrow.Construct(), "TypeError", "construct rejects non-constructor");
    }

    using (var target = engine.Evaluate("({a: 1})", "has.js"))
    using (var number = engine.Number(42))
    using (var trap = engine.Evaluate("new Proxy({}, { has(t, k) { throw new Error('trap') } })", "has-trap.js"))
    {
        Check.Equal(true, target.Has("a"), "has own property");
        Check.Equal(true, target.Has("toString"), "has inherited property");
        Check.Equal(false, target.Has("zzz"), "has missing property is false");
        ExpectJsError(() => number.Has("a"), "TypeError", "has rejects non-object");
        ExpectJsError(() => trap.Has("a"), "Error", "has propagates Proxy trap throw");
    }

    using (var target = engine.Evaluate(
        "(() => { const o = {a: 1}; Object.defineProperty(o, 'fixed', {value: 1, configurable: false}); return o })()",
        "delete.js"))
    using (var undefined = engine.Undefined())
    using (var text = engine.String("abc"))
    {
        Check.Equal(true, target.Delete("a"), "delete configurable property");
        Check.Equal(false, target.Has("a"), "deleted property is gone");
        Check.Equal(false, target.Delete("fixed"), "delete non-configurable reports false");
        Check.Equal(true, target.Has("fixed"), "non-configurable property survives delete");
        Check.Equal(true, target.Delete("missing"), "delete missing property is true");
        ExpectJsError(() => undefined.Delete("a"), "TypeError", "delete rejects undefined");
        Check.Equal(true, text.Delete("zz"), "delete converts primitive with ToObject");
    }

    using (var target = engine.Evaluate(
        "(() => { const o = {b: 1, 2: 1, a: 1, 1: 1}; Object.defineProperty(o, 'hidden', {value: 1, enumerable: false}); o[Symbol('s')] = 1; return o })()",
        "keys.js"))
    using (var keys = target.Keys())
    using (var inherited = engine.Evaluate("Object.create({inherited: 1})", "keys-inherited.js"))
    using (var inheritedKeys = inherited.Keys())
    using (var ordered = engine.Evaluate(
        "new Proxy({}, { ownKeys() { return ['z', 'y'] }, getOwnPropertyDescriptor() { return {value: 1, enumerable: true, configurable: true} } })",
        "keys-proxy.js"))
    using (var orderedKeys = ordered.Keys())
    using (var nothing = engine.Evaluate("null", "keys-null.js"))
    {
        Check.Equal("[\"1\",\"2\",\"b\",\"a\"]", keys.Json(), "keys order and filtering");
        Check.Equal("[]", inheritedKeys.Json(), "keys excludes inherited keys");
        Check.Equal("[\"z\",\"y\"]", orderedKeys.Json(), "keys follows Proxy ownKeys order");
        ExpectJsError(() => nothing.Keys(), "TypeError", "keys rejects null");
    }

    using (var custom = engine.Evaluate("(class { static [Symbol.hasInstance](v) { return v === 7 } })", "has-instance.js"))
    using (var seven = engine.Number(7))
    using (var eight = engine.Number(8))
    using (var array = engine.Evaluate("[]", "instance-array.js"))
    using (var arrayClass = engine.Evaluate("Array", "instance-array-class.js"))
    using (var functionClass = engine.Evaluate("Function", "instance-function-class.js"))
    using (var plain = engine.Evaluate("({})", "instance-plain.js"))
    {
        Check.Equal(true, seven.InstanceOf(custom), "instanceOf honors Symbol.hasInstance");
        Check.Equal(false, eight.InstanceOf(custom), "instanceOf Symbol.hasInstance can decline");
        Check.Equal(true, array.InstanceOf(arrayClass), "instanceOf matches prototype chain");
        Check.Equal(false, array.InstanceOf(functionClass), "instanceOf rejects unrelated constructor");
        ExpectJsError(() => array.InstanceOf(plain), "TypeError", "instanceOf rejects non-callable constructor");
    }
}

static void RunLoopDeliveryChild(string mode)
{
    using var child = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, mode)
    {
        UseShellExecute = false,
        RedirectStandardError = true,
        RedirectStandardOutput = true,
    }) ?? throw new InvalidOperationException("could not start loop delivery child");
    if (!child.WaitForExit(5000))
    {
        child.Kill(entireProcessTree: true);
        throw new TimeoutException($"loop delivery child timed out: {mode}");
    }

    var output = child.StandardOutput.ReadToEnd() + child.StandardError.ReadToEnd();
    Check.Equal(0, child.ExitCode, $"loop delivery child {mode}: {output}");
}

static void RunRejectedPostChild(int acceptedPosts)
{
    using var context = new RejectingSynchronizationContext();
    if (acceptedPosts == 0)
    {
        context.ArmReject();
    }
    var previous = SynchronizationContext.Current;
    SynchronizationContext.SetSynchronizationContext(context);
    try
    {
        using var engine = new Engine(41901 + acceptedPosts);

        var callbackRan = false;
        Value? callback = null;
        Value? timer = null;
        _ = acceptedPosts;
        if (!context.Rejected.Wait(TimeSpan.FromSeconds(2)))
        {
            throw new TimeoutException($"SynchronizationContext did not reject the loop delivery after {context.PostCount} posts");
        }

        WaitForLoopFailure(engine);
        var error = Check.Throws<JsBayException>(() => engine.Evaluate("1", "rejected-post-status.js"), "rejected loop delivery is observable");
        Check.Equal(Status.LoopFailed, error.Status, "rejected loop delivery status");
        Check.Equal(false, callbackRan, "rejected loop delivery never runs JavaScript");
        engine.Close();
        timer?.Dispose();
        callback?.Dispose();
    }
    finally
    {
        SynchronizationContext.SetSynchronizationContext(previous);
    }
}

static void RunLaterRejectedPostChild()
{
    using var context = new BlockingRejectingSynchronizationContext();
    var previous = SynchronizationContext.Current;
    SynchronizationContext.SetSynchronizationContext(context);
    try
    {
        using var engine = new Engine(41902);
        if (!context.FirstAccepted.Wait(TimeSpan.FromSeconds(2)))
        {
            throw new TimeoutException("SynchronizationContext did not accept the initial loop delivery");
        }

        var callbackRan = false;
        using var callback = engine.Bind("deliveryMustNotRun", (_, _) =>
        {
            callbackRan = true;
            return engine.Undefined();
        });
        using var timer = engine.Evaluate("setTimeout(deliveryMustNotRun, 1000)", "rejected-later-post.js");
        context.PumpFirst();
        if (!context.SecondEntered.Wait(TimeSpan.FromSeconds(2)))
        {
            throw new TimeoutException("SynchronizationContext did not receive the replacement loop delivery");
        }

        context.RejectSecond.Set();
        if (!context.Rejected.Wait(TimeSpan.FromSeconds(2)))
        {
            throw new TimeoutException("SynchronizationContext did not reject the replacement loop delivery");
        }

        WaitForLoopFailure(engine);
        var error = Check.Throws<JsBayException>(() => engine.Evaluate("1", "rejected-later-post-status.js"), "rejected replacement loop delivery is observable");
        Check.Equal(Status.LoopFailed, error.Status, "rejected replacement loop delivery status");
        Check.Equal(false, callbackRan, "rejected replacement loop delivery never runs JavaScript");
        engine.Close();
    }
    finally
    {
        SynchronizationContext.SetSynchronizationContext(previous);
    }
}

static void RunWrongThreadPostChild()
{
    using var context = new ThreadPoolSynchronizationContext();
    var previous = SynchronizationContext.Current;
    SynchronizationContext.SetSynchronizationContext(context);
    try
    {
        using var engine = new Engine(41903);
        var callbackRan = false;
        using var callback = engine.Bind("deliveryMustNotRun", (_, _) =>
        {
            callbackRan = true;
            return engine.Undefined();
        });
        using var timer = engine.Evaluate("setTimeout(deliveryMustNotRun, 1)", "wrong-thread-post.js");
        if (!context.Posted.Wait(TimeSpan.FromSeconds(2)))
        {
            throw new TimeoutException("SynchronizationContext did not dispatch the loop delivery");
        }

        context.AllowCallbacks.Set();
        WaitForLoopFailure(engine);
        var error = Check.Throws<JsBayException>(() => engine.Evaluate("1", "wrong-thread-post-status.js"), "wrong-thread delivery is observable");
        Check.Equal(Status.LoopFailed, error.Status, "wrong-thread delivery status");
        Check.Equal(false, callbackRan, "wrong-thread delivery never runs JavaScript");
        engine.Close();
    }
    finally
    {
        SynchronizationContext.SetSynchronizationContext(previous);
    }
}

static void RunLoopStatusLockOrder()
{
#if JSBAY_TEST_HOOKS
    bool? held = null;
    Engine.TestLoopStatusBeforeNativeQuery = value => held = value;
    try
    {
        using var engine = new Engine(41906);
        _ = engine.ClearInterrupt();
        Check.Equal(false, held, "native loop status query does not hold the managed loop gate");
    }
    finally
    {
        Engine.TestLoopStatusBeforeNativeQuery = null;
    }
#endif
}

static void RunDerivedBaseContextChild()
{
    var previous = SynchronizationContext.Current;
    SynchronizationContext.SetSynchronizationContext(new DerivedBaseSynchronizationContext());
    try
    {
        using var engine = new Engine(41904);
        var stopped = false;
        using var stop = engine.Bind("stopLoop", (_, _) =>
        {
            stopped = engine.StopLoop();
            return engine.Undefined();
        });
        using var timer = engine.Evaluate("setTimeout(stopLoop, 1)", "derived-base-context.js");
        engine.RunLoop();
        Check.Equal(true, stopped, "derived base SynchronizationContext uses RunLoop");
    }
    finally
    {
        SynchronizationContext.SetSynchronizationContext(previous);
    }
}

static void RunNullContextChild()
{
    var previous = SynchronizationContext.Current;
    SynchronizationContext.SetSynchronizationContext(null);
    try
    {
        using var engine = new Engine(41905);
        var stopped = false;
        using var stop = engine.Bind("stopLoop", (_, _) =>
        {
            stopped = engine.StopLoop();
            return engine.Undefined();
        });
        using var timer = engine.Evaluate("setTimeout(stopLoop, 1)", "null-context.js");
        engine.RunLoop();
        Check.Equal(true, stopped, "no SynchronizationContext uses RunLoop");
    }
    finally
    {
        SynchronizationContext.SetSynchronizationContext(previous);
    }
}

static void WaitForLoopFailure(Engine engine)
{
    if (!SpinWait.SpinUntil(() =>
        {
            try
            {
                _ = engine.ClearInterrupt();
                return false;
            }
            catch (JsBayException error) when (error.Status == Status.LoopFailed)
            {
                return true;
            }
        }, TimeSpan.FromSeconds(2)))
    {
        throw new TimeoutException("loop delivery failure was not reported to the owner thread");
    }
}

internal static class Check
{
    private static int assertions;
    internal static int Assertions => Volatile.Read(ref assertions);
    public static void Equal<T>(T expected, T actual, string message)
    {
        Interlocked.Increment(ref assertions);
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
        {
            throw new InvalidOperationException($"{message}: expected {expected}, got {actual}");
        }
    }
    public static T Throws<T>(Action action, string message) where T : Exception
    {
        Interlocked.Increment(ref assertions);
        try
        {
            action();
        }
        catch (T error) { return error; }
        throw new InvalidOperationException($"{message}: expected {typeof(T).Name}");
    }
    public static void Contains(string expected, string actual, string message)
    {
        Interlocked.Increment(ref assertions);
        if (!actual.Contains(expected, StringComparison.Ordinal))
        {
            throw new InvalidOperationException($"{message}: expected {expected}, got {actual}");
        }
    }
}

internal sealed class PumpSynchronizationContext : SynchronizationContext, IDisposable
{
    private readonly Queue<(SendOrPostCallback callback, object? state)> pending = new();
    private readonly AutoResetEvent posted = new(false);

    public override void Post(SendOrPostCallback callback, object? state)
    {
        lock (pending)
        {
            pending.Enqueue((callback, state));
        }
        posted.Set();
    }

    public void PumpUntil(Func<bool> done, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!done())
        {
            if (DateTime.UtcNow >= deadline)
            {
                throw new TimeoutException("engine loop did not complete");
            }
            (SendOrPostCallback callback, object? state) item;
            lock (pending)
            {
                if (pending.Count == 0)
                {
                    item = default;
                }
                else
                {
                    item = pending.Dequeue();
                }
            }
            if (item.callback is not null)
            {
                item.callback(item.state);
            }
            else
            {
                posted.WaitOne(TimeSpan.FromMilliseconds(10));
            }
        }
    }

    public void PumpFor(TimeSpan duration)
    {
        var deadline = DateTime.UtcNow + duration;
        while (DateTime.UtcNow < deadline)
        {
            (SendOrPostCallback callback, object? state) item;
            lock (pending)
            {
                item = pending.Count == 0 ? default : pending.Dequeue();
            }
            if (item.callback is not null)
            {
                item.callback(item.state);
            }
            else
            {
                posted.WaitOne(TimeSpan.FromMilliseconds(10));
            }
        }
    }

    public void Dispose() => posted.Dispose();
}

internal sealed class RejectingSynchronizationContext : SynchronizationContext, IDisposable
{
    private readonly Queue<(SendOrPostCallback callback, object? state)> pending = new();
    private readonly AutoResetEvent posted = new(false);
    internal ManualResetEventSlim Accepted { get; } = new(false);
    internal ManualResetEventSlim Rejected { get; } = new(false);
    private int reject;
    private int postCount;

    internal int PostCount => Volatile.Read(ref postCount);

    internal void ArmReject() => Volatile.Write(ref reject, 1);

    public override void Post(SendOrPostCallback callback, object? state)
    {
        Interlocked.Increment(ref postCount);
        if (Volatile.Read(ref reject) != 0)
        {
            Rejected.Set();
            throw new InvalidOperationException("dispatcher rejected loop delivery");
        }

        lock (pending)
        {
            pending.Enqueue((callback, state));
        }
        Accepted.Set();
        posted.Set();
    }

    internal void PumpOne(TimeSpan timeout)
    {
        if (!posted.WaitOne(timeout))
        {
            throw new TimeoutException("dispatcher did not accept the initial loop delivery");
        }
        lock (pending)
        {
            var item = pending.Dequeue();
            item.callback(item.state);
        }
    }

    public void Dispose()
    {
        Rejected.Dispose();
        Accepted.Dispose();
        posted.Dispose();
    }
}

internal sealed class ThreadPoolSynchronizationContext : SynchronizationContext, IDisposable
{
    internal ManualResetEventSlim Posted { get; } = new(false);
    internal ManualResetEventSlim AllowCallbacks { get; } = new(false);

    public override void Post(SendOrPostCallback callback, object? state)
    {
        ThreadPool.QueueUserWorkItem(_ =>
        {
            Posted.Set();
            AllowCallbacks.Wait();
            callback(state);
        });
    }

    public void Dispose()
    {
        AllowCallbacks.Set();
        AllowCallbacks.Dispose();
        Posted.Dispose();
    }
}

internal sealed class BlockingRejectingSynchronizationContext : SynchronizationContext, IDisposable
{
    private readonly Queue<(SendOrPostCallback callback, object? state)> pending = new();
    private int posts;
    internal ManualResetEventSlim FirstAccepted { get; } = new(false);
    internal ManualResetEventSlim SecondEntered { get; } = new(false);
    internal ManualResetEventSlim RejectSecond { get; } = new(false);
    internal ManualResetEventSlim Rejected { get; } = new(false);

    public override void Post(SendOrPostCallback callback, object? state)
    {
        if (Interlocked.Increment(ref posts) == 1)
        {
            lock (pending)
            {
                pending.Enqueue((callback, state));
            }
            FirstAccepted.Set();
            return;
        }

        SecondEntered.Set();
        if (!RejectSecond.Wait(TimeSpan.FromSeconds(2)))
        {
            throw new TimeoutException("test did not release the replacement loop delivery");
        }
        Rejected.Set();
        throw new InvalidOperationException("dispatcher rejected replacement loop delivery");
    }

    internal void PumpFirst()
    {
        lock (pending)
        {
            if (pending.Count == 0)
            {
                throw new InvalidOperationException("initial loop delivery was not queued");
            }
            var item = pending.Dequeue();
            item.callback(item.state);
        }
    }

    public void Dispose()
    {
        FirstAccepted.Dispose();
        SecondEntered.Dispose();
        RejectSecond.Dispose();
        Rejected.Dispose();
    }
}

internal sealed class DerivedBaseSynchronizationContext : SynchronizationContext;

internal sealed class MessageGetterThrowsException : Exception
{
    public override string Message => throw new InvalidOperationException("Message getter must not escape a native callback");
}
