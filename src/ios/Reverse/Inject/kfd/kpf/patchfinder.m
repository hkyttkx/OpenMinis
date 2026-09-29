//
//  patchfinder.m
//  kfd
//
//  Created by Seo Hyun-gyu on 1/8/24.
//

#import <Foundation/Foundation.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <os/log.h>
#import "patchfinder.h"
#import "libdimentio.h"
#import "../libkfd.h"

bool did_patchfinder = false;
uint64_t kaddr_pmap_image4_trust_caches = 0;

// ============================================================
// pmap_image4_trust_caches finder
// Algorithm from KernelPatchfinder.swift:
// 1. Find string "com.apple.private.pmap.load-trust-cache" in kernel __cstring
// 2. Find xref to this string in __TEXT_EXEC
// 3. Walk backwards looking for "movz x9, #0x28" instruction
// 4. Decode ADRP+ADD at (found_pc - 8, found_pc - 4)
// 5. Result - 0x18 = pmap_image4_trust_caches
// ============================================================

#define IS_ADRP_INST(x) (((x) & 0x9F000000U) == 0x90000000U)
#define IS_ADD_X_INST(x) (((x) & 0xFFC00000U) == 0x91000000U)
// Sign-extend 21-bit ADRP immediate (immhi:immlo) to int64_t
#define ADRP_IMM_DECODE(x) (((((int64_t)((x) >> 5) & 0x7FFFF) << 2) | (((x) >> 29) & 0x3)) << 43 >> 43)
#define ADD_X_IMM_DECODE(x) (((x) >> 10) & 0xFFF)

uint64_t find_pmap_image4_trust_caches(pfinder_t pfinder) {
    // Use pfinder's already-loaded in-memory section data.
    // This correctly handles MH_FILESET kernelcache (iOS 15+)
    // and avoids re-reading ~10MB from kernel memory.
    uint64_t text_exec_addr = pfinder.sec_text.s64.addr;
    uint64_t text_exec_size = pfinder.sec_text.s64.size;
    const uint8_t *text_exec_data = (const uint8_t *)pfinder.sec_text.data;

    uint64_t cstring_addr = pfinder.sec_cstring.s64.addr;
    uint64_t cstring_size = pfinder.sec_cstring.s64.size;
    const uint8_t *cstring_data = (const uint8_t *)pfinder.sec_cstring.data;

    os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] text_exec=0x%llx size=0x%llx cstring=0x%llx size=0x%llx",
           text_exec_addr, text_exec_size, cstring_addr, cstring_size);

    if (!text_exec_data || !text_exec_size || !cstring_data || !cstring_size) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] FAIL: missing section data");
        return 0;
    }

    // Step 1: Find "com.apple.private.pmap.load-trust-cache" in __cstring (in-memory)
    const char *target_str = "com.apple.private.pmap.load-trust-cache";
    size_t target_len = strlen(target_str) + 1;
    uint64_t string_addr = 0;

    for (uint64_t j = 0; j + target_len <= cstring_size; j++) {
        if (memcmp(cstring_data + j, target_str, target_len) == 0) {
            string_addr = cstring_addr + j;
            break;
        }
    }

    if (!string_addr) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] FAIL: string not found in __cstring");
        return 0;
    }
    os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] string at 0x%llx", string_addr);

    // Step 2: Find xref to this string in __TEXT_EXEC (ADRP+ADD pattern, in-memory)
    uint64_t xref_addr = 0;
    const uint32_t *instrs = (const uint32_t *)text_exec_data;
    uint64_t num_instrs = text_exec_size / 4;

    for (uint64_t j = 0; j + 1 < num_instrs; j++) {
        uint32_t i0 = instrs[j];
        uint32_t i1 = instrs[j + 1];

        if (IS_ADRP_INST(i0) && IS_ADD_X_INST(i1)) {
            uint64_t pc = text_exec_addr + j * 4;
            int64_t adrp_imm = ADRP_IMM_DECODE(i0);
            uint64_t adrp_result = (pc & ~0xFFFULL) + (adrp_imm << 12);
            uint64_t add_imm = ADD_X_IMM_DECODE(i1);
            uint64_t resolved = adrp_result + add_imm;

            if (resolved == string_addr) {
                xref_addr = pc;
                break;
            }
        }
    }

    if (!xref_addr) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] FAIL: xref not found in __TEXT_EXEC");
        return 0;
    }
    os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] xref at 0x%llx", xref_addr);

    // Step 3: Walk backwards looking for movz xN/wN, #0x28
    // 0xD2800509 = movz x9, #0x28 (original pattern)
    // Also match: movz xN, #0x28 → (instr & 0xFFFFFFE0) == 0xD2800500
    //             movz wN, #0x28 → (instr & 0xFFFFFFE0) == 0x52800500
    uint64_t xref_instr_idx = (xref_addr - text_exec_addr) / 4;
    uint64_t movz_addr = 0;

    // Dump instructions near xref for debugging
    os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] dumping 20 instrs before xref:");
    for (uint64_t k = 0; k < 20 && k <= xref_instr_idx; k++) {
        uint32_t instr = instrs[xref_instr_idx - k];
        os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder]   xref-%llu: 0x%llx = 0x%08x", k*4, xref_addr - k*4, instr);
    }

    for (uint64_t k = 0; k < 0x80 && k <= xref_instr_idx; k++) {
        uint32_t instr = instrs[xref_instr_idx - k];
        // Match movz x/wN, #0x28 (any register)
        if ((instr & 0xFFFFFFE0) == 0xD2800500 ||   // movz xN, #0x28
            (instr & 0xFFFFFFE0) == 0x52800500) {    // movz wN, #0x28
            movz_addr = xref_addr - k * 4;
            os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] matched movz at 0x%llx (instr=0x%08x)", movz_addr, instr);
            break;
        }
    }

    if (!movz_addr) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] FAIL: movz x9, #0x28 not found");
        return 0;
    }
    os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] movz at 0x%llx", movz_addr);

    // Step 4: ADRP+ADD at (movz_addr - 8, movz_addr - 4)
    uint64_t movz_instr_idx = (movz_addr - text_exec_addr) / 4;
    if (movz_instr_idx < 2) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] FAIL: movz too close to start");
        return 0;
    }
    uint32_t adrp_instr = instrs[movz_instr_idx - 2];
    uint32_t add_instr = instrs[movz_instr_idx - 1];

    if (!IS_ADRP_INST(adrp_instr) || !IS_ADD_X_INST(add_instr)) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] FAIL: expected ADRP+ADD before movz, got 0x%x 0x%x", adrp_instr, add_instr);
        return 0;
    }

    uint64_t pc = movz_addr - 8;
    int64_t adrp_imm = ADRP_IMM_DECODE(adrp_instr);
    uint64_t adrp_result = (pc & ~0xFFFULL) + (adrp_imm << 12);
    uint64_t add_imm = ADD_X_IMM_DECODE(add_instr);
    uint64_t emu = adrp_result + add_imm;

    // Step 5: Subtract 0x18 to get pmap_image4_trust_caches
    uint64_t result = emu - 0x18;
    os_log_error(OS_LOG_DEFAULT, "[kfd-tc-finder] pmap_image4_trust_caches = 0x%llx", result);

    return result;
}

