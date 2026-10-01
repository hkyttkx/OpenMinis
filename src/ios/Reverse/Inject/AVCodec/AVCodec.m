/*
 * AVCodec.m — 通用 Hook 引擎
 *
 * 功能：通过 ObjC runtime 方法替换实现 JSON 驱动的 hook 系统
 * 编译：-fno-objc-arc -dynamiclib -framework Foundation -lobjc
 *
 * 支持全部 6 种 HookType：
 *   1. methodSwizzle   — 方法替换，完全自定义行为
 *   2. flexOverride    — 覆盖返回值和参数，精准控制
 *   3. modifyProperty  — 执行原方法后修改对象属性
 *   4. returnConstant  — 直接返回固定值，跳过原方法
 *   5. blockMethod     — 阻止方法执行，方法体置空
 *   6. logMethod       — 记录方法调用和返回值
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <signal.h>
#import <syslog.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <pthread.h>
#import <stdatomic.h>
#import <Block.h>

#pragma mark - ========== 模板 Section 声明 ==========

__attribute__((section("__DATA,__avc_cfg_a")))
static char kAVCCfgA[1024] = "@@AVC_CFG_A@@";

__attribute__((section("__DATA,__avc_cfg_b")))
static char kAVCCfgB[65536] = "@@AVC_CFG_B@@";

__attribute__((section("__DATA,__avc_cfg_c")))
static char kAVCCfgC[64] = "@@AVC_CFG_C@@";

#pragma mark - ========== 全局状态 ==========

static NSMutableDictionary *gOrigIMPs = nil;
static dispatch_queue_t gOrigIMPsQueue = NULL;
static _Atomic int gInitState = 0;

#pragma mark - ========== 工具函数 ==========

// ══════════════════════════════════════════════════════════════════
//  日志开关
//
//  默认**静默**。原因：引擎原本每条 hook 都会 syslog 一次（实测 40 处），
//  日志前缀特征明显，`log stream` 一搜即中，等于自己报出「本进程被注入了」。
//
//  但日志是排查问题的唯一手段（前几轮全靠它定位 bug），所以保留开关：
//  编译时加 -DFUCK_VERBOSE=1 即可恢复全部输出。
// ══════════════════════════════════════════════════════════════════
#ifndef FUCK_VERBOSE
#define FUCK_VERBOSE 0
#endif

#if FUCK_VERBOSE
#define FUCKLOG(...) syslog(LOG_ERR, __VA_ARGS__)
#else
#define FUCKLOG(...) do {} while (0)
#endif

static int ios_major_version(void) {
    char buf[64] = {0};
    size_t len = sizeof(buf);
    if (sysctlbyname("kern.osproductversion", buf, &len, NULL, 0) == 0) {
        int v = 0;
        sscanf(buf, "%d", &v);
        return v;
    }
    return 15;
}

static int parseIntValue(NSString *str) {
    if (!str) return 0;
    if ([str caseInsensitiveCompare:@"true"] == NSOrderedSame ||
        [str caseInsensitiveCompare:@"yes"] == NSOrderedSame) {
        return 1;
    }
    if ([str caseInsensitiveCompare:@"false"] == NSOrderedSame ||
        [str caseInsensitiveCompare:@"no"] == NSOrderedSame) {
        return 0;
    }
    return [str intValue];
}

static NSString *impKey(NSString *className, NSString *methodName, BOOL isClassMethod) {
    return [NSString stringWithFormat:@"%@|%@|%d", className, methodName, (int)isClassMethod];
}

#pragma mark - ========== Crash Guard ==========

static void crash_guard_handler(int sig) {
    FUCKLOG("[ 捕获信号 %d，抑制崩溃", sig);
}

static void install_crash_guard(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = crash_guard_handler;
    sa.sa_flags = SA_RESETHAND;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS,  &sa, NULL);
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
    sigaction(SIGPIPE, &sa, NULL);
}

#pragma mark - ========== 返回类型字符获取 ==========

static char getReturnTypeChar(Method method) {
    char *returnTypeStr = method_copyReturnType(method);
    char retChar = returnTypeStr ? returnTypeStr[0] : 'v';
    if (returnTypeStr) free(returnTypeStr);
    return retChar;
}

#pragma mark - ========== createReturnIMP ==========

static IMP createReturnIMP(NSString *value, char retType) {
    id block = nil;

    switch (retType) {
        case 'B': {
            BOOL v = [value boolValue] & 1;
            block = Block_copy(^BOOL(id self) { return v; });
            break;
        }
        case 'c':
        case 'C': {
            BOOL v = parseIntValue(value) != 0;
            block = Block_copy(^BOOL(id self) { return v; });
            break;
        }
        case 'i':
        case 'I': {
            int v = [value intValue];
            block = Block_copy(^int(id self) { return v; });
            break;
        }
        case 'q':
        case 'Q': {
            long long v = [value longLongValue];
            block = Block_copy(^long long(id self) { return v; });
            break;
        }
        case 'l':
        case 'L': {
            long v = (long)[value longLongValue];
            block = Block_copy(^long(id self) { return v; });
            break;
        }
        case 's':
        case 'S': {
            short v = (short)[value intValue];
            block = Block_copy(^short(id self) { return v; });
            break;
        }
        case 'f': {
            float v = [value floatValue];
            block = Block_copy(^float(id self) { return v; });
            break;
        }
        case 'd': {
            double v = [value doubleValue];
            block = Block_copy(^double(id self) { return v; });
            break;
        }
        case '@': {
            if ([value isEqualToString:@"nil"] || [value isEqualToString:@"(null)"]) {
                block = Block_copy(^id(id self) { return nil; });
            } else {
                NSString *v = [value retain];
                block = Block_copy(^id(id self) { return v; });
            }
            break;
        }
        case 'v':
        default: {
            block = Block_copy(^(id self) { });
            break;
        }
    }

    IMP imp = imp_implementationWithBlock(block);
    return imp;
}

#pragma mark - ========== createBlockIMP ==========

/* blockMethod: 阻止方法执行，根据返回类型返回零值 */
static IMP createBlockIMP(char retType) {
    id block = nil;

    switch (retType) {
        case 'B':
        case 'c':
        case 'C': {
            block = Block_copy(^BOOL(id self) { return NO; });
            break;
        }
        case 'i':
        case 'I': {
            block = Block_copy(^int(id self) { return 0; });
            break;
        }
        case 'q':
        case 'Q': {
            block = Block_copy(^long long(id self) { return 0LL; });
            break;
        }
        case 'l':
        case 'L': {
            block = Block_copy(^long(id self) { return 0L; });
            break;
        }
        case 's':
        case 'S': {
            block = Block_copy(^short(id self) { return 0; });
            break;
        }
        case 'f': {
            block = Block_copy(^float(id self) { return 0.0f; });
            break;
        }
        case 'd': {
            block = Block_copy(^double(id self) { return 0.0; });
            break;
        }
        case '@': {
            block = Block_copy(^id(id self) { return nil; });
            break;
        }
        case 'v':
        default: {
            block = Block_copy(^(id self) { });
            break;
        }
    }

    return imp_implementationWithBlock(block);
}

