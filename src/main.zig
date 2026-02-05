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

    const json_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

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
        const reply = try conn.getWorkspaces(init.gpa);
        defer reply.deinit(init.gpa);

        const workspaces = try std.json.parseFromSlice([]const replies.Workspace, init.gpa, reply.body, json_opts);
        defer workspaces.deinit();

        std.log.debug("{any}", .{workspaces.value});
    }

    // GET_OUTPUT
    {
        const reply = try conn.getOutputs(init.gpa);
        defer reply.deinit(init.gpa);

        const outputs = try std.json.parseFromSlice([]const replies.Output, init.gpa, reply.body, json_opts);
        defer outputs.deinit();

        std.log.debug("{any}", .{outputs.value});
    }

    // GET_TREE
    {
        const reply = try conn.getTree(init.gpa);
        defer reply.deinit(init.gpa);

        const outputs = try std.json.parseFromSlice(replies.Node, init.gpa, reply.body, json_opts);
        defer outputs.deinit();

        std.log.debug("{any}", .{outputs.value});
    }

    // GET_MARKS
    {
        const reply = try conn.getMarks(init.gpa);
        defer reply.deinit(init.gpa);

        const marks = try std.json.parseFromSlice([]const []const u8, init.gpa, reply.body, json_opts);
        defer marks.deinit();

        std.log.debug("{any}", .{marks.value});
    }

    // GET_BAR_CONFIG
    {
        const reply = try conn.getBars(init.gpa);
        defer reply.deinit(init.gpa);

        const bars = try std.json.parseFromSlice([]const []const u8, init.gpa, reply.body, json_opts);
        defer bars.deinit();

        std.log.debug("{any}", .{bars});

        const reply2 = try conn.getBarConfig(init.gpa, bars.value[0]);
        defer reply2.deinit(init.gpa);

        const bar = try std.json.parseFromSlice(replies.BarConfig, init.gpa, reply2.body, json_opts);
        defer bar.deinit();

        std.log.debug("{any}", .{bar.value});
    }

    // GET_VERSION
    {
        const reply = try conn.getVersion(init.gpa);
        defer reply.deinit(init.gpa);

        const version = try std.json.parseFromSlice(replies.Version, init.gpa, reply.body, json_opts);
        defer version.deinit();

        std.log.info("sway version: {s}", .{version.value.human_readable});
    }

    // GET_BINDING_MODES
    {
        const reply = try conn.getBindingModes(init.gpa);
        defer reply.deinit(init.gpa);

        const modes = try std.json.parseFromSlice([]const []const u8, init.gpa, reply.body, json_opts);
        defer modes.deinit();
        //
        std.log.debug("{any}", .{modes.value});
    }

    // GET_CONFIG
    {
        const reply = try conn.getConfig(init.gpa);
        defer reply.deinit(init.gpa);

        const config = try std.json.parseFromSlice(replies.Config, init.gpa, reply.body, json_opts);
        defer config.deinit();

        std.log.debug("{any}", .{config.value.config});
    }

    // SEND_TICK
    {
        const reply = try conn.sendTick(init.gpa, &.{});
        defer reply.deinit(init.gpa);

        const tick = try std.json.parseFromSlice(replies.Tick, init.gpa, reply.body, json_opts);
        defer tick.deinit();

        std.log.debug("{any}", .{tick.value});
    }

    // GET_BINDING_STATE
    {
        const reply = try conn.getBindingState(init.gpa);
        defer reply.deinit(init.gpa);

        const state = try std.json.parseFromSlice(replies.BindingState, init.gpa, reply.body, json_opts);
        defer state.deinit();

        std.log.debug("{any}", .{state.value});
    }

    // GET_INPUTS
    {
        const reply = try conn.getInputs(init.gpa);
        defer reply.deinit(init.gpa);

        const inputs = try std.json.parseFromSlice([]const replies.Input, init.gpa, reply.body, json_opts);
        defer inputs.deinit();

        std.log.debug("{any}", .{inputs.value});
    }

    // GET_SEATS
    {
        const reply = try conn.getSeats(init.gpa);
        defer reply.deinit(init.gpa);

        const seats = try std.json.parseFromSlice([]const replies.Seat, init.gpa, reply.body, json_opts);
        defer seats.deinit();

        std.log.debug("{any}", .{seats.value});
    }

    // SUBSCRIBE
    {
        _ = try conn.subscribe(init.gpa, &.{.tick}, handleEvent);
    }
}

fn handleEvent(gpa: std.mem.Allocator, payload: swayipc.IpcPayload) bool {
    defer payload.deinit(gpa);

    std.log.debug("event: '{s}'", .{payload.body});

    switch (payload.header.payload_type) {
        .tick => |e| {
            const tick = std.json.parseFromSlice(events.Tick, gpa, payload.body, .{ .ignore_unknown_fields = true }) catch |err| {
                std.log.err("failed parsing json for event '{t}': {t}", .{ e, err });
                return false;
            };
            defer tick.deinit();

            if (std.mem.eql(u8, tick.value.payload, "hup")) {
                return false;
            }
        },
        else => |x| std.log.warn("ignoring event {t}", .{x}),
    }

    return true;
}
