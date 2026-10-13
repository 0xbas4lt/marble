///! Pinned. Must not be moved or copied.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const types = @import("types.zig");
const log = @import("log.zig");

const Pmm = @import("physical_memory_manager.zig");
const Vmm = @import("virtual_memory_manager.zig");

const KAlloc = @This();

pub const Error = error{OutOfMemory};

/// `ChunkHeader` describes any tracked chunk of memory, either freed, or allocated.
/// It must be placed right before the requested allocated region's base address.
/// It is always placed at the very beginning of every tracked chunk.
const ChunkHeader = extern struct {
    const MagicValue = std.meta.Int(.unsigned, @bitSizeOf(usize) - 1);
    const correct_magic_value: MagicValue = @truncate(std.hash.Fnv1a_128.hash("chunk header magic"));

    /// Size of the entire chunk, including the `ChunkHeader` itself.
    chunk_size: usize,
    /// Pointer to the previous `ChunkHeader`.
    prev: *ChunkHeader,
    /// Pointer to the next `ChunkHeader`.
    next: *ChunkHeader,

    flags_and_magic: packed struct(usize) {
        magic_value: MagicValue,
        is_allocated: u1,
    },

    fn init(is_allocated: bool, chunk_size: usize, prev: *ChunkHeader, next: *ChunkHeader) ChunkHeader {
        return .{
            .chunk_size = chunk_size,
            .prev = prev,
            .next = next,
            .flags_and_magic = .{
                .is_allocated = @intFromBool(is_allocated),
                .magic_value = correct_magic_value,
            },
        };
    }

    inline fn payloadSize(self: *const ChunkHeader) usize {
        @branchHint(.likely);
        return self.chunk_size - @sizeOf(ChunkHeader);
    }

    inline fn isAllocated(self: *const ChunkHeader) bool {
        @branchHint(.likely);
        return self.flags_and_magic.is_allocated;
    }

    inline fn isMagicValid(self: *const ChunkHeader) bool {
        @branchHint(.likely);
        return self.flags_and_magic.magic_value == correct_magic_value;
    }

    inline fn payloadAddr(self: *const ChunkHeader) types.VirtAddr {
        return @intCast(@intFromPtr(self) + @sizeOf(ChunkHeader));
    }

    inline fn addrAfter(self: *const ChunkHeader) types.VirtAddr {
        return @intCast(@intFromPtr(self) + self.chunk_size);
    }

    inline fn invalidate(self: *ChunkHeader) void {
        @branchHint(.likely);
        self.flags_and_magic = 0;
    }
};

const chunk_alignment: std.mem.Alignment = blk: {
    const min_alignment = std.mem.Alignment.fromByteUnits(16);
    break :blk std.mem.Alignment.of(ChunkHeader).max(min_alignment);
};

pmm: *Pmm,
vmm: *Vmm,
/// NOTE: Pinned. Must not be moved or copied.
sentinel: ChunkHeader,

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .free = free,
    .remap = remap,
    .resize = resize,
};

/// `addr` must be page-aligned.
fn allocPages(self: *KAlloc, addr: types.VirtAddr, count: usize) Error!void {
    const max_page_count = 128;
    if (count > max_page_count) {
        log.err("kalloc: allocPages() reached max frame count", .{});
        return Error.OutOfMemory;
    }

    var frame_count: usize = 0;
    var frames: [max_page_count]Pmm.PhysFrame = undefined;
    errdefer for (0..frame_count) |i|
        self.pmm.freeFrame(frames[i]);
    while (frame_count < count) : (frame_count += 1)
        frames[frame_count] = self.pmm.allocateFrame() catch
            return Error.OutOfMemory;

    var mapped_count: usize = 0;
    errdefer for (0..mapped_count) |i| {
        // FIXME: Add unmapping, once vmm supports it.
        _ = i;
    };
    while (mapped_count < count) : (mapped_count += 1)
        self.vmm.map(addr + mapped_count * config.page_size_bytes, frames[mapped_count].physBase(), .{}) catch
            return Error.OutOfMemory;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const self: *KAlloc = @ptrCast(@alignCast(ctx));

    const last_base: types.VirtAddr = if (self.sentinel.prev == &self.sentinel)
        config.kernel_heap_arena_start
    else
        @intCast(self.sentinel.prev.addrAfter());

    var current_header_ptr = self.sentinel.next;
    var return_header_ptr: *ChunkHeader = undefined;
    while (current_header_ptr != &self.sentinel) : (current_header_ptr = current_header_ptr.next) {}

    if (current_header_ptr == &self.sentinel) {
        // FIXME: Resolve alignment.

        const min_chunk_size = len + @sizeOf(ChunkHeader);
        const page_count = std.math.divCeil(usize, min_chunk_size, config.page_size_bytes) catch
            return null;
        self.allocPages(last_base, page_count) catch
            return null;

        return_header_ptr = @ptrFromInt(last_base);
        return_header_ptr.* = .init(false, page_count * config.page_size_bytes, self.sentinel.prev, &self.sentinel);
        self.sentinel.prev.next = return_header_ptr;
        self.sentinel.prev = return_header_ptr;
    }

    _ = alignment;
    _ = ret_addr;
    return @ptrFromInt(return_header_ptr.payloadAddr());
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = new_len;
    _ = return_address;
    return false;
}

fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
    _ = context;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = return_address;
    return null;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, return_address: usize) void {
    // TODO: Check if attempting to free the sentinel

    _ = ctx;
    _ = buf;
    _ = alignment;
    _ = return_address;
}

/// Pinned. Must not be moved or copied.
pub fn init(
    self: *KAlloc,
    physical_memory_manager: *Pmm,
    virtual_memory_manager: *Vmm,
) void {
    self.* = KAlloc{
        .pmm = physical_memory_manager,
        .vmm = virtual_memory_manager,
        .sentinel = ChunkHeader.init(true, 0, undefined, undefined),
    };
    self.sentinel.prev = &self.sentinel;
    self.sentinel.next = &self.sentinel;
}

pub fn deinit(self: *KAlloc) void {
    _ = self;
}

pub fn allocator(self: *KAlloc) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const testing = @import("./testing.zig");
test "kernel allocator test/write page-aligned" {
    std.testing.allocator;
}
