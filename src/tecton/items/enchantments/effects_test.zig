pub fn Suite(comptime scope: type) type {
    return struct {
        const Part0 = @import("effects_test_part_1.zig").Suite(scope);
        pub const case_000 = Part0.case_000;
        pub const case_001 = Part0.case_001;
        pub const case_002 = Part0.case_002;
        pub const case_003 = Part0.case_003;
        pub const case_004 = Part0.case_004;
        pub const case_005 = Part0.case_005;
        pub const case_006 = Part0.case_006;
        pub const case_007 = Part0.case_007;
        pub const case_008 = Part0.case_008;
        pub const case_009 = Part0.case_009;
        pub const case_010 = Part0.case_010;
        const Part1 = @import("effects_test_part_2.zig").Suite(scope);
        pub const case_011 = Part1.case_011;
        pub const case_012 = Part1.case_012;
        pub const case_013 = Part1.case_013;
        pub const case_014 = Part1.case_014;
        pub const case_015 = Part1.case_015;
    };
}
