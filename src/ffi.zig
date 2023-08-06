const std = @import("std");
const Ast = std.zig.Ast;

const o = @import("./obj.zig");
const t = @import("./token.zig");
const m = @import("./memory.zig");
const v = @import("./value.zig");
const ZigType = @import("./zigtypes.zig").Type;
const Reporter = @import("./reporter.zig");

const Self = @This();

gc: *m.GarbageCollector,
reporter: Reporter,
source: t.Token = undefined,
ast: Ast = undefined,

const basic_types = std.ComptimeStringMap(
    o.ObjTypeDef,
    .{
        .{ "u8", .{ .def_type = .Integer } },
        .{ "i8", .{ .def_type = .Integer } },
        .{ "u16", .{ .def_type = .Integer } },
        .{ "i16", .{ .def_type = .Integer } },
        .{ "u32", .{ .def_type = .Integer } },
        .{ "i32", .{ .def_type = .Integer } },

        .{ "f32", .{ .def_type = .Float } },
        .{ "f64", .{ .def_type = .Float } },

        .{ "bool", .{ .def_type = .Bool } },
        .{ "u1", .{ .def_type = .Bool } },
    },
);

const zig_basic_types = std.ComptimeStringMap(
    ZigType,
    .{
        .{
            "u8",
            ZigType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 8,
                },
            },
        },
        .{
            "i8",
            ZigType{
                .Int = .{
                    .signedness = .signed,
                    .bits = 8,
                },
            },
        },
        .{
            "u16",
            ZigType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 16,
                },
            },
        },
        .{
            "i16",
            ZigType{
                .Int = .{
                    .signedness = .signed,
                    .bits = 16,
                },
            },
        },
        .{
            "u32",
            ZigType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 32,
                },
            },
        },
        .{
            "i32",
            ZigType{
                .Int = .{
                    .signedness = .signed,
                    .bits = 32,
                },
            },
        },

        .{
            "f32",
            ZigType{
                .Float = .{
                    .bits = 32,
                },
            },
        },
        .{
            "f64",
            ZigType{
                .Float = .{
                    .bits = 64,
                },
            },
        },

        .{
            "bool",
            ZigType{ .Bool = {} },
        },
        .{
            "u1",
            ZigType{
                .Int = .{
                    .signedness = .unsigned,
                    .bits = 1,
                },
            },
        },
    },
);

pub const Zdef = struct {
    name: []const u8,
    type_def: *o.ObjTypeDef,
    zig_type: ZigType,
};

pub fn parse(self: *Self, zdef: t.Token) !?*Zdef {
    // TODO: maybe an Arena allocator for those kinds of things that can live for the whole process lifetime
    const duped = self.gc.allocator.dupeZ(u8, zdef.literal_string.?) catch @panic("Out of memory");
    // defer self.gc.allocator.free(duped);

    self.source = zdef;
    self.ast = Ast.parse(
        self.gc.allocator,
        duped,
        .zig,
    ) catch @panic("Could not parse zdef");

    for (self.ast.errors) |err| {
        if (!err.is_note) {
            self.reportZigError(err);
        }
    }

    if (self.ast.errors.len > 0) {
        return null;
    }

    const root_decls = self.ast.rootDecls();

    if (root_decls.len > 1) {
        self.reporter.report(
            .zdef,
            self.source,
            "Only one declaration is allowed in zdef",
        );
    } else if (root_decls.len == 0) {
        self.reporter.report(
            .zdef,
            self.source,
            "At least one declaration is required in zdef",
        );

        return null;
    }

    return self.getZdef(root_decls[0]);
}

fn getZdef(self: *Self, decl_index: Ast.Node.Index) !?*Zdef {
    const decl = self.ast.nodes.get(decl_index);

    return switch (decl.tag) {
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => try self.fnProto(decl.tag, decl_index),

        .identifier => try self.identifier(decl_index),

        .ptr_type_aligned,
        .ptr_type_sentinel,
        .ptr_type,
        => try self.ptrType(decl.tag, decl_index),

        else => fail: {
            self.reporter.report(
                .zdef,
                self.source,
                "Unsupported zig node: only C ABI compatible function signatures, structs and enums are supported",
            );
            break :fail null;
        },
    };
}

fn identifier(self: *Self, decl_index: Ast.Node.Index) anyerror!*Zdef {
    const id = self.ast.tokenSlice(self.ast.nodes.get(decl_index).main_token);

    const type_def = if (basic_types.get(id)) |basic_type|
        basic_type
    else
        null;
    const zig_type = if (zig_basic_types.get(id)) |zig_basic_type|
        zig_basic_type
    else
        null;

    if (type_def == null or zig_type == null) {
        // TODO: search for struct names
        self.reporter.report(
            .zdef,
            self.source,
            "Unknown or unsupported type",
        );
    }

    var zdef = try self.gc.allocator.create(Zdef);
    zdef.* = .{
        .type_def = try self.gc.type_registry.getTypeDef(type_def orelse .{ .def_type = .Void }),
        .zig_type = zig_type orelse ZigType{ .Void = {} },
        .name = id,
    };

    return zdef;
}

