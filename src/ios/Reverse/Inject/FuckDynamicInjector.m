//
//  FuckDynamicInjector.m
//  自实现动态注入引擎（基于 mach thread injection + kfd trust cache）
//  从参考项目 troll_dynamic_spoofer 提取核心注入逻辑并改造
//
//  支持越狱环境（jailbreakd IPC）和 TrollStore 环境（kfd exploit）
//

#import "FuckDynamicInjector.h"
#import <Foundation/Foundation.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>
#import <errno.h>
#import <mach/mach.h>
#import <mach/thread_act.h>
#import <mach/thread_status.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach-o/fat.h>
#import <CommonCrypto/CommonDigest.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <os/log.h>
#import <xpc/xpc.h>

// ============== 注入日志（Release 也落盘，供 App 内「注入日志」查看）==============
//
// 日志写入 <App Documents>/inject_debug.log。
// 主进程与 root 子进程（-FuckInject）都会写同一路径 —— 子进程通过
// 环境变量 FUCK_INJECT_LOG_PATH 拿到主进程传来的绝对路径，
// 避免子进程因 UID 不同解析到不同 Documents 目录。

static NSString *FuckLogPath(void) {
    const char *env = getenv("FUCK_INJECT_LOG_PATH");
    if (env && env[0]) return [NSString stringWithUTF8String:env];
    // 回退：自己推导 Documents
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"inject_debug.log"];
}

static void FuckLogWrite(const char *func, int line, NSString *level, NSString *msg) {
    NSLog(@"[FuckInject][%s:%d] %@%@", func, line, level ?: @"", msg);

    static NSLock *logLock = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ logLock = [[NSLock alloc] init]; });

    [logLock lock];
    @autoreleasepool {
        NSString *path = FuckLogPath();
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line_ = [NSString stringWithFormat:@"[%@] %s:%d %@%@\n",
                           [df stringFromDate:[NSDate date]], func, line, level ?: @"", msg];

        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) {
            [line_ writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            // 日志文件对 mobile 可读
            chmod(path.UTF8String, 0644);
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (fh) {
                @try {
                    [fh seekToEndOfFile];
                    [fh writeData:[line_ dataUsingEncoding:NSUTF8StringEncoding]];
                    [fh closeFile];
                } @catch (__unused NSException *e) {}
            }
        }
    }
    [logLock unlock];
}

static void FuckLog(const char *func, int line, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    FuckLogWrite(func, line, @"", msg);
}

#define FLog(fmt, ...) FuckLog(__FUNCTION__, __LINE__, fmt, ##__VA_ARGS__)
#define FLogError(fmt, ...) FuckLog(__FUNCTION__, __LINE__, @"❌ " fmt, ##__VA_ARGS__)
#define FLogSuccess(fmt, ...) FuckLog(__FUNCTION__, __LINE__, @"✅ " fmt, ##__VA_ARGS__)

// ============== 外部声明 ==============

// bootstrap API
extern mach_port_t bootstrap_port;
extern kern_return_t bootstrap_look_up(mach_port_t, const char *, mach_port_t *);

// ptrace
#ifndef PT_ATTACHEXC
#define PT_ATTACHEXC 14
#endif
#ifndef PT_DETACH
#define PT_DETACH 11
#endif
int ptrace(int request, pid_t pid, caddr_t addr, int data);

// csops
#define FUCK_CS_OPS_STATUS       0
#define FUCK_CS_DEBUGGED         0x10000000
#define FUCK_CS_GET_TASK_ALLOW   0x00000004
#define FUCK_CS_PLATFORM_BINARY  0x04000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

// libproc
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif
extern int proc_listallpids(void *buffer, int buffersize);
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

// mach_vm
typedef uint64_t mach_vm_address_t;
typedef uint64_t mach_vm_size_t;
extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                        mach_vm_size_t size);
extern kern_return_t mach_vm_write(vm_map_t target_task, mach_vm_address_t address,
                                    vm_offset_t data, mach_msg_type_number_t dataCnt);
extern kern_return_t mach_vm_protect(vm_map_t target_task, mach_vm_address_t address,
                                      mach_vm_size_t size, boolean_t set_maximum,
                                      vm_prot_t new_protection);
extern kern_return_t mach_vm_read_overwrite(vm_map_t target_task,
                                             mach_vm_address_t address,
                                             mach_vm_size_t size,
                                             mach_vm_address_t data,
                                             mach_vm_size_t *outsize);

extern char **environ;

// Sandbox extension API
enum fuck_sandbox_filter_type {
    FUCK_SANDBOX_FILTER_NONE,
    FUCK_SANDBOX_FILTER_PATH,
    FUCK_SANDBOX_FILTER_GLOBAL_NAME,
    FUCK_SANDBOX_FILTER_LOCAL_NAME,
    FUCK_SANDBOX_FILTER_APPLEEVENT_DESTINATION,
    FUCK_SANDBOX_FILTER_RIGHT_NAME,
    FUCK_SANDBOX_FILTER_PREFERENCE_DOMAIN,
    FUCK_SANDBOX_FILTER_KEXT_BUNDLE_ID,
    FUCK_SANDBOX_FILTER_INFO_TYPE,
    FUCK_SANDBOX_FILTER_NOTIFICATION,
};
extern const char * APP_SANDBOX_READ;
extern const char * APP_SANDBOX_READ_WRITE;
extern const enum fuck_sandbox_filter_type SANDBOX_CHECK_NO_REPORT;
int sandbox_check(pid_t, const char *operation, enum fuck_sandbox_filter_type, ...);
int64_t sandbox_extension_consume(const char *extension_token);
char *sandbox_extension_issue_file(const char *extension_class, const char *path, uint32_t flags);
int sandbox_extension_release(int64_t extension_handle);

// posix_spawn persona API
__attribute__((weak_import))
extern int posix_spawnattr_set_persona_np(posix_spawnattr_t *attr, uid_t persona, uint32_t flags);
__attribute__((weak_import))
extern int posix_spawnattr_set_persona_uid_np(posix_spawnattr_t *attr, uid_t uid);
__attribute__((weak_import))
extern int posix_spawnattr_set_persona_gid_np(posix_spawnattr_t *attr, gid_t gid);

// kfd headers


// ============== Relaxin / roothide 桥接 ==============
//
// Relaxin 越狱基于 roothide 架构（vendor 自 Dopamine 的 BaseBin）。
// roothide 把越狱根放在一个随机路径（jbroot），并提供 jbserver XPC 接口。
// 与 trust cache 相关的关键接口：
//
//   int jbclient_trust_library_recurse(const char *libraryPath, void *addressInCaller);
//   int jbclient_trust_file_by_path(const char *path);
//   bool jbclient_roothide_jailbroken(void);
//   char *jbclient_get_jbroot(void);
//
// jbserver 走 launchd 的 xpc_bootstrap_pipe，域名 JBS_DOMAIN_ROOTHIDE = 5。
// 这里全部用 dlsym 动态解析，避免编译期链接依赖（libjailbreak 在非越狱环境不存在）。

typedef int (*FuckTrustLibraryRecurseFn)(const char *, void *);
typedef int (*FuckTrustFileByPathFn)(const char *);
typedef bool (*FuckRoothideJailbrokenFn)(void);
typedef char *(*FuckGetJbrootFn)(void);

// 加载 libjailbreak（roothide 版本），返回句柄；失败返回 NULL
static void *FuckLoadLibJailbreak(void) {
    // roothide 的 jbroot 是随机路径，先尝试从 jbserver 查询
    static void *cached = NULL;
    static BOOL tried = NO;
    if (tried) return cached;
    tried = YES;

    const char *candidates[] = {
        "/var/jb/usr/lib/libjailbreak.dylib",
        "/usr/lib/libjailbreak.dylib",
        "/var/jb/basebin/libjailbreak.dylib",
        NULL
    };
    for (int i = 0; candidates[i]; i++) {
        void *h = dlopen(candidates[i], RTLD_NOW);
        if (h) {
            cached = h;
            FLog(@"[roothide] libjailbreak 已加载: %s", candidates[i]);
            return cached;
        }
    }
    // 最后尝试 dyld 全局（若 jailbreakd 注入过）
    cached = dlopen("libjailbreak.dylib", RTLD_NOW);
    if (cached) FLog(@"[roothide] libjailbreak 从 dyld 加载成功");
    else FLog(@"[roothide] libjailbreak 未找到（非越狱环境或路径变化）");
    return cached;
}

// 返回 YES 表示走通了 roothide 通道
static BOOL FuckRoothideTrustDylib(NSString *dylibPath) {
    void *h = FuckLoadLibJailbreak();
    if (!h) return NO;

    // 先确认处于 roothide 越狱环境
    FuckRoothideJailbrokenFn jailbroken =
        (FuckRoothideJailbrokenFn)dlsym(h, "jbclient_roothide_jailbroken");
    if (jailbroken && !jailbroken()) {
        FLog(@"[roothide] jbclient_roothide_jailbroken() == false");
        return NO;
    }

    FuckTrustLibraryRecurseFn trustLibrary =
        (FuckTrustLibraryRecurseFn)dlsym(h, "jbclient_trust_library_recurse");
    if (trustLibrary) {
        int r = trustLibrary(dylibPath.UTF8String, NULL);
        FLog(@"[roothide] jbclient_trust_library_recurse => %d", r);
        if (r == 0) return YES;
    } else {
        FLog(@"[roothide] 无 jbclient_trust_library_recurse 符号");
    }

    FuckTrustFileByPathFn trustPath =
        (FuckTrustFileByPathFn)dlsym(h, "jbclient_trust_file_by_path");
    if (trustPath) {
        int r = trustPath(dylibPath.UTF8String);
        FLog(@"[roothide] jbclient_trust_file_by_path => %d", r);
        if (r == 0) return YES;
    } else {
        FLog(@"[roothide] 无 jbclient_trust_file_by_path 符号");
    }

    return NO;
}

// 查询 roothide 越狱根（用于日志与路径构造）
static NSString *FuckRoothideJbroot(void) {
    void *h = FuckLoadLibJailbreak();
    if (!h) return nil;
    FuckGetJbrootFn getRoot = (FuckGetJbrootFn)dlsym(h, "jbclient_get_jbroot");
    if (!getRoot) return nil;
    char *p = getRoot();
    return p ? [NSString stringWithUTF8String:p] : nil;
}

// ============== CDHash 常量 ==============
#define FUCK_CS_MAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define FUCK_CS_MAGIC_CODEDIRECTORY      0xfade0c02
#define FUCK_CS_HASHTYPE_SHA160          1
#define FUCK_CS_HASHTYPE_SHA256_256      2
#define FUCK_CS_HASHTYPE_SHA256_160      3
#define FUCK_CS_HASHTYPE_SHA384          4
#define FUCK_CS_CDHASH_LEN              20
#define FUCK_CS_SLOT_CODEDIRECTORY      0x0
#define FUCK_CS_SLOT_ALT_CD_START       0x1000
#define FUCK_CS_SLOT_ALT_CD_LIMIT       0x1005

