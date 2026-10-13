const std = @import("std");
const config = @import("config.zig");

const RingBuffer = struct {
    interface: std.Io.Writer,
    backing: [config.log_buffer_size_bytes]u8,
    cursor: usize,

    inline fn writeByte(self: *RingBuffer, byte: u8) void {
        self.backing[self.cursor] = byte;
        self.cursor = (self.cursor + 1) % self.backing.len;
    }

    inline fn writeBytes(self: *RingBuffer, bytes: []const u8) void {
        for (bytes) |b| self.writeByte(b);
    }

    inline fn writeSeparator(self: *RingBuffer) void {
        self.writeByte(0);
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        if (data.len == 0) return std.Io.Writer.Error.WriteFailed;
        const self: *RingBuffer = @fieldParentPtr("interface", w);

        const staging = w.buffer[0..w.end];
        self.writeBytes(staging);
        w.end = 0;

        var written_count = staging.len;

        for (data[0 .. data.len - 1]) |bytes| {
            self.writeBytes(bytes);
            written_count += bytes.len;
        }
        const splat_bytes = data[data.len - 1];
        for (0..splat) |_| self.writeBytes(splat_bytes);
        written_count += splat_bytes.len * splat;

        return written_count;
    }
};

const buffer_vtable = std.Io.Writer.VTable{ .drain = RingBuffer.drain };
var buffer: RingBuffer = .{
    .backing = .{0} ** config.log_buffer_size_bytes,
    .cursor = 0,
    .interface = .{
        .vtable = &buffer_vtable,
        .buffer = &.{},
    },
};

const SerialWriter = struct {
    interface: std.Io.Writer,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const serial = @import("serial.zig");

        if (data.len == 0) return std.Io.Writer.Error.WriteFailed;

        const staging = w.buffer[0..w.end];
        serial.writeString(staging);
        w.end = 0;

        var written_count = staging.len;

        for (data[0 .. data.len - 1]) |bytes| {
            serial.writeString(bytes);
            written_count += bytes.len;
        }
        const splat_bytes = data[data.len - 1];
        for (0..splat) |_| serial.writeString(splat_bytes);
        written_count += splat_bytes.len * splat;

        return written_count;
    }
};

const serial_vtable: std.Io.Writer.VTable = .{ .drain = SerialWriter.drain };
var serial_writer: SerialWriter = .{ .interface = .{ .vtable = &serial_vtable, .buffer = &.{} } };

const sinks: [2]*std.Io.Writer = .{ &buffer.interface, &serial_writer.interface };

fn sinkWriteBytes(bytes: []const u8) void {
    for (sinks) |sink| sink.writeAll(bytes) catch {};
}

fn sinkWriteByte(byte: u8) void {
    for (sinks) |sink| sink.writeByte(byte) catch {};
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    for (sinks) |sink| sink.print(fmt, args) catch {};
    buffer.writeSeparator();
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    sinkWriteBytes("INFO: ");
    print(fmt, args);
    sinkWriteByte('\n');
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    sinkWriteBytes("WANR: ");
    print(fmt, args);
    sinkWriteByte('\n');
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    sinkWriteBytes("ERROR: ");
    print(fmt, args);
    sinkWriteByte('\n');
}
