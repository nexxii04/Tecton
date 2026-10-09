pub fn Suite(comptime scope: type) type {
    return struct {
        const Part0 = @import("chest_test_part_1.zig").Suite(scope);
        pub const case_000 = Part0.case_000;
        pub const case_001 = Part0.case_001;
        pub const case_002 = Part0.case_002;
        const Part1 = @import("chest_test_part_2.zig").Suite(scope);
        pub const case_003 = Part1.case_003;
    };
}
