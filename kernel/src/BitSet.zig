const std = @import("std");

/// Padding bits at the end are assumed to be 0.
masks: []MaskInt,
bit_length: usize,

const BitSet = @This();

pub const MaskInt = usize;
pub const ShiftInt = std.math.Log2Int(MaskInt);

pub const Range = struct {
    /// The index of the first bit of interest.
    start: usize,
    /// The index immediately after the last bit of interest.
    end: usize,
};

/// NOTE: masks.len * @bitSizeOf(MaskInt) > usize is **undefined behaviour**.
/// NOTE: Padding bits are assumed to be 0.
pub fn fromRaw(masks: []MaskInt, bit_length: usize) BitSet {
    const masks_bit_length = masks.len * @bitSizeOf(MaskInt);
    std.debug.assert(bit_length <= masks_bit_length);
    return .{ .masks = masks, .bit_length = bit_length };
}

/// Sets the specified bit to `1`.
pub fn set(self: *BitSet, index: usize) void {
    std.debug.assert(index < self.bit_length);
    self.masks[maskIndex(index)] |= maskBit(index);
}

/// Sets the specified bit to `0`.
pub fn unset(self: *BitSet, index: usize) void {
    std.debug.assert(index < self.bit_length);
    self.masks[maskIndex(index)] &= ~maskBit(index);
}

/// Returns `true` if the bit by `index` is set, otherwise returns 0.
pub fn get(self: *const BitSet, index: usize) bool {
    std.debug.assert(index < self.bit_length);
    return (self.masks[maskIndex(index)] & maskBit(index)) != 0;
}

/// Finds the index of the first unset bit.
pub fn findFirstUnset(self: *const BitSet) ?usize {
    var bit_offset_aligned: usize = 0;
    const mask = for (self.masks) |mask| {
        if (mask != std.math.maxInt(MaskInt))
            break mask;
        bit_offset_aligned += @bitSizeOf(MaskInt);
    } else return null;

    const result_offset = bit_offset_aligned + @ctz(~mask);
    if (result_offset >= self.bit_length)
        return null;
    return result_offset;
}

/// Finds the index of the first unset bit at or after `index`. Returns `null` if none is found.
pub fn findFirstUnsetFrom(self: *const BitSet, index: usize) ?usize {
    std.debug.assert(index < self.bit_length);

    const bits = @bitSizeOf(MaskInt);

    var word: usize = index / bits;
    const start_bit: ShiftInt = @intCast(index % bits);

    var free: MaskInt = ~self.masks[word] & (~@as(MaskInt, 0) << start_bit);

    while (true) {
        if (free != 0) {
            const result = word * bits + @ctz(free);
            return if (result < self.bit_length) result else null;
        }
        word += 1;
        if (word >= self.masks.len) return null;
        free = ~self.masks[word];
    }
}

/// Finds the index of the first set bit at or after `index`. Returns `null` if none is found.
pub fn findFirstSetFrom(self: *const BitSet, index: usize) ?usize {
    std.debug.assert(index < self.bit_length);

    const bits = @bitSizeOf(MaskInt);

    var word: usize = index / bits;
    const start_bit: ShiftInt = @intCast(index % bits);

    var candidates: MaskInt = self.masks[word] & (~@as(MaskInt, 0) << start_bit);

    while (true) {
        if (candidates != 0) {
            const result = word * bits + @ctz(candidates);
            return if (result < self.bit_length) result else null;
        }
        word += 1;
        if (word >= self.masks.len) return null;
        candidates = self.masks[word];
    }
}

/// Finds the first index of the first bit of a continuous unset bit range of at least `length` count.
/// If no such range is found, `null` is returned.
pub fn findFirstUnsetRange(self: *const BitSet, length: usize) ?Range {
    std.debug.assert(length != 0);
    if (length > self.bit_length) return null;
    var last_range_end: usize = 0;
    while (last_range_end < self.bit_length) {
        const range_start = self.findFirstUnsetFrom(last_range_end) orelse return null;
        last_range_end = self.findFirstSetFrom(range_start) orelse self.bit_length;
        const range_length = last_range_end - range_start;
        if (range_length >= length) return Range{
            .start = range_start,
            .end = range_start + length,
        };
    }
    return null;
}

