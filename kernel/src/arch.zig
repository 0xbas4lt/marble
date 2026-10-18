const builtin = @import("builtin");

pub const x86_64 = @import("arch/x86_64/arch.zig");

pub const current = switch (builtin.target.cpu.arch) {
    .x86_64 => x86_64,
    else => @compileError("unsupported architecture"),
};

// test {
//     _ = x86_64;
// }
