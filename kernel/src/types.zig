const std = @import("std");

pub const PhysAddr = u64;
pub const VirtAddr = u64;

/// src.len is guaranteed to not exceed dest_end - dest_begin.
pub const ExecutableLoadSegment = struct {
    /// Must outlive this struct.
    src: []const u8,
    preferred_dest_begin: VirtAddr,
    preferred_dest_end: VirtAddr,
};

pub const ExecutableRelocation = struct {
    preferred_slot: VirtAddr,
    preferred_target: VirtAddr,
};

pub const ExecutableInfo = struct {
    allocator: std.mem.Allocator,
    entry_addr: VirtAddr,
    load_segments: []ExecutableLoadSegment,
    relocations: []ExecutableRelocation,
    load_bias_alignment: std.mem.Alignment,

    pub fn deinit(self: *ExecutableInfo) void {
        self.allocator.free(self.load_segments);
    }
};
