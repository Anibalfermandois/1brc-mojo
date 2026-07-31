#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <string>

namespace {

constexpr NSUInteger kGridThreads = 256 * 256;
constexpr NSUInteger kThreadsPerGroup = 256;

constexpr const char* kScanSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void count_newlines(
    device const uchar* data [[buffer(0)]],
    constant ulong& logical_length [[buffer(1)]],
    constant uint& grid_threads [[buffer(2)]],
    device uint* counts [[buffer(3)]],
    uint tid [[thread_position_in_grid]]) {
    uint count = 0;
    for (ulong index = ulong(tid); index < logical_length;
         index += ulong(grid_threads)) {
        count += uint(data[index] == uchar('\n'));
    }
    counts[tid] = count;
}

kernel void parse_temperatures(
    device const uchar* data [[buffer(0)]],
    constant ulong& logical_length [[buffer(1)]],
    constant uint& grid_threads [[buffer(2)]],
    device uint* counts [[buffer(3)]],
    device long* sums [[buffer(4)]],
    uint tid [[thread_position_in_grid]]) {
    uint count = 0;
    long total = 0;
    for (ulong index = ulong(tid); index < logical_length;
         index += ulong(grid_threads)) {
        if (data[index] != uchar('\n')) {
            continue;
        }

        uint c_frac = uint(data[index - 1] & uchar(0x0F));
        uint c_units = uint(data[index - 3] & uchar(0x0F));
        uint c4 = uint(data[index - 4]);
        uint c5 = uint(data[index - 5]);
        uint c4_value = c4 & 0x0F;
        uint has_tens = uint(c4_value <= 9);
        uint is_negative = uint(c4 == 45) | uint(c5 == 45);
        int temperature = int(
            c4_value * has_tens * 100 + c_units * 10 + c_frac);
        temperature *= 1 - int(is_negative) * 2;

        total += long(temperature);
        count += 1;
    }
    counts[tid] = count;
    sums[tid] = total;
}

kernel void index_stations(
    device const uchar* data [[buffer(0)]],
    constant ulong& logical_length [[buffer(1)]],
    constant uint& grid_threads [[buffer(2)]],
    device const ulong* suffix_occupancy [[buffer(3)]],
    device const short* suffix_prefix [[buffer(4)]],
    device uint* counts [[buffer(5)]],
    device long* temperature_sums [[buffer(6)]],
    device long* dense_sums [[buffer(7)]],
    device long* dense_sq_sums [[buffer(8)]],
    device long* invalid_counts [[buffer(9)]],
    uint tid [[thread_position_in_grid]]) {
    constexpr ulong suffix_multiplier = 3202095764612966159ul;
    constexpr uint suffix_shift = 51;
    constexpr int last_dense_id = 412;

    uint count = 0;
    long temperature_total = 0;
    long dense_total = 0;
    long dense_sq_total = 0;
    long invalid = 0;

    for (ulong index = ulong(tid); index < logical_length;
         index += ulong(grid_threads)) {
        if (data[index] != uchar('\n')) {
            continue;
        }

        uint c_frac = uint(data[index - 1] & uchar(0x0F));
        uint c_units = uint(data[index - 3] & uchar(0x0F));
        uint c4 = uint(data[index - 4]);
        uint c5 = uint(data[index - 5]);
        uint c4_value = c4 & 0x0F;
        uint has_tens = uint(c4_value <= 9);
        uint is_negative = uint(c4 == 45) | uint(c5 == 45);
        int temperature = int(
            c4_value * has_tens * 100 + c_units * 10 + c_frac);
        temperature *= 1 - int(is_negative) * 2;

        uint temperature_width =
            6 - uint(c5 == 59) - 2 * uint(c4 == 59);
        ulong semicolon = index - ulong(temperature_width);
        uint semicolon32 = uint(semicolon);
        ulong suffix_key = 0;
        if (semicolon32 >= 8) {
            device const packed_uchar4* packed = reinterpret_cast<
                device const packed_uchar4*>(data + semicolon32 - 8);
            uint low = as_type<uint>(packed[0]);
            uint high = as_type<uint>(packed[1]);
            suffix_key = ulong(low) | (ulong(high) << 32);
            ulong newline_xor =
                suffix_key ^ ulong(0x0A0A0A0A0A0A0A0Aul);
            ulong newline_bits =
                (newline_xor - ulong(0x0101010101010101ul))
                & ~newline_xor
                & ulong(0x8080808080808080ul);
            if (newline_bits != 0) {
                uint newline_byte = (63 - uint(clz(newline_bits))) / 8;
                suffix_key >>= ulong((newline_byte + 1) * 8);
            }
        } else {
            for (uint cursor = 0; cursor < semicolon32; ++cursor) {
                suffix_key |= ulong(data[cursor]) << ulong(cursor * 8);
            }
        }

        int dense = -1;
        uint slot = uint((suffix_key * suffix_multiplier) >> suffix_shift);
        uint word_index = slot >> 6;
        uint bit_index = slot & 63;
        ulong slot_bit = ulong(1) << ulong(bit_index);
        if ((suffix_occupancy[word_index] & slot_bit) != 0) {
            ulong lower_bits =
                suffix_occupancy[word_index] & (slot_bit - ulong(1));
            dense = int(suffix_prefix[word_index])
                + int(popcount(lower_bits));
        }
        if (
            semicolon32 >= 12 && uint(data[semicolon32 - 12]) == 80
            && uint(data[semicolon32 - 11]) == 97
            && uint(data[semicolon32 - 10]) == 108
            && uint(data[semicolon32 - 9]) == 109) {
            dense = last_dense_id;
        }

        temperature_total += long(temperature);
        count += 1;
        if (dense < 0) {
            invalid += 1;
        } else {
            dense_total += long(dense);
            dense_sq_total += long(dense * dense);
        }
    }

    counts[tid] = count;
    temperature_sums[tid] = temperature_total;
    dense_sums[tid] = dense_total;
    dense_sq_sums[tid] = dense_sq_total;
    invalid_counts[tid] = invalid;
}
)METAL";

