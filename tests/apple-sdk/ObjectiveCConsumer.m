#import "JSBayObjC.h"
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"%@", message);
        abort();
    }
}

int jsbay_objc_sdk_probe(void) {
    @autoreleasepool {
        NSError *error = nil;
        {
            NSError *refused = nil;
            JSBayEngine *mainDenied = [[JSBayEngine alloc] initWithIdentifier:81090 error:&refused];
            Check(mainDenied == nil && refused.code == JSBayErrorInvalidArgument,
                  @"main run loop attach must be refused without opt-in");
        }
        JSBayEngine *engine = [[JSBayEngine alloc] initWithIdentifier:81002
                                               allowMainRunLoopAttach:YES
                                                                error:&error];
        Check(engine != nil, error.localizedDescription);
        error = nil;
        JSBayEngine *duplicate = [[JSBayEngine alloc] initWithIdentifier:81002
                                                  allowMainRunLoopAttach:YES
                                                                   error:&error];
        Check(duplicate == nil && error.code == JSBayErrorInvalidArgument,
              @"duplicate engine ID must be invalid argument");
        error = nil;
        double duplicateNumber = 0;
        Check([[engine evaluate:@"40+2" filename:@"duplicate-id.js" cache:nil
                          error:&error] numberValue:&duplicateNumber error:&error] &&
                  duplicateNumber == 42,
              @"duplicate create disturbed the original engine");
        JSBayValue *sync =
            [engine bindSync:@"objcSync"
                timeoutMilliseconds:1000
                            starter:^(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                      JSBaySyncCompletion *completion) {
                                (void)thisValue;
                                (void)arguments;
                                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                                    NSError *completionError = nil;
                                    Check([completion resolveString:@"42" error:&completionError],
                                          completionError.localizedDescription);
                                });
                            }
                              error:&error];
        Check(sync != nil, error.localizedDescription);
        Check([[engine evaluate:@"Number(objcSync())" filename:@"sync.js" cache:nil
                          error:&error] numberValue:&duplicateNumber error:&error] &&
                  duplicateNumber == 42,
              @"sync completion mismatch");
        Check([engine bindSync:@"objcSyncThrow"
                  timeoutMilliseconds:1000
                              starter:^(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                        JSBaySyncCompletion *completion) {
                                  (void)thisValue;
                                  (void)arguments;
                                  (void)completion;
                                  @throw [NSException exceptionWithName:@"SyncThrow"
                                                                 reason:@"sync"
                                                               userInfo:nil];
                              }
                                error:&error] != nil,
              error.localizedDescription);
        error = nil;
        Check([engine evaluate:@"objcSyncThrow()"
                      filename:@"sync-throw.js"
                         cache:nil
                         error:&error] == nil &&
                  error.code == JSBayErrorException,
              @"sync callback throw must reject immediately");
        JSBayValue *syncException = error.userInfo[JSBayExceptionValueKey];
        error = nil;
        /* Typed sync rejects become Error objects (message property), not bare JSON strings. */
        Check([[[syncException valueForKey:@"message" error:&error] stringValue:&error]
                  isEqualToString:@"Objective-C sync callback threw"] &&
                  error == nil,
              @"sync callback throw message mismatch");
        Check([[engine evaluate:@"40+2" filename:@"sync-throw-recovery.js" cache:nil
                          error:&error] numberValue:&duplicateNumber error:&error] &&
                  duplicateNumber == 42,
              @"sync callback throw damaged engine");
        const unichar loneSurrogateCodeUnit[] = {0xD800};
        NSString *invalidUnicode = [NSString stringWithCharacters:loneSurrogateCodeUnit length:1];
        error = nil;
        Check([engine evaluate:invalidUnicode
                      filename:@"invalid-input.js"
                         cache:nil
                         error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"unpaired UTF-16 input must be rejected before evaluation");

        JSBayValue *object = [engine evaluate:@"({ value: 40, add(a,b) { return a + b } })"
                                     filename:@"objc.js"
                                        cache:nil
                                        error:&error];
        Check(object != nil, error.localizedDescription);
        error = nil;
        Check([engine evaluate:@"1" filename:invalidUnicode cache:nil error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid filename must be rejected");
        JSBayCacheOptions *invalidDirectory =
            [[JSBayCacheOptions alloc] initWithDirectory:invalidUnicode version:@"v1"];
        error = nil;
        Check([engine evaluate:@"1"
                      filename:@"cache-input.js"
                         cache:invalidDirectory
                         error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid cache directory must be rejected");
        JSBayCacheOptions *invalidVersion =
            [[JSBayCacheOptions alloc] initWithDirectory:NSTemporaryDirectory()
                                                 version:invalidUnicode];
        error = nil;
        Check([engine evaluate:@"1" filename:@"cache-input.js" cache:invalidVersion
                         error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid cache version must be rejected");
        error = nil;
        Check([engine stringValue:invalidUnicode error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid string input must be rejected");
        error = nil;
        Check([engine errorValue:invalidUnicode error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid error text must be rejected");
        error = nil;
        Check([engine jsonValue:invalidUnicode error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid JSON input must be rejected");
        error = nil;
        Check([engine bind:invalidUnicode
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      return [engine undefinedValue:callbackError];
                  }
                     error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid bind name must be rejected");
        error = nil;
        Check([object valueForKey:invalidUnicode error:&error] == nil &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid property key must be rejected");
        JSBayValue *validPropertyValue = [engine numberValue:1 error:&error];
        error = nil;
        Check(![object setValue:validPropertyValue forKey:invalidUnicode error:&error] &&
                  error.code == JSBayErrorInvalidArgument,
              @"invalid property key must be rejected on set");
        JSBayValue *nul = [engine stringValue:@"hi\0😀" error:&error];
        Check([[nul stringValue:&error] isEqualToString:@"hi\0😀"], @"UTF-8/NUL mismatch");
        error = nil;
        JSBayValue *loneSurrogate = [engine evaluate:@"'\\ud800'"
                                            filename:@"surrogate.js"
                                               cache:nil
                                               error:&error];
        Check(loneSurrogate != nil, error.localizedDescription);
        Check([[loneSurrogate stringValue:&error] isEqualToString:@"\uFFFD"] && error == nil,
              @"unpaired surrogate must become U+FFFD");
        uint8_t inputBytes[] = {0, 1, 255, 0};
        NSMutableData *input = [NSMutableData dataWithBytes:inputBytes length:sizeof(inputBytes)];
        JSBayValue *buffer = [engine arrayBufferValue:input error:&error];
        ((uint8_t *)input.mutableBytes)[1] = 99;
        NSData *expectedBytes = [NSData dataWithBytes:inputBytes length:sizeof(inputBytes)];
        Check([[buffer dataValue:&error] isEqualToData:expectedBytes], @"binary copy-in isolation");
        NSMutableData *output = [[buffer dataValue:&error] mutableCopy];
        ((uint8_t *)output.mutableBytes)[1] = 88;
        Check([[buffer dataValue:&error] isEqualToData:expectedBytes],
              @"binary copy-out isolation");
        Check([[[engine arrayBufferValue:[NSData data] error:&error] dataValue:&error] length] == 0,
              @"empty buffer mismatch");
        JSBayValue *view = [engine evaluate:@"new Uint8Array([8,9,0,255,7]).subarray(2,4)"
                                   filename:@"view.js"
                                      cache:nil
                                      error:&error];
        uint8_t visibleBytes[] = {0, 255};
        Check([[view dataValue:&error] isEqualToData:[NSData dataWithBytes:visibleBytes length:2]],
              @"typed view window mismatch");
        JSBayCacheOptions *cache =
            [[JSBayCacheOptions alloc] initWithDirectory:NSTemporaryDirectory()
                                                 version:NSUUID.UUID.UUIDString];
        NSString *cachedSource = @"globalThis.__ocCache=(globalThis.__ocCache||0)+1;__ocCache";
        double cacheNumber = 0;
        JSBayValue *cold = [engine evaluate:cachedSource
                                   filename:@"oc-cache.js"
                                      cache:cache
                                      error:&error];
        Check([cold numberValue:&cacheNumber error:&error] && cacheNumber == 1 && !cache.didHit,
              @"cold cache mismatch");
        JSBayValue *warm = [engine evaluate:cachedSource
                                   filename:@"oc-cache.js"
                                      cache:cache
                                      error:&error];
#ifdef JSBAY_NO_BYTECODE_CACHE
        BOOL expectedHit = NO;
#else
        BOOL expectedHit = YES;
#endif
        Check([warm numberValue:&cacheNumber error:&error] && cacheNumber == 2 &&
                  cache.didHit == expectedHit,
              @"warm cache or single execution mismatch");
        JSBayValue *add = [object valueForKey:@"add" error:&error];
        JSBayValue *one = [engine numberValue:1 error:&error];
        JSBayValue *two = [engine numberValue:1 error:&error];
        JSBayValue *sum = [add callWithThis:object arguments:@[ one, two ] error:&error];
        double number = 0;
        Check([sum numberValue:&number error:&error] && number == 2,
              @"live function value mismatch");
        JSBayValueKind kind = JSBayValueKindUndefined;
        Check([sum valueKind:&kind error:&error] && kind == JSBayValueKindNumber,
              @"value kind mismatch");
        JSBayValue *symbolValue = [engine evaluate:@"Symbol('kind')"
                                          filename:@"symbol-kind.js"
                                             cache:nil
                                             error:&error];
        Check(symbolValue != nil && [symbolValue valueKind:&kind error:&error] &&
                  kind == JSBayValueKindSymbol,
              @"symbol kind mismatch");
        JSBayValue *bigIntValue = [engine evaluate:@"1n"
                                          filename:@"bigint-kind.js"
                                             cache:nil
                                             error:&error];
        Check(bigIntValue != nil && [bigIntValue valueKind:&kind error:&error] &&
                  kind == JSBayValueKindBigInt,
              @"bigint kind mismatch");

        __block JSBayValue *borrowed = nil;
        __block JSBayValue *escaped = nil;
        Check([engine bind:@"capture"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      borrowed = arguments[0];
                      NSError *borrowedCloseError = nil;
                      Check(![borrowed close:&borrowedCloseError] &&
                                borrowedCloseError.code == JSBayErrorInvalidArgument,
                            @"borrowed callback value close must be rejected");
                      NSError *borrowedThrow =
                          [NSError errorWithDomain:JSBayErrorDomain
                                              code:JSBayErrorException
                                          userInfo:@{JSBayExceptionValueKey : borrowed}];
                      NSError *borrowedDescribeError = nil;
                      Check(JSBayDescribeAndCloseException(borrowedThrow, &borrowedDescribeError) ==
                                    nil &&
                                borrowedDescribeError.code == JSBayErrorInvalidArgument,
                            @"borrowed exception text must be rejected before conversion");
                      escaped = [borrowed retainValue:callbackError];
                      return [engine undefinedValue:callbackError];
                  }
                     error:&error] != nil,
              error.localizedDescription);
        Check([engine evaluate:@"capture(9)" filename:@"capture.js" cache:nil error:&error] != nil,
              error.localizedDescription);
        Check(![borrowed numberValue:&number error:&error], @"borrowed value escaped callback");
        error = nil;
        Check(![borrowed close:&error] && error.code == JSBayErrorStaleValue,
              @"expired borrowed value close must be stale");
        error = nil;
        Check([escaped numberValue:&number error:&error] && number == 9,
              @"retained callback value did not escape");

        Check([engine bind:@"nativeObject"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      JSBayValue *result = [engine objectValue:callbackError];
                      JSBayValue *yes = [engine boolValue:YES error:callbackError];
                      if (![result setValue:yes forKey:@"ok" error:callbackError])
                          return nil;
                      return result;
                  }
                     error:&error] != nil,
              error.localizedDescription);
        JSBayValue *native = [engine evaluate:@"nativeObject()"
                                     filename:@"native.js"
                                        cache:nil
                                        error:&error];
        BOOL boolValue = NO;
        Check([[native valueForKey:@"ok" error:&error] boolValue:&boolValue error:&error] &&
                  boolValue,
              @"native object mismatch");

        Check([engine bind:@"throwSeven"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      JSBayValue *seven = [engine numberValue:7 error:callbackError];
                      if (!seven)
                          return nil;
                      if (callbackError)
                          *callbackError =
                              [NSError errorWithDomain:JSBayErrorDomain
                                                  code:0
                                              userInfo:@{JSBayExceptionValueKey : seven}];
                      return nil;
                  }
                     error:&error] != nil,
              error.localizedDescription);
        Check([engine evaluate:@"throwSeven()" filename:@"throw.js" cache:nil error:&error] == nil,
              @"expected JS exception");
        JSBayValue *exception = error.userInfo[JSBayExceptionValueKey];
        error = nil;
        Check([exception numberValue:&number error:&error] && number == 7, @"throw value changed");

        Check([engine bind:@"objcThrow"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      (void)callbackError;
                      @throw [NSException exceptionWithName:@"ObjCConsumerThrow"
                                                     reason:@"objc callback exception"
                                                   userInfo:nil];
                  }
                     error:&error] != nil,
              error.localizedDescription);
        error = nil;
        Check([engine evaluate:@"objcThrow()" filename:@"objc-throw.js" cache:nil
                         error:&error] == nil &&
                  error.code == JSBayErrorException,
              @"Objective-C callback throw must become a JavaScript exception");
        Check(error.userInfo[JSBayExceptionValueKey] != nil,
              @"Objective-C callback throw must carry a JavaScript exception value");
        error = nil;
        JSBayValue *afterObjCThrow = [engine evaluate:@"40+2"
                                             filename:@"objc-throw-recovery.js"
                                                cache:nil
                                                error:&error];
        Check([afterObjCThrow numberValue:&number error:&error] && number == 42,
              @"engine did not recover after Objective-C callback throw");

        // Object operations: construct, has, delete, keys, instanceOf.
        JSBayValue * (^evaluate)(NSString *) = ^JSBayValue *(NSString *source) {
            NSError *evaluateError = nil;
            JSBayValue *value = [engine evaluate:source
                                        filename:@"object-operations.js"
                                           cache:nil
                                           error:&evaluateError];
            Check(value != nil, evaluateError.localizedDescription);
            return value;
        };
        // The exception value of a failed call, or nil when the call did not fail with one.
        JSBayValue * (^thrownValue)(NSError *) = ^JSBayValue *(NSError *failure) {
            return failure.code == JSBayErrorException ? failure.userInfo[JSBayExceptionValueKey]
                                                       : nil;
        };
        JSBayValue * (^thrownMessage)(NSError *) = ^JSBayValue *(NSError *failure) {
            return [thrownValue(failure) valueForKey:@"message" error:nil];
        };
        BOOL (^isTypeError)(NSError *) = ^BOOL(NSError *failure) {
            NSString *name = [[thrownValue(failure) valueForKey:@"name" error:nil] stringValue:nil];
            return [name isEqualToString:@"TypeError"];
        };
        BOOL flag = NO;
        JSBayValue *point = evaluate(@"(function P(x) { this.x = x })");
        JSBayValue *numberFortyTwo = [engine numberValue:42 error:&error];
        error = nil;
        JSBayValue *constructed = [point constructWithArguments:@[ numberFortyTwo ] error:&error];
        Check(constructed != nil && error == nil &&
                  [[constructed valueForKey:@"x" error:&error] numberValue:&number error:&error] &&
                  number == 42 &&
                  [constructed instanceOfConstructor:point result:&flag error:&error] && flag,
              @"construct did not run the constructor");
        Check([[[evaluate(@"(function Q() { this.n = arguments.length })")
                  constructWithArguments:@[]
                                   error:&error] valueForKey:@"n"
                                                       error:&error] numberValue:&number
                                                                           error:&error] &&
                  number == 0,
              @"construct default arguments mismatch");
        error = nil;
        Check([evaluate(@"(function B() { throw new Error('ctor boom') })")
                  constructWithArguments:@[]
                                   error:&error] == nil &&
                  [[thrownMessage(error) stringValue:nil] isEqualToString:@"ctor boom"],
              @"construct exception value mismatch");
        error = nil;
        Check([evaluate(@"(() => 1)") constructWithArguments:@[] error:&error] == nil &&
                  isTypeError(error),
              @"construct of non-constructor must throw TypeError");

        JSBayValue *hasTarget = evaluate(@"({ a: 1, get g() { return 1 } })");
        error = nil;
        for (NSString *present in @[ @"a", @"g", @"toString" ]) {
            flag = NO;
            Check([hasTarget hasKey:present result:&flag error:&error] && flag,
                  @"has own, accessor, or inherited key mismatch");
        }
        flag = YES;
        Check([hasTarget hasKey:@"missing" result:&flag error:&error] && !flag && error == nil,
              @"has missing key mismatch");
        flag = YES;
        Check(![numberFortyTwo hasKey:@"a" result:&flag error:&error] && isTypeError(error) &&
                  flag == YES,
              @"has on a non-object must throw TypeError and leave result untouched");
        error = nil;
        Check(![evaluate(@"new Proxy({}, { has() { throw new Error('has trap') } })")
                  hasKey:@"a"
                  result:&flag
                   error:&error] &&
                  [[thrownMessage(error) stringValue:nil] isEqualToString:@"has trap"],
              @"has trap exception value mismatch");

        JSBayValue *deletable =
            evaluate(@"(() => {\n"
                      "  const o = { a: 1 };\n"
                      "  Object.defineProperty(o, 'fixed', { value: 1, configurable: false });\n"
                      "  return o;\n"
                      "})()");
        error = nil;
        flag = NO;
        Check([deletable deleteKey:@"a" result:&flag error:&error] && flag &&
                  [deletable hasKey:@"a" result:&flag error:&error] && !flag,
              @"delete of a configurable property mismatch");
        flag = YES;
        Check([deletable deleteKey:@"fixed" result:&flag error:&error] && !flag && error == nil &&
                  [deletable hasKey:@"fixed" result:&flag error:&error] && flag,
              @"delete of a non-configurable property must report NO without an error");
        flag = NO;
        Check([deletable deleteKey:@"missing" result:&flag error:&error] && flag,
              @"delete of a missing key mismatch");
        error = nil;
        Check(![[engine undefinedValue:&error] deleteKey:@"a" result:&flag error:&error] &&
                  isTypeError(error),
              @"delete on undefined must throw TypeError");

        JSBayValue *keyed =
            evaluate(@"(() => {\n"
                      "  const o = Object.create({ inherited: 1 });\n"
                      "  o.b = 1; o[2] = 1; o.a = 1; o[1] = 1;\n"
                      "  Object.defineProperty(o, 'hidden', { value: 1, enumerable: false });\n"
                      "  o[Symbol('s')] = 1;\n"
                      "  return o;\n"
                      "})()");
        error = nil;
        Check([[[keyed keysWithError:&error] jsonValue:&error]
                  isEqualToString:@"[\"1\",\"2\",\"b\",\"a\"]"],
              @"keys must be own enumerable string keys, integers first");
        error = nil;
        Check([[engine nullValue:&error] keysWithError:&error] == nil && isTypeError(error),
              @"keys on null must throw TypeError");

        JSBayValue *customInstance =
            evaluate(@"(class { static [Symbol.hasInstance](v) { return v === 7 } })");
        error = nil;
        flag = YES;
        Check([numberFortyTwo instanceOfConstructor:customInstance result:&flag error:&error] &&
                  !flag,
              @"Symbol.hasInstance false result mismatch");
        flag = NO;
        Check([[engine numberValue:7 error:&error] instanceOfConstructor:customInstance
                                                                  result:&flag
                                                                   error:&error] &&
                  flag,
              @"Symbol.hasInstance true result mismatch");
        JSBayValue *list = evaluate(@"[]");
        flag = NO;
        Check([list instanceOfConstructor:evaluate(@"Array") result:&flag error:&error] && flag,
              @"instanceOf prototype chain mismatch");
        flag = YES;
        Check([list instanceOfConstructor:evaluate(@"Function") result:&flag error:&error] && !flag,
              @"array must not be an instance of Function");
        error = nil;
        Check(![list instanceOfConstructor:evaluate(@"({})") result:&flag error:&error] &&
                  isTypeError(error),
              @"instanceOf non-callable must throw TypeError");
        error = nil;

        error = nil;
        Check([engine evaluate:@"throw 'objc-display\\0😀'"
                      filename:@"describe-and-close.js"
                         cache:nil
                         error:&error] == nil,
              @"expected description source");
        NSError *descriptionError = error;
        JSBayValue *consumed = descriptionError.userInfo[JSBayExceptionValueKey];
        error = nil;
        Check([JSBayDescribeAndCloseException(descriptionError, &error)
                  isEqualToString:@"objc-display\0😀"] &&
                  error == nil,
              @"consuming description text");
        Check(![consumed stringValue:&error] && error.code == JSBayErrorStaleValue,
              @"consuming description closes original");

        error = nil;
        Check([engine evaluate:@"throw {toString(){throw 9}}"
                      filename:@"describe-and-close-secondary.js"
                         cache:nil
                         error:&error] == nil,
              @"expected secondary description source");
        descriptionError = error;
        consumed = descriptionError.userInfo[JSBayExceptionValueKey];
        error = nil;
        Check([JSBayDescribeAndCloseException(descriptionError, &error)
                  isEqualToString:@"JavaScript exception"] &&
                  error == nil,
              @"secondary consuming description fallback");
        Check(![consumed stringValue:&error] && error.code == JSBayErrorStaleValue,
              @"secondary consuming description closes original");

        Check([engine bind:@"recursive"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      double depth = 0;
                      if (![arguments[0] numberValue:&depth error:callbackError])
                          return nil;
                      if (depth == 0)
                          return [engine numberValue:40 error:callbackError];
                      return [engine
                          evaluate:[NSString stringWithFormat:@"recursive(%d)+1", (int)depth - 1]
                          filename:@"recursive.js"
                             cache:nil
                             error:callbackError];
                  }
                     error:&error] != nil,
              error.localizedDescription);
        JSBayValue *recursive = [engine evaluate:@"recursive(2)"
                                        filename:@"recursive.js"
                                           cache:nil
                                           error:&error];
        Check([recursive numberValue:&number error:&error] && number == 42,
              @"nested callback mismatch");

        __block NSInteger automaticTimerCount = 0;
        Check([engine bind:@"objcAutomaticTimer"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      automaticTimerCount += 1;
                      return [engine undefinedValue:callbackError];
                  }
                     error:&error] != nil,
              error.localizedDescription);
        Check([engine evaluate:@"setTimeout(objcAutomaticTimer, 1)"
                      filename:@"automatic-timer.js"
                         cache:nil
                         error:&error] != nil,
              error.localizedDescription);
        Check([engine evaluate:@"setTimeout(objcAutomaticTimer, 2)"
                      filename:@"automatic-timer-next.js"
                         cache:nil
                         error:&error] != nil,
              error.localizedDescription);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        Check(automaticTimerCount == 2, @"CFRunLoop driver did not run both timers");

        JSBayEngine *pending = [[JSBayEngine alloc] initWithIdentifier:81006
                                                allowMainRunLoopAttach:YES
                                                                 error:&error];
        __block BOOL closedTimerFired = NO;
        Check([pending bind:@"objcClosedTimer"
                   callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                          NSError **callbackError) {
                       (void)thisValue;
                       (void)arguments;
                       closedTimerFired = YES;
                       return [pending undefinedValue:callbackError];
                   }
                      error:&error] != nil,
              error.localizedDescription);
        Check([pending evaluate:@"setTimeout(objcClosedTimer, 1)"
                       filename:@"closed-timer.js"
                          cache:nil
                          error:&error] != nil,
              error.localizedDescription);
        Check([pending close:&error], error.localizedDescription);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
        Check(!closedTimerFired, @"closed engine ran a pending timer");

        Check([engine bind:@"objcStopLoop"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      Check([engine stopLoop], @"stopLoop rejected active runLoop");
                      return [engine undefinedValue:callbackError];
                  }
                     error:&error] != nil,
              error.localizedDescription);
        Check([engine evaluate:@"setTimeout(objcStopLoop, 1)"
                      filename:@"blocking-loop.js"
                         cache:nil
                         error:&error] != nil,
              error.localizedDescription);
        Check([engine runLoop:&error], error.localizedDescription);

        __block BOOL rejectedNestedRunLoop = NO;
        __block NSInteger recoveredTimerCount = 0;
        Check([engine bind:@"objcRejectedRunLoop"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      NSError *nestedError = nil;
                      Check(![engine runLoop:&nestedError] &&
                                nestedError.code == JSBayErrorInvalidArgument,
                            @"runLoop from a callback must be rejected");
                      rejectedNestedRunLoop = YES;
                      return [engine undefinedValue:callbackError];
                  }
                     error:&error] != nil,
              error.localizedDescription);
        Check([engine bind:@"objcRecoveredTimer"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      recoveredTimerCount += 1;
                      return [engine undefinedValue:callbackError];
                  }
                     error:&error] != nil,
              error.localizedDescription);
        Check([engine evaluate:@"objcRejectedRunLoop(); setTimeout(objcRecoveredTimer, 1)"
                      filename:@"rejected-run-loop.js"
                         cache:nil
                         error:&error] != nil,
              error.localizedDescription);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
        Check(rejectedNestedRunLoop && recoveredTimerCount == 1,
              @"rejected runLoop did not restore the automatic driver");

        JSBayEngine *other = [[JSBayEngine alloc] initWithIdentifier:81004
                                              allowMainRunLoopAttach:YES
                                                               error:&error];
        dispatch_semaphore_t wrongThreadDone = dispatch_semaphore_create(0);
        __block BOOL rejectedWrongThread = NO;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            @autoreleasepool {
                NSError *threadError = nil;
                (void)[engine numberValue:1 error:&threadError];
                rejectedWrongThread = threadError.code == JSBayErrorWrongThread;
                dispatch_semaphore_signal(wrongThreadDone);
            }
        });
        Check(dispatch_semaphore_wait(wrongThreadDone,
                                      dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0 &&
                  rejectedWrongThread,
              @"owner-thread check accepted foreign thread");
        JSBayValue *foreign = [other numberValue:1 error:&error];
        Check(![object setValue:foreign forKey:@"foreign" error:&error],
              @"cross-engine value accepted");
        error = nil;
        Check([point constructWithArguments:@[ foreign ] error:&error] == nil &&
                  error.code == JSBayErrorStaleValue,
              @"cross-engine construct argument accepted");
        error = nil;
        flag = NO;
        Check(![hasTarget instanceOfConstructor:foreign result:&flag error:&error] &&
                  error.code == JSBayErrorStaleValue,
              @"cross-engine instanceOf constructor accepted");
        error = nil;
        Check([engine bind:@"foreignCallback"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      (void)callbackError;
                      return foreign;
                  }
                     error:&error] != nil,
              error.localizedDescription);
        Check([engine evaluate:@"foreignCallback()"
                      filename:@"foreign-callback.js"
                         cache:nil
                         error:&error] == nil,
              @"foreign callback value accepted");
        error = nil;
        JSBayEngine *closing = [[JSBayEngine alloc] initWithIdentifier:81005
                                                allowMainRunLoopAttach:YES
                                                                 error:&error];
        JSBayValue *closingValue = [closing numberValue:1 error:&error];
        Check([closing bind:@"closeDuringCallback"
                   callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                          NSError **callbackError) {
                       (void)thisValue;
                       [closing close:callbackError];
                       return arguments[0];
                   }
                      error:&error] != nil,
              error.localizedDescription);
        (void)[closing evaluate:@"closeDuringCallback(7)"
                       filename:@"close-callback.js"
                          cache:nil
                          error:&error];
        error = nil;
        Check([closingValue numberValue:&number error:&error] == NO,
              @"callback close left a live value");
        error = nil;
        JSBayValue *saved = [object retainValue:&error];
        Check([object close:&error], error.localizedDescription);
        Check([object close:&error], error.localizedDescription);
        Check([saved valueForKey:@"value" error:&error] != nil, @"retained object lost");
        Check([other close:&error], error.localizedDescription);
        Check([engine close:&error], error.localizedDescription);
        Check([engine close:&error], error.localizedDescription);
        Check([saved valueForKey:@"value" error:&error] == nil &&
                  error.code == JSBayErrorStaleValue,
              @"value survived close");
        JSBayEngine *replacement = [[JSBayEngine alloc] initWithIdentifier:engine.identifier
                                                    allowMainRunLoopAttach:YES
                                                                     error:&error];
        Check(replacement != nil, error.localizedDescription);
        Check(![engine stopLoop], @"closed engine stopped same-id replacement");
        Check([replacement
                      bind:@"replacementStopLoop"
                  callback:^JSBayValue *(JSBayValue *thisValue, NSArray<JSBayValue *> *arguments,
                                         NSError **callbackError) {
                      (void)thisValue;
                      (void)arguments;
                      Check([replacement stopLoop], @"replacement stopLoop was rejected");
                      return [replacement undefinedValue:callbackError];
                  }
                     error:&error] != nil,
              error.localizedDescription);
        Check([replacement evaluate:@"setTimeout(replacementStopLoop, 1)"
                           filename:@"replacement-stop-loop.js"
                              cache:nil
                              error:&error] != nil,
              error.localizedDescription);
        Check([replacement runLoop:&error], error.localizedDescription);
        Check(![engine requestInterrupt], @"closed engine interrupted same-id replacement");
        JSBayValue *replacementValue = [replacement evaluate:@"40+2"
                                                    filename:@"replacement.js"
                                                       cache:nil
                                                       error:&error];
        Check([replacementValue numberValue:&number error:&error] && number == 42,
              @"same-id replacement did not evaluate");
        Check([replacementValue close:&error], error.localizedDescription);
        Check([replacement close:&error], error.localizedDescription);
    }
    return 0;
}

#ifndef JSBAY_SDK_PROBE_NO_MAIN
int main(void) {
    int result = jsbay_objc_sdk_probe();
    if (result == 0)
        NSLog(@"PASS: Objective-C SDK consumer");
    return result;
}
#endif
