#include "quickjs.h"
#include <stdbool.h>

typedef void JSRuntimeFinalizer(JSRuntime *, void *);

JSValue JS_NewTypeError(JSContext *, const char *, ...);
JSValue JS_NewRangeError(JSContext *, const char *, ...);
JSValue JS_NewReferenceError(JSContext *, const char *, ...);
JSValue JS_NewSyntaxError(JSContext *, const char *, ...);
JSValue JS_NewInternalError(JSContext *, const char *, ...);
int JS_AddRuntimeFinalizer(JSRuntime *, JSRuntimeFinalizer *, void *);
bool JS_IsSameValue(JSContext *, JSValueConst, JSValueConst);
void JS_WalkHeapObjects(JSRuntime *, JSHeapObjectVisitor *, void *);
typedef void JSHeapGraphNodeVisitor(void *, const void *, const char *, size_t, int, uint64_t);
typedef void JSHeapGraphEdgeVisitor(void *, const void *, const void *, int, const char *, size_t, uint32_t);
void JS_WalkHeapGraph(JSRuntime *, JSHeapGraphNodeVisitor *, JSHeapGraphEdgeVisitor *, void *);
#if JSBAY_INSPECTOR
#endif
int jsbay_qjs_JS_IsPromise(JSContext *, JSValueConst);
