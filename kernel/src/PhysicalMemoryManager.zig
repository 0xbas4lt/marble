//!
//! Physical Memory Manager
//!
//! Caller must ensure, that after unlocking any frames, and before `.lockPmmFrames` is called,
//! no frames are handed out.
//!

const std = @import("std");

const BitSet = @import("BitSet.zig");
const types = @import("types.zig");

const PhysicalMemoryManager = @This();

/// PMM is completely responsible for tracking physical frames.
/// Should not be created, or modified outside the PMM.
pub const FrameSpan = struct {
    frame_count: usize,

    /// For internal PMM use.
    index: usize,
};

page_size: usize,
bit_set: BitSet,
backing_buf_span: FrameSpan,
are_backing_frames_locked: bool,

pub const AllocError = error{OutOfMemory};
pub const FreeError = error{ DoubleFree, UntrackedMemory };

/// Calculates the amount of consequtive usable physical frames, required by PhysicalMemoryManager to initialize.
/// `memory_end_phys` must be the last usable physical address + 1.
pub fn requiredBufferPageCount(memory_end_phys: types.PhysAddr, page_size: usize) usize {
    @branchHint(.cold);
    const masks_length = bitSetMasksLength(memory_end_phys, page_size);
    const masks_size = masks_length * @sizeOf(BitSet.MaskInt);
    const bit_set_framesize = std.math.divCeil(usize, masks_size, page_size) catch unreachable;
    return bit_set_framesize;
}

/// Calculates the amount of frames that the PhysicalMemoryManager will track.
fn trackedFrameCount(memory_end_phys: types.PhysAddr, page_size: usize) usize {
    @branchHint(.cold);
    const mem_top_align = std.mem.alignForward(types.PhysAddr, memory_end_phys, @intCast(page_size));
    const frame_count = mem_top_align / page_size;
    return frame_count;
}

/// Calculates the length of the BitSet mask slice.
fn bitSetMasksLength(memory_end_phys: types.PhysAddr, page_size: usize) usize {
    @branchHint(.cold);
    const bit_set_length = trackedFrameCount(memory_end_phys, page_size);
    const masks_length = std.math.divCeil(usize, bit_set_length, @bitSizeOf(BitSet.MaskInt)) catch unreachable;
    return masks_length;
}

/// Initializes and creates a PhysicalMemoryManager instance.
/// `memory_end_phys` must be the last usable physical address + 1.
/// `buffer` must have a size of at least `requiredPageCount` * page size,
/// be page-aligned, and point to a usable memory region, for Physical Memory Manager to use
/// for it's internal structures.
/// `buffer` will be treated as memory, reserved by the PhysicalMemoryManager.
pub fn init(
    page_size: usize,
    memory_end_phys: types.PhysAddr,
    hhdm_offset: types.VirtAddr,
    buffer: []u8,
) PhysicalMemoryManager {
    @branchHint(.cold);

    const bit_set_framesize = requiredBufferPageCount(memory_end_phys, page_size);
    std.debug.assert(buffer.len >= bit_set_framesize * page_size);

    const buffer_physbase = @as(types.PhysAddr, @intFromPtr(buffer.ptr)) - hhdm_offset;
    std.debug.assert(buffer_physbase % page_size == 0);
    const buffer_base_index = buffer_physbase / page_size;

    const bit_set_length = trackedFrameCount(memory_end_phys, page_size);
    const bit_set_masks_length = bitSetMasksLength(memory_end_phys, page_size);
    // SAFETY: alignment BitSet.MaskInt must be congurent with page_size.
    const bit_set_masks: []BitSet.MaskInt = @as([*]BitSet.MaskInt, @ptrCast(@alignCast(buffer)))[0..bit_set_masks_length];

    // As specified by `BitSet.masks`, padding bits are assumed to be 0.
    @memset(bit_set_masks, 0);
    var bit_set: BitSet = .fromRaw(bit_set_masks, bit_set_length);
    // Set everything as allocated by default.
    // PMM's own frames are also locked.
    bit_set.setRangeValue(.{ .start = 0, .end = bit_set_length }, true);

    return PhysicalMemoryManager{
        .bit_set = bit_set,
        .page_size = page_size,
        .backing_buf_span = .{
            .index = buffer_base_index,
            .frame_count = bit_set_framesize,
        },
        .are_backing_frames_locked = true,
    };
}

