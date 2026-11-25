//! Helpers shared by the QuickJS host-object adapters.

pub fn create(comptime c: type, comptime host_value: type) type {
    return struct {
        const qjs = c.qjs;

        pub fn throwMsg(ctx: ?*qjs.JSContext, msg: [*:0]const u8) qjs.JSValue {
            return qjs.JS_ThrowTypeError(ctx, "%s", msg);
        }

        /// Plain Error, not a TypeError. `message` is the own message string, so callers that only scan text still see the "TypeError: " prefix.
        pub fn throwPlainError(ctx: ?*qjs.JSContext, msg: [*:0]const u8) qjs.JSValue {
            const err = qjs.JS_NewError(ctx);
            if (c.jsIsException(err)) return err;
            const msg_val = c.jsbay_qjs_JS_NewString(ctx, msg);
            if (c.jsIsException(msg_val)) {
                c.jsbay_qjs_JS_FreeValue(ctx, err);
                return msg_val;
            }
            _ = qjs.JS_DefinePropertyValueStr(
                ctx,
                err,
                "message",
                msg_val,
                qjs.JS_PROP_WRITABLE | qjs.JS_PROP_CONFIGURABLE,
            );
            return qjs.JS_Throw(ctx, err);
        }

        pub fn hostToJs(ctx: ?*qjs.JSContext, hv: host_value.HostValue) qjs.JSValue {
            switch (hv.tag) {
                host_value.tag_number => return c.jsbay_qjs_JS_NewFloat64(ctx, hv.number),
                host_value.tag_string => {
                    const ptr = hv.ptr orelse return c.JS_UNDEFINED;
                    return qjs.JS_NewStringLen(ctx, ptr, hv.len);
                },
                else => return c.JS_UNDEFINED,
            }
        }
    };
}
