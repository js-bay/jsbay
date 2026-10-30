#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, JSBayAdmissionClass) {
    JSBayAdmissionClassForeground = 0,
    JSBayAdmissionClassBackground = 1,
};

FOUNDATION_EXPORT NSErrorDomain const JSBayErrorDomain;
FOUNDATION_EXPORT NSErrorUserInfoKey const JSBayExceptionValueKey;

/// Consumes the JavaScript Value in an exception NSError and returns its text. A second JavaScript throw returns @"JavaScript exception" after closing both values. Ownership, stale-value, and thread errors are returned through error.
FOUNDATION_EXPORT NSString *_Nullable JSBayDescribeAndCloseException(
    NSError *exception, NSError *_Nullable *_Nullable error);

typedef NS_ERROR_ENUM(JSBayErrorDomain, JSBayErrorCode){
    JSBayErrorOK = 0,          JSBayErrorException = 1,        JSBayErrorInvalidArgument = 2,
    JSBayErrorWrongThread = 3, JSBayErrorInstanceNotFound = 4, JSBayErrorStaleValue = 5,
    JSBayErrorOutOfMemory = 6, JSBayErrorUnsupported = 7,      JSBayErrorLoopFailed = 8,
};

typedef NS_ENUM(NSInteger, JSBayValueKind) {
    JSBayValueKindUndefined,
    JSBayValueKindNull,
    JSBayValueKindBool,
    JSBayValueKindNumber,
    JSBayValueKindString,
    JSBayValueKindObject,
    JSBayValueKindArray,
    JSBayValueKindFunction,
    JSBayValueKindSymbol,
    JSBayValueKindBigInt,
};

@class JSBayEngine;
@class JSBayValue;
@class JSBaySyncCompletion;

/// Runs on the Engine owner thread. Return a Value, or set error. To throw a JavaScript value, set an NSError whose userInfo has JSBayExceptionValueKey.
typedef JSBayValue *_Nullable (^JSBayNativeCallback)(JSBayValue *thisValue,
                                                     NSArray<JSBayValue *> *arguments,
                                                     NSError *_Nullable *_Nullable error);

/// Runs on the owner thread. Completion is data-only and may be used later on any thread; it must not be passed JSBayValue instances after this block returns.
typedef void (^JSBaySyncStarter)(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                 JSBaySyncCompletion *completion);

@interface JSBaySyncCompletion : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (JSBayErrorCode)tryResolveString:(NSString *)value;
- (JSBayErrorCode)tryResolveBytes:(NSData *)bytes;
- (JSBayErrorCode)tryReject:(NSString *)message;
- (BOOL)resolveString:(NSString *)value error:(NSError *_Nullable *_Nullable)error;
- (BOOL)resolveBytes:(NSData *)bytes error:(NSError *_Nullable *_Nullable)error;
- (BOOL)reject:(NSString *)message error:(NSError *_Nullable *_Nullable)error;
@end

@interface JSBayCacheOptions : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic, copy, readonly) NSString *directory;
@property(nonatomic, copy, readonly) NSString *version;
@property(nonatomic, readonly) BOOL didHit;
- (instancetype)initWithDirectory:(NSString *)directory version:(NSString *)version;
@end

@interface JSBayValue : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (BOOL)valueKind:(JSBayValueKind *)output error:(NSError *_Nullable *_Nullable)error;
- (BOOL)close:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)retainValue:(NSError *_Nullable *_Nullable)error;
- (BOOL)boolValue:(BOOL *)output error:(NSError *_Nullable *_Nullable)error;
- (BOOL)numberValue:(double *)output error:(NSError *_Nullable *_Nullable)error;
- (nullable NSString *)stringValue:(NSError *_Nullable *_Nullable)error;
- (nullable NSString *)jsonValue:(NSError *_Nullable *_Nullable)error;
- (nullable NSData *)dataValue:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)valueForKey:(NSString *)key error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setValue:(JSBayValue *)value
          forKey:(NSString *)key
           error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)callWithThis:(nullable JSBayValue *)thisValue
                            arguments:(NSArray<JSBayValue *> *)arguments
                                error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)constructWithArguments:(NSArray<JSBayValue *> *)arguments
                                          error:(NSError *_Nullable *_Nullable)error;
