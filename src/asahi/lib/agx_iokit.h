
/*
 * Copyright 2021 Alyssa Rosenzweig
 * Copyright 2026 Andres Riofrio
 * SPDX-License-Identifier: MIT
 */

#pragma once

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>

#if __APPLE__
#include <IOKit/IODataQueueClient.h>
#include <mach/mach.h>
#endif

#include "util/macros.h"

/*
 * This section contains the minimal set of definitions to trace the macOS
 * (IOKit) interface to the AGX accelerator.
 * They are not used under Linux.
 *
 * Information is this file was originally determined independently. More
 * recently, names have been augmented via the oob_timestamp code sample from
 * Project Zero [1]
 *
 * [1] https://bugs.chromium.org/p/project-zero/issues/detail?id=1986
 */

#define AGX_SERVICE_TYPE 0x100005

enum agx_selector_label {
   AGX_SELECTOR_LABEL_GET_GLOBAL_IDS,
   AGX_SELECTOR_LABEL_SET_API,
   AGX_SELECTOR_LABEL_CREATE_COMMAND_QUEUE,
   AGX_SELECTOR_LABEL_FREE_COMMAND_QUEUE,
   AGX_SELECTOR_LABEL_ALLOCATE_MEM,
   AGX_SELECTOR_LABEL_FREE_MEM,
   AGX_SELECTOR_LABEL_CREATE_SHMEM,
   AGX_SELECTOR_LABEL_FREE_SHMEM,
   AGX_SELECTOR_LABEL_CREATE_NOTIFICATION_QUEUE,
   AGX_SELECTOR_LABEL_FREE_NOTIFICATION_QUEUE,
   AGX_SELECTOR_LABEL_SUBMIT_COMMAND_BUFFERS,
   AGX_SELECTOR_LABEL_GET_VERSION,
   AGX_SELECTOR_LABEL_INVALID,
};

#define AGX_SELECTOR_INVALID UINT32_MAX

// Used on macOS 13 (verified), macOS 14 (unverified) and macOS 15 (only
// SET_API, CREATE_COMMAND_QUEUE, ALLOCATE_MEM, and CREATE_NOTIFICATION_QUEUE
// verified).
#define _AGX_V13_SELECTORS(X)                                                  \
   X(AGX_SELECTOR_LABEL_GET_GLOBAL_IDS, 0x6)                                   \
   X(AGX_SELECTOR_LABEL_SET_API, 0x7)                                          \
   X(AGX_SELECTOR_LABEL_CREATE_COMMAND_QUEUE, 0x8)                             \
   X(AGX_SELECTOR_LABEL_FREE_COMMAND_QUEUE, 0x9)                               \
   X(AGX_SELECTOR_LABEL_ALLOCATE_MEM, 0xA)                                     \
   X(AGX_SELECTOR_LABEL_FREE_MEM, 0xB)                                         \
   X(AGX_SELECTOR_LABEL_CREATE_SHMEM, 0xF)                                     \
   X(AGX_SELECTOR_LABEL_FREE_SHMEM, 0x10)                                      \
   X(AGX_SELECTOR_LABEL_CREATE_NOTIFICATION_QUEUE, 0x11)                       \
   X(AGX_SELECTOR_LABEL_FREE_NOTIFICATION_QUEUE, 0x12)                         \
   X(AGX_SELECTOR_LABEL_SUBMIT_COMMAND_BUFFERS, 0x1E)                          \
   X(AGX_SELECTOR_LABEL_GET_VERSION, 0x2A)

/** Used on macOS 26. */
#define _AGX_V26_SELECTORS(X)                                                  \
   X(AGX_SELECTOR_LABEL_GET_GLOBAL_IDS, AGX_SELECTOR_INVALID) /* Unknown */    \
   X(AGX_SELECTOR_LABEL_SET_API, AGX_SELECTOR_INVALID)        /* Removed */    \
   X(AGX_SELECTOR_LABEL_CREATE_COMMAND_QUEUE, 0x7)            /**/             \
   X(AGX_SELECTOR_LABEL_FREE_COMMAND_QUEUE, 0x8)              /* Unverified */ \
   X(AGX_SELECTOR_LABEL_ALLOCATE_MEM, 0x9)                    /**/             \
   X(AGX_SELECTOR_LABEL_FREE_MEM, 0xA)                        /* Unverified */ \
   X(AGX_SELECTOR_LABEL_CREATE_SHMEM, 0xE)                    /**/             \
   X(AGX_SELECTOR_LABEL_FREE_SHMEM, 0xF)                      /* Unverified */ \
   X(AGX_SELECTOR_LABEL_CREATE_NOTIFICATION_QUEUE, 0x10)      /* */            \
   X(AGX_SELECTOR_LABEL_FREE_NOTIFICATION_QUEUE, 0x11)        /* Unverified */ \
   X(AGX_SELECTOR_LABEL_SUBMIT_COMMAND_BUFFERS, 0x1D)         /* Unverified */ \
   X(AGX_SELECTOR_LABEL_GET_VERSION, 0x2A)                    /* Unverified */