typedef struct { uint32_t magic; uint32_t length; uint32_t count; } FuckCS_SuperBlob;
typedef struct { uint32_t type; uint32_t offset; } FuckCS_BlobIndex;
typedef struct {
    uint32_t magic; uint32_t length; uint32_t version; uint32_t flags;
    uint32_t hashOffset; uint32_t identOffset;
    uint32_t nSpecialSlots; uint32_t nCodeSlots; uint32_t codeLimit;
    uint8_t hashSize; uint8_t hashType; uint8_t platform; uint8_t pageSize;
    uint32_t spare2;
} FuckCS_CodeDirectory;



// ============== 工具函数 ==============

static int FuckWaitForPid(pid_t pid) {
    int status = 0;
    while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {}
    return status;
}

static int FuckSpawnArguments(NSArray<NSString *> *arguments, BOOL asRootPersona) {
    if (arguments.count == 0) return -1;

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) return -1;

    short flags = POSIX_SPAWN_CLOEXEC_DEFAULT;
    posix_spawnattr_setflags(&attr, flags);
    posix_spawnattr_setpgroup(&attr, 0);

    if (asRootPersona && posix_spawnattr_set_persona_np &&
        posix_spawnattr_set_persona_uid_np && posix_spawnattr_set_persona_gid_np) {
        posix_spawnattr_set_persona_np(&attr, 99, 1);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);
    }

    char **argv = calloc(arguments.count + 1, sizeof(char *));
    if (!argv) { posix_spawnattr_destroy(&attr); return ENOMEM; }

    for (NSUInteger i = 0; i < arguments.count; i++) {
        argv[i] = (char *)arguments[i].UTF8String;
    }
    argv[arguments.count] = NULL;

    pid_t pid = 0;
    int ret = posix_spawn(&pid, argv[0], NULL, &attr, argv, environ);
    free(argv);
    posix_spawnattr_destroy(&attr);
    if (ret != 0) return ret;

    return FuckWaitForPid(pid);
}

static NSString *FuckResourcePath(NSString *name) {
    if (!name.length) return nil;
    NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:name];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

// ============== LSApplicationProxy 辅助 ==============

static id FuckPerformSelector(id obj, NSString *selName) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [obj performSelector:sel];
#pragma clang diagnostic pop
}

static id FuckPerformSelectorObj(id obj, NSString *selName, id arg) {
    SEL sel = NSSelectorFromString(selName);
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    return [obj performSelector:sel withObject:arg];
#pragma clang diagnostic pop
}

static id FuckProxyForBundleID(NSString *bundleID) {
    if (!bundleID.length) return nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass) return nil;
    return FuckPerformSelectorObj(proxyClass, @"applicationProxyForIdentifier:", bundleID);
}

