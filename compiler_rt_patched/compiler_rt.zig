const std = @import("std");
const builtin = @import("builtin");
const os_tag = builtin.os.tag;
const arch = builtin.cpu.arch;
const abi = builtin.abi;
const assert = std.debug.assert;

comptime {
    symbol(&memset, "memset");
    _ = @import("memmove.zig");
    _ = @import("memcpy.zig");

    switch (arch) {
        .x86,
        .x86_64,
        => {
            symbol(&zig_probe_stack, "__zig_probe_stack");
        },
        else => {},
    }
}

pub const PreferredLoadStoreElement = element: {
    if (std.simd.suggestVectorLength(u8)) |vec_size| {
        const Vec = @Vector(vec_size, u8);

        if (@sizeOf(Vec) == vec_size and std.math.isPowerOfTwo(vec_size)) {
            break :element Vec;
        }
    }
    break :element usize;
};

pub inline fn symbol(comptime func: *const anyopaque, comptime name: []const u8) void {
    // The function shouldn't be exported at all when testing compiler_rt.
    // Instead, we just need to reference the function so that it's compiled.
    if (!builtin.is_test) @export(func, .{
        .name = name,
        .linkage = .weak,
        .visibility = .hidden,
    });
}

// Zig's own stack-probe routine (available only on x86 and x86_64)
pub fn zig_probe_stack() callconv(.naked) void {
    @setRuntimeSafety(false);

    // Versions of the Linux kernel before 5.1 treat any access below SP as
    // invalid so let's update it on the go, otherwise we'll get a segfault
    // instead of triggering the stack growth.

    switch (arch) {
        .x86_64 => {
            // %rax = probe length, %rsp = stack pointer
            asm volatile (
                \\        push   %%rcx
                \\        mov    %%rax, %%rcx
                \\        cmp    $0x1000,%%rcx
                \\        jb     2f
                \\ 1:
                \\        sub    $0x1000,%%rsp
                \\        orl    $0,16(%%rsp)
                \\        sub    $0x1000,%%rcx
                \\        cmp    $0x1000,%%rcx
                \\        ja     1b
                \\ 2:
                \\        sub    %%rcx, %%rsp
                \\        orl    $0,16(%%rsp)
                \\        add    %%rax,%%rsp
                \\        pop    %%rcx
                \\        ret
            );
        },
        .x86 => {
            // %eax = probe length, %esp = stack pointer
            asm volatile (
                \\        push   %%ecx
                \\        mov    %%eax, %%ecx
                \\        cmp    $0x1000,%%ecx
                \\        jb     2f
                \\ 1:
                \\        sub    $0x1000,%%esp
                \\        orl    $0,8(%%esp)
                \\        sub    $0x1000,%%ecx
                \\        cmp    $0x1000,%%ecx
                \\        ja     1b
                \\ 2:
                \\        sub    %%ecx, %%esp
                \\        orl    $0,8(%%esp)
                \\        add    %%eax,%%esp
                \\        pop    %%ecx
                \\        ret
            );
        },
        else => {},
    }

    unreachable;
}

fn fastMemset(dest: ?[*]u8, c: c_int, len: usize) callconv(.c) ?[*]u8 {
    @disableIntrinsics();

    const b: u8 = @truncate(@as(c_uint, @bitCast(c)));
    const n = std.simd.suggestVectorLength(u8) orelse @sizeOf(usize);

    const d = dest.?;

    if (len > 2 * n) {
        memsetSmallPowerOf2(d, b, n);

        const begin_aligned = std.mem.alignBackward(usize, @intFromPtr(d) + n, n);
        const end_aligned = std.mem.alignForward(usize, @intFromPtr(d) + len - n, n);

        const aligned_ptr: [*]align(n) u8 = @ptrFromInt(begin_aligned);

        var i: usize = 0;
        while (true) {
            memsetSmallPowerOf2(aligned_ptr + n * i, b, n);

            i += 1;
            if (i == @divExact(end_aligned - begin_aligned, n))
                break;
        }

        memsetSmallPowerOf2(d + len - n, b, n);
    } else {
        if (len == 0) return dest;

        shortMemset(0, @ctz(@as(usize, 2 * n)), d, b, len);
    }

    return dest;
}

fn memsetSmallPowerOf2(d: [*]u8, b: u8, comptime size: usize) void {
    @disableIntrinsics();

    if (size > @sizeOf(usize)) {
        d[0..size].* = @splat(b);
    } else {
        const T = @Int(.unsigned, 8 * size);
        var splatted: T = 0; // Setting this to undefined causes a memset call and thus infinite recursion in Debug test-compiler-rt.
        @as(*[size]u8, @ptrCast(&splatted)).* = @splat(b);
        @as(*align(1) T, @ptrCast(d)).* = splatted;
    }
}

fn shortMemset(
    log_min: comptime_int,
    log_max: comptime_int,
    d: [*]u8,
    b: u8,
    len: usize,
) void {
    @disableIntrinsics();

    if (log_min + 1 != log_max) {
        const mid = (log_min + log_max) / 2;
        if (len > 1 << mid) {
            shortMemset(mid, log_max, d, b, len);
        } else {
            shortMemset(log_min, mid, d, b, len);
        }
    } else {
        const size = 1 << log_min;

        memsetSmallPowerOf2(d, b, size);
        memsetSmallPowerOf2(d + len - size, b, size);
    }
}

fn smallMemset(dest: ?[*]u8, c: c_int, len: usize) callconv(.c) ?[*]u8 {
    @disableIntrinsics();

    const b: u8 = @truncate(@as(c_uint, @bitCast(c)));

    if (len != 0) {
        var d = dest.?;
        var n = len;
        while (true) {
            d[0] = b;
            n -= 1;
            if (n == 0) break;
            d += 1;
        }
    }

    return dest;
}

pub const memset = if (builtin.optimize == .small)
    smallMemset
else
    fastMemset;

pub const test_safety = switch (builtin.zig_backend) {
    .stage2_aarch64 => false,
    else => builtin.is_test,
};
