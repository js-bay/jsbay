using System.Diagnostics;
using JsBay;

const int Iterations = 1000;
const int Warmup = 100;
static long Measure(Action action, int n = Iterations) { for (var i = 0; i < Warmup; i++) action(); var timer = Stopwatch.StartNew(); for (var i = 0; i < n; i++) action(); return timer.ElapsedTicks * 1_000_000_000L / Stopwatch.Frequency; }
static void EvalNumber(Engine engine, string source) { using var result = engine.Evaluate(source, "interop.js"); if (result.Number() != 42) throw new InvalidOperationException("unexpected result"); }
using var engine = new Engine(810001);
using var binding = engine.Bind("benchCallback", (_, _) => engine.Number(42));
var eval = Measure(() => EvalNumber(engine, "var n=0; for(var i=0;i<64;i++)n+=i; 42"));
var callback = Measure(() => EvalNumber(engine, "benchCallback()"));
var textJson = Measure(() => { using var value = engine.Evaluate("({text:'public interop',count:42})", "text-json.js"); if (value.Json() != "{\"text\":\"public interop\",\"count\":42}") throw new InvalidOperationException("unexpected JSON"); });
var bytes = Enumerable.Repeat((byte)7, 4096).ToArray();
var buffer = Measure(() => { using var value = engine.ArrayBuffer(bytes); if (!value.Bytes().SequenceEqual(bytes)) throw new InvalidOperationException("buffer mismatch"); });
engine.Close();
Action lifecycleOperation = () => { using var valueEngine = new Engine(820000 + Random.Shared.Next(100000)); using var value = valueEngine.Evaluate("42", "lifecycle.js"); if (value.Number() != 42) throw new InvalidOperationException("unexpected lifecycle result"); };
for (var i = 0; i < Warmup; i++) lifecycleOperation();
var lifecycleTimer = Stopwatch.StartNew();
for (var i = 0; i < 100; i++) lifecycleOperation();
var lifecycle = lifecycleTimer.ElapsedTicks * 1_000_000_000L / Stopwatch.Frequency;
Console.WriteLine($"{eval} {callback} {textJson} {buffer} {lifecycle}");
