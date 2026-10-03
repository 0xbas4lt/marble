const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const types = @import("types.zig");
const pmm = @import("physical_memory_manager.zig");
const vmm = @import("virtual_memory_manager.zig");

const chunk_header_size_with_backref = @sizeOf(ChunkHeader) + backref_size_bytes;

const backref_size_bytes = 8;
const tail_min_recovered_bytes = 256;

comptime {
    if (chunk_header_size_with_backref > tail_min_recovered_bytes)
        @compileError("tail_min_recovered_bytes is too small");
}

var total_free_byte_count: usize = undefined;
var total_free_chunk_count: usize = undefined;

var sentinel = struct {
    head: *ChunkHeader = undefined,
    tail: *ChunkHeader = undefined,
}{};

/// The chunk itself must be sized u64 + u64 + u64 - so the `types.VirtAddr` right before the allocated structure is always a pointer to its ChunkHeader.
const ChunkHeader = packed struct {
    prev_addr: types.VirtAddr,
    next_addr: types.VirtAddr,
    /// The most significant bit is the 'freed' flag, other bits are the size of the chunk, following the `ChunkHeader`.
    size_and_free: usize,

    const isFreeBitMask: usize = @as(usize, 1) << @as(u6, @bitSizeOf(usize) - 1);

    pub inline fn prev(self: *const ChunkHeader) *ChunkHeader {
        return @ptrFromInt(self.prev_addr);
    }

    pub inline fn next(self: *const ChunkHeader) *ChunkHeader {
        return @ptrFromInt(self.next_addr);
    }

    pub inline fn isFree(self: *const ChunkHeader) bool {
        return self.size_and_free & isFreeBitMask == isFreeBitMask;
    }

    pub inline fn setFree(self: *ChunkHeader) void {
        self.size_and_free |= isFreeBitMask;
    }

    pub inline fn setAllocated(self: *ChunkHeader) void {
        self.size_and_free &= ~isFreeBitMask;
    }

    pub inline fn getSize(self: *const ChunkHeader) usize {
        return self.size_and_free & ~isFreeBitMask;
    }

    pub inline fn setSpanSize(self: *ChunkHeader, size: usize) void {
        self.size_and_free = (size & ~isFreeBitMask) | (self.size_and_free & isFreeBitMask);
    }

    // TODO: Impl, and refactor downstream code.
    pub inline fn getAddrAfter(self: *const ChunkHeader) types.VirtAddr {
        return @intCast(@intFromPtr(self) + @sizeOf(ChunkHeader));
    }

    // TODO: Impl, and refactor downstream code.
    pub inline fn getAddrAfterBackref(self: *const ChunkHeader) types.VirtAddr {
        return self.getAddrAfter() + backref_size_bytes;
    }

    pub const NewHeaderOptions = struct {
        prev_chunk: *ChunkHeader,
        next_chunk: *ChunkHeader,
        size: usize,
        is_free: bool,
    };

    pub inline fn newAtAddress(
        address: types.VirtAddr,
        options: NewHeaderOptions,
    ) *ChunkHeader {
        const log = @import("log.zig");
        log.info("kalloc: newAtAddress, address: 0x{X}", .{address});

        var header: *ChunkHeader = @ptrFromInt(address);
        header.prev_addr = @intFromPtr(options.prev_chunk);
        header.next_addr = @intFromPtr(options.next_chunk);
        header.setSpanSize(options.size);
        if (options.is_free) header.setFree() else header.setAllocated();
        return header;
    }
};

fn map(virt_addr: types.VirtAddr, phys_addr: types.VirtAddr) AllocError!void {
    return vmm.map(virt_addr, phys_addr, .{}) catch |err| switch (err) {
        vmm.Error.AlreadyMapped => @panic("kalloc: attempted to map a page to an already-mapped virtual address"),
        vmm.Error.OutOfMemory => AllocError.OutOfMemory,
    };
}

pub fn init() void {
    const frame = pmm.allocateFrame() catch
        @panic("kalloc init: out of memory");
    map(config.kernel_heap_arena_start, frame.physBase()) catch
        @panic("kalloc init: map failed");

    const free_byte_count = config.page_size_bytes - @sizeOf(ChunkHeader) - backref_size_bytes;

    const chunk = ChunkHeader.newAtAddress(
        config.kernel_heap_arena_start,
        .{
            .next_chunk = undefined,
            .prev_chunk = undefined,
            .size = free_byte_count,
            .is_free = true,
        },
    );

    sentinel.head = chunk;
    sentinel.tail = chunk;

    total_free_byte_count = free_byte_count;
    total_free_chunk_count = 1;
}

const AllocError = error{ InvalidSize, OutOfMemory };

const AllocOptions = struct {
    /// Specifies the requested alignment. Must be a power of 2.
    /// Must not be 0.
    alignment: std.mem.Alignment = .@"16",
};

