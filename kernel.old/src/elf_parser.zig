const std = @import("std");
const types = @import("types.zig");

//
// ELF64 execution layout:
//
// ElfIdent
// ELF64 header
// Program File Header
// Segments
// ...
// (Optional) Section header table
//
// See: https://github.com/torvalds/linux/blob/master/include/uapi/linux/elf.h
//      https://refspecs.linuxfoundation.org/elf/gabi4+/
//      https://refspecs.linuxfoundation.org/elf/gabi41.pdf
//

const Elf64Addr = u64;
const Elf64Half = u16;
const Elf64SHalf = i16;
const Elf64Off = u64;
const Elf64SWord = i32;
const Elf64Word = u32;
const Elf64XWord = u64;
const Elf64SXWord = i64;
const Elf64Versym = u16;

const magic_number: u32 = @bitCast([4]u8{ 0x7F, 'E', 'L', 'F' });

const EiClass = enum(u8) {
    /// Invalid class
    elf_class_none = 0,
    /// 32-bit objects
    elf_class_32 = 1,
    /// 64-bit objects
    elf_class_64 = 2,
    _,
};

const EiData = enum(u8) {
    /// Invalid data encoding
    elf_data_none = 0,
    elf_data_2_lsb = 1,
    elf_data_2_msb = 2,
    _,
};

/// Must be located at the very beginning of the file.
const ElfIdent = extern struct {
    /// File identification
    ei_mag: u32,
    /// File class
    ei_class: EiClass,
    /// Data encoding of the processor-specific data in the object file
    ei_data: EiData,
    /// Must match `ElfVersion.ev_current`
    ei_version: u8,
    ei_pad: [9]u8,
};

/// Must be located right before the `ElfIdent`.
const Elf64Ehdr = extern struct {
    /// Identifies the object file type.
    e_type: Elf64Half,
    /// specifies the required architecture for an individual file.
    e_machine: Elf64Half,
    /// Identifies the object file version. Must match `ElfVersion.ev_current`.
    e_version: Elf64Word,
    /// This member gives the virtual address to which the system first
    /// transfers control, thus starting the process. If the file has no
    /// associated entry point, this member holds zero.
    e_entry: Elf64Addr,
    /// This member holds the program header table’s file offset in bytes.
    /// If the file has no program header table, this member holds zero.
    e_phoff: Elf64Off,
    /// This member holds the section header table’s file offset in bytes. If
    /// the file has no section header table, this member holds zero.
    e_shoff: Elf64Off,
    /// Processor-specific flags associated with the file.
    /// Flag names take the form EF_machine_flag.
    /// See ‘‘Machine Information’’ in the processor supplement for flag definitions.
    e_flags: Elf64Word,
    /// ELF header’s size in bytes
    e_ehsize: Elf64Half,
    /// Size in bytes of one entry in the file’s program header table;
    /// all entries are the same size
    e_phentsize: Elf64Half,
    /// Number of entries in the program header table.
    /// Thus the product of e_phentsize and e_phnum gives the table’s size in bytes.
    /// If a file has no program header table, e_phnum holds the value zero.
    e_phnum: Elf64Half,
    /// Section header’s size in bytes. A section header is one entry in the section header table;
    /// all entries are the same size.
    e_shentsize: Elf64Half,
    /// The number of entries in the section header table.
    /// Thus the product of e_shentsize and e_shnum gives the section header table’s size in bytes.
    /// If a file has no section header table, e_shnum holds the value zero.
    e_shnum: Elf64Half,
    /// The section header table index of the entry associated with the section name string table.
    /// If the file has no section name string table, this member holds the value SHN_UNDEF.
    /// See ‘‘Sections’’ and ‘‘String Table’’ in docs.
    e_shstrndx: Elf64Half,
};

const ElfType = enum(u16) {
    /// No file type
    et_none = 0,
    /// Relocatable file
    et_rel = 1,
    /// Executable file
    et_exec = 2,
    /// Shared object file
    et_dyn = 3,
    /// Core file (reserved)
    et_core = 4,
    _,
    // /// Processor-specific (reserved)
    // et_elproc = 0xFF00,
    // /// Processor-specific (reserved)
    // et_hiproc = 0xFFFF,
};

