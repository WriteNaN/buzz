const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const _vm = @import("vm.zig");
const VM = _vm.VM;
const RunFlavor = _vm.RunFlavor;
const ImportRegistry = _vm.ImportRegistry;
const Parser = @import("Parser.zig");
const CodeGen = @import("Codegen.zig");
const _obj = @import("obj.zig");
const ObjString = _obj.ObjString;
const ObjTypeDef = _obj.ObjTypeDef;
const TypeRegistry = @import("memory.zig").TypeRegistry;
const Ast = @import("Ast.zig");
const BuildOptions = @import("build_options");
const clap = @import("ext/clap/clap.zig");
const GarbageCollector = @import("memory.zig").GarbageCollector;
const JIT = if (!is_wasm) @import("Jit.zig") else void;
const is_wasm = builtin.cpu.arch.isWasm();
const repl = if (!is_wasm) @import("repl.zig").repl else void;
const wasm_repl = @import("wasm_repl.zig");

pub export const initRepl_export = wasm_repl.initRepl;
pub export const runLine_export = wasm_repl.runLine;

pub const os = if (is_wasm)
    @import("wasm.zig")
else
    std.os;

fn printBanner(out: std.fs.File.Writer, full: bool) void {
    out.print(
        "\n👨‍🚀 buzz {s}-{s} Copyright (C) 2021-present Benoit Giannangeli\n",
        .{
            if (BuildOptions.version.len > 0) BuildOptions.version else "unreleased",
            BuildOptions.sha,
        },
    ) catch unreachable;

    if (full) {
        out.print(
            "Built with Zig {} {s}\nAllocator: {s}, Memory limit: {} {s}\nJIT: {s}, CPU limit: {} {s}\n",
            .{
                builtin.zig_version,
                switch (builtin.mode) {
                    .ReleaseFast => "release-fast",
                    .ReleaseSafe => "release-safe",
                    .ReleaseSmall => "release-small",
                    .Debug => "debug",
                },
                if (builtin.mode == .Debug)
                    "gpa"
                else if (BuildOptions.mimalloc) "mimalloc" else "c_allocator",
                if (BuildOptions.memory_limit) |ml|
                    ml
                else
                    0,
                if (BuildOptions.memory_limit != null)
                    "bytes"
                else
                    "(unlimited)",
                if (BuildOptions.jit and BuildOptions.cycle_limit == null)
                    "on"
                else
                    "off",
                if (BuildOptions.cycle_limit) |cl| cl else 0,
                if (BuildOptions.cycle_limit != null) "cycles" else "(unlimited)",
            },
        ) catch unreachable;
    }
}

