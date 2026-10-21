//!
//! X86_64 standard UART serial port driver implementation.
//!
//!  See https://wiki.osdev.org/Serial_Ports.
//! IO Port Offset   Setting of DLAB   I/O Access   Register mapped to this port
//! +0               0                 Read         Receive buffer.
//! +0               0                 Write        Transmit buffer.
//! +1               0                 Read/Write   Interrupt Enable Register.
//! +0               1                 Read/Write   With DLAB set to 1, this is the least significant byte of the divisor value for setting the baud rate.
//! +1               1                 Read/Write   With DLAB set to 1, this is the most significant byte of the divisor value.
//! +2               -                 Read         Interrupt Identification
//! +2               -                 Write        FIFO control registers
//! +3               -                 Read/Write   Line Control Register. The most significant bit of this register is the DLAB.
//! +4               -                 Read/Write   Modem Control Register.
//! +5               -                 Read         Line Status Register.
//! +6               -                 Read         Modem Status Register.
//! +7               -                 Read/Write   Scratch Register.

const std = @import("std");
const builtin = @import("builtin");
const KernelEventLogger = @import("KernelEventLogger.zig");

const SerialDriver = @This();

base_port: u16,
write_port_fn: *const fn (port: u16, value: u8) void,
read_port_fn: *const fn (port: u16) u8,
poll_timeout_count: usize = 0,
writer: std.Io.Writer,

const max_poll_attempt_count: usize = 100000;
const max_poll_timeout_count: usize = 10;

const LineControlRegister = packed struct(u8) {
    const DataBitsPerByte = enum(u2) {
        bits_5 = 0b00,
        bits_6 = 0b01,
        bits_7 = 0b10,
        bits_8 = 0b11,
    };

    const StopBits = enum(u1) {
        bits_1 = 0,
        bits_1f5_or_2 = 1,
    };

    const Parity = enum(u3) {
        none = 0b000,
        odd = 0b001,
        even = 0b011,
        mark = 0b101,
        space = 0b111,
    };

    /// The number of bits in a character.
    data_bits_per_byte: DataBitsPerByte,
    /// The serial controller can be configured to send a number of bits after each character of data.
    /// These reliable bits can be used to by the controller to verify that the sending and receiving devices are in phase.
    /// If the character length is specifically 5 bits, the stop bits can only be set to 1 or 1.5.
    /// For other character lengths, the stop bits can only be set to 1 or 2.
    stop_bits: StopBits,
    /// The controller can be made to add or expect a parity bit at the end of each character of data transmitted.
    /// With this parity bit, if a single bit of data is inverted by interference, a parity error can be raised.
    /// The parity type can be NONE, EVEN, ODD, MARK or SPACE.
    /// If parity is set to NONE, no parity bit will be added and none will be expected.
    /// If one is sent by the transmitter and not expected by the receiver, it will likely cause an error.
    /// If the parity is MARK or SPACE, the parity bit will be expected to be always set to 1 or 0 respectively.
    /// If the parity is set to EVEN or ODD, the controller calculates the accuracy of the parity by adding together the values of all the data bits and the parity bit.
    /// If the port is set to have EVEN parity, the result must be even. If it is set to have ODD parity, the result must be odd.
    parity: Parity,

    break_enable: u1,
    divisor_latch_access: u1,
};

const LineStatusRegister = packed struct(u8) {
    /// Set if there is data that can be read.
    data_ready: u1,
    /// Set if there has been data lost.
    overrun_error: u1,
    /// Set if there was an error in the transmission as detected by parity.
    parity_error: u1,
    /// Set if a stop bit was missing.
    framing_error: u1,
    /// Set if there is a break in data input.
    break_indicator: u1,
    /// Set if the transmission buffer is empty (i.e. data can be sent).
    transmitter_holding_register_empty: u1,
    /// Set if the transmitter is not doing anything.
    transmitter_empty: u1,
    /// Set if there is an error with a word in the input buffer.
    impending_error: u1,
};

const FifoControlRegister = packed struct(u8) {
    const InterruptTriggerLevel = enum(u2) {
        bytes_1 = 0b00,
        bytes_4 = 0b01,
        bytes_8 = 0b10,
        bytes_14 = 0b11,
    };

    enable_fifo: u1,
    /// Clear recieve fifo buffer. Self-resets.
    clear_recieve_fifo: u1,
    /// Clear transmit fifo buffer. Self-resets.
    clear_transmit_fifo: u1,
    dma_mode_select: u1,
    _reserved: u2 = 0,
    interrupt_trigger_level: InterruptTriggerLevel,
};

const ModemControlRegister = packed struct(u8) {
    data_terminal_ready: u1,
    request_to_send: u1,
    out_1: u1,
    out_2: u1,
    loop: u1,
    _reserved: u3 = 0,
};

const line_control_reg_dlab_unset = LineControlRegister{
    .break_enable = 0,
    .divisor_latch_access = 0,
    .data_bits_per_byte = .bits_8,
    .parity = .none,
    .stop_bits = .bits_1,
};

const line_control_reg_dlab_set = LineControlRegister{
    .break_enable = 0,
    .divisor_latch_access = 1,
    .data_bits_per_byte = .bits_8,
    .parity = .none,
    .stop_bits = .bits_1,
};

pub const Error = error{DeviceUnavailable};

const writer_vtable: std.Io.Writer.VTable = .{
    .drain = writerDrain,
};