static NSString *FuckProxyString(id proxy, NSString *selName) {
    id value = FuckPerformSelector(proxy, selName);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static NSString *FuckProxyPathFromURL(id proxy, NSString *selName) {
    id url = FuckPerformSelector(proxy, selName);
    return [url respondsToSelector:@selector(path)] ? [url path] : nil;
}

static NSString *FuckCanonicalExecutablePath(NSString *bundleID) {
    id proxy = FuckProxyForBundleID(bundleID);
    NSString *execPath = FuckProxyString(proxy, @"canonicalExecutablePath");
    if (execPath.length) return execPath;
    NSString *bundlePath = FuckProxyPathFromURL(proxy, @"bundleURL");
    NSString *exeName = FuckProxyString(proxy, @"bundleExecutable");
    if (!bundlePath.length || !exeName.length) return nil;
    return [bundlePath stringByAppendingPathComponent:exeName];
}

static BOOL FuckOpenApp(NSString *bundleID) {
    id ws = FuckPerformSelector(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    if (!ws) return NO;
    SEL openSel = NSSelectorFromString(@"openApplicationWithBundleID:");
    if (![ws respondsToSelector:openSel]) return NO;
    // openApplicationWithBundleID: 返回 BOOL，不能用 performSelector（会把 BOOL 当对象指针 → EXC_BAD_ACCESS）
    // 使用 NSInvocation 正确处理 BOOL 返回值
    NSMethodSignature *sig = [ws methodSignatureForSelector:openSel];
    if (!sig) return NO;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:ws];
    [inv setSelector:openSel];
    [inv setArgument:&bundleID atIndex:2];
    [inv invoke];
    BOOL result = NO;
    [inv getReturnValue:&result];
    return result;
}

// ============== TeamID 提取（4种方式）==============

static NSString *FuckExtractTeamIDFromApp(NSString *bundleID) {
    FLog(@"[TeamID] 开始提取 TeamID, bundleID=%@", bundleID);

    id proxy = FuckProxyForBundleID(bundleID);
    NSString *execPath = FuckProxyString(proxy, @"canonicalExecutablePath");
    if (!execPath.length) {
        NSString *bundlePath = FuckProxyPathFromURL(proxy, @"bundleURL");
        NSString *exeName = FuckProxyString(proxy, @"bundleExecutable");
        if (bundlePath.length && exeName.length)
            execPath = [bundlePath stringByAppendingPathComponent:exeName];
    }
    NSString *bundlePath = FuckProxyPathFromURL(proxy, @"bundleURL");

    // 方法1: ldid -e 提取 entitlements
    if (execPath.length) {
        NSString *ldidPath = FuckResourcePath(@"ldid");
        if (ldidPath.length) {
            chmod(ldidPath.UTF8String, 0755);
            int pipeFDs[2];
            if (pipe(pipeFDs) == 0) {
                posix_spawn_file_actions_t actions;
                posix_spawn_file_actions_init(&actions);
                posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO);
                posix_spawn_file_actions_addclose(&actions, pipeFDs[0]);

                const char *argv[] = {ldidPath.UTF8String, "-e", execPath.UTF8String, NULL};
                pid_t pid = 0;
                int spawnRet = posix_spawn(&pid, ldidPath.UTF8String, &actions, NULL,
                                           (char *const *)argv, NULL);
                posix_spawn_file_actions_destroy(&actions);
                close(pipeFDs[1]);

                if (spawnRet == 0) {
                    NSMutableData *outputData = [NSMutableData data];
                    char buf[4096];
                    ssize_t n;
                    while ((n = read(pipeFDs[0], buf, sizeof(buf))) > 0)
                        [outputData appendBytes:buf length:n];
                    close(pipeFDs[0]);
                    waitpid(pid, NULL, 0);

                    if (outputData.length > 0) {
                        id plist = [NSPropertyListSerialization propertyListWithData:outputData
                                                                            options:0 format:NULL error:NULL];
                        if ([plist isKindOfClass:[NSDictionary class]]) {
                            NSString *teamID = plist[@"com.apple.developer.team-identifier"];
                            if (teamID.length) {
                                FLog(@"[TeamID] 方法1a: team-identifier = %@", teamID);
                                return teamID;
                            }
                            NSString *appID = plist[@"application-identifier"];
                            if (appID.length) {
                                NSRange dot = [appID rangeOfString:@"."];
                                if (dot.location != NSNotFound && dot.location == 10) {
                                    NSString *tid = [appID substringToIndex:dot.location];
                                    FLog(@"[TeamID] 方法1b: application-identifier = %@", tid);
                                    return tid;
                                }
                            }
                        }
                    }
                } else {
                    close(pipeFDs[0]);
                }
            }
        }
    }

    // 方法2: embedded.mobileprovision
    if (bundlePath.length) {
        NSString *provPath = [bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"];
        NSData *provData = [NSData dataWithContentsOfFile:provPath];
        if (provData.length) {
            NSString *provStr = [[NSString alloc] initWithData:provData encoding:NSASCIIStringEncoding];
            if (provStr) {
                NSRange xmlStart = [provStr rangeOfString:@"<?xml"];
                NSRange xmlEnd = [provStr rangeOfString:@"</plist>"];
                if (xmlStart.location != NSNotFound && xmlEnd.location != NSNotFound) {
                    NSString *xmlStr = [provStr substringWithRange:
                        NSMakeRange(xmlStart.location, xmlEnd.location + xmlEnd.length - xmlStart.location)];
                    NSData *xmlData = [xmlStr dataUsingEncoding:NSUTF8StringEncoding];
                    if (xmlData) {
                        id plist = [NSPropertyListSerialization propertyListWithData:xmlData
                                                                            options:0 format:NULL error:NULL];
                        if ([plist isKindOfClass:[NSDictionary class]]) {
                            NSArray *teamIDs = plist[@"TeamIdentifier"];
                            if ([teamIDs isKindOfClass:[NSArray class]] && teamIDs.count > 0) {
                                NSString *teamID = teamIDs[0];
                                if ([teamID isKindOfClass:[NSString class]] && teamID.length > 0) {
                                    FLog(@"[TeamID] 方法2: mobileprovision = %@", teamID);
                                    return teamID;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 方法3: Mach-O CodeDirectory
    if (execPath.length) {
        NSData *execData = [NSData dataWithContentsOfFile:execPath];
        if (execData.length >= 32) {
            const uint8_t *bytes = (const uint8_t *)execData.bytes;
            NSUInteger len = execData.length;
            const uint8_t *sliceBytes = bytes;
            NSUInteger sliceLen = len;

            uint32_t magic = *(uint32_t *)bytes;
            if (magic == 0xCAFEBABE || magic == 0xBEBAFECA) {
                BOOL swap = (magic == 0xCAFEBABE);
                uint32_t nfat = *(uint32_t *)(bytes + 4);
                if (swap) nfat = OSSwapInt32(nfat);
                for (uint32_t i = 0; i < nfat; i++) {
                    NSUInteger hdrOff = 8 + i * 20;
                    if (hdrOff + 20 > len) break;
                    uint32_t cpuType = *(uint32_t *)(bytes + hdrOff);
                    uint32_t offset = *(uint32_t *)(bytes + hdrOff + 8);
                    uint32_t size = *(uint32_t *)(bytes + hdrOff + 12);
                    if (swap) { cpuType = OSSwapInt32(cpuType); offset = OSSwapInt32(offset); size = OSSwapInt32(size); }
                    if (cpuType == 0x0100000C) {
                        if (offset + size <= len) { sliceBytes = bytes + offset; sliceLen = size; }
                        break;
                    }
                }
            }

            uint32_t sliceMagic = *(uint32_t *)sliceBytes;
            int headerSize = (sliceMagic == 0xFEEDFACF) ? 32 : (sliceMagic == 0xFEEDFACE ? 28 : 0);
            if (headerSize > 0 && sliceLen >= (NSUInteger)headerSize + 8) {
                uint32_t ncmds = *(uint32_t *)(sliceBytes + 16);
                NSUInteger cmdOff = headerSize;
                uint32_t csDataOff = 0;

                for (uint32_t c = 0; c < ncmds; c++) {
                    if (cmdOff + 8 > sliceLen) break;
                    uint32_t cmd = *(uint32_t *)(sliceBytes + cmdOff);
                    uint32_t cmdsize = *(uint32_t *)(sliceBytes + cmdOff + 4);
                    if (cmd == 0x1D && cmdOff + 16 <= sliceLen) {
                        csDataOff = *(uint32_t *)(sliceBytes + cmdOff + 8);
                        break;
                    }
                    cmdOff += cmdsize;
                }

                if (csDataOff > 0 && csDataOff + 12 <= sliceLen) {
                    uint32_t sbMagic = OSSwapBigToHostInt32(*(uint32_t *)(sliceBytes + csDataOff));
                    if (sbMagic == 0xFADE0CC0) {
                        uint32_t blobCount = OSSwapBigToHostInt32(*(uint32_t *)(sliceBytes + csDataOff + 8));
                        uint32_t useCdOff = 0, useCdLen = 0;

                        for (uint32_t b = 0; b < blobCount; b++) {
                            NSUInteger idxOff = csDataOff + 12 + b * 8;
                            if (idxOff + 8 > sliceLen) break;
                            uint32_t blobType = OSSwapBigToHostInt32(*(uint32_t *)(sliceBytes + idxOff));
                            uint32_t blobOff = OSSwapBigToHostInt32(*(uint32_t *)(sliceBytes + idxOff + 4));
                            NSUInteger absOff = csDataOff + blobOff;
                            if (absOff + 8 > sliceLen) continue;
                            uint32_t bMagic = OSSwapBigToHostInt32(*(uint32_t *)(sliceBytes + absOff));
                            uint32_t bLen = OSSwapBigToHostInt32(*(uint32_t *)(sliceBytes + absOff + 4));
                            if (bMagic == 0xFADE0C02) {
                                if (blobType == 0x1000) { useCdOff = (uint32_t)absOff; useCdLen = bLen; }
                                else if (blobType == 0 && useCdOff == 0) { useCdOff = (uint32_t)absOff; useCdLen = bLen; }
                            }
                        }

                        if (useCdOff > 0 && useCdOff + 52 <= sliceLen && useCdLen >= 52) {
                            const uint8_t *cdData = sliceBytes + useCdOff;
                            uint32_t version = OSSwapBigToHostInt32(*(uint32_t *)(cdData + 8));
                            if (version >= 0x20100) {
                                uint32_t teamOffset = OSSwapBigToHostInt32(*(uint32_t *)(cdData + 48));
                                if (teamOffset > 0 && teamOffset < useCdLen) {
                                    NSUInteger tidStart = teamOffset;
                                    NSUInteger tidEnd = tidStart;
                                    while (tidEnd < useCdLen && cdData[tidEnd] != 0) tidEnd++;
                                    if (tidEnd > tidStart) {
                                        NSString *teamID = [[NSString alloc] initWithBytes:(cdData + tidStart)
                                                                                    length:(tidEnd - tidStart)
                                                                                  encoding:NSUTF8StringEncoding];
                                        if (teamID.length == 10) {
                                            FLog(@"[TeamID] 方法3: CodeDirectory = %@", teamID);
                                            return teamID;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    FLog(@"[TeamID] 所有方法均失败");
    return nil;
}

// ============== CDHash 计算 ==============

static NSData *FuckComputeCDHash(NSString *filePath) {
    FILE *f = fopen(filePath.UTF8String, "rb");
    if (!f) { FLogError(@"[CDHash] 无法打开: %@", filePath); return nil; }

    struct mach_header_64 mh;
    fseek(f, 0, SEEK_SET);
    fread(&mh, sizeof(mh), 1, f);
    uint32_t archOffset = 0;

    if (mh.magic == FAT_MAGIC || mh.magic == FAT_CIGAM) {
        struct fat_header fh;
        fseek(f, 0, SEEK_SET);
        fread(&fh, sizeof(fh), 1, f);
        uint32_t nArch = OSSwapBigToHostInt32(fh.nfat_arch);
        for (uint32_t i = 0; i < nArch; i++) {
            struct fat_arch fa;
            fread(&fa, sizeof(fa), 1, f);
            if ((OSSwapBigToHostInt32(fa.cpusubtype) & ~0x80000000) == CPU_SUBTYPE_ARM64_ALL) {
                archOffset = OSSwapBigToHostInt32(fa.offset);
                break;
            }
        }
        if (!archOffset) { fclose(f); return nil; }
        fseek(f, archOffset, SEEK_SET);
        fread(&mh, sizeof(mh), 1, f);
    } else if (mh.magic != MH_MAGIC_64 && mh.magic != MH_CIGAM_64) {
        fclose(f); return nil;
    }

    uint32_t csOff = 0, csSize = 0;
    uint32_t cmdOff = archOffset + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < OSSwapLittleToHostInt32(mh.ncmds); i++) {
        struct load_command lc;
        fseek(f, cmdOff, SEEK_SET);
        fread(&lc, sizeof(lc), 1, f);
        if (OSSwapLittleToHostInt32(lc.cmd) == LC_CODE_SIGNATURE) {
            struct linkedit_data_command cs;
            fseek(f, cmdOff, SEEK_SET);
            fread(&cs, sizeof(cs), 1, f);
            csOff = archOffset + OSSwapLittleToHostInt32(cs.dataoff);
            csSize = OSSwapLittleToHostInt32(cs.datasize);
            break;
        }
        cmdOff += OSSwapLittleToHostInt32(lc.cmdsize);
    }
    if (!csOff || !csSize) { fclose(f); FLogError(@"[CDHash] 无代码签名"); return nil; }

    FuckCS_SuperBlob sb;
    fseek(f, csOff, SEEK_SET);
    fread(&sb, sizeof(sb), 1, f);
    if (OSSwapBigToHostInt32(sb.magic) != FUCK_CS_MAGIC_EMBEDDED_SIGNATURE) { fclose(f); return nil; }

    uint32_t blobCount = OSSwapBigToHostInt32(sb.count);
    uint32_t bestCDOff = 0, bestCDLen = 0;
    uint8_t bestHashType = 0;
    unsigned bestRank = 0;
    static const uint8_t rankOrder[] = { FUCK_CS_HASHTYPE_SHA160, FUCK_CS_HASHTYPE_SHA256_160,
                                         FUCK_CS_HASHTYPE_SHA256_256, FUCK_CS_HASHTYPE_SHA384 };

    for (uint32_t i = 0; i < blobCount; i++) {
        FuckCS_BlobIndex idx;
        fseek(f, csOff + sizeof(FuckCS_SuperBlob) + i * sizeof(FuckCS_BlobIndex), SEEK_SET);
        fread(&idx, sizeof(idx), 1, f);
        uint32_t blobType = OSSwapBigToHostInt32(idx.type);
        if (blobType != FUCK_CS_SLOT_CODEDIRECTORY &&
            !(blobType >= FUCK_CS_SLOT_ALT_CD_START && blobType < FUCK_CS_SLOT_ALT_CD_LIMIT)) continue;

        uint32_t blobOff = OSSwapBigToHostInt32(idx.offset);
        FuckCS_CodeDirectory cd;
        fseek(f, csOff + blobOff, SEEK_SET);
        fread(&cd, sizeof(cd), 1, f);
        if (OSSwapBigToHostInt32(cd.magic) != FUCK_CS_MAGIC_CODEDIRECTORY) continue;

        unsigned rank = 0;
        for (unsigned r = 0; r < sizeof(rankOrder); r++) {
            if (rankOrder[r] == cd.hashType) { rank = r + 1; break; }
        }
        if (rank > bestRank) {
            bestRank = rank;
            bestCDOff = blobOff;
            bestCDLen = OSSwapBigToHostInt32(cd.length);
            bestHashType = cd.hashType;
        }
    }
    if (!bestCDOff || !bestCDLen) { fclose(f); FLogError(@"[CDHash] 未找到 CodeDirectory"); return nil; }

    uint8_t *cdData = malloc(bestCDLen);
    if (!cdData) { fclose(f); return nil; }
    fseek(f, csOff + bestCDOff, SEEK_SET);
    fread(cdData, bestCDLen, 1, f);
    fclose(f);

    uint8_t cdhash[FUCK_CS_CDHASH_LEN];
    switch (bestHashType) {
        case FUCK_CS_HASHTYPE_SHA160: {
            uint8_t full[CC_SHA1_DIGEST_LENGTH];
            CC_SHA1(cdData, bestCDLen, full);
            memcpy(cdhash, full, FUCK_CS_CDHASH_LEN);
            break;
        }
        case FUCK_CS_HASHTYPE_SHA256_256:
        case FUCK_CS_HASHTYPE_SHA256_160: {
            uint8_t full[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(cdData, bestCDLen, full);
            memcpy(cdhash, full, FUCK_CS_CDHASH_LEN);
            break;
        }
        case FUCK_CS_HASHTYPE_SHA384: {
            uint8_t full[CC_SHA384_DIGEST_LENGTH];
            CC_SHA384(cdData, bestCDLen, full);
            memcpy(cdhash, full, FUCK_CS_CDHASH_LEN);
            break;
        }
        default: free(cdData); return nil;
    }
    free(cdData);

    FLog(@"[CDHash] hashType=%u, cdLen=%u", bestHashType, bestCDLen);
    return [NSData dataWithBytes:cdhash length:FUCK_CS_CDHASH_LEN];
}

// ============== Trust Cache 注入 ==============

// Phase 1: jailbreakd IPC (Dopamine 越狱) — ARC safe, no xpc_release
static int FuckJailbreakdTrustCacheAdd(NSData *cdhash) {
    if (!cdhash || cdhash.length != FUCK_CS_CDHASH_LEN) return -1;

    void *h = dlopen("/usr/lib/system/libxpc.dylib", RTLD_NOW);
    if (!h) { FLog(@"[TrustCache] 无法加载 libxpc"); return -2; }

    // Use void* for pipe API function pointers to avoid ARC conflicts
    // xpc_pipe_t is an ObjC object under ARC, void* avoids retain/release issues
    typedef void* (*pipe_create_fn)(mach_port_t, uint64_t);
    typedef int (*pipe_routine_fn)(void*, void*, void**);

    pipe_create_fn _pipe_create = (pipe_create_fn)dlsym(h, "xpc_pipe_create_from_port");
    pipe_routine_fn _pipe_routine = (pipe_routine_fn)dlsym(h, "xpc_pipe_routine");
    if (!_pipe_create || !_pipe_routine) {
        FLog(@"[TrustCache] XPC pipe API 不可用");
        return -3;
    }

    // 端口名多候选：Dopamine / roothide / 通用别名
    const char *jbdNames[] = {
        "com.opa334.jailbreakd",
        "com.opa334.jailbreakd.xpc",
        "jailbreakd",
        "com.roothide.jailbreakd",
        NULL
    };
    mach_port_t jbdPort = MACH_PORT_NULL;
    kern_return_t kr = KERN_FAILURE;
    const char *hitName = NULL;
    for (int ni = 0; jbdNames[ni]; ni++) {
        kr = bootstrap_look_up(bootstrap_port, jbdNames[ni], &jbdPort);
        if (kr == KERN_SUCCESS && jbdPort != MACH_PORT_NULL) {
            hitName = jbdNames[ni];
            break;
        }
        jbdPort = MACH_PORT_NULL;
    }
    if (jbdPort == MACH_PORT_NULL) {
        FLog(@"[TrustCache] jailbreakd 全端口名均不可用 (kr=%d)", kr);
        return -4;
    }
    FLog(@"[TrustCache] jailbreakd 端口命中: %s", hitName);

    void *pipe = _pipe_create(jbdPort, 0);
    if (!pipe) {
        mach_port_deallocate(mach_task_self(), jbdPort);
        return -8;
    }

    xpc_object_t msg = xpc_dictionary_create_empty();
    xpc_dictionary_set_uint64(msg, "jb-domain", 4);
    xpc_dictionary_set_uint64(msg, "action", 7);
    xpc_dictionary_set_data(msg, "cdhash", cdhash.bytes, cdhash.length);

    void *reply = NULL;
    int err = _pipe_routine(pipe, (__bridge void *)msg, &reply);
    // Under ARC: msg is auto-released, pipe is void* (unmanaged), reply is void*
    mach_port_deallocate(mach_task_self(), jbdPort);

    if (err != 0) { FLog(@"[TrustCache] jailbreakd 通信失败: err=%d", err); return -9; }
    if (!reply) return -10;

    int64_t result = xpc_dictionary_get_int64((__bridge xpc_object_t)reply, "result");
    return (int)result;
}

// Phase 2: kfd exploit trust cache 注入（通过独立子进程执行，避免 kernel panic）
// 参考项目使用 posix_spawn 隔离 kfd exploit，子进程崩溃不影响主进程
static BOOL FuckKfdTrustCacheInject(NSData *cdhash) {
    FLog(@"[kfd] 开始 kfd exploit trust cache 注入（子进程模式）...");

    // 查找 FuckKfdHelper 可执行文件
    NSString *helperPath = FuckResourcePath(@"FuckKfdHelper");
    if (!helperPath.length) {
        FLogError(@"[kfd] FuckKfdHelper 不存在于 App bundle");
        return NO;
    }
    chmod(helperPath.UTF8String, 0755);

    // 将 CDHash 转换为 hex 字符串传递给子进程
    const uint8_t *hashBytes = (const uint8_t *)cdhash.bytes;
    char cdhashHex[41];
    for (int i = 0; i < 20; i++) {
        snprintf(cdhashHex + i * 2, 3, "%02x", hashBytes[i]);
    }
    cdhashHex[40] = '\0';

    FLog(@"[kfd] 启动 FuckKfdHelper 子进程, cdhash=%s", cdhashHex);

    // 创建临时文件捕获 kfd 输出
    NSString *tmpLog = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"kfd_output_%d.log", getpid()]];
    [[NSFileManager defaultManager] createFileAtPath:tmpLog contents:nil attributes:nil];
    int logFd = open(tmpLog.UTF8String, O_RDWR | O_CREAT | O_TRUNC, 0644);
    
    // 通过 posix_spawn 在独立子进程中运行 exploit，重定向 stdout/stderr
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    if (logFd >= 0) {
        posix_spawn_file_actions_adddup2(&actions, logFd, STDOUT_FILENO);
        posix_spawn_file_actions_adddup2(&actions, logFd, STDERR_FILENO);
        posix_spawn_file_actions_addclose(&actions, logFd);
    }
    
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    short flags = POSIX_SPAWN_CLOEXEC_DEFAULT;
    posix_spawnattr_setflags(&attr, flags);
    posix_spawnattr_setpgroup(&attr, 0);
    
    if (posix_spawnattr_set_persona_np && posix_spawnattr_set_persona_uid_np && 
        posix_spawnattr_set_persona_gid_np) {
        posix_spawnattr_set_persona_np(&attr, 99, 1);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);
    }
    
    const char *argv[] = {helperPath.UTF8String, cdhashHex, NULL};
    pid_t pid = 0;
    int spawnRet = posix_spawn(&pid, helperPath.UTF8String, &actions, &attr, 
                               (char *const *)argv, environ);
    
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (logFd >= 0) close(logFd);
    
    if (spawnRet != 0) {
        FLogError(@"[kfd] posix_spawn 失败: %d", spawnRet);
        return NO;
    }
    
    int status = FuckWaitForPid(pid);
    
    // 读取并记录 kfd 输出
    NSData *logData = [NSData dataWithContentsOfFile:tmpLog];
    if (logData.length > 0) {
        NSString *output = [[NSString alloc] initWithData:logData encoding:NSUTF8StringEncoding];
        FLog(@"[kfd] 子进程输出: %@", output);
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmpLog error:nil];

    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        FLogSuccess(@"[kfd] 子进程 trust cache 注入成功!");
        return YES;
    }

    if (WIFSIGNALED(status)) {
        int sig = WTERMSIG(status);
        FLogError(@"[kfd] 子进程被信号 %d (%s) 杀死",
                  sig,
                  sig == 10 ? "SIGBUS" : sig == 11 ? "SIGSEGV" :
                  sig == 6 ? "SIGABRT" : "其他");
    } else if (WIFEXITED(status)) {
        FLogError(@"[kfd] 子进程退出码: %d", WEXITSTATUS(status));
    } else {
        FLogError(@"[kfd] 子进程异常状态: %d", status);
    }

    return NO;
}
static BOOL FuckInjectTrustCache(NSString *filePath) {
    FLog(@"[TrustCache] 开始 Trust Cache 注入: %@", filePath);

    NSData *cdhash = FuckComputeCDHash(filePath);
    if (!cdhash || cdhash.length != FUCK_CS_CDHASH_LEN) {
        FLogError(@"[TrustCache] CDHash 计算失败");
        return NO;
    }

    const uint8_t *bytes = cdhash.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity: FUCK_CS_CDHASH_LEN * 2];
    for (int i = 0; i < FUCK_CS_CDHASH_LEN; i++) [hex appendFormat:@"%02x", bytes[i]];
    FLog(@"[TrustCache] CDHash: %@", hex);

    NSString *jbroot = FuckRoothideJbroot();
    if (jbroot) FLog(@"[TrustCache] roothide jbroot: %@", jbroot);

    // ---- Phase 1: Relaxin / roothide jbserver（iOS 17.x 上的正路）----
    FLog(@"[TrustCache] Phase 1: roothide jbserver (Relaxin)...");
    if (FuckRoothideTrustDylib(filePath)) {
        FLogSuccess(@"[TrustCache] roothide trust cache 注入成功!");
        return YES;
    }
    FLog(@"[TrustCache] roothide 通道未走通，继续尝试其他路径");

    // ---- Phase 2: Dopamine jailbreakd IPC（多端口名候选）----
    FLog(@"[TrustCache] Phase 2: jailbreakd IPC...");
    int ret = FuckJailbreakdTrustCacheAdd(cdhash);
    if (ret == 0) {
        FLogSuccess(@"[TrustCache] jailbreakd trust cache 注入成功!");
        return YES;
    }
    FLog(@"[TrustCache] jailbreakd IPC 返回: %d", ret);

    // ---- Phase 3: kfd exploit（兜底，iOS 16.x 及以下可用）----
    FLog(@"[TrustCache] Phase 3: kfd exploit...");
    BOOL kfdResult = FuckKfdTrustCacheInject(cdhash);
    if (kfdResult) {
        FLogSuccess(@"[TrustCache] kfd trust cache 注入成功!");
        return YES;
    }

    FLogError(@"[TrustCache] 所有 trust cache 注入方式均失败");
    return NO;
}

// ============== OPAINJECT 核心注入引擎 ==============

// 返回落脚点（ropLoop）查找。
//
// 历史实现依赖 "shared cache 基址 >= 0x140000000" 这一硬编码假设，
// 在 iOS 17.x 的 dyld shared cache 新布局下该阈值失效，会命中到不属于
// 目标进程映射范围的地址，thread_set_state 后目标进程执行到无效地址直接
// SIGSEGV（这正是 17.0 以上闪退的直接原因）。
//
// 现改为：
//   1. 优先搜索 "ret; ret" 连续指令序列 —— 这是编译器为函数末尾对齐
//      产生的固定模式，任何 iOS 版本的 shared cache 里都存在，且跳进去
//      执行完就回落到 LR(=0) 处停住，语义与原来的 "b ." 自旋等价；
//   2. 回退到 "b ."（0x14000000）搜索，但不做基址范围限制。
static uint64_t FuckFindRopLoop(void) {
    const uint32_t RET_INSN = 0xD65F03C0;

    uint32_t imageCount = _dyld_image_count();

    // ---- 优先：ret; ret 序列（版本无关） ----
    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *cmd =
            (const struct load_command *)((uint8_t *)header + sizeof(struct mach_header_64));

        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, "__TEXT") == 0) {
                    const struct section_64 *sec =
                        (const struct section_64 *)((uint8_t *)seg + sizeof(*seg));
                    for (uint32_t k = 0; k < seg->nsects; k++) {
                        if (strcmp(sec[k].sectname, "__text") != 0 || sec[k].size < 8) continue;
                        uint32_t *code = (uint32_t *)(sec[k].addr + slide);
                        size_t count = sec[k].size / sizeof(uint32_t);
                        for (size_t n = 0; n + 1 < count; n++) {
                            if (code[n] == RET_INSN && code[n + 1] == RET_INSN) {
                                uint64_t addr = (uint64_t)&code[n];
                                const char *imgName = _dyld_get_image_name(i);
                                FLog(@"找到 ropLoop(ret;ret): 0x%llx (image %d: %s)",
                                     addr, i, imgName ? imgName : "unknown");
                                return addr;
                            }
                        }
                    }
                }
            }
            cmd = (const struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
        }
    }

    // ---- 回退：b .（不做基址范围限制） ----
    for (uint32_t i = 0; i < imageCount; i++) {
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *cmd =
            (const struct load_command *)((uint8_t *)header + sizeof(struct mach_header_64));

        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, "__TEXT") == 0) {
                    const struct section_64 *sec =
                        (const struct section_64 *)((uint8_t *)seg + sizeof(*seg));
                    for (uint32_t k = 0; k < seg->nsects; k++) {
                        if (strcmp(sec[k].sectname, "__text") != 0 || sec[k].size < 4) continue;
                        uint32_t *code = (uint32_t *)(sec[k].addr + slide);
                        size_t count = sec[k].size / sizeof(uint32_t);
                        for (size_t n = 0; n < count; n++) {
                            if (code[n] == 0x14000000) {
                                uint64_t addr = (uint64_t)&code[n];
                                const char *imgName = _dyld_get_image_name(i);
                                FLog(@"找到 ropLoop(b): 0x%llx (image %d: %s)", addr, i,
                                     imgName ? imgName : "unknown");
                                return addr;
                            }
                        }
                    }
                }
            }
            cmd = (const struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
        }
    }
    FLogError(@"未在任意 image 中找到 ropLoop");
    return 0;
}

static void *FuckFindSymbolInImage(const char *imageName, const char *symbolName) {
    char mangledName[256];
    snprintf(mangledName, sizeof(mangledName), "_%s", symbolName);

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, imageName)) continue;

        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *cmd =
            (const struct load_command *)((uint8_t *)header + sizeof(struct mach_header_64));

        const struct symtab_command *symtab = NULL;
        uint64_t linkeditVmaddr = 0;
        uint64_t linkeditFileoff = 0;

        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SYMTAB) {
                symtab = (const struct symtab_command *)cmd;
            } else if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, "__LINKEDIT") == 0) {
                    linkeditVmaddr = seg->vmaddr;
                    linkeditFileoff = seg->fileoff;
                }
            }
            cmd = (const struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
        }

        if (!symtab || !linkeditVmaddr) continue;

        uintptr_t linkeditBase = (uintptr_t)slide + linkeditVmaddr - linkeditFileoff;
        const struct nlist_64 *syms = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
        const char *strtab = (const char *)(linkeditBase + symtab->stroff);

        for (uint32_t k = 0; k < symtab->nsyms; k++) {
            if (syms[k].n_un.n_strx == 0) continue;
            if ((syms[k].n_type & N_TYPE) != N_SECT) continue;
            const char *symStr = strtab + syms[k].n_un.n_strx;
            if (strcmp(symStr, mangledName) == 0) {
                void *result = (void *)(syms[k].n_value + slide);
                FLog(@"[nlist] 找到 %s @ %p", mangledName, result);
                return result;
            }
        }
    }
    return NULL;
}