fn computeCutTail(candidate_addr: types.VirtAddr, chunk_end_addr: types.VirtAddr) ?types.VirtAddr {
    const aligned = std.mem.alignForward(types.VirtAddr, candidate_addr, @alignOf(ChunkHeader));
    if (aligned + @sizeOf(ChunkHeader) > chunk_end_addr) return null;
    const tail_size = chunk_end_addr - aligned - @sizeOf(ChunkHeader);
    if (tail_size < tail_min_recovered_bytes) return null;
    return aligned;
}

pub fn allocBytes(
    size_bytes: usize,
    options: AllocOptions,
) AllocError![]u8 {
    if (size_bytes == 0)
        return AllocError.InvalidSize;

    const alignment = options.alignment.toByteUnits();

    var cur_chunk_h = sentinel.head;
    var found_fit = false;
    var best_chunk_h: *ChunkHeader = undefined;
    var best_chunk_original_size: usize = undefined;
    var best_chunk_end_addr: types.VirtAddr = undefined;
    var min_wasted_bytes: usize = std.math.maxInt(usize);
    var cut_tail_at: ?types.VirtAddr = null;
    var req_map_count: usize = 0;
    var req_map_start: types.VirtAddr = undefined;
    while (true) : ({
        if (cur_chunk_h == sentinel.tail) break;
        cur_chunk_h = cur_chunk_h.next();
    }) {
        if (!cur_chunk_h.isFree()) continue;

        const is_tail = cur_chunk_h == sentinel.tail;
        const req_base_addr: types.VirtAddr = @intCast(std.mem.alignForward(
            usize,
            @intFromPtr(cur_chunk_h) + @sizeOf(ChunkHeader) + backref_size_bytes,
            alignment,
        ));
        const pad_size_no_backref = @as(usize, req_base_addr) - @intFromPtr(cur_chunk_h) - @sizeOf(ChunkHeader);
        const req_size_with_padding = pad_size_no_backref + size_bytes;
        const cur_chunk_size = cur_chunk_h.getSize();
        const is_too_large = req_size_with_padding > cur_chunk_size;

        var cur_wasted_bytes = pad_size_no_backref;
        var cur_cut_tail_at: ?types.VirtAddr = null;
        var cur_req_map_count: usize = 0;
        var cur_req_map_start: types.VirtAddr = undefined;
        var cur_chunk_end_addr: types.VirtAddr = undefined;

        if (is_too_large and !is_tail) {
            const between_space_bytes = @intFromPtr(cur_chunk_h.next()) - @intFromPtr(cur_chunk_h) - @sizeOf(ChunkHeader);
            if (between_space_bytes >= req_size_with_padding) {
                cur_chunk_end_addr = @intFromPtr(cur_chunk_h.next());
                const candidate = req_base_addr + @as(types.VirtAddr, size_bytes);
                if (computeCutTail(candidate, cur_chunk_end_addr)) |aligned| {
                    cur_cut_tail_at = aligned;
                } else {
                    cur_wasted_bytes += cur_chunk_end_addr - candidate;
                }
                cur_req_map_count = 0;
            } else continue;
        } else if (is_too_large and is_tail) {
            const additional_bytes_count = req_size_with_padding - backref_size_bytes - cur_chunk_size;
            cur_req_map_start = std.mem.alignForward(types.VirtAddr, cur_chunk_h.getAddrAfterBackref(), config.page_size_bytes);
            cur_req_map_count = std.mem.alignForward(types.VirtAddr, @intCast(additional_bytes_count), config.page_size_bytes) / config.page_size_bytes;
            cur_chunk_end_addr = cur_req_map_start + cur_req_map_count * config.page_size_bytes;

            const candidate = req_base_addr + @as(types.VirtAddr, size_bytes);
            if (computeCutTail(candidate, cur_chunk_end_addr)) |aligned| {
                cur_cut_tail_at = aligned;
                cur_wasted_bytes += @sizeOf(ChunkHeader);
            } else {
                cur_wasted_bytes += cur_chunk_end_addr - candidate;
            }
        } else {
            cur_req_map_count = 0;
            cur_chunk_end_addr = if (is_tail)
                @intFromPtr(cur_chunk_h) + @sizeOf(ChunkHeader) + backref_size_bytes + cur_chunk_size
            else
                @intFromPtr(cur_chunk_h.next());

            const candidate = req_base_addr + @as(types.VirtAddr, size_bytes);
            if (computeCutTail(candidate, cur_chunk_end_addr)) |aligned| {
                cur_cut_tail_at = aligned;
            } else {
                cur_wasted_bytes += cur_chunk_end_addr - candidate;
            }
        }

        if (cur_wasted_bytes > min_wasted_bytes) continue;
        found_fit = true;
        best_chunk_h = cur_chunk_h;
        best_chunk_original_size = cur_chunk_size;
        best_chunk_end_addr = cur_chunk_end_addr;
        min_wasted_bytes = cur_wasted_bytes;
        cut_tail_at = cur_cut_tail_at;
        req_map_count = cur_req_map_count;
        req_map_start = cur_req_map_start;
    }

    if (!found_fit) {
        if (sentinel.tail.isFree()) return AllocError.OutOfMemory;

        const new_chunk_addr: types.VirtAddr = @intCast(@intFromPtr(sentinel.tail) + @sizeOf(ChunkHeader) + backref_size_bytes + sentinel.tail.getSize());
        const new_chunk_h = ChunkHeader.newAtAddress(new_chunk_addr, .{
            .prev_chunk = sentinel.tail,
            .next_chunk = undefined,
            .size = 0,
            .is_free = true,
        });
        sentinel.tail.next_addr = @intFromPtr(new_chunk_h);
        sentinel.tail = new_chunk_h;

        const req_base_addr: types.VirtAddr = @intCast(std.mem.alignForward(
            usize,
            new_chunk_h.getAddrAfterBackref(),
            alignment,
        ));
        const pad_size_no_backref = @as(usize, req_base_addr) - new_chunk_addr - @sizeOf(ChunkHeader);
        const req_size_with_padding = pad_size_no_backref + size_bytes;

        const additional_bytes_count = req_size_with_padding - backref_size_bytes;
        req_map_start = std.mem.alignForward(types.VirtAddr, new_chunk_h.getAddrAfterBackref(), config.page_size_bytes);
        req_map_count = std.mem.alignForward(types.VirtAddr, @intCast(additional_bytes_count), config.page_size_bytes) / config.page_size_bytes;
        best_chunk_end_addr = req_map_start + req_map_count * config.page_size_bytes;

        min_wasted_bytes = pad_size_no_backref;
        const candidate = req_base_addr + @as(types.VirtAddr, size_bytes);
        if (computeCutTail(candidate, best_chunk_end_addr)) |aligned| {
            cut_tail_at = aligned;
            min_wasted_bytes += @sizeOf(ChunkHeader);
        } else {
            min_wasted_bytes += best_chunk_end_addr - candidate;
        }
        best_chunk_h = new_chunk_h;
        best_chunk_original_size = 0;
        found_fit = true;
    }

    // Allocate, map, splice, or (and) expand, in accordance to provided flags of best_chunk_h.
    if (req_map_count > 0) {
        var i: usize = 0;
        while (i < req_map_count) : (i += 1) {
            // FIXME: PARTIAL ALLOCATION LEAKS MEMORY PAGES ON OOM.
            const frame = pmm.allocateFrame() catch return AllocError.OutOfMemory;
            map(req_map_start + i * config.page_size_bytes, frame.physBase()) catch
                @panic("kalloc: map failed while growing heap");
        }
        total_free_byte_count += req_map_count * config.page_size_bytes;
    }

    const chunk_addr = @intFromPtr(best_chunk_h);
    const req_base_addr: types.VirtAddr = @intCast(std.mem.alignForward(
        usize,
        chunk_addr + @sizeOf(ChunkHeader) + backref_size_bytes,
        alignment,
    ));

    total_free_byte_count -= best_chunk_original_size;
    total_free_chunk_count -= 1;

    if (cut_tail_at) |tail_addr| {
        const was_tail = best_chunk_h == sentinel.tail;
        const old_next_h: ?*ChunkHeader = if (was_tail) null else best_chunk_h.next();
        const tail_size = best_chunk_end_addr - tail_addr - @sizeOf(ChunkHeader);

        const tail_chunk_h = ChunkHeader.newAtAddress(tail_addr, .{
            .prev_chunk = best_chunk_h,
            .next_chunk = if (old_next_h) |n| n else undefined,
            .size = tail_size,
            .is_free = true,
        });

        if (old_next_h) |n| {
            n.prev_addr = @intFromPtr(tail_chunk_h);
        } else {
            sentinel.tail = tail_chunk_h;
        }
        best_chunk_h.next_addr = @intFromPtr(tail_chunk_h);
        best_chunk_h.setSpanSize(tail_addr - chunk_addr - @sizeOf(ChunkHeader) - backref_size_bytes);

        total_free_byte_count += tail_size;
        total_free_chunk_count += 1;
    } else {
        best_chunk_h.setSpanSize(best_chunk_end_addr - chunk_addr - @sizeOf(ChunkHeader) - backref_size_bytes);
    }
    best_chunk_h.setAllocated();

    const backref_ptr: *usize = @ptrFromInt(req_base_addr - backref_size_bytes);
    backref_ptr.* = chunk_addr;

    const result_ptr: [*]u8 = @ptrFromInt(req_base_addr);
    return result_ptr[0..size_bytes];
}

const FreeError = error{ DoubleFree, OutOfBounds };

fn freeBytes(slice: []u8) FreeError!void {
    // TODO: Find the matching header, and mark it as free.
    _ = slice;
}

const PageAllocator = struct {
    pub const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        _ = ctx;
        _ = return_address;
        const bytes = allocBytes(len, .{ .alignment = alignment }) catch return null;
        return bytes.ptr;
    }

    fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        //TODO: Implement resizing.
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return false;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        _ = context;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = return_address;
        return null;
    }

    fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = return_address;
    }
};

var page_allocator_impl: PageAllocator = .{};
pub var page_allocator: std.mem.Allocator = .{
    .ptr = &page_allocator_impl,
    .vtable = &PageAllocator.vtable,
};
