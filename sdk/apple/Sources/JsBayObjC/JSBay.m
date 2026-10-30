#import "jsbay.h"
#import "JSBayObjC.h"
#import "jsbay_sync.h"
#import <pthread.h>
#include <stdlib.h>
#include <string.h>

NSErrorDomain const JSBayErrorDomain = @"com.jsbay.error";
NSErrorUserInfoKey const JSBayExceptionValueKey = @"JSBayExceptionValue";

@class JSBayCallbackScope;
@interface JSBayEngine ()
@property(nonatomic) pthread_t owner;
@property(atomic) BOOL open;
@property(nonatomic) BOOL allowMainRunLoopAttach;
@property(nonatomic) void *loopUserData;
@property(nonatomic) jsbay_status_t loopRestoreFailure;
@property(nonatomic, strong) NSMutableArray<JSBayCallbackScope *> *scopes;
- (nullable JSBayValue *)ownedValue:(uint64_t)handle;
- (BOOL)requireOpen:(NSError **)error;
- (BOOL)requireSame:(JSBayValue *)value error:(NSError **)error;
- (nullable JSBayValue *)valueResult:(jsbay_status_t)status
                               value:(uint64_t)value
                           exception:(uint64_t)exception
                               error:(NSError **)error;
- (BOOL)voidResult:(jsbay_status_t)status exception:(uint64_t)exception error:(NSError **)error;
- (JSBayCallbackScope *)beginCallbackScope;
- (void)endCallbackScope:(JSBayCallbackScope *)scope;
@end

@interface JSBayCacheOptions ()
@property(nonatomic) BOOL didHit;
@end

@interface JSBayValue ()
@property(nonatomic, weak) JSBayEngine *engine;
@property(nonatomic) uint64_t handle;
@property(nonatomic) BOOL borrowed;
@property(nonatomic) BOOL closed;
- (instancetype)initWithEngine:(JSBayEngine *)engine
                        handle:(uint64_t)handle
                      borrowed:(BOOL)borrowed;
- (BOOL)usable:(NSError **)error;
- (BOOL)requireOwnedForConsume:(NSError **)error;
- (uint64_t)callbackHandleForEngine:(JSBayEngine *)engine error:(NSError **)error;
- (void)closeFromCallbackScope;
- (void)invalidateBorrowed;
@end

@interface JSBayCallbackScope : NSObject
@property(nonatomic, strong) NSMutableArray<JSBayValue *> *owned;
@property(nonatomic, strong) NSMutableArray<JSBayValue *> *borrowed;
- (void)trackOwned:(JSBayValue *)value;
- (void)trackBorrowed:(JSBayValue *)value;
- (void)close;
@end

@interface JSBayBinding : NSObject
@property(nonatomic, weak) JSBayEngine *engine;
@property(nonatomic, copy) JSBayNativeCallback callback;
@end
static NSError *JSBayStatusError(jsbay_status_t status);
@implementation JSBayBinding
@end

@interface JSBaySyncBinding : NSObject
@property(nonatomic, weak) JSBayEngine *engine;
@property(nonatomic, copy) JSBaySyncStarter starter;
@end
@implementation JSBaySyncBinding
@end
@class JSBayLoopBinding;
@interface JSBayLoopTicket : NSObject
@property(nonatomic, weak) JSBayLoopBinding *binding;
@property(nonatomic) uint64_t generation;
@property(nonatomic) jsbay_loop_task_t task;
@property(nonatomic) void *taskData;
@end
@implementation JSBayLoopTicket
@end

@interface JSBayLoopBinding : NSObject
@property(nonatomic) CFRunLoopRef runLoop;
@property(nonatomic) NSLock *lock;
@property(nonatomic) CFRunLoopTimerRef timer;
@property(nonatomic) uint64_t generation;
@property(nonatomic) BOOL attached;
@property(nonatomic) int32_t identifier;
- (instancetype)initWithRunLoop:(CFRunLoopRef)runLoop identifier:(int32_t)identifier;
- (BOOL)scheduleAfter:(uint64_t)delay task:(jsbay_loop_task_t)task data:(void *)data;
- (void)cancel;
- (void)shutdown;
@end

@implementation JSBayLoopBinding
- (instancetype)initWithRunLoop:(CFRunLoopRef)runLoop identifier:(int32_t)identifier {
    if ((self = [super init])) {
        _runLoop = (CFRunLoopRef)CFRetain(runLoop);
        _lock = [NSLock new];
        _attached = YES;
        _identifier = identifier;
    }
    return self;
}
- (void)dealloc {
    if (_timer)
        CFRelease(_timer);
    CFRelease(_runLoop);
}
- (BOOL)scheduleAfter:(uint64_t)delay task:(jsbay_loop_task_t)task data:(void *)data {
    [_lock lock];
    if (!_attached) {
        [_lock unlock];
        return NO;
    }
    uint64_t generation = ++_generation;
    [_lock unlock];
    CFRetain((__bridge CFTypeRef)self);
    CFRunLoopPerformBlock(_runLoop, kCFRunLoopCommonModes, ^{
        [self.lock lock];
        if (!self.attached || self.generation != generation) {
            [self.lock unlock];
            CFRelease((__bridge CFTypeRef)self);
            return;
        }
        if (_timer) {
            CFRunLoopTimerInvalidate(_timer);
            CFRelease(_timer);
            _timer = NULL;
        }
        JSBayLoopTicket *ticket = [JSBayLoopTicket new];
        ticket.binding = self;
        ticket.generation = generation;
        ticket.task = task;
        ticket.taskData = data;
        CFRunLoopTimerRef timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + ((CFTimeInterval)delay / 1000.0), 0,
            0, 0, ^(CFRunLoopTimerRef unused) {
                (void)unused;
                JSBayLoopBinding *binding = ticket.binding;
                [binding.lock lock];
                BOOL run = binding.attached && binding.generation == ticket.generation;
                if (run) {
                    CFRelease(binding->_timer);
                    binding->_timer = NULL;
                }
                [binding.lock unlock];
                if (run) {
                    ticket.task(ticket.taskData);
                    (void)jsbay_engine_loop_status(binding.identifier);
                }
            });
        _timer = timer;
        CFRunLoopAddTimer(self.runLoop, timer, kCFRunLoopCommonModes);
        [self.lock unlock];
        CFRelease((__bridge CFTypeRef)self);
    });
    CFRunLoopWakeUp(_runLoop);
    return YES;
}
- (void)cancel {
    /* Soft cancel: drop pending timer only; keep attached so suspend/resume can schedule again. */
    [_lock lock];
    ++_generation;
    if (_timer) {
        CFRunLoopTimerInvalidate(_timer);
        CFRelease(_timer);
        _timer = NULL;
    }
    [_lock unlock];
}
- (void)shutdown {
    /* Hard teardown after detach/destroy. */
    [_lock lock];
    _attached = NO;
    ++_generation;
    if (_timer) {
        CFRunLoopTimerInvalidate(_timer);
        CFRelease(_timer);
        _timer = NULL;
    }
    [_lock unlock];
}
@end

