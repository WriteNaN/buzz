const obj = @import("../obj.zig");
const Value = @import("../value.zig").Value;

pub fn toList(ctx: *obj.NativeCtx) c_int {
    const range = ctx.vm.peek(0).obj().access(obj.ObjRange, .Range, ctx.vm.gc).?;

    var list: *obj.ObjList = ctx.vm.gc.allocateObject(
        obj.ObjList,
        obj.ObjList.init(
            ctx.vm.gc.allocator,
            ctx.vm.gc.type_registry.getTypeDef(
                .{
                    .def_type = .Integer,
                },
            ) catch @panic("Could not instanciate list"),
        ),
    ) catch @panic("Could not instanciate range");

    ctx.vm.push(Value.fromObj(list.toObj()));

    if (range.low < range.high) {
        var i: i32 = range.low;
        while (i < range.high) : (i += 1) {
            list.rawAppend(ctx.vm.gc, Value.fromInteger(i)) catch @panic("Could not append to list");
        }
    } else {
        var i: i32 = range.low;
        while (i > range.high) : (i -= 1) {
            list.rawAppend(ctx.vm.gc, Value.fromInteger(i)) catch @panic("Could not append to list");
        }
    }

    return 1;
}

pub fn len(ctx: *obj.NativeCtx) c_int {
    const range = ctx.vm.peek(0).obj().access(obj.ObjRange, .Range, ctx.vm.gc).?;

    ctx.vm.push(
        Value.fromInteger(
            if (range.low < range.high)
                range.high - range.low
            else
                range.low - range.high,
        ),
    );

    return 1;
}

pub fn invert(ctx: *obj.NativeCtx) c_int {
    const range = ctx.vm.peek(0).obj().access(obj.ObjRange, .Range, ctx.vm.gc).?;

    ctx.vm.push(
        Value.fromObj((ctx.vm.gc.allocateObject(
            obj.ObjRange,
            obj.ObjRange{
                .high = range.low,
                .low = range.high,
            },
        ) catch @panic("Could not instanciate range")).toObj()),
    );

    return 1;
}