/// Changes the value of all bits in the specified range to
/// match the passed boolean.
pub fn setRangeValue(self: *BitSet, range: Range, value: bool) void {
    std.debug.assert(range.end <= self.bit_length);
    std.debug.assert(range.start <= range.end);
    if (range.start == range.end) return;

    const start_mask_index = maskIndex(range.start);
    const start_bit = @as(ShiftInt, @truncate(range.start));

    const end_mask_index = maskIndex(range.end);
    const end_bit = @as(ShiftInt, @truncate(range.end));

    if (start_mask_index == end_mask_index) {
        var mask1 = std.math.boolMask(MaskInt, true) << start_bit;
        var mask2 = std.math.boolMask(MaskInt, true) >> (@bitSizeOf(MaskInt) - 1) - (end_bit - 1);
        self.masks[start_mask_index] &= ~(mask1 & mask2);

        mask1 = std.math.boolMask(MaskInt, value) << start_bit;
        mask2 = std.math.boolMask(MaskInt, value) >> (@bitSizeOf(MaskInt) - 1) - (end_bit - 1);
        self.masks[start_mask_index] |= mask1 & mask2;
    } else {
        var bulk_mask_index: usize = undefined;
        if (start_bit > 0) {
            self.masks[start_mask_index] =
                (self.masks[start_mask_index] & ~(std.math.boolMask(MaskInt, true) << start_bit)) |
                (std.math.boolMask(MaskInt, value) << start_bit);
            bulk_mask_index = start_mask_index + 1;
        } else {
            bulk_mask_index = start_mask_index;
        }

        while (bulk_mask_index < end_mask_index) : (bulk_mask_index += 1) {
            self.masks[bulk_mask_index] = std.math.boolMask(MaskInt, value);
        }

        if (end_bit > 0) {
            self.masks[end_mask_index] =
                (self.masks[end_mask_index] & (std.math.boolMask(MaskInt, true) << end_bit)) |
                (std.math.boolMask(MaskInt, value) >> ((@bitSizeOf(MaskInt) - 1) - (end_bit - 1)));
        }
    }
}

inline fn maskBit(index: usize) MaskInt {
    return @as(MaskInt, 1) << @as(ShiftInt, @truncate(index));
}

inline fn maskIndex(index: usize) usize {
    return index >> @bitSizeOf(ShiftInt);
}

/// --------------------------------------------------------------------
/// AI-generated tests
/// --------------------------------------------------------------------
const testing = std.testing;

const mask_bits = @bitSizeOf(MaskInt);

/// Backing storage for test bit sets. 8 masks hold at least 256 bits,
/// which is more than any test length below needs.
const test_mask_count = 8;
const max_test_bits = test_mask_count * mask_bits;

/// Creates a cleared bit set that uses the fewest masks possible,
/// so the last mask has padding bits whenever `bit_length` isn't a multiple of `mask_bits`.
fn initTest(masks: *[test_mask_count]MaskInt, bit_length: usize) BitSet {
    const used = (bit_length + mask_bits - 1) / mask_bits;
    @memset(masks, 0);
    return BitSet.fromRaw(masks[0..used], bit_length);
}

/// Sets bits [start, end) one at a time, so it doesn't depend on `setRangeValue`.
fn setBits(bs: *BitSet, start: usize, end: usize) void {
    for (start..end) |i| bs.set(i);
}

/// Asserts that every bit matches `model`, and that the padding bits are still 0.
fn expectMatches(bs: *const BitSet, model: []const bool) !void {
    try testing.expectEqual(model.len, bs.bit_length);
    for (model, 0..) |expected, i| {
        testing.expectEqual(expected, bs.get(i)) catch |err| {
            std.debug.print("bit {d}: expected {}\n", .{ i, expected });
            return err;
        };
    }
    var i = bs.bit_length;
    while (i < bs.masks.len * mask_bits) : (i += 1) {
        const padding_bit = (bs.masks[i / mask_bits] >> @as(ShiftInt, @intCast(i % mask_bits))) & 1;
        testing.expectEqual(0, padding_bit) catch |err| {
            std.debug.print("padding bit {d} was modified\n", .{i});
            return err;
        };
    }
}

