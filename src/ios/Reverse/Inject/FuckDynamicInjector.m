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

// 扫描 roothide 的随机越狱根。
//
// 为什么必须扫：roothide 把越狱环境放在
//   /var/containers/Bundle/Application/.jbroot-<32位十六进制>
// 下面（也在 AppGroup 里放一份）。写死 /var/jb 在本机不存在 —— 实测
// 那台设备上 /var/jb 完全没有，于是 libjailbreak 永远加载失败，
// 拿不到 jbserver 通道，注入必然失败。
// 判断一个候选目录是否是「完整的」越狱根。
//
// 为什么必须校验：Relaxin/roothide 会在**多个位置**各放一份同名
// .jbroot-<hex>，但内容并不相同（实测这台设备）：
//   /var/containers/Bundle/Application/.jbroot-XXX/   完整（含 basebin/usr/System…）
//   /var/mobile/Containers/Shared/AppGroup/.jbroot-XXX/  只是部分镜像
//                                                        （仅有 var/ 与 .jbroot）
// 只按名字找到第一个就返回，会拿到那份不完整的，随后
// basebin/libjailbreak.dylib 不存在，dlopen 直接失败。
//
// 判据：必须含 basebin/ 或 usr/lib/ 且其中确有 libjailbreak。
static BOOL FuckIsCompleteJailbreakRoot(NSString *path) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *marks = @[
        @"basebin/libjailbreak.dylib",
        @"usr/lib/libjailbreak.dylib",
        @"basebin/jailbreakd",
        @"usr/bin/jbctl",
    ];
    for (NSString *m in marks) {
        if ([fm fileExistsAtPath:[path stringByAppendingPathComponent:m]]) return YES;
    }
    return NO;
}

static NSString *FuckScanJailbreakRoot(void) {
    // 1) 环境变量显式指定（最高优先，且也做完整性校验）
    const char *envRoot = getenv("MINIS_JBROOT");
    if (envRoot && envRoot[0]) {
        NSString *e = [NSString stringWithUTF8String:envRoot];
        if (FuckIsCompleteJailbreakRoot(e)) {
            FLog(@"[roothide] 使用 MINIS_JBROOT 指定的根: %@", e);
            return e;
        }
        FLog(@"[roothide] MINIS_JBROOT=%@ 不是完整越狱根，忽略", e);
    }

    // 2) 依次扫描各父目录。
    //    顺序有意为之：App 安装目录下的那份是完整的，优先；
    //    AppGroup 那份常是部分镜像，放最后。
    NSArray<NSString *> *parents = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application",
        @"/var/mobile/Containers/Shared/AppGroup",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *firstIncomplete = nil;

    for (NSString *parent in parents) {
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:parent error:nil];
        if (!items) continue;

        NSArray<NSString *> *sorted = [items sortedArrayUsingSelector:@selector(compare:)];

        // 先看 .jbroot-* 命名（roothide 的标准形式）
        for (NSString *name in sorted) {
            if (![name hasPrefix:@".jbroot-"]) continue;
            NSString *p = [parent stringByAppendingPathComponent:name];
            if (FuckIsCompleteJailbreakRoot(p)) return p;
            if (!firstIncomplete) {
                firstIncomplete = p;
                FLog(@"[roothide] %@ 是不完整的镜像（无 basebin），继续找", p);
            }
        }
        // 再兜底：任何含 libjailbreak 的隐藏目录
        for (NSString *name in sorted) {
            if (![name hasPrefix:@"."]) continue;
            if ([name hasPrefix:@".jbroot-"]) continue;   // 上一轮已查
            NSString *p = [parent stringByAppendingPathComponent:name];
            if (FuckIsCompleteJailbreakRoot(p)) return p;
        }
    }

    // 3) 全军覆没：仍返回那个不完整的，至少 dlopen 的候选路径能拼出来，
    //    由调用方的多候选循环去试。
    if (firstIncomplete) {
        FLog(@"[roothide] 未找到完整越狱根，退回不完整镜像: %@", firstIncomplete);
    }
    return firstIncomplete;
}

// 加载 libjailbreak（roothide 版本），返回句柄；失败返回 NULL
static void *FuckLoadLibJailbreak(void) {
    static void *cached = NULL;
    static BOOL tried = NO;
    if (tried) return cached;
    tried = YES;

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];

    // 1) 扫出来的真实根（最可靠）
    NSString *root = FuckScanJailbreakRoot();
    if (root.length) {
        FLog(@"[roothide] 扫描到越狱根: %@", root);
        [candidates addObject:[root stringByAppendingPathComponent:@"basebin/libjailbreak.dylib"]];
        [candidates addObject:[root stringByAppendingPathComponent:@"usr/lib/libjailbreak.dylib"]];
    } else {
        FLog(@"[roothide] 未扫描到 .jbroot-* 目录");
    }

    // 2) 常见固定位置兜底
    [candidates addObjectsFromArray:@[
        @"/var/jb/basebin/libjailbreak.dylib",
        @"/var/jb/usr/lib/libjailbreak.dylib",
        @"/usr/lib/libjailbreak.dylib",
    ]];

    for (NSString *path in candidates) {
        void *h = dlopen(path.UTF8String, RTLD_NOW);
        if (h) {
            cached = h;
            FLog(@"[roothide] libjailbreak 已加载: %@", path);
            return cached;
        }
    }

    // 3) dyld 全局（若 jailbreakd 已经注入过）
    cached = dlopen("libjailbreak.dylib", RTLD_NOW);
    if (cached) {
        FLog(@"[roothide] libjailbreak 从 dyld 加载成功");
    } else {
        FLog(@"[roothide] libjailbreak 未找到（非越狱环境或路径变化）");
    }
    return cached;
}

// 返回 YES 表示走通了 roothide 通道
// ═══════════════════════════════════════════════════════════════
// 提权通道：以 root 身份运行后续流程
// ═══════════════════════════════════════════════════════════════
//
// 这是「和越狱自带工具同级」的关键。越狱自带的 opainject 能注入成功，
// 唯一原因是它以 root 运行；我们以 501 运行，于是 proc_pidpath 看不见
// 别的进程、sandbox extension 发不出、task_for_pid 受限。
//
// roothide 通过 libjailbreak 提供官方提权接口（不是漏洞利用）：
//   jbclient_root_steal_ucred(uid, &out)  向 jailbreakd 请求该 uid 的凭据
//   jbclient_root_sign_thread(...)        让凭据在当前线程生效
//   jbclient_root_set_mac_label(...)      设置沙盒标签，去掉沙盒限制
//
// 三者任一成功即可让后续流程畅通；全失败则退回原有逐项修补的路径。

