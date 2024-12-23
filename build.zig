const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "nim",
        .root_source_file = b.path("nim.zig"),
        .target = b.graph.host,
    });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Play nim.");
    run_step.dependOn(&run_exe.step);
}