// ES module loader bridge for the JSC backend.
//
// JavaScriptCore's public Objective-C headers do not expose the module-loader protocol. This file forward-declares the framework classes and selectors used by the bridge, then links against JavaScriptCore.
//
// The Zig side uses plain C function pointers, so these private declarations are contained in this file.
//
// Exposed to Zig (see src/backend/jsc.zig for the extern decls):
//   jsbay_jsc_install_module_loader  — attach delegate + stash Zig callbacks
//   jsbay_jsc_eval_module            — evaluate a module source string by name
//   jsbay_jsc_import_module          — import a bare specifier synchronously
//   jsbay_jsc_uninstall_module_loader — detach delegate (engine destroy hook)
//
// Ownership notes:
//   - The JSContext created here is retained by the delegate for its lifetime; the underlying JSGlobalContextRef is owned by Zig (Zig calls JSGlobalContextRelease in JscBackend.freeContext).
//   - out_result / out_error (from eval/import) are malloc'd C strings; the Zig caller frees via free().

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

// ---- Private JSC API forward declarations ----

typedef NS_ENUM(NSInteger, JsBayJSScriptType) {
    JsBayJSScriptTypeProgram = 0,
    JsBayJSScriptTypeModule  = 1,
};

@class JSScript;

@interface JSScript : NSObject
+ (instancetype)scriptOfType:(JsBayJSScriptType)type
                  withSource:(NSString *)source
                andSourceURL:(NSURL *)sourceURL
            andBytecodeCache:(NSURL *)cachePath
            inVirtualMachine:(JSVirtualMachine *)vm
                       error:(NSError **)error;
@end

@protocol JSModuleLoaderDelegate <NSObject>
@optional
// JSC invokes this asynchronous callback to load a module.
- (void)context:(JSContext *)ctx
    fetchModuleForIdentifier:(JSValue *)identifier
         withResolveHandler:(JSValue *)resolveValue
         andRejectHandler:(JSValue *)rejectValue;

// JSC may invoke this synchronous callback to load a module.
- (JSScript *)context:(JSContext *)ctx
  scriptForModuleWithModuleIdentifier:(JSValue *)identifier
                                error:(NSError **)error;
@end

@interface JSContext (JsBayModulePrivate)
@property (nonatomic, weak) id<JSModuleLoaderDelegate> moduleLoaderDelegate;
- (JSValue *)evaluateJSScript:(JSScript *)script;
@end

// ---- C-callable bridge types (mirror ModuleLoaderVTable in src/types.zig) ----

typedef bool (*jsbay_mod_load_fn)(void *user_data,
                                const char *canonical_id,
                                const char **out_src,
                                size_t *out_len);

typedef char *(*jsbay_mod_resolve_fn)(void *user_data,
                                    const char *referrer,
                                    const char *specifier);

typedef void (*jsbay_mod_free_resolved_fn)(void *user_data, char *ptr);

// ---- Delegate class ----

