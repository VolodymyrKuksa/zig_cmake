const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    b.build_root.handle.makePath("ext") catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };
    var ext_dir = b.build_root.handle.openDir("ext", .{}) catch unreachable;
    defer ext_dir.close();

    var cmake_deps = prepareExternal(gpa.allocator(), b, target, optimize, ext_dir) catch |err| {
        std.debug.panic("Failed to prepare external dependencies: {}", .{err});
    };
    defer cmake_deps.deinit(gpa.allocator());

    const sc_mod = b.addModule("SDL_shadercross", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/sdl_shadercross.zig"),
        .link_libc = true,
    });

    const build_root = try b.build_root.handle.realpathAlloc(gpa.allocator(), ".");
    defer gpa.allocator().free(build_root);
    const ext_install_dir = try std.fmt.allocPrint(gpa.allocator(), "{s}/ext/", .{b.install_prefix});
    defer gpa.allocator().free(ext_install_dir);
    const ext_install_subdir = try std.fs.path.relative(gpa.allocator(), build_root, ext_install_dir);
    defer gpa.allocator().free(ext_install_subdir);

    sc_mod.addIncludePath(b.path(cmake_deps.sdl_include_path));
    sc_mod.addLibraryPath(b.path(cmake_deps.sdl_lib_path));
    sc_mod.addIncludePath(b.path(cmake_deps.sdl_shadercross_include_path));
    sc_mod.addLibraryPath(b.path(cmake_deps.sdl_shadercross_lib_path));
    sc_mod.addLibraryPath(b.path(ext_install_subdir));

    sc_mod.linkSystemLibrary("SDL3.0", .{ .needed = true });
    sc_mod.linkSystemLibrary("SDL3_shadercross", .{ .needed = true });
    sc_mod.linkSystemLibrary("dxcompiler", .{ .needed = true });
    sc_mod.linkSystemLibrary("spirv-cross-c-shared.0.67.0", .{ .needed = true });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    b.installFile(
        try std.fmt.bufPrint(&buf, "{s}/libSDL3.0.dylib", .{cmake_deps.sdl_lib_path}),
        "ext/libSDL3.0.dylib",
    );
    b.installFile(
        try std.fmt.bufPrint(&buf, "{s}/libdxcompiler.dylib", .{cmake_deps.sdl_shadercross_lib_path}),
        "ext/libdxcompiler.dylib",
    );
    b.installFile(
        try std.fmt.bufPrint(&buf, "{s}/libspirv-cross-c-shared.0.67.0.dylib", .{cmake_deps.sdl_shadercross_lib_path}),
        "ext/libspirv-cross-c-shared.0.dylib",
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
    run_tests.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}

const ExternalOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ext_dir: std.fs.Dir,
    dependency: []const u8,
    ext_subdir: []const u8,
    include_subdir: ?[]const u8 = null,
    copy_bin: bool = false,
    additional_cmake_generate_options: []const []const u8 = &.{},
};

const CMakeDependencies = struct {
    fn init(
        allocator: std.mem.Allocator,
        sdl_include_path: []const u8,
        sdl_lib_path: []const u8,
        sdl_shadercross_include_path: []const u8,
        sdl_shadercross_lib_path: []const u8,
    ) !CMakeDependencies {
        return .{
            .sdl_include_path = try allocator.dupe(u8, sdl_include_path),
            .sdl_lib_path = try allocator.dupe(u8, sdl_lib_path),
            .sdl_shadercross_include_path = try allocator.dupe(u8, sdl_shadercross_include_path),
            .sdl_shadercross_lib_path = try allocator.dupe(u8, sdl_shadercross_lib_path),
        };
    }

    fn deinit(self: *CMakeDependencies, allocator: std.mem.Allocator) void {
        allocator.free(self.sdl_include_path);
        allocator.free(self.sdl_lib_path);
        allocator.free(self.sdl_shadercross_include_path);
        allocator.free(self.sdl_shadercross_lib_path);
    }

    sdl_include_path: []const u8,
    sdl_lib_path: []const u8,
    sdl_shadercross_include_path: []const u8,
    sdl_shadercross_lib_path: []const u8,
};