const ElfMachine = enum(u16) {
    /// No machine
    em_none = 0,
    /// AT&T WE 32100
    em_m32 = 1,
    /// SPARC
    em_sparc = 2,
    /// Intel 80386
    em_386 = 3,
    /// Motorola 68000
    em_68k = 4,
    /// Motorola 88000
    em_88k = 5,
    /// Intel 80860
    em_860 = 7,
    /// MIPS I Architecture
    em_mips = 8,
    /// IBM System/370 Processor
    em_s370 = 9,
    /// MIPS RS3000 Little-endian
    em_mips_rs3_le = 10,
    /// Hewlett-Packard PA-RISC
    em_parisc = 15,
    /// Fujitsu VPP500
    em_vpp500 = 17,
    /// Enhanced instruction set SPARC
    em_sparc32plus = 18,
    /// Intel 80960
    em_960 = 19,
    /// PowerPC
    em_ppc = 20,
    /// 64-bit PowerPC
    em_ppc64 = 21,
    /// IBM System/390 Processor
    em_s390 = 22,
    /// NEC V800
    em_v800 = 36,
    /// Fujitsu FR20
    em_fr20 = 37,
    /// TRW RH-32
    em_rh32 = 38,
    /// Motorola RCE
    em_rce = 39,
    /// Advanced RISC Machines ARM
    em_arm = 40,
    /// Digital Alpha
    em_alpha = 41,
    /// Hitachi SH
    em_sh = 42,
    /// SPARC Version 9
    em_sparcv9 = 43,
    /// Siemens TriCore embedded processor
    em_tricore = 44,
    /// Argonaut RISC Core, Argonaut Technologies Inc.
    em_arc = 45,
    /// Hitachi H8/300
    em_h8_300 = 46,
    /// Hitachi H8/300H
    em_h8_300h = 47,
    /// Hitachi H8S
    em_h8s = 48,
    /// Hitachi H8/500
    em_h8_500 = 49,
    /// Intel IA-64 processor architecture
    em_ia_64 = 50,
    /// Stanford MIPS-X
    em_mips_x = 51,
    /// Motorola ColdFire
    em_coldfire = 52,
    /// Motorola M68HC12
    em_68hc12 = 53,
    /// Fujitsu MMA Multimedia Accelerator
    em_mma = 54,
    /// Siemens PCP
    em_pcp = 55,
    /// Sony nCPU embedded RISC processor
    em_ncpu = 56,
    /// Denso NDR1 microprocessor
    em_ndr1 = 57,
    /// Motorola Star*Core processor
    em_starcore = 58,
    /// Toyota ME16 processor
    em_me16 = 59,
    /// STMicroelectronics ST100 processor
    em_st100 = 60,
    /// Advanced Logic Corp. TinyJ embedded processor family
    em_tinyj = 61,
    /// AMD x86-64 architecture
    em_x86_64 = 62,
    /// Sony DSP Processor
    em_pdsp = 63,
    /// Digital Equipment Corp. PDP-10
    em_pdp10 = 64,
    /// Digital Equipment Corp. PDP-11
    em_pdp11 = 65,
    /// Siemens FX66 microcontroller
    em_fx66 = 66,
    /// STMicroelectronics ST9+ 8/16 bit microcontroller
    em_st9plus = 67,
    /// STMicroelectronics ST7 8-bit microcontroller
    em_st7 = 68,
    /// Motorola MC68HC16 Microcontroller
    em_68hc16 = 69,
    /// Motorola MC68HC11 Microcontroller
    em_68hc11 = 70,
    /// Motorola MC68HC08 Microcontroller
    em_68hc08 = 71,
    /// Motorola MC68HC05 Microcontroller
    em_68hc05 = 72,
    /// Silicon Graphics SVx
    em_svx = 73,
    /// STMicroelectronics ST19 8-bit microcontroller
    em_st19 = 74,
    /// Digital VAX
    em_vax = 75,
    /// Axis Communications 32-bit embedded processor
    em_cris = 76,
    /// Infineon Technologies 32-bit embedded processor
    em_javelin = 77,
    /// Element 14 64-bit DSP Processor
    em_firepath = 78,
    /// LSI Logic 16-bit DSP Processor
    em_zsp = 79,
    /// Donald Knuth's educational 64-bit processor
    em_mmix = 80,
    /// Harvard University machine-independent object files
    em_huany = 81,
    /// SiTera Prism
    em_prism = 82,
    /// Atmel AVR 8-bit microcontroller
    em_avr = 83,
    /// Fujitsu FR30
    em_fr30 = 84,
    /// Mitsubishi D10V
    em_d10v = 85,
    /// Mitsubishi D30V
    em_d30v = 86,
    /// NEC v850
    em_v850 = 87,
    /// Mitsubishi M32R
    em_m32r = 88,
    /// Matsushita MN10300
    em_mn10300 = 89,
    /// Matsushita MN10200
    em_mn10200 = 90,
    /// picoJava
    em_pj = 91,
    /// OpenRISC 32-bit embedded processor
    em_openrisc = 92,
    /// ARC Cores Tangent-A5
    em_arc_a5 = 93,
    /// Tensilica Xtensa Architecture
    em_xtensa = 94,
    /// Alphamosaic VideoCore processor
    em_videocore = 95,
    /// Thompson Multimedia General Purpose Processor
    em_tmm_gpp = 96,
    /// National Semiconductor 32000 series
    em_ns32k = 97,
    /// Tenor Network TPC processor
    em_tpc = 98,
    /// Trebia SNP 1000 processor
    em_snp1k = 99,
    /// STMicroelectronics (www.st.com) ST200 microcontroller
    em_st200 = 100,
    _,
};