struct agx_allocate_resource_resp {
   uint64_t gpu_va;
   uint64_t cpu;
   uint32_t handle;
   uint64_t sub_size;
};

struct agx_v13_allocate_resource_resp {
   uint64_t gpu_va;
   uint64_t cpu;
   uint32_t unk4[3];
   uint32_t handle;
   uint64_t root_size;
   uint32_t guid;
   uint32_t unk11[7];
   /* Maximum size of the suballocation. For a suballocation, this equals:
    *
    *    sub_size = root_size - (sub_cpu - root_cpu)
    *
    * For root allocations, this equals the size.
    */
   uint64_t sub_size;
} __attribute__((packed));

struct agx_v26_allocate_resource_resp {
   uint32_t unk0[2];

   /* Returned CPU virtual address */
   uint64_t cpu;

   /* Returned GPU virtual address */
   uint64_t gpu_va;

   uint32_t unk4[3];

   /* Handle used to identify the resource in the segment list */
   uint32_t handle;

   /* Size of the root resource from which we are allocated. If this is not a
    * suballocation, this is equal to the size.
    */
   uint64_t root_size;

   /* Globally unique identifier for the resource, shown in Instruments */
   uint32_t guid;

   uint32_t unk11[7];

   /** Might or might not correspond to sub_size. */
   uint64_t unk_size;
} __attribute__((packed));

struct IOAccelCommandQueueSubmitArgs_Command {
   uint32_t command_buffer_shmem_id;
   uint32_t segment_list_shmem_id;
   uint64_t unk1B; // 0, new in 12.x
   uint64_t notify_1;
   uint64_t notify_2;
   uint32_t unk2;
   uint32_t unk3;
} __attribute__((packed));

// Version Detection

static int
get_macos_major_version(void)
{
   char str[32];
   size_t size = sizeof(str);
   if (sysctlbyname("kern.osproductversion", str, &size, NULL, 0) == 0) {
      int major = 0;
      sscanf(str, "%d", &major);
      return major;
   } else {
      fprintf(stderr, "Failed to get macOS version from sysctl\n");
      abort();
   }
}

enum agx_version {
   AGX_VERSION_13,
   AGX_VERSION_26,
};

static enum agx_version
_agx_get_version(void)
{
   int major_version = get_macos_major_version();
   if (major_version <= 15) {
      return AGX_VERSION_13;
   } else if (15 < major_version && major_version < 26) {
      UNREACHABLE("Invalid macOS version");
   } else if (major_version >= 26) {
      return AGX_VERSION_26;
   }
   UNREACHABLE("Invalid macOS version");
}

static int _agx_version_cached = -1;
static inline enum agx_version
agx_get_version(void)
{
   if (_agx_version_cached == -1) {
      _agx_version_cached = _agx_get_version();
   }
   return _agx_version_cached;
}

// Lookup and Conversion

static inline uint32_t
agx_selector(enum agx_selector_label label)
{
   switch (agx_get_version()) {
   case AGX_VERSION_13:
      switch (label) {
#define X(label, value)                                                        \
   case label:                                                                 \
      return value;
         _AGX_V13_SELECTORS(X)
#undef X
      case AGX_SELECTOR_LABEL_INVALID:
         return AGX_SELECTOR_INVALID;
      }

   case AGX_VERSION_26:
      switch (label) {
#define X(label, value)                                                        \
   case label:                                                                 \
      return value;
         _AGX_V26_SELECTORS(X)
#undef X
      case AGX_SELECTOR_LABEL_INVALID:
         return AGX_SELECTOR_INVALID;
      }
   }
}

static inline enum agx_selector_label
agx_selector_label(uint32_t selector)
{
   switch (agx_get_version()) {
   case AGX_VERSION_13:
#define X(label, value)                                                        \
   if (selector == value)                                                      \
      return label;
      _AGX_V13_SELECTORS(X)
#undef X
      return AGX_SELECTOR_LABEL_INVALID;

   case AGX_VERSION_26:
#define X(label, value)                                                        \
   if (selector == value)                                                      \
      return label;
      _AGX_V26_SELECTORS(X)
#undef X
      return AGX_SELECTOR_LABEL_INVALID;
   }
}

struct agx_allocate_resource_resp
get_agx_allocate_resource_resp(void *outputStruct, size_t outputStructCnt);