typedef int (*FuckStealUcredFn)(uint64_t uid, uint64_t *outToken);
typedef int (*FuckSignThreadFn)(uint64_t token);
typedef int (*FuckSetMacLabelFn)(const char *label, uint64_t token);

/// 当前进程是否已经提权（EUID 变为 0）
static BOOL FuckIsElevated(void) {
    return geteuid() == 0;
}

/// 已缓存的提权结果，避免重复请求
static int gElevationResult = -999;

/// 尝试提权到 root。返回 0 表示成功（或本来就已是 root）。
static int FuckTryElevateToRoot(void) {
    if (gElevationResult != -999) return gElevationResult;

    if (FuckIsElevated()) {
        FLog(@"[Elevate] 本进程已是 root，无需提权");
        gElevationResult = 0;
        return 0;
    }

    void *h = FuckLoadLibJailbreak();
    if (!h) {
        FLog(@"[Elevate] libjailbreak 未加载，跳过提权");
        gElevationResult = -1;
        return -1;
    }

    // 1) 偷 root 凭据
    FuckStealUcredFn steal = (FuckStealUcredFn)dlsym(h, "jbclient_root_steal_ucred");
    if (!steal) {
        FLog(@"[Elevate] 无 jbclient_root_steal_ucred 符号");
        gElevationResult = -2;
        return -2;
    }

    uint64_t token = 0;
    int r = steal(0, &token);      // uid 0 = root
    FLog(@"[Elevate] jbclient_root_steal_ucred(0) => %d, token=%llu", r, token);

    if (r != 0 || token == 0) {
        // 提权被拒：多半是调用方缺少 platform 域需要的标志。
        // 不影响后续：原有逐项修补的路径仍然可用。
        FLog(@"[Elevate] 提权被拒（该接口通常要求调用方带 CS_PLATFORM_BINARY）");
        gElevationResult = -3;
        return -3;
    }

    // 2) 让凭据在当前线程生效
    FuckSignThreadFn signThread = (FuckSignThreadFn)dlsym(h, "jbclient_root_sign_thread");
    if (signThread) {
        int sr = signThread(token);
        FLog(@"[Elevate] jbclient_root_sign_thread => %d", sr);
    } else {
        FLog(@"[Elevate] 无 jbclient_root_sign_thread 符号");
    }

    // 3) 设置沙盒标签，去掉沙盒限制
    FuckSetMacLabelFn setLabel = (FuckSetMacLabelFn)dlsym(h, "jbclient_root_set_mac_label");
    if (setLabel) {
        int lr = setLabel("sandbox", token);
        FLog(@"[Elevate] jbclient_root_set_mac_label => %d", lr);
    }

    // 验证是否真的提上去了
    if (FuckIsElevated()) {
        FLogSuccess(@"[Elevate] ✅ 已提权到 root（后续流程按 root 身份执行）");
        gElevationResult = 0;
        return 0;
    }

    FLog(@"[Elevate] 凭据已拿到但 EUID 仍为 %d —— 线程签名可能未生效，"
          @"继续走逐项修补路径", geteuid());
    gElevationResult = -4;
    return -4;
}

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

// 请 roothide 把指定进程标记为可调试（这是 iOS 17 上拿到有效 task port 的前提）
static BOOL FuckRoothideSetProcessDebugged(uint64_t pid, BOOL fully) {
    void *h = FuckLoadLibJailbreak();
    if (!h) {
        FLogError(@"[roothide] libjailbreak 未加载，无法调用 set_process_debugged");
        return NO;
    }

    typedef int (*Fn)(uint64_t, bool);
    void *sym = dlsym(h, "jbclient_platform_set_process_debugged");
    if (!sym) {
        FLog(@"[roothide] 无 jbclient_platform_set_process_debugged 符号");
        return NO;
    }
    int r = ((Fn)sym)(pid, fully ? true : false);
    FLog(@"[roothide] set_process_debugged(pid=%llu, fully=%d) => %d", pid, fully ? 1 : 0, r);
    return r == 0;
}

