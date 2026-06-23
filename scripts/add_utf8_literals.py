#!/usr/bin/env python3
"""Add /utf8 to all Erlang <<"string">> literals that lack it."""
import re
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
PATHS = list(ROOT.glob("src/**/*.erl")) + list(ROOT.glob("test/**/*.erl"))

PAT = re.compile(r'<<"((?:[^"\\]|\\.)*)">>(?!/)')


def fix_line(line: str) -> str:
    return PAT.sub(r'<<"\1"/utf8>>', line)


def main() -> None:
    changed = []
    for path in PATHS:
        text = path.read_text(encoding="utf-8")
        new = "\n".join(fix_line(line) for line in text.splitlines())
        if new != text:
            path.write_text(new, encoding="utf-8")
            changed.append(path.relative_to(ROOT))
    print(f"Updated {len(changed)} files")
    for p in changed:
        print(p)


if __name__ == "__main__":
    import sys
    if "--check" in sys.argv:
        remaining = 0
        for path in PATHS:
            for i, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if PAT.search(line):
                    remaining += 1
                    print(f"{path.relative_to(ROOT)}:{i}: {line.strip()[:120]}")
        print(f"remaining: {remaining}")
    else:
        main()
