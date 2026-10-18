comptime {
    _ = @import("compiler_rt_patched");
}

const COM1: u16 = 0x3f8;

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[ret]"
        : [ret] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

fn writeByte(b: u8) void {
    while ((inb(COM1 + 5) & 0x20) == 0) {}
    outb(COM1, b);
}

pub fn writeString(s: []const u8) void {
    for (s) |b| {
        if (b == '\n') writeByte('\r');
        writeByte(b);
    }
}

var foo: u8 = 12;
var foo_ptr = &foo;

export fn _start() callconv(.c) noreturn {
    foo = 10;
    writeByte(foo_ptr.*);
    writeString("Hello, World!");
    foo_ptr.* = '!';
    writeByte(foo_ptr.*);

    while (true) {}
}