using Clock = std::chrono::steady_clock;

uint64_t elapsed_ns(Clock::time_point start, Clock::time_point end) {
    return uint64_t(
        std::chrono::duration_cast<std::chrono::nanoseconds>(end - start)
            .count());
}

struct MetalScan {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLComputePipelineState> scan_pipeline = nil;
    id<MTLComputePipelineState> temperature_pipeline = nil;
    id<MTLComputePipelineState> station_pipeline = nil;
    id<MTLBuffer> input = nil;
    id<MTLBuffer> counts = nil;
    id<MTLBuffer> temperature_sums = nil;
    id<MTLBuffer> suffix_occupancy = nil;
    id<MTLBuffer> suffix_prefix = nil;
    id<MTLBuffer> dense_sums = nil;
    id<MTLBuffer> dense_sq_sums = nil;
    id<MTLBuffer> invalid_counts = nil;
    NSUInteger logical_length = 0;
    NSUInteger mapped_length = 0;
    uint64_t context_ns = 0;
    uint64_t wrap_ns = 0;
    uint64_t station_setup_ns = 0;
    uint64_t run_wall_ns = 0;
    uint64_t gpu_ns = 0;
    int64_t temperature_sum = 0;
    int64_t dense_sum = 0;
    int64_t dense_sq_sum = 0;
    int64_t invalid_count = 0;
    std::string error;
};

void set_error(MetalScan* scan, NSString* message) {
    if (message == nil) {
        scan->error = "unknown Metal error";
        return;
    }
    scan->error = [message UTF8String];
}

}  // namespace

