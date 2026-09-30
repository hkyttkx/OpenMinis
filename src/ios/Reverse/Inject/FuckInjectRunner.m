//
// FuckInjectRunner.m
//
// 独立动态注入子进程入口。
// 不启动 SwiftUI / UIKit App 生命周期，避免主 App 自身作为 root 子进程时
// 在 init 之前收到 SIGHUP。由 FuckDynamicInjector.injectDylib 直接 spawn。
//
// 用法：FuckInjectRunner <dylibPath> <bundleID> [mode]
//

#import <Foundation/Foundation.h>
#import <signal.h>
#import <stdlib.h>
#import "FuckDynamicInjector.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        // 独立入口的第一条有效操作：忽略会话挂断及管道信号。
        signal(SIGHUP, SIG_IGN);
        signal(SIGINT, SIG_IGN);
        signal(SIGQUIT, SIG_IGN);
        signal(SIGPIPE, SIG_IGN);
        signal(SIGTERM, SIG_IGN);

        if (argc < 3) {
            fprintf(stderr, "usage: FuckInjectRunner <dylibPath> <bundleID> [mode]\\n");
            return 64;
        }

        NSString *dylibPath = [NSString stringWithUTF8String:argv[1]];
        NSString *bundleID = [NSString stringWithUTF8String:argv[2]];
        int mode = argc >= 4 ? atoi(argv[3]) : 0;

        int ret = [FuckDynamicInjector cliInjectWithDylibPath:dylibPath
                                                     bundleID:bundleID
                                                         mode:mode];
        return ret;
    }
}