/// Doesn't free anything, but invalidates all further allocation, and freeing calls.
pub fn deinit(self: *PhysicalMemoryManager) void {
    @branchHint(.cold);
    self.page_size = 0;
    self.bit_set.bit_length = 0;
    self.bit_set.masks = &.{};
    self.backing_buf_span.frame_count = 0;
    self.backing_buf_span.index = 0;
}

/// Sets PMM's own frames as allocated. If `.unlockMemoryRegion` was called,
/// this must be called before handing out any frames.
pub fn lockPmmFrames(self: *PhysicalMemoryManager) void {
    @branchHint(.cold);
    self.are_backing_frames_locked = true;
    self.bit_set.setRangeValue(.{
        .start = self.backing_buf_span.index,
        .end = self.backing_buf_span.index + self.backing_buf_span.frame_count,
    }, true);
}

/// Sets frames that are fully included in the memory region,
/// defined by (`physbase` to `physbase` + `size`) as `freed`.
/// Does not error on double free.
/// May return `error.UntrackedMemory`.
pub fn unlockMemoryRegion(self: *PhysicalMemoryManager, physbase: types.PhysAddr, size: usize) !void {
    @branchHint(.cold);
    std.debug.assert(size > 0);
    self.are_backing_frames_locked = false;
    if (size < self.page_size)
        return;

    const base_align = std.mem.alignForward(types.PhysAddr, physbase, @intCast(self.page_size));
    const end_align = std.mem.alignBackward(usize, physbase + size, self.page_size);
    const base_index = base_align / self.page_size;
    const end_index = end_align / self.page_size; // Last frame + 1

    if (end_index <= base_index) return;

    if (end_index > self.bit_set.bit_length)
        return error.UntrackedMemory;

    self.bit_set.setRangeValue(.{ .start = base_index, .end = end_index }, false);
}

/// Sets frames that are at least partially included in the memory region,
/// defined by (`physbase` to `physbase` + `size`) as `allocated`.
/// Untracked part of the memory region is ignored.
pub fn lockMemoryRegion(self: *PhysicalMemoryManager, physbase: types.PhysAddr, size: usize) !void {
    @branchHint(.cold);
    std.debug.assert(size > 0);
    const base_align = std.mem.alignBackward(types.PhysAddr, physbase, @intCast(self.page_size));
    const end_align = std.mem.alignForward(usize, physbase + size, self.page_size);
    const base_index = base_align / self.page_size;
    const end_index_unclamped = end_align / self.page_size; // Last frame + 1
    const end_index =
        if (end_index_unclamped > self.bit_set.bit_length) self.bit_set.bit_length else end_index_unclamped;

    if (end_index <= base_index) return;

    self.bit_set.setRangeValue(.{ .start = base_index, .end = end_index }, true);
}

/// Allocates a `FrameSpan` of `frame_count` frames.
/// May return `Error.OutOfMemory`.
/// `frame_count` must be larger than 0.
/// SAFETY: Not an atomic operation.
pub fn allocate(self: *PhysicalMemoryManager, frame_count: usize) AllocError!FrameSpan {
    @branchHint(.likely);
    std.debug.assert(self.are_backing_frames_locked);
    std.debug.assert(frame_count > 0);
    const bit_range = self.bit_set.findFirstUnsetRange(frame_count) orelse
        return AllocError.OutOfMemory;
    self.bit_set.setRangeValue(bit_range, true);
    return FrameSpan{
        .index = bit_range.start,
        .frame_count = frame_count,
    };
}

/// Frees a `FrameSpan`. May panic on double-free,
/// SAFETY: Not an atomic operation.
/// FIXME: Add double-free check, once BitSet supports it.
pub fn free(self: *PhysicalMemoryManager, span: FrameSpan) FreeError!void {
    @branchHint(.likely);
    const end = span.index + span.frame_count; // last frame + 1
    if (end > self.bit_set.bit_length)
        return FreeError.UntrackedMemory;
    self.bit_set.setRangeValue(.{
        .start = span.index,
        .end = end,
    }, false);
}

