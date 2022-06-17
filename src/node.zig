const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

const _obj = @import("./obj.zig");
const _token = @import("./token.zig");
const _value = @import("./value.zig");
const _codegen = @import("./codegen.zig");
const _parser = @import("./parser.zig");
const _chunk = @import("./chunk.zig");
const disassembler = @import("./disassembler.zig");

const ObjTypeDef = _obj.ObjTypeDef;
const ObjString = _obj.ObjString;
const ObjNative = _obj.ObjNative;
const ObjFunction = _obj.ObjFunction;
const ObjObject = _obj.ObjObject;
const FunctionType = ObjFunction.FunctionType;
const copyStringRaw = _obj.copyStringRaw;
const Value = _value.Value;
const valueToString = _value.valueToString;
const Token = _token.Token;
const TokenType = _token.TokenType;
const CodeGen = _codegen.CodeGen;
const Parser = _parser.Parser;
const Frame = _parser.Frame;
const Local = _parser.Local;
const Global = _parser.Global;
const UpValue = _parser.UpValue;
const OpCode = _chunk.OpCode;

pub const ParsedArg = struct {
    name: ?Token,
    arg: *ParseNode,
};

pub const ParseNodeType = enum(u8) {
    Function,
    Enum,
    VarDeclaration,
    FunDeclaration,
    ListDeclaration,
    MapDeclaration,
    ObjectDeclaration,

    Binary,
    Unary,
    Subscript,
    Unwrap,
    ForceUnwrap,
    Is,

    And,
    Or,

    NamedVariable,

    Number,
    String,
    StringLiteral,
    Boolean,
    Null,

    List,
    Map,

    Super,
    Dot,
    ObjectInit,

    Throw,
    Break,
    Continue,
    Call,
    If,
    Block, // For semantic purposes only
    Return,
    For,
    ForEach,
    DoUntil,
    While,
    Export,
    Import,
    Catch,
};

pub const ParseNode = struct {
    const Self = @This();

    node_type: ParseNodeType,
    // If null, either its a statement or its a reference to something unkown that should ultimately raise a compile error
    type_def: ?*ObjTypeDef = null,
    location: Token = undefined,
    // Wether optional jumps must be patch before generate this node bytecode
    patch_opt_jumps: bool = false,

    toJson: fn (*Self, std.ArrayList(u8).Writer) anyerror!void = stringify,
    toByteCode: fn (*Self, *CodeGen, ?*std.ArrayList(usize)) anyerror!?*ObjFunction = generate,

    fn generate(self: *Self, codegen: *CodeGen, _: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        if (self.patch_opt_jumps) {
            assert(codegen.opt_jumps != null and codegen.opt_jumps.?.items.len > 0);

            // Hope over OP_POP if actual value
            const njump: usize = try codegen.emitJump(.OP_JUMP);

            for (codegen.opt_jumps.?.items) |jump| {
                try codegen.patchJump(jump);
            }
            // If aborted by a null optional, will result in null on the stack
            try codegen.emitOpCode(.OP_POP);

            try codegen.patchJump(njump);

            codegen.opt_jumps.?.deinit();
            codegen.opt_jumps = null;
        }
    }

    fn stringify(self: *Self, out: std.ArrayList(u8).Writer) anyerror!void {
        try out.print(
            "\"type_def\": \"{s}\"",
            .{
                if (self.type_def) |type_def| try type_def.toString(std.heap.c_allocator) else "N/A",
            },
        );
    }
};

pub const SlotType = enum(u8) {
    Local,
    UpValue,
    Global,
};

