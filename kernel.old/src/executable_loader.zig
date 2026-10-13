const std = @import("std");
const config = @import("config.zig");
const types = @import("types.zig");

const Pmm = @import("physical_memory_manager.zig");
const Vmm = @import("virtual_memory_manager.zig");

pub const Error = error{
    InvalidAddress,
    OutOfMemory,
};

fn randomIntStub(from: usize, to: usize) usize {
    _ = to;
    return from;
}

pub const LoadedExecutable = struct {
    pmm: *Pmm,
    vmm: *Vmm,
    allocator: std.mem.Allocator,
    frames: []Pmm.PhysFrame,
    page_addrs: []types.VirtAddr,
    entry_addr: types.VirtAddr,

    pub fn deinit(self: *LoadedExecutable) void {
        // FIXME: Add pages unmap once VMM supports unmapping.
        self.allocator.free(self.page_addrs);
        for (self.frames) |frame| self.pmm.freeFrame(frame);
        self.allocator.free(self.frames);
    }
};

const PageBitmapFlags = packed struct(u4) {
    map: u1,
    read: u1,
    write: u1,
    execute: u1,
};

pub fn load(pmm: *Pmm, vmm: *Vmm, allocator: std.mem.Allocator, exec_info: *const types.ExecutableInfo) Error!LoadedExecutable {
    // Restict alignment to be page-alignment, and the requested base_alignmet.
    // `config.page_size_bytes` and `exec_info.load_bias_alignment` must be a power-of-two.
    const exec_alignment = std.mem.Alignment.fromByteUnits(@max(exec_info.load_bias_alignment.toByteUnits(), config.page_size_bytes));

    var low_preferred_dest_begin: types.VirtAddr = std.math.maxInt(types.VirtAddr);
    var high_preferred_dest_end: types.VirtAddr = 0;
    for (exec_info.load_segments) |segment| {
        low_preferred_dest_begin = @min(low_preferred_dest_begin, segment.preferred_dest_begin);
        high_preferred_dest_end = @max(high_preferred_dest_end, segment.preferred_dest_end);
    }
    if (low_preferred_dest_begin >= high_preferred_dest_end)
        return Error.InvalidAddress;
    // const exec_span_bytes: usize = @intCast(high_preferred_dest_end - low_preferred_dest_begin);
    // if (exec_span_bytes > config.executable_arena_end - config.executable_arena_start)
    //     return Error.InvalidAddress;
    // const exec_base_max: types.VirtAddr = config.executable_arena_end - exec_span_bytes;

    const mapped_image_begin = std.mem.alignBackward(types.VirtAddr, low_preferred_dest_begin, config.page_size_bytes);
    const mapped_image_end = std.mem.alignForward(types.VirtAddr, high_preferred_dest_end, config.page_size_bytes);
    const image_span_bytes: usize = @intCast(mapped_image_end - mapped_image_begin);

    if (image_span_bytes > config.executable_arena_end - config.executable_arena_start)
        return Error.InvalidAddress;
    const exec_base_max: types.VirtAddr = config.executable_arena_end - image_span_bytes;

    if (config.executable_arena_start > std.math.maxInt(types.VirtAddr) - @as(types.VirtAddr, exec_alignment.toByteUnits() - 1))
        return Error.InvalidAddress;
    const low_aligned: types.VirtAddr = @intCast(exec_alignment.forward(@intCast(config.executable_arena_start)));
    const high_aligned: types.VirtAddr = @intCast(exec_alignment.backward(@intCast(exec_base_max)));

    if (low_aligned > high_aligned)
        return Error.InvalidAddress;
    const align_span_bytes = std.math.sub(usize, @intCast(high_aligned), @intCast(low_aligned)) catch
        return Error.InvalidAddress;
    const align_slot_count = align_span_bytes / exec_alignment.toByteUnits() + 1;
    const align_slot_index: usize = randomIntStub(0, align_slot_count);

    const exec_base = low_aligned + @as(types.VirtAddr, align_slot_index * exec_alignment.toByteUnits());

    // const max_page_count: usize = std.math.divCeil(usize, exec_span_bytes, config.page_size_bytes) catch
    //     unreachable;
    const max_page_count = image_span_bytes / config.page_size_bytes;
    var page_bitmap = allocator.alloc(PageBitmapFlags, max_page_count) catch
        return Error.OutOfMemory;
    defer allocator.free(page_bitmap);
    std.crypto.secureZero(PageBitmapFlags, page_bitmap);

    // const mapped_image_begin = std.mem.alignBackward(low_preferred_dest_begin, config.page_size_bytes);
    // const mapped_image_end = std.mem.alignForward(high_preferred_dest_end, config.page_size_bytes);
    for (exec_info.load_segments) |segment| {
        const normalized_begin = segment.preferred_dest_begin - mapped_image_begin;
        const normalized_end = segment.preferred_dest_end - mapped_image_begin;
        const normalized_begin_aligned = std.mem.alignBackward(types.VirtAddr, normalized_begin, config.page_size_bytes);
        const normalized_end_aligned = std.mem.alignForward(types.VirtAddr, normalized_end, config.page_size_bytes);
        const seg_page_count = (normalized_end_aligned - normalized_begin_aligned) / config.page_size_bytes;
        const first_page_index = normalized_begin_aligned / config.page_size_bytes;
        const seg_flags = PageBitmapFlags{ // FIXME: Set proper flags (after adding the same to the parser)
            .map = 1, // Must always be 1.
            .execute = 1,
            .read = 1,
            .write = 1,
        };
        const seg_flags_bits: u4 = @bitCast(seg_flags);

        for (0..seg_page_count) |offset| {
            const i = first_page_index + offset;
            const current_bits: u4 = @bitCast(page_bitmap[i]);
            const new_bits = current_bits | seg_flags_bits;
            page_bitmap[i] = @bitCast(new_bits);
        }
    }

    var allocated_frames: std.ArrayList(Pmm.PhysFrame) = .empty;
    var allocated_page_addrs: std.ArrayList(types.VirtAddr) = .empty;
    errdefer {
        // FIXME: Unmap the pages (currently not possible)
        allocated_page_addrs.clearAndFree(allocator);
        for (allocated_frames.items) |frame|
            pmm.freeFrame(frame);
        allocated_frames.clearAndFree(allocator);
    }

    for (page_bitmap, 0..) |flags, i| {
        if (flags.map == 0) continue;
        const page_addr = exec_base + @as(types.VirtAddr, i * config.page_size_bytes);
        const frame = pmm.allocateFrame() catch
            return Error.OutOfMemory;
        allocated_frames.append(allocator, frame) catch
            return Error.OutOfMemory;
        vmm.map(page_addr, frame.physBase(), .{}) catch |err| switch (err) {
            Vmm.Error.OutOfMemory => return Error.OutOfMemory,
            Vmm.Error.AlreadyMapped => @panic("can't load executable: already mapped"),
        };
        allocated_page_addrs.append(allocator, page_addr) catch
            return Error.OutOfMemory;
    }

    for (allocated_page_addrs.items) |addr| {
        const page_bytes_ptr: *[config.page_size_bytes]u8 = @ptrFromInt(addr);
        std.crypto.secureZero(u8, page_bytes_ptr);
    }

    for (exec_info.load_segments) |segment| {
        // const seg_base_addr = segment.preferred_dest_begin - low_preferred_dest_begin + exec_base;
        const seg_base_addr = segment.preferred_dest_begin - mapped_image_begin + exec_base;
        const dest_ptr: [*]u8 = @ptrFromInt(seg_base_addr);
        @memcpy(dest_ptr[0..segment.src.len], segment.src);
    }

    // FIXME: Fix the issue of confilicing errdefer upstream, and this one.
    const frames_slice = allocated_frames.toOwnedSlice(allocator) catch
        return Error.OutOfMemory;
    errdefer allocator.free(frames_slice);
    const page_addrs_slice = allocated_page_addrs.toOwnedSlice(allocator) catch
        return Error.OutOfMemory;
    errdefer allocator.free(page_addrs_slice);

    return LoadedExecutable{
        .pmm = pmm,
        .vmm = vmm,
        .allocator = allocator,
        .frames = frames_slice,
        .page_addrs = page_addrs_slice,
        // .entry_addr = exec_info.entry_addr + exec_base,
        .entry_addr = exec_info.entry_addr - mapped_image_begin + exec_base,
    };
}
