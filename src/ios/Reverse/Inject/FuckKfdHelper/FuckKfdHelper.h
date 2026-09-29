#ifndef FuckKfdHelper_h
#define FuckKfdHelper_h

// FuckKfdHelper 是一个独立的命令行可执行文件
// 用于在子进程中执行 kfd exploit trust cache 注入
// 避免 exploit 崩溃导致主 App 进程 kernel panic
//
// 用法: FuckKfdHelper <cdhash_hex_40chars>
// 返回: 0=成功, 1=失败, 128+sig=被信号杀死

#endif