fn expectRange(expected: ?Range, actual: ?Range) !void {
    try testing.expectEqual(expected, actual);
}

// --- naive reference implementations, used to cross-check the real ones ---

fn modelFirstFrom(model: []const bool, from: usize, want: bool) ?usize {
    for (model[from..], from..) |value, i| {
        if (value == want) return i;
    }
    return null;
}

/// First-fit search by scanning runs of free bits, an independent algorithm from
/// the one in `findFirstUnsetRange`.
fn modelUnsetRange(model: []const bool, length: usize) ?Range {
    var run_start: usize = 0;
    for (model, 0..) |is_set, i| {
        if (is_set) {
            run_start = i + 1;
        } else if (i + 1 - run_start >= length) {
            return .{ .start = run_start, .end = run_start + length };
        }
    }
    return null;
}

fn nextRandom(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.*;
}

// --- fromRaw -----------------------------------------------------------------

test "fromRaw accepts a bit length that exactly fills the masks" {
    var masks = [_]MaskInt{ 0, 0 };
    const bs = BitSet.fromRaw(&masks, 2 * mask_bits);
    try testing.expectEqual(2 * mask_bits, bs.bit_length);
    try testing.expectEqual(2, bs.masks.len);
}

test "an empty bit set has nothing to find" {
    var masks = [_]MaskInt{};
    const bs = BitSet.fromRaw(&masks, 0);
    try testing.expectEqual(null, bs.findFirstUnset());
    try testing.expectEqual(null, bs.findFirstUnsetRange(1));
}

// --- set / unset / get -----------------------------------------------------------

test "set, unset and get work across mask boundaries" {
    var masks: [test_mask_count]MaskInt = undefined;
    const len: usize = 3 * mask_bits;
    var bs = initTest(&masks, len);

    const indices = [_]usize{ 0, 1, mask_bits - 1, mask_bits, mask_bits + 1, 2 * mask_bits - 1, 2 * mask_bits, len - 1 };
    for (indices) |index| {
        bs.set(index);
        // Only `index` is set.
        for (0..len) |i| try testing.expectEqual(i == index, bs.get(i));
        bs.unset(index);
    }
    for (0..len) |i| try testing.expect(!bs.get(i));
}

test "set and unset are idempotent and leave neighbours alone" {
    var masks: [test_mask_count]MaskInt = undefined;
    var bs = initTest(&masks, 2 * mask_bits);
    bs.set(mask_bits - 1);
    bs.set(mask_bits + 1);

    bs.set(mask_bits);
    bs.set(mask_bits);
    try testing.expect(bs.get(mask_bits));
    try testing.expect(bs.get(mask_bits - 1));
    try testing.expect(bs.get(mask_bits + 1));

    bs.unset(mask_bits);
    bs.unset(mask_bits);
    try testing.expect(!bs.get(mask_bits));
    try testing.expect(bs.get(mask_bits - 1));
    try testing.expect(bs.get(mask_bits + 1));
}

// --- findFirstUnset ----------------------------------------------------------------

test "findFirstUnset" {
    var masks: [test_mask_count]MaskInt = undefined;
    const len: usize = 2 * mask_bits + 6; // last mask has padding
    var bs = initTest(&masks, len);

    try testing.expectEqual(0, bs.findFirstUnset());

    setBits(&bs, 0, mask_bits + 3);
    try testing.expectEqual(mask_bits + 3, bs.findFirstUnset());

    // Fully set: the padding bits are 0, but they must not be reported.
    setBits(&bs, mask_bits + 3, len);
    try testing.expectEqual(null, bs.findFirstUnset());

    bs.unset(mask_bits);
    try testing.expectEqual(mask_bits, bs.findFirstUnset());
    bs.unset(0);
    try testing.expectEqual(0, bs.findFirstUnset());
}