/// See: https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html
const PType = enum(u32) {
    /// Array element is unused; other members' values are undefined. This type lets the program header table have ignored entries
    pt_null = 0,
    /// Array element specifies a loadable segment, described by p_filesz and p_memsz.
    /// The bytes from the file are mapped to the beginning of the memory segment.
    /// If the segment's memory size (p_memsz) is larger than the file size (p_filesz),
    /// the ``extra'' bytes are defined to hold the value 0 and to follow the segment's initialized area.
    /// The file size may not be larger than the memory size.
    /// Loadable segment entries in the program header table appear in ascending order, sorted on the p_vaddr member.
    pt_load = 1,
    pt_dynamic = 2,
    pt_interp = 3,
    pt_note = 4,
    pt_shlib = 5,
    pt_phdr = 6,
    pt_tls = 7,
    _,
    // pt_loos = 0x60000000,
    // pt_hios = 0x6FFFFFFF,
    // pt_loproc = 0x70000000,
    // pt_hiproc = 0x7FFFFFFF,
};

const Elf64Phdr = extern struct {
    /// Tells what kind of segment this array element describes or how to interpret the array element's information.
    /// See: https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html#p_type
    p_type: PType,
    /// See: https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html#p_flags.
    p_flags: Elf64Word,
    /// The offset from the beginning of the file at which the first byte of the segment resides.
    p_offset: Elf64Off,
    /// The virtual address at which the first byte of the segment resides in memory.
    p_vaddr: Elf64Addr,
    /// On systems for which physical addressing is relevant, this is reserved for the segment's physical address.
    /// Irrelevant for Marble.
    p_addr: Elf64Addr,
    /// The number of bytes in the file image of the segment. May be zero.
    p_filesz: Elf64XWord,
    /// The number of bytes in the memory image of the segment. May be zero.
    p_memsz: Elf64XWord,
    /// Loadable process segments must have congruent values for p_vaddr and p_offset, modulo the page size.
    /// This member gives the value to which the segments are aligned in memory and in the file.
    /// Values 0 and 1 mean no alignment is required. Otherwise, p_align should be a positive,
    /// integral power of 2, and p_vaddr should equal p_offset, modulo p_align.
    p_align: Elf64XWord,
};

/// Fits both in Elf32_Ehdr and Elf64_Ehdr
const ElfVersion = enum(u32) {
    /// Invalid version
    ev_none = 0,
    /// Current version
    ev_current = 1,
};

