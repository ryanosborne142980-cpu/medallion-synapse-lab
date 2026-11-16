"""Run .sql files against the Synapse serverless SQL endpoint with an Entra token from `az`.

Usage:
    python scripts/run_sql.py sql/00_setup.sql --database master
    python scripts/run_sql.py sql/10_bronze.sql sql/20_silver.sql
    python scripts/run_sql.py -q "SELECT COUNT(*) FROM bronze.nfip_claims"

Files are split into batches on lines containing only GO (like sqlcmd). sqlcmd-style
variables such as $(storage_account) are substituted, so the same files also run in
sqlcmd with -v or, after a manual find/replace, in Synapse Studio.
"""

from __future__ import annotations

import argparse
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

import pyodbc

SQL_COPT_SS_ACCESS_TOKEN = 1256
RESOURCE_GROUP = "rg-medallion-lab"
GO_LINE = re.compile(r"^\s*GO\s*$", re.IGNORECASE | re.MULTILINE)
VARIABLE = re.compile(r"\$\((\w+)\)")


def az(*args: str) -> str:
    exe = shutil.which("az") or shutil.which("az.cmd")
    if not exe:
        raise SystemExit("Azure CLI not found on PATH")
    result = subprocess.run([exe, *args], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"az {' '.join(args)} failed:\n{result.stderr.strip()}")
    return result.stdout.strip()


def lab_settings() -> dict[str, str]:
    workspace = az("synapse", "workspace", "list", "-g", RESOURCE_GROUP, "--query", "[0].name", "-o", "tsv")
    storage = az("storage", "account", "list", "-g", RESOURCE_GROUP, "--query", "[0].name", "-o", "tsv")
    if not workspace or not storage:
        raise SystemExit(f"No workspace/storage found in {RESOURCE_GROUP}; deploy first")
    return {"workspace": workspace, "storage_account": storage}


def connect(server: str, database: str) -> pyodbc.Connection:
    token = az("account", "get-access-token", "--resource", "https://database.windows.net/",
               "--query", "accessToken", "-o", "tsv")
    token_bytes = token.encode("utf-16-le")
    attrs = {SQL_COPT_SS_ACCESS_TOKEN: struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)}
    conn_str = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{server},1433;Database={database};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60;"
    )
    return pyodbc.connect(conn_str, attrs_before=attrs, autocommit=True)


def substitute(sql: str, variables: dict[str, str]) -> str:
    def repl(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in variables:
            raise SystemExit(f"SQL references $({name}) but no value was provided (--var {name}=...)")
        return variables[name]
    return VARIABLE.sub(repl, sql)


def print_results(cursor: pyodbc.Cursor, max_rows: int) -> None:
    while True:
        if cursor.description:
            columns = [c[0] for c in cursor.description]
            rows = cursor.fetchmany(max_rows + 1)
            widths = [max(len(str(c)), *(len(str(r[i])) for r in rows[:max_rows])) if rows else len(str(c))
                      for i, c in enumerate(columns)]
            widths = [min(w, 40) for w in widths]
            print("  " + " | ".join(str(c)[:40].ljust(w) for c, w in zip(columns, widths)))
            print("  " + "-+-".join("-" * w for w in widths))
            for row in rows[:max_rows]:
                print("  " + " | ".join(str(v)[:40].ljust(w) for v, w in zip(row, widths)))
            if len(rows) > max_rows:
                print(f"  ... (more than {max_rows} rows)")
        elif cursor.rowcount not in (-1, None):
            print(f"  ({cursor.rowcount} rows affected)")
        if not cursor.nextset():
            break


def run_batches(conn: pyodbc.Connection, label: str, sql: str, max_rows: int) -> None:
    batches = [b.strip() for b in GO_LINE.split(sql) if b.strip()]
    for number, batch in enumerate(batches, start=1):
        first_line = next((ln for ln in batch.splitlines() if ln.strip() and not ln.strip().startswith("--")), "")
        print(f"[{label} #{number}] {first_line.strip()[:100]}")
        started = time.perf_counter()
        cursor = conn.cursor()
        try:
            cursor.execute(batch)
            print_results(cursor, max_rows)
        except pyodbc.Error as exc:
            print(f"  ERROR: {exc}", file=sys.stderr)
            raise SystemExit(1) from exc
        finally:
            cursor.close()
        print(f"  ({time.perf_counter() - started:.1f}s)")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="*", type=Path)
    parser.add_argument("-q", "--query", help="run an inline query instead of files")
    parser.add_argument("-d", "--database", default="lab")
    parser.add_argument("--var", action="append", default=[], metavar="NAME=VALUE")
    parser.add_argument("--max-rows", type=int, default=25)
    args = parser.parse_args()
    if not args.files and not args.query:
        parser.error("give one or more .sql files or --query")

    variables = lab_settings()
    for item in args.var:
        name, _, value = item.partition("=")
        variables[name] = value
    server = f"{variables['workspace']}-ondemand.sql.azuresynapse.net"

    conn = connect(server, args.database)
    try:
        if args.query:
            run_batches(conn, "query", substitute(args.query, variables), args.max_rows)
        for path in args.files:
            run_batches(conn, path.name, substitute(path.read_text(encoding="utf-8"), variables), args.max_rows)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
