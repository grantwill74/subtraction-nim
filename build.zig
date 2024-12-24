const std = @import("std");

pub fn build(b: *std.Build) void {
    const dbg = b.addExecutable(.{
        .name = "nim",
        .root_source_file = b.path("nim.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .link_libc = false,
        .linkage = .static,
    });

    b.installArtifact(dbg);
    

    const run_exe = b.addRunArtifact(dbg);

    const run_step = b.step("run", "Play nim.");
    run_step.dependOn(&run_exe.step);
}