static bool JSBayLoopSchedule(void *userData, uint64_t delay, jsbay_loop_task_t task,
                              void *taskData) {
    return [(__bridge JSBayLoopBinding *)userData scheduleAfter:delay task:task data:taskData];
}
static void JSBayLoopCancel(void *userData) {
    [(__bridge JSBayLoopBinding *)userData cancel];
}

@interface JSBaySyncCompletion ()
@property(nonatomic) uint64_t requestID;
@property(nonatomic) BOOL terminal;
@property(nonatomic, strong) NSLock *lock;
- (instancetype)initWithRequestID:(uint64_t)requestID;
@end
@implementation JSBaySyncCompletion
- (instancetype)initWithRequestID:(uint64_t)requestID {
    if ((self = [super init])) {
        _requestID = requestID;
        _lock = [NSLock new];
    }
    return self;
}
- (JSBayErrorCode)complete:(jsbay_status_t)outcome
                      kind:(jsbay_sync_payload_kind_t)kind
                      data:(NSData *)data {
    [_lock lock];
    @try {
        if (_terminal)
            return JSBayErrorStaleValue;
        if (!data)
            return JSBayErrorInvalidArgument;
        jsbay_status_t status = jsbay_sync_complete(
            _requestID, outcome, kind, (jsbay_utf8_t){.data = data.bytes, .len = data.length});
        if (status == JSBAY_OK || status == JSBAY_STALE_VALUE)
            _terminal = YES;
        return (JSBayErrorCode)status;
    } @finally {
        [_lock unlock];
    }
}
- (JSBayErrorCode)tryResolveString:(NSString *)value {
    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!data)
        return JSBayErrorInvalidArgument;
    return [self complete:JSBAY_OK kind:JSBAY_SYNC_PAYLOAD_UTF8_STRING data:data];
}
- (JSBayErrorCode)tryResolveBytes:(NSData *)bytes {
    return [self complete:JSBAY_OK kind:JSBAY_SYNC_PAYLOAD_BYTES data:bytes ?: [NSData data]];
}
- (JSBayErrorCode)tryReject:(NSString *)message {
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!data)
        return JSBayErrorInvalidArgument;
    return [self complete:JSBAY_EXCEPTION kind:JSBAY_SYNC_PAYLOAD_UTF8_STRING data:data];
}
- (BOOL)resolveString:(NSString *)value error:(NSError **)error {
    JSBayErrorCode code = [self tryResolveString:value];
    if (code != JSBayErrorOK) {
        if (error)
            *error = JSBayStatusError((jsbay_status_t)code);
        return NO;
    }
    return YES;
}
- (BOOL)resolveBytes:(NSData *)bytes error:(NSError **)error {
    JSBayErrorCode code = [self tryResolveBytes:bytes];
    if (code != JSBayErrorOK) {
        if (error)
            *error = JSBayStatusError((jsbay_status_t)code);
        return NO;
    }
    return YES;
}
- (BOOL)reject:(NSString *)message error:(NSError **)error {
    JSBayErrorCode code = [self tryReject:message];
    if (code != JSBayErrorOK) {
        if (error)
            *error = JSBayStatusError((jsbay_status_t)code);
        return NO;
    }
    return YES;
}
@end

static NSError *JSBayStatusError(jsbay_status_t status) {
    return [NSError errorWithDomain:JSBayErrorDomain
                               code:status
                           userInfo:@{
                               NSLocalizedDescriptionKey :
                                   [NSString stringWithFormat:@"JsBay status %d", status]
                           }];
}
NSString *JSBayDescribeAndCloseException(NSError *exception, NSError **error) {
    if (error)
        *error = nil;
    JSBayValue *original = exception.userInfo[JSBayExceptionValueKey];
    if (!original) {
        if (error)
            *error = exception;
        return nil;
    }
    NSError *local = nil;
    if (![original requireOwnedForConsume:&local]) {
        if (error)
            *error = local;
        return nil;
    }
    NSString *description = [original stringValue:&local];
    if (description) {
        if (![original close:&local]) {
            if (error)
                *error = local;
            return nil;
        }
        return description;
    }
    JSBayValue *secondary = local.userInfo[JSBayExceptionValueKey];
    if (!secondary) {
        if (error)
            *error = local;
        return nil;
    }
    NSError *closeError = nil;
    BOOL secondaryClosed = [secondary close:&closeError];
    BOOL originalClosed = [original close:&closeError];
    if (!secondaryClosed || !originalClosed) {
        if (error)
            *error = closeError;
        return nil;
    }
    return @"JavaScript exception";
}
static BOOL JSBayUTF8(NSString *string, NSData **storage, jsbay_utf8_t *output, NSError **error) {
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!data) {
        if (error)
            *error = [NSError
                errorWithDomain:JSBayErrorDomain
                           code:JSBAY_INVALID_ARGUMENT
                       userInfo:@{NSLocalizedDescriptionKey : @"text must be well-formed Unicode"}];
        return NO;
    }
    *storage = data;
    *output = (jsbay_utf8_t){.data = data.bytes, .len = data.length};
    return YES;
}
static NSLock *JSBayEngineStateLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSLock new];
    });
    return lock;
}

@implementation JSBayCacheOptions
@synthesize directory = _directory, version = _version, didHit = _didHit;
- (instancetype)initWithDirectory:(NSString *)directory version:(NSString *)version {
    if ((self = [super init])) {
        _directory = [directory copy];
        _version = [version copy];
    }
    return self;
}
@end

@implementation JSBayCallbackScope
- (instancetype)init {
    if ((self = [super init])) {
        _owned = [NSMutableArray array];
        _borrowed = [NSMutableArray array];
    }
    return self;
}
- (void)trackOwned:(JSBayValue *)value {
    [_owned addObject:value];
}
- (void)trackBorrowed:(JSBayValue *)value {
    [_borrowed addObject:value];
}
- (void)close {
    for (JSBayValue *value in _borrowed)
        [value invalidateBorrowed];
    for (JSBayValue *value in _owned)
        [value closeFromCallbackScope];
    [_borrowed removeAllObjects];
    [_owned removeAllObjects];
}
@end

