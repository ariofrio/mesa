/*
 * Copyright 2026 Andres Riofrio
 * SPDX-License-Identifier: MIT
 */

#include "agx_iokit.h"

struct agx_allocate_resource_resp
get_agx_allocate_resource_resp(void *outputStruct, size_t outputStructCnt)
{
   enum agx_version major_version = agx_get_version();
   switch (major_version) {
   case AGX_VERSION_13: {
      assert(outputStructCnt == sizeof(struct agx_v13_allocate_resource_resp));
      struct agx_v13_allocate_resource_resp *resp = outputStruct;
      return (struct agx_allocate_resource_resp){
         .gpu_va = resp->gpu_va,
         .cpu = resp->cpu,
         .handle = resp->handle,
         .sub_size = resp->sub_size,
      };
   }
   case AGX_VERSION_26: {
      assert(outputStructCnt == sizeof(struct agx_v26_allocate_resource_resp));
      struct agx_v26_allocate_resource_resp *resp = outputStruct;
      return (struct agx_allocate_resource_resp){
         .gpu_va = resp->gpu_va,
         .cpu = resp->cpu,
         .handle = resp->handle,
         .sub_size = resp->unk_size,
      };
   }
   }
}