extern "C" void* metal_scan_create() {
    @autoreleasepool {
        auto started = Clock::now();
        auto* scan = new MetalScan;

        scan->device = MTLCreateSystemDefaultDevice();
        if (scan->device == nil) {
            scan->error = "MTLCreateSystemDefaultDevice returned nil";
            return scan;
        }

        scan->queue = [scan->device newCommandQueue];
        if (scan->queue == nil) {
            scan->error = "failed to create Metal command queue";
            return scan;
        }

        NSError* compile_error = nil;
        NSString* source = [NSString stringWithUTF8String:kScanSource];
        id<MTLLibrary> library = [scan->device newLibraryWithSource:source
                                                           options:nil
                                                             error:&compile_error];
        if (library == nil) {
            set_error(scan, compile_error.localizedDescription);
            return scan;
        }

        id<MTLFunction> scan_function =
            [library newFunctionWithName:@"count_newlines"];
        if (scan_function == nil) {
            scan->error = "compiled Metal library lacks count_newlines";
            return scan;
        }

        NSError* pipeline_error = nil;
        scan->scan_pipeline = [scan->device
            newComputePipelineStateWithFunction:scan_function
                                           error:&pipeline_error];
        if (scan->scan_pipeline == nil) {
            set_error(scan, pipeline_error.localizedDescription);
            return scan;
        }

        id<MTLFunction> temperature_function =
            [library newFunctionWithName:@"parse_temperatures"];
        if (temperature_function == nil) {
            scan->error = "compiled Metal library lacks parse_temperatures";
            return scan;
        }

        pipeline_error = nil;
        scan->temperature_pipeline = [scan->device
            newComputePipelineStateWithFunction:temperature_function
                                           error:&pipeline_error];
        if (scan->temperature_pipeline == nil) {
            set_error(scan, pipeline_error.localizedDescription);
            return scan;
        }

        id<MTLFunction> station_function =
            [library newFunctionWithName:@"index_stations"];
        if (station_function == nil) {
            scan->error = "compiled Metal library lacks index_stations";
            return scan;
        }

        pipeline_error = nil;
        scan->station_pipeline = [scan->device
            newComputePipelineStateWithFunction:station_function
                                           error:&pipeline_error];
        if (scan->station_pipeline == nil) {
            set_error(scan, pipeline_error.localizedDescription);
            return scan;
        }

        if (
            kThreadsPerGroup
                > scan->scan_pipeline.maxTotalThreadsPerThreadgroup
            || kThreadsPerGroup
                > scan->temperature_pipeline.maxTotalThreadsPerThreadgroup
            || kThreadsPerGroup
                > scan->station_pipeline.maxTotalThreadsPerThreadgroup) {
            scan->error = "Metal pipeline does not support a 256-thread group";
            return scan;
        }

        scan->counts = [scan->device
            newBufferWithLength:kGridThreads * sizeof(uint32_t)
                        options:MTLResourceStorageModeShared];
        if (scan->counts == nil) {
            scan->error = "failed to allocate shared result buffer";
            return scan;
        }
        scan->temperature_sums = [scan->device
            newBufferWithLength:kGridThreads * sizeof(int64_t)
                        options:MTLResourceStorageModeShared];
        if (scan->temperature_sums == nil) {
            scan->error = "failed to allocate shared temperature sum buffer";
            return scan;
        }
        scan->dense_sums = [scan->device
            newBufferWithLength:kGridThreads * sizeof(int64_t)
                        options:MTLResourceStorageModeShared];
        scan->dense_sq_sums = [scan->device
            newBufferWithLength:kGridThreads * sizeof(int64_t)
                        options:MTLResourceStorageModeShared];
        scan->invalid_counts = [scan->device
            newBufferWithLength:kGridThreads * sizeof(int64_t)
                        options:MTLResourceStorageModeShared];
        if (
            scan->dense_sums == nil || scan->dense_sq_sums == nil
            || scan->invalid_counts == nil) {
            scan->error = "failed to allocate shared station result buffers";
            return scan;
        }

        scan->context_ns = elapsed_ns(started, Clock::now());
        return scan;
    }
}