static void *FuckFindPthreadSetSelfByMSR(void) {
#ifdef __arm64__
    const uint32_t MSR_TPIDR_EL0_X0 = 0xD51BD040;
    const uint32_t RET_INSN = 0xD65F03C0;

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "libsystem_pthread")) continue;

        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *cmd =
            (const struct load_command *)((uint8_t *)header + sizeof(struct mach_header_64));

        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, "__TEXT") == 0) {
                    const struct section_64 *sec =
                        (const struct section_64 *)((uint8_t *)seg + sizeof(*seg));
                    for (uint32_t k = 0; k < seg->nsects; k++) {
                        if (strcmp(sec[k].sectname, "__text") == 0 && sec[k].size >= 4) {
                            uint32_t *code = (uint32_t *)(sec[k].addr + slide);
                            size_t count = sec[k].size / sizeof(uint32_t);
                            for (size_t n = 0; n < count; n++) {
                                if (code[n] == MSR_TPIDR_EL0_X0) {
                                    size_t funcStart = n;
                                    for (size_t back = 1; back <= n && back <= 16; back++) {
                                        uint32_t prev = code[n - back];
                                        if (prev == RET_INSN ||
                                            (prev & 0xFC000000) == 0x14000000 ||
                                            (prev & 0xFC000000) == 0x94000000) {
                                            funcStart = n - back + 1;
                                            break;
                                        }
                                    }
                                    void *result = (void *)&code[funcStart];
                                    FLog(@"[MSR] 找到 __pthread_set_self @ %p", result);
                                    return result;
                                }
                            }
                        }
                    }
                }
            }
            cmd = (const struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
        }
    }
