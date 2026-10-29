#import "JSBayObjC.h"
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>

enum { kWarmup = 100, kIterations = 1000, kPayloadSize = 4096 };

static uint64_t Now(void) {
    return mach_continuous_time();
}
static uint64_t TicksToNanoseconds(uint64_t ticks) {
    mach_timebase_info_data_t info;
    mach_timebase_info(&info);
    return ticks * info.numer / info.denom;
}
static BOOL Number(JSBayEngine *engine, NSString *source, NSError **error) {
    JSBayValue *value = [engine evaluate:source filename:@"interop.js" cache:nil error:error];
    if (!value)
        return NO;
    double output = 0;
    BOOL ok = [value numberValue:&output error:error] && output == 42;
    NSError *closeError = nil;
    if (![value close:&closeError]) {
        if (error && !*error)
            *error = closeError;
        return NO;
    }
    return ok;
}
static uint64_t Measure(JSBayEngine *engine, NSString *source, NSError **error) {
    for (NSUInteger i = 0; i < kWarmup; ++i)
        if (!Number(engine, source, error))
            return 0;
    uint64_t start = Now();
    for (NSUInteger i = 0; i < kIterations; ++i)
        if (!Number(engine, source, error))
            return 0;
    return TicksToNanoseconds(Now() - start);
}
static void SetInvalidResult(NSError **error) {
    if (error && !*error)
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:1 userInfo:nil];
}
static BOOL TextJSON(JSBayEngine *engine, NSError **error) {
    JSBayValue *value = [engine evaluate:@"({text:'public interop',count:42})"
                                filename:@"text-json.js"
                                   cache:nil
                                   error:error];
    NSString *json = value ? [value jsonValue:error] : nil;
    NSError *closeError = nil;
    BOOL closed = value ? [value close:&closeError] : NO;
#if defined(JSBAY_INTEROP_FAULT_EMPTY_JSON)
    json = nil;
#endif
    if (!closed && error && !*error)
        *error = closeError;
    if (!json || ![json isEqualToString:@"{\"text\":\"public interop\",\"count\":42}"] || !closed) {
        SetInvalidResult(error);
        return NO;
    }
    return YES;
}
static BOOL BufferCopy(JSBayEngine *engine, NSData *input, NSError **error) {
    JSBayValue *value = [engine arrayBufferValue:input error:error];
    NSData *copy = value ? [value dataValue:error] : nil;
    NSError *closeError = nil;
    BOOL closed = value ? [value close:&closeError] : NO;
#if defined(JSBAY_INTEROP_FAULT_WRONG_BUFFER)
    copy = [NSData data];
#endif
    if (!closed && error && !*error)
        *error = closeError;
    if (!copy || ![copy isEqualToData:input] || !closed) {
        SetInvalidResult(error);
        return NO;
    }
    return YES;
}
static uint64_t MeasureTextJSON(JSBayEngine *engine, NSError **error) {
    for (NSUInteger i = 0; i < kWarmup; ++i)
        if (!TextJSON(engine, error))
            return 0;
    uint64_t start = Now();
    for (NSUInteger i = 0; i < kIterations; ++i)
        if (!TextJSON(engine, error))
            return 0;
    return TicksToNanoseconds(Now() - start);
}
static uint64_t MeasureBuffer(JSBayEngine *engine, NSData *input, NSError **error) {
    for (NSUInteger i = 0; i < kWarmup; ++i)
        if (!BufferCopy(engine, input, error))
            return 0;
    uint64_t start = Now();
    for (NSUInteger i = 0; i < kIterations; ++i)
        if (!BufferCopy(engine, input, error))
            return 0;
    return TicksToNanoseconds(Now() - start);
}
static uint64_t Lifecycle(NSError **error) {
    for (NSUInteger i = 0; i < kWarmup; ++i) {
        JSBayEngine *engine = [[JSBayEngine alloc] initWithIdentifier:(int32_t)(1600000 + i)
                                                                error:error];
        if (!engine || !Number(engine, @"42", error) || ![engine close:error])
            return 0;
    }
    uint64_t start = Now();
    for (NSUInteger i = 0; i < 100; ++i) {
        JSBayEngine *engine = [[JSBayEngine alloc] initWithIdentifier:(int32_t)(1600100 + i)
                                                                error:error];
        if (!engine || !Number(engine, @"42", error) || ![engine close:error])
            return 0;
    }
    return TicksToNanoseconds(Now() - start);
}
int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        JSBayEngine *engine = [[JSBayEngine alloc] initWithIdentifier:1500001 error:&error];
        JSBayValue *binding =
            [engine bind:@"benchCallback"
                callback:^JSBayValue *(JSBayValue *selfValue, NSArray<JSBayValue *> *arguments,
                                       NSError **callbackError) {
                    (void)selfValue;
                    (void)arguments;
                    return [engine numberValue:42 error:callbackError];
                }
                   error:&error];
        if (!engine || !binding)
            return 2;
        uint64_t eval =
            error ? 0 : Measure(engine, @"var n=0; for(var i=0;i<64;i++)n+=i; 42", &error);
        uint64_t callback = error ? 0 : Measure(engine, @"benchCallback()", &error);
        uint8_t payload[kPayloadSize];
        memset(payload, 7, sizeof(payload));
        NSData *input = [NSData dataWithBytes:payload length:sizeof(payload)];
        uint64_t text = error ? 0 : MeasureTextJSON(engine, &error);
        uint64_t buffer = error ? 0 : MeasureBuffer(engine, input, &error);
        [binding close:nil];
        [engine close:nil];
        uint64_t life = error ? 0 : Lifecycle(&error);
        if (error || !eval || !callback || !text || !buffer || !life) {
            NSLog(@"Objective-C interop benchmark failed: %@", error);
            return 2;
        }
        printf("%llu %llu %llu %llu %llu\n", eval, callback, text, buffer, life);
        return 0;
    }
}
