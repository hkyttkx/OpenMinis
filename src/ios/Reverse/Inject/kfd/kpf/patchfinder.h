//
//  patchfinder.h
//  kfd
//
//  Created by Seo Hyun-gyu on 1/8/24.
//

#ifndef patchfinder_h
#define patchfinder_h

#include "../libkfd.h"
#include "../libkfd/perf.h"

int do_dynamic_patchfinder(struct kfd* kfd, uint64_t kbase);

int import_kfd_offsets(void);
int save_kfd_offsets(void);

// pmap_image4_trust_caches finder
extern uint64_t kaddr_pmap_image4_trust_caches;

#endif /* patchfinder_h */