int do_dynamic_patchfinder(struct kfd* kfd, uint64_t kbase) {
    // Guard: skip if already run (prevent double execution which doubles crash risk)
    if (did_patchfinder) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] patchfinder already completed, skipping");
        return 0;
    }

    os_log_error(OS_LOG_DEFAULT, "[kfd-pf] do_dynamic_patchfinder: ENTER, kbase=0x%llx", kbase);

    // Try importing cached offsets first (avoids millions of kernel reads)
    if (import_kfd_offsets() == 0) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] imported cached offsets OK, skipping patchfinder");
        did_patchfinder = true;
        return 0;
    }

    uint64_t kslide = kbase - 0xFFFFFFF007004000;
    set_kbase(kbase);
    set_kfd(kfd);
    // CRITICAL: Set global _kfd so kreadbuf_kfd/kwritebuf_kfd work
    // find_pmap_image4_trust_caches uses kreadbuf_kfd which depends on _kfd
    _kfd = (uint64_t)kfd;

    os_log_error(OS_LOG_DEFAULT, "[kfd-pf] pfinder_init starting (reads ~10MB kernel data via sem_open kread)...");
    pfinder_t pfinder;
    if(pfinder_init(&pfinder) == KERN_SUCCESS) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] pfinder_init OK, finding symbols...");
        printf("pfinder_init: success!\n");

        uint64_t cdevsw = pfinder_cdevsw(pfinder);
        if(cdevsw) kaddr_cdevsw = cdevsw - kslide;
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] cdevsw=0x%llx", kaddr_cdevsw);

        uint64_t gPhysBase = pfinder_gPhysBase(pfinder);
        if(gPhysBase) kaddr_gPhysBase = gPhysBase - kslide;
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] gPhysBase=0x%llx", kaddr_gPhysBase);

        uint64_t gPhysSize = pfinder_gPhysSize(pfinder);
        if(gPhysSize) kaddr_gPhysSize = gPhysSize - kslide;
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] gPhysSize=0x%llx", kaddr_gPhysSize);

        uint64_t gVirtBase = pfinder_gVirtBase(pfinder);
        if(gVirtBase) kaddr_gVirtBase = gVirtBase - kslide;
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] gVirtBase=0x%llx", kaddr_gVirtBase);
        
        uint64_t perfmon_dev_open = pfinder_perfmon_dev_open(pfinder);
        if(perfmon_dev_open) kaddr_perfmon_dev_open = perfmon_dev_open - kslide;
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] perfmon_dev_open=0x%llx", kaddr_perfmon_dev_open);

        uint64_t perfmon_devices = pfinder_perfmon_devices(pfinder);
        if(perfmon_devices) kaddr_perfmon_devices = perfmon_devices - kslide;
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] perfmon_devices=0x%llx", kaddr_perfmon_devices);

        uint64_t ptov_table = pfinder_ptov_table(pfinder);
        if(ptov_table) kaddr_ptov_table = ptov_table - kslide;
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] ptov_table=0x%llx", kaddr_ptov_table);

        // Find pmap_image4_trust_caches (for trust cache injection)
        // Uses pfinder's in-memory section data (handles MH_FILESET correctly)
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] finding pmap_image4_trust_caches...");
        uint64_t pmap_tc = find_pmap_image4_trust_caches(pfinder);
        if(pmap_tc) kaddr_pmap_image4_trust_caches = pmap_tc - kslide;
        printf("pmap_image4_trust_caches: 0x%llx\n", kaddr_pmap_image4_trust_caches);
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] pmap_image4_trust_caches=0x%llx", kaddr_pmap_image4_trust_caches);

    } else {
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] pfinder_init FAILED");
        printf("failed to init patchfinder\n");
    }
    save_kfd_offsets();
    pfinder_term(&pfinder);
    did_patchfinder = true;
    os_log_error(OS_LOG_DEFAULT, "[kfd-pf] do_dynamic_patchfinder: DONE");
    return 0;
}

