const std = @import("std");

// What happens if this is imported like a zig dependency?
// How to properly package the executable and libraries to ship to other users?

pub fn build(b: *std.Build) void {
    std.debug.print("install prefix: \"{s}\"\n", .{b.install_prefix});
    std.debug.print("build root: \"{?s}\"\n", .{b.build_root.path});

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    prepareExternal() catch |err| std.debug.panic("Failed to prepare external: {}", .{err});

    const sc_mod = b.addModule("SDL_shadercross", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/sdl_shadercross.zig"),
        .link_libc = true,
    });

    sc_mod.addIncludePath(b.path("external/SDL/include/"));
    sc_mod.addIncludePath(b.path("external/SDL_shadercross/include/"));
    sc_mod.addLibraryPath(b.path("external/SDL/lib/"));
    sc_mod.addLibraryPath(b.path("external/SDL_shadercross/lib/"));

    sc_mod.linkSystemLibrary("SDL3.0", .{ .needed = true });
    sc_mod.linkSystemLibrary("SDL3_shadercross", .{ .needed = true });
    sc_mod.linkSystemLibrary("dxcompiler", .{ .needed = true });
    sc_mod.linkSystemLibrary("spirv-cross-c-shared.0.64.0", .{ .needed = true });

    b.installFile(
        "external/SDL/lib/libSDL3.0.dylib",
        "external/libSDL3.0.dylib",
    );
    b.installFile(
        "external/SDL_shadercross/lib/libdxcompiler.dylib",
        "external/libdxcompiler.dylib",
    );
    b.installFile(
        "external/SDL_shadercross/lib/libspirv-cross-c-shared.0.64.0.dylib",
        "external/libspirv-cross-c-shared.0.64.0.dylib",
    );

    ////////////////////////////// APP /////////////////////////////////////////////////////////////
    const app_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    app_mod.addImport("SDL_shadercross", sc_mod);
    const exe = b.addExecutable(.{
        .name = "test_app",
        .root_module = app_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run gt_sample");
    run_step.dependOn(&run_cmd.step);

    ////////////////////////////// TEST ////////////////////////////////////////////////////////////
    const filters = b.args orelse &.{};

    const tests = b.addTest(.{
        .name = "tests",
        .root_module = sc_mod,
        .target = target,
        .optimize = optimize,
        .filters = filters,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}

fn prepareExternal() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // TODO: use
    var vendor_dir = try std.fs.cwd().openDir("vendor", .{});
    defer vendor_dir.close();

    // Debug
    const vendor_path = try vendor_dir.realpathAlloc(gpa.allocator(), ".");
    defer gpa.allocator().free(vendor_path);
    std.debug.print("vendor path: {s}\n", .{vendor_path});

    std.fs.cwd().makePath("external") catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };
    var external_dir = try std.fs.cwd().openDir("external", .{});
    defer external_dir.close();

    var vendor_version = try vendor_dir.openFile("version.txt", .{});
    defer vendor_version.close();

    // Compare version files to figure out if we need to rebuild dependencies.
    const should_rebuild = blk: {
        var external_version = external_dir.openFile("version.txt", .{}) catch |err| {
            switch (err) {
                error.FileNotFound => break :blk true,
                else => return err,
            }
        };
        defer external_version.close();

        const ven_content = try vendor_version.readToEndAlloc(gpa.allocator(), 6000);
        defer gpa.allocator().free(ven_content);
        const ext_content = try external_version.readToEndAlloc(gpa.allocator(), 6000);
        defer gpa.allocator().free(ext_content);
        break :blk !std.mem.eql(u8, ven_content, ext_content);
    };

    if (should_rebuild) {
        std.debug.print("external/version.txt is outdated, rebuilding vendored dependencies\n", .{});

        // Update submodules
        var git_submodule_update = std.process.Child.init(
            &.{ "git", "submodule", "update", "--init", "--recursive" },
            gpa.allocator(),
        );
        const update_term = try git_submodule_update.spawnAndWait();
        if (std.meta.activeTag(update_term) != .Exited or update_term.Exited != 0) {
            return error.SubmoduleUpdateFailed;
        }

        try buildSDL(gpa.allocator(), vendor_dir, external_dir);
        try buildSDLShadercross(gpa.allocator(), vendor_dir, external_dir);

        try vendor_dir.copyFile("version.txt", external_dir, "version.txt", .{});
    } else {
        std.debug.print("external/version.txt is up to date, skipping vendored dependencies rebuild\n", .{});
    }
}

fn buildSDL(allocator: std.mem.Allocator, vendor_dir: std.fs.Dir, external_dir: std.fs.Dir) !void {
    var sdl_src_dir = try vendor_dir.openDir("SDL", .{});
    defer sdl_src_dir.close();
    sdl_src_dir.makeDir("build") catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    var build_dir = try sdl_src_dir.openDir("build", .{});
    defer build_dir.close();

    const src_path = try sdl_src_dir.realpathAlloc(allocator, ".");
    defer allocator.free(src_path);
    const build_path = try sdl_src_dir.realpathAlloc(allocator, "build");
    defer allocator.free(build_path);

    var cmake_generate = std.process.Child.init(
        &.{ "cmake", "-S", src_path, "-B", build_path },
        allocator,
    );
    const generate_term = try cmake_generate.spawnAndWait();
    if (std.meta.activeTag(generate_term) != .Exited or generate_term.Exited != 0) {
        return error.CMakeGenerateFailed;
    }

    var cmake_build = std.process.Child.init(
        &.{ "cmake", "--build", build_path, "-j", "16" },
        allocator,
    );
    const build_term = try cmake_build.spawnAndWait();
    if (std.meta.activeTag(build_term) != .Exited or build_term.Exited != 0) {
        return error.CMakeBuildFailed;
    }

    try external_dir.deleteTree("SDL");

    try copyDir(allocator, sdl_src_dir, "build", external_dir, "SDL/lib", .{
        .include_extensions = &.{".dylib"},
        .verbose = true,
    });
    try copyDir(allocator, sdl_src_dir, "include", external_dir, "SDL/include", .{
        .verbose = true,
        .recursive = true,
    });
}

fn buildSDLShadercross(allocator: std.mem.Allocator, vendor_dir: std.fs.Dir, external_dir: std.fs.Dir) !void {
    vendor_dir.makePath("SDL_shadercross/build") catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    const sdl_build_path = try vendor_dir.realpathAlloc(allocator, "SDL/build");
    defer allocator.free(sdl_build_path);
    const sdl_cmake_opt = try std.fmt.allocPrint(allocator, "-DSDL3_DIR={s}", .{sdl_build_path});
    defer allocator.free(sdl_cmake_opt);
    const src_path = try vendor_dir.realpathAlloc(allocator, "SDL_shadercross");
    defer allocator.free(src_path);
    const build_path = try vendor_dir.realpathAlloc(allocator, "SDL_shadercross/build");
    defer allocator.free(build_path);

    var cmake_generate = std.process.Child.init(
        &.{
            "cmake",
            "-S",
            src_path,
            "-B",
            build_path,
            sdl_cmake_opt,
            "-DSDLSHADERCROSS_VENDORED=ON",
            "-DSDLSHADERCROSS_STATIC=ON",
            "-DSDLSHADERCROSS_SHARED=OFF",
        },
        allocator,
    );
    const generate_term = try cmake_generate.spawnAndWait();
    if (std.meta.activeTag(generate_term) != .Exited or generate_term.Exited != 0) {
        return error.CMakeGenerateFailed;
    }

    var cmake_build = std.process.Child.init(
        &.{ "cmake", "--build", build_path, "-j", "16" },
        allocator,
    );
    const build_term = try cmake_build.spawnAndWait();
    if (std.meta.activeTag(build_term) != .Exited or build_term.Exited != 0) {
        return error.CMakeBuildFailed;
    }

    try external_dir.deleteTree("SDL_shadercross");

    try copyDir(
        allocator,
        vendor_dir,
        "SDL_shadercross/build",
        external_dir,
        "SDL_shadercross/lib",
        .{ .include_extensions = &.{".a"}, .verbose = true },
    );
    try copyDir(
        allocator,
        vendor_dir,
        "SDL_shadercross/build/external",
        external_dir,
        "SDL_shadercross/lib",
        .{
            .include_extensions = &.{".dylib"},
            .verbose = true,
            .recursive = true,
            .mirror_source_directory_tree = false,
        },
    );
    const libspirv_realpath = try external_dir.realpathAlloc(
        allocator,
        "SDL_shadercross/lib/libspirv-cross-c-shared.0.64.0.dylib",
    );
    defer allocator.free(libspirv_realpath);
    try external_dir.symLink(
        libspirv_realpath,
        "SDL_shadercross/lib/libspirv-cross-c-shared.0.dylib",
        .{},
    );
    try copyDir(
        allocator,
        vendor_dir,
        "SDL_shadercross/include",
        external_dir,
        "SDL_shadercross/include",
        .{ .verbose = true, .recursive = true },
    );

    var bin_dir = try external_dir.makeOpenPath("SDL_shadercross/bin", .{});
    defer bin_dir.close();

    try vendor_dir.copyFile("SDL_shadercross/build/shadercross", bin_dir, "shadercross", .{});
}

const CopyDirOpt = struct {
    include_extensions: []const []const u8 = &.{},
    mirror_source_directory_tree: bool = true,
    recursive: bool = false,
    verbose: bool = false,
};

fn copyDir(
    allocator: std.mem.Allocator,
    src_dir: std.fs.Dir,
    src_subdir: []const u8,
    dst_dir: std.fs.Dir,
    dst_subdir: []const u8,
    options: CopyDirOpt,
) !void {
    var src = try src_dir.openDir(src_subdir, .{ .iterate = true });
    defer src.close();

    const src_abs = try src.realpathAlloc(allocator, ".");
    defer allocator.free(src_abs);

    var dst = try dst_dir.makeOpenPath(dst_subdir, .{});
    defer dst.close();

    const dst_abs = try dst.realpathAlloc(allocator, ".");
    defer allocator.free(dst_abs);

    if (options.recursive) {
        var walker = try src.walk(allocator);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            switch (entry.kind) {
                .file => try copyFile(
                    entry.path,
                    entry.path[0 .. entry.path.len - entry.basename.len],
                    src,
                    dst,
                    options.include_extensions,
                    options.mirror_source_directory_tree,
                    options.verbose,
                ),
                .directory, .sym_link => {}, // Intentionally empty
                else => return error.UnexpectedEntryKind,
            }
        }
    } else {
        var it = src.iterate();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .file => try copyFile(
                    entry.name,
                    ".",
                    src,
                    dst,
                    options.include_extensions,
                    options.mirror_source_directory_tree,
                    options.verbose,
                ),
                .directory, .sym_link => {}, // Intentionally empty
                else => return error.UnexpectedEntryKind,
            }
        }
    }
}

fn copyFile(
    rel_path: []const u8,
    dir_path: []const u8,
    src: std.fs.Dir,
    dst: std.fs.Dir,
    include_extensions: []const []const u8,
    mirror_source_directory_tree: bool,
    verbose: bool,
) !void {
    const extension = std.fs.path.extension(rel_path);
    const should_copy = include_extensions.len == 0 or blk: {
        for (include_extensions) |ext| {
            if (std.mem.eql(u8, ext, extension)) {
                break :blk true;
            }
        }
        break :blk false;
    };
    if (should_copy) {
        // const dirpath = entry.path[0 .. entry.path.len - entry.basename.len];
        if (mirror_source_directory_tree) {
            dst.makePath(dir_path) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                }
            };
        }
        const dst_rel_path = if (mirror_source_directory_tree)
            rel_path
        else
            std.fs.path.basename(rel_path);
        try src.copyFile(rel_path, dst, dst_rel_path, .{});
        if (verbose) {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = try dst.realpath(dst_rel_path, &buf);
            std.debug.print("Copied \"{s}\"\n", .{path});
        }
    }
}
