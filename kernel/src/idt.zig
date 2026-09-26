const std = @import("std");
const gdt = @import("gdt.zig");

const Gate = packed struct {
    offset_low: u16 = 0,
    segment_selector: u16 = 0,
    ist: u3 = 0,
    _reserved0: u5 = 0,
    type: u4 = 0,
    _reserved1: u1 = 0,
    dpl: u2 = 0,
    p: u1 = 0,
    offset_mid: u16 = 0,
    offset_high: u32 = 0,
    _reserved2: u32 = 0,
};

const InterruptFrame = packed struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

export fn __isrDispatch(frame: *InterruptFrame) void {
    const exception_name = switch (frame.vector) {
        0 => "#DE Divide Error",
        1 => "#DB Debug Exception",
        3 => "#BP Breakpoint",
        4 => "#OF Overflow",
        5 => "#BR BOUND Range Exceeded",
        7 => "#UD Invalid Opcode",
        8 => "#DF Double Fault",
        10 => "#TS Invalid TSS",
        11 => "#NP Segment Not Present",
        12 => "#SS Stack-Segment Fault",
        13 => "#GP General Protection",
        14 => "#PF Page Fault",
        16 => "#MF x87 FPU Floating-Point Error",
        17 => "#AC Alignment Check",
        18 => "#MC Machine Check",
        19 => "#XM SIMD Floating-Point Exception",
        20 => "#VE Virtualization Exception",
        32...255 => "",
        else => "#?? Unknown Exception",
    };

    if (frame.vector < 32) {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf,
            \\EXCEPTION:  {s}
            \\INT VECTOR: 0x{X:016}
            \\ERROR CODE: 0x{X:016}
            \\
            \\[SPECIAL-PURPOSE REGISTERS]
            \\RIP: 0x{X:016}  CS:  0x{X:016}
            \\SS:  0x{X:016}  RSP: 0x{X:016}
            \\RFLAGS:                       0x{X:016}
            \\
            \\[GENERAL-PURPOSE REGISTERS]
            \\RAX: 0x{X:016}  RCX: 0x{X:016}
            \\RDX: 0x{X:016}  RBX: 0x{X:016}
            \\RBP: 0x{X:016}  RSI: 0x{X:016}
            \\RDI: 0x{X:016}  R15: 0x{X:016}
            \\R14: 0x{X:016}  R13: 0x{X:016}
            \\R12: 0x{X:016}  R11: 0x{X:016}
            \\R10: 0x{X:016}  R9:  0x{X:016}
            \\R8:                           0x{X:016}
        , .{
            exception_name,
            frame.vector,
            frame.error_code,
            frame.rip,
            frame.cs,
            frame.ss,
            frame.rsp,
            frame.rflags,
            frame.rax,
            frame.rcx,
            frame.rdx,
            frame.rbx,
            frame.rbp,
            frame.rsi,
            frame.rdi,
            frame.r15,
            frame.r14,
            frame.r13,
            frame.r12,
            frame.r11,
            frame.r10,
            frame.r9,
            frame.r8,
        }) catch @panic("message did not fit in the buffer");
        @panic(msg);
    }
}

fn generateIsr(comptime vector: usize) fn () callconv(.naked) void {
    return struct {
        fn call() callconv(.naked) void {
            const has_err_code = switch (vector) {
                8, 10, 11, 12, 13, 14, 17 => true,
                else => false,
            };

            if (!has_err_code) asm volatile ("pushq $0" ::: .{ .memory = true });

            asm volatile (
                \\pushq %[vector]
                \\pushq %rax
                \\pushq %rcx
                \\pushq %rdx
                \\pushq %rbx
                \\pushq %rbp
                \\pushq %rsi
                \\pushq %rdi
                \\pushq %r8
                \\pushq %r9
                \\pushq %r10
                \\pushq %r11
                \\pushq %r12
                \\pushq %r13
                \\pushq %r14
                \\pushq %r15
                \\movq %rsp, %rdi
                \\call __isrDispatch
                \\popq %r15
                \\popq %r14
                \\popq %r13
                \\popq %r12
                \\popq %r11
                \\popq %r10
                \\popq %r9
                \\popq %r8
                \\popq %rdi
                \\popq %rsi
                \\popq %rbp
                \\popq %rbx
                \\popq %rdx
                \\popq %rcx
                \\popq %rax
                \\addq $16, %rsp
                \\iretq
                :
                : [vector] "i" (@as(u64, vector)),
                : .{ .memory = true });
        }
    }.call;
}

const isr_stubs: [256]*const fn () callconv(.naked) void = blk: {
    var stubs: [256]*const fn () callconv(.naked) void = undefined;
    for (0..256) |vector| {
        stubs[vector] = generateIsr(vector);
    }
    break :blk stubs;
};

var idt: [256]Gate = [_]Gate{.{}} ** 256;

pub fn init() void {
    inline for (0..256) |vector| {
        const addr: u64 = @intFromPtr(isr_stubs[vector]);
        idt[vector].offset_low = @truncate(addr);
        idt[vector].offset_mid = @truncate(addr >> 16);
        idt[vector].offset_high = @truncate(addr >> 32);
        idt[vector].segment_selector = gdt.kernel_code_selector;
        idt[vector].type = 0xE;
        idt[vector].dpl = 0;
        idt[vector].p = 1;
        idt[vector].ist = 0;
    }

    // #DF
    idt[8].ist = 1;

    const idtr = packed struct { limit: u16, base: u64 }{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };

    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (&idtr),
    );
}