extern "C" int32_t metal_scan_wrap(
    void* opaque_scan,
    void* bytes,
    size_t logical_length,
    size_t mapped_length) {
    @autoreleasepool {
        auto* scan = static_cast<MetalScan*>(opaque_scan);
        if (
            scan == nullptr || scan->device == nil
            || scan->scan_pipeline == nil
            || scan->temperature_pipeline == nil
            || scan->station_pipeline == nil) {
            return -1;
        }
        if (!scan->error.empty()) {
            return -1;
        }
        if (bytes == nullptr || logical_length == 0) {
            scan->error = "input pointer is null or file is empty";
            return -1;
        }
        if (logical_length > mapped_length) {
            scan->error = "logical input length exceeds mapped length";
            return -1;
        }
        if (mapped_length > scan->device.maxBufferLength) {
            scan->error = "mapped input exceeds Metal maxBufferLength";
            return -1;
        }

        auto started = Clock::now();
        scan->input = [scan->device
            newBufferWithBytesNoCopy:bytes
                              length:mapped_length
                             options:MTLResourceStorageModeShared
                         deallocator:nil];
        scan->wrap_ns = elapsed_ns(started, Clock::now());

        if (scan->input == nil) {
            scan->error = "Metal rejected the no-copy mmap buffer";
            return -1;
        }

        scan->logical_length = logical_length;
        scan->mapped_length = mapped_length;
        return 0;
    }
}

extern "C" int32_t metal_scan_set_station_tables(
    void* opaque_scan,
    const void* suffix_occupancy,
    size_t suffix_occupancy_bytes,
    const void* suffix_prefix,
    size_t suffix_prefix_bytes) {
    @autoreleasepool {
        auto* scan = static_cast<MetalScan*>(opaque_scan);
        if (scan == nullptr || scan->device == nil || !scan->error.empty()) {
            return -1;
        }
        if (
            suffix_occupancy == nullptr || suffix_prefix == nullptr
            || suffix_occupancy_bytes != 128 * sizeof(uint64_t)
            || suffix_prefix_bytes != 128 * sizeof(int16_t)) {
            scan->error = "station tables have unexpected size";
            return -1;
        }

        auto started = Clock::now();
        scan->suffix_occupancy = [scan->device
            newBufferWithBytes:suffix_occupancy
                        length:suffix_occupancy_bytes
                       options:MTLResourceStorageModeShared];
        scan->suffix_prefix = [scan->device
            newBufferWithBytes:suffix_prefix
                        length:suffix_prefix_bytes
                       options:MTLResourceStorageModeShared];
        scan->station_setup_ns = elapsed_ns(started, Clock::now());
        if (scan->suffix_occupancy == nil || scan->suffix_prefix == nil) {
            scan->error = "failed to create Metal station lookup buffers";
            return -1;
        }
        return 0;
    }
}

