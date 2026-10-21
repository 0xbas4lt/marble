const std = @import("std");
const Allocator = std.mem.Allocator;

pub const PhysicalFreeListAllocator = struct {
    const Error = error{OutOfMemory};

    const Header = struct {};

    size: usize,
};

// Physical Memory
//
// 4KIB
//
// 4KIB
//
// 4KIB
//
// 4KIB
//
// 4KIB
//
// 4KIB
//
// 4KIB
//
// 4KIB
//
