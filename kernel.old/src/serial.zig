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

pub fn init() void {
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x80);
    outb(COM1 + 0, 0x03);
    outb(COM1 + 1, 0x00);
    outb(COM1 + 3, 0x03);
    outb(COM1 + 2, 0xc7);
    outb(COM1 + 4, 0x0b);
}