// 请 roothide 重新校验当前进程的签名（标记 debugged 后有时需要配合这一步）
static BOOL FuckRoothideCSRevalidate(void) {
    void *h = FuckLoadLibJailbreak();
    if (!h) return NO;
    typedef int (*Fn)(void);
    void *sym = dlsym(h, "jbclient_cs_revalidate");
    if (!sym) return NO;
    int r = ((Fn)sym)();
    FLog(@"[roothide] cs_revalidate => %d", r);
    return r == 0;
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

static int FuckSpawnArgumentsWithOutput(NSArray<NSString *> *arguments, BOOL asRootPersona, NSString **outLog);
static int FuckSpawnArguments(NSArray<NSString *> *arguments, BOOL asRootPersona);

static int FuckWaitForPid(pid_t pid) {
    int status = 0;
    while (waitpid(pid, &status, 0) == -1 && errno == EINTR) {}
    return status;
}

static int FuckSpawnArgumentsWithOutput(NSArray<NSString *> *arguments, BOOL asRootPersona, NSString **outLog) {
    if (arguments.count == 0) return -1;

    posix_spawnattr_t attr;
    if (posix_spawnattr_init(&attr) != 0) return -1;

    // ── 信号与会话处理（「子进程被信号 1 杀死」的根因所在）──
    //
    // 这里有一个必须避开的陷阱：
    //   POSIX_SPAWN_SETSIGDEF 的语义是「把集合内的信号恢复为系统默认处理」，
    //   而 SIGHUP 的默认处理恰恰是终止进程。把 SIGHUP 放进 sigdefault 集合，
    //   等于主动要求内核在挂断时杀死子进程 —— 刚好制造了要避免的结果。
    //
    //   而 POSIX_SPAWN_SETSIGIGN 在 Darwin SDK 中并未导出，无法用于设置忽略集。
    //
    // 因此实际生效的手段是：
    //   (a) POSIX_SPAWN_SETSID（存在时）让子进程脱离父进程的会话与进程组；
    //   (b) 子进程自身在入口处 signal(SIG_IGN) —— 见 MinisApp.swift 的
    //       handleInjectionSubprocessIfNeeded，这是最可靠的一层防护。
    short flags = POSIX_SPAWN_CLOEXEC_DEFAULT;

#ifdef POSIX_SPAWN_SETSID
    flags |= POSIX_SPAWN_SETSID;
#endif

    posix_spawnattr_setflags(&attr, flags);

    FLog(@"[SPAWN] flags=0x%x, ignoreSignals 由子进程自身处理", flags);

    if (asRootPersona && posix_spawnattr_set_persona_np &&
        posix_spawnattr_set_persona_uid_np && posix_spawnattr_set_persona_gid_np) {
        posix_spawnattr_set_persona_np(&attr, 99, 1);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);
    }

    // 子进程输出重定向到注入日志：父进程不读管道，若子进程继续写 stdout
    // 会收到 SIGPIPE / SIGHUP。直接落到文件最稳。
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    int outPipe[2] = {-1, -1};
    BOOL usePipe = (outLog != NULL);
    if (usePipe) {
        if (pipe(outPipe) == 0) {
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDERR_FILENO);
            posix_spawn_file_actions_addclose(&actions, outPipe[0]);
        } else {
            usePipe = NO;
        }
    }

    int logFD = -1;
    if (!usePipe) {
        const char *envPath = getenv("FUCK_INJECT_LOG_PATH");
        NSString *logPath = envPath && envPath[0]
            ? [NSString stringWithUTF8String:envPath]
            : [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
               stringByAppendingPathComponent:@"inject_debug.log"];
        if (logPath.length) {
            logFD = open(logPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
            if (logFD >= 0) {
                posix_spawn_file_actions_adddup2(&actions, logFD, STDOUT_FILENO);
                posix_spawn_file_actions_adddup2(&actions, logFD, STDERR_FILENO);
                posix_spawn_file_actions_addclose(&actions, logFD);
            }
        }
    }
    int devNull = open("/dev/null", O_RDONLY);
    if (devNull >= 0) {
        posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO);
        posix_spawn_file_actions_addclose(&actions, devNull);
    }

    char **argv = calloc(arguments.count + 1, sizeof(char *));
    if (!argv) {
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attr);
        return ENOMEM;
    }

    for (NSUInteger i = 0; i < arguments.count; i++) {
        argv[i] = (char *)arguments[i].UTF8String;
    }
    argv[arguments.count] = NULL;

    pid_t pid = 0;
    int ret = posix_spawn(&pid, argv[0], &actions, &attr, argv, environ);
    free(argv);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    if (ret != 0) return ret;

    return FuckWaitForPid(pid);
}

static int FuckSpawnArguments(NSArray<NSString *> *arguments, BOOL asRootPersona) {
    return FuckSpawnArgumentsWithOutput(arguments, asRootPersona, NULL);
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

// LSApplicationProxy 查询必须在主线程做。
//
// 实测：从后台队列调用 applicationProxyForIdentifier: 会**静默返回 nil**
// —— 它内部的 XPC/服务连接依赖主线程 runloop。返回 nil 的直接后果是
// 「无法获取 xxx 的可执行文件路径」，注入在查 PID 这一步就断了。
//
// 但整个注入流程又不能放回主线程（那会冻住 UI，之前修过一次）。
// 所以这里单独把这一次查询 sync 回主线程，其余流程仍在后台。
static NSString *FuckCanonicalExecutablePath(NSString *bundleID) {
    __block NSString *result = nil;

    void (^work)(void) = ^{
        id proxy = FuckProxyForBundleID(bundleID);
        if (!proxy) return;

        NSString *execPath = FuckProxyString(proxy, @"canonicalExecutablePath");
        if (execPath.length) { result = execPath; return; }

        NSString *bundlePath = FuckProxyPathFromURL(proxy, @"bundleURL");
        NSString *exeName = FuckProxyString(proxy, @"bundleExecutable");
        if (bundlePath.length && exeName.length) {
            result = [bundlePath stringByAppendingPathComponent:exeName];
        }
    };

    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }

    if (!result.length) {
        FLogError(@"[Path] 主线程查询也拿不到 %@ 的路径（LSApplicationProxy 返回 nil）", bundleID);
    }
    return result;
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
// ── 注入通道（rawValue 与 Swift 侧 DynamicInjectChannel 一一对应）──
typedef NS_ENUM(int, FuckInjectChannel) {
    FuckInjectChannelAuto       = 0,
    FuckInjectChannelElevate    = 1,
    FuckInjectChannelRoothide   = 2,
    FuckInjectChannelJailbreakd = 3,
    FuckInjectChannelKfd        = 4,
};

static FuckInjectChannel FuckSelectedChannel(void) {
    const char *env = getenv("FUCK_INJECT_CHANNEL");
    if (!env || !env[0]) return FuckInjectChannelAuto;
    int v = atoi(env);
    if (v < 0 || v > 4) return FuckInjectChannelAuto;
    return (FuckInjectChannel)v;
}

static const char *FuckChannelName(FuckInjectChannel c) {
    switch (c) {
        case FuckInjectChannelAuto:       return "自动";
        case FuckInjectChannelElevate:    return "提权到 root";
        case FuckInjectChannelRoothide:   return "roothide jbserver";
        case FuckInjectChannelJailbreakd: return "jailbreakd XPC";
        case FuckInjectChannelKfd:        return "kfd";
    }
    return "?";
}

static BOOL FuckInjectTrustCache(NSString *filePath) {
    FLog(@"[TrustCache] 开始 Trust Cache 注入: %@", filePath);

    FuckInjectChannel ch = FuckSelectedChannel();
    FLog(@"[TrustCache] 用户选择的通道: %s", FuckChannelName(ch));

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

    // 各通道封装成块，便于「指定单个」与「自动依次尝试」共用同一份实现。
    BOOL (^runElevate)(void) = ^BOOL{
        int er = FuckTryElevateToRoot();
        return er == 0;
    };
    BOOL (^runRoothide)(void) = ^BOOL{
        return FuckRoothideTrustDylib(filePath);
    };
    BOOL (^runJailbreakd)(void) = ^BOOL{
        return FuckJailbreakdTrustCacheAdd(cdhash) == 0;
    };
    BOOL (^runKfd)(void) = ^BOOL{
        return FuckKfdTrustCacheInject(cdhash);
    };

    if (ch == FuckInjectChannelAuto) {
        // 自动：按强弱顺序依次尝试，任一成功即停止。
        // 提权放第一——成功则后续全部畅通，是最省事的一条。
        struct { const char *name; BOOL (^fn)(void); } steps[] = {
            { "提权到 root",        runElevate },
            { "roothide jbserver", runRoothide },
            { "jailbreakd XPC",    runJailbreakd },
            { "kfd",               runKfd },
        };
        int n = (int)(sizeof(steps) / sizeof(steps[0]));
        for (int i = 0; i < n; i++) {
            FLog(@"[TrustCache] 自动模式 %d/%d：尝试 %s", i + 1, n, steps[i].name);
            BOOL ok = steps[i].fn();
            if (ok) {
                FLogSuccess(@"[TrustCache] 通道「%s」成功", steps[i].name);
                return YES;
            }
            FLog(@"[TrustCache] 通道「%s」未成功，继续下一个", steps[i].name);
        }
        FLogError(@"[TrustCache] 所有通道均失败");
        return NO;
    }

    // 指定单个通道：只跑它，失败也不自动切换，方便逐个排查。
    // （提权成功后仍继续跑 roothide：提权解决的是权限，trust cache 仍要写。）
    switch (ch) {
        case FuckInjectChannelElevate: {
            BOOL ok = runElevate();
            if (!ok) {
                FLogError(@"[TrustCache] 指定的「提权到 root」通道失败");
                return NO;
            }
            FLog(@"[TrustCache] 已提权，继续写 trust cache（走 roothide）");
            BOOL tr = runRoothide() || runJailbreakd();
            if (!tr) FLogError(@"[TrustCache] 提权成功但 trust cache 仍未写入");
            return tr;
        }
        case FuckInjectChannelRoothide:
            if (runRoothide()) { FLogSuccess(@"[TrustCache] roothide 成功"); return YES; }
            FLogError(@"[TrustCache] 指定的「roothide jbserver」通道失败");
            return NO;
        case FuckInjectChannelJailbreakd:
            if (runJailbreakd()) { FLogSuccess(@"[TrustCache] jailbreakd 成功"); return YES; }
            FLogError(@"[TrustCache] 指定的「jailbreakd XPC」通道失败");
            return NO;
        case FuckInjectChannelKfd:
            if (runKfd()) { FLogSuccess(@"[TrustCache] kfd 成功"); return YES; }
            FLogError(@"[TrustCache] 指定的「kfd」通道失败（iOS 17 上该通道已被修补，属正常）");
            return NO;
        case FuckInjectChannelAuto:
            break;
    }
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
// 在指定映像的 __text 里找 ret 序列。
// want == 2 找 ret;ret，want == 1 找单个 ret。
static uint64_t FuckScanRetSequence(const char *imageName, uint32_t want) {
    const uint32_t RET_INSN = 0xD65F03C0;
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

        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, "__TEXT") == 0) {
                    const struct section_64 *sec =
                        (const struct section_64 *)((uint8_t *)seg + sizeof(*seg));
                    for (uint32_t k = 0; k < seg->nsects; k++) {
                        if (strcmp(sec[k].sectname, "__text") != 0) continue;
                        uint32_t *code = (uint32_t *)(sec[k].addr + slide);
                        size_t count = sec[k].size / sizeof(uint32_t);
                        for (size_t n = 0; n + 1 < count; n++) {
                            if (want == 2) {
                                if (code[n] == RET_INSN && code[n + 1] == RET_INSN)
                                    return (uint64_t)&code[n];
                            } else if (code[n] == RET_INSN) {
                                return (uint64_t)&code[n];
                            }
                        }
                    }
                }
            }
            cmd = (const struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
        }
    }
    return 0;
}

