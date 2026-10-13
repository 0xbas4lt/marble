//! Physical memory manager.
const std = @import("std");
const limine = @import("limine.zig");
const types = @import("types.zig");
const config = @import("config.zig");
const serial = @import("serial.zig");

const Pmm = @This();

/// '1' marks used, '0' marks unused.
bitmap: []u64 = undefined,
frame_count: usize = undefined,
hhdm_offset: types.PhysAddr = undefined,
kernel_physical_base: types.PhysAddr = undefined,

pub const Error = error{
    OutOfMemory,
};

/// Returns the tracked frame count. Last frame might reach outside the usable memory range.
pub inline fn frameCount(self: *Pmm) usize {
    return self.frame_count;
}

inline fn setBit(self: *Pmm, index: usize) void {
    self.bitmap[index / 64] |= @as(u64, 1) << @truncate(index % 64);
}

inline fn clearBit(self: *Pmm, index: usize) void {
    self.bitmap[index / 64] &= ~(@as(u64, 1) << @truncate(index % 64));
}

inline fn testBit(self: *Pmm, index: usize) bool {
    return (self.bitmap[index / 64] >> @truncate(index % 64)) & @as(u64, 1) == 1;
}

pub fn kernelPhysBase(self: *Pmm) types.PhysAddr {
    return self.kernel_physical_base;
}

pub inline fn hhdmOffset(self: *Pmm) types.PhysAddr {
    return self.hhdm_offset;
}

pub const PhysFrame = struct {
    index: usize,
    pmm: *Pmm,

    /// NOTE: This calculates the virtual address using the higher half direct mapping offset.
    /// This means that this is not usable during remapping of the kernel to the address expected by the linker script.
    pub inline fn virtBase(self: *const PhysFrame) types.VirtAddr {
        return self.physBase() + self.pmm.hhdmOffset();
    }

    pub inline fn physBase(self: *const PhysFrame) types.PhysAddr {
        return self.index * config.page_size_bytes;
    }
};

pub fn frameFromPhysBase(self: *Pmm, addr: types.PhysAddr) PhysFrame {
    return .{
        .pmm = self,
        .index = std.mem.alignBackward(types.PhysAddr, addr, config.page_size_bytes) / config.page_size_bytes,
    };
}

pub fn init(
    hhdm_offset: types.PhysAddr,
    limine_memmap_resp: *const limine.MemmapResponse,
    kernel_physical_base: types.PhysAddr,
) Pmm {
    // hhdm_offset = hhdm_off;
    // kernel_physical_base = kernel_phys_base;
    var pmm_instance = Pmm{
        .hhdm_offset = hhdm_offset,
        .kernel_physical_base = kernel_physical_base,
        .bitmap = undefined,
        .frame_count = undefined,
    };

    var top: u64 = 0;
    for (limine_memmap_resp.entries()) |entry| {
        if (entry.type != @intFromEnum(limine.MemmapType.usable) and entry.type != @intFromEnum(limine.MemmapType.bootloader_reclaimable)) continue;
        top = @max(top, entry.base + entry.length);
    }
    pmm_instance.frame_count = std.math.divCeil(usize, top, config.page_size_bytes) catch unreachable;

    const bitmap_length = std.math.divCeil(usize, pmm_instance.frame_count, 64) catch unreachable;
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

    pmm_instance.bitmap = @as([*]u64, @ptrFromInt(bitmap_base_phys + @as(u64, hhdm_offset)))[0..bitmap_length];
    @memset(pmm_instance.bitmap, std.math.maxInt(u64));

    for (limine_memmap_resp.entries()) |entry| {
        if (entry.type != @intFromEnum(limine.MemmapType.usable)) continue;

        const aligned_base = std.mem.alignForward(u64, entry.base, config.page_size_bytes);
        const new_length = entry.length + entry.base - aligned_base;
        if (new_length < config.page_size_bytes) continue;
        const aligned_length = std.mem.alignBackward(u64, new_length, config.page_size_bytes);

        const base_index = aligned_base / config.page_size_bytes;
        const length_frames = aligned_length / config.page_size_bytes;
        for (0..length_frames) |i| pmm_instance.clearBit(base_index + i);
    }

    const bitmap_base_index = bitmap_base_phys / config.page_size_bytes;
    for (0..bitmap_size_frames) |i| pmm_instance.setBit(bitmap_base_index + i);

    const kernel_base_index = kernel_physical_base / config.page_size_bytes;
    for (0..config.kernelSizePages()) |i| pmm_instance.setBit(kernel_base_index + i);

    return pmm_instance;
}

pub fn allocateFrame(self: *Pmm) Error!PhysFrame {
    for (0.., self.bitmap) |word_index, word| {
        if (word == std.math.maxInt(u64)) continue;
        const index = word_index * 64 + @ctz(~word);
        self.setBit(index);
        return PhysFrame{ .pmm = self, .index = index };
    }
    return Error.OutOfMemory;
}

pub fn freeFrame(self: *Pmm, frame: PhysFrame) void {
    if (frame.index >= self.frame_count) @panic("out of range physical memory freeing attempt has occured");
    if (!self.testBit(frame.index)) @panic("double free of a physical memory frame has occured");
    self.clearBit(frame.index);
    return;
}

/// Mark the provided frame as `allocated`.
pub fn lockFrame(self: *Pmm, frame: PhysFrame) void {
    self.setBit(frame.index);
    return;
}
