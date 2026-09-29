#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 自实现动态注入引擎（基于 mach thread injection + kfd trust cache）
/// 支持越狱环境（jailbreakd IPC）和 TrollStore 环境（kfd exploit）
@interface FuckDynamicInjector : NSObject

/// 动态注入 dylib 到目标进程
/// @param dylibPath 要注入的 dylib 文件路径（任意路径）
/// @param bundleID 目标应用的 bundle ID
/// @param progress 进度回调（主线程）
/// @param completion 完成回调（主线程）：success, message
+ (void)injectDylib:(NSString *)dylibPath
        intoBundleID:(NSString *)bundleID
            progress:(void (^)(NSString *step))progress
          completion:(void (^)(BOOL success, NSString *message))completion;

/// CLI 入口：以 root 子进程身份执行注入（从 main 调用）
/// 参数: -FuckInject <dylibPath> <bundleID>
/// 返回: 0=成功, 非0=失败
+ (int)cliInjectWithDylibPath:(NSString *)dylibPath bundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
