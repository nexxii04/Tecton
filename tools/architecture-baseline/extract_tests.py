import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "tools/architecture-baseline"
SPEC = importlib.util.spec_from_file_location("metrics", BASE / "metrics.py")
METRICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METRICS)
STARTS = {
    "tecton.zig": "test ",
    "network/network_handler.zig": "fn test",
    "plugins/runtime.zig": "test ",
    "world/provider/persistence.zig": "const FakeSink",
    "tasks/threaded_tasks.zig": "test ",
    "world/block/traits/chest.zig": "test ",
    "items/enchantments/ops.zig": "const testing",
    "entity/traits/chunk_streaming.zig": "test ",
    "network/movement_broadcast.zig": "test ",
    "entity/traits/villager_trade.zig": "test ",
    "network/handlers/item_stack_request.zig": "test ",
    "world/provider/leveldb_provider.zig": "test ",
    "entity/traits/chunk_generation.zig": "test ",
    "world/dimension/dimension.zig": "test ",
    "network/compression/compression.zig": "test ",
}


def top_names(source):
    return list(dict.fromkeys(re.findall(r'^(?:pub )?(?:threadlocal )?(?:const|var|fn) ([A-Za-z_][A-Za-z_0-9]*)', source, re.M)))


def extract(path, prefix, source=None):
    source = path.read_text() if source is None else source
    found = re.search(r'^' + re.escape(prefix), source, re.M)
    if not found:
        found = re.search(r'^test ', source, re.M)
    if not found:
        return None
    lex = METRICS.tokens(source)
    depth = 0
    start = None
    ranges = []
    for token, offset in lex:
        if token == "test" and depth == 0:
            start = offset
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
            if depth == 0 and start is not None:
                ranges.append((start, offset + 1))
                start = None
    suffix = "\n\n".join(source[a:z] for a, z in ranges) + "\n"
    production = source
    for a, z in reversed(ranges):
        production = production[:a] + production[z:]
    production = production.rstrip() + "\n"
    names = [n for n in top_names(production) if re.search(r'\b' + re.escape(n) + r'\b', suffix)]
    dependencies = {}
    for match in re.finditer(r'@import\("([^"\n]+\.zig)"\)', suffix):
        name = match.group(1)
        dependencies.setdefault(name, "test_dependency_" + str(len(dependencies)))
    for name, alias in dependencies.items():
        suffix = suffix.replace('@import(' + json.dumps(name) + ')', 'scope.' + alias)
    lex = METRICS.tokens(suffix)
    tests = []
    depth = 0
    start = None
    for i, (token, offset) in enumerate(lex):
        if token == "test" and depth == 0:
            start = (i, offset)
        if token == "{":
            depth += 1
        if token == "}":
            depth -= 1
            if depth == 0 and start is not None:
                begin, position = start
                brace = next(j for j in range(begin, i) if lex[j][0] == "{")
                title = suffix[position:lex[brace][1]].strip()
                tests.append((position, offset + 1, title, suffix[lex[brace][1] + 1:offset]))
                start = None
    private = {}
    modified_lex = METRICS.tokens(suffix)
    depth = 0
    replacements = []
    titles = []
    for i, (token, offset) in enumerate(modified_lex):
        if token == "test" and depth == 0:
            brace = next(j for j in range(i, len(modified_lex)) if modified_lex[j][0] == "{")
            title = suffix[offset:modified_lex[brace][1]].strip()
            titles.append(title)
            replacements.append((offset, modified_lex[brace][1], f"pub fn case_{len(titles) - 1:03d}() !void "))
        if token == "{": depth += 1
        if token == "}": depth -= 1
    for a, z, text in reversed(replacements):
        suffix = suffix[:a] + text + suffix[z:]
    aliases = "\n".join(f"const {n} = scope.{n};" for n in names)
    aliases += "\n" + "\n".join(f"const {n} = scope.{n};" for n in private.values())
    suite = "pub fn Suite(comptime scope: type) type {\nreturn struct {\n" + aliases + "\n" + suffix + "\n};\n}\n"
    suite = METRICS.TOKEN.sub(lambda match: "" if match.group().startswith(("//", "/*")) else match.group(), suite)
    scope_lines = [f"pub const {alias} = @import({json.dumps(name)});" for name, alias in dependencies.items()]
    scope_lines += [f"pub const {n} = test_owner.{n};" for n in names]
    scope_lines += [f"pub const {alias} = test_owner.{old};" for old, alias in private.items()]
    production += "\nconst test_owner = @This();\nconst test_scope = struct {\n" + "\n".join(scope_lines) + "\n};\n"
    destination = path.with_name(path.stem + "_test.zig")
    if destination.exists() and source == path.read_text(): raise RuntimeError(f"test collision: {destination}")
    for i, title in enumerate(titles):
        production += f'\n{title} {{\ntry @import("{destination.name}").Suite(test_scope).case_{i:03d}();\n}}\n'
    production = METRICS.TOKEN.sub(lambda match: "" if match.group().startswith(("//", "/*")) else match.group(), production)
    path.write_text(production)
    destination.write_text(suite)
    return {"source": str(path.relative_to(ROOT)), "test_file": str(destination.relative_to(ROOT)), "tests": titles, "private_capabilities": private, "borrowed_declarations": names, "borrowed_imports": dependencies, "before_sha256": hashlib.sha256(source.encode()).hexdigest(), "assertions_before": sum(len(re.findall(r'\b(?:expect\w*|assert)\s*\(', source[a:z])) for a, z in ranges), "assertions_after": len(re.findall(r'\b(?:expect\w*|assert)\s*\(', suite))}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--output", type=Path, default=BASE / "evidence/r2/test-extraction.json")
    args = parser.parse_args()
    selections = {name: STARTS.get(name, "test ") for name in args.paths} if args.paths else STARTS
    for name in selections:
        path = ROOT / "src/tecton" / name
        if not path.is_file() or path.with_name(path.stem + "_test.zig").exists():
            raise RuntimeError(f"missing source or existing suite: {name}")
    entries = []
    for name, prefix in selections.items():
        entries.append(extract(ROOT / "src/tecton" / name, prefix))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(entries, indent=2) + "\n")
    print(f"Extracted {sum(len(e['tests']) for e in entries if e)} tests across {len(entries)} sources")


if __name__ == "__main__":
    main()