#endif
    return NULL;
}

static pid_t FuckFindPIDByExecPath(const char *targetPath) {
    if (!targetPath || targetPath[0] == '\0') return -1;

    char resolvedTarget[PROC_PIDPATHINFO_MAXSIZE];
    if (realpath(targetPath, resolvedTarget) == NULL)
        strlcpy(resolvedTarget, targetPath, sizeof(resolvedTarget));

    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return -1;

    pid_t *pids = (pid_t *)calloc(count, sizeof(pid_t));
    if (!pids) return -1;

    int actual = proc_listallpids(pids, count * sizeof(pid_t));
    pid_t found = -1;
    char pathBuf[PROC_PIDPATHINFO_MAXSIZE];

    for (int i = 0; i < actual; i++) {
        if (pids[i] <= 0) continue;
        memset(pathBuf, 0, sizeof(pathBuf));
        if (proc_pidpath(pids[i], pathBuf, sizeof(pathBuf)) > 0) {
            if (strcmp(pathBuf, resolvedTarget) == 0) {
                found = pids[i];
                break;
            }
        }
    }
    free(pids);
    return found;
}

static pid_t FuckFindPIDForBundleID(NSString *bundleID) {
    NSString *execPath = FuckCanonicalExecutablePath(bundleID);
    if (!execPath.length) {
        FLogError(@"无法获取 %@ 的可执行文件路径", bundleID);
        return -1;
    }
    pid_t pid = FuckFindPIDByExecPath(execPath.UTF8String);
    if (pid > 0) FLog(@"找到目标进程 PID: %d", pid);
    else FLogError(@"未找到 %@ 的运行进程", bundleID);
    return pid;
}

static BOOL FuckWaitForRemoteThread(thread_act_t thread, uint64_t donePC, int timeoutMs) {
    FLog(@"等待远程线程完成, donePC=0x%llx, 超时=%dms", donePC, timeoutMs);
    int elapsed = 0;
    const int pollInterval = 10;

    while (elapsed < timeoutMs) {
#ifdef __arm64__
        arm_thread_state64_t state;
        mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
        kern_return_t kr = thread_get_state(thread, ARM_THREAD_STATE64,
                                            (thread_state_t)&state, &count);
        if (kr == KERN_SUCCESS) {
            uint64_t pc = __darwin_arm_thread_state64_get_pc(state);
            uint64_t x0 = state.__x[0];
            if (pc == donePC) {
                FLogSuccess(@"远程线程已到达 done 地址 (PC=0x%llx, x0=0x%llx)", pc, x0);
                return YES;
            }
            // 每 500ms 打印一次 PC 用于诊断
            if (elapsed > 0 && elapsed % 500 == 0) {
                FLog(@"远程线程 PC=0x%llx (等待 0x%llx, 已等 %dms)", pc, donePC, elapsed);
            }
        } else {
            FLogError(@"thread_get_state 失败: %d (%s) - 线程可能已崩溃", kr, mach_error_string(kr));
        }
#endif
        usleep(pollInterval * 1000);
        elapsed += pollInterval;
    }
    FLogError(@"等待远程线程超时 (%dms)", timeoutMs);
    return NO;
}

// OPAINJECT 核心: 将 dylib 注入到运行中的进程
// 注入模式 FuckInjectMode 与 FuckInjectModeStrict/Clean 常量见头文件。
//   Strict —— 严格复刻原实现：dylib 位于目标 App bundle 同级目录，
//             申请 sandbox extension 后注入
//   Clean  —— 无痕模式：dylib 位于我方 tmp，直接注入绝对路径，
//             不往目标 App 目录写任何文件
#define FuckInjectModeA FuckInjectModeStrict
#define FuckInjectModeB FuckInjectModeClean

static int FuckOpaInject(pid_t targetPID, const char *dylibPath, FuckInjectMode mode) {
    FLog(@"========== OPAINJECT 开始 (模式 %s) ==========", mode == FuckInjectModeA ? "A/严格复刻" : "B/无痕");
    FLog(@"目标 PID: %d, dylib: %s", targetPID, dylibPath);
    FLog(@"运行身份 UID: %d", getuid());

    {
        char kb[64] = {0}; size_t kbl = sizeof(kb);
        sysctlbyname("kern.osproductversion", kb, &kbl, NULL, 0);
        char kv[256] = {0}; size_t kvl = sizeof(kv);
        sysctlbyname("kern.version", kv, &kvl, NULL, 0);
        FLog(@"[环境] iOS %s", kb);
        FLog(@"[环境] %s", kv);
    }

    mach_port_t targetTask = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), targetPID, &targetTask);
    if (kr != KERN_SUCCESS) {
        FLogError(@"task_for_pid 失败: %d (%s)", kr, mach_error_string(kr));
        return -1;
    }
    if (targetTask == MACH_PORT_NULL || targetTask == MACH_PORT_DEAD) {
        FLogError(@"获取的 task port 无效: %d", targetTask);
        return -2;
    }
    FLog(@"获取 task port: %d", targetTask);

    // 检查目标进程的 cs_flags (用于诊断)
    {
        uint32_t targetFlags = 0;
        int csRet = csops(targetPID, FUCK_CS_OPS_STATUS, &targetFlags, sizeof(targetFlags));
        FLog(@"[DIAG] 目标进程(PID %d) cs_flags=0x%x (csops ret=%d)", targetPID, targetFlags, csRet);
        FLog(@"[DIAG]   CS_VALID=%d CS_DEBUGGED=%d CS_PLATFORM=%d CS_REQUIRE_LV=%d",
              (targetFlags & 0x1) ? 1 : 0,
              (targetFlags & FUCK_CS_DEBUGGED) ? 1 : 0,
              (targetFlags & FUCK_CS_PLATFORM_BINARY) ? 1 : 0,
              (targetFlags & 0x2000) ? 1 : 0);
        FLog(@"[DIAG]   CS_GET_TASK_ALLOW=%d CS_INSTALLER=%d CS_RESTRICT=%d CS_RUNTIME=%d",
              (targetFlags & FUCK_CS_GET_TASK_ALLOW) ? 1 : 0,
              (targetFlags & 0x8) ? 1 : 0,
              (targetFlags & 0x800) ? 1 : 0,
              (targetFlags & 0x10000) ? 1 : 0);
    }
    FLog(@"[注入策略] ct_bypass 签名 + sandbox extension (不使用 ptrace)");

    uint64_t ropLoop = FuckFindRopLoop();
    if (!ropLoop) {
        FLogError(@"未找到 ropLoop");
        mach_port_deallocate(mach_task_self(), targetTask);
        return -3;
    }

    void *dlopenAddr = dlsym(RTLD_DEFAULT, "dlopen");
    if (!dlopenAddr) {
        FLogError(@"无法获取 dlopen 地址");
        mach_port_deallocate(mach_task_self(), targetTask);
        return -4;
    }

    void *pthreadSetSelfAddr = dlsym(RTLD_DEFAULT, "__pthread_set_self");
    if (!pthreadSetSelfAddr) {
        void *h = dlopen("/usr/lib/system/libsystem_pthread.dylib", RTLD_NOLOAD);
        if (h) pthreadSetSelfAddr = dlsym(h, "__pthread_set_self");
    }
    if (!pthreadSetSelfAddr)
        pthreadSetSelfAddr = FuckFindSymbolInImage("libsystem_pthread", "__pthread_set_self");
    if (!pthreadSetSelfAddr)
        pthreadSetSelfAddr = FuckFindPthreadSetSelfByMSR();
    void *pthreadMainThreadAddr = dlsym(RTLD_DEFAULT, "pthread_main_thread_np");

    FLog(@"dlopen=%p, pss=%p, pmtn=%p", dlopenAddr, pthreadSetSelfAddr, pthreadMainThreadAddr);

    mach_vm_address_t remoteAddr = 0;
    mach_vm_size_t allocSize = 0x100000;
    kr = mach_vm_allocate(targetTask, &remoteAddr, allocSize, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) {
        FLogError(@"mach_vm_allocate 失败: %d", kr);
        mach_port_deallocate(mach_task_self(), targetTask);
        return -5;
    }

    size_t pathLen = strlen(dylibPath) + 1;
    kr = mach_vm_write(targetTask, remoteAddr, (vm_offset_t)dylibPath, (mach_msg_type_number_t)pathLen);
    if (kr != KERN_SUCCESS) {
        FLogError(@"写入路径失败: %d", kr);
        mach_vm_deallocate(targetTask, remoteAddr, allocSize);
        mach_port_deallocate(mach_task_self(), targetTask);
        return -6;
    }
    mach_vm_protect(targetTask, remoteAddr, allocSize, FALSE, VM_PROT_READ | VM_PROT_WRITE);

    // Sandbox Extension
    //
    // 模式 A（严格复刻）：绝不主动申请 extension。原实现的语义是
    //   「dylib 已在目标 App 自己的 bundle 目录内，目标进程天然有权读」，
    //   只有当内核判定仍然缺权限时才补发 token。
    // 模式 B（无痕）：dylib 在我方 tmp 目录，必然需要 extension 授权，
    //   主动申请并注入 consume。
    int readExtNeeded = sandbox_check(targetPID, "file-read-data",
                                       FUCK_SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT, dylibPath);
    int execExtNeeded = sandbox_check(targetPID, "file-map-executable",
                                       FUCK_SANDBOX_FILTER_PATH | SANDBOX_CHECK_NO_REPORT, dylibPath);
    if (mode == FuckInjectModeB) {
        // 无痕模式一律申请，保证目标进程能 mmap(PROT_EXEC) 我方 tmp 下的文件
        if (!readExtNeeded) readExtNeeded = 1;
        if (!execExtNeeded) execExtNeeded = 1;
    }
    FLog(@"[Sandbox] readExt=%d, execExt=%d (模式 %s)",
         readExtNeeded, execExtNeeded, mode == FuckInjectModeA ? "A" : "B");

    char *sbxTokenRead = readExtNeeded ? sandbox_extension_issue_file(APP_SANDBOX_READ, dylibPath, 0) : NULL;
    char *sbxTokenExec = execExtNeeded ? sandbox_extension_issue_file("com.apple.sandbox.executable", dylibPath, 0) : NULL;
    FLog(@"[Sandbox] token read: %s", sbxTokenRead ?: "(NULL)");
    FLog(@"[Sandbox] token exec: %s", sbxTokenExec ?: "(NULL)");

    // 如果 exec token 为 NULL，尝试其他 extension class
    if (!sbxTokenExec && execExtNeeded) {
        sbxTokenExec = sandbox_extension_issue_file("com.apple.sandbox.executable", dylibPath, 1);
        FLog(@"[Sandbox] retry exec token (flags=1): %s", sbxTokenExec ?: "(NULL)");
    }
    if (!sbxTokenExec && execExtNeeded) {
        sbxTokenExec = sandbox_extension_issue_file(APP_SANDBOX_READ_WRITE, dylibPath, 0);
        FLog(@"[Sandbox] fallback RW token: %s", sbxTokenExec ?: "(NULL)");
    }

    uint64_t tokenReadOff = 0x2000, tokenExecOff = 0x3000;
    BOOL hasSbxRead = NO, hasSbxExec = NO;
    if (sbxTokenRead) {
        size_t tl = strlen(sbxTokenRead) + 1;
        kr = mach_vm_write(targetTask, remoteAddr + tokenReadOff, (vm_offset_t)sbxTokenRead, (mach_msg_type_number_t)tl);
        if (kr == KERN_SUCCESS) {
            hasSbxRead = YES;
            FLog(@"[Sandbox] wrote read token to remote (%zu bytes)", tl);
        } else {
            FLogError(@"[Sandbox] failed to write read token: %d", kr);
        }
        free(sbxTokenRead);
    }
    if (sbxTokenExec) {
        size_t tl = strlen(sbxTokenExec) + 1;
        kr = mach_vm_write(targetTask, remoteAddr + tokenExecOff, (vm_offset_t)sbxTokenExec, (mach_msg_type_number_t)tl);
        if (kr == KERN_SUCCESS) {
            hasSbxExec = YES;
            FLog(@"[Sandbox] wrote exec token to remote (%zu bytes)", tl);
        } else {
            FLogError(@"[Sandbox] failed to write exec token: %d", kr);
        }
        free(sbxTokenExec);
    }
    FLog(@"[Sandbox] hasSbxRead=%d, hasSbxExec=%d", hasSbxRead, hasSbxExec);
    void *sbxConsumeAddr = dlsym(RTLD_DEFAULT, "sandbox_extension_consume");
    FLog(@"[Sandbox] sandbox_extension_consume: %p", sbxConsumeAddr);

