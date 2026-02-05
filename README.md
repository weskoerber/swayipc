# swayipc

A Sway IPC client implementation.

## Usage

```zig
const std = @import("std");
const swayipc = @import("swayipc");
const IpcConnection = swayipc.IpcConnection;
const IpcPayload = swayipc.IpcPayload;

pub fn main(init: std.process.Init) !void {
    // 1. Connect to the socket at $SWAYSOCK.
    const ipc_stream = try swayipc.connect(.{ .env = init.environ_map }, init.io);
    defer ipc_stream.close(init.io);

    // 2. Create a socket reader and writer.
    var ipc_read_buf: [1024]u8 = undefined;
    var ipc_write_buf: [1024]u8 = undefined;
    var ipc_reader = ipc_stream.reader(init.io, &ipc_read_buf);
    var ipc_writer = ipc_stream.writer(init.io, &ipc_write_buf);

    // 2. Initialize the connection wrapper.
    var ipc = IpcConnection.init(&ipc_reader.interface, &ipc_writer.interface);

    // 3. Send IPC messages.
    const version = try ipc.getVersion(init.gpa);
    defer version.deinit();
    std.debug.print("sway version: {s}\n", .{version.value.human_readable});

    // 4. Subscribe to events.
    // 4a. Define events to subscribe.
    const events: []const IpcPayload.Event = &.{ .workspace, .tick };

    // 4b. Define event handlers.
    const handlers: IpcConnection.EventHandlers = .{
        .default = handleEvent,
        .tick = handleTickEvent,
    };

    // 4c. Send the subscribe IPC message.
    try ipc.subscribe(init.gpa, events, handlers);
}

fn handleEvent(gpa: std.mem.Allocator, event: swayipc.IpcPayload.Event, body: []const u8) bool {
    _ = gpa;
    _ = body;

    std.log.warn("unhandled event: '{t}'", .{event});

    return true;
}

fn handleTickEvent(tick: swayipc.events.Tick) bool {
    return !std.mem.eql(u8, tick.payload, "HUP");
}
```