pub fn init(
    base_port: u16,
    write_port_byte_fn: *const fn (port: u16, value: u8) void,
    read_port_byte_fn: *const fn (port: u16) u8,
) Error!SerialDriver {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => {},
        else => return Error.DeviceUnavailable,
    }

    var serial: SerialDriver = .{
        .read_port_fn = read_port_byte_fn,
        .write_port_fn = write_port_byte_fn,
        .base_port = base_port,
        .writer = .{
            .buffer = &.{},
            .vtable = &writer_vtable,
        },
    };

    if (!serial.setLineControlRegister(line_control_reg_dlab_unset))
        return Error.DeviceUnavailable;

    if (!serial.setInterruptEnableRegister(0))
        return Error.DeviceUnavailable;

    // Set baud rate to 115200 by setting the divisor.
    if (!serial.setLineControlRegister(line_control_reg_dlab_set))
        return Error.DeviceUnavailable;
    serial.write_port_fn(base_port, 1);
    serial.write_port_fn(base_port + 1, 0);
    if (!serial.setLineControlRegister(line_control_reg_dlab_unset))
        return Error.DeviceUnavailable;

    serial.setFifoControlRegister(.{
        .enable_fifo = 1,
        .clear_recieve_fifo = 1,
        .clear_transmit_fifo = 1,
        .dma_mode_select = 0,
        .interrupt_trigger_level = .bytes_1,
    });

    if (!serial.probe())
        return Error.DeviceUnavailable;

    return serial;
}

pub fn deinit(self: *SerialDriver) void {
    _ = self;
}

fn probe(self: *SerialDriver) bool {
    const test_byte: u8 = 0xAE;

    defer _ = self.setModemControlRegister(.{
        .data_terminal_ready = 1,
        .request_to_send = 1,
        .out_1 = 0,
        .out_2 = 0,
        .loop = 0,
    });

    if (!self.setModemControlRegister(.{
        .data_terminal_ready = 1,
        .request_to_send = 1,
        .out_1 = 0,
        .out_2 = 0,
        .loop = 1,
    })) return false;

    if (!self.writeByte(test_byte))
        return false;

    const byte = self.readByte() orelse return false;
    return byte == test_byte;
}

fn writeByte(self: *SerialDriver, value: u8) bool {
    for (0..max_poll_attempt_count) |_| {
        const line_status = self.readLineStatusRegister();
        if (line_status.transmitter_holding_register_empty == 0)
            continue;

        self.poll_timeout_count = 0;
        self.write_port_fn(self.base_port, value);
        return true;
    }
    self.poll_timeout_count += 1;
    return false;
}

fn readByte(self: *SerialDriver) ?u8 {
    for (0..max_poll_attempt_count) |_| {
        const line_status = self.readLineStatusRegister();
        if (line_status.data_ready == 0)
            continue;

        self.poll_timeout_count = 0;
        return self.read_port_fn(self.base_port);
    }
    self.poll_timeout_count += 1;
    return null;
}

/// Sets the line control register. Returns `true` on success, and `false` otherwise.
/// Register's state should be treated as unreliable, if `false` was returned.
fn setLineControlRegister(self: *SerialDriver, value: LineControlRegister) bool {
    const port = self.base_port + 3; // As noted above, +3 is the line control register offset.
    return self.setRegisterAndProbe(port, @backingInt(value));
}

/// Sets the interrupt enable register. Returns `true` on success, and `false` otherwise.
/// Register's state should be treated as unreliable, if `false` was returned.
fn setInterruptEnableRegister(self: *SerialDriver, value: u8) bool {
    const port = self.base_port + 1; // As noted above, +1 is the interrupt enable register offset.
    return self.setRegisterAndProbe(port, value);
}

/// Reads the line status register.
fn readLineStatusRegister(self: *SerialDriver) LineStatusRegister {
    const port = self.base_port + 5; // As noted above, +5 is the line status register offset.
    return @fromBackingInt(self.read_port_fn(port));
}

fn setModemControlRegister(self: *SerialDriver, value: ModemControlRegister) bool {
    const port = self.base_port + 4;
    return self.setRegisterAndProbe(port, @backingInt(value));
}

fn setFifoControlRegister(self: *SerialDriver, value: FifoControlRegister) void {
    const port = self.base_port + 2;
    self.write_port_fn(port, @backingInt(value));
}

fn setRegisterAndProbe(self: *SerialDriver, port: u16, value: u8) bool {
    self.write_port_fn(port, value);
    return self.read_port_fn(port) == value;
}

fn writerDrain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    const self: *SerialDriver = @alignCast(@fieldParentPtr("writer", io_w));
    if (self.poll_timeout_count >= max_poll_timeout_count)
        return std.Io.Writer.Error.WriteFailed;

    var total_written: usize = 0;

    for (data, 0..) |chunk, index| {
        const is_last = (index == data.len - 1);
        const iterations = if (is_last) splat else 1;

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            for (chunk) |byte| {
                if (byte == '\n' and !self.writeByte('\r'))
                    return total_written;
                if (!self.writeByte(byte))
                    return total_written;
                total_written += 1;
            }
        }
    }

    return total_written;
}

pub const KernelEventSink = struct {
    iter: KernelEventLogger.Iterator,
    driver: *SerialDriver,

    pub fn flush(self: *KernelEventSink) void {
        var record = self.iter.next();
        while (record) |r| : (record = self.iter.next()) {
            const severity = switch (r.tag.severity()) {
                .note => "NOTE",
                .debug => "DEBUG",
                .warning => "WARNING",
                .@"error" => "ERROR",
            };

            self.driver.writer.print("[0x{X}] {s}: {s}\n", .{ r.clock_count, severity, r.tag.string() }) catch {
                self.driver.writer.print("Kernel log event was skipped: sink error\n", .{}) catch {};
            };
        }
    }
};

pub fn initKernelEventSink(self: *SerialDriver, iter: KernelEventLogger.Iterator) KernelEventSink {
    return .{ .driver = self, .iter = iter };
}