pub const NamedVariableNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .NamedVariable,
        .toJson = stringify,
        .toByteCode = generate,
    },

    identifier: Token,
    value: ?*ParseNode = null,
    slot: usize,
    slot_type: SlotType,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        var get_op: OpCode = undefined;
        var set_op: OpCode = undefined;

        switch (self.slot_type) {
            .Local => {
                get_op = .OP_GET_LOCAL;
                set_op = .OP_SET_LOCAL;
            },
            .Global => {
                get_op = .OP_GET_GLOBAL;
                set_op = .OP_SET_GLOBAL;
            },
            .UpValue => {
                get_op = .OP_GET_UPVALUE;
                set_op = .OP_SET_UPVALUE;
            },
        }

        if (self.value) |value| {
            _ = try value.toJson(value, codegen);

            try codegen.emitCodeArg(set_op, self.slot);
        } else {
            try codegen.emitCodeArg(get_op, self.slot);
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"NamedVariable\", \"identifier\": \"{s}\", \"slot\": \"{}\",", .{ self.identifier.lexeme, self.slot });

        try ParseNode.stringify(node, out);

        try out.writeAll(",\"value\": ");

        if (self.value) |value| {
            try value.toJson(value, out);
        } else {
            try out.writeAll("null");
        }

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .NamedVariable) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const NumberNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Number,
        .toJson = stringify,
        .toByteCode = generate,
    },

    constant: f64,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        try codegen.emitConstant(Value{ .Number = self.constant });
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Number\", \"constant\": \"{}\", ", .{self.constant});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Number) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const BooleanNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Boolean,
        .toJson = stringify,
        .toByteCode = generate,
    },

    constant: bool,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        try codegen.emitOpCode(if (self.constant) .OP_TRUE else .OP_FALSE);
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Boolean\", \"constant\": \"{}\", ", .{self.constant});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Boolean) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const StringLiteralNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .StringLiteral,
        .toJson = stringify,
        .toByteCode = generate,
    },

    constant: *ObjString,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        try codegen.emitConstant(self.constant.toValue());

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"StringLiteral\", \"constant\": \"{s}\", ", .{self.constant.string});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .StringLiteral) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const StringNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .String,
        .toJson = stringify,
        .toByteCode = generate,
    },

    // List of nodes that will eventually be converted to strings concatened together
    elements: []*ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.elements.len == 0) {
            // Push the empty string which is always the constant 0
            try codegen.emitCodeArg(.OP_CONSTANT, 0);

            return null;
        }

        for (self.elements) |element, index| {
            if (element.type_def == null or element.type_def.?.def_type == .Placeholder) {
                codegen.reportErrorAt(element.location, "Unknown type");

                break;
            }

            _ = try element.toByteCode(element, codegen, breaks);
            if (element.type_def.?.def_type != .String) {
                try codegen.emitOpCode(.OP_TO_STRING);

                if (index >= 2) {
                    try codegen.emitOpCode(.OP_ADD);
                }
            }
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"String\", \"elements\": [");

        for (self.elements) |element, i| {
            try element.toJson(element, out);

            if (i < self.elements.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return .{
            .elements = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.elements.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .String) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const NullNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Null,
        .toJson = stringify,
        .toByteCode = generate,
    },

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        try codegen.emitOpCode(.OP_NULL);
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        try out.writeAll("{\"node\": \"Null\", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Null) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ListNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .List,
        .toJson = stringify,
        .toByteCode = generate,
    },

    items: []*ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const item_type = self.node.type_def.?.resolved_type.?.List.item_type;
        const list_offset: usize = try codegen.emitList();

        for (self.items) |item| {
            if (item.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(item.location, "Unknown type");
            } else if (!item.type_def.?.eql(item_type)) {
                try codegen.reportTypeCheckAt(item_type, item.type_def.?, "Bad list type", item.location);
            } else {
                _ = try item.toJson(item, codegen);
            }
        }

        const list_type_constant: u24 = try codegen.makeConstant(Value{ .Obj = node.type_def.?.toObj() });
        try self.patchList(list_offset, list_type_constant);
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"List\", \"items\": [");

        for (self.items) |item, i| {
            try item.toJson(item, out);

            if (i < self.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .List) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const MapNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Map,
        .toJson = stringify,
        .toByteCode = generate,
    },

    keys: []*ParseNode,
    values: []*ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const key_type = self.node.type_def.?.resolved_type.?.Map.key_type;
        const value_type = self.node.type_def.?.resolved_type.?.Map.value_type;

        const map_offset: usize = try codegen.emitMap();

        assert(self.keys.len == self.values.len);

        for (self.keys) |key, i| {
            const value = self.values[i];

            _ = try key.toJson(key, codegen);
            _ = try value.toJson(value, codegen);

            try codegen.emitOpCode(.OP_SET_MAP);

            if (key.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(key.location, "Unknown type");
            }

            if (value.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(value.location, "Unknown type");
            }

            if (!key.type_def.?.eql(key_type)) {
                try codegen.reportTypeCheckAt(key_type, key.type_def.?, "Bad key type", key.location);
            }

            if (!value.type_def.?.eql(value_type)) {
                try codegen.reportTypeCheckAt(value_type, value.type_def.?, "Bad value type", value.location);
            }
        }

        const map_type_constant: u24 = try codegen.makeConstant(Value{ .Obj = node.type_def.?.toObj() });
        try codegen.patchMap(map_offset, map_type_constant);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Map\", \"items\": [");

        for (self.keys) |key, i| {
            try out.writeAll("{\"key\": ");

            try key.toJson(key, out);

            try out.writeAll("\", value\": ");

            try self.values[i].toJson(self.values[i], out);

            try out.writeAll("}");

            if (i < self.keys.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Map) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const UnwrapNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Unwrap,
        .toJson = stringify,
        .toByteCode = generate,
    },

    unwrapped: *ParseNode,
    original_type: ?*ObjTypeDef,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.original_type == null or self.original_type.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.unwrapped.location, "Unknown type");

            return null;
        }

        if (!self.original_type.?.optional) {
            try codegen.reportErrorAt(self.unwrapped.location, "Not an optional.");
        }

        try codegen.emitCodeArg(.OP_COPY, 1);
        try codegen.emitOpCode(.OP_NULL);
        try codegen.emitOpCode(.OP_EQUAL);
        try codegen.emitOpCode(.OP_NOT);

        const jump: usize = try codegen.emitJump(.OP_JUMP_IF_FALSE);

        if (codegen.opt_jumps == null) {
            codegen.opt_jumps = std.ArrayList(usize).init(codegen.allocator);
        }
        try codegen.opt_jumps.?.append(jump);

        try self.emitOpCode(.OP_POP); // Pop test result

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Unwrap\", \"unwrapped\": ");

        try self.unwrapped.toJson(self.unwrapped, out);
        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Unwrap) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ForceUnwrapNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .ForceUnwrap,
        .toJson = stringify,
        .toByteCode = generate,
    },

    unwrapped: *ParseNode,
    original_type: ?*ObjTypeDef,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.original_type == null or self.original_type.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.unwrapped.location, "Unknown type");

            return null;
        }

        if (!self.original_type.?.optional) {
            try codegen.reportErrorAt(self.unwrapped.location, "Not an optional.");
        }

        try codegen.emitOpCode(.OP_UNWRAP);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"ForceUnwrap\", \"unwrapped\": ");

        try self.unwrapped.toJson(self.unwrapped, out);
        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .ForceUnwrap) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const IsNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Is,
        .toJson = stringify,
        .toByteCode = generate,
    },

    left: *ParseNode,
    constant: Value,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        try codegen.emitCodeArg(.OP_CONSTANT, try codegen.makeConstant(self.constant));

        try codegen.emitOpCode(.OP_IS);
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Is\", \"left\": ");

        try self.left.toJson(self.left, out);
        try out.print(", \"constant\": \"{s}\", ", .{try valueToString(std.heap.c_allocator, self.constant)});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Is) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const UnaryNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Unary,
        .toJson = stringify,
        .toByteCode = generate,
    },

    left: *ParseNode,
    operator: TokenType,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const left_type = self.left.type_def.?;

        if (left_type.def_type == .Placeholder) {
            try codegen.reportErrorAt(node.location, "Unknown type");
        }

        _ = try self.left.toJson(self.left, codegen);

        switch (self.operator) {
            .Bang => {
                if (left_type.def_type != .Bool) {
                    try codegen.reportErrorFmt(
                        self.left.location,
                        "Expected type `bool`, got `{s}`",
                        .{try left_type.toString(codegen.allocator)},
                    );
                }

                try codegen.emitOpCode(.OP_NOT);
            },
            .Minus => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorFmt(
                        self.left.location,
                        "Expected type `num`, got `{s}`",
                        .{try left_type.toString(codegen.allocator)},
                    );
                }

                try codegen.emitOpCode(.OP_NEGATE);
            },
            else => unreachable,
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Unary\", \"left\": ");

        try self.left.toJson(self.left, out);
        try out.print(", \"operator\": \"{}\", ", .{self.operator});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Unary) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const BinaryNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Binary,
        .toJson = stringify,
        .toByteCode = generate,
    },

    left: *ParseNode,
    right: *ParseNode,
    operator: TokenType,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const left_type = self.left.type_def.?;
        const right_type = self.right.type_def.?;

        if (left_type.def_type == .Placeholder or right_type.def_type == .Placeholder) {
            try codegen.reportErrorAt(node.location, "Unknown type");
        }

        if (!left_type.eql(right_type)) {
            try codegen.reportTypeCheckAt(left_type, right_type, "Type mismatch", node.location);
        }

        switch (self.operator) {
            .QuestionQuestion => {
                if (!left_type.optional) {
                    try codegen.reportErrorAt(node.location, "Not an optional");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_NULL_OR);
            },
            .Greater => {
                // Checking only left operand since we asserted earlier that both operand have the same type
                if (left_type.def_type != .Number) {
                    try self.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_GREATER);
            },
            .Less => {
                if (left_type.def_type != .Number) {
                    try self.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_LESS);
            },
            .GreaterEqual => {
                if (left_type.def_type != .Number) {
                    try self.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_LESS);
                try codegen.emitOpCode(.OP_NOT);
            },
            .LessEqual => {
                if (left_type.def_type != .Number) {
                    try self.reportErrorAt(self.left.location, "Expected `num`.");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_GREATER);
                try codegen.emitOpCode(.OP_NOT);
            },
            .BangEqual => {
                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_EQUAL);
                try codegen.emitOpCode(.OP_NOT);
            },
            .EqualEqual => {
                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_EQUAL);
            },
            .Plus => {
                // zig fmt: off
                if (left_type.def_type != .Number
                    and left_type.def_type != .String
                    and left_type.def_type != .List
                    and left_type.def_type != .Map) {
                    try self.reportError("Expected a `num`, `str`, list or map.");
                }
                // zig fmt: on

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_ADD);
            },
            .Minus => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(node.location, "Expected `num`.");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_SUBTRACT);
            },
            .Star => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(node.location, "Expected `num`.");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_MULTIPLY);
            },
            .Slash => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(node.location, "Expected `num`.");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_DIVIDE);
            },
            .Percent => {
                if (left_type.def_type != .Number) {
                    try codegen.reportErrorAt(node.location, "Expected `num`.");
                }

                _ = try self.left.toJson(self.left, codegen);
                _ = try self.right.toJson(self.right, codegen);
                try codegen.emitOpCode(.OP_MOD);
            },
            .And => {
                if (left_type.def_type != .Bool) {
                    try codegen.reportErrorAt(node.location, "`and` expects operands to be `bool`");
                }

                _ = try self.left.toJson(self.left, codegen);

                const end_jump: usize = try codegen.emitJump(.OP_JUMP_IF_FALSE);
                try codegen.emitOpCode(.OP_POP);

                _ = try self.right.toJson(self.right, codegen);

                try codegen.patchJump(end_jump);
            },
            .Or => {
                if (left_type.def_type != .Bool) {
                    try codegen.reportErrorAt(node.location, "`and` expects operands to be `bool`");
                }

                _ = try self.left.toJson(self.left, codegen);

                const else_jump: usize = try codegen.emitJump(.OP_JUMP_IF_FALSE);
                const end_jump: usize = try codegen.emitJump(.OP_JUMP);

                try self.patchJump(else_jump);
                try codegen.emitOpCode(.OP_POP);

                _ = try self.right.toJson(self.right, codegen);

                try codegen.patchJump(end_jump);
            },
            else => unreachable,
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Binary\", \"left\": ");

        try self.left.toJson(self.left, out);
        try out.print(", \"operator\": \"{}\", \"right\": ", .{self.operator});
        try self.right.toJson(self.right, out);
        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Binary) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const SubscriptNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Subscript,
        .toJson = stringify,
        .toByteCode = generate,
    },

    subscripted: *ParseNode,
    index: *ParseNode,
    value: ?*ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.subscripted.type_def == null or self.subscripted.type_def.?.def_type == .Placeholder) {
            codegen.reportErrorAt(self.subscripted.location, "Unknown type.");
        }

        if (self.index.type_def == null or self.index.type_def.?.def_type == .Placeholder) {
            codegen.reportErrorAt(self.index.location, "Unknown type.");
        }

        if (self.value != null and (self.value.?.type_def == null or self.value.?.type_def.?.def_type == .Placeholder)) {
            codegen.reportErrorAt(self.value.?.location, "Unknown type.");
        }

        switch (self.subscripted.type_def.?.def_type) {
            .String => {
                if (self.index.type_def.?.def_type != .Number) {
                    try codegen.reportErrorAt(self.index.location, "Expected `num` index.");
                }

                assert(self.value == null);
            },
            .List => {
                if (self.index.type_def.?.def_type != .Number) {
                    try codegen.reportErrorAt(self.index.location, "Expected `num` index.");
                }

                if (self.value) |value| {
                    if (!self.subscripted.type_def.?.resolved_type.?.List.item_type.eql(value.type_def.?)) {
                        try codegen.reportTypeCheckAt(self.subscripted.type_def.?.resolved_type.?.List.item_type, value.type_def.?, "Bad value type", value.location);
                    }
                }
            },
            .Map => {
                if (!self.subscripted.type_def.?.resolved_type.?.Map.key_type.eql(self.index.type_def.?)) {
                    try codegen.reportTypeCheckAt(self.subscripted.type_def.?.resolved_type.?.Map.key_type, self.index.type_def.?, "Bad key type", self.index.location);
                }

                if (self.value) |value| {
                    if (!self.subscripted.type_def.?.resolved_type.?.Map.value_type.eql(value.type_def.?)) {
                        try codegen.reportTypeCheckAt(self.subscripted.type_def.?.resolved_type.?.Map.value_type, value.type_def.?, "Bad value type", value.location);
                    }
                }
            },
        }

        _ = try self.index.toByteCode(self.index, codegen, breaks);

        if (self.value) |value| {
            _ = try value.toByteCode(value, codegen, breaks);

            codegen.emitOpCode(.OP_SET_SUBSCRIPT);
        } else {
            codegen.emitOpCode(.OP_GET_SUBSCRIPT);
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Subscript\", \"subscripted\": ");

        try self.subscripted.toJson(self.subscripted, out);

        try out.writeAll(", \"index\": ");

        try self.index.toJson(self.index, out);

        try out.writeAll(", ");

        if (self.value) |value| {
            try out.writeAll("\"value\": ");
            try value.toJson(value, out);
            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Subscript) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const FunctionNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Function,
        .toJson = stringify,
        .toByteCode = generate,
    },

    default_arguments: std.StringArrayHashMap(*ParseNode),
    body: ?*BlockNode = null,
    arrow_expr: ?*ParseNode = null,
    native: ?*ObjNative = null,
    test_message: ?*ParseNode = null,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        var enclosing = codegen.current;
        codegen.current = try codegen.allocator.create(Frame);
        codegen.current.?.* = Frame{
            .locals = [_]Local{undefined} ** 255,
            .upvalues = [_]UpValue{undefined} ** 255,
            .enclosing = enclosing,
            .function_node = self,
            .constants = std.ArrayList(Value).init(codegen.allocator),
        };

        var function = try ObjFunction.init(
            codegen.allocator,
            self.node.type_def.?.resolved_type.?.Function.name,
        );

        function.type_def = self.node.type_def.?;

        // First chunk constant is the empty string
        _ = try function.chunk.addConstant(null, Value{
            .Obj = (try copyStringRaw(codegen.strings, codegen.allocator, "", true // The substring we built is now owned by codegen
            )).toObj(),
        });

        codegen.current.?.function = function;

        const function_type = self.node.type_def.?.resolved_type.?.Function.function_type;

        // Can't have both arrow expression and body
        assert((self.arrow_expr != null and self.body == null) or (self.arrow_expr == null and self.body != null));

        // Generate function's body bytecode
        if (self.arrow_expr) |arrow_expr| {
            try arrow_expr.toJson(arrow_expr.node, codegen);
        } else {
            try self.body.?.toJson(self.body.?.node, codegen);
        }

        if (function_type != .Extern) {
            // If .Script, search for exported globals and return them in a map
            if (function_type == .Script or function_type == .ScriptEntryPoint) {
                // If top level, search `main` or `test` function(s) and call them
                // Then put any exported globals on the stack
                if (!codegen.testing and function_type == .ScriptEntryPoint) {
                    var found_main: bool = false;
                    for (codegen.globals.items) |global, index| {
                        if (mem.eql(u8, global.name.string, "main") and !global.hidden and global.prefix == null) {
                            found_main = true;

                            try codegen.emitCodeArg(.OP_GET_GLOBAL, @intCast(u24, index));
                            try codegen.emitCodeArg(.OP_GET_LOCAL, 1); // cli args are always local 0
                            try codegen.emitCodeArgs(.OP_CALL, 1, 0);
                            break;
                        }
                    }
                } else if (codegen.testing) {
                    // Create an entry point wich runs all `test`
                    for (codegen.globals.items) |global, index| {
                        if (global.name.string.len > 5 and mem.eql(u8, global.name.string[0..5], "$test") and !global.hidden and global.prefix == null) {
                            try codegen.emitCodeArg(.OP_GET_GLOBAL, @intCast(u24, index));
                            try codegen.emitCodeArgs(.OP_CALL, 0, 0);
                        }
                    }
                }

                // If we're being imported, put all globals on the stack
                if (codegen.imported) {
                    var exported_count: usize = 0;
                    for (codegen.globals.items) |_, index| {
                        exported_count += 1;

                        if (exported_count > 16777215) {
                            try codegen.reportErrorAt(self.node.location, "Can't export more than 16777215 values.");
                            break;
                        }

                        try codegen.emitCodeArg(.OP_GET_GLOBAL, @intCast(u24, index));
                    }

                    try codegen.emitCodeArg(.OP_EXPORT, @intCast(u24, exported_count));
                } else {
                    try codegen.emitOpCode(.OP_VOID);
                    try codegen.emitOpCode(.OP_RETURN);
                }
            } else if (codegen.current.?.function.type_def.resolved_type.?.Function.return_type.def_type == .Void and !codegen.current.?.return_emitted) {
                // TODO: detect if some branches of the function body miss a return statement
                try codegen.emitReturn();
            }
        }

        var frame = codegen.current.?;
        var current_function: *ObjFunction = frame.function;

        codegen.current = frame.enclosing;

        // `extern` functions don't have upvalues
        if (function_type == .Extern) {
            try codegen.emitCodeArg(.OP_CONSTANT, try codegen.makeConstant(self.native.toValue()));
        } else {
            try codegen.emitCodeArg(.OP_CLOSURE, try codegen.makeConstant(current_function.toValue()));

            var i: usize = 0;
            while (i < current_function.upvalue_count) : (i += 1) {
                try codegen.emit(if (frame.upvalues[i].is_local) 1 else 0);
                try codegen.emit(frame.upvalues[i].index);
            }
        }

        std.debug.print("\n\n==========================", .{});
        try disassembler.disassembleChunk(
            &current_function.chunk,
            current_function.name.string,
        );
        std.debug.print("\n\n==========================", .{});

        return current_function;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Function\", \"type\": \"{}\", \"default_arguments\": {{", .{self.node.type_def.?.resolved_type.?.Function.function_type});

        var it = self.default_arguments.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) {
                try out.writeAll(",");
            }

            first = false;

            try out.print("\"{s}\": ", .{entry.key_ptr.*});
            try entry.value_ptr.*.toJson(entry.value_ptr.*, out);
        }

        if (self.body) |body| {
            try out.writeAll("}, \"body\": ");

            try body.toNode().toJson(body.toNode(), out);
        } else if (self.arrow_expr) |expr| {
            try out.writeAll("}, \"arrow_expr\": ");

            try expr.toJson(expr, out);
        }

        try out.writeAll(", ");

        if (self.native) |native| {
            try out.print("\"native\": \"{s}\",", .{try valueToString(std.heap.c_allocator, native.toValue())});
        }

        if (self.test_message) |test_message| {
            try test_message.toJson(test_message, out);

            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(parser: *Parser, function_type: FunctionType, file_name_or_name: ?[]const u8) !Self {
        var self = Self{
            .body = try parser.allocator.create(BlockNode),
            .default_arguments = std.StringArrayHashMap(*ParseNode).init(parser.allocator),
        };

        self.body.?.* = BlockNode.init(parser.allocator);

        const function_name: []const u8 = switch (function_type) {
            .EntryPoint => "main",
            .ScriptEntryPoint, .Script => file_name_or_name orelse "<script>",
            .Catch => "<catch>",
            else => file_name_or_name orelse "???",
        };

        const function_def = ObjFunction.FunctionDef{
            .name = try copyStringRaw(parser.strings, parser.allocator, function_name, false),
            .return_type = try parser.getTypeDef(.{ .def_type = .Void }),
            .parameters = std.StringArrayHashMap(*ObjTypeDef).init(parser.allocator),
            .has_defaults = std.StringArrayHashMap(bool).init(parser.allocator),
            .function_type = function_type,
        };

        const type_def = ObjTypeDef.TypeUnion{ .Function = function_def };

        self.node.type_def = try parser.getTypeDef(
            .{
                .def_type = .Function,
                .resolved_type = type_def,
            },
        );

        return self;
    }

    pub fn deinit(self: Self) void {
        self.body.deinit();
        self.default_arguments.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Function) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const CallNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Call,
        .toJson = stringify,
        .toByteCode = generate,
    },

    callee: *ParseNode,
    arguments: std.StringArrayHashMap(*ParseNode),
    catches: ?[]*ParseNode = null,
    invoked: bool = false,
    super: ?*NamedVariableNode = null,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.callee_type == null or self.callee_type.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.callee.location, "Unknown type");
        }

        const args: std.StringArrayHashMap(*ObjTypeDef) = if (self.callee_type.?.def_type == .Function)
            self.callee_type.?.resolved_type.?.Function.parameters
        else
            self.callee_type.?.resolved_type.?.Native.parameters;
        const arg_keys = args.keys();

        // FIXME: Right now if dot call, can't have default arguments because we don't have a reference to the method ParseNode.
        //        For native calls it's acceptable but not for user defined object methods.
        //        https://github.com/giann/buzz/issues/45
        const default_args = self.callee.node_type == .Function and FunctionNode.cast(self.callee).?.default_arguments;

        // Push arguments on the stack, in the correct order
        for (arg_keys) |arg_key, index| {
            const argument: ?*ParseNode = if (index == 0 and self.arguments.get("$") != null)
                self.arguments.get("$").? // First argument with omitted name
            else
                self.arguments.get(arg_key);

            if (argument != null) {
                if (argument.?.type_def == null or argument.?.type_def.?.def_type == .Placeholder) {
                    try codegen.reportErrorAt(argument.?.location, "Unknown type");
                }

                if (!args.get(arg_key).?.eql(argument.?.type_def.?)) {
                    try codegen.reportTypeCheckAt(
                        args.get(arg_key).?,
                        argument.?.type_def.?,
                        "Bad argument type",
                        argument.?.location,
                    );
                }

                _ = try argument.?.toByteCode(argument.?, codegen, breaks);
            } else if (default_args != null and default_args.?.get(arg_key)) |default| {
                _ = try default.?.toByteCode(default.?, codegen, breaks);
            } else {
                try codegen.reportErrorFmt(node.location, "Missing argument `{s}`.", .{arg_key});
            }
        }

        // If super call, push super as a new local
        if (self.super) |super| {
            _ = try super.node.toByteCode(super.node, codegen, breaks);
        }

        if (self.invoked) {
            try codegen.emitCodeArg(.OP_INVOKE, try codegen.identifierConstant(DotNode.cast(self.callee).?.identifier.lexeme));
        } else if (self.super != null) {
            try codegen.emitCodeArg(.OP_SUPER_INVOKE, try codegen.identifierConstant(SuperNode.cast(self.callee).?.identifier.lexeme));
        }

        // Catch clauses
        if (self.catches) |catches| {
            for (catches) |catch_clause| {
                _ = try catch_clause.toByteCode(catch_clause, codegen, breaks);
            }
        }

        if (!self.invoked) {
            try codegen.emitCodeArgs(
                .OP_CALL,
                self.arguments.count(),
                if (self.catches) |catches| catches.len else 0,
            );
        } else {
            try codegen.emitTwo(
                self.arguments.count(),
                if (self.catches) |catches| catches.len else 0,
            );
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Call\", \"callee\": ");

        try self.callee.toJson(self.callee, out);

        try out.writeAll(", \"arguments\": [");

        for (self.arguments.items) |argument, i| {
            try out.print("{{\"name\": \"{s}\", \"value\": ", .{if (argument.name) |name| name.lexeme else "N/A"});

            try argument.arg.toJson(argument.arg, out);

            try out.writeAll("}");

            if (i < self.arguments.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        if (self.catches) |catches| {
            try out.writeAll("\"catches\": [");

            for (catches) |clause, i| {
                try clause.toJson(clause, out);

                if (i < catches.len - 1) {
                    try out.writeAll(",");
                }
            }

            try out.writeAll("],");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator, callee: *ParseNode) Self {
        return Self{
            .callee = callee,
            .arguments = std.ArrayList(ParsedArg).init(allocator),
        };
    }

    pub fn deinit(self: Self) void {
        self.callee.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Call) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const VarDeclarationNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .VarDeclaration,
        .toJson = stringify,
        .toByteCode = generate,
    },

    name: Token,
    value: ?*ParseNode = null,
    type_def: ?*ObjTypeDef = null,
    type_name: ?Token = null,
    constant: bool,
    slot: usize,
    slot_type: SlotType,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.value) |value| {
            if (value.type_def == null or value.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(value.location, "Unknown type.");
            } else if (self.type_def == null or self.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(node.location, "Unknown type.");
            } else if (!value.type_def.?.eql(self.type_def.?)) {
                try codegen.reportTypeCheckAt(self.type_def.?, value.type_def.?, "Wrong variable type", value.location);
            }

            _ = value.toByteCode(value, codegen, breaks);
        } else {
            try codegen.emitOpCode(.OP_VOID);
        }

        if (self.slot_type == .Global) {
            try codegen.emitCodeArg(.OP_DEFINE_GLOBAL, self.slot);
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print(
            "{{\"node\": \"VarDeclaration\", \"name\": \"{s}\", \"constant\": {}, \"var_type_def\": \"{s}\", \"type_name\": \"{s}\", ",
            .{
                self.name.lexeme,
                self.constant,
                if (self.type_def) |type_def| try type_def.toString(std.heap.c_allocator) else "N/A",
                if (self.type_name) |type_name| type_name.lexeme else "N/A",
            },
        );

        if (self.value) |value| {
            try out.writeAll("\"value\": ");

            try value.toJson(value, out);

            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .VarDeclaration) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const EnumNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Enum,
        .toJson = stringify,
        .toByteCode = generate,
    },

    slot: usize,
    cases: std.ArrayList(*ParseNode),

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (node.type_def.?.resolved_type.?.Enum.enum_type.def_type == .Placeholder) {
            try codegen.reportErrorAt(node.location, "Unknwon enum type.");
        }

        try codegen.emitCodeArg(.OP_ENUM, try codegen.makeConstant(node.type_def.?.toValue()));
        try codegen.emitCodeArg(.OP_DEFINE_GLOBAL, @intCast(u24, self.slot));

        try codegen.emitCodeArg(.OP_GET_GLOBAL, @intCast(u24, self.slot));

        for (self.cases.items) |case| {
            if (case.type_def == null or case.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(case.location, "Unknown type.");
            } else if (!case.type_def.eql(node.type_def.?.resolved_type.?.Enum.enum_type.toInstance())) {
                try codegen.reportTypeCheckAt(node.type_def.?.resolved_type.?.Enum.enum_type.toInstance(), case.type_def, "Bad enum case type", case.location);
            }

            _ = try case.toByteCode(case, codegen, breaks);

            try codegen.emitOpCode(.OP_ENUM_CASE);
        }

        try codegen.emitOpCode(.OP_POP);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Enum\", \"cases\": [");

        for (self.cases.items) |case, i| {
            try case.toJson(case, out);
            if (i < self.cases.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .cases = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.cases.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Enum) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ThrowNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Throw,
        .toJson = stringify,
        .toByteCode = generate,
    },

    error_value: *ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        _ = try self.error_value.toByteCode(self.error_value, codegen, breaks);

        codegen.emitOpCode(.OP_THROW);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Throw\", \"error_value\": ");

        try self.error_value.toJson(self.error_value, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Throw) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const BreakNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Break,
        .toJson = stringify,
        .toByteCode = generate,
    },

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        assert(breaks != null);

        try breaks.?.append(codegen.emitJump(.OP_JUMP));

        return null;
    }

    fn stringify(_: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        try out.writeAll("{\"node\": \"Break\" }");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Break) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ContinueNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Continue,
        .toJson = stringify,
        .toByteCode = generate,
    },

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        assert(breaks != null);

        try breaks.?.append(codegen.emitJump(.OP_LOOP));

        return null;
    }

    fn stringify(_: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        try out.writeAll("{\"node\": \"Continue\" }");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Continue) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const IfNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .If,
        .toJson = stringify,
        .toByteCode = generate,
    },

    condition: *ParseNode,
    body: *ParseNode,
    else_branch: ?*ParseNode = null,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.condition.type_def == null or self.condition.type_def.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.condition.location, "Unknown type.");
        }

        if (self.condition.type_def.?.def_type != .Bool) {
            try codegen.reportErrorAt(self.condition.location, "`if` condition must be bool");
        }

        _ = try self.condition.toByteCode(self.condition, codegen, breaks);

        const then_jump: usize = try codegen.emitJump(.OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(.OP_POP);

        _ = try self.body.toByteCode(self.body, codegen, breaks);

        const else_jump: usize = try codegen.emitJump(.OP_JUMP);

        try codegen.patchJump(then_jump);
        try codegen.emitOpCode(.OP_POP);

        if (self.else_branch) |else_branch| {
            _ = try else_branch.toByteCode(else_branch, codegen, breaks);
        }

        try codegen.patchJump(else_jump);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"If\", \"condition\": ");

        try self.condition.toJson(self.condition, out);

        try out.writeAll(", \"body\": ");

        try self.body.toJson(self.body, out);

        if (self.else_branch) |else_branch| {
            try out.writeAll(", \"else\": ");
            try else_branch.toJson(else_branch, out);
        }

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .If) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ReturnNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Return,
        .toJson = stringify,
        .toByteCode = generate,
    },

    value: ?*ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.value) |value| {
            if (value.type_def == null or value.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(value.location, "Unknown type.");
            } else if (!codegen.current.?.function.?.type_def.resolved_type.?.Function.return_type.eql(value.type_def.?)) {
                try codegen.reportTypeCheckAt(
                    codegen.current.?.function.?.type_def.resolved_type.?.Function.return_type,
                    value.type_def,
                    "Return value",
                );
            }

            _ = try value.toByteCode(value, codegen, breaks);
        } else {
            codegen.emitOpCode(.OP_VOID);
        }

        try codegen.emitOpCode(.OP_RETURN);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Return\"");

        if (self.value) |value| {
            try out.writeAll("\"value\": ");
            try value.toJson(value, out);
        }

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Return) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ForNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .For,
        .toJson = stringify,
        .toByteCode = generate,
    },

    init_expressions: std.ArrayList(*ParseNode),
    condition: *ParseNode,
    post_loop: std.ArrayList(*ParseNode),
    body: *ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, _breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, _breaks);

        var self = Self.cast(node).?;

        for (self.init_expressions.items) |expr| {
            if (expr.type_def == null or expr.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(expr.location, "Unknown type");
            }

            _ = try expr.toByteCode(expr, codegen, _breaks);
        }

        const loop_start: usize = codegen.currentCode();

        if (self.condition.type_def == null or self.condition.type_def.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.condition.location, "Unknown type.");
        }

        if (self.condition.type_def.?.def_type != .Bool) {
            try codegen.reportErrorAt(self.condition.location, "`for` condition must be bool");
        }

        _ = try self.condition.toByteCode(self.condition, codegen, _breaks);

        const exit_jump: usize = try codegen.emitJump(.OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(.OP_POP);

        // Jump over expressions which will be executed at end of loop
        // TODO: since we don't generate as we parse, we can get rid of this jump and just generate the post_loop later
        var body_jump: usize = try codegen.emitJump(.OP_JUMP);

        const expr_loop: usize = self.currentCode();
        for (self.post_loop) |expr| {
            if (expr.type_def == null or expr.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(expr.location, "Unknown type");
            }

            _ = try expr.toByteCode(expr, codegen, _breaks);
        }

        try codegen.emitLoop(loop_start);

        try codegen.patchJump(body_jump);

        var breaks: std.ArrayList(usize) = std.ArrayList(usize).init(codegen.allocator);
        defer breaks.deinit();

        _ = try self.block.toByteCode(self.block, codegen, &breaks);

        try codegen.emitLoop(expr_loop);

        try codegen.patchJump(exit_jump);

        try codegen.emitOpCode(.OP_POP);

        // Patch breaks
        for (breaks.items) |jump| {
            try codegen.patchJumpOrLoop(jump, loop_start);
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"For\", \"init_expression\": [");

        for (self.init_expressions.items) |expression, i| {
            try expression.toJson(expression, out);

            if (i < self.init_expressions.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], \"condition\": ");

        try self.condition.toJson(self.condition, out);

        try out.writeAll(", \"post_loop\": [");

        for (self.post_loop.items) |expression| {
            try expression.toJson(expression, out);
            try out.writeAll(", ");
        }

        try out.writeAll("], \"body\": ");

        try self.body.toJson(self.body, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .init_expression = std.ArrayList(*ParseNode).init(allocator),
            .post_loop = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.init_expressions.deinit();
        self.post_loop.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .For) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ForEachNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .ForEach,
        .toJson = stringify,
        .toByteCode = generate,
    },

    key: ?*ParseNode = null,
    value: *ParseNode,
    iterable: *ParseNode,
    block: *ParseNode,
    key_slot: u24,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, _breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, _breaks);

        var self = Self.cast(node).?;

        // Type checking
        if (self.iterable.type_def == null or self.iterable.type_def.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.iterable, "Unknown type.");
        } else {
            if (self.key) |key| {
                if (key.type_def == null or key.type_def.?.def_type == .Placeholder) {
                    try codegen.reportErrorAt(key, "Unknown type.");
                }

                switch (self.iterable.type_def.?.def_type) {
                    .String, .List => {
                        if (key.type_def.?.def_type != .Number) {
                            try codegen.reportErrorAt(key.location, "Expected `num`.");
                        }
                    },
                    .Map => {
                        if (!key.type_def.?.eql(self.iterable.type_def.?.resolved_type.?.Map.key_type)) {
                            try codegen.reportTypeCheckAt(self.iterable.type_def.?.resolved_type.?.Map.key_type, key.type_def.?, "Bad key type", key.location);
                        }
                    },
                    .Enum => try codegen.reportErrorAt(key.location, "No key available when iterating over enum."),
                }
            }

            if (self.value.type_def == null or self.value.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(self.value, "Unknown type.");
            }

            switch (self.iterable.type_def.?.def_type) {
                .Map => {
                    if (!self.value.type_def.?.eql(self.iterable.type_def.?.resolved_type.?.Map.value_type)) {
                        try codegen.reportTypeCheckAt(self.iterable.type_def.?.resolved_type.?.Map.value_type, self.value.type_def.?, "Bad value type", self.value.location);
                    }
                },
                .List => {
                    if (!self.value.type_def.?.eql(self.iterable.type_def.?.resolved_type.?.List.item_type)) {
                        try codegen.reportTypeCheckAt(self.iterable.type_def.?.resolved_type.?.List.item_type, self.value.type_def.?, "Bad value type", self.value.location);
                    }
                },
                .String => {
                    if (self.value.type_def.?.def_type != .String) {
                        try codegen.reportErrorAt(self.value.location, "Expected `str`.");
                    }
                },
                .Enum => {
                    if (!self.value.type_def.?.eql(self.iterable.type_def.?.toInstance())) {
                        try codegen.reportTypeCheckAt(self.iterable.type_def.?.toInstance(), self.value.type_def.?, "Bad value type", self.value.location);
                    }
                },
            }
        }

        _ = try self.iterable.toByteCode(self.iterable, codegen, _breaks);

        const loop_start: usize = self.currentCode();

        // Calls `next` and update key and value locals
        try self.emitOpCode(.OP_FOREACH);

        // If next key is null, exit loop
        try self.emitCodeArg(.OP_GET_LOCAL, VarDeclarationNode.cast(self.key orelse self.value).?.slot);
        try self.emitOpCode(.OP_NULL);
        try self.emitOpCode(.OP_EQUAL);
        try self.emitOpCode(.OP_NOT);
        const exit_jump: usize = try self.emitJump(.OP_JUMP_IF_FALSE);
        try self.emitOpCode(.OP_POP); // Pop condition result

        var breaks: std.ArrayList(usize) = std.ArrayList(usize).init(codegen.allocator);
        defer breaks.deinit();

        _ = try self.block.toByteCode(self.block, codegen, &breaks);

        try self.emitLoop(loop_start);

        // Patch condition jump
        try self.patchJump(exit_jump);
        // Patch breaks
        for (breaks.items) |jump| {
            try self.patchJumpOrLoop(jump, loop_start);
        }

        try self.emitOpCode(.OP_POP); // Pop element being iterated on

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"ForEach\", ");

        if (self.key) |key| {
            try out.writeAll("\"key\": ");
            try key.toJson(key, out);
        }

        try out.writeAll(", \"value\": ");

        try self.value.toJson(self.value, out);

        try out.writeAll(", \"iterable\": ");

        try self.iterable.toJson(self.iterable, out);

        try out.writeAll(", \"block\": ");

        try self.block.toJson(self.block, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .init_expression = std.ArrayList(*ParseNode).init(allocator),
            .post_loop = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.init_expressions.deinit();
        self.post_loop.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .ForEach) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const WhileNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .While,
        .toJson = stringify,
        .toByteCode = generate,
    },

    condition: *ParseNode,
    block: *ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, _breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, _breaks);

        var self = Self.cast(node).?;

        const loop_start: usize = self.currentCode();

        if (self.condition.type_def == null or self.condition.type_def.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.condition.location, "Unknown type.");
        }

        if (self.condition.type_def.?.def_type != .Bool) {
            try codegen.reportErrorAt(self.condition.location, "`while` condition must be bool");
        }

        _ = try self.condition.toByteCode(self.condition, codegen, _breaks);

        const exit_jump: usize = try codegen.emitJump(.OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(.OP_POP);

        var breaks: std.ArrayList(usize) = std.ArrayList(usize).init(codegen.allocator);
        defer breaks.deinit();

        _ = try self.block.toByteCode(self.block, codegen, &breaks);

        try self.emitLoop(loop_start);
        try self.patchJump(exit_jump);

        try self.emitOpCode(.OP_POP); // Pop condition (is not necessary if broke out of the loop)

        // Patch breaks
        for (breaks.items) |jump| {
            try self.patchJumpOrLoop(jump, loop_start);
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"While\", \"condition\": ");

        try self.condition.toJson(self.condition, out);

        try out.writeAll(", \"block\": ");

        try self.block.toJson(self.block, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .init_expression = std.ArrayList(*ParseNode).init(allocator),
            .post_loop = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.init_expressions.deinit();
        self.post_loop.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .While) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const DoUntilNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .DoUntil,
        .toJson = stringify,
        .toByteCode = generate,
    },

    condition: *ParseNode,
    block: *ParseNode,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, _breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, _breaks);

        var self = Self.cast(node).?;

        const loop_start: usize = codegen.currentCode();

        var breaks: std.ArrayList(usize) = std.ArrayList(usize).init(codegen.allocator);
        defer breaks.deinit();

        _ = try self.block.toByteCode(self.block, codegen, &breaks);

        if (self.condition.type_def == null or self.condition.type_def.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(self.condition.location, "Unknown type.");
        }

        if (self.condition.type_def.?.def_type != .Bool) {
            try codegen.reportErrorAt(self.condition.location, "`do` condition must be bool");
        }

        _ = try self.condition.toByteCode(self.condition, codegen, breaks);

        try codegen.emitOpCode(.OP_NOT);
        const exit_jump: usize = try codegen.emitJump(.OP_JUMP_IF_FALSE);
        try codegen.emitOpCode(.OP_POP);

        try codegen.emitLoop(loop_start);
        try codegen.patchJump(exit_jump);

        try codegen.emitOpCode(.OP_POP); // Pop condition

        // Patch breaks
        for (breaks.items) |jump| {
            try codegen.patchJumpOrLoop(jump, loop_start);
        }
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"DoUntil\", \"condition\": ");

        try self.condition.toJson(self.condition, out);

        try out.writeAll(", \"block\": ");

        try self.block.toJson(self.block, out);

        try out.writeAll(", ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .init_expression = std.ArrayList(*ParseNode).init(allocator),
            .post_loop = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.init_expressions.deinit();
        self.post_loop.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .DoUntil) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const BlockNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Block,
        .toJson = stringify,
        .toByteCode = generate,
    },

    statements: std.ArrayList(*ParseNode),

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        for (self.statements) |statement| {
            _ = try statement.toByteCode(statement, codegen, breaks);
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Block\", \"statements\": [");

        for (self.statements.items) |statement, i| {
            try statement.toJson(statement, out);

            if (i < self.statements.items.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .statements = std.ArrayList(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.statements.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Block) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const SuperNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Super,
        .toJson = stringify,
        .toByteCode = generate,
    },

    this: *NamedVariableNode,
    identifier: Token,
    // if call, CallNode will fetch super
    super: ?*NamedVariableNode = null,
    call: ?*CallNode = null,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.call) |call| {
            _ = try call.node.toByteCode(call.node, codegen, breaks);
        } else {
            assert(self.super != null);

            _ = try self.super.?.node.toByteCode(self.super.?.node, codegen, breaks);

            try codegen.emitCodeArg(.OP_GET_SUPER, try codegen.identifierConstant(self.identifier.lexeme));
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Super\", \"member_name\": \"{s}\", ", .{self.member_name.lexeme});

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Super) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const DotNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Dot,
        .toJson = stringify,
        .toByteCode = generate,
    },

    callee: *ParseNode,
    identifier: Token,
    value: ?*ParseNode = null,
    call: ?*CallNode = null,
    enum_index: ?usize = null,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;
        const callee_type = self.callee.type_def.?;

        if (callee_type.def_type == .Placeholder) {
            try codegen.reportErrorAt(node.location, "Unknown type");
        }

        // zig fmt: off
        if (callee_type.def_type != .ObjectInstance
            and callee_type.def_type != .Object
            and callee_type.def_type != .Enum
            and callee_type.def_type != .EnumInstance
            and callee_type.def_type != .List
            and callee_type.def_type != .Map
            and callee_type.def_type != .String) {
            try codegen.reportErrorAt(node.location, "Doesn't have field access.");
        }
        // zig fmt: on

        switch (callee_type.def_type) {
            .String => {
                if (self.call) |call_node| { // Call
                    try codegen.emitOpCode(.OP_COPY);
                    _ = try call_node.toByteCode(call_node, codegen, breaks);
                } else { // Expression
                    try codegen.emitCodeArg(.OP_GET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                }
            },
            .ObjectInstance, .Object => {
                if (self.value) |value| {
                    if (value.type_def == null or value.type_def.?.def_type == .Placeholder) {
                        try codegen.reportErrorAt(value.location, "Unknown type");
                    }

                    _ = try value.toByteCode(value, codegen, breaks);

                    try codegen.emitCodeArg(.OP_SET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                } else if (self.call) |call| {
                    _ = try call.node.toByteCode(call.node, codegen, breaks);
                } else {
                    try codegen.emitCodeArg(.OP_GET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                }
            },
            .Enum => {
                try codegen.emitCodeArg(.OP_GET_ENUM_CASE, self.enum_index.?);
            },
            .EnumInstance => {
                assert(std.mem.eql(u8, self.identifier.lexeme, "value"));

                try codegen.emitOpCode(.OP_GET_ENUM_CASE_VALUE);
            },
            .List, .Map => {
                if (self.call) |call| {
                    try codegen.emitOpCode(.OP_COPY);

                    _ = try call.node.toByteCode(call.node, codegen, breaks);
                } else {
                    try codegen.emitCodeArg(.OP_GET_PROPERTY, try codegen.identifierConstant(self.identifier.lexeme));
                }
            },
            else => unreachable,
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"Dot\", \"callee\": ");

        try self.callee.toJson(self.callee, out);

        try out.print(", \"identifier\": \"{s}\", ", .{self.identifier.lexeme});

        if (self.value) |value| {
            try out.writeAll("\"value\": ");
            try value.toJson(value, out);
            try out.writeAll(", ");
        }

        if (self.call) |call| {
            try out.writeAll("\"value\": ");
            try call.toNode().toJson(call.toNode(), out);
            try out.writeAll(", ");
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Dot) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ObjectInitNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .ObjectInit,
        .toJson = stringify,
        .toByteCode = generate,
    },

    properties: std.StringHashMap(*ParseNode),

    fn getSuperField(self: *Self, object: *ObjTypeDef, name: []const u8) ?*ObjTypeDef {
        const obj_def: ObjObject.ObjectDef = object.resolved_type.?.Object;
        if (obj_def.fields.get(name)) |obj_field| {
            return obj_field;
        } else if (obj_def.super) |obj_super| {
            return self.getSuperField(obj_super, name);
        }

        return null;
    }

    fn checkOmittedProperty(self: *Self, codegen: *CodeGen, obj_def: ObjObject.ObjectDef, init_properties: std.StringHashMap(void)) anyerror!void {
        var it = obj_def.fields.iterator();
        while (it.next()) |kv| {
            // If ommitted in initialization and doesn't have default value
            if (init_properties.get(kv.key_ptr.*) == null and obj_def.fields_defaults.get(kv.key_ptr.*) == null) {
                try codegen.reportErrorFmt(self.node.location, "Property `{s}` was not initialized and has no default value", .{kv.key_ptr.*});
            }
        }

        if (obj_def.super) |super_def| {
            try self.checkOmittedProperty(super_def.resolved_type.?.Object, init_properties);
        }
    }

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        try codegen.emitOpCode(.OP_INSTANCE);

        if (node.type_def == null or node.type_def.?.def_type == .Placeholder) {
            try codegen.reportErrorAt(node.location, "Unknown type.");
        } else if (node.type_def.?.def_type != .ObjectInstance) {
            try codegen.reportErrorAt(node.location, "Expected an object or a class.");
        }

        const object_type = node.type_def.?.resolved_type.?.ObjectInstance;
        const obj_def = object_type.resolved_type.?.Object;

        // To keep track of what's been initialized or not by this statement
        var init_properties = std.StringHashMap(void).init(self.allocator);
        defer init_properties.deinit();

        var it = self.properties.iterator();
        while (it.next()) |kv| {
            const property_name = kv.key_ptr.*;
            const property_name_constant: u24 = try codegen.identifierConstant(property_name);
            const value = kv.value_ptr.*;

            if (obj_def.fields.get(property_name) orelse self.getSuperField(object_type, property_name)) |prop| {
                try self.emitCodeArg(.OP_COPY, 0); // Will be popped by OP_SET_PROPERTY

                if (value.type_def == null or value.type_def == .Placeholder) {
                    try codegen.reportErrorAt(value.location, "Unknown type.");
                } else if (!value.type_def.?.eql(prop)) {
                    try codegen.reportTypeCheckAt(prop, value.type_def.?, "Wrong property type", value.location);
                }

                _ = try value.toByteCode(value, codegen, breaks);

                try init_properties.put(property_name, {});

                try self.emitCodeArg(.OP_SET_PROPERTY, property_name_constant);
                try self.emitOpCode(.OP_POP); // Pop property value
            } else {
                try codegen.reportErrorFmt("Property `{s}` does not exists", .{property_name});
            }
        }

        // Did we initialized all properties without a default value?
        try self.checkOmittedProperty(codegen, obj_def, init_properties);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"ObjectInit\", \"properties\": {");

        var it = self.properties.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) {
                try out.writeAll(",");
            }

            first = false;

            try out.print("\"{s}\": ", .{entry.key_ptr.*});

            try entry.value_ptr.*.toJson(entry.value_ptr.*, out);
        }

        try out.writeAll("}, ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .properties = std.StringHashMap(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.properties.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .ObjectInit) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ObjectDeclarationNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .ObjectDeclaration,
        .toJson = stringify,
        .toByteCode = generate,
    },

    parent_slot: ?usize = null,
    slot: usize,
    methods: std.StringHashMap(*ParseNode),
    properties: std.StringHashMap(?*ParseNode),

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        const object_type = node.type_def.?;
        const name_constant = try codegen.makeConstant(object_type.resolved_type.?.Object.name.toValue());
        const object_type_constant = try codegen.makeConstant(object_type.toValue());

        // Put  object on the stack and define global with it
        try codegen.emitCodeArg(.OP_OBJECT, name_constant);
        try codegen.emit(@intCast(u32, object_type_constant));
        try codegen.emitCodeArg(.OP_DEFINE_GLOBAL, @intCast(u24, self.slot));

        // Does it inherits from another object/class
        if (self.parent_slot) |parent_slot| {
            // Put parent on the stack as the `super` local
            try codegen.emitCodeArg(.OP_GET_GLOBAL, @intCast(u24, parent_slot));

            // Actually do the inheritance
            try codegen.emitCodeArg(.OP_GET_GLOBAL, @intCast(u24, self.slot));
            try codegen.emitCodeArg(.OP_INHERIT, @intCast(u24, parent_slot));
        }

        // Put the object on the stack to set its fields
        try codegen.emitCodeArg(.OP_GET_GLOBAL, @intCast(u24, self.slot));

        // Methods
        var it = self.methods.iterator();
        while (it.next()) |kv| {
            const member_name = kv.key_ptr.*;
            const member = kv.value_ptr.*;
            const member_name_constant: u24 = try self.identifierConstant(member_name);

            if (member.type_def == null or member.type_def.?.def_type == .Placeholder) {
                try codegen.reportErrorAt(member.location, "Unknown type");
            }

            const is_static = object_type.resolved_type.?.Object.static_fields.get(member_name) != null;

            _ = member.toByteCode(member, codegen, breaks);
            try codegen.emitCodeArg(if (is_static) .OP_PROPERTY else .OP_METHOD, member_name_constant);
        }

        // Properties
        var it2 = self.properties.iterator();
        while (it2.next()) |kv| {
            const member_name = kv.key_ptr.*;
            const member = kv.value_ptr.*;
            const member_name_constant: u24 = try self.identifierConstant(member_name);
            const is_static = object_type.resolved_type.?.Object.static_fields.get(member_name) != null;
            const property_type = object_type.resolved_type.?.Object.fields.get(member_name) orelse object_type.resolved_type.?.Object.static_fields.get(member_name);

            assert(property_type != null);

            // Create property default value
            if (member) |default| {
                if (default.type_def == null or default.type_def.?.def_type == .Placeholder) {
                    try codegen.reportErrorAt(default.location, "Unknown type");
                } else if (!property_type.eql(default.type_def.?)) {
                    try codegen.reportTypeCheckAt(property_type, default.type_def.?, "Wrong property default value type", default.location);
                }

                if (is_static) {
                    try codegen.emitOpCode(.OP_COPY);
                }

                _ = try default.toByteCode(default, codegen, breaks);

                // Create property default value
                if (is_static) {
                    try codegen.emitCodeArg(.OP_SET_PROPERTY, member_name_constant);
                    try codegen.emitOpCode(.OP_POP);
                } else {
                    try codegen.emitCodeArg(.OP_PROPERTY, member_name_constant);
                }
            }
        }

        // Pop object
        try codegen.emitOpCode(.OP_POP);

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.writeAll("{\"node\": \"ObjectDeclaration\", \"members\": [");

        for (self.members) |member, i| {
            try member.toJson(member, out);

            if (i < self.members.len - 1) {
                try out.writeAll(",");
            }
        }

        try out.writeAll("], ");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn init(allocator: Allocator) Self {
        return Self{
            .properties = std.StringHashMap(*ParseNode).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.properties.deinit();
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .ObjectDeclaration) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ExportNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Export,
        .toJson = stringify,
        .toByteCode = generate,
    },

    identifier: Token,
    alias: ?Token = null,

    pub fn generate(_: *ParseNode, _: *CodeGen, _: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Export\", \"identifier\": \"{s}\", ", .{self.identifier.lexeme});

        if (self.alias) |alias| {
            try out.print("\"alias\": \"{s}\", ", .{alias.lexeme});
        }

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Export) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};

