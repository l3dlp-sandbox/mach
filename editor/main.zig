//! Mach graphical editor and CLI tool
const std = @import("std");
const Io = std.Io;
const build_info = @import("build_info");

const usage =
    \\Usage: mach [command] [options]
    \\
    \\Commands:
    \\  version    Print Mach version information
    \\  help, -h   Print this help message
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) {
        try stderr.writeAll(usage);
        try stderr.flush();
        std.process.exit(1);
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "version")) {
        try stdout.print("mach {s}\n", .{build_info.mach_version});
        try stdout.print("zig  {s}\n", .{build_info.mach_zig_version});
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, cmd, "help") or
        std.mem.eql(u8, cmd, "-h") or
        std.mem.eql(u8, cmd, "--help"))
    {
        try stdout.writeAll(usage);
        try stdout.flush();
        return;
    }

    try stderr.print("mach: unknown command '{s}'\n\n", .{cmd});
    try stderr.writeAll(usage);
    try stderr.flush();
    std.process.exit(1);
}
