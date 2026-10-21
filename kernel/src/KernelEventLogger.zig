//!
//! Kernel logger and ring buffer.
//! Each write to the ring buffer advances the cursor.
//!
const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const KernelEventLogger = @This();

/// `ring_buffer.len` must be a power of two.
ring_buffer: []Record,
/// SAFETY: Check if wrap-over is plausible on the target.
/// FIXME: 32-bit compatibility.
total_logged_record_count: usize,
clock_count_fn: *const fn () ?usize,

pub const Severity = enum {
    debug,
    note,
    warning,
    @"error",
};

pub const Tag = enum(u16) {
    milestone_kernel_booting,
    milestone_physical_memory_manager_ready,
    milestone_kernel_heap_ready,
    milestone_virtual_memory_manager_ready,

    warn_unavailable_serial,

    pub fn string(self: Tag) []const u8 {
        return switch (self) {
            .milestone_kernel_booting => "kernel is booting",
            .milestone_physical_memory_manager_ready => "physical memory manager is ready",
            .milestone_kernel_heap_ready => "kernel heap allocator is ready",
            .milestone_virtual_memory_manager_ready => "virtual memory manager is ready",
            .warn_unavailable_serial => "serial port is unavailable",
        };
    }

    pub fn severity(self: Tag) Severity {
        return switch (self) {
            .milestone_kernel_booting => .note,
            .milestone_physical_memory_manager_ready => .debug,
            .milestone_kernel_heap_ready => .debug,
            .milestone_virtual_memory_manager_ready => .debug,
            .warn_unavailable_serial => .warning,
        };
    }
};

pub const Record = extern struct {
    tag: Tag,

    /// Set to 0xFFFFFFFF_FFFFFFFF if no clock count is provided.
    clock_count: u64,
};

/// `buffer.len` must be a power of two.
pub fn init(buffer: []Record, clock_count_fn: *const fn () ?usize) KernelEventLogger {
    std.debug.assert(std.math.isPowerOfTwo(buffer.len));
    return .{
        .ring_buffer = buffer,
        .total_logged_record_count = 0,
        .clock_count_fn = clock_count_fn,
    };
}

pub fn log(self: *KernelEventLogger, tag: Tag) void {
    const clock_count: u64 = @intCast(self.clock_count_fn() orelse std.math.maxInt(u64));
    const buf_index = self.total_logged_record_count % self.ring_buffer.len;
    self.ring_buffer[buf_index] = .{ .tag = tag, .clock_count = clock_count };
    self.total_logged_record_count +%= 1;
}

pub const Iterator = struct {
    /// Historical index (not the wrapped one!!).
    /// Set by `.next()`.
    index: usize = 0,
    logger: *const KernelEventLogger,
    /// Returns the next available record.
    /// If there are no records left, returns a `null`.
    pub fn next(self: *@This()) ?Record {
        if (self.index >= self.logger.total_logged_record_count)
            return null;
        const last_index =
            if (self.logger.total_logged_record_count > self.logger.ring_buffer.len)
                self.logger.total_logged_record_count - self.logger.ring_buffer.len
            else
                0;
        if (self.index < last_index)
            self.index = last_index;
        const buf_index = self.index % self.logger.ring_buffer.len;
        self.index +%= 1;
        const result = self.logger.ring_buffer[buf_index];
        return result;
    }
};

pub fn iter(self: *const KernelEventLogger) Iterator {
    return .{ .logger = self };
}

// --------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------
const test_clock = struct {
    pub fn null_clock() ?usize {
        return null;
    }
};

test "write and read raw buffer" {
    var buf: [8]Record = @splat(undefined);
    var logger = init(&buf, test_clock.null_clock);
    logger.log(.milestone_kernel_booting);
    logger.log(.milestone_kernel_heap_ready);
    logger.log(.milestone_physical_memory_manager_ready);
    logger.log(.milestone_virtual_memory_manager_ready);
    try testing.expectEqual(buf[0], Record{
        .tag = .milestone_kernel_booting,
        .clock_count = std.math.maxInt(u64),
    });
    try testing.expectEqual(buf[1], Record{
        .tag = .milestone_kernel_heap_ready,
        .clock_count = std.math.maxInt(u64),
    });
    try testing.expectEqual(buf[2], Record{
        .tag = .milestone_physical_memory_manager_ready,
        .clock_count = std.math.maxInt(u64),
    });
    try testing.expectEqual(buf[3], Record{
        .tag = .milestone_virtual_memory_manager_ready,
        .clock_count = std.math.maxInt(u64),
    });
}