pub const ImportNode = struct {
    const Self = @This();

    node: ParseNode = .{
        .node_type = .Import,
        .toJson = stringify,
        .toByteCode = generate,
    },

    imported_symbols: ?std.StringHashMap(void) = null,
    prefix: ?Token = null,
    path: Token,
    import: ?Parser.ScriptImport,

    pub fn generate(node: *ParseNode, codegen: *CodeGen, breaks: ?*std.ArrayList(usize)) anyerror!?*ObjFunction {
        _ = try node.generate(codegen, breaks);

        var self = Self.cast(node).?;

        if (self.import) |import| {
            try codegen.emitCodeArg(
                .OP_CONSTANT,
                try codegen.makeConstant(
                    (try import.function.toByteCode(import.function, codegen, breaks)).?.toValue(),
                ),
            );
            try codegen.emitOpCode(.OP_IMPORT);
        }

        return null;
    }

    fn stringify(node: *ParseNode, out: std.ArrayList(u8).Writer) anyerror!void {
        var self = Self.cast(node).?;

        try out.print("{{\"node\": \"Import\", \"path\": \"{s}\"", .{self.path.literal_string});

        if (self.prefix) |prefix| {
            try out.print(",\"prefix\": \"{s}\"", .{prefix.lexeme});
        }

        try out.writeAll(",\"imported_symbols\": [");
        if (self.imported_symbols) |imported_symbols| {
            var key_it = imported_symbols.keyIterator();
            var total = imported_symbols.count();
            var count: usize = 0;
            while (key_it.next()) |symbol| {
                try out.print("\"{s}\"", .{symbol});

                if (count < total - 1) {
                    try out.writeAll(",");
                }

                count += 1;
            }
        }
        try out.writeAll("]");

        if (self.import) |import| {
            try out.writeAll(",\"import\": ");
            try import.function.toJson(import.function, out);
        }

        try out.writeAll(",");

        try ParseNode.stringify(node, out);

        try out.writeAll("}");
    }

    pub fn toNode(self: *Self) *ParseNode {
        return &self.node;
    }

    pub fn cast(node: *ParseNode) ?*Self {
        if (node.node_type != .Import) {
            return null;
        }

        return @fieldParentPtr(Self, "node", node);
    }
};