@implementation JSBayValue
- (instancetype)initWithEngine:(JSBayEngine *)engine
                        handle:(uint64_t)handle
                      borrowed:(BOOL)borrowed {
    if ((self = [super init])) {
        _engine = engine;
        _handle = handle;
        _borrowed = borrowed;
    }
    return self;
}
- (BOOL)usable:(NSError **)error {
    if (_closed || !_handle || !_engine || !_engine.open) {
        if (error)
            *error = JSBayStatusError(JSBAY_STALE_VALUE);
        return NO;
    }
    return [_engine requireOpen:error];
}
- (BOOL)requireOwnedForConsume:(NSError **)error {
    if (_borrowed) {
        if (error)
            *error = JSBayStatusError(_closed ? JSBAY_STALE_VALUE : JSBAY_INVALID_ARGUMENT);
        return NO;
    }
    return [self usable:error];
}
- (BOOL)close:(NSError **)error {
    if (_closed) {
        if (_borrowed) {
            if (error)
                *error = JSBayStatusError(JSBAY_STALE_VALUE);
            return NO;
        }
        return YES;
    }
    if (_borrowed) {
        if (error)
            *error = JSBayStatusError(JSBAY_INVALID_ARGUMENT);
        return NO;
    }
    if (!_engine || !_engine.open) {
        _closed = YES;
        _handle = 0;
        return YES;
    }
    if (![_engine requireOpen:error])
        return NO;
    jsbay_status_t status = jsbay_value_release(_handle);
    if (status != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(status);
        return NO;
    }
    _closed = YES;
    _handle = 0;
    return YES;
}
- (void)closeFromCallbackScope {
    if (_closed)
        return;
    if (!_borrowed && _engine.open)
        (void)jsbay_value_release(_handle);
    _closed = YES;
    _handle = 0;
}
- (void)invalidateBorrowed {
    if (_borrowed) {
        _closed = YES;
        _handle = 0;
    }
}
- (uint64_t)callbackHandleForEngine:(JSBayEngine *)engine error:(NSError **)error {
    if (![engine requireSame:self error:error])
        return 0;
    uint64_t copy = 0;
    jsbay_status_t status = jsbay_value_retain(_handle, &copy);
    if (status != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(status);
        return 0;
    }
    return copy;
}
- (nullable JSBayValue *)retainValue:(NSError **)error {
    if (![self usable:error])
        return nil;
    uint64_t copy = 0;
    jsbay_status_t status = jsbay_value_retain(_handle, &copy);
    if (status != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(status);
        return nil;
    }
    // Intentionally bypasses callback scope: retain is the explicit escape hatch.
    return [[JSBayValue alloc] initWithEngine:_engine handle:copy borrowed:NO];
}
- (BOOL)valueKind:(JSBayValueKind *)output error:(NSError **)error {
    if (!output || ![self usable:error])
        return NO;
    jsbay_value_kind_t kind = JSBAY_VALUE_UNDEFINED;
    jsbay_status_t status = jsbay_value_type(_handle, &kind);
    if (status != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(status);
        return NO;
    }
    *output = (JSBayValueKind)kind;
    return YES;
}
- (BOOL)boolValue:(BOOL *)output error:(NSError **)error {
    if (![self usable:error])
        return NO;
    bool value = false;
    jsbay_status_t s = jsbay_value_to_bool(_handle, &value);
    if (s != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(s);
        return NO;
    }
    *output = value;
    return YES;
}
- (BOOL)numberValue:(double *)output error:(NSError **)error {
    if (![self usable:error])
        return NO;
    double value = 0;
    jsbay_status_t s = jsbay_value_to_number(_handle, &value);
    if (s != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(s);
        return NO;
    }
    *output = value;
    return YES;
}
- (nullable NSString *)text:(BOOL)json error:(NSError **)error {
    if (![self usable:error])
        return nil;
    jsbay_bytes_t bytes = {0};
    uint64_t exception = 0;
    jsbay_status_t s = json ? jsbay_value_to_json(_handle, &bytes, &exception)
                            : jsbay_value_to_utf8(_handle, &bytes, &exception);
    if (![_engine voidResult:s exception:exception error:error])
        return nil;
    NSString *result = [[NSString alloc] initWithBytes:bytes.data
                                                length:bytes.len
                                              encoding:NSUTF8StringEncoding];
    jsbay_free_bytes(bytes);
    if (!result && error)
        *error = [NSError
            errorWithDomain:JSBayErrorDomain
                       code:JSBAY_INVALID_ARGUMENT
                   userInfo:@{NSLocalizedDescriptionKey : @"js-bay returned invalid UTF-8"}];
    return result;
}
- (NSString *)stringValue:(NSError **)error {
    return [self text:NO error:error];
}
- (NSString *)jsonValue:(NSError **)error {
    return [self text:YES error:error];
}
- (NSData *)dataValue:(NSError **)error {
    if (![self usable:error])
        return nil;
    jsbay_bytes_t bytes = {0};
    uint64_t exception = 0;
    jsbay_status_t status = jsbay_value_copy_buffer(_handle, &bytes, &exception);
    if (![_engine voidResult:status exception:exception error:error])
        return nil;
    NSData *data = [NSData dataWithBytes:bytes.data length:bytes.len];
    jsbay_free_bytes(bytes);
    return data;
}
- (nullable JSBayValue *)valueForKey:(NSString *)key error:(NSError **)error {
    if (![self usable:error])
        return nil;
    NSData *data;
    jsbay_utf8_t utf8;
    if (!JSBayUTF8(key, &data, &utf8, error))
        return nil;
    uint64_t value = 0, exception = 0;
    return [_engine valueResult:jsbay_value_get(_handle, utf8, &value, &exception)
                          value:value
                      exception:exception
                          error:error];
}
- (BOOL)setValue:(JSBayValue *)value forKey:(NSString *)key error:(NSError **)error {
    if (![self usable:error] || ![_engine requireSame:value error:error])
        return NO;
    NSData *data;
    jsbay_utf8_t utf8;
    if (!JSBayUTF8(key, &data, &utf8, error))
        return NO;
    uint64_t exception = 0;
    return [_engine voidResult:jsbay_value_set(_handle, utf8, value.handle, &exception)
                     exception:exception
                         error:error];
}
- (nullable JSBayValue *)callWithThis:(JSBayValue *)thisValue
                            arguments:(NSArray<JSBayValue *> *)arguments
                                error:(NSError **)error {
    if (![self usable:error])
        return nil;
    JSBayValue *receiver = thisValue;
    JSBayValue *temporary = nil;
    if (!receiver) {
        temporary = [_engine undefinedValue:error];
        if (!temporary)
            return nil;
        receiver = temporary;
    }
    @try {
        if (![_engine requireSame:receiver error:error])
            return nil;
        for (JSBayValue *arg in arguments)
            if (![_engine requireSame:arg error:error])
                return nil;
        NSUInteger count = arguments.count;
        uint64_t *handles = count ? calloc(count, sizeof(uint64_t)) : NULL;
        if (count && !handles) {
            if (error)
                *error = JSBayStatusError(JSBAY_OUT_OF_MEMORY);
            return nil;
        }
        for (NSUInteger i = 0; i < count; i++)
            handles[i] = arguments[i].handle;
        uint64_t value = 0, exception = 0;
        JSBayValue *result =
            [_engine valueResult:jsbay_value_call(_handle, receiver.handle, handles, count, &value,
                                                  &exception)
                           value:value
                       exception:exception
                           error:error];
        free(handles);
        return result;
    } @finally {
        [temporary close:nil];
    }
}
- (nullable JSBayValue *)constructWithArguments:(NSArray<JSBayValue *> *)arguments
                                          error:(NSError **)error {
    if (![self usable:error])
        return nil;
    for (JSBayValue *arg in arguments)
        if (![_engine requireSame:arg error:error])
            return nil;
    NSUInteger count = arguments.count;
    uint64_t *handles = count ? calloc(count, sizeof(uint64_t)) : NULL;
    if (count && !handles) {
        if (error)
            *error = JSBayStatusError(JSBAY_OUT_OF_MEMORY);
        return nil;
    }
    for (NSUInteger i = 0; i < count; i++)
        handles[i] = arguments[i].handle;
    uint64_t value = 0, exception = 0;
    JSBayValue *result =
        [_engine valueResult:jsbay_value_construct(_handle, handles, count, &value, &exception)
                       value:value
                   exception:exception
                       error:error];
    free(handles);
    return result;
}
- (BOOL)hasKey:(NSString *)key result:(BOOL *)result error:(NSError **)error {
    if (![self usable:error])
        return NO;
    NSData *data;
    jsbay_utf8_t utf8;
    if (!JSBayUTF8(key, &data, &utf8, error))
        return NO;
    bool found = false;
    uint64_t exception = 0;
    if (![_engine voidResult:jsbay_value_has(_handle, utf8, &found, &exception)
                   exception:exception
                       error:error])
        return NO;
    *result = found;
    return YES;
}
- (BOOL)deleteKey:(NSString *)key result:(BOOL *)result error:(NSError **)error {
    if (![self usable:error])
        return NO;
    NSData *data;
    jsbay_utf8_t utf8;
    if (!JSBayUTF8(key, &data, &utf8, error))
        return NO;
    bool deleted = false;
    uint64_t exception = 0;
    if (![_engine voidResult:jsbay_value_delete(_handle, utf8, &deleted, &exception)
                   exception:exception
                       error:error])
        return NO;
    *result = deleted;
    return YES;
}
- (nullable JSBayValue *)keysWithError:(NSError **)error {
    if (![self usable:error])
        return nil;
    uint64_t array = 0, exception = 0;
    return [_engine valueResult:jsbay_value_keys(_handle, &array, &exception)
                          value:array
                      exception:exception
                          error:error];
}
- (BOOL)instanceOfConstructor:(JSBayValue *)constructor
                       result:(BOOL *)result
                        error:(NSError **)error {
    if (![self usable:error] || ![_engine requireSame:constructor error:error])
        return NO;
    bool matched = false;
    uint64_t exception = 0;
    if (![_engine
            voidResult:jsbay_value_instance_of(_handle, constructor.handle, &matched, &exception)
             exception:exception
                 error:error])
        return NO;
    *result = matched;
    return YES;
}
@end

