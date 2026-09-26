const std = @import("std");
const serial = @import("serial.zig");
const arch = @import("arch/x86_64.zig");

const Self = @This();

var panic_depth: usize = 0;

fn serialPrint(
    comptime bufSize: usize,
    comptime fmt: []const u8,
    args: anytype,
) void {
    var fmt_buf: [bufSize]u8 = .{0} ** bufSize;
    const str = std.fmt.bufPrint(&fmt_buf, fmt, args) catch &fmt_buf;
    serial.writeString(str);
}

fn tryWritePanicToSerial(ret_addr: ?usize, msg: []const u8) void {
    if (panic_depth > 1) return;

    serial.writeString("\n[KERNEL PANIC]\n");
    serial.writeString(msg);
    serial.writeString("\n[STACK TRACE]\n");
    if (ret_addr) |addr| {
        Self.serialPrint(@sizeOf(usize) * 2 + 2, "0x{X:016}", .{addr});
        serial.writeString("\n");
    }

    var stack_trace_addrs: [16]usize = undefined;
    const stack_trace = std.debug.captureCurrentStackTrace(.{
        .first_address = ret_addr,
    }, &stack_trace_addrs);

    for (stack_trace.return_addresses) |addr| {
        Self.serialPrint(@sizeOf(usize) * 2 + 2, "0x{X:016}", .{addr});
        serial.writeString("\n");
    }
}

pub fn panicExtra(ret_addr: ?usize, comptime format: []const u8, args: anytype) noreturn {
    asm volatile ("cli");
    panic_depth += 1;

    var fmt_buf: [512]u8 = .{0} ** 512;
    const msg = std.fmt.bufPrint(&fmt_buf, format, args) catch &fmt_buf;

    tryWritePanicToSerial(ret_addr, msg);

    arch.halt();
}

pub fn call(
    msg: []const u8,
    first_trace_addr: ?usize,
) noreturn {
    asm volatile ("cli");
    panic_depth += 1;

    tryWritePanicToSerial(first_trace_addr, msg);

    arch.halt();
}

pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
    @branchHint(.cold);
    panicExtra(@returnAddress(), "sentinel mismatch: expected {any}, found {any}", .{
        expected, found,
    });
}
pub fn unwrapError(err: anyerror) noreturn {
    @branchHint(.cold);
    panicExtra(@returnAddress(), "attempt to unwrap error: {s}", .{@errorName(err)});
}
pub fn outOfBounds(index: usize, len: usize) noreturn {
    @branchHint(.cold);
    panicExtra(@returnAddress(), "index out of bounds: index {d}, len {d}", .{ index, len });
}
pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
    @branchHint(.cold);
    panicExtra(@returnAddress(), "start index {d} is larger than end index {d}", .{ start, end });
}
pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
    @branchHint(.cold);
    panicExtra(@returnAddress(), "access of union field '{s}' while field '{s}' is active", .{
        @tagName(accessed), @tagName(active),
    });
}
pub fn sliceCastLenRemainder(src_len: usize) noreturn {
    @branchHint(.cold);
    panicExtra(@returnAddress(), "slice length '{d}' does not divide exactly into destination elements", .{src_len});
}
pub fn reachedUnreachable() noreturn {
    @branchHint(.cold);
    call("reached unreachable code", @returnAddress());
}
pub fn unwrapNull() noreturn {
    @branchHint(.cold);
    call("attempt to use null value", @returnAddress());
}
pub fn castToNull() noreturn {
    @branchHint(.cold);
    call("cast causes pointer to be null", @returnAddress());
}
pub fn incorrectAlignment() noreturn {
    @branchHint(.cold);
    call("incorrect alignment", @returnAddress());
}
pub fn invalidErrorCode() noreturn {
    @branchHint(.cold);
    call("invalid error code", @returnAddress());
}
pub fn integerOutOfBounds() noreturn {
    @branchHint(.cold);
    call("integer does not fit in destination type", @returnAddress());
}
pub fn integerOverflow() noreturn {
    @branchHint(.cold);
    call("integer overflow", @returnAddress());
}
pub fn shlOverflow() noreturn {
    @branchHint(.cold);
    call("left shift overflowed bits", @returnAddress());
}
pub fn shrOverflow() noreturn {
    @branchHint(.cold);
    call("right shift overflowed bits", @returnAddress());
}
pub fn divideByZero() noreturn {
    @branchHint(.cold);
    call("division by zero", @returnAddress());
}
pub fn exactDivisionRemainder() noreturn {
    @branchHint(.cold);
    call("exact division produced remainder", @returnAddress());
}
pub fn integerPartOutOfBounds() noreturn {
    @branchHint(.cold);
    call("integer part of floating point value out of bounds", @returnAddress());
}
pub fn corruptSwitch() noreturn {
    @branchHint(.cold);
    call("switch on corrupt value", @returnAddress());
}
pub fn shiftRhsTooBig() noreturn {
    @branchHint(.cold);
    call("shift amount is greater than the type size", @returnAddress());
}
pub fn invalidEnumValue() noreturn {
    @branchHint(.cold);
    call("invalid enum value", @returnAddress());
}
pub fn forLenMismatch() noreturn {
    @branchHint(.cold);
    call("for loop over objects with non-equal lengths", @returnAddress());
}
pub fn copyLenMismatch() noreturn {
    @branchHint(.cold);
    call("source and destination arguments have non-equal lengths", @returnAddress());
}
pub fn memcpyAlias() noreturn {
    @branchHint(.cold);
    call("@memcpy arguments alias", @returnAddress());
}
pub fn noreturnReturned() noreturn {
    @branchHint(.cold);
    call("'noreturn' function returned", @returnAddress());
}
