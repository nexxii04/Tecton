const std = @import("std");
const Chunk = @import("../chunk/chunk.zig").Chunk;
const TerrainGenerator = @import("./terrain-generator.zig").TerrainGenerator;

const GenerationRequest = struct {
    x: i32,
    z: i32,
    allocator: std.mem.Allocator,
    generator: TerrainGenerator,
    result: ?*Chunk = null,
    err: bool = false,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
};

pub const ThreadedGenerator = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    generator: TerrainGenerator,
    pool: std.Io.Group,

    pub fn init(io: std.Io, allocator: std.mem.Allocator, generator: TerrainGenerator) !*ThreadedGenerator {
        const self = try allocator.create(ThreadedGenerator);
        self.* = .{
            .io = io,
            .allocator = allocator,
            .generator = generator,
            .pool = .init,
        };
        return self;
    }

    pub fn deinit(self: *ThreadedGenerator) void {
        self.pool.cancel(self.io);
        self.generator.deinit();
        self.allocator.destroy(self);
    }

    pub fn generate(self: *ThreadedGenerator, x: i32, z: i32) !*Chunk {
        return self.generator.generate(self.allocator, x, z);
    }

    pub fn generateAsync(self: *ThreadedGenerator, x: i32, z: i32) !*Chunk {
        var request = GenerationRequest{
            .x = x,
            .z = z,
            .allocator = self.allocator,
            .generator = self.generator,
        };

        try self.pool.concurrent(self.io, runGeneration, .{ self.io, &request });

        try request.mutex.lock(self.io);
        defer request.mutex.unlock(self.io);
        while (!request.completed.load(.acquire)) {
            request.condition.wait(self.io, &request.mutex);
        }

        if (request.err) return error.GenerationFailed;
        return request.result.?;
    }

    fn runGeneration(io: std.Io, request: *GenerationRequest) void {
        const chunk = request.generator.generate(request.allocator, request.x, request.z) catch {
            request.mutex.lock(io) catch |err| {
                std.log.err("failed to acquire lock: {}", .{err});
                request.err = true;
                request.condition.signal();
                return;
            };
            request.err = true;
            request.completed.store(true, .release);
            request.condition.signal();
            request.mutex.unlock(io);
            return;
        };

        request.mutex.lock(io) catch |err| {
            std.log.err("failed to acquire lock: {}", .{err});
            request.err = true;
            request.condition.signal();
            return;
        };
        request.result = chunk;
        request.completed.store(true, .release);
        request.condition.signal();
        request.mutex.unlock(io);
    }
};