#ifdef __arm64__
    uint64_t stackAddr = remoteAddr + 0x80000;
    thread_act_t remoteThread = MACH_PORT_NULL;
    BOOL done = NO;
    arm_thread_state64_t state;

    if (pthreadSetSelfAddr && pthreadMainThreadAddr) {
        // Phase 2a: pthread_main_thread_np
        memset(&state, 0, sizeof(state));
        __darwin_arm_thread_state64_set_pc_fptr(state, pthreadMainThreadAddr);
        __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
        __darwin_arm_thread_state64_set_sp(state, stackAddr);
        kr = thread_create_running(targetTask, ARM_THREAD_STATE64,
                                   (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &remoteThread);
        if (kr != KERN_SUCCESS) {
            FLogError(@"Phase 2a thread_create_running 失败: %d", kr);
            mach_vm_deallocate(targetTask, remoteAddr, allocSize);
            mach_port_deallocate(mach_task_self(), targetTask);
            return -7;
        }
        if (!FuckWaitForRemoteThread(remoteThread, ropLoop, 5000)) {
            FLogError(@"Phase 2a 超时");
            thread_terminate(remoteThread);
            mach_vm_deallocate(targetTask, remoteAddr, allocSize);
            mach_port_deallocate(mach_task_self(), targetTask);
            return -8;
        }

        arm_thread_state64_t rs;
        mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
        thread_get_state(remoteThread, ARM_THREAD_STATE64, (thread_state_t)&rs, &cnt);
        uint64_t mainThreadPtr = rs.__x[0];
        FLog(@"[Phase 2a] 主线程指针: 0x%llx", mainThreadPtr);

        if (mainThreadPtr != 0) {
            // Phase 2b: __pthread_set_self
            thread_suspend(remoteThread);
            memset(&state, 0, sizeof(state));
            state.__x[0] = mainThreadPtr;
            __darwin_arm_thread_state64_set_pc_fptr(state, pthreadSetSelfAddr);
            __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
            __darwin_arm_thread_state64_set_sp(state, stackAddr);
            thread_set_state(remoteThread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
            thread_resume(remoteThread);
            if (!FuckWaitForRemoteThread(remoteThread, ropLoop, 5000)) {
                FLogError(@"Phase 2b 超时");
                thread_terminate(remoteThread);
                mach_vm_deallocate(targetTask, remoteAddr, allocSize);
                mach_port_deallocate(mach_task_self(), targetTask);
                return -9;
            }
            FLogSuccess(@"TLS 初始化完成");
        }

        // Phase 2.5: sandbox extension consume
        if (sbxConsumeAddr && hasSbxRead) {
            thread_suspend(remoteThread);
            memset(&state, 0, sizeof(state));
            state.__x[0] = remoteAddr + tokenReadOff;
            __darwin_arm_thread_state64_set_pc_fptr(state, sbxConsumeAddr);
            __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
            __darwin_arm_thread_state64_set_sp(state, stackAddr);
            thread_set_state(remoteThread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
            thread_resume(remoteThread);
            FuckWaitForRemoteThread(remoteThread, ropLoop, 5000);
        }
        if (sbxConsumeAddr && hasSbxExec) {
            thread_suspend(remoteThread);
            memset(&state, 0, sizeof(state));
            state.__x[0] = remoteAddr + tokenExecOff;
            __darwin_arm_thread_state64_set_pc_fptr(state, sbxConsumeAddr);
            __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
            __darwin_arm_thread_state64_set_sp(state, stackAddr);
            thread_set_state(remoteThread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
            thread_resume(remoteThread);
            FuckWaitForRemoteThread(remoteThread, ropLoop, 5000);
        }

        // Phase 3: dlopen
        FLog(@"[Phase 3] 调用 dlopen(path, RTLD_NOW)...");
        thread_suspend(remoteThread);
        memset(&state, 0, sizeof(state));
        state.__x[0] = remoteAddr;
        state.__x[1] = 2; // RTLD_NOW
        __darwin_arm_thread_state64_set_pc_fptr(state, dlopenAddr);
        __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
        __darwin_arm_thread_state64_set_sp(state, stackAddr);
        thread_set_state(remoteThread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
        thread_resume(remoteThread);
        done = FuckWaitForRemoteThread(remoteThread, ropLoop, 15000);
        if (remoteThread != MACH_PORT_NULL) thread_terminate(remoteThread);

    } else {
        // ===== 替代方案: pthread_create_from_mach_thread =====
        void *pcfmt = dlsym(RTLD_DEFAULT, "pthread_create_from_mach_thread");
        if (!pcfmt) {
            FLogError(@"pthread_create_from_mach_thread 不可用");
            mach_vm_deallocate(targetTask, remoteAddr, allocSize);
            mach_port_deallocate(mach_task_self(), targetTask);
            return -10;
        }

        FLog(@"[替代方案] pthread_create_from_mach_thread: %p", pcfmt);
        thread_act_array_t tBefore = NULL;
        mach_msg_type_number_t cBefore = 0;
        task_threads(targetTask, &tBefore, &cBefore);

        memset(&state, 0, sizeof(state));
        state.__x[0] = remoteAddr + 0x1000;
        state.__x[1] = 0;
        state.__x[2] = ropLoop;
        state.__x[3] = 0;
        __darwin_arm_thread_state64_set_pc_fptr(state, pcfmt);
        __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
        __darwin_arm_thread_state64_set_sp(state, stackAddr);
        kr = thread_create_running(targetTask, ARM_THREAD_STATE64,
                                   (thread_state_t)&state, ARM_THREAD_STATE64_COUNT, &remoteThread);
        if (kr != KERN_SUCCESS) {
            FLogError(@"thread_create_running 失败: %d", kr);
            vm_deallocate(mach_task_self(), (vm_address_t)tBefore, cBefore * sizeof(thread_act_t));
            mach_vm_deallocate(targetTask, remoteAddr, allocSize);
            mach_port_deallocate(mach_task_self(), targetTask);
            return -7;
        }
        if (!FuckWaitForRemoteThread(remoteThread, ropLoop, 10000)) {
            FLogError(@"pthread_create_from_mach_thread 超时");
            thread_terminate(remoteThread);
            vm_deallocate(mach_task_self(), (vm_address_t)tBefore, cBefore * sizeof(thread_act_t));
            mach_vm_deallocate(targetTask, remoteAddr, allocSize);
            mach_port_deallocate(mach_task_self(), targetTask);
            return -8;
        }


        // 检查 pthread_create_from_mach_thread 的返回值 (x0)
        {
            arm_thread_state64_t retState;
            mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
            kr = thread_get_state(remoteThread, ARM_THREAD_STATE64,
                                  (thread_state_t)&retState, &cnt);
            if (kr == KERN_SUCCESS) {
                int retVal = (int)retState.__x[0];
                FLog(@"pthread_create_from_mach_thread 返回: %d", retVal);
            }
        }
        usleep(100000);
        thread_act_array_t tAfter = NULL;
        mach_msg_type_number_t cAfter = 0;
        task_threads(targetTask, &tAfter, &cAfter);

        thread_act_t newPt = MACH_PORT_NULL;
        for (mach_msg_type_number_t i = 0; i < cAfter; i++) {
            BOOL isOld = (tAfter[i] == remoteThread);
            for (mach_msg_type_number_t j = 0; !isOld && j < cBefore; j++) {
                if (tAfter[i] == tBefore[j]) isOld = YES;
            }
            if (isOld) continue;
            arm_thread_state64_t cs;
            mach_msg_type_number_t cc = ARM_THREAD_STATE64_COUNT;
            if (thread_get_state(tAfter[i], ARM_THREAD_STATE64, (thread_state_t)&cs, &cc) == KERN_SUCCESS) {
                if (__darwin_arm_thread_state64_get_pc(cs) == ropLoop) { newPt = tAfter[i]; break; }
            }
        }
        vm_deallocate(mach_task_self(), (vm_address_t)tBefore, cBefore * sizeof(thread_act_t));
        vm_deallocate(mach_task_self(), (vm_address_t)tAfter, cAfter * sizeof(thread_act_t));

        if (newPt == MACH_PORT_NULL) {
            FLogError(@"未找到新 pthread 线程");
            thread_terminate(remoteThread);
            mach_vm_deallocate(targetTask, remoteAddr, allocSize);
            mach_port_deallocate(mach_task_self(), targetTask);
            return -9;
        }

        // sandbox consume on new pthread
        if (sbxConsumeAddr && hasSbxRead) {
            thread_suspend(newPt);
            memset(&state, 0, sizeof(state));
            state.__x[0] = remoteAddr + tokenReadOff;
            __darwin_arm_thread_state64_set_pc_fptr(state, sbxConsumeAddr);
            __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
            __darwin_arm_thread_state64_set_sp(state, stackAddr - 0x1000);
            thread_set_state(newPt, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
            thread_resume(newPt);
            FuckWaitForRemoteThread(newPt, ropLoop, 5000);
        }
        if (sbxConsumeAddr && hasSbxExec) {
            thread_suspend(newPt);
            memset(&state, 0, sizeof(state));
            state.__x[0] = remoteAddr + tokenExecOff;
            __darwin_arm_thread_state64_set_pc_fptr(state, sbxConsumeAddr);
            __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
            __darwin_arm_thread_state64_set_sp(state, stackAddr - 0x1000);
            thread_set_state(newPt, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
            thread_resume(newPt);
            FuckWaitForRemoteThread(newPt, ropLoop, 5000);
        }

        // dlopen on new pthread
        FLog(@"[Phase 3] 复用 pthread 调用 dlopen...");
        thread_suspend(newPt);
        memset(&state, 0, sizeof(state));
        state.__x[0] = remoteAddr;
        state.__x[1] = 2; // RTLD_NOW
        __darwin_arm_thread_state64_set_pc_fptr(state, dlopenAddr);
        __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
        __darwin_arm_thread_state64_set_sp(state, stackAddr - 0x1000);
        thread_set_state(newPt, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
        thread_resume(newPt);
        done = FuckWaitForRemoteThread(newPt, ropLoop, 15000);

        // 读取 dlopen 返回值
        if (done) {
            arm_thread_state64_t finalState;
            mach_msg_type_number_t finalCount = ARM_THREAD_STATE64_COUNT;
            kr = thread_get_state(newPt, ARM_THREAD_STATE64,
                                  (thread_state_t)&finalState, &finalCount);
            if (kr == KERN_SUCCESS) {
                uint64_t handle = finalState.__x[0];
                if (handle != 0) {
                    FLogSuccess(@"dlopen 返回 handle=0x%llx", handle);
                } else {
                    FLogError(@"dlopen 返回 NULL — 调用 dlerror 获取详情...");
                    done = NO;
                    void *dlerrorAddr = dlsym(RTLD_DEFAULT, "dlerror");
                    if (dlerrorAddr) {
                        thread_suspend(newPt);
                        memset(&state, 0, sizeof(state));
                        __darwin_arm_thread_state64_set_pc_fptr(state, dlerrorAddr);
                        __darwin_arm_thread_state64_set_lr_fptr(state, (void *)ropLoop);
                        __darwin_arm_thread_state64_set_sp(state, stackAddr - 0x1000);
                        thread_set_state(newPt, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT);
                        thread_resume(newPt);
                        if (FuckWaitForRemoteThread(newPt, ropLoop, 5000)) {
                            arm_thread_state64_t errState;
                            mach_msg_type_number_t errCnt = ARM_THREAD_STATE64_COUNT;
                            kr = thread_get_state(newPt, ARM_THREAD_STATE64, (thread_state_t)&errState, &errCnt);
                            if (kr == KERN_SUCCESS && errState.__x[0] != 0) {
                                uint64_t errStrAddr = errState.__x[0];
                                char errBuf[512] = {0};
                                mach_vm_size_t readSize = 0;
                                kr = mach_vm_read_overwrite(targetTask, errStrAddr, sizeof(errBuf) - 1,
                                                            (mach_vm_address_t)errBuf, &readSize);
                                if (kr == KERN_SUCCESS && readSize > 0) {
                                    errBuf[readSize] = '\0';
                                    FLogError(@"dlerror: %s", errBuf);
                                } else {
                                    FLogError(@"dlerror 返回地址 0x%llx 但读取失败: %d", errStrAddr, kr);
                                }
                            } else {
                                FLog(@"dlerror 返回 NULL (无额外错误信息)");
                            }
                        }
                    }
                }
            }
        }
        thread_terminate(newPt);
        thread_terminate(remoteThread);
    }

    mach_port_deallocate(mach_task_self(), targetTask);
    FLog(@"========== OPAINJECT %@ ==========", done ? @"成功" : @"失败");
    return done ? 0 : -9;
#else
    mach_vm_deallocate(targetTask, remoteAddr, allocSize);
    mach_port_deallocate(mach_task_self(), targetTask);
    return -10;
#endif
}

// ============== dylib ad-hoc 签名 ==============

static BOOL FuckSignDylibAdHoc(NSString *targetPath) {
    FLog(@"[Sign] ad-hoc 签名: %@", targetPath);
    NSString *ldidPath = FuckResourcePath(@"ldid");
    if (!ldidPath.length || !targetPath.length) return NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:targetPath]) return NO;
    chmod(ldidPath.UTF8String, 0755);
    NSArray *args = @[ldidPath, @"-S", targetPath];
    int ret = FuckSpawnArguments(args, NO);
    if (ret == 0) FLogSuccess(@"ad-hoc 签名成功");
    else FLogError(@"ad-hoc 签名失败, ret=%d", ret);
    return ret == 0;
}

// ct_bypass CoreTrust bypass 签名
static BOOL FuckCTBypass(NSString *targetPath, NSString *teamID) {
    FLog(@"[CTB] CoreTrust bypass: %@, teamID=%@", targetPath, teamID);
    NSString *ctbPath = FuckResourcePath(@"ct_bypass");
    if (!ctbPath.length) { FLogError(@"ct_bypass 工具不存在"); return NO; }
    chmod(ctbPath.UTF8String, 0755);
    NSArray *args = @[ctbPath, @"-i", targetPath, @"-r", @"-t", teamID ?: @""];
    int ret = FuckSpawnArguments(args, YES);
    if (ret == 0) FLogSuccess(@"ct_bypass 成功");
    else FLogError(@"ct_bypass 失败, ret=%d", ret);
    return ret == 0;
}

// ============== 公开接口实现 ==============



// ============== 目标进程崩溃日志抓取 ==============
//
// 注入后若目标 App 闪退，把对应的 .ips 崩溃报告摘要追加到注入日志，
// 便于在 App 内直接看到失败原因（无需连电脑看 Xcode 设备日志）。
// iOS 崩溃报告目录：/var/mobile/Library/Logs/CrashReporter/
static void FuckCaptureTargetCrashLog(NSString *bundleID, NSString *execName) {
    if (!bundleID.length) return;

    NSArray<NSString *> *dirs = @[
        @"/var/mobile/Library/Logs/CrashReporter",
        @"/var/mobile/Library/Logs/CrashReporter/DiagnosticLogs",
        @"/var/root/Library/Logs/CrashReporter",
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *prefix = execName.length ? execName : bundleID;

    for (NSString *dir in dirs) {
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:nil];
        if (!items.count) continue;

        // 取最近 3 分钟内、文件名包含目标进程名的报告
        NSMutableArray<NSDictionary *> *hits = [NSMutableArray array];
        NSDate *now = [NSDate date];
        for (NSString *name in items) {
            if (![name containsString:prefix] && ![name containsString:bundleID]) continue;
            if (![name hasSuffix:@".ips"] && ![name hasSuffix:@".crash"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            NSDate *mtime = attrs[NSFileModificationDate];
            if (!mtime || [now timeIntervalSinceDate:mtime] > 180) continue;
            [hits addObject:@{@"path": full, @"mtime": mtime}];
        }
        if (!hits.count) continue;

        [hits sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"mtime"] compare:a[@"mtime"]];
        }];

        NSDictionary *latest = hits.firstObject;
        NSString *content = [NSString stringWithContentsOfFile:latest[@"path"]
                                                      encoding:NSUTF8StringEncoding error:nil];
        if (!content.length) continue;

        // .ips 是「首行 JSON + 正文 JSON」，截取前 6KB 足够定位异常类型
        NSString *excerpt = content.length > 6144 ? [content substringToIndex:6144] : content;
        FLog(@"========== 检测到目标进程崩溃报告 ==========");
        FLog(@"报告文件: %@", latest[@"path"]);
        FLog(@"内容摘要:\n%@", excerpt);
        FLog(@"========== 崩溃报告结束 ==========");
        return;
    }
    FLog(@"[Crash] 未在崩溃目录找到 %@ 的近期报告", prefix);
}

@implementation FuckDynamicInjector

// ===== CLI entry: runs as root subprocess =====
// Called from main() when argv[1] == "-FuckInject"
// Reference: DGHandleSet2cdCommand in reference project
+ (int)cliInjectWithDylibPath:(NSString *)dylibPath bundleID:(NSString *)bundleID mode:(int)modeInt {
    FuckInjectMode mode = (modeInt == 1) ? FuckInjectModeB : FuckInjectModeA;
    FLog(@"========== FuckInject CLI mode (root subprocess) ==========");
    FLog(@"dylib: %@, bundleID: %@", dylibPath, bundleID);
    FLog(@"注入模式: %s", mode == FuckInjectModeA ? "A/严格复刻（拷入目标 bundle 同级目录）" : "B/无痕（仅在 tmp，注入后清除）");
    FLog(@"UID: %d, EUID: %d", getuid(), geteuid());

    if (!dylibPath.length || !bundleID.length) {
        FLogError(@"invalid arguments");
        return 1;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
        FLogError(@"dylib not found: %@", dylibPath);
        return 2;
    }

    // ===== Step 1: 复制 dylib 到目标 App 的 .app 同级目录 =====
    // 参考项目: DGCopyAndSignPayloadDylib → DGCoreTargetPath = bundleContainer/Core
    // dlopen 会被沙盒拦截 mmap(PROT_EXEC)，文件必须在目标 App 的 bundle container 内
    NSString *targetBundlePath = FuckProxyPathFromURL(FuckProxyForBundleID(bundleID), @"bundleURL");
    NSString *injectedDylibPath = dylibPath; // fallback
    if (mode == FuckInjectModeA && targetBundlePath.length) {
        NSString *containerPath = [targetBundlePath stringByDeletingLastPathComponent];
        NSString *dylibName = [dylibPath lastPathComponent];
        NSString *destPath = [containerPath stringByAppendingPathComponent:dylibName];
        FLog(@"[CLI] Step 1: copy dylib to bundle container");
        FLog(@"[CLI]   src: %@", dylibPath);
        FLog(@"[CLI]   dst: %@", destPath);

        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:destPath error:nil];
        NSError *copyErr = nil;
        if ([fm copyItemAtPath:dylibPath toPath:destPath error:&copyErr]) {
            chmod(destPath.UTF8String, 0755);
            chown(destPath.UTF8String, 0, 0);
            injectedDylibPath = destPath;
            FLogSuccess(@"[CLI] copied to: %@", destPath);
        } else {
            FLogError(@"[CLI] copy failed: %@", copyErr.localizedDescription);
        }
    } else if (mode == FuckInjectModeA) {
        FLogError(@"[CLI] cannot get target bundle path");
    } else {
        // 模式 B：dylib 留在原处（主进程已放在我方 tmp），不往目标 App 目录写任何文件
        FLog(@"[CLI] 无痕模式：沿用原始路径 %@", injectedDylibPath);
    }

    // ===== Step 2: CoreTrust bypass (对复制后的文件签名) =====
    NSString *targetTeamID = FuckExtractTeamIDFromApp(bundleID);
    FLog(@"[CLI] target TeamID: %@", targetTeamID ?: @"(none)");

    // 模式 B 仅做 ldid ad-hoc 签名（trust cache 由 roothide jbserver 负责），
    // 不跑 ct_bypass —— 该漏洞在 iOS 17.0 起已收紧，跑了只会引入失败分支。
    if (mode == FuckInjectModeB) {
        NSString *ldidPathOnly = FuckResourcePath(@"ldid");
        if (ldidPathOnly.length) {
            chmod(ldidPathOnly.UTF8String, 0755);
            int lr = FuckSpawnArguments(@[ldidPathOnly, @"-S", injectedDylibPath], YES);
            FLog(@"[CLI] (模式B) ldid -S => ret=%d", lr);
        } else {
            FLog(@"[CLI] (模式B) ldid 不在 bundle 内，跳过 ad-hoc 签名");
        }
    } else if (targetTeamID.length > 0) {
        NSString *ctBypassPath = FuckResourcePath(@"ct_bypass");
        NSString *ldidPath = FuckResourcePath(@"ldid");

        if (ctBypassPath.length && ldidPath.length) {
            chmod(ldidPath.UTF8String, 0755);
            chmod(ctBypassPath.UTF8String, 0755);

            NSDictionary *preAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:injectedDylibPath error:NULL];
            unsigned long long preSz = [preAttrs fileSize];

            // ldid -S (ad-hoc sign)
            FLog(@"[CLI] Step 2a: ldid -S %@", injectedDylibPath);
            int ldidRet = FuckSpawnArguments(@[ldidPath, @"-S", injectedDylibPath], YES);
            FLog(@"[CLI] ldid -S => ret=%d", ldidRet);

            NSDictionary *midAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:injectedDylibPath error:NULL];
            unsigned long long midSz = [midAttrs fileSize];
            FLog(@"[CLI] after ldid: %llu bytes (delta=%+lld)", midSz, (long long)(midSz - preSz));

            // ct_bypass -i <dylib> -r -t <teamID>
            FLog(@"[CLI] Step 2b: ct_bypass -i %@ -r -t %@", injectedDylibPath, targetTeamID);
            int ctRet = FuckSpawnArguments(@[ctBypassPath, @"-i", injectedDylibPath, @"-r", @"-t", targetTeamID], YES);
            FLog(@"[CLI] ct_bypass => ret=%d", ctRet);

            NSDictionary *postAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:injectedDylibPath error:NULL];
            unsigned long long postSz = [postAttrs fileSize];
            FLog(@"[CLI] after ct_bypass: %llu bytes (delta=%+lld)", postSz, (long long)(postSz - midSz));

            if (ctRet != 0) {
                FLogError(@"ct_bypass failed (ret=%d)", ctRet);
            } else if (postSz <= midSz) {
                FLogError(@"ct_bypass returned 0 but file size did not increase");
            } else {
                FLogSuccess(@"CoreTrust bypass OK: TeamID=%@, +%lld bytes", targetTeamID, (long long)(postSz - midSz));
            }
        } else {
            FLogError(@"tools missing: ct_bypass=%@, ldid=%@", ctBypassPath ?: @"nil", ldidPath ?: @"nil");
        }
    } else {
        FLogError(@"no TeamID extracted, skipping ct_bypass");
    }

    // ===== Step 3: chmod/chown =====
    chmod(injectedDylibPath.UTF8String, 0755);
    chown(injectedDylibPath.UTF8String, 0, 0);
    FLog(@"[CLI] chmod 0755, chown 0:0");

    // ===== Step 4: find target, inject =====
    // 注意: CLI 子进程没有 UI 环境，不能调用 LSApplicationWorkspace (会 SIGSEGV)
    // 目标 App 必须由主进程在 spawn 之前启动
    pid_t pid = FuckFindPIDForBundleID(bundleID);
    if (pid <= 0) {
        // 重试几次，目标可能正在启动中
        for (int retry = 0; retry < 5 && pid <= 0; retry++) {
            FLog(@"[CLI] target not running, waiting... (retry %d/5)", retry + 1);
            usleep(1000000); // 1s
            pid = FuckFindPIDForBundleID(bundleID);
        }
        if (pid <= 0) {
            FLogError(@"target process not found after retries");
            // 清理已复制的 dylib 后再退出
            if (![injectedDylibPath isEqualToString:dylibPath]) {
                [[NSFileManager defaultManager] removeItemAtPath:injectedDylibPath error:nil];
                FLog(@"[CLI] cleaned up (PID not found): %@", injectedDylibPath);
            }
            return 3;
        }
    }

    // ===== Step 5: 执行注入（失败重试最多 3 次）=====
    int ret = -1;
    for (int attempt = 1; attempt <= 3; attempt++) {
        FLog(@"[CLI] inject attempt %d/3, PID=%d", attempt, pid);
        ret = FuckOpaInject(pid, injectedDylibPath.UTF8String, mode);
        if (ret == 0) {
            FLogSuccess(@"injection succeeded!");
            break;
        }
        FLogError(@"injection failed (code: %d) attempt %d/3", ret, attempt);
        if (attempt < 3) {
            // 等待后刷新 PID（进程可能被系统重启）
            usleep(800000); // 0.8s
            pid_t newPid = FuckFindPIDForBundleID(bundleID);
            if (newPid > 0 && newPid != pid) {
                FLog(@"[CLI] PID changed: %d -> %d", pid, newPid);
                pid = newPid;
            } else if (newPid <= 0) {
                FLogError(@"[CLI] target process gone, stop retrying");
                break;
            }
        }
    }

    // 清理: 删除复制到 bundle container 的 dylib（无论成功失败都清理）
    if (![injectedDylibPath isEqualToString:dylibPath]) {
        if ([[NSFileManager defaultManager] removeItemAtPath:injectedDylibPath error:nil]) {
            FLog(@"[CLI] cleaned up: %@", injectedDylibPath);
        } else {
            FLogError(@"[CLI] cleanup failed: %@", injectedDylibPath);
        }
    }

    return ret;
}

