/*
 * Copyright 2025 Andres Riofrio
 * SPDX-License-Identifier: MIT
 *
 * Metal test for wrap.c to verify struct field assumptions.
 * Run with DYLD_INSERT_LIBRARIES=libwrap.dylib to see traced output.
 *
 * Tests:
 * 1. Basic shared buffer allocation (root allocation)
 * 2. GPU-private buffer (check if gpu_va field is populated)
 * 3. MTLHeap sub-allocation (verify size vs sub_size differ)
 * 4. Failed allocation attempt (verify status field)
 */

#import <stdio.h>
#import <Metal/Metal.h>

int
main(int argc, const char *argv[])
{
   @autoreleasepool {
      /* Get default Metal device */
      id<MTLDevice> device = MTLCreateSystemDefaultDevice();
      if (!device) {
         fprintf(stderr, "No Metal device available\n");
         return 1;
      }

      printf("=== Metal device: %s ===\n", [[device name] UTF8String]);

      /* Test 1: Basic shared buffer (root allocation, has CPU mapping) */
      printf("\n=== Test 1: Shared buffer (root allocation) ===\n");
      {
         id<MTLBuffer> buffer =
            [device newBufferWithLength:4096
                                options:MTLResourceStorageModeShared];
         if (!buffer) {
            fprintf(stderr, "Failed to allocate shared buffer\n");
            return 1;
         }
         printf("Shared buffer: %zu bytes, contents=%p\n",
                (size_t)[buffer length], [buffer contents]);

         uint32_t *ptr = (uint32_t *)[buffer contents];
         ptr[0] = 0xDEADBEEF;
      }

      /* Test 2: GPU-private buffer (no CPU mapping, check if gpu_va populated) */
      printf("\n=== Test 2: Private buffer (GPU-only, check gpu_va) ===\n");
      {
         id<MTLBuffer> buffer =
            [device newBufferWithLength:4096
                                options:MTLResourceStorageModePrivate];
         if (!buffer) {
            fprintf(stderr, "Failed to allocate private buffer\n");
            return 1;
         }
         printf("Private buffer: %zu bytes (no CPU contents)\n",
                (size_t)[buffer length]);
      }

      /* Test 3: MTLHeap sub-allocation (should show size != sub_size) */
      printf("\n=== Test 3: Heap sub-allocation (size vs sub_size) ===\n");
      {
         MTLHeapDescriptor *heapDesc = [[MTLHeapDescriptor alloc] init];
         heapDesc.size = 1024 * 1024; /* 1MB heap */
         heapDesc.storageMode = MTLStorageModeShared;

         id<MTLHeap> heap = [device newHeapWithDescriptor:heapDesc];
         if (!heap) {
            fprintf(stderr, "Failed to create heap\n");
            return 1;
         }
         printf("Created heap: %zu bytes\n",
                (size_t)[heap currentAllocatedSize]);

         /* Allocate a small buffer from the heap */
         id<MTLBuffer> subBuffer =
            [heap newBufferWithLength:4096
                              options:MTLResourceStorageModeShared];
         if (!subBuffer) {
            fprintf(stderr, "Failed to allocate from heap\n");
            return 1;
         }
         printf("Sub-allocated buffer: %zu bytes from heap\n",
                (size_t)[subBuffer length]);

         /* Allocate another to see pattern */
         id<MTLBuffer> subBuffer2 =
            [heap newBufferWithLength:8192
                              options:MTLResourceStorageModeShared];
         if (subBuffer2) {
            printf("Sub-allocated buffer 2: %zu bytes from heap\n",
                   (size_t)[subBuffer2 length]);
         }
      }

      /* Test 4: Intentionally fail allocation (check status field) */
      printf("\n=== Test 4: Failed allocation (check status) ===\n");
      {
         /* Try to allocate way more than available - should fail */
         id<MTLBuffer> hugeBuffer =
            [device newBufferWithLength:1ULL << 48
                                options:MTLResourceStorageModeShared];
         if (hugeBuffer) {
            printf("Surprisingly succeeded allocating huge buffer!\n");
         } else {
            printf(
               "Allocation failed as expected (check wrap output for status)\n");
         }
      }
   }

   printf("\n=== Metal test completed successfully ===\n");
   return 0;
}