test "findFirstUnset on a bit set that exactly fills its masks" {
    var masks: [test_mask_count]MaskInt = undefined;
    var bs = initTest(&masks, 2 * mask_bits);
    setBits(&bs, 0, 2 * mask_bits);
    try testing.expectEqual(null, bs.findFirstUnset());
    bs.unset(2 * mask_bits - 1);
    try testing.expectEqual(2 * mask_bits - 1, bs.findFirstUnset());
}

// --- findFirstUnsetFrom / findFirstSetFrom -------------------------------------------

test "findFirstUnsetFrom scans across masks and ignores padding" {
    var masks: [test_mask_count]MaskInt = undefined;
    const len: usize = 3 * mask_bits + 10;
    var bs = initTest(&masks, len);
    setBits(&bs, 0, len);
    bs.unset(mask_bits + 5);
    bs.unset(len - 1);

    try testing.expectEqual(mask_bits + 5, bs.findFirstUnsetFrom(0));
    try testing.expectEqual(mask_bits + 5, bs.findFirstUnsetFrom(mask_bits + 5));
    try testing.expectEqual(len - 1, bs.findFirstUnsetFrom(mask_bits + 6));
    try testing.expectEqual(len - 1, bs.findFirstUnsetFrom(len - 1));

    bs.set(len - 1);
    try testing.expectEqual(null, bs.findFirstUnsetFrom(mask_bits + 6));
}

test "findFirstSetFrom scans across masks and ignores padding" {
    var masks: [test_mask_count]MaskInt = undefined;
    const len: usize = 3 * mask_bits + 10;
    var bs = initTest(&masks, len);

    try testing.expectEqual(null, bs.findFirstSetFrom(0));

    bs.set(2);
    bs.set(mask_bits);
    bs.set(len - 1);
    try testing.expectEqual(2, bs.findFirstSetFrom(0));
    try testing.expectEqual(2, bs.findFirstSetFrom(2));
    try testing.expectEqual(mask_bits, bs.findFirstSetFrom(3));
    try testing.expectEqual(mask_bits, bs.findFirstSetFrom(mask_bits)); // starts exactly on a mask boundary
    try testing.expectEqual(len - 1, bs.findFirstSetFrom(mask_bits + 1));
    try testing.expectEqual(len - 1, bs.findFirstSetFrom(len - 1));

    bs.unset(len - 1);
    try testing.expectEqual(null, bs.findFirstSetFrom(mask_bits + 1));
}

// --- findFirstUnsetRange ---------------------------------------------------------------

test "findFirstUnsetRange returns exactly the requested length" {
    var masks: [test_mask_count]MaskInt = undefined;
    const len: usize = 2 * mask_bits + 6;
    const bs = initTest(&masks, len);

    try expectRange(.{ .start = 0, .end = 1 }, bs.findFirstUnsetRange(1));
    try expectRange(.{ .start = 0, .end = 10 }, bs.findFirstUnsetRange(10));
    try expectRange(.{ .start = 0, .end = len }, bs.findFirstUnsetRange(len));
    try expectRange(null, bs.findFirstUnsetRange(len + 1));
}

test "findFirstUnsetRange skips runs that are too short" {
    var masks: [test_mask_count]MaskInt = undefined;
    const len: usize = 3 * mask_bits;
    var bs = initTest(&masks, len);
    setBits(&bs, 0, 3);
    bs.set(4);
    bs.set(6);
    // Free runs: [3, 4), [5, 6) and [7, len).

    try expectRange(.{ .start = 3, .end = 4 }, bs.findFirstUnsetRange(1));
    try expectRange(.{ .start = 7, .end = 9 }, bs.findFirstUnsetRange(2));
    try expectRange(.{ .start = 7, .end = len }, bs.findFirstUnsetRange(len - 7));
    try expectRange(null, bs.findFirstUnsetRange(len - 6));
}

