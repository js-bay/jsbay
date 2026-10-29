//! Patch-sensitive JavaScript semantics run through the public engine path.
//!
//! These are deliberately small regression sentinels for the areas touched by vendor patches and diagnostic hooks. They complement upstream Test262: a failure here means our integration changed an observable language result.

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");

test "patch semantics: TypedArray and DataView preserve byte order and views" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "var b=new ArrayBuffer(8);var d=new DataView(b);d.setUint16(0,0x1234,false);d.setUint16(2,0x5678,true);var a=new Uint8Array(b);a[0]+','+a[1]+','+a[2]+','+a[3]", "18,52,120,86");
        }
    }.run);
}

test "patch semantics: thrown values cross a finally block unchanged" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "var trace='';try{try{throw {tag:'expected'}}finally{trace='finally'}}catch(e){trace+':'+e.tag}", "finally:expected");
        }
    }.run);
}

test "patch semantics: debugger statement preserves subsequent completion value" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "var before=1; debugger; before+41", "42");
        }
    }.run);
}

test "patch semantics: nested catch finally and rethrow preserve the final thrown value" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "var trace=[];try{try{throw 'inner'}catch(e){trace.push(e);throw 'outer'}finally{trace.push('finally')}}catch(e){trace.push(e)}trace.join(',')", "inner,finally,outer");
        }
    }.run);
}

test "patch semantics: async jobs run after synchronous code in FIFO order" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "var order=[];Promise.resolve().then(function(){order.push('micro')});order.push('sync');order.join(',')", "sync");
            // evalScript drains pending jobs at its documented event-loop boundary.
            try helpers.expectEvalEquals(id, "order.join(',')", "sync,micro");
        }
    }.run);
}

test "patch semantics: reachable cyclic objects survive explicit garbage collection boundaries" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id, "globalThis.keep={v:41};keep.self=keep;keep.self.v", "41");
            engine.runGc(id);
            try helpers.expectEvalEquals(id, "keep.self.v+1", "42");
        }
    }.run);
}
