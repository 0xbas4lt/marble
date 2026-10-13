pub fn halt() noreturn {
    while (true) asm volatile (
        \\cli
        \\hlt
    );
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

pub var ext_cpuid_max_leaf: u32 = undefined;
pub var max_physical_address_bits: ?u8 = null;
pub var max_linear_address_bits: ?u8 = null;

/// Queries the CPU, and initialized internal variables.
fn init() void {
    ext_cpuid_max_leaf = cpuid(0x80000000, 0).eax;

    const ext_cpuid_leaf_index: u32 = 0x80000008;
    if (ext_cpuid_leaf_index <= ext_cpuid_max_leaf) {
        const ext_cpuid_leaf_resp = cpuid(ext_cpuid_leaf_index, 0);
        max_physical_address_bits = @truncate(ext_cpuid_leaf_resp.eax);
        max_linear_address_bits = @truncate(ext_cpuid_leaf_resp.eax >> 8);
    }
}
