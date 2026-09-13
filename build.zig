const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("my_scanner", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-scanner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "my_scanner", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the scanner CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // bench：与 yuku lexer 的同进程对比基准。
    // yuku 源码由 scripts/bench.sh clone 到 .bench-deps/yuku（gitignore），
    // 只有 `zig build bench` 会真正编译它，其余 step 不受影响。
    // yuku 的 lexer.zig 通过 @import("util") 和 @import("parser_extension")
    // 引用其构建系统的模块，这里照原样接线（extension 用空 options）。
    const yuku_root = ".bench-deps/yuku";
    const yuku_util = b.createModule(.{
        .root_source_file = .{ .cwd_relative = yuku_root ++ "/src/util/root.zig" },
        .target = target,
    });
    const yuku_lexer = b.createModule(.{
        .root_source_file = .{ .cwd_relative = yuku_root ++ "/src/parser/lexer.zig" },
        .target = target,
    });
    yuku_lexer.addImport("util", yuku_util);
    yuku_lexer.addImport("parser_extension", b.addOptions().createModule());

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "my_scanner", .module = mod },
                .{ .name = "yuku_lexer", .module = yuku_lexer },
            },
        }),
    });
    const bench_step = b.step("bench", "Lexer benchmark vs yuku (requires .bench-deps/yuku)");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    if (b.args) |args| bench_cmd.addArgs(args);
}
