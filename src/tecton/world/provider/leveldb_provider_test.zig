pub fn Suite(comptime scope: type) type {
    return struct {
        const Part0 = @import("leveldb_provider_test_part_1.zig").Suite(scope);
        pub const case_000 = Part0.case_000;
        pub const case_001 = Part0.case_001;
        pub const case_002 = Part0.case_002;
        pub const case_003 = Part0.case_003;
        const Part1 = @import("leveldb_provider_test_part_2.zig").Suite(scope);
        pub const case_004 = Part1.case_004;
        pub const case_005 = Part1.case_005;
    };
}
