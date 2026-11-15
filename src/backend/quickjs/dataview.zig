//! Backend-typed facade for shared dataview support.

const c = @import("c_api.zig");

fn nativeIsDataView(val: c.qjs.JSValue) bool {
    return c.JS_IsDataView(val) != 0;
}

const shared = @import("../quickjs_common/dataview.zig").create(c, nativeIsDataView);

pub const QjsDataViewInfo = shared.QjsDataViewInfo;
pub const qjsIsDataView = shared.qjsIsDataView;
pub const qjsDataViewInfo = shared.qjsDataViewInfo;
pub const qjsNewDataView = shared.qjsNewDataView;