// 找一个「目标进程里也一定存在」的落地地址。
//
// 这个地址会被写进【目标进程】线程的 PC / LR，所以它必须落在目标进程也有映射的
// 区域里，绝不能是本进程（Minis）映像中的地址。
//
// 实测崩溃正是这个原因：旧实现用 _dyld_get_image_header 扫遍本进程所有映像，
// 命中的第一个 ret;ret 落在 Minis.app/Minis 里，把它交给目标 App 的线程后
// 线程立即 EXC_BAD_ACCESS（KERN_INVALID_ADDRESS），目标进程被 SIGSEGV 杀死，
// 外部表现为「注入失败 -9 / 未找到新 pthread 线程」。
//
// libsystem 系列在每个进程里都会加载，且系统库来自 dyld 共享缓存，同一台设备
// 上地址一致 —— 是本进程与目标进程之间的安全交集，因此优先只在这些映像里找。
static uint64_t FuckFindRopLoop(void) {
    static const char *kSharedImages[] = {
        "libsystem_pthread",
        "libsystem_platform",
        "libsystem_malloc",
        "libsystem_c",
        "libsystem_kernel",
    };
    const size_t kCount = sizeof(kSharedImages) / sizeof(kSharedImages[0]);

    for (size_t i = 0; i < kCount; i++) {
        for (uint32_t want = 2; want >= 1; want--) {
            uint64_t addr = FuckScanRetSequence(kSharedImages[i], want);
            if (addr) {
                FLog(@"找到 ropLoop(%s): 0x%llx (image: %s)",
                     want == 2 ? "ret;ret" : "ret", addr, kSharedImages[i]);
                return addr;
            }
        }
    }

    // 兜底：仍然只在系统库范围内找，绝不回退到本进程自己的映像。
    // 找不到就是找不到 —— 用错地址会让目标进程崩溃，比注入失败更糟。
    FLogError(@"未在系统库中找到 ropLoop gadget");
    return 0;
}

// 校验 gadget 是否落在本进程某个系统库映射内，且距离该映射起点足够近。
// 系统库由 dyld 共享缓存提供，同设备地址一致，因此「本进程命中 + 靠近库起点」
// 可以当作「目标进程同样可用」的保守判据。
static BOOL FuckIsSharedLibraryAddress(uint64_t addr, uint64_t *outOffset) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (!strstr(name, "/usr/lib/") && !strstr(name, "libsystem")) continue;
        if (!strstr(name, "system") && !strstr(name, "libsystem")) continue;

        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;

        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct load_command *cmd =
            (const struct load_command *)((uint8_t *)header + sizeof(struct mach_header_64));

        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (cmd->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)cmd;
                uint64_t segStart = seg->vmaddr + slide;
                uint64_t segEnd = segStart + seg->vmsize;
                if (addr >= segStart && addr < segEnd) {
                    if (outOffset) *outOffset = addr - segStart;
                    return YES;
                }
            }
            cmd = (const struct load_command *)((uint8_t *)cmd + cmd->cmdsize);
        }
    }
    return NO;
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

