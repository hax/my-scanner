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
    // 两份 yuku：基线快照（.bench-deps/yuku，引入向量化前的版本）与
    // 主干（.bench-deps/yuku-main，perf(lexer) 系列提交之后）
    const yuku_util = b.createModule(.{
        .root_source_file = .{ .cwd_relative = ".bench-deps/yuku/src/util/root.zig" },
        .target = target,
    });
    const yuku_lexer = b.createModule(.{
        .root_source_file = .{ .cwd_relative = ".bench-deps/yuku/src/parser/lexer.zig" },
        .target = target,
    });
    yuku_lexer.addImport("util", yuku_util);
    // 空 options 会因缓存路径相同而冲突，加区分字段（extension 只按名字
    // @hasDecl 探测，多余字段无害）
    const ext_old = b.addOptions();
    ext_old.addOption([]const u8, "which", "yuku-old");
    yuku_lexer.addImport("parser_extension", ext_old.createModule());

    const yuku_main_util = b.createModule(.{
        .root_source_file = .{ .cwd_relative = ".bench-deps/yuku-main/src/util/root.zig" },
        .target = target,
    });
    const yuku_lexer_main = b.createModule(.{
        .root_source_file = .{ .cwd_relative = ".bench-deps/yuku-main/src/parser/lexer.zig" },
        .target = target,
    });
    yuku_lexer_main.addImport("util", yuku_main_util);
    const ext_main = b.addOptions();
    ext_main.addOption([]const u8, "which", "yuku-main");
    yuku_lexer_main.addImport("parser_extension", ext_main.createModule());

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "my_scanner", .module = mod },
                .{ .name = "yuku_lexer", .module = yuku_lexer },
                .{ .name = "yuku_lexer_main", .module = yuku_lexer_main },
            },
        }),
    });
    const bench_step = b.step("bench", "Lexer benchmark vs yuku (requires .bench-deps/yuku)");
    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_cmd.step);
    if (b.args) |args| bench_cmd.addArgs(args);
}
