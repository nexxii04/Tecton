pub fn Suite(comptime Tecton: type, comptime Entity: type, comptime Dimension: type) type {
    return struct {
        fn cast(ctx: *anyopaque) *Tecton {
            return @ptrCast(@alignCast(ctx));
        }

        pub fn shutdown(ctx: *anyopaque) anyerror!void {
            return cast(ctx).shutdown();
        }

        pub fn registerEcsEntity(ctx: *anyopaque, entity: *Entity) void {
            cast(ctx).registerEcsEntity(entity);
        }

        pub fn unregisterEcsEntity(ctx: *anyopaque, entity: *Entity) void {
            cast(ctx).unregisterEcsEntity(entity);
        }

        pub fn refreshWorldCommandEnums(ctx: *anyopaque) void {
            cast(ctx).refreshWorldCommandEnums();
        }

        pub fn refreshFloatingTextCommandEnums(ctx: *anyopaque) void {
            cast(ctx).refreshFloatingTextCommandEnums();
        }

        pub fn assignDimension(ctx: *anyopaque, runtime_id: i64, dimension: *Dimension) anyerror!void {
            return cast(ctx).instances.assignDimension(runtime_id, dimension);
        }
    };
}