test "overwrite head and read raw buffer" {
    const buf_size = 8;
    var buf: [buf_size]Record = @splat(undefined);
    var logger = init(&buf, test_clock.null_clock);
    for (0..buf_size) |_| logger.log(.milestone_kernel_booting);
    logger.log(.milestone_kernel_heap_ready);
    try testing.expectEqual(buf[0], Record{
        .tag = .milestone_kernel_heap_ready,
        .clock_count = std.math.maxInt(u64),
    });
    for (1..buf_size) |i| try testing.expectEqual(buf[i], Record{
        .tag = .milestone_kernel_booting,
        .clock_count = std.math.maxInt(u64),
    });
}

test "iterator read empty" {
    var buf: [8]Record = @splat(undefined);
    var logger = init(&buf, test_clock.null_clock);
    var iterator = logger.iter();
    try testing.expectEqual(null, iterator.next());
}

test "iterator read" {
    var buf: [8]Record = @splat(undefined);
    var logger = init(&buf, test_clock.null_clock);
    logger.log(.milestone_kernel_booting);
    logger.log(.milestone_kernel_heap_ready);
    logger.log(.milestone_physical_memory_manager_ready);
    logger.log(.milestone_virtual_memory_manager_ready);
    var iterator = logger.iter();
    var record = iterator.next();
    var i: usize = 0;
    while (record) |rec| : ({
        record = iterator.next();
        i += 1;
    }) {
        try testing.expectEqual(rec.clock_count, std.math.maxInt(u64));
        testing.expectEqual(rec.tag, switch (i) {
            0 => Tag.milestone_kernel_booting,
            1 => Tag.milestone_kernel_heap_ready,
            2 => Tag.milestone_physical_memory_manager_ready,
            3 => Tag.milestone_virtual_memory_manager_ready,
            else => unreachable,
        }) catch |err| {
            std.debug.print("[{}] record's tag: {}\n", .{ i, rec.tag });
            return err;
        };
    }
    errdefer std.debug.print("Iterated over {} records.\n", .{i});
    try testing.expectEqual(i, 4);
}

test "iterator read overflowing" {
    var buf: [8]Record = @splat(undefined);
    var logger = init(&buf, test_clock.null_clock);
    for (0..2) |_| {
        logger.log(.milestone_kernel_booting);
        logger.log(.milestone_kernel_heap_ready);
        logger.log(.milestone_physical_memory_manager_ready);
        logger.log(.milestone_virtual_memory_manager_ready);
    }
    logger.log(.milestone_kernel_heap_ready);

    // Expected buffer layout:
    //.kernel_heap_ready
    //.kernel_heap_ready               <- last
    //.physical_memory_manager_ready
    //.virtual_memory_manager_ready
    //.kernel_boot_start
    //.kernel_heap_ready
    //.physical_memory_manager_ready
    //.virtual_memory_manager_ready

    var iterator = logger.iter();
    var record = iterator.next();
    var i: usize = 0;
    while (record) |rec| : ({
        record = iterator.next();
        i += 1;
    }) {
        try testing.expectEqual(rec.clock_count, std.math.maxInt(u64));
        testing.expectEqual(switch (i) {
            0 => Tag.milestone_kernel_heap_ready,
            1 => Tag.milestone_physical_memory_manager_ready,
            2 => Tag.milestone_virtual_memory_manager_ready,
            3 => Tag.milestone_kernel_booting,
            4 => Tag.milestone_kernel_heap_ready,
            5 => Tag.milestone_physical_memory_manager_ready,
            6 => Tag.milestone_virtual_memory_manager_ready,
            7 => Tag.milestone_kernel_heap_ready,
            else => unreachable,
        }, rec.tag) catch |err| {
            std.debug.print("#{}-read record's tag: {}\n", .{ i + 1, rec.tag });
            return err;
        };
    }
    errdefer std.debug.print("Iterated over {} records.\n", .{i});
    try testing.expectEqual(8, i);
}

test "iterator read lapped" {
    var buf: [4]Record = @splat(undefined);
    var logger = init(&buf, test_clock.null_clock);
    logger.log(.milestone_kernel_booting);
    logger.log(.milestone_kernel_heap_ready);
    logger.log(.milestone_physical_memory_manager_ready);
    logger.log(.milestone_virtual_memory_manager_ready);
    var iterator = logger.iter();
    try testing.expectEqual(Tag.milestone_kernel_booting, iterator.next().?.tag);
    logger.log(.milestone_kernel_booting);
    logger.log(.milestone_kernel_heap_ready);
    try testing.expectEqual(Tag.milestone_physical_memory_manager_ready, iterator.next().?.tag);
}