const DynTag = enum(Elf64SXWord) {
    /// d_un: ignored     | executable: mandatory   | shared object: mandatory
    DtNull = 0,
    /// d_un: d_val       | executable: optional    | shared object: optional
    DtNeeded = 1,
    /// d_un: d_val       | executable: optional    | shared object: optional
    DtPltrelsz = 2,
    /// d_un: d_ptr       | executable: optional    | shared object: optional
    DtPltgot = 3,
    /// d_un: d_ptr       | executable: mandatory   | shared object: mandatory
    DtHash = 4,
    /// d_un: d_ptr       | executable: mandatory   | shared object: mandatory
    DtStrtab = 5,
    /// d_un: d_ptr       | executable: mandatory   | shared object: mandatory
    DtSymtab = 6,
    /// d_un: d_ptr       | executable: mandatory   | shared object: optional
    DtRela = 7,
    /// d_un: d_val       | executable: mandatory   | shared object: optional
    DtRelasz = 8,
    /// d_un: d_val       | executable: mandatory   | shared object: optional
    DtRelaent = 9,
    /// d_un: d_val       | executable: mandatory   | shared object: mandatory
    DtStrsz = 10,
    /// d_un: d_val       | executable: mandatory   | shared object: mandatory
    DtSyment = 11,
    /// d_un: d_ptr       | executable: optional    | shared object: optional
    DtInit = 12,
    /// d_un: d_ptr       | executable: optional    | shared object: optional
    DtFini = 13,
    /// d_un: d_val       | executable: ignored     | shared object: optional
    DtSoname = 14,
    /// d_un: d_val       | executable: optional    | shared object: ignored
    /// Signifies an entry that is at level 2.
    DtRpath = 15,
    /// d_un: ignored     | executable: ignored     | shared object: optional
    /// Signifies an entry that is at level 2.
    DtSymbolic = 16,
    /// d_un: d_ptr       | executable: mandatory   | shared object: optional
    DtRel = 17,
    /// d_un: d_val       | executable: mandatory   | shared object: optional
    DtRelsz = 18,
    /// d_un: d_val       | executable: mandatory   | shared object: optional
    DtRelent = 19,
    /// d_un: d_val       | executable: optional    | shared object: optional
    DtPltrel = 20,
    /// d_un: d_ptr       | executable: optional    | shared object: ignored
    DtDebug = 21,
    /// d_un: ignored     | executable: optional    | shared object: optional
    /// Signifies an entry that is at level 2.
    DtTextrel = 22,
    /// d_un: d_ptr       | executable: optional    | shared object: optional
    DtJmprel = 23,
    /// d_un: ignored     | executable: optional    | shared object: optional
    /// Signifies an entry that is at level 2.
    DtBindNow = 24,
    /// d_un: d_ptr       | executable: optional    | shared object: optional
    DtInitArray = 25,
    /// d_un: d_ptr       | executable: optional    | shared object: optional
    DtFiniArray = 26,
    /// d_un: d_val       | executable: optional    | shared object: optional
    DtInitArraysz = 27,
    /// d_un: d_val       | executable: optional    | shared object: optional
    DtFiniArraysz = 28,
    /// d_un: d_val       | executable: optional    | shared object: optional
    DtRunpath = 29,
    /// d_un: d_val       | executable: optional    | shared object: optional
    DtFlags = 30,
    /// d_un: d_ptr       | executable: optional    | shared object: ignored
    DtPreinitArray = 32,
    /// d_un: d_val       | executable: optional    | shared object: ignored
    DtPreinitArraysz = 33,
    /// d_un: unspecified | executable: unspecified | shared object: unspecified
    DtLoos = 0x6000000D,
    /// d_un: unspecified | executable: unspecified | shared object: unspecified
    DtHios = 0x6ffff000,
    _,
};

const Elf64Dyn = extern struct {
    d_tag: Elf64SXWord,
    /// Can be interpreted in two ways:
    /// 1.
    ///    This object represents integer values (as `Elf64XWord`) with various interpretations.
    /// 2.
    ///    This object represents program virtual addresses.
    ///    A file's virtual addresses might not match the memory virtual addresses during execution.
    ///    When interpreting addresses contained in the dynamic structure (as `Elf64Addr`), the dynamic linker computes actual addresses,
    ///    based on the original file value and the memory base address.
    ///    For consistency, files do not contain relocation entries to "correct" addresses in the dynamic structure.
    d_un: Elf64XWord,
};

// const Elf64Rel = extern struct {
//     r_offset: Elf64Addr,
//     r_info: Elf64XWord,
// };
//
//