pub fn frameSpanPhysbase(self: *const PhysicalMemoryManager, frame_span: FrameSpan) types.PhysAddr {
    return frame_span.index * self.page_size;
}

/// --------------------------------------------------------------------
/// AI-generated tests
/// --------------------------------------------------------------------
const testing = std.testing;

const test_page_size = 4096;
const test_frame_count = 256;
const test_mem_end: types.PhysAddr = test_frame_count * test_page_size;
/// The backing buffer is pretended to live at physical frame 1.
const test_backing_index = 1;

var test_buf: [test_page_size]u8 align(test_page_size) = undefined;

/// Fresh PMM. Every frame is locked, as `init` leaves it.
fn initTestPmm() PhysicalMemoryManager {
    // phys = virt - hhdm_offset, so this puts `test_buf` at physical frame 1.
    const hhdm_offset: types.VirtAddr = @intFromPtr(&test_buf) - test_backing_index * test_page_size;
    return init(test_page_size, test_mem_end, hhdm_offset, &test_buf);
}

/// PMM with all memory unlocked, except its own backing frames.
fn initFreeTestPmm() !PhysicalMemoryManager {
    var pmm = initTestPmm();
    try pmm.unlockMemoryRegion(0, test_mem_end);
    pmm.lockPmmFrames();
    return pmm;
}

/// Asserts that every frame in [start, end) has the given state.
fn expectRange(pmm: *const PhysicalMemoryManager, start: usize, end: usize, is_set: bool) !void {
    var i = start;
    while (i < end) : (i += 1) {
        testing.expectEqual(is_set, pmm.bit_set.get(i)) catch |err| {
            std.debug.print("frame {d}: expected set={}\n", .{ i, is_set });
            return err;
        };
    }
}

// --- helpers ---------------------------------------------------------------

test "trackedFrameCount treats the end as exclusive" {
    try testing.expectEqual(0, trackedFrameCount(0, 4096));
    try testing.expectEqual(1, trackedFrameCount(1, 4096));
    try testing.expectEqual(1, trackedFrameCount(0xFFF, 4096));
    try testing.expectEqual(1, trackedFrameCount(0x1000, 4096)); // bytes 0x0..0xFFF only
    try testing.expectEqual(2, trackedFrameCount(0x1001, 4096));
    try testing.expectEqual(3, trackedFrameCount(0x3000, 4096));
    try testing.expectEqual(4, trackedFrameCount(0x3001, 4096));
}

test "bitSetMasksLength rounds up at mask boundaries" {
    const bits = @bitSizeOf(BitSet.MaskInt);
    try testing.expectEqual(0, bitSetMasksLength(0, 4096));
    try testing.expectEqual(1, bitSetMasksLength(1, 4096));
    try testing.expectEqual(1, bitSetMasksLength(bits * 4096, 4096)); // exactly one full mask
    try testing.expectEqual(2, bitSetMasksLength(bits * 4096 + 1, 4096)); // one frame over
}

test "requiredBufferPageCount rounds up at page boundaries" {
    const frames_per_buf_page = test_page_size * 8; // one page of bits
    try testing.expectEqual(0, requiredBufferPageCount(0, 4096));
    try testing.expectEqual(1, requiredBufferPageCount(1, 4096));
    try testing.expectEqual(1, requiredBufferPageCount(test_mem_end, 4096));
    try testing.expectEqual(1, requiredBufferPageCount(frames_per_buf_page * 4096, 4096)); // bitmap fills exactly one page
    try testing.expectEqual(2, requiredBufferPageCount(frames_per_buf_page * 4096 + 1, 4096)); // one more frame spills over
}

// --- init / deinit -----------------------------------------------------------

test "init locks every frame and records the backing span" {
    const pmm = initTestPmm();
    try testing.expectEqual(test_page_size, pmm.page_size);
    try testing.expectEqual(test_frame_count, pmm.bit_set.bit_length);
    try testing.expectEqual(test_backing_index, pmm.backing_buf_span.index);
    try testing.expectEqual(1, pmm.backing_buf_span.frame_count);
    try testing.expect(pmm.are_backing_frames_locked);
    try expectRange(&pmm, 0, test_frame_count, true);
}

