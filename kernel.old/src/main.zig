const std = @import("std");
const log = @import("log.zig");
const limine = @import("limine.zig");
const serial = @import("serial.zig");
const config = @import("config.zig");
const types = @import("types.zig");
const gdt = @import("arch/gdt.zig");
const idt = @import("arch/idt.zig");
const arch = @import("arch/x86_64.zig");
const elf_parser = @import("elf_parser.zig");
const executable_loader = @import("executable_loader.zig");

const PhysicalMemoryManager = @import("physical_memory_manager.zig");
const VirtualMemoryManager = @import("virtual_memory_manager.zig");
const KAlloc = @import("kernel_allocator.zig");

pub const panic = @import("panic.zig");
pub const std_options_debug_io: std.Io = std.Io.failing;

fn no_userspace_halt() noreturn {
    log.err("nothing to do: no userspace provided. halting.", .{});
    arch.halt();
}

const Error = error{
    OutOfMemory,
    InsufficientBootInfo,
    NoUserspace,
    MalformedUserspace,
};

fn main() Error!void {
    if (!limine.base_revision.isSupported()) arch.halt();

    serial.init();
    log.info("boot finished; initializing", .{});

    var hhdm_offset: types.PhysAddr = undefined;

    if (limine.hhdm_request.response) |resp| {
        hhdm_offset = @as(types.PhysAddr, resp.offset);
    } else return Error.InsufficientBootInfo;

    var kernel_physical_base: types.PhysAddr = undefined;
    var kernel_virtual_base: types.VirtAddr = undefined;
    if (limine.executable_address_request.response) |resp| {
        kernel_physical_base = resp.physical_base;
        kernel_virtual_base = resp.virtual_base;
    } else return Error.InsufficientBootInfo;

    var memmap: *const limine.MemmapResponse = undefined;
    if (limine.memmap_request.response) |resp| {
        memmap = resp;
    } else return Error.InsufficientBootInfo;

    var module_response: *const limine.ModuleResponse = undefined;
    if (limine.module_request.response) |resp| {
        module_response = resp;
    } else return Error.NoUserspace;
    if (module_response.module_count == 0) return Error.NoUserspace;

    var pmm = PhysicalMemoryManager.init(hhdm_offset, memmap, kernel_physical_base);
    log.info("pmm initialized", .{});

    // Lock crucial frames
    for (memmap.entries()) |entry| {
        if (entry.type != @intFromEnum(limine.MemmapType.executable_and_modules)) continue;
        const base = std.mem.alignBackward(types.PhysAddr, entry.base, config.page_size_bytes);
        const pages: usize = @intCast(std.mem.alignForward(types.PhysAddr, entry.length, config.page_size_bytes) / config.page_size_bytes);
        for (0..pages) |i| pmm.lockFrame(pmm.frameFromPhysBase(base + i * config.page_size_bytes));
    }

    var vmm = VirtualMemoryManager.init(&pmm, kernel_virtual_base);
    log.info("vmm initialized", .{});

    gdt.init();
    log.info("gdt initialized", .{});

    idt.init();
    log.info("idt initialized", .{});

    var kalloc: KAlloc = undefined;
    kalloc.init(&pmm, &vmm);
    defer kalloc.deinit();
    const allocator = kalloc.allocator();
    log.info("allocator intialized", .{});
    _ = allocator.alloc(u8, 1200) catch
        log.err("couldn't allocate 1200 bytes", .{});
    log.info("attempted to allocate 1200 bytes", .{});
    _ = allocator.alloc(u8, 13245) catch
        log.err("couldn't allocate 13245 bytes", .{});
    log.info("attempted to allocate 13245 bytes", .{});

    // const BootProgram = struct {
    //     cmdline: ?[]const u8 = null,
    //     limine_path: ?[]const u8 = null,
    //     bytes: []const u8,
    //     parsed_executable_info: ?types.ExecutableInfo = null,
    // };

    // var boot_programs = allocator.alloc(BootProgram, module_response.module_count) catch
    //     return Error.OutOfMemory;
    // for (module_response.modules(), 0..) |mod, i| {
    //     if (@intFromPtr(mod.cmdline) != 0) {
    //         const bootloader_mem_str: []const u8 = std.mem.span(mod.cmdline);
    //         const str = allocator.alloc(u8, bootloader_mem_str.len) catch
    //             return Error.OutOfMemory;
    //         @memcpy(str, bootloader_mem_str);
    //         boot_programs[i].cmdline = str;
    //     }

    //     if (@intFromPtr(mod.path) != 0) {
    //         const bootloader_mem_str: []const u8 = std.mem.span(mod.path);
    //         const str = allocator.alloc(u8, bootloader_mem_str.len) catch
    //             return Error.OutOfMemory;
    //         @memcpy(str, bootloader_mem_str);
    //         boot_programs[i].limine_path = str;
    //     }

    //     boot_programs[i].bytes = mod.bytes();
    // }
    // defer {
    //     for (boot_programs) |p| {
    //         if (p.cmdline) |a| allocator.free(a);
    //         if (p.limine_path) |a| allocator.free(a);
    //     }
    // }

    // // Reclaim the bootloader memory
    // for (memmap.entries()) |entry| {
    //     if (entry.type != @intFromEnum(limine.MemmapType.bootloader_reclaimable)) continue;
    //     const base = std.mem.alignBackward(types.PhysAddr, entry.base, config.page_size_bytes);
    //     const pages: usize = @intCast(std.mem.alignForward(types.PhysAddr, entry.length, config.page_size_bytes) / config.page_size_bytes);
    //     for (0..pages) |i| pmm.freeFrame(pmm.frameFromPhysBase(base + i * config.page_size_bytes));
    // }

    // for (boot_programs) |*prog| {
    //     const name = prog.limine_path orelse "unknown";
    //     if (elf_parser.parse(allocator, prog.bytes)) |parsed| {
    //         prog.parsed_executable_info = parsed;
    //         log.info("parsed `{s}`", .{name});
    //     } else |err| {
    //         prog.parsed_executable_info = null;
    //         switch (err) {
    //             elf_parser.Error.InvalidFormat => log.err("unable to parse `{s}`: invalid format", .{name}),
    //             elf_parser.Error.Unsupported => log.err("unable to parse `{s}`: unsupported", .{name}),
    //             elf_parser.Error.OutOfMemory => return Error.OutOfMemory,
    //         }
    //     }
    // }
    // defer for (boot_programs) |*p|
    //     if (p.parsed_executable_info) |*pei|
    //         pei.deinit();

    // var loaded_executable = executable_loader.load(
    //     &pmm,
    //     &vmm,
    //     allocator,
    //     &boot_programs[0].parsed_executable_info.?,
    // ) catch |err| switch (err) {
    //     executable_loader.Error.InvalidAddress => {
    //         log.err("unable to load `{s}`: invalid virtual address", .{boot_programs[0].limine_path.?});
    //         return Error.MalformedUserspace;
    //     },
    //     executable_loader.Error.OutOfMemory => return Error.OutOfMemory,
    // };
    // errdefer loaded_executable.deinit();
    // log.info("loaded executable", .{});

    // const executableEnter: *fn () callconv(.c) void = @ptrFromInt(loaded_executable.entry_addr);
    // executableEnter();

    log.info("exiting.", .{});
}

export fn _start() callconv(.c) noreturn {
    main() catch |err| switch (err) {
        Error.OutOfMemory => @panic("out of memory"),
        Error.NoUserspace => log.err("nothing to do: no programs provided. halting", .{}),
        Error.InsufficientBootInfo => log.err("cannot boot: not enough bootloader data", .{}),
        Error.MalformedUserspace => log.err("refusing to boot: malformed initial userspace program", .{}),
    };
    arch.halt();
}
