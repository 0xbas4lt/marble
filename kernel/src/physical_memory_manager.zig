//! Physical memory manager.
const std = @import("std");
const limine = @import("limine.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const serial = @import("serial.zig");

/// '1' marks used, '0' marks unused.
var bitmap: []u64 = undefined;
var frame_count: usize = undefined;

var hhdm_offset: types.PhysAddr = undefined;
var kernel_physical_base: types.PhysAddr = undefined;

pub const Error = error{
    OutOfMemory,
};

/// Returns the tracked frame count. Last frame might reach outside the usable memory range.
pub inline fn frameCount() usize {
    return frame_count;
}

inline fn setBit(index: usize) void {
    bitmap[index / 64] |= @as(u64, 1) << @truncate(index % 64);
}

inline fn clearBit(index: usize) void {
    bitmap[index / 64] &= ~(@as(u64, 1) << @truncate(index % 64));
}

inline fn testBit(index: usize) bool {
    return (bitmap[index / 64] >> @truncate(index % 64)) & @as(u64, 1) == 1;
}

pub fn kernelPhysBase() types.PhysAddr {
    return kernel_physical_base;
}

pub inline fn hhdmOffset() types.PhysAddr {
    return hhdm_offset;
}

pub const PhysFrame = struct {
    index: usize,

    /// NOTE: This calculates the virtual address using the higher half direct mapping offset.
    /// This means that this is not usable during remapping of the kernel to the address expected by the linker script.
    pub inline fn virtBase(self: *const PhysFrame) types.VirtAddr {
        return self.physBase() + hhdmOffset();
    }

    pub inline fn physBase(self: *const PhysFrame) types.PhysAddr {
        return self.index * config.page_size_bytes;
    }

    pub inline fn fromPhysBase(addr: types.PhysAddr) PhysFrame {
        return .{ .index = std.mem.alignBackward(types.PhysAddr, addr, config.page_size_bytes) / config.page_size_bytes };
    }
};

pub fn init(
    hhdm_off: types.PhysAddr,
    limine_memmap_resp: *const limine.MemmapResponse,
    kernel_phys_base: types.PhysAddr,
) void {
    hhdm_offset = hhdm_off;
    kernel_physical_base = kernel_phys_base;

    var top: u64 = 0;
    for (limine_memmap_resp.entries()) |entry| {
        if (entry.type != @intFromEnum(limine.MemmapType.usable) and entry.type != @intFromEnum(limine.MemmapType.bootloader_reclaimable)) continue;
        top = @max(top, entry.base + entry.length);
    }
    frame_count = std.math.divCeil(usize, top, config.page_size_bytes) catch unreachable;

    const bitmap_length = std.math.divCeil(usize, frame_count, 64) catch unreachable;
    const bitmap_size_bytes = bitmap_length * 8;
    const bitmap_size_frames = std.math.divCeil(usize, bitmap_size_bytes, config.page_size_bytes) catch unreachable;

    var bitmap_base_phys: u64 = 0; // Guaranteed to be aligned to config.frame_size_bytes
    var best_fit_entry_length: u64 = std.math.maxInt(u64);
    var found_fit = false;
    for (limine_memmap_resp.entries()) |entry| {
        if (entry.type != @intFromEnum(limine.MemmapType.usable)) continue;

        const aligned_base = std.mem.alignForward(u64, entry.base, config.page_size_bytes);
        const new_length = entry.length + entry.base - aligned_base;
        if (new_length < config.page_size_bytes) continue;
        const aligned_length = std.mem.alignBackward(u64, new_length, config.page_size_bytes);

        if (aligned_length >= bitmap_size_bytes and aligned_length < best_fit_entry_length) {
            found_fit = true;
            best_fit_entry_length = aligned_length;
            bitmap_base_phys = aligned_base;
        }
    }
    if (!found_fit) @panic("no memory left for physical memory manager");

    bitmap = @as([*]u64, @ptrFromInt(bitmap_base_phys + @as(u64, hhdm_off)))[0..bitmap_length];
    @memset(bitmap, std.math.maxInt(u64));

    for (limine_memmap_resp.entries()) |entry| {
        if (entry.type != @intFromEnum(limine.MemmapType.usable)) continue;

        const aligned_base = std.mem.alignForward(u64, entry.base, config.page_size_bytes);
        const new_length = entry.length + entry.base - aligned_base;
        if (new_length < config.page_size_bytes) continue;
        const aligned_length = std.mem.alignBackward(u64, new_length, config.page_size_bytes);

        const base_index = aligned_base / config.page_size_bytes;
        const length_frames = aligned_length / config.page_size_bytes;
        for (0..length_frames) |i| clearBit(base_index + i);
    }

    const bitmap_base_index = bitmap_base_phys / config.page_size_bytes;
    for (0..bitmap_size_frames) |i| setBit(bitmap_base_index + i);

    const kernel_base_index = kernel_physical_base / config.page_size_bytes;
    for (0..config.kernelSizePages()) |i| setBit(kernel_base_index + i);
}

pub fn allocateFrame() Error!PhysFrame {
    for (0.., bitmap) |word_index, word| {
        if (word == std.math.maxInt(u64)) continue;
        const index = word_index * 64 + @ctz(~word);
        setBit(index);
        return PhysFrame{ .index = index };
    }
    return Error.OutOfMemory;
}

pub fn freeFrame(frame: PhysFrame) void {
    if (frame.index >= frame_count) @panic("out of range physical memory freeing attempt has occured");
    if (!testBit(frame.index)) @panic("double free of a physical memory frame has occured");
    clearBit(frame.index);
    return;
}

/// Mark the provided frame as `allocated`.
pub fn lockFrame(frame: PhysFrame) void {
    setBit(frame.index);
    return;
}
