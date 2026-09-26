//! Limine protocol spec (v8.x branch):
//!   https://github.com/limine-bootloader/limine/blob/v8.x/PROTOCOL.md

const COMMON_0: u64 = 0xc7b1dd30df4c8b88;
const COMMON_1: u64 = 0x0a82e883a194f07b;

// ---------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------

export var request_start_marker: RequestsStartMarker linksection(".limine_requests_start") = RequestsStartMarker{};
export var request_end_marker: RequestsEndMarker linksection(".limine_requests_end") = RequestsEndMarker{};

pub export var base_revision: BaseRevision linksection(".limine_requests") = .init(3);
pub export var hhdm_request: HhdmRequest linksection(".limine_requests") = HhdmRequest{};
pub export var memmap_request: MemmapRequest linksection(".limine_requests") = MemmapRequest{};
pub export var module_request: ModuleRequest linksection(".limine_requests") = ModuleRequest{};
pub export var framebuffer_request: FramebufferRequest linksection(".limine_requests") = FramebufferRequest{};
pub export var rsdp_request: RsdpRequest linksection(".limine_requests") = RsdpRequest{};
pub export var executable_address_request: ExecutableAddressRequest linksection(".limine_requests") = ExecutableAddressRequest{};

// ---------------------------------------------------------------------
// Base revision + requests delimiters
// ---------------------------------------------------------------------

/// Declare with e.g. `export var base_revision: limine.BaseRevision = .init(3);`
/// placed in `linksection(".requests")`.
pub const BaseRevision = extern struct {
    id: [3]u64,

    pub fn init(revision: u64) BaseRevision {
        return .{ .id = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, revision } };
    }

    /// The bootloader zeroes the 3rd component iff it honored the
    /// requested revision. Must be checked before using any other
    /// Limine feature.
    pub fn isSupported(self: *const volatile BaseRevision) bool {
        return self.id[2] == 0;
    }
};

pub const RequestsStartMarker = extern struct {
    id: [4]u64 = .{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 },
};

pub const RequestsEndMarker = extern struct {
    id: [2]u64 = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 },
};

// ---------------------------------------------------------------------
// HHDM (Higher Half Direct Map)
// ---------------------------------------------------------------------

pub const HhdmRequest = extern struct {
    id: [4]u64 = .{ COMMON_0, COMMON_1, 0x48dcf1cb8ad2b852, 0x63984e959a98244b },
    revision: u64 = 0,
    response: ?*const HhdmResponse = null,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

// ---------------------------------------------------------------------
// Framebuffer
// ---------------------------------------------------------------------

pub const FramebufferRequest = extern struct {
    id: [4]u64 = .{ COMMON_0, COMMON_1, 0x9d5827dcd881dd75, 0xa3148604f6fab11b },
    revision: u64 = 0,
    response: ?*const FramebufferResponse = null,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers_ptr: ?[*]*const Framebuffer,

    pub fn framebuffers(self: *const FramebufferResponse) []const *const Framebuffer {
        const ptr = self.framebuffers_ptr orelse return &.{};
        return ptr[0..self.framebuffer_count];
    }
};

pub const Framebuffer = extern struct {
    address: ?*anyopaque,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?*anyopaque,
    mode_count: u64,
    modes_ptr: ?[*]*const anyopaque,
};

// ---------------------------------------------------------------------
// Memory map
// ---------------------------------------------------------------------

pub const MemmapRequest = extern struct {
    id: [4]u64 = .{ COMMON_0, COMMON_1, 0x67cf3d9d378a806f, 0xe304acdfc50c3c62 },
    revision: u64 = 0,
    response: ?*const MemmapResponse = null,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries_ptr: ?[*]*const MemmapEntry,

    pub fn entries(self: *const MemmapResponse) []const *const MemmapEntry {
        const ptr = self.entries_ptr orelse return &.{};
        return ptr[0..self.entry_count];
    }
};

pub const MemmapType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: u64,
};

// ---------------------------------------------------------------------
// Modules (used here to load the userspace/kernelspace ELF payloads)
// ---------------------------------------------------------------------

pub const ModuleRequest = extern struct {
    id: [4]u64 = .{ COMMON_0, COMMON_1, 0x3e7e279702be32af, 0xca1c4f3bd1280cee },
    revision: u64 = 1,
    response: ?*const ModuleResponse = null,
    internal_module_count: u64 = 0,
    internal_modules: ?[*]*const InternalModule = null,
};

pub const InternalModule = extern struct {
    path: [*:0]const u8,
    cmdline: [*:0]const u8,
    flags: u64,
};

pub const ModuleResponse = extern struct {
    revision: u64,
    module_count: u64,
    modules_ptr: ?[*]*const File,

    pub fn modules(self: *const ModuleResponse) []const *const File {
        const ptr = self.modules_ptr orelse return &.{};
        return ptr[0..self.module_count];
    }
};

pub const Uuid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

pub const File = extern struct {
    revision: u64,
    address: ?*anyopaque,
    size: u64,
    path: [*:0]const u8,
    cmdline: [*:0]const u8,
    media_type: u32,
    unused: u32,
    tftp_ip: u32,
    tftp_port: u32,
    partition_index: u32,
    mbr_disk_id: u32,
    gpt_disk_uuid: Uuid,
    gpt_part_uuid: Uuid,
    part_uuid: Uuid,

    pub fn bytes(self: *const File) []const u8 {
        const ptr: [*]const u8 = @ptrCast(self.address.?);
        return ptr[0..self.size];
    }
};

// ---------------------------------------------------------------------
// RSDP (root of ACPI table discovery)
// ---------------------------------------------------------------------

pub const RsdpRequest = extern struct {
    id: [4]u64 = .{ COMMON_0, COMMON_1, 0xc5e77b6b397e7b43, 0x27637845accdcf3c },
    revision: u64 = 0,
    response: ?*const RsdpResponse = null,
};

pub const RsdpResponse = extern struct {
    revision: u64,
    /// Physical address, given base revision >= 3.
    address: u64,
};

// ---------------------------------------------------------------------
// Executable address (formerly "kernel address")
// ---------------------------------------------------------------------

pub const ExecutableAddressRequest = extern struct {
    id: [4]u64 = .{ COMMON_0, COMMON_1, 0x71ba76863cc55f63, 0xb2644a48c516a487 },
    revision: u64 = 0,
    response: ?*const ExecutableAddressResponse = null,
};

pub const ExecutableAddressResponse = extern struct {
    revision: u64,
    physical_base: u64,
    virtual_base: u64,
};