#pragma mark - ========== createLogIMP ==========

/* logMethod: 调用原方法并记录调用信息和返回值，支持带参数的方法 */
static IMP createLogIMP(NSValue *origIMPValue, NSString *className, NSString *methodName,
                         BOOL isClassMethod, char retType, Method method) {
    [origIMPValue retain];
    [className retain];
    [methodName retain];

    unsigned int argCount = method_getNumberOfArguments(method);

    /* 无额外参数的方法，直接用简单 block 调用 */
    if (argCount <= 2) {
        id block = nil;
        switch (retType) {
            case 'B':
            case 'c':
            case 'C': {
                block = Block_copy(^BOOL(id self) {
                    IMP origIMP = (IMP)[origIMPValue pointerValue];
                    SEL sel = NSSelectorFromString(methodName);
                    BOOL result = ((BOOL (*)(id, SEL))origIMP)(self, sel);
                    FUCKLOG("[[Log] %s%s.%s → %s",
                           isClassMethod ? "+" : "-",
                           [className UTF8String], [methodName UTF8String],
                           result ? "YES" : "NO");
                    return result;
                });
                break;
            }
            case 'i':
            case 'I': {
                block = Block_copy(^int(id self) {
                    IMP origIMP = (IMP)[origIMPValue pointerValue];
                    SEL sel = NSSelectorFromString(methodName);
                    int result = ((int (*)(id, SEL))origIMP)(self, sel);
                    FUCKLOG("[[Log] %s%s.%s → %d",
                           isClassMethod ? "+" : "-",
                           [className UTF8String], [methodName UTF8String], result);
                    return result;
                });
                break;
            }
            case 'q':
            case 'Q': {
                block = Block_copy(^long long(id self) {
                    IMP origIMP = (IMP)[origIMPValue pointerValue];
                    SEL sel = NSSelectorFromString(methodName);
                    long long result = ((long long (*)(id, SEL))origIMP)(self, sel);
                    FUCKLOG("[[Log] %s%s.%s → %lld",
                           isClassMethod ? "+" : "-",
                           [className UTF8String], [methodName UTF8String], result);
                    return result;
                });
                break;
            }
            case 'f': {
                block = Block_copy(^float(id self) {
                    IMP origIMP = (IMP)[origIMPValue pointerValue];
                    SEL sel = NSSelectorFromString(methodName);
                    float result = ((float (*)(id, SEL))origIMP)(self, sel);
                    FUCKLOG("[[Log] %s%s.%s → %f",
                           isClassMethod ? "+" : "-",
                           [className UTF8String], [methodName UTF8String], result);
                    return result;
                });
                break;
            }
            case 'd': {
                block = Block_copy(^double(id self) {
                    IMP origIMP = (IMP)[origIMPValue pointerValue];
                    SEL sel = NSSelectorFromString(methodName);
                    double result = ((double (*)(id, SEL))origIMP)(self, sel);
                    FUCKLOG("[[Log] %s%s.%s → %f",
                           isClassMethod ? "+" : "-",
                           [className UTF8String], [methodName UTF8String], result);
                    return result;
                });
                break;
            }
            case '@': {
                block = Block_copy(^id(id self) {
                    IMP origIMP = (IMP)[origIMPValue pointerValue];
                    SEL sel = NSSelectorFromString(methodName);
                    id result = ((id (*)(id, SEL))origIMP)(self, sel);
                    FUCKLOG("[[Log] %s%s.%s → %s",
                           isClassMethod ? "+" : "-",
                           [className UTF8String], [methodName UTF8String],
                           result ? [[result description] UTF8String] : "(nil)");
                    return result;
                });
                break;
            }
            case 'v':
            default: {
                block = Block_copy(^(id self) {
                    IMP origIMP = (IMP)[origIMPValue pointerValue];
                    SEL sel = NSSelectorFromString(methodName);
                    ((void (*)(id, SEL))origIMP)(self, sel);
                    FUCKLOG("[[Log] %s%s.%s (void)",
                           isClassMethod ? "+" : "-",
                           [className UTF8String], [methodName UTF8String]);
                });
                break;
            }
        }
        return imp_implementationWithBlock(block);
    }

    /* 有额外参数的方法，使用 NSInvocation 转发所有参数 */
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    [sig retain];
    unsigned int capturedArgCount = argCount;
    char capturedRetType = retType;

    id block = Block_copy(^(id self, ...) {
        if (!origIMPValue) return;
        IMP origIMP = (IMP)[origIMPValue pointerValue];
        SEL sel = NSSelectorFromString(methodName);

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:self];
        [inv setSelector:sel];

        /* 透传所有参数 */
        va_list args;
        va_start(args, self);
        for (unsigned int i = 2; i < capturedArgCount; i++) {
            const char *argType = [sig getArgumentTypeAtIndex:i];
            switch (argType[0]) {
                case '@':
                case '#': {
                    id objArg = va_arg(args, id);
                    [inv setArgument:&objArg atIndex:i];
                    break;
                }
                case 'q':
                case 'Q': {
                    long long llArg = va_arg(args, long long);
                    [inv setArgument:&llArg atIndex:i];
                    break;
                }
                case 'd': {
                    double dArg = va_arg(args, double);
                    [inv setArgument:&dArg atIndex:i];
                    break;
                }
                case 'f': {
                    double dArg = va_arg(args, double);
                    float fVal = (float)dArg;
                    [inv setArgument:&fVal atIndex:i];
                    break;
                }
                default: {
                    int iArg = va_arg(args, int);
                    if (argType[0] == 'B' || argType[0] == 'c' || argType[0] == 'C') {
                        BOOL bVal = (iArg != 0);
                        [inv setArgument:&bVal atIndex:i];
                    } else if (argType[0] == 's' || argType[0] == 'S') {
                        short sVal = (short)iArg;
                        [inv setArgument:&sVal atIndex:i];
                    } else {
                        [inv setArgument:&iArg atIndex:i];
                    }
                    break;
                }
            }
        }
        va_end(args);

        [inv invokeUsingIMP:origIMP];

        /* 记录返回值 */
        switch (capturedRetType) {
            case 'B':
            case 'c':
            case 'C': {
                BOOL rv; [inv getReturnValue:&rv];
                FUCKLOG("[[Log] %s%s.%s → %s",
                       isClassMethod ? "+" : "-",
                       [className UTF8String], [methodName UTF8String],
                       rv ? "YES" : "NO");
                break;
            }
            case 'i':
            case 'I': {
                int rv; [inv getReturnValue:&rv];
                FUCKLOG("[[Log] %s%s.%s → %d",
                       isClassMethod ? "+" : "-",
                       [className UTF8String], [methodName UTF8String], rv);
                break;
            }
            case 'q':
            case 'Q': {
                long long rv; [inv getReturnValue:&rv];
                FUCKLOG("[[Log] %s%s.%s → %lld",
                       isClassMethod ? "+" : "-",
                       [className UTF8String], [methodName UTF8String], rv);
                break;
            }
            case '@': {
                id rv = nil; [inv getReturnValue:&rv];
                FUCKLOG("[[Log] %s%s.%s → %s",
                       isClassMethod ? "+" : "-",
                       [className UTF8String], [methodName UTF8String],
                       rv ? [[rv description] UTF8String] : "(nil)");
                break;
            }
            case 'v': {
                FUCKLOG("[[Log] %s%s.%s (void)",
                       isClassMethod ? "+" : "-",
                       [className UTF8String], [methodName UTF8String]);
                break;
            }
            default: {
                FUCKLOG("[[Log] %s%s.%s (type=%c)",
                       isClassMethod ? "+" : "-",
                       [className UTF8String], [methodName UTF8String], capturedRetType);
                break;
            }
        }
    });

    return imp_implementationWithBlock(block);
}

