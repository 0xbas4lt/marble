const std = @import("std");

const arch = @import("arch.zig").current;
const Limine = @import("limine.zig");
const PhysicalMemoryManager = @import("PhysicalMemoryManager.zig");
const types = @import("types.zig");
const config = @import("config.zig");

// Zig built-ins
comptime {
    _ = @import("compiler_rt_patched");
}

const Gdt = arch.gdt.Gdt(arch);
const Error = struct {};

export fn _start() callconv(.c) noreturn {
    main() catch |err| switch (err) {
        // Error.OutOfMemory => @panic("out of memory"),
        // Error.NoUserspace => log.err("nothing to do: no programs provided. halting", .{}),
        // Error.InsufficientBootInfo => log.err("cannot boot: not enough bootloader data", .{}),
        // Error.MalformedUserspace => log.err("refusing to boot: malformed initial userspace program", .{}),
    };
    arch.halt();
}

fn main() !void {
    // serial.init();

    const limine = Limine.init() catch |err| switch (err) {
        Limine.Error.Unsupported => @panic("cannot boot: Limine version, or a requsted protocol is not supported"),
    };

    const pmm = initPmmWithLimine(limine.memmap, config.page_size, limine.hhdm_offset);
    _ = pmm;

    arch.init();

    var gdt = Gdt.init();
    gdt.load();
}

fn initPmmWithLimine(
    memory_map: *const Limine.MemmapResponse,
    page_size: usize,
    hhdm_offset: types.VirtAddr,
) PhysicalMemoryManager {
    var mem_top: types.PhysAddr = 0;
    for (memory_map.entries()) |entry| switch (entry.type) {
        .usable,
        .bootloader_reclaimable,
        => mem_top = std.mem.alignForward(
            types.PhysAddr,
            @max(mem_top, entry.base + @as(types.PhysAddr, entry.length)),
            page_size,
        ),
        else => {},
    };
    const backing_page_count = PhysicalMemoryManager.requiredBufferPageCount(mem_top, page_size);
    const backing_size = backing_page_count * page_size;

    const backing_physbase: types.PhysAddr =
        for (memory_map.entries()) |entry| {
            if (entry.type != .usable) continue;

            const base_align = std.mem.alignForward(
                types.PhysAddr,
                entry.base,
                @intCast(page_size),
            );
            const top_align = std.mem.alignBackward(
                types.PhysAddr,
                entry.base + @as(types.PhysAddr, entry.length),
                @intCast(page_size),
            );

            if (top_align <= base_align) continue;

            const range_align = top_align - base_align;
            const range_frame_count = range_align / page_size;

            if (range_frame_count >= backing_page_count) {
                break base_align;
            }
        } else @panic("cannot initialize pmm: out of memory");

    const backing_virtbase: types.VirtAddr = backing_physbase + hhdm_offset;

    const backing_ptr: [*]u8 = @ptrFromInt(backing_virtbase);
    const backing = backing_ptr[0..backing_size];

    var pmm = PhysicalMemoryManager.init(page_size, mem_top, hhdm_offset, backing);

    for (memory_map.entries()) |entry| if (entry.type == .usable)
        pmm.unlockMemoryRegion(entry.base, entry.length) catch
            @panic("cannot initialize pmm: untracked memory");

    pmm.lockPmmFrames();

    return pmm;
}
