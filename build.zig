const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const swayipc = b.addModule("swayipc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "swayipc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "swayipc", .module = swayipc },
            },
        }),
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_exe.step);

    // examples
    {
        const version_example_exe = b.addExecutable(.{
            .name = "swayipc-version",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/version.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "swayipc", .module = swayipc },
                },
            }),
        });
        const run_version_example_exe = b.addRunArtifact(version_example_exe);
        if (b.args) |args| {
            run_exe.addArgs(args);
        }
        const run_version_example_step = b.step("run-version-example", "Run the version example");
        run_version_example_step.dependOn(&run_version_example_exe.step);

        const subscribe_example_exe = b.addExecutable(.{
            .name = "swayipc-subscribe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/subscribe.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "swayipc", .module = swayipc },
                },
            }),
        });
        const run_subscribe_example_exe = b.addRunArtifact(subscribe_example_exe);
        if (b.args) |args| {
            run_exe.addArgs(args);
        }
        const run_subscribe_example_step = b.step("run-subscribe-example", "Run the subscribe example");
        run_subscribe_example_step.dependOn(&run_subscribe_example_exe.step);
    }
}
