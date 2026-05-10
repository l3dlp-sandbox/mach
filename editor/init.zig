//! `mach init` initializes a new Mach project in the current directory.
const std = @import("std");
const Io = std.Io;
const build_info = @import("build_info");

/// Files that are emitted verbatim from the editor/init-project/ template.
/// build.zig is special-cased separately so we can substitute the project name.
const verbatim_files = [_]struct { path: []const u8, contents: []const u8 }{
    .{ .path = "src/App.zig", .contents = @embedFile("init-project/src/App.zig") },
    .{ .path = "src/shader.wgsl", .contents = @embedFile("init-project/src/shader.wgsl") },
};

const build_zig_template = @embedFile("init-project/build.zig");
const build_zig_zon_template = @embedFile("init-project/build.zig.zon");

const usage =
    \\Usage: mach init
    \\
    \\Initializes a new Mach project in the current directory.
    \\The project name is taken from the current directory name.
    \\
;

pub fn run(
    io: Io,
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or
            std.mem.eql(u8, arg, "--help"))
        {
            try stdout.writeAll(usage);
            return;
        }
        try stderr.print("mach init: unrecognized argument '{s}'\n\n", .{arg});
        try stderr.writeAll(usage);
        std.process.exit(1);
    }

    // Determine the project name from the current working directory's basename,
    // sanitized to a valid Zig identifier.
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    const cwd_basename = std.fs.path.basename(cwd_path);
    const project_name = try sanitizeExampleName(arena, cwd_basename);

    // Generate a fingerprint matching what `zig init` would produce:
    //   id       = random u32 in [1, 0xffffffff)
    //   checksum = Crc32 of the package name
    const rng: std.Random.IoSource = .{ .io = io };
    const id = rng.interface().intRangeLessThan(u32, 1, 0xffffffff);
    const checksum = std.hash.Crc32.hash(project_name);
    const fingerprint: u64 =
        (@as(u64, checksum) << 32) | @as(u64, id);

    const cwd = Io.Dir.cwd();

    // Refuse to clobber existing files in the current directory.
    const all_files = [_][]const u8{ "build.zig", "build.zig.zon", "src/App.zig", "src/shader.wgsl" };
    for (all_files) |path| {
        if (cwd.access(io, path, .{})) |_| {
            try stderr.print("mach init: refusing to overwrite existing file '{s}'\n", .{path});
            std.process.exit(1);
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }
    }

    // Write build.zig (substitute the placeholder binary name "hello-world" with the project name).
    const build_zig_contents = try std.mem.replaceOwned(
        u8,
        arena,
        build_zig_template,
        "hello-world",
        project_name,
    );
    try writeFile(io, cwd, "build.zig", build_zig_contents);
    try stdout.print("created build.zig\n", .{});

    // Generate build.zig.zon by performing substitutions on the embedded template.
    const mach_url = try std.fmt.allocPrint(
        arena,
        "https://pkg.hexops.org/pkg/hexops/mach/{s}.tar.gz",
        .{build_info.mach_version},
    );
    const zon_contents = try substituteZonTemplate(arena, build_zig_zon_template, .{
        .project_name = project_name,
        .fingerprint = fingerprint,
        .mach_url = mach_url,
    });
    try writeFile(io, cwd, "build.zig.zon", zon_contents);
    try stdout.print("created build.zig.zon\n", .{});

    // Write the verbatim source files.
    cwd.createDirPath(io, "src") catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    for (verbatim_files) |f| {
        try writeFile(io, cwd, f.path, f.contents);
        try stdout.print("created {s}\n", .{f.path});
    }

    // Run `zig fetch --save=mach <url>` so the mach dependency in
    // build.zig.zon ends up with a proper .hash field. Stdio is inherited so
    // the user sees zig's progress / any errors directly.
    const fetch_argv = [_][]const u8{ "zig", "fetch", "--save=mach", mach_url };
    try stdout.print("running $ zig fetch --save=mach {s}\n", .{mach_url});
    try stdout.flush();

    var child = std.process.spawn(io, .{ .argv = &fetch_argv }) catch |err| {
        try stderr.print(
            "mach init: failed to spawn `zig fetch`: {t}\nMake sure `zig` is in your PATH and re-run:\n  $ zig fetch --save=mach {s}\n",
            .{ err, mach_url },
        );
        std.process.exit(1);
    };
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            try stderr.print("mach init: `zig fetch` exited with code {d}\n", .{code});
            std.process.exit(1);
        },
        else => {
            try stderr.print("mach init: `zig fetch` terminated abnormally\n", .{});
            std.process.exit(1);
        },
    }

    try stdout.print(
        \\
        \\Created Mach project "{s}".
        \\
        \\Run the project:
        \\
        \\  $ zig build run
        \\
        \\
    , .{project_name});
}

fn writeFile(io: Io, dir: Io.Dir, sub_path: []const u8, contents: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = contents });
}

const ZonSubstitutions = struct {
    project_name: []const u8,
    fingerprint: u64,
    mach_url: []const u8,
};

/// Performs the small set of fixed substitutions on the embedded editor/init-project/build.zig.zon
/// template file needed to turn it into the project's actual build.zig.zon file.
fn substituteZonTemplate(
    arena: std.mem.Allocator,
    template: []const u8,
    subs: ZonSubstitutions,
) ![]const u8 {
    const new_name = try std.fmt.allocPrint(arena, ".name = .{s},", .{subs.project_name});
    const new_fingerprint = try std.fmt.allocPrint(arena, ".fingerprint = 0x{x},", .{subs.fingerprint});
    const new_mach_dep = try std.fmt.allocPrint(arena, ".url = \"{s}\",", .{subs.mach_url});

    const after_name = try replaceExpected(arena, template, ".name = .init_project,", new_name);
    const after_fp = try replaceExpected(arena, after_name, ".fingerprint = 0x72e87e5112345678,", new_fingerprint);
    return try replaceExpected(arena, after_fp, ".path = \"../..\",", new_mach_dep);
}

/// Like `std.mem.replaceOwned`, but errors out if `needle` does not appear exactly once in
/// `haystack`.
fn replaceExpected(
    arena: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]const u8 {
    const count = std.mem.count(u8, haystack, needle);
    if (count != 1) {
        std.log.err(
            "mach init: expected to find substring '{s}' exactly once in the embedded build.zig.zon template, but found it {d} times",
            .{ needle, count },
        );
        return error.InitTemplateMalformed;
    }
    return std.mem.replaceOwned(u8, arena, haystack, needle, replacement);
}

// Borrowed from 'zig init'
fn sanitizeExampleName(arena: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]const u8 {
    const max_name_len = 32;
    var result: std.ArrayList(u8) = .empty;
    for (bytes, 0..) |byte, i| switch (byte) {
        '0'...'9' => {
            if (i == 0) try result.append(arena, '_');
            try result.append(arena, byte);
        },
        '_', 'a'...'z', 'A'...'Z' => try result.append(arena, byte),
        '-', '.', ' ' => try result.append(arena, '_'),
        else => continue,
    };
    if (!std.zig.isValidId(result.items)) return "foo";
    if (result.items.len > max_name_len)
        result.shrinkRetainingCapacity(max_name_len);

    return result.toOwnedSlice(arena);
}