const RelTypeX86_64 = enum(u32) {
    /// field: none         ; Calculation: none
    r_x86_64_none = 0,
    /// field: word64       ; Calculation: S + A
    r_x86_64_64 = 1,
    /// field: word32       ; Calculation: S + A - P
    r_x86_64_pc32 = 2,
    /// field: word32       ; Calculation: G + A
    r_x86_64_got32 = 3,
    /// field: word32       ; Calculation: L + A - P
    r_x86_64_plt32 = 4,
    /// field: none         ; Calculation: none
    r_x86_64_copy = 5,
    /// field: wordclass    ; Calculation: S
    r_x86_64_glob_dat = 6,
    /// field: wordclass    ; Calculation: S
    r_x86_64_jump_slot = 7,
    /// field: wordclass    ; Calculation: B + A
    r_x86_64_relative = 8,
    /// field: word32       ; Calculation: G + GOT + A - P
    r_x86_64_gotpcrel = 9,
    /// field: word32       ; Calculation: S + A
    r_x86_64_32 = 10,
    /// field: word32       ; Calculation: S + A
    r_x86_64_32s = 11,
    /// field: word16       ; Calculation: S + A
    r_x86_64_16 = 12,
    /// field: word16       ; Calculation: S + A - P
    r_x86_64_pc16 = 13,
    /// field: word8        ; Calculation: S + A
    r_x86_64_8 = 14,
    /// field: word8        ; Calculation: S + A - P
    r_x86_64_pc8 = 15,
    /// field: word64       ; Calculation: unspecified
    r_x86_64_dtpmod64 = 16,
    /// field: word64       ; Calculation: unspecified
    r_x86_64_dtpoff64 = 17,
    /// field: word64       ; Calculation: unspecified
    r_x86_64_tpoff64 = 18,
    /// field: word32       ; Calculation: unspecified
    r_x86_64_tlsgd = 19,
    /// field: word32       ; Calculation: unspecified
    r_x86_64_tlsld = 20,
    /// field: word32       ; Calculation: unspecified
    r_x86_64_dtpoff32 = 21,
    /// field: word32       ; Calculation: unspecified
    r_x86_64_gottpoff = 22,
    /// field: word32       ; Calculation: unspecified
    r_x86_64_tpoff32 = 23,
    /// field: word64       ; Calculation: S + A - P
    r_x86_64_pc64 = 24,
    /// field: word64       ; Calculation: S + A - GOT
    r_x86_64_gotoff64 = 25,
    /// field: word32       ; Calculation: GOT + A - P
    r_x86_64_gotpc32 = 26,
    /// field: word32       ; Calculation: Z + A
    r_x86_64_size32 = 32,
    /// field: word64       ; Calculation: Z + A
    r_x86_64_size64 = 33,
    /// field: word32       ; Calculation: unspecified
    r_x86_64_gotpc32_tlsdesc = 34,
    /// field: none         ; Calculation: unspecified
    r_x86_64_tlsdesc_call = 35,
    /// field: word64×2     ; Calculation: unspecified
    r_x86_64_tlsdesc = 36,
    /// field: wordclass    ; Calculation: indirect (B + A)
    r_x86_64_irelative = 37,
    /// field: word64       ; Calculation: B + A
    r_x86_64_relative64 = 38,
    /// field: word32       ; Calculation: G + GOT + A - P
    r_x86_64_gotpcrelx = 41,
    /// field: word32       ; Calculation: G + GOT + A - P
    r_x86_64_rex_gotpcrelx = 42,
    _,
};

const Elf64RelaRInfo = packed struct(Elf64XWord) {
    rel_type: u32,
    symbol_index: u32,
};

const Elf64Rela = extern struct {
    r_offset: Elf64Addr,
    r_info: Elf64RelaRInfo,
    r_addend: Elf64SXWord,
};

const DtFlags = enum(u8) {
    DfOrigin = 0x1,
    DfSymbolic = 0x2,
    DfTextrel = 0x4,
    DfBindNow = 0x8,
    DfStaticTls = 0x10,
};

const Endianness = enum { little, big };
const WordWidth = enum { word_32, word_64 };