static jsbay_status_t JSBayThrownCallbackException(int instance, NSException *exception,
                                                   uint64_t *outException) {
    static const uint8_t fallback[] = "Objective-C callback threw";
    *outException = 0;
    @try {
        NSString *message = exception.reason ?: exception.name ?: @"Objective-C callback threw";
        NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
        if (data) {
            jsbay_status_t status = jsbay_value_new_error(
                instance, (jsbay_utf8_t){.data = data.bytes, .len = data.length}, outException);
            if (status == JSBAY_OK && *outException)
                return JSBAY_EXCEPTION;
        }
    } @catch (__unused NSException *diagnosticFailure) {
        // Formatting an Objective-C exception must not cross the C callback ABI either.
    }
    jsbay_status_t status = jsbay_value_new_error(
        instance, (jsbay_utf8_t){.data = fallback, .len = sizeof(fallback) - 1}, outException);
    return status == JSBAY_OK && *outException ? JSBAY_EXCEPTION : JSBAY_OUT_OF_MEMORY;
}

static jsbay_status_t JSBayHostCallback(int instance, void *userData, uint64_t thisHandle,
                                        size_t argc, const uint64_t *args, uint64_t *outValue,
                                        uint64_t *outException) {
    JSBayBinding *binding = (__bridge JSBayBinding *)userData;
    CFRetain((__bridge CFTypeRef)binding);
    *outValue = 0;
    *outException = 0;
    @try {
        JSBayEngine *engine = binding.engine;
        if (!engine.open || engine.identifier != instance)
            return JSBAY_INSTANCE_NOT_FOUND;
        JSBayCallbackScope *scope = [engine beginCallbackScope];
        @try {
            JSBayValue *thisValue = [[JSBayValue alloc] initWithEngine:engine
                                                                handle:thisHandle
                                                              borrowed:YES];
            [scope trackBorrowed:thisValue];
            NSMutableArray *values = [NSMutableArray array];
            for (size_t i = 0; i < argc; i++) {
                JSBayValue *v = [[JSBayValue alloc] initWithEngine:engine
                                                            handle:args[i]
                                                          borrowed:YES];
                [scope trackBorrowed:v];
                [values addObject:v];
            }
            NSError *error = nil;
            JSBayValue *result = binding.callback(thisValue, values, &error);
            if (result) {
                uint64_t handle = [result callbackHandleForEngine:engine error:&error];
                if (handle) {
                    *outValue = handle;
                    return JSBAY_OK;
                }
                return JSBAY_STALE_VALUE;
            }
            JSBayValue *exception = error.userInfo[JSBayExceptionValueKey];
            if (exception) {
                uint64_t handle = [exception callbackHandleForEngine:engine error:&error];
                if (handle) {
                    *outException = handle;
                    return JSBAY_EXCEPTION;
                }
                return JSBAY_STALE_VALUE;
            }
            JSBayValue *native =
                [engine errorValue:error.localizedDescription ?: @"Native callback failed"
                             error:nil];
            uint64_t handle = [native callbackHandleForEngine:engine error:nil];
            if (handle) {
                *outException = handle;
                return JSBAY_EXCEPTION;
            }
            return JSBAY_OUT_OF_MEMORY;
        } @finally {
            [engine endCallbackScope:scope];
        }
    } @catch (NSException *exception) {
        return JSBayThrownCallbackException(instance, exception, outException);
    } @finally {
        CFRelease((__bridge CFTypeRef)binding);
    }
}
static void JSBayHostFinalize(void *userData) {
    CFBridgingRelease(userData);
}

static void JSBaySyncStart(int instance, void *userData, uint64_t requestID, uint64_t thisHandle,
                           size_t argc, const uint64_t *args) {
    JSBaySyncBinding *binding = (__bridge JSBaySyncBinding *)userData;
    CFRetain((__bridge CFTypeRef)binding);
    JSBaySyncCompletion *completion = [[JSBaySyncCompletion alloc] initWithRequestID:requestID];
    @try {
        JSBayEngine *engine = binding.engine;
        if (!engine.open || engine.identifier != instance)
            return;
        JSBayCallbackScope *scope = [engine beginCallbackScope];
        @try {
            JSBayValue *thisValue = [[JSBayValue alloc] initWithEngine:engine
                                                                handle:thisHandle
                                                              borrowed:YES];
            [scope trackBorrowed:thisValue];
            NSMutableArray *values = [NSMutableArray array];
            for (size_t i = 0; i < argc; i++) {
                JSBayValue *v = [[JSBayValue alloc] initWithEngine:engine
                                                            handle:args[i]
                                                          borrowed:YES];
                [scope trackBorrowed:v];
                [values addObject:v];
            }
            binding.starter(thisValue, values, completion);
        } @finally {
            [engine endCallbackScope:scope];
        }
    } @catch (__unused NSException *exception) {
        [completion tryReject:@"Objective-C sync callback threw"];
    } @finally {
        CFRelease((__bridge CFTypeRef)binding);
    }
}

@interface JSBayResourceLimits (Private)
- (jsbay_resource_limits_t)cLimits;
@end
@implementation JSBayResourceLimits
- (instancetype)init {
    if (!(self = [super init]))
        return nil;
    _maxTimers = 4096;
    _maxTsfnHandles = 256;
    _maxPendingCalls = 4096;
    _maxPendingBytes = 8u * 1024u * 1024u;
    _maxPendingTasks = 4096;
    return self;
}
- (jsbay_resource_limits_t)cLimits {
    return (jsbay_resource_limits_t){
        .struct_size = sizeof(jsbay_resource_limits_t),
        .max_timers = self.maxTimers,
        .max_tsfn_handles = self.maxTsfnHandles,
        .max_pending_calls = self.maxPendingCalls,
        .max_pending_bytes = self.maxPendingBytes,
        .max_pending_tasks = self.maxPendingTasks,
    };
}
@end

