const std = @import("std");

const SegmentDescriptor = packed struct(u64) {
    limit_low: u16 = 0,
    base_low: u16 = 0,
    base_mid: u8 = 0,
    type: u4,
    s: u1,
    dpl: u2,
    p: u1,
    limit_high: u4 = 0,
    avl: u1 = 0,
    l: u1,
    d_b: u1,
    g: u1,
    base_high: u8 = 0,
};

const TssDescriptor = packed struct(u128) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    type: u4,
    s: u1,
    dpl: u2,
    p: u1,
    limit_high: u4,
    avl: u1,
    l: u1,
    d_b: u1,
    g: u1,
    base_high: u8,
    base_upper: u32,
    _reserved: u32 = 0,
};

const Tss = packed struct {
    _reserved0: u32 = 0,
    rsp0: u64,
    rsp1: u64,
    rsp2: u64,
    _reserved1: u64 = 0,
    ist1: u64,
    ist2: u64,
    ist3: u64,
    ist4: u64,
    ist5: u64,
    ist6: u64,
    ist7: u64,
    _reserved2: u64 = 0,
    _reserved3: u16 = 0,
    io_map_base_address: u16,
};

const GdtTable = packed struct {
    null_descriptor: SegmentDescriptor = .{
        .limit_low = 0,
        .base_low = 0,
        .base_mid = 0,
        .type = 0,
        .s = 0,
        .dpl = 0,
        .p = 0,
        .limit_high = 0,
        .avl = 0,
        .l = 0,
        .d_b = 0,
        .g = 0,
        .base_high = 0,
    },
    kernel_code_descriptor: SegmentDescriptor = .{
        .type = 0b1010,
        .s = 1,
        .dpl = 0,
        .p = 1,
        .l = 1,
        .d_b = 0,
        .g = 0,
    },
    kernel_data_descriptor: SegmentDescriptor = .{
        .type = 0b0010,
        .s = 1,
        .dpl = 0,
        .p = 1,
        .l = 0,
        .d_b = 0,
        .g = 0,
    },
    user_code_descriptor: SegmentDescriptor = .{
        .type = 0b1010,
        .s = 1,
        .dpl = 3,
        .p = 1,
        .l = 1,
        .d_b = 0,
        .g = 0,
    },
    user_data_descriptor: SegmentDescriptor = .{
        .type = 0b0010,
        .s = 1,
        .dpl = 3,
        .p = 1,
        .l = 0,
        .d_b = 0,
        .g = 0,
    },
    tss_descriptor: TssDescriptor = .{
        .limit_low = 0,
        .base_low = undefined,
        .base_mid = undefined,
        .type = 0b1001,
        .s = 0,
        .dpl = 0,
        .p = 1,
        .limit_high = 0,
        .avl = 0,
        .l = 0,
        .d_b = 0,
        .g = 0,
        .base_high = undefined,
        .base_upper = undefined,
    },
};

pub const Gdtr = packed struct {
    limit: u16,
    base: u64,
};

comptime {
    if (@bitSizeOf(Gdtr) != 80) @compileError("incorrect `Gdtr` size");
}

pub const kernel_code_selector: u16 = @offsetOf(GdtTable, "kernel_code_descriptor");
pub const kernel_data_selector: u16 = @offsetOf(GdtTable, "kernel_data_descriptor");
pub const userland_code_selector: u16 = @offsetOf(GdtTable, "user_code_descriptor");
pub const userland_data_selector: u16 = @offsetOf(GdtTable, "user_data_descriptor");
pub const tss_selector: u16 = @offsetOf(GdtTable, "tss_descriptor");

/// Must not be moved - may lead to stale pointers.
pub fn Gdt(comptime Arch: type) type {
    return struct {
        gdt: GdtTable,
        ist1_stack: [8192]u8 align(16),
        tss: Tss,

        pub fn init() @This() {
            return .{
                .gdt = .{},
                .ist1_stack = @splat(0),
                .tss = .{
                    .rsp0 = 0, // TODO: VERY!!! Important for userspace.
                    .rsp1 = 0,
                    .rsp2 = 0,
                    .ist1 = undefined,
                    .ist2 = 0,
                    .ist3 = 0,
                    .ist4 = 0,
                    .ist5 = 0,
                    .ist6 = 0,
                    .ist7 = 0,
                    .io_map_base_address = 0,
                },
            };
        }

        pub fn load(self: *@This()) void {
            const gdtr: Gdtr = .{
                .limit = @sizeOf(GdtTable) - 1,
                .base = @intCast(@intFromPtr(&self.gdt)),
            };

            const tss_base: u64 = @intCast(@intFromPtr(&self.tss));
            const tss_limit: u32 = @sizeOf(Tss) - 1;
            setupTss(&self.gdt, &self.tss, &self.ist1_stack, tss_base, tss_limit);

            Arch.lgdt(&gdtr, kernel_code_selector, kernel_data_selector, tss_selector);
        }
    };
}

fn setupTss(gdt: *GdtTable, tss: *Tss, ist1_stack: []align(16) const u8, tss_base: u64, tss_limit: u32) void {
    gdt.tss_descriptor.base_low = @truncate(tss_base);
    gdt.tss_descriptor.base_mid = @truncate(tss_base >> 16);
    gdt.tss_descriptor.base_high = @truncate(tss_base >> 24);
    gdt.tss_descriptor.base_upper = @truncate(tss_base >> 32);
    gdt.tss_descriptor.limit_low = @truncate(tss_limit);
    gdt.tss_descriptor.limit_high = @truncate(tss_limit >> 16);
    tss.ist1 = @intFromPtr(ist1_stack.ptr) + ist1_stack.len;
}

test "TSS descriptor matches the Intel SDM 64-bit layout" {
    const base: u64 = 0xFFFF_8000_A1B2_C3D4;
    const limit: u32 = 0x67; // @sizeOf(Tss) - 1 (104 - 1)
    const ist1_stack: [128]u8 align(16) = @splat(0);
    var gdt: GdtTable = .{};
    var tss: Tss = undefined;
    setupTss(&gdt, &tss, &ist1_stack, base, limit);

    try std.testing.expectEqual(16, @sizeOf(TssDescriptor));

    const expected = [16]u8{
        0x67, 0x00, // limit 15:0
        0xD4, 0xC3, // base 15:0
        0xB2, // base 23:16
        0x89, // P=1, DPL=0, type=0x9 (available 64-bit TSS)
        0x00, // flags = 0, limit 19:16 = 0
        0xA1, // base 31:24
        0x00, 0x80, 0xFF, 0xFF, // base 63:32
        0x00, 0x00, 0x00, 0x00, // reserved
    };

    try std.testing.expectEqualSlices(u8, &expected, std.mem.asBytes(&gdt.tss_descriptor));
}