/// NOTE: UNION TYPES ARE NOT SUPPORTED
fn fixEndianness(comptime T: type, instance: *T, endianness: Endianness) void {
    const native_endian = @import("builtin").cpu.arch.endian();

    const needs_swap = (endianness == .little and native_endian == .big) or
        (endianness == .big and native_endian == .little);
    if (!needs_swap) return;

    inline for (std.meta.fields(T)) |field| {
        const field_ptr = &@field(instance.*, field.name);

        switch (@typeInfo(field.type)) {
            .int => |info| if (info.bits > 8) {
                field_ptr.* = @byteSwap(field_ptr.*);
            },
            .array => |info| {
                const element_info = @typeInfo(info.child);
                const elements_need_swap = switch (element_info) {
                    .int => |i| i.bits > 8,
                    .@"enum" => |e| @typeInfo(e.tag_type).int.bits > 8,
                    .@"struct" => true,
                    else => false,
                };
                if (elements_need_swap) {
                    for (field_ptr) |*element| {
                        fixEndianness(info.child, element, endianness);
                    }
                }
            },
            .@"enum" => |info| {
                const Tag = info.tag_type;
                const tag_info = @typeInfo(Tag).int;
                if (tag_info.bits > 8) {
                    const int_val = @intFromEnum(field_ptr.*);
                    const swapped = @byteSwap(int_val);
                    field_ptr.* = @enumFromInt(swapped);
                }
            },
            .@"struct" => {
                fixEndianness(field.type, field_ptr, endianness);
            },
            else => {},
        }
    }
}

fn tryParseTypeInstance(comptime T: type, bytes: []const u8, offset: usize, endianness: Endianness) ?T {
    const size = @sizeOf(T);
    if (size + offset > bytes.len) return null;
    const slice = bytes[offset .. offset + size];
    var instance: T = undefined;
    @memcpy(std.mem.asBytes(&instance), slice);
    fixEndianness(T, &instance, endianness);
    return instance;
}

pub const Error = error{
    InvalidFormat,
    Unsupported,
    OutOfMemory,
};

const ElfParser = @This();

allocator: std.mem.Allocator,
source: []const u8,
endianness: Endianness,
load_segments: std.ArrayList(types.ExecutableLoadSegment),
relocations: std.ArrayList(types.ExecutableRelocation),
load_bias_alignment: std.mem.Alignment,
is_entry_valid: bool,
ehdr_ptr: *const Elf64Ehdr,
pt_dynamic_entries: ?[]const u8,

fn parsePtLoad(self: *ElfParser, phdr_ptr: *const Elf64Phdr) Error!void {
    if (phdr_ptr.p_memsz == 0) return;

    const file_off: usize = @intCast(phdr_ptr.p_offset);
    const file_top = std.math.add(usize, file_off, phdr_ptr.p_filesz) catch
        return Error.InvalidFormat;
    if (file_top > self.source.len)
        return Error.InvalidFormat;
    const file_bytes = self.source[file_off..file_top];

    const mem_top = std.math.add(types.VirtAddr, phdr_ptr.p_vaddr, phdr_ptr.p_memsz) catch
        return Error.InvalidFormat;

    if (self.ehdr_ptr.e_entry >= phdr_ptr.p_vaddr and self.ehdr_ptr.e_entry < mem_top)
        self.is_entry_valid = true;

    if (phdr_ptr.p_filesz > phdr_ptr.p_memsz)
        return Error.InvalidFormat;

    if (phdr_ptr.p_align > 1 and phdr_ptr.p_vaddr % phdr_ptr.p_align != phdr_ptr.p_offset % phdr_ptr.p_align)
        return Error.InvalidFormat;

    // NOTE: IMPORTANT: The Sys V specs state that `p_align` **should** be a power of two (given it is bigger than 1),
    // but **NOT must**. This means that the current implementation may disgard some correct executable files.
    // This is the reason `Error.Unsupported` is returned instead of `Error.InvalidFormat`.
    if (phdr_ptr.p_align > 1) {
        if (!std.math.isPowerOfTwo(phdr_ptr.p_align))
            return Error.Unsupported;
        const alignment = std.mem.Alignment.fromByteUnits(@intCast(phdr_ptr.p_align));
        self.load_bias_alignment = self.load_bias_alignment.max(alignment);
    }

    self.load_segments.append(self.allocator, .{
        .src = file_bytes,
        .preferred_dest_begin = phdr_ptr.p_vaddr,
        .preferred_dest_end = mem_top,
    }) catch return Error.OutOfMemory;
}

fn recordPtDynamic(self: *ElfParser, phdr_ptr: *const Elf64Phdr) Error!void {
    const file_top = std.math.add(types.VirtAddr, phdr_ptr.p_offset, phdr_ptr.p_filesz) catch
        return Error.InvalidFormat;
    if (file_top > self.source.len)
        return Error.InvalidFormat;
    if (phdr_ptr.p_filesz == 0 or phdr_ptr.p_filesz % @sizeOf(Elf64Dyn) != 0)
        return Error.InvalidFormat;
    self.pt_dynamic_entries = self.source[phdr_ptr.p_offset..file_top];
}

