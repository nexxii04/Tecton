import tempfile
from pathlib import Path
import unittest

import extract_tests


class ExtractionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.old_root = extract_tests.ROOT
        self.addCleanup(setattr, extract_tests, "ROOT", self.old_root)
        extract_tests.ROOT = Path(self.directory.name)

    def extract(self, source):
        path = extract_tests.ROOT / "sample.zig"
        path.write_text(source)
        result = extract_tests.extract(path, "test ")
        return path.read_text(), path.with_name("sample_test.zig").read_text(), result

    def test_interleaved_production_stays_in_owner(self):
        owner, suite, result = self.extract(
            'const std = @import("std");\n'
            'pub const Kind = struct { value: u8 };\n'
            'test "first" { try std.testing.expect(true); }\n'
            'pub fn after() u8 { return 7; }\n'
            'test "second" { try std.testing.expectEqual(7, after()); }\n'
            'pub const Trait = Kind;\n'
        )
        self.assertIn('pub fn after() u8 { return 7; }', owner)
        self.assertIn('pub const Trait = Kind;', owner)
        self.assertNotIn('pub fn after()', suite)
        self.assertNotIn('pub const Trait', suite)
        self.assertEqual(result['tests'], ['test "first"', 'test "second"'])
        self.assertEqual(result['assertions_before'], result['assertions_after'])

    def test_test_import_is_borrowed_without_inverse_edge(self):
        owner, suite, result = self.extract(
            'const std = @import("std");\n'
            'test "borrow" { const dep = @import("dependency.zig"); try std.testing.expect(dep.valid); }\n'
        )
        self.assertIn('@import("dependency.zig")', owner)
        self.assertNotIn('@import("dependency.zig")', suite)
        self.assertIn('scope.test_dependency_0', suite)
        self.assertEqual(result['borrowed_imports'], {'dependency.zig': 'test_dependency_0'})

    def test_member_access_is_not_mistaken_for_private_function(self):
        owner, suite, result = self.extract(
            'const std = @import("std");\n'
            'const identity = @import("identity.zig");\n'
            'const Other = struct { fn xuid() void {} };\n'
            'test "field" { var result = identity.make(); try std.testing.expect(result.identity.xuid.len > 0); }\n'
        )
        self.assertIn('result.identity.xuid.len', suite)
        self.assertEqual(result['private_capabilities'], {})
        self.assertIn('const Other', owner)

    def test_existing_suite_is_not_overwritten(self):
        path = extract_tests.ROOT / 'sample.zig'
        path.write_text('test "once" {}\n')
        destination = path.with_name('sample_test.zig')
        destination.write_text('existing\n')
        with self.assertRaises(RuntimeError):
            extract_tests.extract(path, 'test ')
        self.assertEqual(destination.read_text(), 'existing\n')
        self.assertEqual(path.read_text(), 'test "once" {}\n')


if __name__ == '__main__':
    unittest.main()
