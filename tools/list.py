"""python -m tools.list — print the tools.yaml registry as a table."""
from __future__ import annotations

from pathlib import Path

from tools.registry import read_tools


def run_list(*, path: Path | None = None) -> int:
    specs = read_tools(path)
    cols = ("name", "kind", "enabled", "cost_tier", "capability")
    rows = [
        (s.name, s.kind, str(s.enabled), s.cost_tier, s.capability or "")
        for s in specs
    ]
    widths = [max(len(c), *(len(r[i]) for r in rows)) if rows else len(c)
              for i, c in enumerate(cols)]
    line = "  ".join(c.ljust(widths[i]) for i, c in enumerate(cols))
    print(line)
    print("  ".join("-" * widths[i] for i in range(len(cols))))
    for r in rows:
        print("  ".join(r[i].ljust(widths[i]) for i in range(len(cols))))
    return 0


def main(argv: list[str] | None = None) -> int:
    return run_list()


if __name__ == "__main__":
    raise SystemExit(main())
