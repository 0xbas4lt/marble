const std = @import("std");
const types = @import("types.zig");
const vmm = @import("virtual_memory_manager.zig");

pub const Error = error{};

pub fn init(exec_info: *const types.ExecutableInfo) Error!void {
    _ = exec_info;
}