fn runFile(allocator: Allocator, file_name: []const u8, args: [][:0]u8, flavor: RunFlavor) !void {
    var total_timer = if (!is_wasm) std.time.Timer.start() catch unreachable else {};
    var import_registry = ImportRegistry.init(allocator);
    var gc = GarbageCollector.init(allocator);
    gc.type_registry = TypeRegistry{
        .gc = &gc,
        .registry = std.StringHashMap(*ObjTypeDef).init(allocator),
    };
    var imports = std.StringHashMap(Parser.ScriptImport).init(allocator);
    var vm = try VM.init(&gc, &import_registry, flavor);
    vm.jit = if (BuildOptions.jit and BuildOptions.cycle_limit == null)
        JIT.init(&vm)
    else
        null;
    defer {
        if (!is_wasm and vm.jit != null) {
            vm.jit.?.deinit();
            vm.jit = null;
        }
    }
    var parser = Parser.init(
        &gc,
        &imports,
        false,
        flavor,
    );
    var codegen = CodeGen.init(
        &gc,
        &parser,
        flavor,
        if (vm.jit) |*jit| jit else null,
    );
    defer {
        codegen.deinit();
        vm.deinit();
        parser.deinit();
        // gc.deinit();
        var it = imports.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.globals.deinit();
        }
        imports.deinit();
        // TODO: free type_registry and its keys which are on the heap
    }

    var file = (if (std.fs.path.isAbsolute(file_name))
        std.fs.openFileAbsolute(file_name, .{})
    else
        std.fs.cwd().openFile(file_name, .{})) catch {
        std.debug.print("File not found", .{});
        return;
    };
    defer file.close();

    const source = try allocator.alloc(u8, (try file.stat()).size);
    defer allocator.free(source);

    _ = try file.readAll(source);

    var timer = try std.time.Timer.start();
    var parsing_time: u64 = undefined;
    var codegen_time: u64 = undefined;
    var running_time: u64 = undefined;

    if (try parser.parse(source, file_name)) |ast| {
        if (!is_wasm) {
            parsing_time = timer.read();
            timer.reset();
        }

        if (flavor == .Run or flavor == .Test) {
            if (try codegen.generate(ast)) |function| {
                if (!is_wasm) {
                    codegen_time = timer.read();
                    timer.reset();
                }

                try vm.interpret(
                    ast,
                    function,
                    args,
                );

                if (!is_wasm) {
                    running_time = timer.read();
                }
            } else {
                return Parser.CompileError.Recoverable;
            }

            if (BuildOptions.show_perf and flavor != .Check and flavor != .Fmt) {
                const parsing_ms = @as(f64, @floatFromInt(parsing_time)) / 1000000;
                const codegen_ms = @as(f64, @floatFromInt(codegen_time)) / 1000000;
                const running_ms = @as(f64, @floatFromInt(running_time)) / 1000000;
                const gc_ms = @as(f64, @floatFromInt(gc.gc_time)) / 1000000;
                const jit_ms = if (vm.jit) |jit|
                    @as(f64, @floatFromInt(jit.jit_time)) / 1000000
                else
                    0;
                std.debug.print(
                    "\u{001b}[2mParsing: {d} ms\nCodegen: {d} ms\nRun: {d} ms\nJIT: {d} ms\nGC: {d} ms\nTotal: {d} ms\nFull GC: {} | GC: {} | Max allocated: {} bytes\n\u{001b}[0m",
                    .{
                        parsing_ms,
                        codegen_ms,
                        running_ms,
                        jit_ms,
                        gc_ms,
                        @as(f64, @floatFromInt(if (!is_wasm) total_timer.read() else 0)) / 1000000,
                        gc.full_collection_count,
                        gc.light_collection_count,
                        gc.max_allocated,
                    },
                );
            }
        } else {
            std.debug.print("Formatting and Ast dump is deactivated", .{});
            // switch (flavor) {
            //     .Run, .Test => unreachable,
            //     .Fmt => {
            //         var formatted = std.ArrayList(u8).init(allocator);
            //         defer formatted.deinit();
            //
            //         try function_node.render(function_node, &formatted.writer(), 0);
            //
            //         std.debug.print("{s}", .{formatted.items});
            //     },
            //     .Ast => {
            //         var json = std.ArrayList(u8).init(allocator);
            //         defer json.deinit();
            //
            //         try function_node.toJson(function_node, &json.writer());
            //
            //         var without_nl = try std.mem.replaceOwned(u8, allocator, json.items, "\n", " ");
            //         defer allocator.free(without_nl);
            //
            //         _ = try std.io.getStdOut().write(without_nl);
            //     },
            //     else => {},
            // }
        }
    } else {
        return Parser.CompileError.Recoverable;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = builtin.mode == .Debug }){};
    var allocator: std.mem.Allocator = if (builtin.mode == .Debug or is_wasm)
        gpa.allocator()
    else if (BuildOptions.mimalloc)
        @import("mimalloc.zig").mim_allocator
    else
        std.heap.c_allocator;

    const params = comptime clap.parseParamsComptime(
        \\-h, --help             Show help and exit
        \\-t, --test             Run test blocks in provided script
        \\-c, --check            Check script for error without running it
        \\-f, --fmt              Format script
        \\-a, --tree             Dump AST as JSON
        \\-v, --version          Print version and exit
        \\-L, --library <str>... Add search path for external libraries
        \\<str>...
        \\
    );

    var diag = clap.Diagnostic{};
    var res = clap.parse(
        clap.Help,
        &params,
        clap.parsers.default,
        .{
            .allocator = allocator,
            .diagnostic = &diag,
        },
    ) catch |err| {
        // Report useful error and exit
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    defer res.deinit();

    if (res.args.version == 1) {
        printBanner(std.io.getStdOut().writer(), true);

        if (!is_wasm) {
            std.posix.exit(0);
        }
    }

    if (res.args.help == 1) {
        std.debug.print("👨‍🚀 buzz A small/lightweight typed scripting language\n\nUsage: buzz ", .{});

        try clap.usage(
            std.io.getStdErr().writer(),
            clap.Help,
            &params,
        );

        std.debug.print("\n\n", .{});

        try clap.help(
            std.io.getStdErr().writer(),
            clap.Help,
            &params,
            .{
                .description_on_new_line = false,
                .description_indent = 4,
                .spacing_between_parameters = 0,
            },
        );

        if (!is_wasm) {
            std.posix.exit(0);
        }
    }

    if (res.args.library.len > 0) {
        var list = std.ArrayList([]const u8).init(allocator);
        defer list.shrinkAndFree(list.items.len);

        for (res.args.library) |path| {
            try list.append(path);
        }

        Parser.user_library_paths = list.items;
    }

    var positionals = std.ArrayList([:0]u8).init(allocator);
    for (res.positionals) |pos| {
        try positionals.append(try allocator.dupeZ(u8, pos));
    }
    defer {
        for (positionals.items) |pos| {
            allocator.free(pos);
        }
        positionals.deinit();
    }

    const flavor: RunFlavor = if (res.args.check == 1)
        .Check
    else if (res.args.@"test" == 1)
        .Test
    else if (res.args.fmt == 1)
        .Fmt
    else if (res.args.tree == 1)
        .Ast
    else if (res.positionals.len == 0)
        .Repl
    else
        .Run;

    if (!is_wasm and flavor == .Repl) {
        repl(allocator) catch {
            if (!is_wasm) {
                std.posix.exit(1);
            }

            std.debug.print("REPL stopped", .{});
        };
    } else if (!is_wasm and positionals.items.len > 0) {
        runFile(
            allocator,
            res.positionals[0],
            positionals.items[1..],
            flavor,
        ) catch {
            if (!is_wasm) {
                std.posix.exit(1);
            }

            std.debug.print("VM stopped", .{});
        };
    } else if (is_wasm) {
        std.debug.print("NYI wasm repl", .{});
    } else {
        std.debug.print("Nothing to run", .{});
    }

    if (!is_wasm) {
        std.posix.exit(0);
    }
}