@interface JSBayResourceUsage ()
@property(nonatomic, readwrite) NSUInteger timers;
@property(nonatomic, readwrite) NSUInteger tsfnHandles;
@property(nonatomic, readwrite) NSUInteger pendingCalls;
@property(nonatomic, readwrite) NSUInteger nativeTasks;
@property(nonatomic, readwrite) NSUInteger scriptTasks;
@property(nonatomic, readwrite) NSUInteger pendingBytes;
@property(nonatomic, copy, readwrite) JSBayResourceLimits *limits;
@end
@implementation JSBayResourceUsage
@end

@interface JSBayResourceGlobalUsage ()
@property(nonatomic, readwrite) NSUInteger timers;
@property(nonatomic, readwrite) NSUInteger tsfnHandles;
@property(nonatomic, readwrite) NSUInteger pendingCalls;
@property(nonatomic, readwrite) NSUInteger nativeTasks;
@property(nonatomic, readwrite) NSUInteger scriptTasks;
@property(nonatomic, readwrite) NSUInteger pendingBytes;
@property(nonatomic, readwrite) NSUInteger maxTimers;
@property(nonatomic, readwrite) NSUInteger maxTsfnHandles;
@property(nonatomic, readwrite) NSUInteger maxPendingCalls;
@property(nonatomic, readwrite) NSUInteger maxNativeTasks;
@property(nonatomic, readwrite) NSUInteger maxScriptTasks;
@property(nonatomic, readwrite) NSUInteger maxPendingBytes;
@property(nonatomic, readwrite) NSUInteger fgHeadroomTimers;
@property(nonatomic, readwrite) NSUInteger fgHeadroomTsfnHandles;
@property(nonatomic, readwrite) NSUInteger fgHeadroomPendingCalls;
@property(nonatomic, readwrite) NSUInteger fgHeadroomNativeTasks;
@property(nonatomic, readwrite) NSUInteger fgHeadroomScriptTasks;
@property(nonatomic, readwrite) NSUInteger fgHeadroomPendingBytes;
@property(nonatomic, readwrite) NSUInteger bgEffectiveMaxTimers;
@property(nonatomic, readwrite) NSUInteger bgEffectiveMaxTsfnHandles;
@property(nonatomic, readwrite) NSUInteger bgEffectiveMaxPendingCalls;
@property(nonatomic, readwrite) NSUInteger bgEffectiveMaxNativeTasks;
@property(nonatomic, readwrite) NSUInteger bgEffectiveMaxScriptTasks;
@property(nonatomic, readwrite) NSUInteger bgEffectiveMaxPendingBytes;
@end
@implementation JSBayResourceGlobalUsage
@end

@interface JSBayInstanceSnapshot ()
@property(nonatomic, readwrite) int32_t instanceId;
@property(nonatomic, readwrite) uint64_t generation;
@property(nonatomic, readwrite) uint64_t ownerThreadId;
@property(nonatomic, readwrite) uint8_t loopMode;
@property(nonatomic, readwrite) uint8_t flags;
@property(nonatomic, readwrite) JSBayAdmissionClass admissionClass;
@property(nonatomic, readwrite) NSUInteger timersReserved;
@property(nonatomic, readwrite) NSUInteger timersRegistered;
@property(nonatomic, readwrite) NSUInteger scriptTasksQueued;
@property(nonatomic, readwrite) NSUInteger nativeTasksQueued;
@property(nonatomic, readwrite) NSUInteger pendingBytes;
@property(nonatomic, readwrite) NSUInteger maxTimers;
@property(nonatomic, readwrite) NSUInteger maxPendingTasks;
@property(nonatomic, readwrite) NSUInteger maxPendingBytes;
@end
@implementation JSBayInstanceSnapshot
@end

@implementation JSBayEngine
@synthesize identifier = _identifier, owner = _owner, open = _open, scopes = _scopes,
            allowMainRunLoopAttach = _allowMainRunLoopAttach, loopUserData = _loopUserData,
            loopRestoreFailure = _loopRestoreFailure;