- (BOOL)hasKey:(NSString *)key result:(BOOL *)result error:(NSError *_Nullable *_Nullable)error;
- (BOOL)deleteKey:(NSString *)key result:(BOOL *)result error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)keysWithError:(NSError *_Nullable *_Nullable)error;
- (BOOL)instanceOfConstructor:(JSBayValue *)constructor
                       result:(BOOL *)result
                        error:(NSError *_Nullable *_Nullable)error;
@end

@interface JSBayResourceLimits : NSObject
@property(nonatomic) NSUInteger maxTimers;
@property(nonatomic) NSUInteger maxTsfnHandles;
@property(nonatomic) NSUInteger maxPendingCalls;
@property(nonatomic) NSUInteger maxPendingBytes;
@property(nonatomic) NSUInteger maxPendingTasks;
@end

@interface JSBayResourceUsage : NSObject
@property(nonatomic, readonly) NSUInteger timers;
@property(nonatomic, readonly) NSUInteger tsfnHandles;
@property(nonatomic, readonly) NSUInteger pendingCalls;
@property(nonatomic, readonly) NSUInteger nativeTasks;
@property(nonatomic, readonly) NSUInteger scriptTasks;
@property(nonatomic, readonly) NSUInteger pendingBytes;
@property(nonatomic, copy, readonly) JSBayResourceLimits *limits;
@end

@interface JSBayInstanceSnapshot : NSObject
@property(nonatomic, readonly) int32_t instanceId;
@property(nonatomic, readonly) uint64_t generation;
@property(nonatomic, readonly) uint64_t ownerThreadId;
@property(nonatomic, readonly) uint8_t loopMode;
@property(nonatomic, readonly) uint8_t flags;
@property(nonatomic, readonly) JSBayAdmissionClass admissionClass;
@property(nonatomic, readonly) NSUInteger timersReserved;
@property(nonatomic, readonly) NSUInteger timersRegistered;
@property(nonatomic, readonly) NSUInteger scriptTasksQueued;
@property(nonatomic, readonly) NSUInteger nativeTasksQueued;
@property(nonatomic, readonly) NSUInteger pendingBytes;
@property(nonatomic, readonly) NSUInteger maxTimers;
@property(nonatomic, readonly) NSUInteger maxPendingTasks;
@property(nonatomic, readonly) NSUInteger maxPendingBytes;
@end

@interface JSBayResourceGlobalUsage : NSObject
@property(nonatomic, readonly) NSUInteger timers;
@property(nonatomic, readonly) NSUInteger tsfnHandles;
@property(nonatomic, readonly) NSUInteger pendingCalls;
@property(nonatomic, readonly) NSUInteger nativeTasks;
@property(nonatomic, readonly) NSUInteger scriptTasks;
@property(nonatomic, readonly) NSUInteger pendingBytes;
@property(nonatomic, readonly) NSUInteger maxTimers;
@property(nonatomic, readonly) NSUInteger maxTsfnHandles;
@property(nonatomic, readonly) NSUInteger maxPendingCalls;
@property(nonatomic, readonly) NSUInteger maxNativeTasks;
@property(nonatomic, readonly) NSUInteger maxScriptTasks;
@property(nonatomic, readonly) NSUInteger maxPendingBytes;
@property(nonatomic, readonly) NSUInteger fgHeadroomTimers;
@property(nonatomic, readonly) NSUInteger fgHeadroomTsfnHandles;
@property(nonatomic, readonly) NSUInteger fgHeadroomPendingCalls;
@property(nonatomic, readonly) NSUInteger fgHeadroomNativeTasks;
@property(nonatomic, readonly) NSUInteger fgHeadroomScriptTasks;
@property(nonatomic, readonly) NSUInteger fgHeadroomPendingBytes;
@property(nonatomic, readonly) NSUInteger bgEffectiveMaxTimers;
@property(nonatomic, readonly) NSUInteger bgEffectiveMaxTsfnHandles;
@property(nonatomic, readonly) NSUInteger bgEffectiveMaxPendingCalls;
@property(nonatomic, readonly) NSUInteger bgEffectiveMaxNativeTasks;
@property(nonatomic, readonly) NSUInteger bgEffectiveMaxScriptTasks;
@property(nonatomic, readonly) NSUInteger bgEffectiveMaxPendingBytes;
@end