// 归一化用于比较：iOS 上 /var 是 /private/var 的符号链接，
// 同一文件两种写法。realpath 在沙盒内可能失败，一旦失败就退回原始字符串，
// 而 proc_pidpath 给的是 /private/var 版本 —— strcmp 永远不相等。
// 实测症状就是「[Path] 扫描定位到 ... ✅」紧接着
//「❌ 未找到运行进程（可执行路径已解析: ...）」，路径明明是对的。
static void FuckNormalizeExecPath(const char *in, char *out, size_t outLen) {
    if (!in || !out || outLen == 0) return;
    const char *p = in;
    if (strncmp(p, "/private/", 9) == 0) p += 8;
    strlcpy(out, p, outLen);
}

// 最后一道保险：比较 "Xxx.app/Xxx" 这一段。
// 容器 UUID 或路径前缀有差异时，这一段的写法是一致的。
static BOOL FuckSameAppExeSuffix(const char *a, const char *b) {
    const char *sa = strstr(a, ".app/");
    const char *sb = strstr(b, ".app/");
    if (!sa || !sb) return NO;
    return strcmp(sa, sb) == 0;
}

static pid_t FuckFindPIDByExecPath(const char *targetPath) {
    if (!targetPath || targetPath[0] == '\0') return -1;

    // 目标路径先归一化（不依赖 realpath 是否可用）
    char resolvedTarget[PROC_PIDPATHINFO_MAXSIZE];
    if (realpath(targetPath, resolvedTarget) == NULL)
        strlcpy(resolvedTarget, targetPath, sizeof(resolvedTarget));

    char normTarget[PROC_PIDPATHINFO_MAXSIZE];
    FuckNormalizeExecPath(resolvedTarget, normTarget, sizeof(normTarget));

    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return -1;

    pid_t *pids = (pid_t *)calloc(count, sizeof(pid_t));
    if (!pids) return -1;

    int actual = proc_listallpids(pids, count * sizeof(pid_t));
    pid_t found = -1;
    char pathBuf[PROC_PIDPATHINFO_MAXSIZE];
    int scanned = 0;

    // 诊断样本：可执行名相同但完整路径没匹配上的进程
    char sample[PROC_PIDPATHINFO_MAXSIZE];
    sample[0] = '\0';
    const char *wantExe = strrchr(normTarget, '/');

    for (int i = 0; i < actual; i++) {
        if (pids[i] <= 0) continue;
        memset(pathBuf, 0, sizeof(pathBuf));
        if (proc_pidpath(pids[i], pathBuf, sizeof(pathBuf)) <= 0) continue;
        scanned++;

        char normBuf[PROC_PIDPATHINFO_MAXSIZE];
        FuckNormalizeExecPath(pathBuf, normBuf, sizeof(normBuf));

        if (strcmp(normBuf, normTarget) == 0
            || FuckSameAppExeSuffix(normBuf, normTarget)
            || strcmp(pathBuf, targetPath) == 0) {
            found = pids[i];
            break;
        }
        if (wantExe && !sample[0] && strstr(pathBuf, wantExe)) {
            strlcpy(sample, pathBuf, sizeof(sample));
        }
    }
    free(pids);

    if (found < 0) {
        // 把「期望路径」和「实际看到的同名字进程」都打出来，
        // 下次失败时一眼能看出差在哪一段。
        FLogError(@"扫描了 %d 个进程，未匹配。期望: %s%s",
                  scanned, normTarget,
                  sample[0] ? [NSString stringWithFormat:@"，同名进程实际路径: %s", sample].UTF8String : "");
    }
    return found;
}

// 直接从 App 安装目录解析可执行文件路径。
//
// 这是最可靠的一条路，不依赖任何私有 API：
//   扫 /var/containers/Bundle/Application/<UUID>/<Name>.app/
//   读它的 Info.plist 拿 CFBundleIdentifier 与 CFBundleExecutable
//   命中 bundleID 就返回 <app>/<exec>
//
// 为什么需要它：LSApplicationProxy 在后台线程会静默返回 nil（实测），
// 而注入流程必须在后台跑（否则冻 UI）。原先只有 Proxy 一条路，
// Proxy 一失败就报「无法获取可执行文件路径」，注入在查 PID 这一步就断了。
static NSString *FuckExecPathByScanningBundles(NSString *bundleID) {
    if (!bundleID.length) return nil;

    NSArray<NSString *> *roots = @[
        @"/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application",
    ];
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *root in roots) {
        NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:root error:nil];
        if (!uuids) continue;

        for (NSString *uuid in uuids) {
            if ([uuid hasPrefix:@"."]) continue;      // .jbroot-* 之类
            NSString *container = [root stringByAppendingPathComponent:uuid];
            NSArray<NSString *> *apps = [fm contentsOfDirectoryAtPath:container error:nil];
            if (!apps) continue;

            for (NSString *appName in apps) {
                if (![appName hasSuffix:@".app"]) continue;
                NSString *appPath = [container stringByAppendingPathComponent:appName];
                NSString *plistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];

                NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                if (!plist) continue;

                NSString *bid = plist[@"CFBundleIdentifier"];
                if (![bid isEqualToString:bundleID]) continue;

                // 优先用 plist 里的可执行名；缺失时退回到去掉 .app 的名字
                NSString *exe = plist[@"CFBundleExecutable"];
                if (!exe.length) exe = [appName stringByDeletingPathExtension];

                NSString *full = [appPath stringByAppendingPathComponent:exe];
                if ([fm fileExistsAtPath:full]) {
                    FLog(@"[Path] 扫描定位到 %@ -> %@", bundleID, full);
                    return full;
                }
            }
        }
    }
    return nil;
}