fn ptrType(self: *Self, tag: Ast.Node.Tag, decl_index: Ast.Node.Index) anyerror!*Zdef {
    const ptr_type = switch (tag) {
        .ptr_type_aligned => self.ast.ptrTypeAligned(decl_index),
        .ptr_type_sentinel => self.ast.ptrTypeSentinel(decl_index),
        .ptr_type => self.ast.ptrType(decl_index),
        else => unreachable,
    };
    _ = ptr_type;

    // If sentinel, must be 0

    // ObjTypeDef should be .String if [:0]u8 and List otherwise

    unreachable;
}

fn fnProto(self: *Self, tag: Ast.Node.Tag, decl_index: Ast.Node.Index) anyerror!*Zdef {
    var buffer = [1]Ast.Node.Index{undefined};
    const fn_proto = switch (tag) {
        .fn_proto_simple => self.ast.fnProtoSimple(&buffer, decl_index),
        .fn_proto_one => self.ast.fnProtoOne(&buffer, decl_index),
        .fn_proto => self.ast.fnProto(decl_index),
        .fn_proto_multi => self.ast.fnProtoMulti(decl_index),
        else => unreachable,
    };
    const return_type_zdef = try self.getZdef(fn_proto.ast.return_type);

    const name = if (fn_proto.name_token) |token| self.ast.tokenSlice(token) else null;

    if (name == null) {
        self.reporter.report(
            .zdef,
            self.source,
            "Functions must be named",
        );
    }

    var function_def = o.ObjFunction.FunctionDef{
        .id = o.ObjFunction.FunctionDef.nextId(),
        .name = try self.gc.copyString(name orelse "unknown"),
        .script_name = try self.gc.copyString(self.source.script_name),
        .return_type = if (return_type_zdef) |return_type|
            return_type.type_def
        else
            try self.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
        .yield_type = try self.gc.type_registry.getTypeDef(.{ .def_type = .Void }),
        .parameters = std.AutoArrayHashMap(*o.ObjString, *o.ObjTypeDef).init(self.gc.allocator),
        .defaults = std.AutoArrayHashMap(*o.ObjString, v.Value).init(self.gc.allocator),
        .function_type = .Extern,
        .generic_types = std.AutoArrayHashMap(*o.ObjString, *o.ObjTypeDef).init(self.gc.allocator),
    };

    var parameters_zig_types = std.ArrayList(ZigType.Fn.Param).init(self.gc.allocator);
    var zig_fn_type = ZigType.Fn{
        .calling_convention = .C,
        // How could it be something else?
        .alignment = 4,
        .is_generic = false,
        .is_var_args = false,
        .return_type = if (return_type_zdef) |return_type|
            &return_type.zig_type
        else
            null,
        .params = undefined,
    };

    var it = fn_proto.iterate(&self.ast);
    while (it.next()) |param| {
        const param_name = if (param.name_token) |param_name_token|
            self.ast.tokenSlice(param_name_token)
        else
            null;

        if (param_name == null) {
            self.reporter.report(
                .zdef,
                self.source,
                "Please provide name to functions arguments",
            );
        }

        const param_zdef = try self.getZdef(param.type_expr);

        try function_def.parameters.put(
            try self.gc.copyString(param_name orelse "$"),
            param_zdef.?.type_def,
        );

        try parameters_zig_types.append(
            .{
                .is_generic = false,
                .is_noalias = false,
                .type = &param_zdef.?.zig_type,
            },
        );
    }

    parameters_zig_types.shrinkAndFree(parameters_zig_types.items.len);
    zig_fn_type.params = parameters_zig_types.items;

    var type_def = try self.gc.allocate(o.ObjTypeDef);
    type_def.* = o.ObjTypeDef{
        .def_type = .Function,
        .resolved_type = .{ .Function = function_def },
    };

    var zdef = try self.gc.allocator.create(Zdef);
    zdef.* = .{
        .zig_type = ZigType{ .Fn = zig_fn_type },
        .type_def = type_def,
        .name = name orelse "unknown",
    };

    return zdef;
}

fn reportZigError(self: *Self, err: Ast.Error) void {
    var message = std.ArrayList(u8).init(self.gc.allocator);
    defer message.deinit();

    message.writer().print("zdef could not be parsed: {}", .{err.tag}) catch unreachable;

    self.reporter.report(
        .zdef,
        self.source,
        message.items,
    );
}