test "deinit invalidates the instance" {
    var pmm = initTestPmm();
    pmm.deinit();
    try testing.expectEqual(0, pmm.page_size);
    try testing.expectEqual(0, pmm.bit_set.bit_length);
    try testing.expectEqual(0, pmm.backing_buf_span.index);
    try testing.expectEqual(0, pmm.backing_buf_span.frame_count);
}

// --- unlockMemoryRegion ------------------------------------------------------

test "unlockMemoryRegion frees only fully covered frames" {
    var pmm = initTestPmm();
    // [0x2800, 0x5800) fully covers frames 3 and 4. Frames 2 and 5 are only partly inside.
    try pmm.unlockMemoryRegion(0x2800, 0x3000);
    try expectRange(&pmm, 0, 3, true);
    try expectRange(&pmm, 3, 5, false);
    try expectRange(&pmm, 5, test_frame_count, true);
}

test "unlockMemoryRegion frees an aligned single frame" {
    var pmm = initTestPmm();
    try pmm.unlockMemoryRegion(4 * test_page_size, test_page_size);
    try expectRange(&pmm, 0, 4, true);
    try expectRange(&pmm, 4, 5, false);
    try expectRange(&pmm, 5, test_frame_count, true);
}

test "unlockMemoryRegion ignores regions that cover no full frame" {
    var pmm = initTestPmm();
    // Smaller than a page.
    try pmm.unlockMemoryRegion(0x4000, 0x800);
    // At least a page long, but straddles a boundary without covering a whole frame.
    try pmm.unlockMemoryRegion(0x4800, 0x1000);
    try expectRange(&pmm, 0, test_frame_count, true);
}

test "unlockMemoryRegion handles a region ending exactly at the tracked end" {
    var pmm = initTestPmm();
    try pmm.unlockMemoryRegion((test_frame_count - 1) * test_page_size, test_page_size);
    try expectRange(&pmm, 0, test_frame_count - 1, true);
    try expectRange(&pmm, test_frame_count - 1, test_frame_count, false);
}

test "unlockMemoryRegion rejects regions past the tracked end" {
    var pmm = initTestPmm();
    try testing.expectError(
        error.UntrackedMemory,
        pmm.unlockMemoryRegion((test_frame_count - 1) * test_page_size, 2 * test_page_size),
    );
    try expectRange(&pmm, 0, test_frame_count, true);
}

test "unlockMemoryRegion clears the backing-frames-locked flag" {
    var pmm = initTestPmm();
    try testing.expect(pmm.are_backing_frames_locked);
    try pmm.unlockMemoryRegion(0x4000, test_page_size);
    try testing.expect(!pmm.are_backing_frames_locked);
}

// --- lockPmmFrames / lockMemoryRegion -----------------------------------------

test "lockPmmFrames re-locks only the backing frames" {
    var pmm = initTestPmm();
    try pmm.unlockMemoryRegion(0, test_mem_end);
    try expectRange(&pmm, 0, test_frame_count, false);
    try testing.expect(!pmm.are_backing_frames_locked);

    pmm.lockPmmFrames();
    try testing.expect(pmm.are_backing_frames_locked);
    try expectRange(&pmm, 0, test_backing_index, false);
    try expectRange(&pmm, test_backing_index, test_backing_index + 1, true);
    try expectRange(&pmm, test_backing_index + 1, test_frame_count, false);
}

test "lockMemoryRegion locks partially covered frames" {
    var pmm = try initFreeTestPmm();
    // [0x4800, 0x5800) touches frames 4 and 5.
    try pmm.lockMemoryRegion(0x4800, 0x1000);
    try expectRange(&pmm, 2, 4, false);
    try expectRange(&pmm, 4, 6, true);
    try expectRange(&pmm, 6, test_frame_count, false);
}

test "lockMemoryRegion locks an aligned single frame and nothing more" {
    var pmm = try initFreeTestPmm();
    try pmm.lockMemoryRegion(10 * test_page_size, test_page_size);
    try expectRange(&pmm, 9, 10, false);
    try expectRange(&pmm, 10, 11, true);
    try expectRange(&pmm, 11, 12, false);
}