fn parseDtRela(self: *ElfParser, rela: types.VirtAddr, relasz: usize, relaent: usize) Error!void {
    if (relaent != @sizeOf(Elf64Rela) or relasz % relaent != 0)
        return Error.InvalidFormat;
    const rela_table_virt_top: types.VirtAddr = std.math.add(types.VirtAddr, rela, relasz) catch
        return Error.InvalidFormat;
    var load_segment: types.ExecutableLoadSegment = undefined;
    var found_load_segment = false;
    for (self.load_segments.items) |segment| {
        if (rela < segment.preferred_dest_begin or rela_table_virt_top >= segment.preferred_dest_end)
            continue;
        found_load_segment = true;
        load_segment = segment;
        break;
    }
    if (!found_load_segment)
        return Error.InvalidFormat;

    const rela_entry_count = relasz / relaent;
    for (0..rela_entry_count) |i| {
        const segment_entry_off = i * @sizeOf(Elf64Rela);
        const rel_entry: Elf64Rela = tryParseTypeInstance(Elf64Rela, load_segment.src, segment_entry_off, self.endianness) orelse
            return Error.InvalidFormat;
        const rel_type: RelTypeX86_64 = @enumFromInt(rel_entry.r_info.rel_type);
        switch (rel_type) {
            .r_x86_64_relative => {},
            else => return Error.Unsupported,
        }
        if (rel_entry.r_info.symbol_index != 0)
            return Error.InvalidFormat;

        const preferred_target = std.math.cast(types.VirtAddr, rel_entry.r_addend) orelse
            return Error.InvalidFormat;

        self.relocations.append(
            self.allocator,
            .{
                .preferred_slot = rel_entry.r_offset,
                .preferred_target = preferred_target,
            },
        ) catch return Error.OutOfMemory;
    }
}

/// Must be called after all PT_LOADs have been parsed.
/// Doesn't do anything, if `self.pt_dynamic_entries` is not set. See `self.recordPtDynamic(...)`.
fn parsePtDynamic(self: *ElfParser) Error!void {
    if (self.pt_dynamic_entries == null)
        return;

    const dyn_entry_count: usize = self.pt_dynamic_entries.?.len / @sizeOf(Elf64Dyn);

    var rela: ?types.VirtAddr = null;
    var relasz: ?usize = null;
    var relaent: ?usize = null;

    var has_reached_dt_null = false;
    for (0..dyn_entry_count) |i| {
        const entry_off = i * @sizeOf(Elf64Dyn);
        const entry = tryParseTypeInstance(Elf64Dyn, self.pt_dynamic_entries.?, entry_off, self.endianness) orelse
            return Error.InvalidFormat;

        const d_tag: DynTag = @enumFromInt(entry.d_tag);
        switch (d_tag) {
            .DtNull => {
                has_reached_dt_null = true;
                break;
            },

            // Collect DT_RELA information.
            .DtRela => {
                if (rela != null)
                    return Error.InvalidFormat;
                rela = @as(types.VirtAddr, entry.d_un);
            },
            .DtRelasz => {
                if (relasz != null)
                    return Error.InvalidFormat;
                relasz = @as(usize, entry.d_un);
            },
            .DtRelaent => {
                if (relaent != null)
                    return Error.InvalidFormat;
                relaent = @as(usize, entry.d_un);
            },

            // Requires shared libraries.
            .DtNeeded => return Error.Unsupported,

            .DtTextrel => return Error.Unsupported,
            // .DtRelr => return Error.Unsupported,

            else => continue,
        }
    }

    if (!has_reached_dt_null)
        return Error.InvalidFormat;

    if (rela) |r| {
        if (relaent == null or relasz == null)
            return Error.InvalidFormat;
        try self.parseDtRela(r, relasz.?, relaent.?);
    }
}

fn deinit(self: *ElfParser) void {
    self.relocations.clearAndFree(self.allocator);
    self.load_segments.clearAndFree(self.allocator);
}