test "findFirstUnsetRange finds runs that cross a mask boundary" {
    var masks: [test_mask_count]MaskInt = undefined;
    var bs = initTest(&masks, 3 * mask_bits);
    setBits(&bs, 0, mask_bits - 2);
    bs.set(mask_bits + 3);
    // Free runs: [mask_bits - 2, mask_bits + 3) and [mask_bits + 4, 3 * mask_bits).

    try expectRange(.{ .start = mask_bits - 2, .end = mask_bits + 3 }, bs.findFirstUnsetRange(5));
    try expectRange(.{ .start = mask_bits + 4, .end = mask_bits + 10 }, bs.findFirstUnsetRange(6));
}

test "findFirstUnsetRange does not count padding bits as free" {
    var masks: [test_mask_count]MaskInt = undefined;
    const len: usize = mask_bits + 6;
    var bs = initTest(&masks, len);
    setBits(&bs, 0, len - 1);
    // Only the last real bit is free. The padding after it is 0 too, but isn't memory.

    try expectRange(.{ .start = len - 1, .end = len }, bs.findFirstUnsetRange(1));
    try expectRange(null, bs.findFirstUnsetRange(2));
}

// --- setRangeValue -----------------------------------------------------------------------

test "setRangeValue matches a naive model for every possible range" {
    const lengths = [_]usize{ 1, 2, mask_bits - 1, mask_bits, mask_bits + 1, 2 * mask_bits - 1, 2 * mask_bits, 2 * mask_bits + 1, 3 * mask_bits + 7 };
    var masks: [test_mask_count]MaskInt = undefined;
    var model: [max_test_bits]bool = undefined;

    for (lengths) |len| {
        // Initial contents: all clear, all set, alternating. This checks that bits outside
        // the range are preserved, not just that the range itself is written.
        for (0..3) |pattern| {
            for (0..len + 1) |start| {
                // `end == start` is the empty range, `end == len` ends exactly at the bit length.
                for (start..len + 1) |end| {
                    for ([_]bool{ false, true }) |value| {
                        var bs = initTest(&masks, len);
                        for (model[0..len], 0..) |*m, i| {
                            m.* = switch (pattern) {
                                0 => false,
                                1 => true,
                                else => i % 2 == 0,
                            };
                            if (m.*) bs.set(i);
                        }

                        bs.setRangeValue(.{ .start = start, .end = end }, value);
                        @memset(model[start..end], value);

                        expectMatches(&bs, model[0..len]) catch |err| {
                            std.debug.print(
                                "len={d} pattern={d} range=[{d}, {d}) value={}\n",
                                .{ len, pattern, start, end, value },
                            );
                            return err;
                        };
                    }
                }
            }
        }
    }
}

// --- cross-check of all the search functions on random bit sets ---------------------------

test "search functions match a naive model on random bit sets" {
    const lengths = [_]usize{ 1, 7, mask_bits - 1, mask_bits, mask_bits + 1, 2 * mask_bits, 2 * mask_bits + 5, 3 * mask_bits + 7 };
    var masks: [test_mask_count]MaskInt = undefined;
    var model_buf: [max_test_bits]bool = undefined;
    var rng_state: u64 = 0x9E3779B97F4A7C15;

    for (lengths) |len| {
        for (0..100) |_| {
            var bs = initTest(&masks, len);
            const model = model_buf[0..len];

            // A random density, so there are sparse, dense and in-between sets.
            const density = nextRandom(&rng_state) % 100;
            for (model, 0..) |*m, i| {
                m.* = nextRandom(&rng_state) % 100 < density;
                if (m.*) bs.set(i);
            }

            try testing.expectEqual(modelFirstFrom(model, 0, false), bs.findFirstUnset());
            for (0..len) |i| {
                try testing.expectEqual(modelFirstFrom(model, i, false), bs.findFirstUnsetFrom(i));
                try testing.expectEqual(modelFirstFrom(model, i, true), bs.findFirstSetFrom(i));
            }
            // One past `len` must be rejected with null.
            for (1..len + 2) |length| {
                try expectRange(modelUnsetRange(model, length), bs.findFirstUnsetRange(length));
            }
        }
    }
}
