const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const VM = @import("./vm.zig").VM;
const Compiler = @import("./compiler.zig").Compiler;
const ObjString = @import("./obj.zig").ObjString;

// Using a global because of vm.stack which would overflow zig's stack

fn repl(allocator: *Allocator, args: ?[][:0]u8) !void {
    var strings = std.StringHashMap(*ObjString).init(allocator);
    var imports = std.StringHashMap(Compiler.ScriptImport).init(allocator);
    var vm = try VM.init(allocator, &strings, null);
    var compiler = Compiler.init(allocator, &strings, &imports, false);
    defer {
        vm.deinit();
        compiler.deinit();
        strings.deinit();
        var it = imports.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.globals.deinit();
        }
        imports.deinit();
    }

    std.debug.print("👨‍🚀 buzz 0.0.1 (C) 2021 Benoit Giannangeli\n", .{});
    while (true) {
        std.debug.print("→ ", .{});

        var line = [_]u8{0} ** 1024;
        _ = try std.io.getStdIn().read(line[0..]);

        if (line.len > 0) {
            if (try compiler.compile(line[0..], "<repl>", false)) |function| {
                _ = try vm.interpret(function, args);
            }
        }
    }
}

fn runFile(allocator: *Allocator, file_name: []const u8, args: ?[][:0]u8, testing: bool) !void {
    var strings = std.StringHashMap(*ObjString).init(allocator);
    var imports = std.StringHashMap(Compiler.ScriptImport).init(allocator);
    var vm = try VM.init(allocator, &strings, null);
    var compiler = Compiler.init(allocator, &strings, &imports, false);
    defer {
        vm.deinit();
        compiler.deinit();
        strings.deinit();
        var it = imports.iterator();
        while (it.next()) |kv| {
            kv.value_ptr.*.globals.deinit();
        }
        imports.deinit();
    }
    
    var file = std.fs.cwd().openFile(file_name, .{}) catch {
        std.debug.warn("File not found", .{});
        return;
    };
    defer file.close();
    
    const source = try allocator.alloc(u8, (try file.stat()).size);
    defer allocator.free(source);
    
    _ = try file.readAll(source);

    if (try compiler.compile(source, file_name, testing)) |function| {
        _ = try vm.interpret(function, args);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .safety = true }){};
    var allocator: *Allocator = if (builtin.mode == .Debug)
            &gpa.allocator
        else
            std.heap.c_allocator;

    var args: [][:0]u8 = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // TODO: use https://github.com/Hejsil/zig-clap
    var testing: bool = false;
    for (args) |arg, index| {
        if (index > 0) {
            if (index == 1 and std.mem.eql(u8, arg, "test")) {
                testing = true;
            } else {
                runFile(allocator, arg, args[index..], testing) catch {
                    // TODO: should probably choses appropriate error code
                    std.os.exit(1);
                };

                std.os.exit(0);
            }
        }
    }
}


test "Testing buzz" {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }){};
    var allocator: *Allocator = if (builtin.mode == .Debug)
        &gpa.allocator
    else
        std.heap.c_allocator;

    var test_dir = try std.fs.cwd().openDir("tests", .{ .iterate = true });
    var it = test_dir.iterate();

    while (try it.next()) |file| {
        if (file.kind == .File) {
            var file_name: []u8 = try allocator.alloc(u8, 6 + file.name.len);
            defer allocator.free(file_name);

            var had_error: bool = false;
            runFile(allocator, try std.fmt.bufPrint(file_name, "tests/{s}", .{file.name}), null, true) catch {
                std.debug.warn("\u{001b}[31m[{s}... ✕]\u{001b}[0m\n", .{file.name});
                had_error = true;
            };

            if (!had_error) {
                std.debug.warn("\u{001b}[32m[{s}... ✔️]\u{001b}[0m\n", .{file.name});
            }
        }
    }
}