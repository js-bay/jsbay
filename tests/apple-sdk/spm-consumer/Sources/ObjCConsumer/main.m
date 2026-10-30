@import Foundation;
@import JsBayObjC;

int main(void) {
    @autoreleasepool {
        NSError *error = nil;
        JSBayEngine *engine = [[JSBayEngine alloc] initWithIdentifier:99102
                                               allowMainRunLoopAttach:YES
                                                                error:&error];
        if (engine == nil)
            return 1;
        JSBayValue *value = [engine evaluate:@"6 * 7"
                                    filename:@"spm-objc.js"
                                       cache:nil
                                       error:&error];
        double number = 0;
        if (![value numberValue:&number error:&error] || number != 42)
            return 2;
        return [engine close:&error] ? 0 : 3;
    }
}
