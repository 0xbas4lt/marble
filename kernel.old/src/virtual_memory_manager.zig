const std = @import("std");
const types = @import("types.zig");
const config = @import("config.zig");
const arch = @import("arch/x86_64.zig");

const Pmm = @import("physical_memory_manager.zig");
const Vmm = @This();

pmm: *Pmm,

/// Universal structure, used as PML4E, PDPTE, PDE
const DirectoryEntry = packed struct(u64) {
    p: u1 = 0,
    rw: u1,
    us: u1,
    pwt: u1,
    pcd: u1,
    a: u1,
    ignored0: u1 = 0,
    ps: u1,
    ignored1: u4 = 0,
    /// Highest non-zero bit must be **less** significant than the CPU-advertized maximum physical address bit.
    referenced_physical_address: u40,
    ignored2: u11 = 0,
    xd: u1,
};

const PageTableEntry = packed struct(u64) {
    p: u1 = 0,
    rw: u1,
    us: u1,
    pwt: u1,
    pcd: u1,
    a: u1,
    d: u1,
    pat: u1,
    g: u1,
    ignored0: u3 = 0,
    /// Highest non-zero bit must be **less** significant than the CPU-advertized maximum physical address bit.
    page_physical_address: u40,
    ignored1: u7 = 0,
    protection_key: u4,
    xd: u1,
};

pub const Error = error{ OutOfMemory, AlreadyMapped };

fn virtAddr4KibToIndicies(addr: types.VirtAddr) struct {
    offset: u12,
    table: u9,
    directory: u9,
    directory_ptr: u9,
    pml4: u9,
} {
    const addr_int = @as(u64, addr);
    return .{
        .offset = @truncate(addr_int),
        .table = @truncate(addr_int >> 12),
        .directory = @truncate(addr_int >> 21),
        .directory_ptr = @truncate(addr_int >> 30),
        .pml4 = @truncate(addr_int >> 39),
    };
}

var pml4: *[512]DirectoryEntry = undefined;

/// If the provided entry's `present` flag is set, returns its referenced child table.
/// Otherwise, allocates a new frame, zeroes it, and sets entry's reference to point to the new table.
fn getOrCreateChildTable(self: *Vmm, comptime Child: type, entry: *DirectoryEntry) Error!*[512]Child {
    if (entry.p == 1) return @ptrFromInt((@as(types.PhysAddr, entry.referenced_physical_address) << 12) + self.pmm.hhdmOffset());

    const phys_frame = try self.pmm.allocateFrame();
    const child: *[512]Child = @ptrFromInt(phys_frame.virtBase());
    std.crypto.secureZero(Child, child);
    entry.referenced_physical_address = @truncate(phys_frame.physBase() >> 12);
    return child;
}

const PteResult = struct {
    pte: *PageTableEntry,
    found_existing: bool,
};

/// Walks page tables.
/// If the page at the provided virtual address is not mapped, creates all necessary structures, and returns `PteResult` with `found_existing` flag unset,
/// and with `pte` flag containing a 'default' _(check this implementation)_ PTE, with the `present` flag **unset**.
/// Otherwise returns `PteResult` with a pointer to the existing PTE, and `found_existing` set.
fn getOrCreatePageTableEntry(self: *Vmm, virt_addr: types.VirtAddr) Error!PteResult {
    const indicies = virtAddr4KibToIndicies(virt_addr);

    var pml4e: *DirectoryEntry = &pml4[indicies.pml4];
    if (pml4e.p == 0) pml4e.* = DirectoryEntry{
        .rw = 1,
        .us = 1,
        .pwt = 0,
        .pcd = 0,
        .a = 0,
        .ps = 0,
        .referenced_physical_address = undefined,
        .xd = 0,
    };
    const pdpt = try self.getOrCreateChildTable(DirectoryEntry, pml4e);
    const pdpte = &pdpt[indicies.directory_ptr];
    pml4e.p = 1;

    if (pdpte.p == 0) pdpte.* = DirectoryEntry{
        .rw = 1,
        .us = 1,
        .pwt = 0,
        .pcd = 0,
        .a = 0,
        .ps = 0,
        .referenced_physical_address = undefined,
        .xd = 0,
    };
    const pd = try self.getOrCreateChildTable(DirectoryEntry, pdpte);
    const pde = &pd[indicies.directory];
    pdpte.p = 1;

    if (pde.p == 0) pde.* = DirectoryEntry{
        .rw = 1,
        .us = 1,
        .pwt = 0,
        .pcd = 0,
        .a = 0,
        .ps = 0,
        .referenced_physical_address = undefined,
        .xd = 0,
    };
    const pt = try self.getOrCreateChildTable(PageTableEntry, pde);
    const pte = &pt[indicies.table];
    pde.p = 1;

    const is_pte_present = pte.p == 1;
    if (!is_pte_present) pte.* = PageTableEntry{
        .rw = 1,
        .us = 0,
        .pwt = 0, //FIXME: Check docs idk what this is.
        .pcd = 0, //FIXME: Check docs idk what this is.
        .a = 0,
        .d = 0,
        .pat = 0, //FIXME: Check docs idk what this is.
        .g = 0, //FIXME: Check docs idk what this is.
        .page_physical_address = undefined,
        .protection_key = 0, // FIXME: Check docs: What does PK do?
        .xd = 0,
    };

    return PteResult{
        .found_existing = is_pte_present,
        .pte = pte,
    };
}

pub const MapFlags = struct {};

pub fn map(self: *Vmm, virt_addr: types.VirtAddr, phys_addr: types.PhysAddr, flags: MapFlags) Error!void {
    _ = flags;
    const result = try self.getOrCreatePageTableEntry(virt_addr);
    if (result.found_existing) return error.AlreadyMapped;
    result.pte.page_physical_address = @truncate(phys_addr >> 12);
    result.pte.p = 1;
}

const oom_msg = "vmm init: out of memory";

const Cr3 = packed struct(u64) {
    pcid: u12,
    /// Highest non-zero bit must be **less** significant than the CPU-advertized maximum physical address bit.
    pml4_phys_addr: u52,
};

/// Initializes the VMM, and sets up the paging. May panic.
/// NOTE: Stack is not tracked explicitly in any way.
pub fn init(pmm: *Pmm, kernel_base_virt_address: types.VirtAddr) Vmm {
    var instance = Vmm{ .pmm = pmm };

    const pml4_frame = pmm.allocateFrame() catch
        @panic(oom_msg);
    pml4 = @ptrFromInt(pml4_frame.virtBase());
    std.crypto.secureZero(DirectoryEntry, pml4);

    for (0..config.kernelSizePages()) |i| instance.map(
        kernel_base_virt_address + i * config.page_size_bytes,
        pmm.kernelPhysBase() + i * config.page_size_bytes,
        .{},
    ) catch
        @panic(oom_msg);

    for (0..pmm.frameCount()) |i| {
        const frame_phys_base: types.PhysAddr = @intCast(i * config.page_size_bytes);
        instance.map(frame_phys_base + pmm.hhdmOffset(), frame_phys_base, .{}) catch
            @panic(oom_msg);
    }

    const cr3 = Cr3{
        .pcid = 0,
        .pml4_phys_addr = @intCast(pml4_frame.physBase() >> 12),
    };

    asm volatile (
        \\movq %[val], %cr3
        :
        : [val] "r" (cr3),
    );

    return instance;
}
