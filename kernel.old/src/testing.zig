const std = @import("std");

const prng_base_seed: u64 = 0xDEADBEEFDEADBEEF;

pub fn prngFill(buf: []u8) void {
    const seed = prng_base_seed ^ @as(u64, @intFromPtr(buf));
    const prng = std.Random.DefaultPrng.init(seed);
    prng.fill(buf);
}

pub fn prngValidate(buf: []const u8) bool {
    const seed = prng_base_seed ^ @as(u64, @intFromPtr(buf));
    const prng = std.Random.DefaultPrng.init(seed);

    // NOTE: See `std.Random.Xoshiro256.fill()` implementation.

    var i: usize = 0;
    const aligned_len = buf.len - (buf.len & 7);

    // Complete 8 byte segments.
    while (i < aligned_len) : (i += 8) {
        var n = prng.next();
        comptime var j: usize = 0;
        inline while (j < 8) : (j += 1) {
            if (buf[i + j] != @as(u8, @truncate(n)))
                return false;
            n >>= 8;
        }
    }

    // Remaining. (cuts the stream)
    if (i != buf.len) {
        var n = prng.next();
        while (i < buf.len) : (i += 1) {
            if (buf[i] != @as(u8, @truncate(n)))
                return false;
            n >>= 8;
        }
    }
}
