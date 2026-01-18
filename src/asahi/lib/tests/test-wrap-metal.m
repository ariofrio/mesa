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
 * 5. GPU command submission (SUBMIT_COMMAND_BUFFERS, CREATE_SHMEM)
 * 6. Buffer deallocation lifecycle (FREE_MEM)
 * 7. Async completion handler (notification ports)
 * 8. Compute shader execution (full command stream with agxdecode)
 */

#import <stdio.h>
#import <unistd.h>
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

      /* Test 5: GPU command submission (exercises SUBMIT_COMMAND_BUFFERS,
       * CREATE_SHMEM) */
      printf("\n=== Test 5: GPU command submission ===\n");
      {
         id<MTLCommandQueue> queue = [device newCommandQueue];
         if (!queue) {
            fprintf(stderr, "Failed to create command queue\n");
            return 1;
         }

         id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];

         /* Simple blit - just need something to submit */
         id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
         [blit endEncoding];

         [cmdBuf commit];
         [cmdBuf waitUntilCompleted];
         printf("Command buffer completed with status: %lu\n",
                (unsigned long)[cmdBuf status]);
      }

      /* Test 6: Explicit buffer lifecycle (exercises FREE_MEM) */
      printf("\n=== Test 6: Buffer deallocation ===\n");
      {
         for (int i = 0; i < 3; i++) {
            @autoreleasepool {
               id<MTLBuffer> buf =
                  [device newBufferWithLength:4096
                                      options:MTLResourceStorageModeShared];
               if (!buf) {
                  fprintf(stderr, "Failed to allocate buffer %d\n", i);
                  return 1;
               }
               printf("Allocated buffer %d\n", i);
            } /* Buffer released here - should trigger FREE_MEM */
            printf("Released buffer %d\n", i);
         }
      }

      /* Test 7: Async completion handler (may exercise notification ports) */
      printf("\n=== Test 7: Async completion handler ===\n");
      {
         id<MTLCommandQueue> queue = [device newCommandQueue];
         __block BOOL completed = NO;

         id<MTLCommandBuffer> cmdBuf = [queue commandBuffer];
         [cmdBuf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
           printf("Completion handler called, status=%lu\n",
                  (unsigned long)[cb status]);
           completed = YES;
         }];

         id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
         [blit endEncoding];
         [cmdBuf commit];

         /* Spin wait for completion */
         while (!completed) {
            usleep(1000);
         }
      }

      /* Test 8: Compute shader with 1 buffer */
      printf("\n=== Test 8: Compute shader (1 buffer) ===\n");
      {
         NSError *error = nil;
         NSString *src =
            @"kernel void add(device uint *out [[buffer(0)]]) { out[0] = 42; }";
         id<MTLLibrary> lib = [device newLibraryWithSource:src
                                                   options:nil
                                                     error:&error];
         if (!lib) {
            fprintf(stderr, "Failed to compile shader: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
         }

         id<MTLFunction> fn = [lib newFunctionWithName:@"add"];
         id<MTLComputePipelineState> pso =
            [device newComputePipelineStateWithFunction:fn error:&error];

         id<MTLBuffer> outBuf =
            [device newBufferWithLength:4 options:MTLResourceStorageModeShared];

         id<MTLCommandQueue> queue = [device newCommandQueue];
         id<MTLCommandBuffer> cmd = [queue commandBuffer];
         id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
         [enc setComputePipelineState:pso];
         [enc setBuffer:outBuf offset:0 atIndex:0];
         [enc dispatchThreads:MTLSizeMake(1, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
         [enc endEncoding];
         [cmd commit];
         [cmd waitUntilCompleted];

         uint32_t *result = [outBuf contents];
         printf("Compute result: %u (expected 42)\n", result[0]);
      }

      /* Test 9: Compute shader with 2 buffers - see if handle refs change */
      printf("\n=== Test 9: Compute shader (2 buffers) ===\n");
      {
         NSError *error = nil;
         NSString *src =
            @"kernel void copy(device uint *in [[buffer(0)]], "
            @"device uint *out [[buffer(1)]]) { out[0] = in[0] + 1; }";
         id<MTLLibrary> lib = [device newLibraryWithSource:src
                                                   options:nil
                                                     error:&error];
         if (!lib) {
            fprintf(stderr, "Failed to compile 2-buffer shader: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
         }

         id<MTLFunction> fn = [lib newFunctionWithName:@"copy"];
         id<MTLComputePipelineState> pso =
            [device newComputePipelineStateWithFunction:fn error:&error];

         id<MTLBuffer> inBuf =
            [device newBufferWithLength:4 options:MTLResourceStorageModeShared];
         id<MTLBuffer> outBuf =
            [device newBufferWithLength:4 options:MTLResourceStorageModeShared];

         /* Write input value */
         uint32_t *inPtr = [inBuf contents];
         inPtr[0] = 100;

         id<MTLCommandQueue> queue = [device newCommandQueue];
         id<MTLCommandBuffer> cmd = [queue commandBuffer];
         id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
         [enc setComputePipelineState:pso];
         [enc setBuffer:inBuf offset:0 atIndex:0];
         [enc setBuffer:outBuf offset:0 atIndex:1];
         [enc dispatchThreads:MTLSizeMake(1, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
         [enc endEncoding];
         [cmd commit];
         [cmd waitUntilCompleted];

         uint32_t *result = [outBuf contents];
         printf("Compute result: %u (expected 101)\n", result[0]);
      }

      /* Test 10: Actual render pass with vertex/fragment shaders */
      printf("\n=== Test 10: Render pass (vertex + fragment) ===\n");
      {
         NSError *error = nil;

         /* Simple vertex + fragment shader */
         NSString *shaderSrc = @
            "#include <metal_stdlib>\n"
            "using namespace metal;\n"
            "struct VertexOut { float4 pos [[position]]; };\n"
            "vertex VertexOut vert(uint vid [[vertex_id]]) {\n"
            "   VertexOut out;\n"
            "   float2 positions[3] = {float2(0,1), float2(-1,-1), float2(1,-1)};\n"
            "   out.pos = float4(positions[vid], 0, 1);\n"
            "   return out;\n"
            "}\n"
            "fragment float4 frag() { return float4(1,0,0,1); }\n";

         id<MTLLibrary> lib = [device newLibraryWithSource:shaderSrc
                                                   options:nil
                                                     error:&error];
         if (!lib) {
            fprintf(stderr, "Failed to compile render shaders: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
         }

         id<MTLFunction> vertFn = [lib newFunctionWithName:@"vert"];
         id<MTLFunction> fragFn = [lib newFunctionWithName:@"frag"];

         /* Create render pipeline */
         MTLRenderPipelineDescriptor *pipeDesc =
            [[MTLRenderPipelineDescriptor alloc] init];
         pipeDesc.vertexFunction = vertFn;
         pipeDesc.fragmentFunction = fragFn;
         pipeDesc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;

         id<MTLRenderPipelineState> pso =
            [device newRenderPipelineStateWithDescriptor:pipeDesc error:&error];
         if (!pso) {
            fprintf(stderr, "Failed to create render pipeline: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
         }

         /* Create a small texture as render target */
         MTLTextureDescriptor *texDesc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                               width:64
                                                              height:64
                                                           mipmapped:NO];
         texDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
         id<MTLTexture> renderTarget = [device newTextureWithDescriptor:texDesc];

         /* Render pass */
         MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
         passDesc.colorAttachments[0].texture = renderTarget;
         passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
         passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
         passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

         id<MTLCommandQueue> queue = [device newCommandQueue];
         id<MTLCommandBuffer> cmd = [queue commandBuffer];
         id<MTLRenderCommandEncoder> enc =
            [cmd renderCommandEncoderWithDescriptor:passDesc];
         [enc setRenderPipelineState:pso];
         [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
         [enc endEncoding];
         [cmd commit];
         [cmd waitUntilCompleted];

         printf("Render pass completed, status=%lu\n", (unsigned long)[cmd status]);
      }

      /* Test 11: Compute shader with different thread count */
      printf("\n=== Test 11: Compute shader (64 threads) ===\n");
      {
         NSError *error = nil;
         NSString *src =
            @"kernel void fill(device uint *out [[buffer(0)]], "
            @"uint tid [[thread_position_in_grid]]) { out[tid] = tid; }";
         id<MTLLibrary> lib = [device newLibraryWithSource:src
                                                   options:nil
                                                     error:&error];
         if (!lib) {
            fprintf(stderr, "Failed to compile fill shader: %s\n",
                    [[error localizedDescription] UTF8String]);
            return 1;
         }

         id<MTLFunction> fn = [lib newFunctionWithName:@"fill"];
         id<MTLComputePipelineState> pso =
            [device newComputePipelineStateWithFunction:fn error:&error];

         id<MTLBuffer> outBuf =
            [device newBufferWithLength:256 options:MTLResourceStorageModeShared];

         id<MTLCommandQueue> queue = [device newCommandQueue];
         id<MTLCommandBuffer> cmd = [queue commandBuffer];
         id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
         [enc setComputePipelineState:pso];
         [enc setBuffer:outBuf offset:0 atIndex:0];
         [enc dispatchThreads:MTLSizeMake(64, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(32, 1, 1)];
         [enc endEncoding];
         [cmd commit];
         [cmd waitUntilCompleted];

         uint32_t *result = [outBuf contents];
         printf("First 4 results: %u %u %u %u (expected 0 1 2 3)\n",
                result[0], result[1], result[2], result[3]);
      }
   }

   printf("\n=== Metal test completed successfully ===\n");
   return 0;
}
