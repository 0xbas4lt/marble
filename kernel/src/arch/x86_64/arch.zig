const std = @import("std");
pub const gdt = @import("./gdt.zig");

pub fn lgdt(gdtr_ptr: *const gdt.Gdtr, kernel_code_selector: u16, kernel_data_selector: u16, tss_selector: u16) void {
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
        : [gdtr_ptr] "r" (gdtr_ptr),
          [cs_sel] "r" (@as(u64, kernel_code_selector)),
          [ds_sel] "r" (@as(u16, kernel_data_selector)),
          [tss_sel] "r" (@as(u16, tss_selector)),
        : .{ .rax = true, .memory = true });
}

pub fn halt() noreturn {
    @branchHint(.cold);
    while (true) {
        asm volatile (
            \\cli
            \\hlt
        );
    }
}

pub fn cpuid(leaf: u32, subleaf: u32) struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
} {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile (
        \\cpuid
        : [eax_out] "={eax}" (eax),
          [ebx_out] "={ebx}" (ebx),
          [ecx_out] "={ecx}" (ecx),
          [edx_out] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
        : .{
          .rax = true,
          .rbx = true,
          .rcx = true,
          .rdx = true,
        });
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

pub var cpuid_info: struct {
    ext_cpuid_max_leaf: u32 = undefined,
    max_physical_address_bits: ?u8 = null,
    max_linear_address_bits: ?u8 = null,
} = .{};

/// Queries the CPU, and initialized internal variables.
pub fn init() void {
    cpuid_info.ext_cpuid_max_leaf = cpuid(0x80000000, 0).eax;

    const ext_cpuid_leaf_index: u32 = 0x80000008;
    if (ext_cpuid_leaf_index <= cpuid_info.ext_cpuid_max_leaf) {
        const ext_cpuid_leaf_resp = cpuid(ext_cpuid_leaf_index, 0);
        cpuid_info.max_physical_address_bits = @truncate(ext_cpuid_leaf_resp.eax);
        cpuid_info.max_linear_address_bits = @truncate(ext_cpuid_leaf_resp.eax >> 8);
    }
}
