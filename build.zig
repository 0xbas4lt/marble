const std = @import("std");

pub fn build(b: *std.Build) void {
    const target_query = blk: {
        var query = std.Target.Query{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        };

        const Feature = std.Target.x86.Feature;
        var disabled = std.Target.Cpu.Feature.Set.empty;
        var enabled = std.Target.Cpu.Feature.Set.empty;

        disabled.addFeature(@backingInt(Feature.mmx));
        disabled.addFeature(@backingInt(Feature.sse));
        disabled.addFeature(@backingInt(Feature.sse2));
        disabled.addFeature(@backingInt(Feature.avx));
        disabled.addFeature(@backingInt(Feature.avx2));
        enabled.addFeature(@backingInt(Feature.soft_float));

        query.cpu_features_sub = disabled;
        query.cpu_features_add = enabled;

        break :blk query;
    };

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const compiler_rt_patched_mod = b.createModule(.{
        .root_source_file = b.path("compiler_rt_patched/compiler_rt.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,

        .omit_frame_pointer = false,
        .strip = false,
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .red_zone = false,
        .pic = false,
        .omit_frame_pointer = false,
        .strip = false,
    });
    kernel_mod.addImport("compiler_rt_patched", compiler_rt_patched_mod);

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = kernel_mod,

        // IMPORTANT: Zig 0.15+ defaults to the self-hosted x86_64
        // codegen backend in Debug mode, and that backend still has
        // real gaps for freestanding/no-SSE targets -- it can emit
        // SSE instructions or fail to legalize float ops (e.g. the
        // "fpext f128 f64" / "no encoding found for: ... movups"
        // errors) even with sse/sse2 explicitly disabled. Forcing the
        // LLVM backend avoids this; see ziglang/zig#22257 and the
        // "Zig's self-hosted x86 backend is now default in Debug
        // mode" discussion on Lobsters for the same fix.
        .use_llvm = true,
        .use_lld = true,
    });

    kernel.bundle_compiler_rt = false;
    kernel.setLinkerScript(b.path("kernel/linker/x86_64.ld"));
    kernel.lto = .none;
    b.installArtifact(kernel);

    const program_hello = b.addExecutable(.{
        .name = "hello.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("programs/hello/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    program_hello.root_module.addImport("compiler_rt_patched", compiler_rt_patched_mod);
    program_hello.bundle_compiler_rt = false; // FIXME: Rework after moving to userland.
    program_hello.pie = true;
    program_hello.setLinkerScript(b.path("programs/linker/x86_64.ld"));
    b.installArtifact(program_hello);

    const kernel_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(kernel_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