fn prepareExternal(
    allocator: std.mem.Allocator,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ext_dir: std.fs.Dir,
) !CMakeDependencies {
    var sdl_info = try generateAndBuildCMakeDependency(allocator, b, .{
        .target = target,
        .optimize = optimize,
        .ext_dir = ext_dir,
        .dependency = "sdl",
        .ext_subdir = "SDL",
        .include_subdir = "include/SDL3",
    });
    defer sdl_info.deinit(allocator);

    const sdl_dir_opt = try std.fmt.allocPrint(allocator, "-DSDL3_DIR={s}", .{
        sdl_info.build_path,
    });
    defer allocator.free(sdl_dir_opt);

    // Check if already downloaded?
    download_external: {
        const shadercross_dep = b.dependency("sdl_shadercross", .{});
        const shadercross_path = shadercross_dep.path(".").getPath(b);
        var shadercross_dir = try std.fs.openDirAbsolute(shadercross_path, .{});
        defer shadercross_dir.close();
        const download_script = shadercross_dir.realpathAlloc(allocator, "external/download.sh") catch {
            break :download_external;
        };
        defer allocator.free(download_script);
        std.fs.accessAbsolute(download_script, .{}) catch {
            break :download_external;
        };
        var download = std.process.Child.init(&.{download_script}, allocator);
        download.cwd_dir = shadercross_dir;
        _ = try download.spawnAndWait();
    }

    var shadercross_info = try generateAndBuildCMakeDependency(allocator, b, .{
        .target = target,
        .optimize = optimize,
        .ext_dir = ext_dir,
        .dependency = "sdl_shadercross",
        .ext_subdir = "SDL_shadercross",
        .include_subdir = "include/SDL3_shadercross",
        .copy_bin = true,
        .additional_cmake_generate_options = &.{
            sdl_dir_opt,
            "-DSDLSHADERCROSS_VENDORED=ON",
        },
    });
    defer shadercross_info.deinit(allocator);

    return try .init(
        allocator,
        sdl_info.ext_include_path.?,
        sdl_info.ext_lib_path,
        shadercross_info.ext_include_path.?,
        shadercross_info.ext_lib_path,
    );
}

const CMakeDependencyInfo = struct {
    fn init(
        allocator: std.mem.Allocator,
        build_path: []const u8,
        ext_include_path: ?[]const u8,
        ext_lib_path: []const u8,
    ) !CMakeDependencyInfo {
        return .{
            .build_path = try allocator.dupe(u8, build_path),
            .ext_include_path = if (ext_include_path) |path| try allocator.dupe(u8, path) else null,
            .ext_lib_path = try allocator.dupe(u8, ext_lib_path),
        };
    }

    fn deinit(self: *CMakeDependencyInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.build_path);
        if (self.ext_include_path) |include_path| {
            allocator.free(include_path);
        }
        allocator.free(self.ext_lib_path);
    }

    build_path: []const u8,
    ext_include_path: ?[]const u8,
    ext_lib_path: []const u8,
};

