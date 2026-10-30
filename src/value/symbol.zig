//! Host-side Symbol and Symbol.for.
//!
//! `newSymbol` matches `Symbol(desc)`: two calls never strict-equal. `forKey` matches `Symbol.for(key)` and therefore equals a symbol the script created with the same key. The caller owns the returned value (`freeValue`). Null means the engine is gone or the backend failed.

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");

const ActiveEngine = backend.ActiveEngine;

pub fn newSymbol(instance_id: i32, desc: []const u8) ?ActiveEngine.Value {
    return make(instance_id, desc, false);
}

pub fn forKey(instance_id: i32, key: []const u8) ?ActiveEngine.Value {
    return make(instance_id, key, true);
}

fn make(instance_id: i32, text: []const u8, is_global: bool) ?ActiveEngine.Value {
    const ctx = engine.getContext(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const val = qjs_mod.qjsSymbol.make(ctx, text, is_global);
            if (qjs_mod.Backend.jsIsException(val)) {
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
                return null;
            }
            return val;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const ctx_ref: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            const raw = if (is_global)
                jsc_mod.jscSymbol.makeFor(ctx_ref, text)
            else
                jsc_mod.jscSymbol.makeUnique(ctx_ref, text);
            const sym = raw orelse return null;
            _ = jsc_mod.jsc.JSValueProtect(@ptrCast(ctx), sym);
            return sym;
        },
        .escargot, .hermes => {
            if (is_global) return ActiveEngine.symbolFor(ctx, text);
            return ActiveEngine.newSymbol(ctx, text);
        },
    }
}