pub fn parse(allocator: std.mem.Allocator, source: []const u8) Error!types.ExecutableInfo {
    const elf_ident = tryParseTypeInstance(ElfIdent, source, 0, .little) orelse
        return Error.InvalidFormat;
    if (elf_ident.ei_mag != magic_number or
        elf_ident.ei_version != @intFromEnum(ElfVersion.ev_current))
        return Error.InvalidFormat;
    const endianness: Endianness = switch (elf_ident.ei_data) {
        .elf_data_none => return Error.InvalidFormat,
        .elf_data_2_lsb => .little,
        .elf_data_2_msb => .big,
        else => return Error.Unsupported,
    };
    const word_width: WordWidth = switch (elf_ident.ei_class) {
        .elf_class_none => return Error.InvalidFormat,
        .elf_class_32 => .word_32,
        .elf_class_64 => .word_64,
        else => return Error.Unsupported,
    };
    if (word_width != .word_64 or
        endianness != .little)
        return Error.Unsupported;

    const elf_ehdr_offset = @sizeOf(ElfIdent);
    const ehdr = tryParseTypeInstance(Elf64Ehdr, source, elf_ehdr_offset, endianness) orelse
        return Error.InvalidFormat;

    if (ehdr.e_version != @intFromEnum(ElfVersion.ev_current))
        return Error.InvalidFormat;

    const e_machine = std.enums.fromInt(ElfMachine, ehdr.e_machine) orelse
        return Error.Unsupported;
    if (e_machine != .em_x86_64)
        return Error.Unsupported;

    if (ehdr.e_phnum == 0 or
        ehdr.e_phoff == 0)
        return Error.Unsupported;

    if (ehdr.e_ehsize != @sizeOf(Elf64Ehdr) + @sizeOf(ElfIdent))
        return Error.InvalidFormat;

    if (ehdr.e_phentsize != @sizeOf(Elf64Phdr))
        return Error.InvalidFormat;

    const e_type = std.enums.fromInt(ElfType, ehdr.e_type) orelse
        return Error.Unsupported;
    if (e_type != .et_dyn)
        return Error.Unsupported;

    const prog_h_table_size = std.math.mul(usize, @sizeOf(Elf64Phdr), @as(usize, ehdr.e_phnum)) catch
        return Error.InvalidFormat;
    const prog_h_top_file_off = std.math.add(usize, @intCast(ehdr.e_phoff), prog_h_table_size) catch
        return Error.InvalidFormat;
    if (prog_h_top_file_off > source.len)
        return Error.InvalidFormat;

    var parse_state = ElfParser{
        .allocator = allocator,
        .ehdr_ptr = &ehdr,
        .endianness = endianness,
        .is_entry_valid = false,
        .load_bias_alignment = .@"1",
        .load_segments = .empty,
        .relocations = .empty,
        .source = source,
        .pt_dynamic_entries = null,
    };
    defer parse_state.deinit();

    var has_pt_dynamic = false;
    for (0..ehdr.e_phnum) |i| {
        // Calculations already validated in `prog_h_table_size` and `prog_h_top_file_off`.
        const phdr_off = @as(usize, ehdr.e_phoff) + @sizeOf(Elf64Phdr) * i;
        const phdr = tryParseTypeInstance(Elf64Phdr, source, phdr_off, endianness) orelse
            return Error.InvalidFormat;
        switch (phdr.p_type) {
            .pt_load => try parse_state.parsePtLoad(&phdr),
            .pt_dynamic => {
                if (has_pt_dynamic)
                    return Error.InvalidFormat;
                try parse_state.recordPtDynamic(&phdr);
                has_pt_dynamic = true;
            },
            .pt_interp => return Error.Unsupported,
            else => continue,
        }
    }

    if (!parse_state.is_entry_valid) return Error.InvalidFormat;

    try parse_state.parsePtDynamic();

    const load_segments = parse_state.load_segments.toOwnedSlice(allocator) catch
        return Error.OutOfMemory;
    errdefer allocator.free(load_segments);
    const relocations = parse_state.relocations.toOwnedSlice(allocator) catch
        return Error.OutOfMemory;
    errdefer allocator.free(relocations);

    return .{
        .allocator = allocator,
        .load_segments = load_segments,
        .entry_addr = ehdr.e_entry,
        .load_bias_alignment = parse_state.load_bias_alignment,
        .relocations = relocations,
    };
}