test "Testing behavior" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = builtin.mode == .Debug,
    }){};
    var allocator: Allocator = gpa.allocator();

    var count: usize = 0;
    var fail_count: usize = 0;
    {
        var test_dir = try std.fs.cwd().openDir(
            "tests",
            .{
                .iterate = true,
            },
        );
        var it = test_dir.iterate();

        while (try it.next()) |file| : (count += 1) {
            if (file.kind == .file and std.mem.endsWith(u8, file.name, ".buzz")) {
                const file_name: []u8 = try allocator.alloc(u8, 6 + file.name.len);
                defer allocator.free(file_name);

                std.debug.print("{s}\n", .{file.name});

                var had_error: bool = false;
                runFile(
                    allocator,
                    try std.fmt.bufPrint(file_name, "tests/{s}", .{file.name}),
                    &[_][:0]u8{},
                    .Test,
                ) catch {
                    std.debug.print("\u{001b}[31m[{s} ✕]\u{001b}[0m\n", .{file.name});
                    had_error = true;
                    fail_count += 1;
                };

                if (!had_error) {
                    std.debug.print("\u{001b}[32m[{s} ✓]\u{001b}[0m\n", .{file.name});
                }
            }
        }
    }

    {
        var test_dir = try std.fs.cwd().openDir(
            "tests/compile_errors",
            .{
                .iterate = true,
            },
        );
        var it = test_dir.iterate();

        while (try it.next()) |file| : (count += 1) {
            if (file.kind == .file and std.mem.endsWith(u8, file.name, ".buzz")) {
                const file_name: []u8 = try allocator.alloc(u8, 21 + file.name.len);
                defer allocator.free(file_name);
                _ = try std.fmt.bufPrint(file_name, "tests/compile_errors/{s}", .{file.name});

                // First line of test file is expected error message
                const test_file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
                const reader = test_file.reader();
                const first_line = try reader.readUntilDelimiterAlloc(allocator, '\n', std.math.maxInt(usize));
                defer allocator.free(first_line);
                const arg0 = std.fmt.allocPrintZ(allocator, "{s}/bin/buzz", .{Parser.buzzPrefix()}) catch unreachable;
                defer allocator.free(arg0);

                const result = try std.ChildProcess.run(
                    .{
                        .allocator = allocator,
                        .argv = ([_][]const u8{
                            arg0,
                            "-t",
                            file_name,
                        })[0..],
                    },
                );

                if (!std.mem.containsAtLeast(u8, result.stderr, 1, first_line[2..])) {
                    fail_count += 1;
                    std.debug.print(
                        "Expected error `{s}` got `{s}`\n",
                        .{
                            first_line[2..],
                            result.stderr,
                        },
                    );

                    std.debug.print("\u{001b}[31m[{s}... ✕]\u{001b}[0m\n", .{file.name});
                } else {
                    std.debug.print("\u{001b}[32m[{s}... ✓]\u{001b}[0m\n", .{file.name});
                }
            }
        }
    }

    if (fail_count == 0) {
        std.debug.print("\n\u{001b}[32m", .{});
    } else {
        std.debug.print("\n\u{001b}[31m", .{});
    }

    std.debug.print("Ran {}, Failed: {}\u{001b}[0m\n", .{
        count,
        fail_count,
    });

    std.posix.exit(if (fail_count == 0) 0 else 1);
}