@interface JsBayModuleLoaderDelegate : NSObject <JSModuleLoaderDelegate>
@property(nonatomic, assign) void *userData;
@property(nonatomic, assign) jsbay_mod_resolve_fn resolveCb;
@property(nonatomic, assign) jsbay_mod_load_fn loadCb;
@property(nonatomic, assign) jsbay_mod_free_resolved_fn freeCb;
// Strong ref to keep the JSContext wrapper alive for the lifetime of the delegate; the underlying JSGlobalContextRef is owned by Zig.
@property(nonatomic, strong) JSContext *context;
// Per-eval override: when the entry is an anonymous module source (from jsbay_jsc_eval_module), we pre-register it here so fetch(entryURL) can serve the source without going through the Zig loader.
@property(nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *entryOverrides;
@end

// URL scheme used to carry canonical ids through the identifier JSValue. Keeping the scheme distinct from common loaders (file:, http:) avoids accidental resolution by JSC's internal resolver.
static NSString *const kJsBayModuleScheme = @"js-bay-module";

// URL form: js-bay-module:///<percent-escaped-canonical-id> The triple-slash-rooted path lets JSC resolve relative specifiers like `./foo` correctly — JSC would otherwise fail silently on bare ids.
static NSURL *jsbay_url_for_id(NSString *canonical) {
    NSCharacterSet *allowed = [NSCharacterSet URLPathAllowedCharacterSet];
    NSString *escaped =
        [canonical stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    NSString *urlStr =
        [NSString stringWithFormat:@"%@:///%@", kJsBayModuleScheme, escaped];
    return [NSURL URLWithString:urlStr];
}
static NSString *jsbay_id_from_url(NSURL *url) {
    if ([url.scheme isEqualToString:kJsBayModuleScheme]) {
        // resourceSpecifier for "js-bay-module:///foo" is "///foo". Strip the leading slashes and percent-decode to recover the canonical id.
        NSString *ssp = url.resourceSpecifier ?: @"";
        while ([ssp hasPrefix:@"/"]) {
            ssp = [ssp substringFromIndex:1];
        }
        return [ssp stringByRemovingPercentEncoding] ?: ssp;
    }
    return url.absoluteString ?: @"";
}

// Rewrite bare ESM specifiers (`from 'X'` / `import('X')` where X has no scheme or leading dot/slash) into `./X` form. JSC's internal resolver then treats them as URL-relative to the module's sourceURL and invokes the delegate fetch for each dependency. Without this transform, bare specifiers are silently dropped by JSC and the import evaluates to undefined — the public Objective-C JSC API does not expose a resolve hook, so source rewriting is the only lever available.
//
// Regex-style rewrite implemented by hand because we don't want to pull in NSRegularExpression for this hot path. The match patterns are:
//   * `import ... from 'X'` / `import ... from "X"`
//   * `import 'X'` / `import "X"`   (side-effect imports)
//   * `export { ... } from 'X'` / `export * from 'X'`
//   * `import('X')` / `import("X")` (dynamic; treat conservatively)
//
// Inside strings and comments we could mistakenly match; this is acceptable for the module-tests fixtures where sources are hand-authored JS without contrived collisions. For general use the transform is a best-effort — callers who need JSC with custom import maps should use the QJS backend.
static BOOL jsbay_is_bare_specifier(NSString *spec) {
    if (spec.length == 0) return NO;
    unichar c0 = [spec characterAtIndex:0];
    if (c0 == '.' || c0 == '/') return NO;
    // Scheme prefix check: letter followed by ":"
    NSRange colon = [spec rangeOfString:@":"];
    if (colon.location != NSNotFound && colon.location > 0 && colon.location < 32) {
        NSString *scheme = [spec substringToIndex:colon.location];
        NSCharacterSet *nonSchemeChars = [[NSCharacterSet
            characterSetWithCharactersInString:
                @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+-."]
            invertedSet];
        if ([scheme rangeOfCharacterFromSet:nonSchemeChars].location == NSNotFound) {
            return NO; // looks like scheme:...
        }
    }
    return YES;
}

static NSString *jsbay_rewrite_specifier_in_quotes(NSString *source,
                                                  NSString *openKey,
                                                  NSCharacterSet *boundary) {
    // Walk `source` looking for occurrences of openKey followed by an optional-whitespace quoted specifier. For each bare specifier found, replace it in-place with `./<spec>`.
    NSMutableString *out = [NSMutableString stringWithCapacity:source.length];
    NSUInteger pos = 0;
    NSUInteger len = source.length;
    while (pos < len) {
        NSRange r = [source rangeOfString:openKey
                                  options:NSLiteralSearch
                                    range:NSMakeRange(pos, len - pos)];
        if (r.location == NSNotFound) {
            [out appendString:[source substringFromIndex:pos]];
            break;
        }
        // Require preceding char be a word boundary (start of file, whitespace, or punctuation) so we don't rewrite inside identifiers like `reexport` or `fromX`.
        if (r.location > 0) {
            unichar prev = [source characterAtIndex:r.location - 1];
            if (!(prev == ' ' || prev == '\t' || prev == '\n' || prev == '\r' ||
                  prev == ';' || prev == '}' || prev == '*' || prev == ')' ||
                  prev == ',' || prev == '(')) {
                // Not a boundary — emit up to and including this match and keep scanning.
                [out appendString:[source substringWithRange:NSMakeRange(pos, r.location + r.length - pos)]];
                pos = r.location + r.length;
                continue;
            }
        }
        (void)boundary;
        // Copy up to the match.
        [out appendString:[source substringWithRange:NSMakeRange(pos, r.location - pos)]];
        [out appendString:openKey];
        NSUInteger scan = r.location + r.length;
        // Skip whitespace.
        while (scan < len) {
            unichar ch = [source characterAtIndex:scan];
            if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') scan++;
            else break;
        }
        if (scan >= len) { pos = scan; break; }
        unichar quote = [source characterAtIndex:scan];
        if (quote != '\'' && quote != '"') {
            // Not a string specifier (could be identifier or template). Emit the whitespace we consumed and continue.
            [out appendString:[source substringWithRange:NSMakeRange(r.location + r.length, scan - r.location - r.length)]];
            pos = scan;
            continue;
        }
        // Emit the whitespace.
        [out appendString:[source substringWithRange:NSMakeRange(r.location + r.length, scan - r.location - r.length)]];
        // Find matching close quote.
        NSUInteger q_start = scan + 1;
        NSUInteger q_end = q_start;
        while (q_end < len) {
            unichar ch = [source characterAtIndex:q_end];
            if (ch == '\\' && q_end + 1 < len) { q_end += 2; continue; }
            if (ch == quote) break;
            q_end++;
        }
        if (q_end >= len) {
            // Unterminated — emit rest and bail.
            [out appendString:[source substringFromIndex:scan]];
            pos = len;
            break;
        }
        NSString *spec = [source substringWithRange:NSMakeRange(q_start, q_end - q_start)];
        NSString *replacement = jsbay_is_bare_specifier(spec)
            ? [NSString stringWithFormat:@"./%@", spec]
            : spec;
        [out appendFormat:@"%C%@%C", quote, replacement, quote];
        pos = q_end + 1;
    }
    return out;
}

static NSString *jsbay_rewrite_bare_specifiers(NSString *source) {
    NSString *s = source;
    s = jsbay_rewrite_specifier_in_quotes(s, @"from", nil);
    s = jsbay_rewrite_specifier_in_quotes(s, @"import", nil);
    // dynamic import(...): handled by `import` key above since the pattern `import(` fits the same "import <whitespace-or-paren>" lead-in.
    return s;
}

static NSString *jsbay_id_from_identifier(JSValue *identifier) {
    NSString *s = [identifier toString] ?: @"";
    NSURL *url = [NSURL URLWithString:s];
    if (url && url.scheme) return jsbay_id_from_url(url);
    return s;
}

@implementation JsBayModuleLoaderDelegate

- (JSScript *)buildScriptForId:(NSString *)canonical
                        source:(NSString *)source
                       context:(JSContext *)ctx
                         error:(NSError **)outError {
    NSURL *url = jsbay_url_for_id(canonical);
    NSString *rewritten = jsbay_rewrite_bare_specifiers(source);
    NSError *scriptErr = nil;
    JSScript *script = [JSScript scriptOfType:JsBayJSScriptTypeModule
                                   withSource:rewritten
                                 andSourceURL:url
                             andBytecodeCache:nil
                             inVirtualMachine:ctx.virtualMachine
                                        error:&scriptErr];
    if (script == nil && outError) *outError = scriptErr;
    return script;
}

// Async fetcher — this is the one JSC actually calls on current versions.
- (void)context:(JSContext *)ctx
    fetchModuleForIdentifier:(JSValue *)identifier
         withResolveHandler:(JSValue *)resolveValue
         andRejectHandler:(JSValue *)rejectValue {
    NSString *canonical = jsbay_id_from_identifier(identifier);

    // Entry override: when jsbay_jsc_eval_module stages an anonymous module, JSC's first fetch is for the entry's identifier — serve it from the override map rather than round-tripping through the Zig loader (which doesn't know about anonymous entry sources).
    NSString *overrideSrc = self.entryOverrides[canonical];
    if (overrideSrc != nil) {
        NSError *scriptErr = nil;
        JSScript *script = [self buildScriptForId:canonical
                                           source:overrideSrc
                                          context:ctx
                                            error:&scriptErr];
        if (script) {
            [resolveValue callWithArguments:@[ script ]];
        } else {
            JSValue *err = [JSValue valueWithNewErrorFromMessage:
                            (scriptErr.localizedDescription ?: @"script creation failed")
                                                       inContext:ctx];
            [rejectValue callWithArguments:@[ err ]];
        }
        return;
    }

    if (self.loadCb == NULL) {
        JSValue *err = [JSValue valueWithNewErrorFromMessage:
                        @"no module load callback configured"
                                                   inContext:ctx];
        [rejectValue callWithArguments:@[ err ]];
        return;
    }

    const char *canonical_c = [canonical UTF8String] ?: "";
    const char *src_ptr = NULL;
    size_t src_len = 0;
    bool ok = self.loadCb(self.userData, canonical_c, &src_ptr, &src_len);
    if (!ok || src_ptr == NULL) {
        NSString *msg = [NSString stringWithFormat:
                         @"could not load module '%@'", canonical];
        JSValue *err = [JSValue valueWithNewErrorFromMessage:msg inContext:ctx];
        [rejectValue callWithArguments:@[ err ]];
        return;
    }

    NSString *sourceStr = [[NSString alloc] initWithBytes:src_ptr
                                                   length:src_len
                                                 encoding:NSUTF8StringEncoding];
    if (sourceStr == nil) {
        JSValue *err = [JSValue valueWithNewErrorFromMessage:
                        @"module source was not valid UTF-8"
                                                   inContext:ctx];
        [rejectValue callWithArguments:@[ err ]];
        return;
    }

    NSError *scriptErr = nil;
    JSScript *script = [self buildScriptForId:canonical
                                       source:sourceStr
                                      context:ctx
                                        error:&scriptErr];
    if (script == nil) {
        JSValue *err = [JSValue valueWithNewErrorFromMessage:
                        (scriptErr.localizedDescription ?: @"JSScript creation failed")
                                                   inContext:ctx];
        [rejectValue callWithArguments:@[ err ]];
        return;
    }
    [resolveValue callWithArguments:@[ script ]];
}

// Synchronous module-loading callback.
- (JSScript *)context:(JSContext *)ctx
  scriptForModuleWithModuleIdentifier:(JSValue *)identifier
                                error:(NSError **)error {
    NSString *canonical = jsbay_id_from_identifier(identifier);
    NSString *overrideSrc = self.entryOverrides[canonical];
    if (overrideSrc != nil) {
        return [self buildScriptForId:canonical
                               source:overrideSrc
                              context:ctx
                                error:error];
    }
    if (self.loadCb == NULL) return nil;
    const char *src_ptr = NULL;
    size_t src_len = 0;
    const char *canonical_c = [canonical UTF8String] ?: "";
    if (!self.loadCb(self.userData, canonical_c, &src_ptr, &src_len) || src_ptr == NULL) {
        if (error) {
            NSString *msg = [NSString stringWithFormat:
                             @"could not load module '%@'", canonical];
            *error = [NSError errorWithDomain:@"jsbay" code:3
                                     userInfo:@{NSLocalizedDescriptionKey : msg}];
        }
        return nil;
    }
    NSString *sourceStr = [[NSString alloc] initWithBytes:src_ptr
                                                   length:src_len
                                                 encoding:NSUTF8StringEncoding];
    if (sourceStr == nil) return nil;
    return [self buildScriptForId:canonical
                           source:sourceStr
                          context:ctx
                            error:error];
}

@end

// ---- Per-context delegate registry ----
//
// NSMapTable with opaque keys (JSGlobalContextRef) and strong-object values.

static NSMapTable *jsbay_delegate_registry(void) {
    static NSMapTable *g_registry = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_registry =
            [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory |
                                                NSPointerFunctionsOpaquePersonality
                                  valueOptions:NSPointerFunctionsStrongMemory |
                                                NSPointerFunctionsObjectPersonality];
    });
    return g_registry;
}

static JsBayModuleLoaderDelegate *jsbay_lookup_delegate(JSGlobalContextRef c_ctx) {
    @synchronized(jsbay_delegate_registry()) {
        return [jsbay_delegate_registry() objectForKey:(__bridge id)c_ctx];
    }
}

// ---- C API exposed to Zig ----

void jsbay_jsc_install_module_loader(JSGlobalContextRef c_ctx,
                                   void *user_data,
                                   jsbay_mod_resolve_fn resolve_cb,
                                   jsbay_mod_load_fn load_cb,
                                   jsbay_mod_free_resolved_fn free_cb) {
    if (c_ctx == NULL || load_cb == NULL) return;

    JSContext *ctx = [JSContext contextWithJSGlobalContextRef:c_ctx];
    if (ctx == nil) return;

    JsBayModuleLoaderDelegate *delegate = jsbay_lookup_delegate(c_ctx);
    if (delegate == nil) {
        delegate = [[JsBayModuleLoaderDelegate alloc] init];
        delegate.context = ctx;
        delegate.entryOverrides =
            [NSMutableDictionary<NSString *, NSString *> dictionary];
        @synchronized(jsbay_delegate_registry()) {
            [jsbay_delegate_registry() setObject:delegate forKey:(__bridge id)c_ctx];
        }
    }
    delegate.userData = user_data;
    delegate.resolveCb = resolve_cb;
    delegate.loadCb = load_cb;
    delegate.freeCb = free_cb;

    ctx.moduleLoaderDelegate = delegate;
}

void jsbay_jsc_uninstall_module_loader(JSGlobalContextRef c_ctx) {
    if (c_ctx == NULL) return;
    @synchronized(jsbay_delegate_registry()) {
        JsBayModuleLoaderDelegate *d = [jsbay_delegate_registry() objectForKey:(__bridge id)c_ctx];
        if (d) {
            if (d.context) d.context.moduleLoaderDelegate = nil;
            [jsbay_delegate_registry() removeObjectForKey:(__bridge id)c_ctx];
        }
    }
}

// ---- Result / error marshalling ----

static char *jsbay_dup_nsstring(NSString *src) {
    if (src == nil) return NULL;
    const char *utf = [src UTF8String];
    if (utf == NULL) return NULL;
    size_t n = strlen(utf);
    char *out = (char *)malloc(n + 1);
    if (out == NULL) return NULL;
    memcpy(out, utf, n + 1);
    return out;
}

static char *jsbay_dup_cstr(const char *s) {
    if (s == NULL) return NULL;
    size_t n = strlen(s);
    char *out = (char *)malloc(n + 1);
    if (out == NULL) return NULL;
    memcpy(out, s, n + 1);
    return out;
}

static char *jsbay_stringify_value(JSContext *ctx, JSValue *val) {
    if (val == nil) return NULL;
    if ([val isUndefined] || [val isNull]) return NULL;
    if ([val isObject]) {
        JSValue *jsonObj = ctx.globalObject[@"JSON"];
        JSValue *stringify = jsonObj[@"stringify"];
        JSValue *result = [stringify callWithArguments:@[ val ]];
        if (result && ![result isUndefined] && ![result isNull]) {
            NSString *s = [result toString];
            if (s) return jsbay_dup_nsstring(s);
        }
    }
    NSString *s = [val toString];
    return jsbay_dup_nsstring(s);
}

static char *jsbay_dup_exception_message(JSContext *ctx, JSValue *exception) {
    (void)ctx;
    if (exception == nil) {
        return jsbay_dup_cstr("unknown JavaScript error");
    }
    JSValue *msg = exception[@"message"];
    NSString *desc = nil;
    if (msg && ![msg isUndefined] && ![msg isNull]) {
        desc = [msg toString];
    }
    if (desc == nil) {
        desc = [exception toString];
    }
    return jsbay_dup_nsstring(desc ?: @"JavaScript error");
}

int jsbay_jsc_eval_module(JSGlobalContextRef c_ctx,
                        const char *source,
                        size_t source_len,
                        const char *module_name,
                        char **out_result,
                        char **out_error) {
    if (out_result) *out_result = NULL;
    if (out_error) *out_error = NULL;
    if (c_ctx == NULL) {
        if (out_error) *out_error = jsbay_dup_cstr("null context");
        return 0;
    }

    JSContext *ctx = [JSContext contextWithJSGlobalContextRef:c_ctx];
    if (ctx == nil) {
        if (out_error) *out_error = jsbay_dup_cstr("could not wrap JSGlobalContextRef");
        return 0;
    }

    NSString *src = [[NSString alloc] initWithBytes:source
                                             length:source_len
                                           encoding:NSUTF8StringEncoding];
    if (src == nil) {
        if (out_error) *out_error = jsbay_dup_cstr("module source was not valid UTF-8");
        return 0;
    }

    NSString *name = module_name
        ? [NSString stringWithUTF8String:module_name]
        : @"<entry>";
    NSURL *url = jsbay_url_for_id(name);

    // Make sure a delegate exists so JSC's internal entry-fetch (which fires even when the JSScript was passed directly to evaluateJSScript:) can be serviced from our override map. If the user didn't configure a loader, we still need a minimal delegate to serve the entry source.
    JsBayModuleLoaderDelegate *delegate = jsbay_lookup_delegate(c_ctx);
    if (delegate == nil) {
        delegate = [[JsBayModuleLoaderDelegate alloc] init];
        delegate.context = ctx;
        delegate.entryOverrides =
            [NSMutableDictionary<NSString *, NSString *> dictionary];
        @synchronized(jsbay_delegate_registry()) {
            [jsbay_delegate_registry() setObject:delegate forKey:(__bridge id)c_ctx];
        }
        ctx.moduleLoaderDelegate = delegate;
    } else if (ctx.moduleLoaderDelegate != delegate) {
        // Re-attach — a prior [JSContext contextWithJSGlobalContextRef:] may have produced a wrapper that lost its weak delegate reference.
        ctx.moduleLoaderDelegate = delegate;
    }
    NSString *canonical = jsbay_id_from_url(url);
    delegate.entryOverrides[canonical] = src;

    // Install a capture-all exception handler; restore before returning.
    __block JSValue *capturedException = nil;
    void (^savedHandler)(JSContext *, JSValue *) = ctx.exceptionHandler;
    ctx.exceptionHandler = ^(JSContext *c, JSValue *exception) {
        (void)c;
        capturedException = exception;
    };

    NSError *scriptErr = nil;
    NSString *rewrittenEntry = jsbay_rewrite_bare_specifiers(src);
    JSScript *script = [JSScript scriptOfType:JsBayJSScriptTypeModule
                                   withSource:rewrittenEntry
                                 andSourceURL:url
                             andBytecodeCache:nil
                             inVirtualMachine:ctx.virtualMachine
                                        error:&scriptErr];
    if (script == nil) {
        ctx.exceptionHandler = savedHandler;
        if (delegate) [delegate.entryOverrides removeObjectForKey:canonical];
        NSString *msg = scriptErr.localizedDescription ?: @"JSScript creation failed";
        if (out_error) *out_error = jsbay_dup_nsstring(msg);
        return 0;
    }

    JSValue *result = [ctx evaluateJSScript:script];

    // Clean up the entry override — we don't want stale sources to linger.
    if (delegate) [delegate.entryOverrides removeObjectForKey:canonical];

    if (capturedException != nil) {
        char *errMsg = jsbay_dup_exception_message(ctx, capturedException);
        ctx.exceptionHandler = savedHandler;
        if (out_error) *out_error = errMsg;
        return 0;
    }

    // evaluateJSScript on a module returns a Promise that resolves to the module namespace. For sync module graphs JSC drains microtasks before returning, so the Promise is already settled. Extract the settled state by wiring a tiny JS-side helper — calling `[thenFn callWithArguments:...]` from ObjC loses the `this` binding and throws "|this| is not a Promise", so we drive the attach via JS.
    char *resultStr = NULL;
    if (result && ![result isUndefined] && ![result isNull] && [result isObject]) {
        // Install the probe function on globalThis once per call — we use globalThis as a scratchpad rather than closures because bridging closures back out still loses `this` under some JSC versions.
        JSValue *probeFn = [ctx evaluateScript:
            @"(function(p) {"
            @"  var s = {state: 'pending', value: undefined};"
            @"  try {"
            @"    p.then(function(v){ s.state='fulfilled'; s.value=v; },"
            @"           function(v){ s.state='rejected';  s.value=v; });"
            @"  } catch (e) { s.state='rejected'; s.value=e; }"
            @"  return s;"
            @"})"];
        if (probeFn && [probeFn isObject]) {
            JSValue *state = [probeFn callWithArguments:@[ result ]];
            if (state && [state isObject]) {
                JSValue *st = state[@"state"];
                NSString *stName = [st toString];
                JSValue *val = state[@"value"];
                if ([stName isEqualToString:@"rejected"]) {
                    char *errMsg = jsbay_dup_exception_message(ctx, val);
                    ctx.exceptionHandler = savedHandler;
                    if (out_error) *out_error = errMsg;
                    return 0;
                }
                if ([stName isEqualToString:@"fulfilled"] &&
                    val && ![val isUndefined] && ![val isNull]) {
                    // For modules, val is the namespace object — don't stringify (side-effects on globalThis are the test harness contract).
                }
            }
        }
    } else if (result && ![result isUndefined] && ![result isNull]) {
        resultStr = jsbay_stringify_value(ctx, result);
    }

    ctx.exceptionHandler = savedHandler;
    if (out_result) *out_result = resultStr;
    return 1;
}

int jsbay_jsc_import_module(JSGlobalContextRef c_ctx,
                          const char *specifier,
                          char **out_result,
                          char **out_error) {
    if (out_result) *out_result = NULL;
    if (out_error) *out_error = NULL;
    if (c_ctx == NULL || specifier == NULL) {
        if (out_error) *out_error = jsbay_dup_cstr("null context or specifier");
        return 0;
    }

    // Build a one-line entry module that imports the specifier via a namespace import, forcing JSC's resolver to go through the delegate.
    NSMutableString *escaped = [NSMutableString string];
    for (const char *p = specifier; *p; ++p) {
        unsigned char c = (unsigned char)*p;
        switch (c) {
            case '\\': [escaped appendString:@"\\\\"]; break;
            case '\'': [escaped appendString:@"\\'"]; break;
            case '\n': [escaped appendString:@"\\n"]; break;
            case '\r': [escaped appendString:@"\\r"]; break;
            default:
                if (c < 0x20) {
                    [escaped appendFormat:@"\\x%02x", c];
                } else {
                    [escaped appendFormat:@"%c", c];
                }
                break;
        }
    }
    NSString *shim = [NSString stringWithFormat:@"import * as ns from '%@';\n",
                                                 escaped];
    const char *shim_c = [shim UTF8String] ?: "";
    size_t shim_len = strlen(shim_c);
    return jsbay_jsc_eval_module(c_ctx, shim_c, shim_len, "<entry>",
                               out_result, out_error);
}
