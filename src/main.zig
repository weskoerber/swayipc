const std = @import("std");
const swayipc = @import("swayipc");
const replies = swayipc.replies;
const events = swayipc.events;

pub fn main(init: std.process.Init) !void {
    const stream = try swayipc.connect(.{ .env = init.environ_map }, init.io);
    defer stream.close(init.io);

    var read_buf: [1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;

    var stream_reader = stream.reader(init.io, &read_buf);
    var stream_writer = stream.writer(init.io, &write_buf);

    var conn: swayipc.IpcConnection = .init(&stream_reader.interface, &stream_writer.interface);

    // RUN_COMMAND
    // {
    //     const reply = try conn.runCommand(init.gpa, "border toggle");
    //     defer reply.deinit(init.gpa);
    //
    //     const result = try std.json.parseFromSlice([]const replies.CommandResult, init.gpa, reply.body, json_opts);
    //     defer result.deinit();
    // }

    // GET_WORKSPACES
    {
        const workspaces = try conn.getWorkspaces(init.gpa);
        defer workspaces.deinit();

        std.log.debug("{any}", .{workspaces.value});
    }

    // GET_OUTPUT
    {
        const outputs = try conn.getOutputs(init.gpa);
        defer outputs.deinit();

        std.log.debug("{any}", .{outputs.value});
    }

    // GET_TREE
    {
        const tree = try conn.getTree(init.gpa);
        defer tree.deinit();

        std.log.debug("{any}", .{tree.value});
    }

    // GET_MARKS
    {
        const marks = try conn.getMarks(init.gpa);
        defer marks.deinit();

        std.log.debug("{any}", .{marks.value});
    }

    // GET_BAR_CONFIG
    {
        const bars = try conn.getBars(init.gpa);
        defer bars.deinit();

        std.log.debug("{any}", .{bars.value});

        const bar_config = try conn.getBarConfig(init.gpa, bars.value[0]);
        defer bar_config.deinit();

        std.log.debug("{any}", .{bar_config.value});
    }

    // GET_VERSION
    {
        const version = try conn.getVersion(init.gpa);
        defer version.deinit();

        std.log.info("sway version: {s}", .{version.value.human_readable});
    }

    // GET_BINDING_MODES
    {
        const modes = try conn.getBindingModes(init.gpa);
        defer modes.deinit();

        std.log.debug("{any}", .{modes.value});
    }

    // GET_CONFIG
    {
        const config = try conn.getConfig(init.gpa);
        defer config.deinit();

        std.log.debug("{any}", .{config.value.config});
    }

    // SEND_TICK
    {
        const tick = try conn.sendTick(init.gpa, &.{});
        defer tick.deinit();

        std.log.debug("{any}", .{tick.value});
    }

    // GET_BINDING_STATE
    {
        const binding_state = try conn.getBindingState(init.gpa);
        defer binding_state.deinit();
        std.log.debug("{any}", .{binding_state.value});
    }

    // GET_INPUTS
    {
        const inputs = try conn.getInputs(init.gpa);
        defer inputs.deinit();

        std.log.debug("{any}", .{inputs.value});
    }

    // GET_SEATS
    {
        const seats = try conn.getSeats(init.gpa);
        defer seats.deinit();

        std.log.debug("{any}", .{seats.value});
    }

    // SUBSCRIBE
    {
        _ = try conn.subscribe(init.gpa, &.{.tick}, .{
            .default = handleEvent,
            .tick = handleTickEvent,
        });
    }
}

fn handleEvent(gpa: std.mem.Allocator, event: swayipc.IpcPayload.Event, body: []const u8) bool {
    _ = gpa;
    _ = body;

    std.log.warn("unhandled event: '{t}'", .{event});

    return true;
}

fn handleTickEvent(tick: swayipc.events.Tick) bool {
    return !std.mem.eql(u8, tick.payload, "hup");
}