// ===== Public API: spawn root subprocess to do injection =====
// Reference: DGHandleThreadDynamicAction spawns self with kDGHelperSet2cd as root
+ (void)injectDylib:(NSString *)dylibPath
        intoBundleID:(NSString *)bundleID
                mode:(int)mode
            progress:(void (^)(NSString *step))progress
          completion:(void (^)(BOOL success, NSString *message))completion {

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        void (^reportProgress)(NSString *) = ^(NSString *step) {
            if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(step); });
        };
        void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, msg); });
        };

        FLog(@"========== FuckDynamicInjector start ==========");
        FLog(@"dylib: %@, bundleID: %@", dylibPath, bundleID);
        FLog(@"current UID: %d (will spawn root subprocess)", getuid());

        if (!dylibPath.length || !bundleID.length) {
            finish(NO, @"invalid arguments");
            return;
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
            finish(NO, [NSString stringWithFormat:@"dylib not found: %@", dylibPath]);
            return;
        }

        // 每次都打开目标 App（后台挂起的进程无法执行注入线程）
        // 打开后立即返回自己的 App
        reportProgress(@"[1/3] 启动目标 App...");
        FLog(@"[SPAWN] opening %@ (ensure foreground)...", bundleID);
        FuckOpenApp(bundleID);
        usleep(1500000); // 等 1.5 秒让目标 App 到前台

        // 返回自己的 App
        NSString *selfBundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (selfBundleID.length) {
            FLog(@"[SPAWN] returning to self: %@", selfBundleID);
            FuckOpenApp(selfBundleID);
            usleep(500000); // 等 0.5 秒切回
        }

        // 等待目标进程就绪（轮询，不用固定时间）
        reportProgress(@"[2/3] 等待目标进程就绪...");
        pid_t targetPid = -1;
        for (int i = 0; i < 10; i++) {
            targetPid = FuckFindPIDForBundleID(bundleID);
            if (targetPid > 0) break;
            usleep(500000); // 每 0.5 秒检查一次
        }
        if (targetPid <= 0) {
            FLogError(@"target app failed to launch");
            finish(NO, @"无法启动目标 App");
            return;
        }
        FLog(@"[SPAWN] target PID: %d", targetPid);

        // Spawn self as root subprocess with -FuckInject <dylibPath> <bundleID>
        // 参考项目: DGSpawnArgumentsNoWait(injectArgs, YES)
        reportProgress(@"[3/3] 执行 root 注入...");

        NSString *exe = [[NSBundle mainBundle] executablePath];
        FLog(@"[SPAWN] executable: %@", exe);
        FLog(@"[SPAWN] args: -FuckInject %@ %@", dylibPath, bundleID);

        // 把日志路径与注入模式通过环境变量传给 root 子进程
        NSString *logPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                             stringByAppendingPathComponent:@"inject_debug.log"];
        setenv("FUCK_INJECT_LOG_PATH", logPath.UTF8String, 1);
        setenv("FUCK_INJECT_MODE", [[NSString stringWithFormat:@"%d", mode] UTF8String], 1);

        NSArray *args = @[exe, @"-FuckInject", dylibPath, bundleID,
                          [NSString stringWithFormat:@"%d", mode]];
        int rawStatus = FuckSpawnArguments(args, YES);

        // FuckSpawnArguments 返回 waitpid 的 raw status，需要 WEXITSTATUS 解析
        int ret = WIFEXITED(rawStatus) ? WEXITSTATUS(rawStatus) : -1;
        FLog(@"[SPAWN] root subprocess raw status: %d, exit code: %d", rawStatus, ret);

        if (ret == 0) {
            FLogSuccess(@"动态注入成功 (root 子进程)");
            finish(YES, @"动态注入成功");
        } else {
            NSString *errMsg;
            if (WIFSIGNALED(rawStatus)) {
                int sig = WTERMSIG(rawStatus);
                errMsg = [NSString stringWithFormat:@"注入子进程被信号 %d 杀死", sig];
            } else {
                errMsg = [NSString stringWithFormat:@"注入失败 (错误码: %d)", ret];
            }
            FLogError(@"%@", errMsg);

            // 目标 App 可能因注入而闪退 —— 抓它的崩溃报告一起归档
            NSString *execPath = FuckCanonicalExecutablePath(bundleID);
            NSString *execName = execPath.length ? [execPath lastPathComponent] : nil;
            FuckCaptureTargetCrashLog(bundleID, execName);

            finish(NO, errMsg);
        }
    });
}

@end
