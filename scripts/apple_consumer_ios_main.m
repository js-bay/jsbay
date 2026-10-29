#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern int jsbay_apple_consumer_probe(void);
#ifdef JSBAY_WITH_SDK_PROBES
extern int jsbay_swift_sdk_probe(void);
extern int jsbay_objc_sdk_probe(void);
#endif
#ifdef JSBAY_WITH_IOS_IO_PROBE
extern int jsbay_ios_io_compat_probe(const char *pathname);
#endif

@interface JsBayAppleConsumerDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation JsBayAppleConsumerDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application;
    (void)options;
    int result = jsbay_apple_consumer_probe();
#ifdef JSBAY_WITH_SDK_PROBES
    if (result == 0) result = jsbay_swift_sdk_probe();
    if (result == 0) result = jsbay_objc_sdk_probe();
#endif
#ifdef JSBAY_WITH_IOS_IO_PROBE
    if (result == 0) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        result = jsbay_ios_io_compat_probe(path.fileSystemRepresentation);
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        if (result == 0) NSLog(@"JSBAY_IOS13_IO_COMPAT_PASS");
    }
#endif
    NSLog(@"JSBAY_APPLE_CONSUMER_%@", result == 0 ? @"PASS" : [NSString stringWithFormat:@"FAIL:%d", result]);
    exit(result == 0 ? 0 : 1);
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(JsBayAppleConsumerDelegate.class));
    }
}
