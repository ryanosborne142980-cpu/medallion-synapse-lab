"""Static checks for the repo's own SQL rules (CI runs this on every PR; no Azure access).

Usage:
    python scripts/lint_sql.py              # lint sql/*.sql
    python scripts/lint_sql.py sql/20_silver.sql
    python scripts/lint_sql.py --fix        # apply safe fixes, then lint
    python scripts/lint_sql.py --fix sql/20_silver.sql

Use --fix to apply safe, mechanical corrections before reporting remaining problems.

Not a general T-SQL parser: sqlfluff's tsql dialect rejects valid Synapse syntax (external file
formats, CETAS), so this enforces only the CLAUDE.md conventions that break deploys or
idempotency. Exits 1 if any rule fails, printing `file:line: rule: message`.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# Variables run_sql.py fills from Azure (lab_settings); anything else would need --var.
KNOWN_VARIABLES = {"storage_account", "workspace"}
VARIABLE = re.compile(r"\$\((\w+)\)")
FILE_NAME = re.compile(r"^(\d{2})_[a-z0-9_]+\.sql$")
HOSTED_URL = re.compile(
    r"https://(?!\$\()([^./'\s]+)\.(?:dfs|blob)\.core\.windows\.net", re.IGNORECASE
)
SQL_HOST = re.compile(
    r"(?<!\$\()(?<![\w.-])([\w][\w-]*?)(-ondemand)?\.sql\.azuresynapse\.net",
    re.IGNORECASE,
)
USE_STMT = re.compile(r"^[ \t]*USE\s+\[?\w+", re.IGNORECASE | re.MULTILINE)
SELECT_STAR = re.compile(
    r"\bSELECT\s+(?:DISTINCT\s+)?(?:TOP\s*\(?\s*\d+\s*\)?\s+)?\*", re.IGNORECASE
)
CREATE_VIEW = re.compile(r"\bCREATE\s+VIEW\b", re.IGNORECASE)
GUARDED_CREATE = re.compile(
    r"\bCREATE\s+(SCHEMA|DATABASE|EXTERNAL\s+DATA\s+SOURCE|EXTERNAL\s+FILE\s+FORMAT"
    r"|DATABASE\s+SCOPED\s+CREDENTIAL)\b",
    re.IGNORECASE,
)
CREATE_EXTERNAL_TABLE = re.compile(
    r"\bCREATE\s+EXTERNAL\s+TABLE\s+([\w.\[\]]+)", re.IGNORECASE
)
IF_GUARD = re.compile(
    r"\bIF\s+NOT\s+EXISTS\b|\bIF\s+\w+\s*\([^)]*\)\s+IS\s+NULL\b", re.IGNORECASE
)
GO_LINE = re.compile(r"^\s*GO\s*$", re.IGNORECASE | re.MULTILINE)
FIRST_PAST_BRONZE = 20  # files numbered >= 20 (silver, gold) may not use SELECT *


def blank(text: str, start: int, end: int) -> str:
    """Replace text[start:end] with spaces, keeping newlines so line numbers survive."""
    return text[:start] + re.sub(r"[^\n]", " ", text[start:end]) + text[end:]


def strip(sql: str, *, strings: bool) -> str:
    """Blank out comments (and string literals if `strings`), preserving offsets."""
    out, i = sql, 0
    while i < len(out):
        two = out[i : i + 2]
        if two == "--":
            end = out.find("\n", i)
            end = len(out) if end == -1 else end
            out = blank(out, i, end)
            i = end
        elif two == "/*":
            end = out.find("*/", i + 2)
            end = len(out) if end == -1 else end + 2
            out = blank(out, i, end)
            i = end
        elif out[i] == "'":
            end = i + 1
            while end < len(out):
                if out[end] == "'" and out[end + 1 : end + 2] == "'":
                    end += 2
                elif out[end] == "'":
                    break
                else:
                    end += 1
            end += 1
            if strings:
                out = blank(out, i + 1, end - 1)
            i = end
        else:
            i += 1
    return out


def line_of(text: str, pos: int) -> int:
    return text.count("\n", 0, pos) + 1


def fix(path: Path) -> int:
    """Apply safe mechanical fixes and return the number of replacements made."""
    raw = path.read_text(encoding="utf-8")
    no_comments = strip(raw, strings=False)
    code = strip(raw, strings=True)
    edits: list[tuple[int, int, str]] = []

    edits.extend(
        (m.start(), m.end(), "CREATE OR ALTER VIEW") for m in CREATE_VIEW.finditer(code)
    )
    edits.extend(
        (m.start(1), m.end(1), "$(storage_account)")
        for m in HOSTED_URL.finditer(no_comments)
    )
    edits.extend(
        (m.start(1), m.end(1), "$(workspace)") for m in SQL_HOST.finditer(no_comments)
    )

    if not edits:
        return 0

    for start, end, replacement in sorted(edits, reverse=True):
        raw = raw[:start] + replacement + raw[end:]
    path.write_bytes(raw.encode("utf-8"))
    return len(edits)


def lint(path: Path) -> list[str]:
    raw = path.read_text(encoding="utf-8")
    no_comments = strip(raw, strings=False)
    code = strip(raw, strings=True)  # no comments, no string contents
    problems: list[str] = []

    def report(pos: int, rule: str, message: str) -> None:
        problems.append(f"{path.as_posix()}:{line_of(raw, pos)}: {rule}: {message}")

    match = FILE_NAME.match(path.name)
    if not match:
        report(0, "file-name", "expected NN_snake_case.sql (e.g. 20_silver.sql)")
    number = int(match.group(1)) if match else 0

    for m in VARIABLE.finditer(no_comments):
        if m.group(1) not in KNOWN_VARIABLES:
            report(
                m.start(),
                "unknown-variable",
                f"$({m.group(1)}) is not one of {sorted(KNOWN_VARIABLES)}",
            )

    for pattern in (HOSTED_URL, SQL_HOST):
        for m in pattern.finditer(no_comments):
            report(m.start(), "hard-coded-name", "use $(storage_account)/$(workspace)")

    for m in USE_STMT.finditer(code):
        report(
            m.start(),
            "no-use",
            "serverless can't USE mid-script; give master its own file",
        )

    for m in CREATE_VIEW.finditer(code):
        report(m.start(), "create-or-alter", "use CREATE OR ALTER VIEW (re-runnable)")

    if number >= FIRST_PAST_BRONZE:
        for m in SELECT_STAR.finditer(code):
            report(m.start(), "select-star", "explicit column lists past bronze")

    # An IF guard (IF NOT EXISTS / IF DB_ID(...) IS NULL) must sit in the CREATE's GO batch.
    batch_starts = [0] + [m.end() for m in GO_LINE.finditer(code)]
    for m in GUARDED_CREATE.finditer(code):
        batch_start = max(s for s in batch_starts if s <= m.start())
        before = code[batch_start : m.start()]
        if not IF_GUARD.search(before):
            report(
                m.start(),
                "guarded-create",
                f"CREATE {m.group(1).upper()} needs an IF guard in its batch",
            )

    for m in CREATE_EXTERNAL_TABLE.finditer(code):
        name = re.escape(m.group(1))
        drop = re.compile(rf"\bDROP\s+EXTERNAL\s+TABLE\s+{name}\b", re.IGNORECASE)
        if not drop.search(code, 0, m.start()):
            report(
                m.start(),
                "cetas-drop",
                f"CREATE EXTERNAL TABLE {m.group(1)} needs an earlier IF EXISTS ... DROP "
                "(CETAS can't overwrite; see /rebuild)",
            )

    return problems


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="*", type=Path, help="default: sql/*.sql")
    parser.add_argument(
        "--fix",
        action="store_true",
        help="apply safe mechanical fixes before linting",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    files = args.files or sorted((root / "sql").glob("*.sql"))
    if not files:
        raise SystemExit("no .sql files found")

    fixed = sum(fix(f) for f in files) if args.fix else 0
    if fixed:
        print(f"lint_sql: applied {fixed} safe fix(es)")

    problems = [p for f in files for p in lint(f)]
    for p in problems:
        print(p)
    print(f"lint_sql: {len(files)} file(s), {len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
