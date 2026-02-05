const std = @import("std");
const log = std.log.scoped(.swayipc);

const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Reader = std.Io.Reader;
const UnixAddress = std.Io.net.UnixAddress;
const Writer = std.Io.Writer;

const assert = std.debug.assert;

pub const ConnectOptions = union(enum) {
    /// Try to  connect to the socket at `path`.
    path: []const u8,

    /// Try to connect to the socket in the `SWAYSOCK` environment variable.
    env: *std.process.Environ.Map,
};

pub const ConnectError = error{MissingEnvironmentVariable} ||
    UnixAddress.InitError || UnixAddress.ConnectError;

pub fn connect(connect_options: ConnectOptions, io: std.Io) ConnectError!std.Io.net.Stream {
    const path: []const u8 = switch (connect_options) {
        .path => |x| x,
        .env => |x| x.get("SWAYSOCK") orelse return error.MissingEnvironmentVariable,
    };

    const sock: UnixAddress = try .init(path);
    const stream = try sock.connect(io);

    log.debug("opened IPC connection to {s}", .{path});

    return stream;
}

pub const IpcConnection = struct {
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    event_handlers: EventHandlers = .{},

    const json_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

    pub const EventHandlers = struct {
        default: ?*const Default = null,
        workspace: ?*const Workspace = null,
        output: ?*const Output = null,
        mode: ?*const Mode = null,
        window: ?*const Window = null,
        bar_config: ?*const BarConfig = null,
        binding: ?*const Binding = null,
        shutdown: ?*const Shutdown = null,
        tick: ?*const Tick = null,
        bar_state: ?*const BarState = null,
        input: ?*const Input = null,

        pub const Default = fn (std.mem.Allocator, IpcPayload.Event, []const u8) bool;
        pub const Workspace = fn (events.Workspace) bool;
        pub const Output = fn (events.Output) bool;
        pub const Mode = fn (events.Mode) bool;
        pub const Window = fn (events.Window) bool;
        pub const BarConfig = fn (events.BarConfigUpdate) bool;
        pub const Binding = fn (events.Binding) bool;
        pub const Shutdown = fn (events.Shutdown) bool;
        pub const Tick = fn (events.Tick) bool;
        pub const BarState = fn (events.BarStateUpdate) bool;
        pub const Input = fn (events.Input) bool;
    };

    pub fn init(reader: *std.Io.Reader, writer: *std.Io.Writer) IpcConnection {
        return .{
            .reader = reader,
            .writer = writer,
        };
    }

    pub fn runCommand(self: *IpcConnection, gpa: std.mem.Allocator, body: []const u8) !IpcPayload {
        return try self.sendIpcMessage(gpa, .run_command, body);
    }

    pub fn subscribe(
        self: *IpcConnection,
        gpa: std.mem.Allocator,
        event_list: []const IpcPayload.Event,
        handlers: EventHandlers,
    ) !void {
        const body = try std.json.Stringify.valueAlloc(gpa, event_list, .{});
        defer gpa.free(body);

        var reply = try self.sendIpcMessage(gpa, .subscribe, body);
        defer reply.deinit(gpa);

        const result = try std.json.parseFromSlice(replies.Subscribe, gpa, reply.body, json_opts);
        defer result.deinit();

        if (!result.value.success) {
            return error.SubscribeFailed;
        }

        try self.listenForEvents(gpa, handlers);
    }

    pub fn getWorkspaces(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed([]const replies.Workspace) {
        return try self.sendAndParseIpcMessage([]const replies.Workspace, gpa, .get_workspaces, &.{});
    }

    pub fn getOutputs(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed([]const replies.Output) {
        return try self.sendAndParseIpcMessage([]const replies.Output, gpa, .get_outputs, &.{});
    }

    pub fn getTree(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed(replies.Node) {
        return try self.sendAndParseIpcMessage(replies.Node, gpa, .get_tree, &.{});
    }

    pub fn getMarks(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed([]const []const u8) {
        return try self.sendAndParseIpcMessage([]const []const u8, gpa, .get_marks, &.{});
    }

    pub fn getBars(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed([]const []const u8) {
        return try self.sendAndParseIpcMessage([]const []const u8, gpa, .get_bar_config, &.{});
    }

    pub fn getBarConfig(self: *IpcConnection, gpa: std.mem.Allocator, id: []const u8) !std.json.Parsed(replies.BarConfig) {
        return try self.sendAndParseIpcMessage(replies.BarConfig, gpa, .get_bar_config, id);
    }

    pub fn getVersion(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed(replies.Version) {
        return try self.sendAndParseIpcMessage(replies.Version, gpa, .get_version, &.{});
    }

    pub fn getBindingModes(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed([]const []const u8) {
        return try self.sendAndParseIpcMessage([]const []const u8, gpa, .get_binding_modes, &.{});
    }

    pub fn getConfig(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed(replies.Config) {
        return try self.sendAndParseIpcMessage(replies.Config, gpa, .get_config, &.{});
    }

    pub fn sendTick(self: *IpcConnection, gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(replies.Tick) {
        return try self.sendAndParseIpcMessage(replies.Tick, gpa, .send_tick, body);
    }

    pub fn getBindingState(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed(replies.BindingState) {
        return try self.sendAndParseIpcMessage(replies.BindingState, gpa, .get_binding_state, &.{});
    }

    pub fn getInputs(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed([]const replies.Input) {
        return try self.sendAndParseIpcMessage([]const replies.Input, gpa, .get_inputs, &.{});
    }

    pub fn getSeats(self: *IpcConnection, gpa: std.mem.Allocator) !std.json.Parsed([]const replies.Seat) {
        return try self.sendAndParseIpcMessage([]const replies.Seat, gpa, .get_seats, &.{});
    }

    pub fn sendIpcMessage(self: *IpcConnection, gpa: std.mem.Allocator, message: IpcPayload.Message, body: []const u8) !IpcPayload {
        const msg: IpcPayload = .{
            .header = .{
                .magic = std.mem.bytesToValue([6]u8, IpcPayload.Header.magic_value),
                .payload_length = @truncate(body.len),
                .payload_type = .{ .message = message },
            },
            .body = body,
        };

        try IpcPayload.write(&msg, self.writer);
        var reply = try IpcPayload.readHead(self.reader);

        assert(std.enums.fromInt(IpcPayload.Message, @intFromEnum(reply.header.payload_type)) != null);

        try reply.readBody(gpa, self.reader);
        return reply;
    }

    fn sendAndParseIpcMessage(
        self: *IpcConnection,
        comptime T: type,
        gpa: std.mem.Allocator,
        payload_type: IpcPayload.Message,
        body: []const u8,
    ) !std.json.Parsed(T) {
        var reply = try self.sendIpcMessage(gpa, payload_type, body);
        defer reply.deinit(gpa);

        return try std.json.parseFromSlice(T, gpa, reply.body, json_opts);
    }

    fn listenForEvents(self: *IpcConnection, gpa: std.mem.Allocator, handlers: EventHandlers) !void {
        while (true) {
            var reply = try IpcPayload.readHead(self.reader);
            defer reply.deinit(gpa);

            assert(std.meta.activeTag(reply.header.payload_type) == .event);
            const event = reply.header.payload_type.event;

            try reply.readBody(gpa, self.reader);

            var keep_listening: bool = false;
            var handled: bool = false;

            switch (event) {
                .workspace => {
                    if (handlers.workspace) |handler| {
                        const json = try parseEventJson(events.Workspace, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .output => {
                    if (handlers.output) |handler| {
                        const json = try parseEventJson(events.Output, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .mode => {
                    if (handlers.mode) |handler| {
                        const json = try parseEventJson(events.Mode, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .window => {
                    if (handlers.window) |handler| {
                        const json = try parseEventJson(events.Window, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .barconfig_update => {
                    if (handlers.bar_config) |handler| {
                        const json = try parseEventJson(events.BarConfigUpdate, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .binding => {
                    if (handlers.binding) |handler| {
                        const json = try parseEventJson(events.Binding, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .shutdown => {
                    if (handlers.shutdown) |handler| {
                        const json = try parseEventJson(events.Shutdown, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .tick => {
                    if (handlers.tick) |handler| {
                        const json = try parseEventJson(events.Tick, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .bar_state_update => {
                    if (handlers.bar_state) |handler| {
                        const json = try parseEventJson(events.BarStateUpdate, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
                .input => {
                    if (handlers.input) |handler| {
                        const json = try parseEventJson(events.Input, gpa, reply.body);
                        defer json.deinit();
                        keep_listening = handler(json.value);
                        handled = true;
                    }
                },
            }

            if (!handled) {
                if (handlers.default) |handler| {
                    keep_listening = handler(gpa, event, reply.body);
                }
            }

            if (!keep_listening) {
                break;
            }
        }
    }

    fn parseEventJson(comptime T: type, gpa: std.mem.Allocator, body: []const u8) !std.json.Parsed(T) {
        return try std.json.parseFromSlice(T, gpa, body, json_opts);
    }
};

/// Representation of an IPC message and reply.
pub const IpcPayload = struct {
    header: Header,
    body: []const u8,

    pub fn deinit(self: *const IpcPayload, gpa: std.mem.Allocator) void {
        gpa.free(self.body);
    }

    pub const Header = struct {
        magic: [6]u8,
        payload_length: u32,
        payload_type: PayloadType,

        pub const magic_value: []const u8 = "i3-ipc";
    };

    pub const PayloadType = union(enum) {
        message: Message,
        event: Event,
    };

    pub const PayloadTypeTag = blk: {
        const names: []const []const u8 = std.meta.fieldNames(Message) ++ std.meta.fieldNames(Event);
        var fields: [names.len]u32 = undefined;

        var index: u32 = 0;
        for (std.meta.fields(Message)) |f| {
            fields[index] = f.value;
            index += 1;
        }
        for (std.meta.fields(Event)) |f| {
            fields[index] = f.value;
            index += 1;
        }

        break :blk @Enum(u32, .exhaustive, names, &fields);
    };

    pub const Message = enum(u32) {
        // Messages
        run_command = 0,
        get_workspaces = 1,
        subscribe = 2,
        get_outputs = 3,
        get_tree = 4,
        get_marks = 5,
        get_bar_config = 6,
        get_version = 7,
        get_binding_modes = 8,
        get_config = 9,
        send_tick = 10,
        sync = 11,
        get_binding_state = 12,
        get_inputs = 100,
        get_seats = 101,
    };

    pub const Event = enum(u32) {
        // Events
        workspace = 0x8000_0000,
        output = 0x8000_0001,
        mode = 0x8000_0002,
        window = 0x8000_0003,
        barconfig_update = 0x8000_0004,
        binding = 0x8000_0005,
        shutdown = 0x8000_0006,
        tick = 0x8000_0007,
        bar_state_update = 0x8000_0014,
        input = 0x8000_0015,
    };

    pub fn write(msg: *const IpcPayload, w: *Writer) !void {
        assert(std.meta.activeTag(msg.header.payload_type) == .message);

        log.debug("> {s} {d} {t}: '{s}'", .{
            msg.header.magic,
            msg.header.payload_length,
            msg.header.payload_type.message,
            msg.body,
        });

        try w.writeAll(&msg.header.magic);
        try w.writeInt(u32, msg.header.payload_length, .native);
        try w.writeInt(u32, @intFromEnum(msg.header.payload_type.message), .native);
        try w.writeAll(msg.body);

        try w.flush();
    }

    pub fn readHead(r: *std.Io.Reader) !IpcPayload {
        const magic = (try r.takeArray(Header.magic_value.len)).*;
        const payload_len = try r.takeInt(u32, .native);
        const payload_type = try r.takeInt(u32, .native);

        const union_value: PayloadType = if (std.enums.fromInt(Message, payload_type)) |m|
            .{ .message = m }
        else if (std.enums.fromInt(Event, payload_type)) |e|
            .{ .event = e }
        else
            return error.PayloadType;

        var reply: IpcPayload = .{
            .header = .{
                .magic = magic,
                .payload_length = payload_len,
                .payload_type = union_value,
            },
            .body = &.{},
        };

        log.debug("< {s} {d} {s}", .{
            reply.header.magic,
            reply.header.payload_length,
            switch (reply.header.payload_type) {
                .message => |m| @tagName(m),
                .event => |e| @tagName(e),
            },
        });

        return reply;
    }

    pub fn readBody(self: *IpcPayload, gpa: std.mem.Allocator, r: *std.Io.Reader) !void {
        const body = try gpa.alloc(u8, self.header.payload_length);
        try r.readSliceAll(body);
        errdefer gpa.free(body);

        self.body = body;

        log.debug("< {s} {d} {s}: '{s}'", .{
            self.header.magic,
            self.header.payload_length,
            switch (self.header.payload_type) {
                .message => |m| @tagName(m),
                .event => |e| @tagName(e),
            },
            self.body,
        });
    }
};

pub const replies = struct {
    pub const CommandResult = struct {
        success: bool,
        parse_error: ?bool = null,
        @"error": ?[]const u8 = null,
    };

    pub const Workspace = struct {
        num: i32,
        name: []const u8,
        visible: bool,
        focused: bool,
        urgent: bool,
        rect: Rect,
        output: []const u8,
    };

    pub const Output = struct {
        name: []const u8,
        make: []const u8,
        model: []const u8,
        serial: []const u8,
        active: bool,
        dpms: bool,
        power: bool,
        primary: bool,
        scale: f32,
        subpixel_hinting: []const u8, // TODO: enum?
        transform: []const u8, // TODO: enum?
        current_workspace: ?[]const u8,
        modes: []const Mode,
        current_mode: Mode,
        rect: Rect,
        hdr: bool,

        pub const Mode = struct { width: i32, height: i32, refresh: i32 };
    };

    pub const Node = struct {
        id: i32,
        name: []const u8,
        type: NodeType,
        border: BorderStyle,
        current_border_width: i32,
        layout: NodeLayout,
        orientation: NodeOrientation,
        percent: ?f32,
        rect: Rect,
        window_rect: Rect,
        deco_rect: Rect,
        geometry: Rect,
        urgent: bool,
        sticky: bool,
        marks: []const []const u8,
        focused: bool,
        focus: []const u32,
        nodes: []const Node,
        floating_nodes: []const Node,
        representation: ?[]const u8 = null,
        fullscreen_mode: FullscreenMode,
        floating: ?FloatingState,
        scratchpad_state: ?ScratchpadState = null,
        app_id: ?[]const u8 = null,
        pid: ?std.os.linux.pid_t = null,
        foreign_toplevel_identifier: ?[]const u8 = null,
        visible: ?bool = null,
        shell: ?[]const u8 = null,
        inhibit_idle: ?bool = null,
        idle_inhibitors: ?IdleInhibitor = null,
        sandbox_engine: ?[]const u8 = null,
        sandbox_app_id: ?[]const u8 = null,
        sandbox_instance_id: ?[]const u8 = null,
        tag: ?[]const u8 = null,
        window: ?i32 = null,
        window_properties: ?WindowProperties = null,

        pub const NodeType = enum { root, output, workspace, con, floating_con };
        pub const BorderStyle = enum { none, normal, pixel, csd };
        pub const NodeLayout = enum { none, splith, splitv, stacked, tabbed, output };
        pub const NodeOrientation = enum { none, vertical, horizontal };
        pub const FullscreenMode = enum(u32) { none, workspace, global };
        pub const FloatingState = enum { auto_off, user_on };
        pub const ScratchpadState = enum { none, fresh };

        pub const IdleInhibitor = struct {
            user: User,
            application: Application,

            pub const User = enum { none, focus, fullscreen, open, visible };
            pub const Application = enum { none, enabled };
        };

        pub const WindowProperties = struct {
            title: ?[]const u8 = null,
            class: ?[]const u8 = null,
            instance: ?[]const u8 = null,
            window_role: ?[]const u8 = null,
            window_type: ?XWindowType = null,
            transient_for: ?u32,

            pub const XWindowType = enum {
                normal,
                dialog,
                utility,
                toolbar,
                splash,
                menu,
                dropdown_menu,
                popup_menu,
                tooltip,
                notification,
                unknown,
            };
        };
    };

    pub const BarConfig = struct {
        id: []const u8,
        mode: BarMode,
        position: BarPosition,
        status_command: ?[]const u8,
        font: []const u8,
        workspace_buttons: bool,
        workspace_min_width: u32,
        binding_mode_indicator: bool,
        verbose: bool,
        colors: BarColor,
        gaps: BarGaps,
        bar_height: u32,
        status_padding: u32,
        status_edge_padding: u32,

        pub const BarMode = enum { dock, hide, invisible };
        pub const BarPosition = enum { bottom, top };
        pub const BarColor = struct {
            background: []const u8,
            statusline: []const u8,
            separator: []const u8,
            focused_background: []const u8,
            focused_statusline: []const u8,
            focused_separator: []const u8,
            focused_workspace_text: []const u8,
            focused_workspace_bg: []const u8,
            focused_workspace_border: []const u8,
            active_workspace_text: []const u8,
            active_workspace_bg: []const u8,
            active_workspace_border: []const u8,
            inactive_workspace_text: []const u8,
            inactive_workspace_bg: []const u8,
            inactive_workspace_border: []const u8,
            urgent_workspace_text: []const u8,
            urgent_workspace_bg: []const u8,
            urgent_workspace_border: []const u8,
            binding_mode_text: []const u8,
            binding_mode_bg: []const u8,
            binding_mode_border: []const u8,
        };

        pub const BarGaps = struct { top: u32, right: u32, bottom: u32, left: u32 };
    };

    pub const Version = struct {
        major: u32,
        minor: u32,
        patch: u32,
        human_readable: []const u8,
        loaded_config_file_name: []const u8,
        variant: Unstable([]const u8),
    };

    pub const Config = struct {
        config: []const u8,
    };

    pub const Tick = struct {
        success: bool,
    };

    pub const Subscribe = struct {
        success: bool,
    };

    pub const BindingState = struct {
        name: []const u8,
    };

    pub const Input = struct {
        identifier: []const u8,
        name: []const u8,
        vendor: u32,
        product: u32,
        type: []const u8,
        xkb_active_layout_name: ?[]const u8 = null,
        xkb_layout_names: ?[]const []const u8 = null,
        scroll_factor: ?f32 = null,
        libinput: ?LibinputSettings = null,

        pub const LibinputSettings = struct {
            send_events: SendEvents,
            tap: ?TapToClick = null,
            tap_button_map: ?TapButtonMap = null,
            tap_drag: ?TapToDrag = null,
            tap_drag_lock: ?DragLock = null,
            accel_speed: ?f64 = null,
            accel_profile: ?AccelProfile = null,
            natural_scroll: ?NaturalScroll = null,
            left_handed: ?LeftHanded = null,
            click_method: ?ClickMethod = null,
            click_buton_map: ?ClickButtonMap = null,
            middle_emulation: ?MiddleEmulation = null,
            scroll_method: ?ScrollMethod = null,
            scroll_button: ?u32 = null, // TODO: libinput code is what type?
            scroll_button_lock: ?ScrollButtonLock = null,
            dwt: ?Dwt = null,
            dwtp: ?Dwtp = null,
            calibration_matrix: ?[6]f32 = null,

            pub const SendEvents = enum { enabled, disabled, disabled_on_external_mouse };
            pub const TapToClick = enum { enabled, disabled };
            pub const TapButtonMap = enum { lmr, lrm };
            pub const TapToDrag = enum { enabled, disabled };
            pub const DragLock = enum { enabled, disabled, enabled_sticky };
            pub const AccelProfile = enum { none, flat, adaptive };
            pub const NaturalScroll = enum { enabled, disabled };
            pub const LeftHanded = enum { enabled, disabled };
            pub const ClickMethod = enum { none, button_areas, clickfinger };
            pub const ClickButtonMap = enum { lmr, lrm };
            pub const MiddleEmulation = enum { enabled, disabled };
            pub const ScrollMethod = enum { none, two_finger, edge, on_button_down };
            pub const ScrollButtonLock = enum { enabled, disabled };
            pub const Dwt = enum { enabled, disabled };
            pub const Dwtp = enum { enabled, disabled };
        };
    };

    pub const Seat = struct {
        name: []const u8,
        capabilities: u32,
        focus: u32,
        devices: []const Input,
    };

    pub const Rect = struct { x: i32, y: i32, width: i32, height: i32 };

    fn Unstable(comptime T: type) type {
        return ?T;
    }
};

pub const events = struct {
    pub const Workspace = struct {
        change: WorkspaceChange,
        current: ?replies.Workspace,
        old: ?replies.Workspace,

        pub const WorkspaceChange = enum {
            init,
            empty,
            focus,
            move,
            rename,
            urgent,
            reload,
        };
    };

    pub const Output = struct {
        change: OutputChange,

        pub const OutputChange = enum { unspecified };
    };

    pub const Mode = struct {
        change: []const u8,
        pango_markup: bool,
    };

    pub const Window = struct {
        change: WindowChange,
        container: replies.Node,

        pub const WindowChange = enum {
            new,
            close,
            focus,
            title,
            fullscreen_mode,
            move,
            floating,
            urgent,
            mark,
        };
    };

    pub const BarConfigUpdate = replies.BarConfig;

    pub const Binding = struct {
        change: BindingChange,
        command: []const u8,
        event_state_mask: []const []const u8,
        input_code: u32,
        symbol: ?[]const u8 = null,
        input_type: BindingInputType,

        pub const BindingChange = enum { run };
        pub const BindingInputType = enum { keyboard, mouse };
    };

    pub const Shutdown = struct {
        change: ShutdownChange,

        pub const ShutdownChange = enum { exit };
    };

    pub const Tick = struct {
        first: bool,
        payload: []const u8,
    };

    pub const BarStateUpdate = struct {
        id: []const u8,
        visible_by_modifier: bool,
    };

    pub const Input = struct {
        change: InputChange,
        input: replies.Input,

        pub const InputChange = enum {
            added,
            removed,
            xkb_keymap,
            xkb_layout,
            libinput_config,
        };
    };
};