#pragma mark - ========== createMethodSwizzleIMP ==========

/* methodSwizzle: 替换原方法实现，记录日志 + 调用原方法 + 可选返回值覆盖，支持带参数方法 */
static IMP createMethodSwizzleIMP(NSValue *origIMPValue, NSString *className, NSString *methodName,
                                   BOOL isClassMethod, char retType, NSString *returnValue, Method method) {
    [origIMPValue retain];
    [className retain];
    [methodName retain];
    if (returnValue) [returnValue retain];

    BOOL hasReturnOverride = (returnValue != nil && returnValue.length > 0);
    unsigned int argCount = method_getNumberOfArguments(method);

    /* 无额外参数的简单方法 */
    if (argCount <= 2) {
        if (retType == 'v') {
            id block = Block_copy(^(id self) {
                FUCKLOG("[[Swizzle] %s%s.%s called",
                       isClassMethod ? "+" : "-",
                       [className UTF8String], [methodName UTF8String]);
                IMP origIMP = (IMP)[origIMPValue pointerValue];
                SEL sel = NSSelectorFromString(methodName);
                ((void (*)(id, SEL))origIMP)(self, sel);
            });
            return imp_implementationWithBlock(block);
        }
        if (hasReturnOverride) {
            /* 有返回值覆盖：记录日志 + 返回固定值（不调原方法） */
            return createReturnIMP(returnValue, retType);
        }
        /* 无返回值覆盖：记录日志 + 调用原方法 + 返回原始结果 */
        return createLogIMP(origIMPValue, className, methodName, isClassMethod, retType, method);
    }

    /* 有额外参数的方法，使用 NSInvocation 转发 */
    NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    [sig retain];
    unsigned int capturedArgCount = argCount;
    char capturedRetType = retType;
    BOOL capturedHasReturn = hasReturnOverride;

    id block = Block_copy(^(id self, ...) {
        FUCKLOG("[[Swizzle] %s%s.%s called (args=%u)",
               isClassMethod ? "+" : "-",
               [className UTF8String], [methodName UTF8String], capturedArgCount - 2);

        if (!origIMPValue) return;
        IMP origIMP = (IMP)[origIMPValue pointerValue];
        SEL sel = NSSelectorFromString(methodName);

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:self];
        [inv setSelector:sel];

        va_list args;
        va_start(args, self);
        for (unsigned int i = 2; i < capturedArgCount; i++) {
            const char *argType = [sig getArgumentTypeAtIndex:i];
            switch (argType[0]) {
                case '@':
                case '#': {
                    id objArg = va_arg(args, id);
                    [inv setArgument:&objArg atIndex:i];
                    break;
                }
                case 'q':
                case 'Q': {
                    long long llArg = va_arg(args, long long);
                    [inv setArgument:&llArg atIndex:i];
                    break;
                }
                case 'd': {
                    double dArg = va_arg(args, double);
                    [inv setArgument:&dArg atIndex:i];
                    break;
                }
                case 'f': {
                    double dArg = va_arg(args, double);
                    float fVal = (float)dArg;
                    [inv setArgument:&fVal atIndex:i];
                    break;
                }
                default: {
                    int iArg = va_arg(args, int);
                    if (argType[0] == 'B' || argType[0] == 'c' || argType[0] == 'C') {
                        BOOL bVal = (iArg != 0);
                        [inv setArgument:&bVal atIndex:i];
                    } else if (argType[0] == 's' || argType[0] == 'S') {
                        short sVal = (short)iArg;
                        [inv setArgument:&sVal atIndex:i];
                    } else {
                        [inv setArgument:&iArg atIndex:i];
                    }
                    break;
                }
            }
        }
        va_end(args);

        [inv invokeUsingIMP:origIMP];

        /* 可选覆盖返回值 */
        if (capturedHasReturn && capturedRetType != 'v') {
            switch (capturedRetType) {
                case 'B':
                case 'c':
                case 'C': {
                    BOOL v = parseIntValue(returnValue) != 0;
                    [inv setReturnValue:&v];
                    break;
                }
                case 'i':
                case 'I': {
                    int v = [returnValue intValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case 'q':
                case 'Q': {
                    long long v = [returnValue longLongValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case 's':
                case 'S': {
                    short v = (short)[returnValue intValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case 'f': {
                    float v = [returnValue floatValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case 'd': {
                    double v = [returnValue doubleValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case '@': {
                    if ([returnValue isEqualToString:@"nil"] || [returnValue isEqualToString:@"(null)"]) {
                        id v = nil;
                        [inv setReturnValue:&v];
                    } else {
                        id v = returnValue;
                        [inv setReturnValue:&v];
                    }
                    break;
                }
                default:
                    break;
            }
        }
    });

    return imp_implementationWithBlock(block);
}

#pragma mark - ========== createInvocationIMP ==========

static IMP createInvocationIMP(NSMethodSignature *sig,
                                unsigned int argCount,
                                char retType,
                                NSValue *origIMPValue,
                                NSString *methodName,
                                NSDictionary *argOverrides,
                                NSString *returnValue) {
    BOOL hasReturnOverride = (returnValue != nil);

    [sig retain];
    [origIMPValue retain];
    [methodName retain];
    [argOverrides retain];
    if (returnValue) [returnValue retain];

    if (argCount <= 2 && !hasReturnOverride) {
        id block = Block_copy(^(id self) {
            if (!origIMPValue) return;
            IMP origIMP = (IMP)[origIMPValue pointerValue];
            SEL sel = NSSelectorFromString(methodName);
            ((void (*)(id, SEL))origIMP)(self, sel);
        });
        return imp_implementationWithBlock(block);
    }

    unsigned int capturedArgCount = argCount;
    char capturedRetType = retType;
    BOOL capturedHasReturn = hasReturnOverride;

    id block = Block_copy(^(id self, ...) {
        if (!origIMPValue) return;
        IMP origIMP = (IMP)[origIMPValue pointerValue];
        SEL sel = NSSelectorFromString(methodName);

        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:self];
        [inv setSelector:sel];

        va_list args;
        va_start(args, self);
        for (unsigned int i = 2; i < capturedArgCount; i++) {
            int overrideIndex = (int)i - 2;
            const char *argType = [sig getArgumentTypeAtIndex:i];
            NSDictionary *override = argOverrides[@(overrideIndex)];

            switch (argType[0]) {
                case '@':
                case '#': {
                    id objArg = va_arg(args, id);
                    if (override && ![override[@"passThrough"] boolValue]) {
                        id overrideVal = override[@"value"] ?: @"";
                        [inv setArgument:&overrideVal atIndex:i];
                    } else {
                        [inv setArgument:&objArg atIndex:i];
                    }
                    break;
                }
                case 'q':
                case 'Q': {
                    long long llArg = va_arg(args, long long);
                    if (override && ![override[@"passThrough"] boolValue]) {
                        long long overrideVal = [override[@"value"] longLongValue];
                        [inv setArgument:&overrideVal atIndex:i];
                    } else {
                        [inv setArgument:&llArg atIndex:i];
                    }
                    break;
                }
                case 'd': {
                    double dArg = va_arg(args, double);
                    if (override && ![override[@"passThrough"] boolValue]) {
                        double overrideVal = [override[@"value"] doubleValue];
                        [inv setArgument:&overrideVal atIndex:i];
                    } else {
                        [inv setArgument:&dArg atIndex:i];
                    }
                    break;
                }
                case 'f': {
                    double dArg = va_arg(args, double);
                    if (override && ![override[@"passThrough"] boolValue]) {
                        float overrideVal = [override[@"value"] floatValue];
                        [inv setArgument:&overrideVal atIndex:i];
                    } else {
                        float fVal = (float)dArg;
                        [inv setArgument:&fVal atIndex:i];
                    }
                    break;
                }
                default: {
                    int iArg = va_arg(args, int);
                    if (override && ![override[@"passThrough"] boolValue]) {
                        NSString *valStr = override[@"value"] ?: @"0";
                        int overrideVal = parseIntValue(valStr);
                        if (argType[0] == 'B' || argType[0] == 'c' || argType[0] == 'C') {
                            BOOL bVal = (overrideVal != 0);
                            [inv setArgument:&bVal atIndex:i];
                        } else if (argType[0] == 's' || argType[0] == 'S') {
                            short sVal = (short)overrideVal;
                            [inv setArgument:&sVal atIndex:i];
                        } else {
                            [inv setArgument:&overrideVal atIndex:i];
                        }
                    } else {
                        if (argType[0] == 'B' || argType[0] == 'c' || argType[0] == 'C') {
                            BOOL bVal = (iArg != 0);
                            [inv setArgument:&bVal atIndex:i];
                        } else if (argType[0] == 's' || argType[0] == 'S') {
                            short sVal = (short)iArg;
                            [inv setArgument:&sVal atIndex:i];
                        } else {
                            [inv setArgument:&iArg atIndex:i];
                        }
                    }
                    break;
                }
            }
        }
        va_end(args);

        [inv invokeUsingIMP:origIMP];

        if (capturedHasReturn) {
            switch (capturedRetType) {
                case 'B':
                case 'c':
                case 'C': {
                    BOOL v = parseIntValue(returnValue) != 0;
                    [inv setReturnValue:&v];
                    break;
                }
                case 'i':
                case 'I': {
                    int v = [returnValue intValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case 'q':
                case 'Q': {
                    long long v = [returnValue longLongValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case 's':
                case 'S': {
                    short v = (short)[returnValue intValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case 'f': {
                    float v = [returnValue floatValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case 'd': {
                    double v = [returnValue doubleValue];
                    [inv setReturnValue:&v];
                    break;
                }
                case '@': {
                    if ([returnValue isEqualToString:@"nil"] || [returnValue isEqualToString:@"(null)"]) {
                        id v = nil;
                        [inv setReturnValue:&v];
                    } else {
                        id v = returnValue;
                        [inv setReturnValue:&v];
                    }
                    break;
                }
                default:
                    break;
            }
        }
    });

    return imp_implementationWithBlock(block);
}

#pragma mark - ========== resolveHookValue ==========

/* 解析 hookValue 字符串，兼容多种格式 */
static NSString *resolveHookValue(NSString *raw) {
    if (!raw || raw.length == 0) return @"1";

    /* 兼容 "BOOL YES" / "BOOL NO" 旧格式 */
    if ([raw hasPrefix:@"BOOL "]) {
        NSString *val = [raw substringFromIndex:5];
        if ([val isEqualToString:@"YES"]) return @"1";
        if ([val isEqualToString:@"NO"]) return @"0";
        return val;
    }
    /* 兼容 "id nil" 格式 */
    if ([raw hasPrefix:@"id "]) {
        return [raw substringFromIndex:3];
    }
    /* 兼容 ReturnValuePreset rawValues */
    if ([raw isEqualToString:@"TRUE"]) return @"1";
    if ([raw isEqualToString:@"FALSE"]) return @"0";
    if ([raw isEqualToString:@"pass-through"]) return nil; /* nil 表示透传 */
    if ([raw hasPrefix:@"custom:"]) return [raw substringFromIndex:7];

    return raw;
}

#pragma mark - ========== resolveKVCValue ==========

/* 将字符串值转换为 KVC 兼容的 NSObject（NSNumber / NSString / nil） */
static id resolveKVCValue(NSString *value) {
    if (!value || value.length == 0) return nil;
    if ([value isEqualToString:@"nil"] || [value isEqualToString:@"(null)"]) return nil;

    /* BOOL */
    if ([value caseInsensitiveCompare:@"YES"] == NSOrderedSame ||
        [value caseInsensitiveCompare:@"TRUE"] == NSOrderedSame) {
        return @YES;
    }
    if ([value caseInsensitiveCompare:@"NO"] == NSOrderedSame ||
        [value caseInsensitiveCompare:@"FALSE"] == NSOrderedSame) {
        return @NO;
    }

    /* 数字（整数和浮点） */
    NSCharacterSet *numChars = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"];
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length > 0 && [numChars characterIsMember:[trimmed characterAtIndex:0]]) {
        if ([trimmed containsString:@"."]) {
            return @([trimmed doubleValue]);
        }
        return @([trimmed longLongValue]);
    }

    /* 其他当作字符串 */
    return value;
}

#pragma mark - ========== applyHook ==========

static void applyHook(NSDictionary *config) {
    NSString *className     = config[@"className"];
    NSString *methodName    = config[@"methodName"];
    BOOL isClassMethod      = [config[@"isClassMethod"] boolValue];
    NSString *hookType      = config[@"hookType"];
    NSString *hookValue     = config[@"hookValue"] ?: @"";
    NSString *propertyKeyPath = config[@"propertyKeyPath"] ?: @"";
    NSArray *overrides      = config[@"overrides"] ?: @[];
    BOOL enabled            = config[@"enabled"] ? [config[@"enabled"] boolValue] : YES;
    NSString *returnValue   = config[@"returnValue"];

    if (!className || !methodName || !hookType || !enabled) return;

    Class cls = NSClassFromString(className);
    if (!cls) {
        FUCKLOG("[ 类不存在: %s", [className UTF8String]);
        return;
    }

    SEL sel = NSSelectorFromString(methodName);
    Method method = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!method) {
        FUCKLOG("[ 方法不存在: %s.%s", [className UTF8String], [methodName UTF8String]);
        return;
    }

    /* 保存原始 IMP */
    NSString *key = impKey(className, methodName, isClassMethod);
    dispatch_sync(gOrigIMPsQueue, ^{
        if (!gOrigIMPs[key]) {
            IMP origIMP = method_getImplementation(method);
            gOrigIMPs[key] = [NSValue valueWithPointer:(void *)origIMP];
        }
    });

    __block NSValue *origIMPValue = nil;
    dispatch_sync(gOrigIMPsQueue, ^{
        origIMPValue = [gOrigIMPs[key] retain];
    });

    char retChar = getReturnTypeChar(method);
    IMP newIMP = NULL;

    /* ===== 根据 hookType 分发 ===== */

    if ([hookType isEqualToString:@"Return Constant"] || [hookType isEqualToString:@"returnConstant"]) {
        /* returnConstant: 直接返回固定值 */
        NSString *val = resolveHookValue(hookValue);
        if (!val) val = resolveHookValue(returnValue);
        if (!val) val = @"1";
        newIMP = createReturnIMP(val, retChar);

    } else if ([hookType isEqualToString:@"Block Method"] || [hookType isEqualToString:@"blockMethod"]) {
        /* blockMethod: 阻止方法执行 */
        newIMP = createBlockIMP(retChar);

    } else if ([hookType isEqualToString:@"Log Method"] || [hookType isEqualToString:@"logMethod"]) {
        /* logMethod: 记录方法调用 */
        newIMP = createLogIMP(origIMPValue, className, methodName, isClassMethod, retChar, method);

    } else if ([hookType isEqualToString:@"Method Swizzle"] || [hookType isEqualToString:@"methodSwizzle"]) {
        /* methodSwizzle: 方法替换 */
        NSString *val = resolveHookValue(hookValue);
        if (!val) val = resolveHookValue(returnValue);
        newIMP = createMethodSwizzleIMP(origIMPValue, className, methodName, isClassMethod, retChar, val, method);

    } else if ([hookType isEqualToString:@"FLEX Override"] || [hookType isEqualToString:@"flexOverride"] ||
               [hookType isEqualToString:@"flex"]) {
        /* flexOverride: 覆盖返回值和参数 */
        NSDictionary *returnOverride = nil;
        NSMutableDictionary *argOverrides = [[NSMutableDictionary alloc] init];

        for (NSDictionary *ovr in overrides) {
            if ([ovr[@"passThrough"] boolValue]) continue;
            int index = [ovr[@"index"] intValue];
            if (index == -1) {
                returnOverride = ovr;
            } else {
                argOverrides[@(index)] = ovr;
            }
        }

        BOOL hasReturnOverride = (returnOverride != nil) && (retChar != 'v');
        BOOL hasArgOverrides = ([argOverrides count] > 0);

        /* 如果没有 overrides 但有 hookValue/returnValue，当作简单返回值覆盖 */
        if (!hasReturnOverride && !hasArgOverrides) {
            NSString *val = resolveHookValue(hookValue);
            if (!val) val = resolveHookValue(returnValue);
            if (val && retChar != 'v') {
                newIMP = createReturnIMP(val, retChar);
            }
        } else if (hasReturnOverride && !hasArgOverrides) {
            NSString *val = returnOverride[@"value"] ?: @"";
            newIMP = createReturnIMP(val, retChar);
        } else if (hasArgOverrides) {
            NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
            unsigned int argCount = method_getNumberOfArguments(method);
            NSString *retVal = hasReturnOverride ? (returnOverride[@"value"] ?: @"") : nil;
            newIMP = createInvocationIMP(sig, argCount, retChar, origIMPValue, methodName, argOverrides, retVal);
        }

        [argOverrides release];

    } else if ([hookType isEqualToString:@"Modify Property"] || [hookType isEqualToString:@"modifyProperty"]) {
        /* modifyProperty: 执行原方法后修改属性 */
        unsigned int argCount = method_getNumberOfArguments(method);

        if (propertyKeyPath.length == 0) {
            FUCKLOG("[ modifyProperty 缺少 propertyKeyPath: %s.%s",
                   [className UTF8String], [methodName UTF8String]);
            [origIMPValue release];
            return;
        }

        /* 预解析 KVC 值：字符串 → NSNumber/NSString/nil */
        NSString *resolvedRaw = resolveHookValue(hookValue);
        if (!resolvedRaw) resolvedRaw = resolveHookValue(returnValue);
        id kvcValue = resolveKVCValue(resolvedRaw ?: @"");
        if (kvcValue) [kvcValue retain];

        [origIMPValue retain];
        [methodName retain];
        [propertyKeyPath retain];

        if (argCount <= 2) {
            id block = Block_copy(^(id self) {
                if (origIMPValue) {
                    IMP origIMP = (IMP)[origIMPValue pointerValue];
                    SEL s = NSSelectorFromString(methodName);
                    ((void (*)(id, SEL))origIMP)(self, s);
                }
                @try {
                    [self setValue:kvcValue forKeyPath:propertyKeyPath];
                } @catch (NSException *e) {
                    FUCKLOG("[ KVC 失败: %s", [[e reason] UTF8String]);
                }
            });
            newIMP = imp_implementationWithBlock(block);
        } else {
            NSMethodSignature *sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
            [sig retain];
            unsigned int capturedArgCount = argCount;

            id block = Block_copy(^(id self, ...) {
                if (!origIMPValue) return;
                IMP origIMP = (IMP)[origIMPValue pointerValue];
                SEL s = NSSelectorFromString(methodName);

                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:self];
                [inv setSelector:s];

                va_list args;
                va_start(args, self);
                for (unsigned int i = 2; i < capturedArgCount; i++) {
                    const char *argType = [sig getArgumentTypeAtIndex:i];
                    switch (argType[0]) {
                        case '@':
                        case '#': {
                            id objArg = va_arg(args, id);
                            [inv setArgument:&objArg atIndex:i];
                            break;
                        }
                        case 'q':
                        case 'Q': {
                            long long llArg = va_arg(args, long long);
                            [inv setArgument:&llArg atIndex:i];
                            break;
                        }
                        case 'd': {
                            double dArg = va_arg(args, double);
                            [inv setArgument:&dArg atIndex:i];
                            break;
                        }
                        case 'f': {
                            double dArg = va_arg(args, double);
                            float fVal = (float)dArg;
                            [inv setArgument:&fVal atIndex:i];
                            break;
                        }
                        default: {
                            int iArg = va_arg(args, int);
                            [inv setArgument:&iArg atIndex:i];
                            break;
                        }
                    }
                }
                va_end(args);

                [inv invokeUsingIMP:origIMP];

                @try {
                    [self setValue:kvcValue forKeyPath:propertyKeyPath];
                } @catch (NSException *e) {
                    FUCKLOG("[ KVC 失败: %s", [[e reason] UTF8String]);
                }
            });
            newIMP = imp_implementationWithBlock(block);
        }
    }

    /* 安装 hook */
    if (newIMP) {
        method_setImplementation(method, newIMP);
        FUCKLOG("[ Hook: %s.%s [%s]",
               [className UTF8String], [methodName UTF8String], [hookType UTF8String]);
    } else {
        FUCKLOG("[ 未能创建 IMP: %s.%s [%s]",
               [className UTF8String], [methodName UTF8String], [hookType UTF8String]);
    }

    [origIMPValue release];
}

#pragma mark - ========== applyAllHooks ==========

static void applyAllHooks(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&gInitState, &expected, 1)) {
        FUCKLOG("[ 初始化已在进行中 (state=%d)", expected);
        return;
    }

    @autoreleasepool {
        gOrigIMPs = [[NSMutableDictionary alloc] init];
        gOrigIMPsQueue = dispatch_queue_create("com.avcodec.session", DISPATCH_QUEUE_SERIAL);

        NSString *configStr = [NSString stringWithUTF8String:kAVCCfgB];
        if (!configStr || [configStr length] == 0 || [configStr hasPrefix:@"@@"]) {
            FUCKLOG("[ 无内嵌 Hook 配置");
            atomic_store(&gInitState, 2);
            return;
        }

        NSData *data = [configStr dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];

        if (error || ![parsed isKindOfClass:[NSArray class]]) {
            FUCKLOG("[ 配置解析失败: %s",
                   error ? [[error localizedDescription] UTF8String] : "非数组格式");
            atomic_store(&gInitState, 2);
            return;
        }

        NSArray *hooks = (NSArray *)parsed;
        FUCKLOG("[ 读取到 %lu 个 Hook 配置", (unsigned long)[hooks count]);

        for (NSDictionary *config in hooks) {
            @try {
                applyHook(config);
            } @catch (NSException *e) {
                FUCKLOG("[ Hook 异常: %s", [[e reason] UTF8String]);
            }
        }

        FUCKLOG("[ Hook 应用完成");
        atomic_store(&gInitState, 2);
    }
}

#pragma mark - ========== Copyright Alert ==========

static void showCopyrightAlertOnMainThread(NSString *message) {
    Class UIAlertControllerClass = NSClassFromString(@"UIAlertController");
    Class UIAlertActionClass = NSClassFromString(@"UIAlertAction");
    Class UIApplicationClass = NSClassFromString(@"UIApplication");

    if (!UIAlertControllerClass || !UIAlertActionClass || !UIApplicationClass) {
        FUCKLOG("[ UIKit 类不可用，跳过弹窗");
        return;
    }

    id app = ((id (*)(id, SEL))objc_msgSend)(UIApplicationClass, NSSelectorFromString(@"sharedApplication"));
    if (!app) return;

    id keyWindow = nil;

    if ([app respondsToSelector:NSSelectorFromString(@"connectedScenes")]) {
        NSSet *scenes = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"connectedScenes"));
        for (id scene in scenes) {
            Class UIWindowSceneClass = NSClassFromString(@"UIWindowScene");
            if (!UIWindowSceneClass || ![scene isKindOfClass:UIWindowSceneClass]) continue;

            if ([scene respondsToSelector:NSSelectorFromString(@"activationState")]) {
                NSInteger state = ((NSInteger (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"activationState"));
                if (state != 0) continue;
            }

            if ([scene respondsToSelector:NSSelectorFromString(@"windows")]) {
                NSArray *windows = ((id (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"windows"));
                for (id window in windows) {
                    BOOL isKey = ((BOOL (*)(id, SEL))objc_msgSend)(window, NSSelectorFromString(@"isKeyWindow"));
                    if (isKey) {
                        keyWindow = window;
                        break;
                    }
                }
            }
            if (keyWindow) break;
        }
    }

    if (!keyWindow) {
        if ([app respondsToSelector:NSSelectorFromString(@"keyWindow")]) {
            keyWindow = ((id (*)(id, SEL))objc_msgSend)(app, NSSelectorFromString(@"keyWindow"));
        }
    }

    if (!keyWindow) return;

    id rootVC = ((id (*)(id, SEL))objc_msgSend)(keyWindow, NSSelectorFromString(@"rootViewController"));
    while (rootVC) {
        id presented = ((id (*)(id, SEL))objc_msgSend)(rootVC, NSSelectorFromString(@"presentedViewController"));
        if (presented) {
            rootVC = presented;
        } else {
            break;
        }
    }

    if (!rootVC) return;

    id alert = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
        UIAlertControllerClass,
        NSSelectorFromString(@"alertControllerWithTitle:message:preferredStyle:"),
        message, nil, (NSInteger)1
    );

    id action = ((id (*)(id, SEL, id, NSInteger, id))objc_msgSend)(
        UIAlertActionClass,
        NSSelectorFromString(@"actionWithTitle:style:handler:"),
        @"\u786E\u5B9A", (NSInteger)0, nil
    );
    ((void (*)(id, SEL, id))objc_msgSend)(alert, NSSelectorFromString(@"addAction:"), action);

    ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(
        rootVC,
        NSSelectorFromString(@"presentViewController:animated:completion:"),
        alert, YES, nil
    );
}

static void showCopyrightAlert(NSString *message) {
    if (!message || [message length] == 0 || [message hasPrefix:@"@@"]) return;

    [message retain];

    int ver = ios_major_version();
    double alertDelay = (ver >= 16) ? 8.0 : 6.0;

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(alertDelay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    showCopyrightAlertOnMainThread(message);
                } @catch (NSException *e) {
                    FUCKLOG("[ 弹窗异常: %s", [[e reason] UTF8String]);
                }
            });
        }
    );
}

#pragma mark - ========== Constructor ==========

__attribute__((constructor))
static void AVCodecInit(void) {
    install_crash_guard();

    FUCKLOG("[ constructor pid=%d thread=%s",
           getpid(), pthread_main_np() ? "main" : "remote");

    NSString *copyright = [NSString stringWithUTF8String:kAVCCfgA];
    if (copyright && [copyright length] > 0 && ![copyright hasPrefix:@"@@"]) {
        FUCKLOG("[ ========================================");
        FUCKLOG("[ %s", [copyright UTF8String]);
        FUCKLOG("[ ========================================");
        showCopyrightAlert(copyright);
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    FUCKLOG("[ 已加载 | 目标: %s",
           bundleId ? [bundleId UTF8String] : "(null)");

    /* 读取自定义延迟（优先使用内嵌值，否则按 iOS 版本默认） */
    int ver = ios_major_version();
    double delay = (ver >= 16) ? 4.0 : 2.0;
    
    NSString *delayStr = [NSString stringWithUTF8String:kAVCCfgC];
    if (delayStr && delayStr.length > 0 && ![delayStr hasPrefix:@"@@"]) {
        double customDelay = [delayStr doubleValue];
        if (customDelay >= 0.5 && customDelay <= 60.0) {
            delay = customDelay;
            FUCKLOG("[ 使用自定义延迟: %.1fs", delay);
        }
    }
    
    FUCKLOG("[ iOS=%d, hook延迟=%.1fs", ver, delay);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^{
            @autoreleasepool {
                @try {
                    applyAllHooks();
                } @catch (NSException *e) {
                    FUCKLOG("[ applyAllHooks 异常: %s", [[e reason] UTF8String]);
                    atomic_store(&gInitState, -1);
                }
            }
        }
    );

    FUCKLOG("[ constructor 返回 (已安排延迟初始化)");
}
