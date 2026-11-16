"""Rebuild a silver or gold layer: drop its CETAS tables, delete their lake folders, re-run the SQL.

Usage:
    python scripts/rebuild_layer.py silver                  # dry run: show the plan, change nothing
    python scripts/rebuild_layer.py silver --apply          # drop, delete, re-run, count, run checks
    python scripts/rebuild_layer.py gold --apply --rerun-check   # rebuild twice, compare row counts

CETAS can't overwrite: re-running a layer file fails while the target folder still holds files.
Targets are parsed from sql/NN_<layer>.sql: every `CREATE EXTERNAL TABLE <name> WITH (LOCATION =
'<layer>/...', ...) AS SELECT` statement. Plain external tables (no AS SELECT) are never touched,
and any LOCATION outside `<layer>/<subfolder>` aborts the run. Every step is idempotent, so a
failed run can simply be run again.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

from run_sql import GO_LINE, az, connect, lab_settings, run_batches, substitute

REPO = Path(__file__).resolve().parent.parent
LAYERS = ("silver", "gold")
DOWNSTREAM = {"silver": "gold"}
CETAS = re.compile(
    r"CREATE\s+EXTERNAL\s+TABLE\s+(?P<name>[\w\[\]]+\.[\w\[\]]+)\s+WITH\s*\((?P<options>[^)]*)\)\s*AS\b",
    re.IGNORECASE,
)
LOCATION = re.compile(r"LOCATION\s*=\s*'(?P<loc>[^']+)'", re.IGNORECASE)
SAFE_LOCATION = re.compile(r"^(?P<layer>silver|gold)/[\w\-]+(/[\w\-]+)*/?$")


@dataclass(frozen=True)
class Target:
    table: str
    folder: str


def layer_file(layer: str, override: Path | None) -> Path:
    if override:
        return override
    matches = sorted((REPO / "sql").glob(f"[0-9][0-9]_{layer}.sql"))
    if len(matches) != 1:
        raise SystemExit(
            f"Expected exactly one sql/NN_{layer}.sql, found {len(matches)}"
        )
    return matches[0]


def find_targets(sql: str, layer: str) -> list[Target]:
    targets = []
    for batch in GO_LINE.split(sql):
        code = re.sub(r"--[^\n]*", "", batch)  # ignore commented-out statements
        for match in CETAS.finditer(code):
            loc = LOCATION.search(match["options"])
            if not loc:
                raise SystemExit(f"{match['name']}: CETAS without LOCATION")
            folder = loc["loc"].strip("/")
            safe = SAFE_LOCATION.match(folder)
            if not safe or safe["layer"] != layer or ".." in folder:
                raise SystemExit(
                    f"{match['name']}: LOCATION '{loc['loc']}' is not under {layer}/<subfolder>; refusing"
                )
            targets.append(
                Target(match["name"].replace("[", "").replace("]", ""), folder)
            )
    if not targets:
        raise SystemExit(f"No CETAS statements found for layer {layer}")
    if len({t.folder for t in targets}) != len(targets):
        raise SystemExit("Two CETAS statements share a LOCATION; fix the SQL first")
    return targets


def drop_and_delete(conn, storage: str, targets: list[Target]) -> None:
    cursor = conn.cursor()
    for t in targets:
        print(f"  drop   {t.table}")
        cursor.execute(
            f"IF OBJECT_ID(N'{t.table}') IS NOT NULL DROP EXTERNAL TABLE {t.table};"
        )
        lake = [
            "--account-name",
            storage,
            "--file-system",
            "lake",
            "--name",
            t.folder,
            "--auth-mode",
            "login",
        ]
        exists = az(
            "storage",
            "fs",
            "directory",
            "exists",
            *lake,
            "--query",
            "exists",
            "-o",
            "tsv",
        )
        if exists == "true":
            print(f"  delete lake/{t.folder}/")
            az("storage", "fs", "directory", "delete", *lake, "--yes")
        else:
            print(f"  skip   lake/{t.folder}/ (not present)")
    cursor.close()


def row_counts(conn, targets: list[Target]) -> dict[str, int]:
    cursor = conn.cursor()
    counts = {
        t.table: cursor.execute(f"SELECT COUNT_BIG(*) FROM {t.table};").fetchone()[0]
        for t in targets
    }
    cursor.close()
    return counts


def rebuild(
    conn, storage: str, path: Path, sql: str, targets: list[Target], max_rows: int
) -> dict[str, int]:
    drop_and_delete(conn, storage, targets)
    run_batches(conn, path.name, sql, max_rows)
    counts = row_counts(conn, targets)
    for table, n in counts.items():
        print(f"  {table}: {n:,} rows")
    return counts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("layer", choices=LAYERS)
    parser.add_argument(
        "--apply", action="store_true", help="actually drop, delete, and rebuild"
    )
    parser.add_argument(
        "--rerun-check",
        action="store_true",
        help="rebuild a second time and compare counts",
    )
    parser.add_argument(
        "--no-checks", action="store_true", help="skip sql/90_checks.sql"
    )
    parser.add_argument("--file", type=Path, help="override the layer SQL file")
    parser.add_argument("-d", "--database", default="lab")
    parser.add_argument("--max-rows", type=int, default=10)
    args = parser.parse_args()

    path = layer_file(args.layer, args.file)
    variables = lab_settings()
    sql = substitute(path.read_text(encoding="utf-8"), variables)
    targets = find_targets(sql, args.layer)

    print(
        f"Rebuild plan for {args.layer} ({path.relative_to(REPO) if path.is_relative_to(REPO) else path}):"
    )
    for t in targets:
        print(f"  {t.table:<40} lake/{t.folder}/")
    if not args.apply:
        print("Dry run: nothing changed. Re-run with --apply to rebuild.")
        return

    conn = connect(
        f"{variables['workspace']}-ondemand.sql.azuresynapse.net", args.database
    )
    try:
        print("\n== Rebuild ==")
        first = rebuild(
            conn, variables["storage_account"], path, sql, targets, args.max_rows
        )
        if args.rerun_check:
            print("\n== Rerun check ==")
            second = rebuild(
                conn, variables["storage_account"], path, sql, targets, args.max_rows
            )
            drift = {t: (first[t], second[t]) for t in first if first[t] != second[t]}
            if drift:
                for table, (a, b) in drift.items():
                    print(f"  DRIFT {table}: {a:,} -> {b:,}", file=sys.stderr)
                raise SystemExit(
                    "Rerun check FAILED: row counts changed between rebuilds"
                )
            print("  Rerun check PASSED: row counts identical")
        checks = REPO / "sql" / "90_checks.sql"
        if checks.is_file() and not args.no_checks:
            print("\n== Checks ==")
            run_batches(
                conn,
                checks.name,
                substitute(checks.read_text(encoding="utf-8"), variables),
                50,
            )
    finally:
        conn.close()

    if args.layer in DOWNSTREAM:
        print(
            f"\nNote: {DOWNSTREAM[args.layer]} CETAS files are copies of the old {args.layer} data and are now "
            f"stale. Rebuild them: python scripts/rebuild_layer.py {DOWNSTREAM[args.layer]} --apply"
        )


if __name__ == "__main__":
    main()