@interface JSBayEngine : NSObject
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(nonatomic, readonly) int32_t identifier;
- (nullable instancetype)initWithIdentifier:(int32_t)identifier
                                      error:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)initWithIdentifier:(int32_t)identifier
                                     limits:(nullable JSBayResourceLimits *)limits
                                      error:(NSError *_Nullable *_Nullable)error;
/// Same as initWithIdentifier:error:, and allows attaching the automatic driver to the process main run loop when allowMainRunLoopAttach is YES. Default init refuses that attach.
- (nullable instancetype)initWithIdentifier:(int32_t)identifier
                     allowMainRunLoopAttach:(BOOL)allowMainRunLoopAttach
                                      error:(NSError *_Nullable *_Nullable)error;
- (nullable instancetype)initWithIdentifier:(int32_t)identifier
                                     limits:(nullable JSBayResourceLimits *)limits
                     allowMainRunLoopAttach:(BOOL)allowMainRunLoopAttach
                                      error:(NSError *_Nullable *_Nullable)error;
- (BOOL)close:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)evaluate:(NSString *)source
                         filename:(NSString *)filename
                            cache:(nullable JSBayCacheOptions *)cache
                            error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)globalValue:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)undefinedValue:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)nullValue:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)boolValue:(BOOL)value error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)numberValue:(double)value error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)stringValue:(NSString *)value error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)arrayBufferValue:(NSData *)value
                                    error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)objectValue:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)arrayValue:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)jsonValue:(NSString *)value error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)errorValue:(NSString *)message error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)bind:(NSString *)name
                     callback:(JSBayNativeCallback)callback
                        error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayValue *)bindSync:(NSString *)name
              timeoutMilliseconds:(uint64_t)timeoutMilliseconds
                          starter:(JSBaySyncStarter)starter
                            error:(NSError *_Nullable *_Nullable)error;
/// Blocks the owner thread until stopLoop or a native callback stops the engine. The automatic CFRunLoop driver is restored when this returns while the engine remains open. Refuses the process main thread unless the engine was created with allowMainRunLoopAttach YES.
- (BOOL)runLoop:(NSError *_Nullable *_Nullable)error;
- (BOOL)stopLoop;
/// Keep-alive pause for multi-runtime Hide. Cancels pending schedules without detaching or clearing timers/VM state. May be called from any thread.
- (BOOL)suspendLoop;
/// Resume after suspendLoop. Does not recreate the engine. May be called from any thread.
- (BOOL)resumeLoop;
- (BOOL)isSuspended;
/// Future admissions only. Pair Hide→Background and Show→Foreground with suspend/resume.
- (BOOL)setAdmissionClass:(JSBayAdmissionClass)admissionClass;
- (JSBayAdmissionClass)admissionClass;
- (BOOL)requestInterrupt;
- (BOOL)clearInterrupt:(NSError *_Nullable *_Nullable)error;
- (BOOL)setExecutionTimeLimitMilliseconds:(uint64_t)milliseconds
                                    error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setMemoryLimitBytes:(uint64_t)bytes error:(NSError *_Nullable *_Nullable)error;
- (BOOL)setResourceLimits:(JSBayResourceLimits *)limits error:(NSError *_Nullable *_Nullable)error;
- (nullable JSBayResourceUsage *)resourceUsage:(NSError *_Nullable *_Nullable)error;
+ (nullable JSBayResourceGlobalUsage *)globalResourceUsage:(NSError *_Nullable *_Nullable)error;
/// Live non-teardown-pending instance ids (arbitrary order). Any thread.
+ (NSArray<NSNumber *> *)listEngines;
/// Any-thread snapshot by id; nil if missing or teardown-pending.
+ (nullable JSBayInstanceSnapshot *)snapshotForIdentifier:(int32_t)identifier;
/// Any-thread snapshot of this engine; nil if closed/tearing down.
- (nullable JSBayInstanceSnapshot *)snapshot;
/// Owner-thread allocator snapshot. Keys match the C field names (mallocCount, …).
- (nullable NSDictionary<NSString *, NSNumber *> *)memoryUsage:(NSError *_Nullable *_Nullable)error;
- (BOOL)runGc:(NSError *_Nullable *_Nullable)error;
- (nullable NSNumber *)startInspectorOnPort:(uint16_t)port
                                      error:(NSError *_Nullable *_Nullable)error;
- (BOOL)stopInspector:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