extern "C" uint64_t metal_scan_count_newlines(void* opaque_scan) {
    @autoreleasepool {
        auto* scan = static_cast<MetalScan*>(opaque_scan);
        if (scan == nullptr || scan->input == nil || !scan->error.empty()) {
            return std::numeric_limits<uint64_t>::max();
        }

        auto started = Clock::now();
        id<MTLCommandBuffer> command = [scan->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder =
            [command computeCommandEncoder];
        if (command == nil || encoder == nil) {
            scan->error = "failed to create Metal command buffer or encoder";
            return std::numeric_limits<uint64_t>::max();
        }

        uint64_t logical_length = uint64_t(scan->logical_length);
        uint32_t grid_threads = uint32_t(kGridThreads);
        [encoder setComputePipelineState:scan->scan_pipeline];
        [encoder setBuffer:scan->input offset:0 atIndex:0];
        [encoder setBytes:&logical_length length:sizeof(logical_length) atIndex:1];
        [encoder setBytes:&grid_threads length:sizeof(grid_threads) atIndex:2];
        [encoder setBuffer:scan->counts offset:0 atIndex:3];
        [encoder dispatchThreads:MTLSizeMake(kGridThreads, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(kThreadsPerGroup, 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];

        if (command.status == MTLCommandBufferStatusError) {
            set_error(scan, command.error.localizedDescription);
            return std::numeric_limits<uint64_t>::max();
        }

        if (command.GPUEndTime >= command.GPUStartTime) {
            scan->gpu_ns = uint64_t(
                (command.GPUEndTime - command.GPUStartTime) * 1.0e9);
        } else {
            scan->gpu_ns = 0;
        }

        auto* counts = static_cast<const uint32_t*>(scan->counts.contents);
        uint64_t total = 0;
        for (NSUInteger index = 0; index < kGridThreads; ++index) {
            total += counts[index];
        }
        scan->run_wall_ns = elapsed_ns(started, Clock::now());
        return total;
    }
}

extern "C" uint64_t metal_scan_parse_temperatures(void* opaque_scan) {
    @autoreleasepool {
        auto* scan = static_cast<MetalScan*>(opaque_scan);
        if (scan == nullptr || scan->input == nil || !scan->error.empty()) {
            return std::numeric_limits<uint64_t>::max();
        }

        auto started = Clock::now();
        id<MTLCommandBuffer> command = [scan->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder =
            [command computeCommandEncoder];
        if (command == nil || encoder == nil) {
            scan->error = "failed to create Metal command buffer or encoder";
            return std::numeric_limits<uint64_t>::max();
        }

        uint64_t logical_length = uint64_t(scan->logical_length);
        uint32_t grid_threads = uint32_t(kGridThreads);
        [encoder setComputePipelineState:scan->temperature_pipeline];
        [encoder setBuffer:scan->input offset:0 atIndex:0];
        [encoder setBytes:&logical_length length:sizeof(logical_length) atIndex:1];
        [encoder setBytes:&grid_threads length:sizeof(grid_threads) atIndex:2];
        [encoder setBuffer:scan->counts offset:0 atIndex:3];
        [encoder setBuffer:scan->temperature_sums offset:0 atIndex:4];
        [encoder dispatchThreads:MTLSizeMake(kGridThreads, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(kThreadsPerGroup, 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];

        if (command.status == MTLCommandBufferStatusError) {
            set_error(scan, command.error.localizedDescription);
            return std::numeric_limits<uint64_t>::max();
        }

        if (command.GPUEndTime >= command.GPUStartTime) {
            scan->gpu_ns = uint64_t(
                (command.GPUEndTime - command.GPUStartTime) * 1.0e9);
        } else {
            scan->gpu_ns = 0;
        }

        auto* counts = static_cast<const uint32_t*>(scan->counts.contents);
        auto* sums =
            static_cast<const int64_t*>(scan->temperature_sums.contents);
        uint64_t total_count = 0;
        int64_t total_sum = 0;
        for (NSUInteger index = 0; index < kGridThreads; ++index) {
            total_count += counts[index];
            total_sum += sums[index];
        }
        scan->temperature_sum = total_sum;
        scan->run_wall_ns = elapsed_ns(started, Clock::now());
        return total_count;
    }
}

extern "C" int64_t metal_scan_temperature_sum(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->temperature_sum;
}

extern "C" uint64_t metal_scan_index_stations(void* opaque_scan) {
    @autoreleasepool {
        auto* scan = static_cast<MetalScan*>(opaque_scan);
        if (
            scan == nullptr || scan->input == nil
            || scan->suffix_occupancy == nil || scan->suffix_prefix == nil
            || !scan->error.empty()) {
            return std::numeric_limits<uint64_t>::max();
        }

        auto started = Clock::now();
        id<MTLCommandBuffer> command = [scan->queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder =
            [command computeCommandEncoder];
        if (command == nil || encoder == nil) {
            scan->error = "failed to create Metal command buffer or encoder";
            return std::numeric_limits<uint64_t>::max();
        }

        uint64_t logical_length = uint64_t(scan->logical_length);
        uint32_t grid_threads = uint32_t(kGridThreads);
        [encoder setComputePipelineState:scan->station_pipeline];
        [encoder setBuffer:scan->input offset:0 atIndex:0];
        [encoder setBytes:&logical_length length:sizeof(logical_length) atIndex:1];
        [encoder setBytes:&grid_threads length:sizeof(grid_threads) atIndex:2];
        [encoder setBuffer:scan->suffix_occupancy offset:0 atIndex:3];
        [encoder setBuffer:scan->suffix_prefix offset:0 atIndex:4];
        [encoder setBuffer:scan->counts offset:0 atIndex:5];
        [encoder setBuffer:scan->temperature_sums offset:0 atIndex:6];
        [encoder setBuffer:scan->dense_sums offset:0 atIndex:7];
        [encoder setBuffer:scan->dense_sq_sums offset:0 atIndex:8];
        [encoder setBuffer:scan->invalid_counts offset:0 atIndex:9];
        [encoder dispatchThreads:MTLSizeMake(kGridThreads, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(kThreadsPerGroup, 1, 1)];
        [encoder endEncoding];
        [command commit];
        [command waitUntilCompleted];

        if (command.status == MTLCommandBufferStatusError) {
            set_error(scan, command.error.localizedDescription);
            return std::numeric_limits<uint64_t>::max();
        }

        if (command.GPUEndTime >= command.GPUStartTime) {
            scan->gpu_ns = uint64_t(
                (command.GPUEndTime - command.GPUStartTime) * 1.0e9);
        } else {
            scan->gpu_ns = 0;
        }

        auto* counts = static_cast<const uint32_t*>(scan->counts.contents);
        auto* temperature_sums =
            static_cast<const int64_t*>(scan->temperature_sums.contents);
        auto* dense_sums =
            static_cast<const int64_t*>(scan->dense_sums.contents);
        auto* dense_sq_sums =
            static_cast<const int64_t*>(scan->dense_sq_sums.contents);
        auto* invalid_counts =
            static_cast<const int64_t*>(scan->invalid_counts.contents);
        uint64_t total_count = 0;
        int64_t total_temperature_sum = 0;
        int64_t total_dense_sum = 0;
        int64_t total_dense_sq_sum = 0;
        int64_t total_invalid_count = 0;
        for (NSUInteger index = 0; index < kGridThreads; ++index) {
            total_count += counts[index];
            total_temperature_sum += temperature_sums[index];
            total_dense_sum += dense_sums[index];
            total_dense_sq_sum += dense_sq_sums[index];
            total_invalid_count += invalid_counts[index];
        }
        scan->temperature_sum = total_temperature_sum;
        scan->dense_sum = total_dense_sum;
        scan->dense_sq_sum = total_dense_sq_sum;
        scan->invalid_count = total_invalid_count;
        scan->run_wall_ns = elapsed_ns(started, Clock::now());
        return total_count;
    }
}

extern "C" uint64_t metal_scan_station_setup_ns(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->station_setup_ns;
}

extern "C" int64_t metal_scan_dense_sum(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->dense_sum;
}

extern "C" int64_t metal_scan_dense_sq_sum(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->dense_sq_sum;
}

extern "C" int64_t metal_scan_invalid_count(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->invalid_count;
}

extern "C" uint64_t metal_scan_context_ns(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->context_ns;
}

extern "C" uint64_t metal_scan_wrap_ns(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->wrap_ns;
}

extern "C" uint64_t metal_scan_run_wall_ns(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->run_wall_ns;
}

extern "C" uint64_t metal_scan_gpu_ns(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    return scan == nullptr ? 0 : scan->gpu_ns;
}

extern "C" void metal_scan_report_error(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    if (scan == nullptr) {
        std::fprintf(stderr, "Metal zero-copy scan: null context\n");
    } else if (!scan->error.empty()) {
        std::fprintf(stderr, "Metal zero-copy scan: %s\n", scan->error.c_str());
    }
}

extern "C" void metal_scan_destroy(void* opaque_scan) {
    auto* scan = static_cast<MetalScan*>(opaque_scan);
    if (scan == nullptr) {
        return;
    }
    scan->input = nil;
    delete scan;
}