const char* get_kernversion(void) {
    char kern_version[512] = {};
    size_t size = sizeof(kern_version);
    sysctlbyname("kern.version", &kern_version, &size, NULL, 0);
    printf("current kern.version: %s\n", kern_version);

    return strdup(kern_version);;
}

int import_kfd_offsets(void) {
    NSString* save_path = [NSString stringWithFormat:@"%@/Documents/kfund_offsets.plist", NSHomeDirectory()];
    if(access(save_path.UTF8String, F_OK) == -1)
        return -1;

    NSDictionary *offsets = [NSDictionary dictionaryWithContentsOfFile:save_path];
    NSString *saved_kern_version = [offsets objectForKey:@"kern_version"];
    if(strcmp(get_kernversion(), saved_kern_version.UTF8String) != 0)
        return -1;

    kaddr_cdevsw = [offsets[@"off_cdevsw"] unsignedLongLongValue];
    kaddr_gPhysBase = [offsets[@"off_gPhysBase"] unsignedLongLongValue];
    kaddr_gPhysSize = [offsets[@"off_gPhysSize"] unsignedLongLongValue];
    kaddr_gVirtBase = [offsets[@"off_gVirtBase"] unsignedLongLongValue];
    kaddr_perfmon_dev_open = [offsets[@"off_perfmon_dev_open"] unsignedLongLongValue];
    kaddr_perfmon_devices = [offsets[@"off_perfmon_devices"] unsignedLongLongValue];
    kaddr_ptov_table = [offsets[@"off_ptov_table"] unsignedLongLongValue];
    kaddr_pmap_image4_trust_caches = [offsets[@"off_pmap_image4_trust_caches"] unsignedLongLongValue];

    // Reject cache if critical offsets are missing (e.g. pmap_image4_trust_caches
    // was 0 from a previous run with the kslide bug)
    if (!kaddr_pmap_image4_trust_caches || !kaddr_cdevsw) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-pf] cached offsets incomplete (tc=0x%llx cdevsw=0x%llx), re-running patchfinder",
               kaddr_pmap_image4_trust_caches, kaddr_cdevsw);
        return -1;
    }

    return 0;
}

int save_kfd_offsets(void) {
    NSString* save_path = [NSString stringWithFormat:@"%@/Documents/kfund_offsets.plist", NSHomeDirectory()];
    remove(save_path.UTF8String);

    NSDictionary *offsets = @{
        @"kern_version": @(get_kernversion()),
        @"off_cdevsw": @(kaddr_cdevsw),
        @"off_gPhysBase": @(kaddr_gPhysBase),
        @"off_gPhysSize": @(kaddr_gPhysSize),
        @"off_gVirtBase": @(kaddr_gVirtBase),
        @"off_perfmon_dev_open": @(kaddr_perfmon_dev_open),
        @"off_perfmon_devices": @(kaddr_perfmon_devices),
        @"off_ptov_table": @(kaddr_ptov_table),
        @"off_pmap_image4_trust_caches": @(kaddr_pmap_image4_trust_caches),
    };

    BOOL success = [offsets writeToFile:save_path atomically:YES];
    if (!success) {
        printf("failed to saved offsets: %s\n", save_path.UTF8String);
        return -1;
    }
    printf("saved offsets for kfd: %s\n", save_path.UTF8String);

    return 0;
}