test "lockMemoryRegion clamps a region that runs past the tracked end" {
    var pmm = try initFreeTestPmm();
    try pmm.lockMemoryRegion((test_frame_count - 1) * test_page_size, 4 * test_page_size);
    try expectRange(&pmm, test_frame_count - 2, test_frame_count - 1, false);
    try expectRange(&pmm, test_frame_count - 1, test_frame_count, true);
}

test "lockMemoryRegion ignores regions entirely outside the tracked range" {
    var pmm = try initFreeTestPmm();
    try pmm.lockMemoryRegion(test_mem_end + test_page_size, test_page_size);
    try expectRange(&pmm, 2, test_frame_count, false);
}

// --- allocate / free ---------------------------------------------------------

test "allocate fails when everything is locked" {
    var pmm = initTestPmm();
    try testing.expectError(error.OutOfMemory, pmm.allocate(1));
}

test "allocate returns the lowest free span and marks it allocated" {
    var pmm = try initFreeTestPmm();

    // Frame 0 is free, frame 1 is the PMM's own.
    const a = try pmm.allocate(1);
    try testing.expectEqual(0, a.index);
    try testing.expectEqual(1, a.frame_count);
    try expectRange(&pmm, 0, 1, true);

    // Two consecutive frames can't fit before the locked frame 1, so this starts at 2.
    const b = try pmm.allocate(2);
    try testing.expectEqual(2, b.index);
    try testing.expectEqual(2, b.frame_count);
    try expectRange(&pmm, 2, 4, true);
    try expectRange(&pmm, 4, test_frame_count, false);
}

test "allocate fails when no span is large enough" {
    var pmm = try initFreeTestPmm();
    // Frame 1 is locked, so a span of every frame can never exist.
    try testing.expectError(error.OutOfMemory, pmm.allocate(test_frame_count));
    // A span of every frame after frame 1 does fit.
    const span = try pmm.allocate(test_frame_count - 2);
    try testing.expectEqual(2, span.index);
}

test "allocate can use the very last frame" {
    var pmm = try initFreeTestPmm();
    _ = try pmm.allocate(1); // frame 0
    const big = try pmm.allocate(test_frame_count - 3); // frames 2..=254
    try testing.expectEqual(2, big.index);
    const last = try pmm.allocate(1); // frame 255 is the only one left
    try testing.expectEqual(test_frame_count - 1, last.index);
    try expectRange(&pmm, 0, test_frame_count, true);
    try testing.expectError(error.OutOfMemory, pmm.allocate(1));
}

test "free releases a span and it can be allocated again" {
    var pmm = try initFreeTestPmm();
    const span = try pmm.allocate(3);
    try expectRange(&pmm, span.index, span.index + span.frame_count, true);

    try pmm.free(span);
    try expectRange(&pmm, span.index, span.index + span.frame_count, false);

    const again = try pmm.allocate(3);
    try testing.expectEqual(span.index, again.index);
}

test "free only touches its own span" {
    var pmm = try initFreeTestPmm();
    const a = try pmm.allocate(2);
    const b = try pmm.allocate(2);
    try pmm.free(a);
    try expectRange(&pmm, a.index, a.index + a.frame_count, false);
    try expectRange(&pmm, b.index, b.index + b.frame_count, true);
}

test "free accepts a span ending exactly at the tracked end" {
    var pmm = try initFreeTestPmm();
    try pmm.lockMemoryRegion((test_frame_count - 2) * test_page_size, 2 * test_page_size);
    try pmm.free(.{ .index = test_frame_count - 2, .frame_count = 2 });
    try expectRange(&pmm, test_frame_count - 2, test_frame_count, false);
}

test "free rejects spans past the tracked end" {
    var pmm = try initFreeTestPmm();
    try testing.expectError(
        error.UntrackedMemory,
        pmm.free(.{ .index = test_frame_count - 1, .frame_count = 2 }),
    );
    try testing.expectError(
        error.UntrackedMemory,
        pmm.free(.{ .index = test_frame_count, .frame_count = 1 }),
    );
}
