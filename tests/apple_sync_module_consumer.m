// Compile-only consumer of the installed Clang module.  It intentionally imports no source-tree header so packaging errors are visible here.
@import JsBay;

int jsbay_apple_sync_module_consumer(void) {
    (void)&jsbay_engine_bind_sync;
    (void)&jsbay_sync_complete;
    return 0;
}
