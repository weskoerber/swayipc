const std = @import("std");
const swayipc = @import("swayipc");
const IpcConnection = swayipc.IpcConnection;

const version = "0.0.0";

pub const Args = struct {
    monitor: bool = false,
    pretty: bool = false,
    quiet: bool = false,
    raw: bool = false,
    socket: ?[]const u8 = null,
    type: swayipc.Message = .run_command,

    pub const strings = struct {
        pub const help: []const []const u8 = &.{ "-h", "--help" };
        pub const monitor: []const []const u8 = &.{ "-m", "--monitor" };
        pub const pretty: []const []const u8 = &.{ "-p", "--pretty" };
        pub const quiet: []const []const u8 = &.{ "-q", "--quiet" };
        pub const raw: []const []const u8 = &.{ "-r", "--raw" };
        pub const socket: []const []const u8 = &.{ "-s", "--socket" };
        pub const @"type": []const []const u8 = &.{ "-t", "--type" };
        pub const version: []const []const u8 = &.{ "-v", "--version" };
    };
};

pub const Result = struct {
    pub const success = 0;
    pub const connection_error = 1;
    pub const app_err = 2;
};

pub fn main(init: std.process.Init) !u8 {
    var arg_iter = init.minimal.args.iterate();
    defer arg_iter.deinit();
    _ = arg_iter.next();

    var args: Args = .{};

    var stderr_buf: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var sway_args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer sway_args.deinit(init.gpa);

    while (arg_iter.next()) |arg| {
        if (argIs(arg, Args.strings.help)) {
            usage(stderr, Result.connection_error);
        } else if (argIs(arg, Args.strings.monitor)) {
            args.monitor = true;
        } else if (argIs(arg, Args.strings.pretty)) {
            args.pretty = true;
        } else if (argIs(arg, Args.strings.quiet)) {
            args.quiet = true;
        } else if (argIs(arg, Args.strings.raw)) {
            args.raw = true;
        } else if (argIs(arg, Args.strings.socket)) {
            args.socket = arg_iter.next() orelse missingArgument(stderr, arg);
        } else if (argIs(arg, Args.strings.type)) {
            const type_str = arg_iter.next() orelse missingArgument(stderr, arg);
            const type_enum = std.meta.stringToEnum(swayipc.Message, type_str) orelse fatal(stderr, "Unknown message type '{s}'", .{type_str}, Result.connection_error);
            args.type = type_enum;
        } else if (argIs(arg, Args.strings.version)) {
            try stderr.print("swayipc version {s}\n", .{version});
            try stderr.flush();
            std.process.exit(Result.success);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            fatal(stderr, "swaymsg: unrecognized option '{s}'", .{arg}, Result.connection_error);
        } else {
            try sway_args.append(init.gpa, arg);
        }
    }

    if (args.monitor and args.type != .subscribe) {
        fatal(stderr, "Monitor can only be used with -t SUBSCRIBE", .{}, Result.connection_error);
    }

    const conn_options: swayipc.ConnectOptions = if (args.socket) |path|
        .{ .path = path }
    else
        .{ .env = init.environ_map };
    const ipc_stream = try swayipc.connect(conn_options, init.io);
    defer ipc_stream.close(init.io);

    var ipc_read_buf: [1024]u8 = undefined;
    var ipc_write_buf: [1024]u8 = undefined;
    var ipc_reader = ipc_stream.reader(init.io, &ipc_read_buf);
    var ipc_writer = ipc_stream.writer(init.io, &ipc_write_buf);

    var ipc = IpcConnection.init(&ipc_reader.interface, &ipc_writer.interface);

    const body = try std.mem.join(init.gpa, " ", sway_args.items);
    defer init.gpa.free(body);

    var stdout_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const pretty = (args.pretty or try std.Io.File.stdout().isTty(init.io)) and !args.quiet;

    if (pretty) switch (args.type) {
        .get_workspaces => {
            const workspaces = try ipc.getWorkspaces(init.gpa);
            defer workspaces.deinit();

            for (workspaces.value) |w| {
                try stdout.print(
                    \\Workspace {d} ({{t}})
                    \\  Output: {s}
                    \\  Layout: {{s}}
                    \\  Representation: {{s}}
                    \\
                    \\
                , .{ w.num, w.output });
            }
        },
        else => return error.TODO,
    } else {
        var reply = ipc.sendIpcMessage(init.gpa, args.type, body) catch |err| fatal(stderr, "IPC message error: '{t}'", .{err}, Result.app_err);
        defer reply.deinit(init.gpa);

        if (args.quiet) {
            return Result.success;
        }

        try stdout.writeAll(reply.body);
    }

    return Result.success;
}

fn argIs(arg: []const u8, matches: []const []const u8) bool {
    for (matches) |match| {
        if (std.mem.eql(u8, arg, match)) {
            return true;
        }
    }

    return false;
}

fn usage(stderr: *std.Io.Writer, code: u8) noreturn {
    const usage_str =
        \\Usage: swayipc [options] [message]
        \\
        \\  -h, --help             Show help message and quit.
        \\  -m, --monitor          Monitor until killed (-t SUBSCRIBE only)
        \\  -p, --pretty           Use pretty output even when not using a tty
        \\  -q, --quiet            Be quiet.
        \\  -r, --raw              Use raw output even if using a tty
        \\  -s, --socket <socket>  Use the specified socket.
        \\  -t, --type <type>      Specify the message type.
        \\  -v, --version          Show the version number and quit.
        \\
    ;
    stderr.writeAll(usage_str) catch {};
    stderr.flush() catch {};
    std.process.exit(code);
}

fn missingArgument(stderr: *std.Io.Writer, arg: []const u8) noreturn {
    stderr.print("swayipc: option '{s}' requires an argument\n", .{arg}) catch {};
    usage(stderr, Result.connection_error);
}

fn fatal(stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype, code: u8) noreturn {
    stderr.print(fmt ++ "\n", args) catch {};
    stderr.flush() catch {};
    std.process.exit(code);
}
