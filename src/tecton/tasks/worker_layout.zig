const std = @import("std");

pub const WorkerLayout = enum { shared, split };

pub const WorkerCountResolution = struct {
    cpu_count: usize,
    recommended_max: usize,
    requested_count: usize,
    resolved_count: usize,
    auto_selected: bool,
};

pub const WorkerLayoutResolution = struct {
    layout: WorkerLayout,
    cpu_count: usize,
    worker_count: usize,
    input_worker_count: usize,
    world_worker_count: usize,
};

pub fn computeWorkerCount(configured_count: usize) usize {
    return resolveWorkerCount(configured_count).resolved_count;
}

pub fn totalServerThreadCount(worker_count: usize) usize {
    return 1 + 3 + worker_count;
}

pub fn resolveWorkerCount(configured_count: usize) WorkerCountResolution {
    const cpu_count = std.Thread.getCpuCount() catch 4;
    return resolveWorkerCountForCpu(configured_count, cpu_count);
}

pub fn resolveWorkerCountForCpu(configured_count: usize, cpu_count: usize) WorkerCountResolution {
    const recommended_max = recommendedWorkerCountForCpu(cpu_count);
    if (configured_count > 0) {
        return .{
            .cpu_count = cpu_count,
            .recommended_max = recommended_max,
            .requested_count = configured_count,
            .resolved_count = @min(configured_count, recommended_max),
            .auto_selected = false,
        };
    }

    return .{
        .cpu_count = cpu_count,
        .recommended_max = recommended_max,
        .requested_count = 0,
        .resolved_count = recommended_max,
        .auto_selected = true,
    };
}

fn recommendedWorkerCountForCpu(cpu_count: usize) usize {
    if (cpu_count <= 2) return 1;
    const count = cpu_count - 2;
    return @max(@as(usize, 1), @min(count, 16));
}

pub fn resolveWorkerLayout(requested: WorkerLayout, worker_count: usize, cpu_count: usize) WorkerLayoutResolution {
    if (requested == .split and worker_count >= 2) {
        const requested_input = @max(@as(usize, 1), cpu_count / 4);
        const input_count = @min(requested_input, worker_count - 1);
        return .{
            .layout = .split,
            .cpu_count = cpu_count,
            .worker_count = worker_count,
            .input_worker_count = input_count,
            .world_worker_count = worker_count - input_count,
        };
    }
    return .{
        .layout = .shared,
        .cpu_count = cpu_count,
        .worker_count = worker_count,
        .input_worker_count = 0,
        .world_worker_count = worker_count,
    };
}
