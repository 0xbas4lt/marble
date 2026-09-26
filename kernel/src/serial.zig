//! COM1 serial output — the easiest way to get text out of the kernel
//! before you have a framebuffer console. QEMU maps this to stdio with
//! `-serial stdio` (see scripts/run.sh).
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

pub fn init() void {
    outb(COM1 + 1, 0x00); // disable interrupts
    outb(COM1 + 3, 0x80); // enable DLAB
    outb(COM1 + 0, 0x03); // divisor low byte -> 38400 baud
    outb(COM1 + 1, 0x00); // divisor high byte
    outb(COM1 + 3, 0x03); // 8 bits, no parity, one stop bit
    outb(COM1 + 2, 0xc7); // enable FIFO, clear, 14-byte threshold
    outb(COM1 + 4, 0x0b); // IRQs enabled, RTS/DSR set
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