- (jsbay_status_t)restoreAutomaticLoop {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return JSBAY_INSTANCE_NOT_FOUND;
    }
    JSBayLoopBinding *binding = [[JSBayLoopBinding alloc] initWithRunLoop:CFRunLoopGetCurrent()
                                                               identifier:_identifier];
    void *user = (void *)CFBridgingRetain(binding);
    jsbay_status_t status =
        jsbay_engine_attach_loop(_identifier, JSBayLoopSchedule, JSBayLoopCancel, user);
    if (status != JSBAY_OK) {
        CFBridgingRelease(user);
        [lock unlock];
        return status;
    }
    if (_loopUserData) {
        [(__bridge JSBayLoopBinding *)_loopUserData shutdown];
        CFBridgingRelease(_loopUserData);
    }
    _loopUserData = user;
    _loopRestoreFailure = JSBAY_OK;
    [lock unlock];
    return JSBAY_OK;
}
- (instancetype)initWithIdentifier:(int32_t)identifier error:(NSError **)error {
    return [self initWithIdentifier:identifier limits:nil allowMainRunLoopAttach:NO error:error];
}
- (instancetype)initWithIdentifier:(int32_t)identifier
                            limits:(JSBayResourceLimits *)limits
                             error:(NSError **)error {
    return [self initWithIdentifier:identifier limits:limits allowMainRunLoopAttach:NO error:error];
}
- (instancetype)initWithIdentifier:(int32_t)identifier
            allowMainRunLoopAttach:(BOOL)allowMainRunLoopAttach
                             error:(NSError **)error {
    return [self initWithIdentifier:identifier
                             limits:nil
             allowMainRunLoopAttach:allowMainRunLoopAttach
                              error:error];
}
- (instancetype)initWithIdentifier:(int32_t)identifier
                            limits:(JSBayResourceLimits *)limits
            allowMainRunLoopAttach:(BOOL)allowMainRunLoopAttach
                             error:(NSError **)error {
    if (!(self = [super init]))
        return nil;
    _identifier = identifier;
    _owner = pthread_self();
    _allowMainRunLoopAttach = allowMainRunLoopAttach;
    _scopes = [NSMutableArray array];
    if (CFEqual(CFRunLoopGetCurrent(), CFRunLoopGetMain()) && !allowMainRunLoopAttach) {
        if (error)
            *error = JSBayStatusError(JSBAY_INVALID_ARGUMENT);
        return nil;
    }
    bool created = false;
    if (limits) {
        jsbay_resource_limits_t c_limits = [limits cLimits];
        created = jsbay_engine_create_with_limits(identifier, NULL, NULL, &c_limits);
    } else {
        created = jsbay_engine_create(identifier, NULL, NULL);
    }
    if (!created) {
        if (error)
            *error = JSBayStatusError(JSBAY_INVALID_ARGUMENT);
        return nil;
    }
    JSBayLoopBinding *binding = [[JSBayLoopBinding alloc] initWithRunLoop:CFRunLoopGetCurrent()
                                                               identifier:identifier];
    void *user = (void *)CFBridgingRetain(binding);
    jsbay_status_t attached =
        jsbay_engine_attach_loop(identifier, JSBayLoopSchedule, JSBayLoopCancel, user);
    if (attached != JSBAY_OK) {
        CFBridgingRelease(user);
        jsbay_engine_destroy(identifier);
        if (error)
            *error = JSBayStatusError(attached);
        return nil;
    }
    _loopUserData = user;
    _open = YES;
    return self;
}
- (BOOL)requireOpen:(NSError **)error {
    if (!_open) {
        if (error)
            *error = JSBayStatusError(JSBAY_INSTANCE_NOT_FOUND);
        return NO;
    }
    if (!pthread_equal(_owner, pthread_self())) {
        if (error)
            *error = JSBayStatusError(JSBAY_WRONG_THREAD);
        return NO;
    }
    jsbay_status_t status = jsbay_engine_loop_status(_identifier);
    if (_loopRestoreFailure != JSBAY_OK)
        status = _loopRestoreFailure;
    if (status != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(status);
        return NO;
    }
    return YES;
}
- (BOOL)requireSame:(JSBayValue *)value error:(NSError **)error {
    if (value.engine != self || ![value usable:error]) {
        if (error && !*error)
            *error = JSBayStatusError(JSBAY_STALE_VALUE);
        return NO;
    }
    return YES;
}
- (BOOL)close:(NSError **)error {
    if (!self.open)
        return YES;
    if (!pthread_equal(_owner, pthread_self())) {
        if (error)
            *error = JSBayStatusError(JSBAY_WRONG_THREAD);
        return NO;
    }
    jsbay_status_t status = jsbay_engine_detach_loop(_identifier);
    if (status != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(status);
        return NO;
    }
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return YES;
    }
    if (_loopUserData) {
        [(__bridge JSBayLoopBinding *)_loopUserData shutdown];
        CFBridgingRelease(_loopUserData);
        _loopUserData = NULL;
    }
    self.open = NO;
    [lock unlock];
    jsbay_engine_destroy(_identifier);
    return YES;
}
- (JSBayValue *)ownedValue:(uint64_t)handle {
    JSBayValue *value = [[JSBayValue alloc] initWithEngine:self handle:handle borrowed:NO];
    [_scopes.lastObject trackOwned:value];
    return value;
}
- (JSBayValue *)valueResult:(jsbay_status_t)status
                      value:(uint64_t)value
                  exception:(uint64_t)exception
                      error:(NSError **)error {
    if (status == JSBAY_OK && value && !exception)
        return [self ownedValue:value];
    if (status == JSBAY_EXCEPTION && exception && !value) {
        if (error)
            *error =
                [NSError errorWithDomain:JSBayErrorDomain
                                    code:status
                                userInfo:@{JSBayExceptionValueKey : [self ownedValue:exception]}];
        return nil;
    }
    if (error)
        *error = JSBayStatusError(status);
    return nil;
}
- (BOOL)voidResult:(jsbay_status_t)status exception:(uint64_t)exception error:(NSError **)error {
    if (status == JSBAY_OK && !exception)
        return YES;
    if (status == JSBAY_EXCEPTION && exception) {
        if (error)
            *error =
                [NSError errorWithDomain:JSBayErrorDomain
                                    code:status
                                userInfo:@{JSBayExceptionValueKey : [self ownedValue:exception]}];
        return NO;
    }
    if (error)
        *error = JSBayStatusError(status);
    return NO;
}
- (JSBayValue *)simple:(jsbay_status_t (*)(int, uint64_t *))function error:(NSError **)error {
    if (![self requireOpen:error])
        return nil;
    uint64_t value = 0;
    jsbay_status_t s = function(_identifier, &value);
    if (s != JSBAY_OK || !value) {
        if (error)
            *error = JSBayStatusError(s);
        return nil;
    }
    return [self ownedValue:value];
}
- (JSBayValue *)evaluate:(NSString *)source
                filename:(NSString *)filename
                   cache:(JSBayCacheOptions *)cache
                   error:(NSError **)error {
    if (![self requireOpen:error])
        return nil;
    NSData *sourceData, *filenameData, *directoryData, *versionData;
    jsbay_utf8_t sourceUTF8, filenameUTF8, directoryUTF8, versionUTF8;
    if (!JSBayUTF8(source, &sourceData, &sourceUTF8, error) ||
        !JSBayUTF8(filename, &filenameData, &filenameUTF8, error))
        return nil;
    uint64_t value = 0, exception = 0;
    BOOL hit = NO;
    jsbay_engine_evaluate_options_t options, *optionPtr = NULL;
    if (cache) {
        cache.didHit = NO;
        if (!JSBayUTF8(cache.directory, &directoryData, &directoryUTF8, error) ||
            !JSBayUTF8(cache.version, &versionData, &versionUTF8, error))
            return nil;
        options =
            (jsbay_engine_evaluate_options_t){sizeof(options), directoryUTF8, versionUTF8, &hit};
        optionPtr = &options;
    }
    jsbay_status_t status =
        jsbay_engine_evaluate(_identifier, sourceUTF8, filenameUTF8, optionPtr, &value, &exception);
    if (cache)
        cache.didHit = hit;
    return [self valueResult:status value:value exception:exception error:error];
}
- (JSBayValue *)globalValue:(NSError **)error {
    return [self simple:jsbay_engine_global error:error];
}
- (JSBayValue *)undefinedValue:(NSError **)error {
    return [self simple:jsbay_value_undefined error:error];
}
- (JSBayValue *)nullValue:(NSError **)error {
    return [self simple:jsbay_value_null error:error];
}
- (JSBayValue *)objectValue:(NSError **)error {
    return [self simple:jsbay_value_new_object error:error];
}
- (JSBayValue *)arrayValue:(NSError **)error {
    return [self simple:jsbay_value_new_array error:error];
}
- (JSBayValue *)boolValue:(BOOL)x error:(NSError **)e {
    if (![self requireOpen:e])
        return nil;
    uint64_t v = 0;
    jsbay_status_t s = jsbay_value_new_bool(_identifier, x, &v);
    if (s == JSBAY_OK)
        return [self ownedValue:v];
    if (e)
        *e = JSBayStatusError(s);
    return nil;
}
- (JSBayValue *)numberValue:(double)x error:(NSError **)e {
    if (![self requireOpen:e])
        return nil;
    uint64_t v = 0;
    jsbay_status_t s = jsbay_value_new_number(_identifier, x, &v);
    if (s == JSBAY_OK)
        return [self ownedValue:v];
    if (e)
        *e = JSBayStatusError(s);
    return nil;
}
- (JSBayValue *)stringValue:(NSString *)x error:(NSError **)e {
    return [self stringLike:x function:jsbay_value_new_string error:e];
}
- (JSBayValue *)errorValue:(NSString *)x error:(NSError **)e {
    return [self stringLike:x function:jsbay_value_new_error error:e];
}
- (JSBayValue *)stringLike:(NSString *)x
                  function:(jsbay_status_t (*)(int, jsbay_utf8_t, uint64_t *))fn
                     error:(NSError **)e {
    if (![self requireOpen:e])
        return nil;
    NSData *d;
    jsbay_utf8_t text;
    if (!JSBayUTF8(x, &d, &text, e))
        return nil;
    uint64_t v = 0;
    jsbay_status_t s = fn(_identifier, text, &v);
    if (s == JSBAY_OK)
        return [self ownedValue:v];
    if (e)
        *e = JSBayStatusError(s);
    return nil;
}
- (JSBayValue *)arrayBufferValue:(NSData *)input error:(NSError **)error {
    if (![self requireOpen:error])
        return nil;
    uint64_t value = 0;
    jsbay_status_t status =
        jsbay_value_new_array_buffer(_identifier, input.bytes, input.length, &value);
    if (status == JSBAY_OK)
        return [self ownedValue:value];
    if (error)
        *error = JSBayStatusError(status);
    return nil;
}
- (JSBayValue *)jsonValue:(NSString *)x error:(NSError **)e {
    if (![self requireOpen:e])
        return nil;
    NSData *d;
    jsbay_utf8_t text;
    if (!JSBayUTF8(x, &d, &text, e))
        return nil;
    uint64_t v = 0, ex = 0;
    return [self valueResult:jsbay_value_new_json(_identifier, text, &v, &ex)
                       value:v
                   exception:ex
                       error:e];
}
- (JSBayValue *)bind:(NSString *)name
            callback:(JSBayNativeCallback)callback
               error:(NSError **)error {
    if (![self requireOpen:error])
        return nil;
    NSData *d;
    jsbay_utf8_t text;
    if (!JSBayUTF8(name, &d, &text, error))
        return nil;
    JSBayBinding *b = [JSBayBinding new];
    b.engine = self;
    b.callback = callback;
    void *user = (void *)CFBridgingRetain(b);
    uint64_t f = 0, ex = 0;
    jsbay_status_t s =
        jsbay_engine_bind(_identifier, text, JSBayHostCallback, user, JSBayHostFinalize, &f, &ex);
    if (s != JSBAY_OK) {
        CFBridgingRelease(user);
        return [self valueResult:s value:f exception:ex error:error];
    }
    return [self ownedValue:f];
}
- (JSBayValue *)bindSync:(NSString *)name
     timeoutMilliseconds:(uint64_t)timeoutMilliseconds
                 starter:(JSBaySyncStarter)starter
                   error:(NSError **)error {
    if (![self requireOpen:error])
        return nil;
    if (!timeoutMilliseconds) {
        if (error)
            *error = JSBayStatusError(JSBAY_INVALID_ARGUMENT);
        return nil;
    }
    NSData *d;
    jsbay_utf8_t text;
    if (!JSBayUTF8(name, &d, &text, error))
        return nil;
    JSBaySyncBinding *b = [JSBaySyncBinding new];
    b.engine = self;
    b.starter = starter;
    void *user = (void *)CFBridgingRetain(b);
    uint64_t f = 0, ex = 0;
    jsbay_status_t s = jsbay_engine_bind_sync(_identifier, text, JSBaySyncStart, user,
                                              JSBayHostFinalize, timeoutMilliseconds, &f, &ex);
    if (s != JSBAY_OK) {
        CFBridgingRelease(user);
        return [self valueResult:s value:f exception:ex error:error];
    }
    return [self ownedValue:f];
}
- (BOOL)runLoop:(NSError **)error {
    if (![self requireOpen:error])
        return NO;
    if (pthread_main_np() && !_allowMainRunLoopAttach) {
        if (error)
            *error = JSBayStatusError(JSBAY_INVALID_ARGUMENT);
        return NO;
    }
    jsbay_status_t detached = jsbay_engine_detach_loop(_identifier);
    if (detached != JSBAY_OK) {
        if (error)
            *error = JSBayStatusError(detached);
        return NO;
    }
    jsbay_status_t status = jsbay_engine_run_loop(_identifier);
    if (status != JSBAY_OK) {
        jsbay_status_t restored = [self restoreAutomaticLoop];
        if (restored != JSBAY_OK && self.open)
            _loopRestoreFailure = restored;
        if (error)
            *error = JSBayStatusError(status);
        return NO;
    }
    if (!self.open)
        return YES;
    status = [self restoreAutomaticLoop];
    if (status != JSBAY_OK) {
        _loopRestoreFailure = status;
        if (error)
            *error = JSBayStatusError(status);
        return NO;
    }
    return YES;
}
- (BOOL)stopLoop {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return NO;
    }
    BOOL result = jsbay_engine_stop_loop(_identifier);
    [lock unlock];
    return result;
}
- (BOOL)suspendLoop {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return NO;
    }
    BOOL result = jsbay_engine_suspend(_identifier);
    [lock unlock];
    return result;
}
- (BOOL)resumeLoop {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return NO;
    }
    BOOL result = jsbay_engine_resume(_identifier);
    [lock unlock];
    return result;
}
- (BOOL)isSuspended {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return NO;
    }
    BOOL result = jsbay_engine_is_suspended(_identifier);
    [lock unlock];
    return result;
}
- (BOOL)setAdmissionClass:(JSBayAdmissionClass)admissionClass {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return NO;
    }
    BOOL result =
        jsbay_engine_set_admission_class(_identifier, (jsbay_admission_class_t)admissionClass);
    [lock unlock];
    return result;
}
- (JSBayAdmissionClass)admissionClass {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return JSBayAdmissionClassForeground;
    }
    jsbay_admission_class_t cls = JSBAY_ADMISSION_FOREGROUND;
    (void)jsbay_engine_get_admission_class(_identifier, &cls);
    [lock unlock];
    return (JSBayAdmissionClass)cls;
}