static pid_t FuckFindPIDForBundleID(NSString *bundleID) {
    // 1) 扫安装目录（最可靠，不依赖私有 API）
    NSString *execPath = FuckExecPathByScanningBundles(bundleID);

    // 2) 退回 LSApplicationProxy（仅当扫描没命中）
    if (!execPath.length) {
        FLog(@"[Path] 扫描未命中，回退 LSApplicationProxy");
        execPath = FuckCanonicalExecutablePath(bundleID);
    }

    // 3) 还是拿不到：按进程名模糊匹配（App 主进程名通常等于可执行名）
    if (!execPath.length) {
        FLogError(@"两条路径都没拿到 %@ 的可执行路径，改用进程名匹配", bundleID);
        NSString *shortName = [bundleID componentsSeparatedByString:@"."].lastObject;
        int count = proc_listallpids(NULL, 0);
        if (count > 0) {
            pid_t *pids = (pid_t *)calloc(count, sizeof(pid_t));
            if (pids) {
                int actual = proc_listallpids(pids, count * sizeof(pid_t));
                char buf[PROC_PIDPATHINFO_MAXSIZE];
                for (int i = 0; i < actual; i++) {
                    if (pids[i] <= 0) continue;
                    memset(buf, 0, sizeof(buf));
                    if (proc_pidpath(pids[i], buf, sizeof(buf)) > 0) {
                        NSString *p = [NSString stringWithUTF8String:buf];
                        if (shortName.length &&
                            [[p lastPathComponent] caseInsensitiveCompare:shortName] == NSOrderedSame) {
                            FLog(@"[Path] 进程名匹配到 %@ -> PID %d", bundleID, pids[i]);
                            free(pids);
                            return pids[i];
                        }
                    }
                }
                free(pids);
            }
        }
        return -1;
    }

    pid_t pid = FuckFindPIDByExecPath(execPath.UTF8String);
    if (pid > 0) FLog(@"找到目标进程 PID: %d", pid);
    else FLogError(@"未找到 %@ 的运行进程（可执行路径已解析: %@）", bundleID, execPath);
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

    // ── 先做权限与状态的完整诊断（失败时才有迹可循）──
    {
        // 自身权限：jbserver 的 platform 域要求调用方带 CS_PLATFORM_BINARY
        uint32_t selfFlags = 0;
        int selfRet = csops(getpid(), FUCK_CS_OPS_STATUS, &selfFlags, sizeof(selfFlags));
        FLog(@"[DIAG] 本进程 cs_flags=0x%x (csops ret=%d)", selfFlags, selfRet);
        FLog(@"[DIAG]   CS_PLATFORM_BINARY=%d  ← jbserver platform 域要求此标志",
             (selfFlags & FUCK_CS_PLATFORM_BINARY) ? 1 : 0);
        FLog(@"[DIAG]   CS_GET_TASK_ALLOW=%d", (selfFlags & FUCK_CS_GET_TASK_ALLOW) ? 1 : 0);
        FLog(@"[DIAG]   CS_DEBUGGED=%d", (selfFlags & FUCK_CS_DEBUGGED) ? 1 : 0);

        // 目标进程权限：决定 task_for_pid 能否成功
        uint32_t targetFlags = 0;
        int tfRet = csops(targetPID, FUCK_CS_OPS_STATUS, &targetFlags, sizeof(targetFlags));
        FLog(@"[DIAG] 目标进程 cs_flags=0x%x (csops ret=%d)", targetFlags, tfRet);
        FLog(@"[DIAG]   CS_PLATFORM=%d CS_GET_TASK_ALLOW=%d CS_DEBUGGED=%d CS_RUNTIME=%d",
             (targetFlags & FUCK_CS_PLATFORM_BINARY) ? 1 : 0,
             (targetFlags & FUCK_CS_GET_TASK_ALLOW) ? 1 : 0,
             (targetFlags & FUCK_CS_DEBUGGED) ? 1 : 0,
             (targetFlags & 0x10000) ? 1 : 0);
        if ((targetFlags & FUCK_CS_GET_TASK_ALLOW) == 0) {
            FLog(@"[DIAG] ⚠️ 目标进程未带 CS_GET_TASK_ALLOW —— task_for_pid 很可能被软拒绝（返回死端口）");
            FLog(@"[DIAG]    这正是「kr=0 但 port=-1」的原因，必须靠 roothide 打 debugged 标记绕过");
        }
    }

    // ── 获取 task port ──
    //
    // iOS 17 上 task_for_pid 可能返回 KERN_SUCCESS 但给到 MACH_PORT_DEAD
    // 之类的无效值（实测 targetTask == -1）。根因是目标进程未被内核标记为
    // 「可调试」—— 即使调用方持有 task_for_pid-allow 权限，AMFI 也会拦。
    //
    // roothide 提供 jbserver 接口可以给指定 pid 打上 debugged 标记，
    // 这正是越狱环境下 Dopamine/Relaxin 自己调试 App 的方式。
    mach_port_t targetTask = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), targetPID, &targetTask);

    if (kr != KERN_SUCCESS || targetTask == MACH_PORT_NULL || targetTask == MACH_PORT_DEAD) {
        FLog(@"[TP] 首次 task_for_pid 未拿到有效 port (kr=%d, port=%d)，尝试经 roothide 标记后重试",
             kr, targetTask);

        // 经 jbserver 把目标进程标记为 fully-debugged
        BOOL marked = FuckRoothideSetProcessDebugged((uint64_t)targetPID, YES);
        FLog(@"[TP] roothide set_process_debugged => %@", marked ? @"成功" : @"失败（多为调用方缺 CS_PLATFORM_BINARY 或 jbserver 未响应）");

        // 再尝试一次（有些实现需要目标进程重新校验签名才生效）
        if (marked) {
            FuckRoothideCSRevalidate();
            usleep(120000);
        }

        targetTask = MACH_PORT_NULL;
        kr = task_for_pid(mach_task_self(), targetPID, &targetTask);
        FLog(@"[TP] 重试 task_for_pid: kr=%d, port=%d", kr, targetTask);
    }

    if (kr != KERN_SUCCESS) {
        FLogError(@"task_for_pid 失败: %d (%s)", kr, mach_error_string(kr));
        return -1;
    }
    if (targetTask == MACH_PORT_NULL || targetTask == MACH_PORT_DEAD) {
        FLogError(@"获取的 task port 无效: %d（目标进程可能拒绝被调试，或需要该 App 处于前台）",
                  targetTask);
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
    // 落地前自检：必须是系统库映射内的地址。
    // 一旦落在本进程自己的映像里，目标进程会直接 SIGSEGV —— 宁可中止注入，
    // 也不要让目标 App 崩溃。
    {
        uint64_t off = 0;
        if (!FuckIsSharedLibraryAddress(ropLoop, &off)) {
            FLogError(@"拒绝使用非系统库地址作为 ropLoop: 0x%llx（目标进程会崩溃）", ropLoop);
            mach_port_deallocate(mach_task_self(), targetTask);
            return -3;
        }
        FLog(@"[校验] ropLoop 位于系统库映射内，偏移 0x%llx", off);
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
    // 无痕模式下 dylib 留在本 App 容器内，目标进程默认**读不到**它，
    // 完全依赖下面这两个 sandbox extension 才能打开。
    // 一旦两个都发放失败，后面的 dlopen 必然返回 NULL —— 与其让调用方
    // 看到一个含义模糊的 dlopen 失败，不如在这里就把原因说清楚。
    BOOL injectModeB = (mode == FuckInjectModeB);
    int dylibReadableWarned = 0;
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

        // Phase 3 前置检查：无痕模式下若两个 token 都没拿到，
    // 目标进程读不到 dylib，dlopen 一定失败。提前给出结论性日志。
    if (injectModeB && !hasSbxRead && !hasSbxExec) {
        FLogError(@"[Sandbox] 无痕模式下两个 extension 均未发放 —— "
                  @"目标进程读不到 %@，dlopen 必然失败。"
                  @"请确认 App 具备 com.apple.private.security.no-sandbox", dylibPath);
        dylibReadableWarned = 1;
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

    // 先尝试提权：即便用户选了别的通道，拿到 root 也会让后续每一步更顺。
    // 失败不阻断——原有逐项修补的路径依然保留。
    {
        int er = FuckTryElevateToRoot();
        FLog(@"[Elevate] 预提权结果: %d (EUID=%d)", er, geteuid());
    }
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
            // 目标 App 的 bundle 同级目录由 container-manager 管控，
            // 普通 App 进程即使有 no-sandbox 也可能被拒（实测报
            //「没有访问该容器的许可」）。此时自动降级为无痕模式：
            // dylib 留在原处，靠 sandbox extension 让目标进程能读。
            FLogError(@"[CLI] copy failed: %@", copyErr.localizedDescription);
            FLog(@"[CLI] ⤵️ 自动降级为无痕模式：dylib 保持原路径，改用 sandbox extension 授权");
            mode = FuckInjectModeB;
            injectedDylibPath = dylibPath;
        }
    } else if (mode == FuckInjectModeA) {
        FLogError(@"[CLI] cannot get target bundle path");
    } else {
        // 模式 B：dylib 留在原处（主进程已放在我方 tmp），不往目标 App 目录写任何文件
        FLog(@"[CLI] 无痕模式：沿用原始路径 %@", injectedDylibPath);
        // 目标 App 以 mobile(501) 运行，需要「其他用户可读」才能打开这个文件。
        // 我方容器默认 0600，不改权限即使有 sandbox token 也可能被拒。
        chmod(injectedDylibPath.UTF8String, 0644);
        {
            struct stat st;
            if (stat(injectedDylibPath.UTF8String, &st) == 0) {
                if ((st.st_mode & 0004) == 0) {
                    // 仍不可读：容器目录本身也需要 o+x，否则路径无法穿过
                    NSString *dir = [injectedDylibPath stringByDeletingLastPathComponent];
                    chmod(dir.UTF8String, 0755);
                    FLog(@"[CLI] dylib 权限补正：file=0644 dir=0755（原目录无 o+x）");
                }
            }
        }
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
            // 注意：进程内注入时，spawn bundle 内的可执行文件会与注入子进程
            // 遇到同一个问题（被信号 1 掐掉）。这里把签名视为「尽力而为」，
            // 失败不影响后续信任链 —— roothide jbserver 走的是 launchd，
            // 不依赖本地签名结果。
            int lr = FuckSpawnArguments(@[ldidPathOnly, @"-S", injectedDylibPath], YES);
            FLog(@"[CLI] (模式B) ldid -S => ret=%d（失败不影响 roothide 信任链）", lr);
        } else {
            FLog(@"[CLI] (模式B) ldid 不在 bundle 内，跳过 ad-hoc 签名");
        }
    }

    // 签名步骤依赖 spawn 本 bundle 内的 ldid / ct_bypass，而 spawn 在本环境
    // 不可用（实测 ret=1 且文件大小无变化，说明工具根本没有执行）。
    // roothide 信任链由 jbserver 完成，不依赖本地签名结果，因此直接跳过。
    BOOL needLocalSign = NO;
    if (needLocalSign && targetTeamID.length > 0) {
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
            FLog(@"[CLI] ldid -S => ret=%d（失败不影响 roothide 信任链）", ldidRet);

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
        FLog(@"[CLI] 已跳过本地签名（roothide 信任链不依赖）");
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

    void (^finish)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
        if (completion) {
            completion(success, message);
        }
    };
    void (^reportProgress)(NSString *) = ^(NSString *step) {
        if (progress) {
            progress(step);
        }
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        FLog(@"========== Relaxin 官方唯一通道注入开始 ==========");
        FLog(@"输入路径: %@", dylibPath);
        FLog(@"目标 App: %@", bundleID);

        if (!dylibPath.length || !bundleID.length) {
            finish(NO, @"参数无效：dylib 路径或 BundleID 为空");
            return;
        }

        // 1. 定位 Relaxin 越狱根与官方 opainject 二进制
        NSString *jbroot = FuckRoothideJbroot();
        if (!jbroot.length) {
            finish(NO, @"未检测到 Relaxin 越狱根环境（.jbroot）");
            return;
        }

        NSString *officialOpainject = [jbroot stringByAppendingPathComponent:@"basebin/opainject"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:officialOpainject]) {
            officialOpainject = [jbroot stringByAppendingPathComponent:@"usr/bin/opainject"];
        }
        if (![[NSFileManager defaultManager] fileExistsAtPath:officialOpainject]) {
            finish(NO, [NSString stringWithFormat:@"未在越狱根找到官方 opainject: %@", officialOpainject]);
            return;
        }
        FLogSuccess(@"[Relaxin] 官方 opainject 就绪: %@", officialOpainject);

        // 2. 查找目标进程 PID（如果没运行则启动它）
        reportProgress(@"正在查找目标进程…");
        pid_t targetPid = FuckFindPIDForBundleID(bundleID);
        if (targetPid <= 0) {
            reportProgress(@"目标未启动，正在调起…");
            FLog(@"[SPAWN] 正在拉起目标 App: %@", bundleID);
            FuckOpenApp(bundleID);
            // 给目标 App 充分的启动时间，特别是 Unity / 大型游戏，不要暴力拉回自己导致 watchdog 强杀
            for (int i = 0; i < 20; i++) {
                usleep(500000);
                targetPid = FuckFindPIDForBundleID(bundleID);
                if (targetPid > 0) {
                    FLog(@"[SPAWN] 目标 App 已启动，PID = %d，稍作等待使其主窗口就绪…", targetPid);
                    usleep(1000000);
                    break;
                }
            }
        }

        if (targetPid <= 0) {
            finish(NO, [NSString stringWithFormat:@"无法获取目标 %@ 的运行 PID，请先在桌面打开它", bundleID]);
            return;
        }
        FLogSuccess(@"[Relaxin] 目标 PID: %d", targetPid);

        // 3. 准备可被目标进程与 opainject 共同访问的有效 dylib
        reportProgress(@"准备插件文件与越狱信任…");
        NSString *finalDylibPath = dylibPath;

        // 如果用户传入的是 .deb，由 Swift 层已自动提取，这里做兜底检查
        if ([dylibPath hasSuffix:@".deb"]) {
            finish(NO, @"请选择解包后的 .dylib 动态库，不要直接选择 .deb 压缩包");
            return;
        }

        // 核心突破：解决严格沙盒 App（如 App Store 游戏、王牌战争）报 file system sandbox blocked mmap()
        // 苹果沙盒机制：目标 App 唯一天然具有执行权限（mmap RX）的路径是它自己的容器目录（Data Container tmp 或 Bundle 目录）。
        // 尝试定位目标 App 的 Data Container 路径
        NSString *targetContainerTmp = nil;
        id targetProxy = FuckProxyForBundleID(bundleID);
        NSString *targetDataURL = FuckProxyPathFromURL(targetProxy, @"dataContainerURL");
        if (targetDataURL.length) {
            targetContainerTmp = [targetDataURL stringByAppendingPathComponent:@"tmp"];
        }

        NSString *destDir = nil;
        if (targetContainerTmp.length && [[NSFileManager defaultManager] fileExistsAtPath:targetContainerTmp]) {
            destDir = targetContainerTmp;
            FLogSuccess(@"[SandboxBypass] 成功定位目标 App 自身数据容器 tmp: %@", destDir);
        } else {
            // 回退到越狱公共 tmp 目录
            destDir = [jbroot stringByAppendingPathComponent:@"tmp/minis_stage"];
            [[NSFileManager defaultManager] createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
        }
        chmod(destDir.UTF8String, 0777);

        NSString *stagedDylib = [destDir stringByAppendingPathComponent:[dylibPath lastPathComponent]];
        [[NSFileManager defaultManager] removeItemAtPath:stagedDylib error:nil];
        NSError *cpErr = nil;
        if ([[NSFileManager defaultManager] copyItemAtPath:dylibPath toPath:stagedDylib error:&cpErr]) {
            chmod(stagedDylib.UTF8String, 0755);
            finalDylibPath = stagedDylib;
            FLogSuccess(@"[Relaxin] 已将 dylib 投递到目标进程合法可读写区: %@", finalDylibPath);
        } else {
            FLogError(@"[Relaxin] 暂存失败: %@, 尝试沿用原路径", cpErr.localizedDescription);
        }

        // 4. 必须先对 dylib 进行 ad-hoc 签名，生成合法的 CodeDirectory 哈希
        // 否则即使提交给 Trust Cache，内核加载器 dyld 校验时也会报 (code signature invalid, errno=1)
        NSString *ldidPath = FuckResourcePath(@"ldid");
        if (!ldidPath.length) {
            ldidPath = [jbroot stringByAppendingPathComponent:@"usr/bin/ldid"];
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
            chmod(ldidPath.UTF8String, 0755);
            FLog(@"[Relaxin] 正在执行 ldid -S 签名: %@", finalDylibPath);
            int lr = FuckSpawnArguments(@[ldidPath, @"-S", finalDylibPath], YES);
            FLog(@"[Relaxin] ldid 签名返回码: %d", lr);
        }

        // 5. 将 dylib 加入系统 Trust Cache（双重保障：jbctl + jbclient 接口）
        NSString *jbctlPath = [jbroot stringByAppendingPathComponent:@"usr/bin/jbctl"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:jbctlPath]) {
            FLog(@"[Relaxin] 调用 jbctl trustcache add: %@", finalDylibPath);
            FuckSpawnArguments(@[jbctlPath, @"trustcache", @"add", finalDylibPath], YES);
        }
        FLog(@"[Relaxin] 调用 jbclient_trust_file_by_path 注入 Trust Cache…");
        FuckRoothideTrustDylib(finalDylibPath);

        // 6. 标记目标进程可调试
        FLog(@"[Relaxin] 标记目标 PID %d 为可调试…", targetPid);
        FuckRoothideSetProcessDebugged(targetPid, YES);

        // 6. 调用官方原生 opainject
        reportProgress(@"正在调用 Relaxin 官方引擎执行注入…");
        FLog(@"[Relaxin] 正在执行: %@ %d %@", officialOpainject, targetPid, finalDylibPath);

        NSArray<NSString *> *args = @[
            officialOpainject,
            [NSString stringWithFormat:@"%d", targetPid],
            finalDylibPath
        ];

        NSString *injectOutput = nil;
        int rc = FuckSpawnArgumentsWithOutput(args, YES, &injectOutput);
        FLog(@"[Relaxin] 官方 opainject 返回码: %d", rc);

        // 注入完成后立即清理暂存的 dylib，保持无痕
        if (finalDylibPath && ![finalDylibPath isEqualToString:dylibPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:finalDylibPath error:nil];
            FLog(@"[Relaxin] 已清除目标容器内的临时 dylib");
        }

        // 深度检查输出：哪怕 opainject 返回 0，只要 dlopen 报错就绝不能报成功！
        BOOL dlopenFailed = NO;
        NSString *failReason = nil;
        if ([injectOutput containsString:@"dlopen failed"]) {
            dlopenFailed = YES;
            if ([injectOutput containsString:@"sandbox blocked mmap"]) {
                failReason = @"沙盒拦截：系统禁止目标 App 映射外部动态库";
            } else if ([injectOutput containsString:@"code signature invalid"]) {
                failReason = @"签名错误：目标 App 内核拒绝未经 PAC 签名的代码";
            } else {
                failReason = @"目标 App dlopen 载入失败，请检查架构与依赖";
            }
        }

        if (rc == 0 && !dlopenFailed) {
            FLogSuccess(@"[Relaxin] ✅ 官方引擎注入成功完成，目标进程已顺利载入动态库！");
            finish(YES, [NSString stringWithFormat:@"注入成功 (PID: %d)", targetPid]);
        } else {
            NSString *err = failReason ? failReason : [NSString stringWithFormat:@"官方 opainject 退出码 %d", rc];
            FLogError(@"[Relaxin] ❌ 注入失败: %@", err);
            finish(NO, err);
        }
    });
}
@end
