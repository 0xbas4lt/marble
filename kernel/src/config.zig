const std = @import("std");
const types = @import("types.zig");

pub const page_size_bytes: usize = 4096;

pub const log_buffer_size_bytes: usize = 1024 * 2;

pub const kernel_heap_start: usize = 0xffffffdf80000000;
pub const kernel_heap_end: usize = 0xffffffff7fffffff;

extern const _kernel_start: u8;
extern const _kernel_end: u8;
pub inline fn kernelStartVirtAddr() types.VirtAddr {
    return @intFromPtr(&_kernel_start);
}
pub inline fn kernelEndVirtAddr() types.VirtAddr {
    return @intFromPtr(&_kernel_end);
}
pub inline fn kernelSizeBytes() usize {
    return @as(usize, kernelEndVirtAddr() - kernelStartVirtAddr());
}
pub inline fn kernelSizePages() usize {
    return std.math.divCeil(usize, kernelSizeBytes(), page_size_bytes) catch
        unreachable;
}