+ (NSArray<NSNumber *> *)listEngines {
    size_t need = jsbay_engine_list(NULL, 0);
    if (need == 0)
        return @[];
    int *buf = (int *)malloc(need * sizeof(int));
    if (!buf)
        return @[];
    size_t n = jsbay_engine_list(buf, need);
    if (n > need) {
        free(buf);
        need = n;
        buf = (int *)malloc(need * sizeof(int));
        if (!buf)
            return @[];
        n = jsbay_engine_list(buf, need);
    }
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:n];
    for (size_t i = 0; i < n && i < need; i++)
        [out addObject:@(buf[i])];
    free(buf);
    return out;
}
+ (JSBayInstanceSnapshot *)snapshotForIdentifier:(int32_t)identifier {
    jsbay_instance_snapshot_t snap = {.struct_size = sizeof(snap)};
    if (!jsbay_engine_snapshot(identifier, &snap))
        return nil;
    JSBayInstanceSnapshot *out = [JSBayInstanceSnapshot new];
    out.instanceId = snap.instance_id;
    out.generation = snap.generation;
    out.ownerThreadId = snap.owner_thread_id;
    out.loopMode = snap.loop_mode;
    out.flags = snap.flags;
    out.admissionClass = (JSBayAdmissionClass)snap.admission_class;
    out.timersReserved = snap.timers_reserved;
    out.timersRegistered = snap.timers_registered;
    out.scriptTasksQueued = snap.script_tasks_queued;
    out.nativeTasksQueued = snap.native_tasks_queued;
    out.pendingBytes = snap.pending_bytes;
    out.maxTimers = snap.max_timers;
    out.maxPendingTasks = snap.max_pending_tasks;
    out.maxPendingBytes = snap.max_pending_bytes;
    return out;
}
- (JSBayInstanceSnapshot *)snapshot {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return nil;
    }
    int32_t id = _identifier;
    [lock unlock];
    return [JSBayEngine snapshotForIdentifier:id];
}
- (BOOL)requestInterrupt {
    NSLock *lock = JSBayEngineStateLock();
    [lock lock];
    if (!self.open) {
        [lock unlock];
        return NO;
    }
    BOOL result = jsbay_engine_request_interrupt(_identifier);
    [lock unlock];
    return result;
}
- (BOOL)clearInterrupt:(NSError **)e {
    if (![self requireOpen:e])
        return NO;
    return jsbay_engine_clear_interrupt(_identifier);
}
- (BOOL)setExecutionTimeLimitMilliseconds:(uint64_t)x error:(NSError **)e {
    if (![self requireOpen:e])
        return NO;
    return jsbay_engine_set_execution_time_limit(_identifier, x);
}
- (BOOL)setMemoryLimitBytes:(uint64_t)x error:(NSError **)e {
    if (![self requireOpen:e])
        return NO;
    return jsbay_engine_set_memory_limit(_identifier, x);
}
- (BOOL)setResourceLimits:(JSBayResourceLimits *)limits error:(NSError **)e {
    if (![self requireOpen:e])
        return NO;
    if (!limits) {
        if (e)
            *e = JSBayStatusError(JSBAY_INVALID_ARGUMENT);
        return NO;
    }
    jsbay_resource_limits_t c_limits = [limits cLimits];
    return jsbay_engine_set_resource_limits(_identifier, &c_limits);
}
- (JSBayResourceUsage *)resourceUsage:(NSError **)e {
    if (![self requireOpen:e])
        return nil;
    jsbay_resource_usage_t usage = {.struct_size = sizeof(usage)};
    if (!jsbay_engine_get_resource_usage(_identifier, &usage)) {
        if (e)
            *e = JSBayStatusError(JSBAY_INVALID_ARGUMENT);
        return nil;
    }
    JSBayResourceLimits *limits = [JSBayResourceLimits new];
    limits.maxTimers = usage.max_timers;
    limits.maxTsfnHandles = usage.max_tsfn_handles;
    limits.maxPendingCalls = usage.max_pending_calls;
    limits.maxPendingBytes = usage.max_pending_bytes;
    limits.maxPendingTasks = usage.max_pending_tasks;
    JSBayResourceUsage *out = [JSBayResourceUsage new];
    out.timers = usage.timers;
    out.tsfnHandles = usage.tsfn_handles;
    out.pendingCalls = usage.pending_calls;
    out.nativeTasks = usage.native_tasks;
    out.scriptTasks = usage.script_tasks;
    out.pendingBytes = usage.pending_bytes;
    out.limits = limits;
    return out;
}
+ (JSBayResourceGlobalUsage *)globalResourceUsage:(NSError **)e {
    jsbay_resource_global_usage_t usage = {.struct_size = sizeof(usage)};
    if (!jsbay_resource_global_usage(&usage)) {
        if (e)
            *e = JSBayStatusError(JSBAY_INVALID_ARGUMENT);
        return nil;
    }
    JSBayResourceGlobalUsage *out = [JSBayResourceGlobalUsage new];
    out.timers = usage.timers;
    out.tsfnHandles = usage.tsfn_handles;
    out.pendingCalls = usage.pending_calls;
    out.nativeTasks = usage.native_tasks;
    out.scriptTasks = usage.script_tasks;
    out.pendingBytes = usage.pending_bytes;
    out.maxTimers = usage.max_timers;
    out.maxTsfnHandles = usage.max_tsfn_handles;
    out.maxPendingCalls = usage.max_pending_calls;
    out.maxNativeTasks = usage.max_native_tasks;
    out.maxScriptTasks = usage.max_script_tasks;
    out.maxPendingBytes = usage.max_pending_bytes;
    out.fgHeadroomTimers = usage.fg_headroom_timers;
    out.fgHeadroomTsfnHandles = usage.fg_headroom_tsfn_handles;
    out.fgHeadroomPendingCalls = usage.fg_headroom_pending_calls;
    out.fgHeadroomNativeTasks = usage.fg_headroom_native_tasks;
    out.fgHeadroomScriptTasks = usage.fg_headroom_script_tasks;
    out.fgHeadroomPendingBytes = usage.fg_headroom_pending_bytes;
    out.bgEffectiveMaxTimers = usage.bg_effective_max_timers;
    out.bgEffectiveMaxTsfnHandles = usage.bg_effective_max_tsfn_handles;
    out.bgEffectiveMaxPendingCalls = usage.bg_effective_max_pending_calls;
    out.bgEffectiveMaxNativeTasks = usage.bg_effective_max_native_tasks;
    out.bgEffectiveMaxScriptTasks = usage.bg_effective_max_script_tasks;
    out.bgEffectiveMaxPendingBytes = usage.bg_effective_max_pending_bytes;
    return out;
}

