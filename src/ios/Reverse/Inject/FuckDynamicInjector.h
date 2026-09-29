#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 注入模式
///   0 = 严格复刻原实现：dylib 先拷入目标 App 的 bundle 同级目录，
///       按原流程申请 sandbox extension 后再注入；注入完成后清理该临时文件。
///   1 = 无痕模式：dylib 仅留在调用方 tmp 目录，直接以绝对路径注入目标进程；
///       不向目标 App 目录写入任何文件，注入后立即清除临时 dylib。
typedef NS_ENUM(int, FuckInjectMode) {
    FuckInjectModeStrict = 0,
    FuckInjectModeClean  = 1,
};

/// 自实现动态注入引擎
///
/// 注入链路（与原实现保持一致）：
///   root 子进程 → 拷贝/准备 dylib → 签名 → 写入 trust cache →
///   task_for_pid → mach_vm_allocate 写路径 → thread_create_running →
///   远程 dlopen → 清理临时文件
///
/// trust cache 写入按可用性依次尝试三条通道：
///   1. Relaxin / roothide jbserver（jbclient_trust_library_recurse）—— iOS 17.x 首选
///   2. Dopamine jailbreakd IPC（多端口名候选）
///   3. kfd exploit（仅在 iOS 16.x 及以下有效，作为兜底）
@interface FuckDynamicInjector : NSObject

/// 动态注入 dylib 到目标进程（启动 root 子进程执行，不阻塞调用线程）
/// @param dylibPath 要注入的 dylib 文件路径
/// @param bundleID 目标应用的 bundle ID
/// @param mode 注入模式（FuckInjectMode）
/// @param progress 进度回调（主线程）
/// @param completion 完成回调（主线程）：success, message
+ (void)injectDylib:(NSString *)dylibPath
        intoBundleID:(NSString *)bundleID
                mode:(int)mode
            progress:(void (^)(NSString *step))progress
          completion:(void (^)(BOOL success, NSString *message))completion;

/// CLI 入口：以 root 子进程身份执行注入（由 main 在 argv[1] == "-FuckInject" 时调用）
/// 参数: -FuckInject <dylibPath> <bundleID> [mode]
/// 返回: 0=成功, 非0=失败
+ (int)cliInjectWithDylibPath:(NSString *)dylibPath
                     bundleID:(NSString *)bundleID
                         mode:(int)mode;

@end

NS_ASSUME_NONNULL_END
