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

var ist1_stack: [2048]u8 = .{0} ** 2048;

var tss = Tss{
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
};

const Gdt = packed struct {
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

pub const kernel_code_selector: u16 = @offsetOf(Gdt, "kernel_code_descriptor");
pub const kernel_data_selector: u16 = @offsetOf(Gdt, "kernel_data_descriptor");
pub const userland_code_selector: u16 = @offsetOf(Gdt, "user_code_descriptor");
pub const userland_data_selector: u16 = @offsetOf(Gdt, "user_data_descriptor");

var gdt = Gdt{};

pub fn init() void {
    tss.ist1 = @intFromPtr(&ist1_stack) + ist1_stack.len;
    const tss_addr: u64 = @intCast(@intFromPtr(&tss));
    gdt.tss_descriptor.base_low = @truncate(tss_addr);
    gdt.tss_descriptor.base_mid = @truncate(tss_addr >> 16);
    gdt.tss_descriptor.base_high = @truncate(tss_addr >> 24);
    gdt.tss_descriptor.base_upper = @truncate(tss_addr >> 32);
    const tss_limit: u32 = @sizeOf(Tss) - 1;
    gdt.tss_descriptor.limit_low = @truncate(tss_limit);
    gdt.tss_descriptor.limit_high = @truncate(tss_limit >> 16);

    const gdtr = packed struct {
        limit: u16,
        base: u64,
    }{
        .limit = @sizeOf(Gdt) - 1,
        .base = @intCast(@intFromPtr(&gdt)),
    };

    const tss_selector = @offsetOf(Gdt, "tss_descriptor");

    asm volatile (
        \\lgdt (%[gdtr_ptr])
        \\push %[cs_sel]
        \\lea 1f(%rip), %rax
        \\push %rax
        \\lretq
        \\1:
        \\mov %[ds_sel], %ds
        \\mov %[ds_sel], %es
        \\mov %[ds_sel], %ss
        \\mov %[ds_sel], %fs
        \\mov %[ds_sel], %gs
        \\ltr %[tss_sel]
        :
        : [gdtr_ptr] "r" (&gdtr),
          [cs_sel] "r" (@as(u64, kernel_code_selector)),
          [ds_sel] "r" (@as(u16, kernel_data_selector)),
          [tss_sel] "r" (@as(u16, tss_selector)),
        : .{ .rax = true, .memory = true });
}