fn generateAndBuildCMakeDependency(
    allocator: std.mem.Allocator,
    b: *std.Build,
    opts: ExternalOptions,
) !CMakeDependencyInfo {
    if (opts.target.result.os.tag != builtin.target.os.tag or
        opts.target.result.cpu.arch != builtin.target.cpu.arch)
    {
        return error.CrossCompilationNotSupported;
    }

    const dep_hash = try getDependencyHash(b, opts.dependency);

    const triple = try opts.target.result.zigTriple(allocator);
    defer allocator.free(triple);
    const triple_mod = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
        triple,
        @tagName(opts.optimize),
    });
    defer allocator.free(triple_mod);
    const ext_subpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
        opts.ext_subdir,
        triple_mod,
    });
    defer allocator.free(ext_subpath);
    const hash_subpath = try std.fmt.allocPrint(allocator, "{s}/hash.txt", .{ext_subpath});
    defer allocator.free(hash_subpath);

    const dependency = b.dependency(opts.dependency, .{});
    const dep_path = dependency.path(".").getPath(b);
    var dep_dir = try std.fs.openDirAbsolute(dep_path, .{});
    defer dep_dir.close();
    var build_dir = blk: {
        const relpath = try std.fmt.allocPrint(allocator, "build/{s}", .{triple_mod});
        defer allocator.free(relpath);
        dep_dir.makePath(relpath) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        break :blk try dep_dir.openDir(relpath, .{});
    };
    defer build_dir.close();
    const build_path = try build_dir.realpathAlloc(allocator, ".");
    defer allocator.free(build_path);

    var inc_path: ?[]const u8 = null;
    if (opts.include_subdir) |include_subdir| {
        inc_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            ext_subpath,
            include_subdir,
        });
    }
    defer {
        if (inc_path) |path| {
            allocator.free(path);
        }
    }

    const ext_lib_path = try std.fmt.allocPrint(allocator, "{s}/lib", .{ext_subpath});
    defer allocator.free(ext_lib_path);

    const build_root = try b.build_root.handle.realpathAlloc(allocator, ".");
    defer allocator.free(build_root);

    var info: CMakeDependencyInfo = undefined;
    {
        var inc_buf: [std.fs.max_path_bytes]u8 = undefined;
        var lib_buf: [std.fs.max_path_bytes]u8 = undefined;

        var rel_inc_path: ?[]const u8 = null;
        if (inc_path) |include_path| {
            opts.ext_dir.makePath(include_path) catch |err| {
                switch (err) {
                    error.PathAlreadyExists => {},
                    else => return err,
                }
            };
            const abs_path = try opts.ext_dir.realpathAlloc(allocator, include_path);
            defer allocator.free(abs_path);
            const rel_path = try std.fs.path.relative(allocator, build_root, abs_path);
            defer allocator.free(rel_path);
            const base = std.fs.path.dirname(rel_path) orelse return error.InvalidIncludePath;
            std.mem.copyForwards(u8, &inc_buf, base);
            rel_inc_path = inc_buf[0..base.len];
        }
        opts.ext_dir.makePath(ext_lib_path) catch |err| {
            switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            }
        };
        const abs_path = try opts.ext_dir.realpathAlloc(allocator, ext_lib_path);
        defer allocator.free(abs_path);
        const rel_path = try std.fs.path.relative(allocator, build_root, abs_path);
        defer allocator.free(rel_path);
        std.mem.copyForwards(u8, &lib_buf, rel_path);
        const lib_path = lib_buf[0..rel_path.len];

        info = try .init(allocator, build_path, rel_inc_path, lib_path);
    }

    const should_rebuild = blk: {
        var hash_file = opts.ext_dir.openFile(hash_subpath, .{}) catch break :blk true;
        defer hash_file.close();
        const contents = try hash_file.readToEndAlloc(allocator, 2048);
        defer allocator.free(contents);
        break :blk !std.mem.eql(u8, dep_hash, contents);
    };
    if (!should_rebuild) {
        std.debug.print("CMake dependency up to date - {s}\n", .{opts.dependency});
        return info;
    }

    const cmake_build_type = switch (opts.optimize) {
        .Debug => "Debug",
        .ReleaseFast => "Release",
        .ReleaseSafe => "ReleaseWithDebInfo",
        .ReleaseSmall => "MinSizeRel",
    };
    const cmake_build_type_option = try std.fmt.allocPrint(
        allocator,
        "-DCMAKE_BUILD_TYPE={s}",
        .{cmake_build_type},
    );
    defer allocator.free(cmake_build_type_option);

    const default_options: []const []const u8 = &.{
        "cmake",
        cmake_build_type_option,
        "-S",
        dep_path,
        "-B",
        build_path,
    };
    var all_options = try allocator.alloc([]const u8, default_options.len +
        opts.additional_cmake_generate_options.len);
    defer allocator.free(all_options);

    for (default_options, 0..) |option, i| {
        all_options[i] = option;
    }
    for (opts.additional_cmake_generate_options, 0..) |option, i| {
        all_options[default_options.len + i] = option;
    }

    var cmake_generate = std.process.Child.init(all_options, allocator);
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

    try opts.ext_dir.deleteTree(ext_subpath);

    {
        try copyDir(allocator, build_dir, ".", opts.ext_dir, ext_lib_path, .{
            .include_extensions = &.{
                opts.target.result.dynamicLibSuffix(),
                opts.target.result.staticLibSuffix(),
            },
            .verbose = true,
            .recursive = true,
            .mirror_source_directory_tree = false,
        });
    }

    if (opts.copy_bin) {
        const bin_subpath = try std.fmt.allocPrint(allocator, "{s}/bin", .{ext_subpath});
        defer allocator.free(bin_subpath);
        try copyDir(allocator, build_dir, ".", opts.ext_dir, bin_subpath, .{
            .exclude_filenames = &.{"Makefile"},
            .include_extensions = &.{opts.target.result.exeFileExt()},
            .verbose = true,
        });
    }

    if (inc_path) |include_path| {
        try copyDir(allocator, dep_dir, opts.include_subdir.?, opts.ext_dir, include_path, .{
            .verbose = true,
            .recursive = true,
        });
    }

    var hash_file = try opts.ext_dir.createFile(hash_subpath, .{});
    defer hash_file.close();

    try hash_file.writeAll(dep_hash);

    return info;
}

fn getDependencyHash(b: *std.Build, name: []const u8) ![]const u8 {
    for (b.available_deps) |dep| {
        if (std.mem.eql(u8, dep[0], name)) return dep[1];
    }
    return error.DependencyHashNotFound;
}

const CopyDirOpt = struct {
    exclude_filenames: []const []const u8 = &.{},
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
        outer: while (try it.next()) |entry| {
            for (options.exclude_filenames) |excluded_name| {
                if (std.mem.eql(u8, excluded_name, entry.name)) {
                    continue :outer;
                }
            }
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