- (NSDictionary<NSString *, NSNumber *> *)memoryUsage:(NSError **)e {
    if (![self requireOpen:e])
        return nil;
    jsbay_memory_usage_t u;
    memset(&u, 0, sizeof(u));
    u.struct_size = (uint32_t)sizeof(u);
    if (!jsbay_engine_get_memory_usage(_identifier, &u)) {
        if (e)
            *e = [NSError errorWithDomain:@"JSBay" code:JSBAY_INSTANCE_NOT_FOUND userInfo:nil];
        return nil;
    }
    return @{
        @"mallocCount" : @(u.malloc_count),
        @"mallocSize" : @(u.malloc_size),
        @"mallocLimit" : @(u.malloc_limit),
        @"memoryUsedCount" : @(u.memory_used_count),
        @"memoryUsedSize" : @(u.memory_used_size),
        @"atomCount" : @(u.atom_count),
        @"atomSize" : @(u.atom_size),
        @"objCount" : @(u.obj_count),
        @"objSize" : @(u.obj_size),
        @"shapeCount" : @(u.shape_count),
    };
}
- (BOOL)runGc:(NSError **)e {
    if (![self requireOpen:e])
        return NO;
    return jsbay_engine_run_gc(_identifier);
}
- (NSNumber *)startInspectorOnPort:(uint16_t)port error:(NSError **)error {
    if (![self requireOpen:error])
        return nil;
    uint16_t actual = 0;
    return jsbay_engine_inspector_start(_identifier, port, &actual) ? @(actual) : nil;
}
- (BOOL)stopInspector:(NSError **)error {
    if (![self requireOpen:error])
        return NO;
    jsbay_engine_inspector_stop(_identifier);
    return YES;
}
- (JSBayCallbackScope *)beginCallbackScope {
    JSBayCallbackScope *s = [JSBayCallbackScope new];
    [_scopes addObject:s];
    return s;
}
- (void)endCallbackScope:(JSBayCallbackScope *)scope {
    NSCAssert(_scopes.lastObject == scope, @"scope order");
    [_scopes removeLastObject];
    [scope close];
}
@end
