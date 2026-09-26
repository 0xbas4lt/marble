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

const Endianness = enum { little, big };
const WordWidth = enum { word_32, word_64 };

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

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!types.ExecutableInfo {
    const elf_ident = tryParseTypeInstance(ElfIdent, bytes, 0, .little) orelse
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
    const elf_ehdr = tryParseTypeInstance(Elf64Ehdr, bytes, elf_ehdr_offset, endianness) orelse
        return Error.InvalidFormat;

    if (elf_ehdr.e_version != @intFromEnum(ElfVersion.ev_current))
        return Error.InvalidFormat;

    const e_machine = std.enums.fromInt(ElfMachine, elf_ehdr.e_machine) orelse
        return Error.Unsupported;
    if (e_machine != .em_x86_64)
        return Error.Unsupported;

    if (elf_ehdr.e_phnum == 0 or
        elf_ehdr.e_phoff == 0)
        return Error.Unsupported;

    if (elf_ehdr.e_ehsize != @sizeOf(Elf64Ehdr) + @sizeOf(ElfIdent))
        return Error.InvalidFormat;

    if (elf_ehdr.e_phentsize != @sizeOf(Elf64Phdr))
        return Error.InvalidFormat;

    const prog_h_table_size = std.math.mul(usize, @sizeOf(Elf64Phdr), @as(usize, elf_ehdr.e_phnum)) catch
        return Error.InvalidFormat;
    const prog_h_top_file_off = std.math.add(usize, @intCast(elf_ehdr.e_phoff), prog_h_table_size) catch
        return Error.InvalidFormat;
    if (prog_h_top_file_off > bytes.len)
        return Error.InvalidFormat;

    var load_segments: std.ArrayList(types.ExecutableLoadSegment) = .empty;
    errdefer load_segments.clearAndFree(allocator);

    var is_entry_valid = false;
    for (0..elf_ehdr.e_phnum) |i| {
        // Calculations already validated in `prog_h_table_size` and `prog_h_top_file_off`.
        const header_off = @as(usize, elf_ehdr.e_phoff) + @sizeOf(Elf64Phdr) * i;
        const header = tryParseTypeInstance(Elf64Phdr, bytes, header_off, endianness) orelse
            return Error.InvalidFormat;
        switch (header.p_type) {
            .pt_load => {},
            .pt_interp => return Error.Unsupported,
            else => continue,
        }

        if (header.p_memsz == 0) continue;

        const file_off: usize = @intCast(header.p_offset);
        const file_top = std.math.add(usize, file_off, header.p_filesz) catch
            return Error.InvalidFormat;
        if (file_top > bytes.len)
            return Error.InvalidFormat;
        const file_bytes = bytes[file_off..file_top];

        const mem_top = std.math.add(types.VirtAddr, header.p_vaddr, header.p_memsz) catch
            return Error.InvalidFormat;

        if (elf_ehdr.e_entry >= header.p_vaddr and elf_ehdr.e_entry <= mem_top)
            is_entry_valid = true;

        if (header.p_filesz > header.p_memsz)
            return Error.InvalidFormat;

        load_segments.append(allocator, .{
            .src = file_bytes,
            .dest_begin = header.p_vaddr,
            .dest_end = mem_top,
        }) catch return Error.OutOfMemory;
    }

    if (!is_entry_valid) return Error.InvalidFormat;

    const load_segments_slice = load_segments.toOwnedSlice(allocator) catch
        return Error.OutOfMemory;
    errdefer allocator.free(load_segments_slice);

    return .{
        .allocator = allocator,
        .load_segments = load_segments_slice,
        .entry_addr = elf_ehdr.e_entry,
    };
}
