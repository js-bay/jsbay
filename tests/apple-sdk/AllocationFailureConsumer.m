#import "JSBayObjC.h"
#import <stdlib.h>

// Only the SDK translation unit redirects calloc to this test implementation.
static BOOL failNextAllocation;
void *JSBayTestCalloc(size_t count, size_t size) {
    if (failNextAllocation) {
        failNextAllocation = NO;
        return NULL;
    }
    return calloc(count, size);
}

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"%@", message);
        abort();
    }
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        JSBayEngine *engine = [[JSBayEngine alloc] initWithIdentifier:81003 allowMainRunLoopAttach:YES error:&error];
        Check(engine != nil, error.localizedDescription);
        JSBayValue *function = [engine evaluate:@"(function(value) { return value + 1; })"
                                       filename:@"allocation-failure.js"
                                          cache:nil
                                          error:&error];
        JSBayValue *argument = [engine numberValue:41 error:&error];
        Check(function != nil && argument != nil, error.localizedDescription);
        failNextAllocation = YES;
        JSBayValue *failed = [function callWithThis:nil arguments:@[ argument ] error:&error];
        Check(!failNextAllocation, @"call did not exercise the SDK argument allocation");
        Check(failed == nil && [error.domain isEqualToString:JSBayErrorDomain] &&
                  error.code == JSBayErrorOutOfMemory,
              @"argument allocation failure must return an out-of-memory NSError");
        error = nil;
        JSBayValue *recovered = [function callWithThis:nil arguments:@[ argument ] error:&error];
        double number = 0;
        Check(recovered != nil && [recovered numberValue:&number error:&error] && number == 42,
              @"engine must remain usable after argument allocation failure");
        Check([engine close:&error], error.localizedDescription);
        NSLog(@"PASS: Objective-C argument allocation failure and recovery");
    }
    return 0;
}
