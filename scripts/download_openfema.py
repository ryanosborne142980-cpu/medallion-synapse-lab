"""Download OpenFEMA datasets as Parquet pages into a local landing folder.

Layout mirrors the lake so the folder can be uploaded as-is:
    data/landing/<dataset>/ingest_date=YYYY-MM-DD/part-00000.parquet

The bulk NfipClaimsV3.parquet file returns 403 to scripted clients, so this pages
the public API ($top/$skip, ordered by id for stable paging) with $format=parquet.

Each run is a full snapshot. OpenFEMA's NfipClaims v3 has no per-record change
timestamp (asOfDate is one value for the whole snapshot), so incremental handling
happens downstream: silver keeps the latest ingest_date per id.
"""

from __future__ import annotations

import argparse
import datetime as dt
import http.client
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

DATASETS = {
    "nfip_claims": "https://www.fema.gov/api/open/v3/NfipClaims",
    "disaster_declarations": "https://www.fema.gov/api/open/v2/DisasterDeclarationsSummaries",
}
USER_AGENT = "medallion-synapse-lab/0.1"
PARQUET_MAGIC = b"PAR1"


def fetch(url: str, retries: int = 5) -> bytes:
    """GET with exponential backoff on transient failures."""
    for attempt in range(1, retries + 1):
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except (urllib.error.URLError, http.client.HTTPException, ConnectionError, TimeoutError) as exc:
            status = getattr(exc, "code", None)
            if status is not None and 400 <= status < 500 and status != 429:
                raise
            if attempt == retries:
                raise
            wait = 2**attempt
            print(f"  retry {attempt}/{retries} in {wait}s ({exc})", file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError("unreachable")


def query_url(base: str, **params: str | int) -> str:
    encoded = urllib.parse.urlencode({f"${k}": v for k, v in params.items()}, safe="',")
    return f"{base}?{encoded}"


def record_count(base: str, filter_expr: str | None) -> int:
    params: dict[str, str | int] = {"top": 1, "select": "id", "inlinecount": "allpages"}
    if filter_expr:
        params["filter"] = filter_expr
    payload = json.loads(fetch(query_url(base, **params)))
    return int(payload["metadata"]["count"])


def is_complete_parquet(body: bytes) -> bool:
    """A complete Parquet file starts and ends with the magic bytes."""
    return body.startswith(PARQUET_MAGIC) and body.endswith(PARQUET_MAGIC)


def page_url(base: str, skip: int, top: int, fmt: str, filter_expr: str | None) -> str:
    params: dict[str, str | int] = {"top": top, "skip": skip, "orderby": "id", "format": fmt}
    if filter_expr:
        params["filter"] = filter_expr
    return query_url(base, **params)


def try_parquet(base: str, skip: int, top: int, filter_expr: str | None, retries: int) -> bytes | None:
    """Return a complete Parquet body, or None if the server truncates it."""
    try:
        body = fetch(page_url(base, skip, top, "parquet", filter_expr), retries)
    except urllib.error.HTTPError as exc:
        if 400 <= exc.code < 500 and exc.code != 429:
            raise
        return None
    except (urllib.error.URLError, http.client.HTTPException, ConnectionError, TimeoutError):
        return None
    return body if is_complete_parquet(body) else None


def fetch_range(base: str, skip: int, top: int, filter_expr: str | None, retries: int,
                rejected: list[dict]) -> list[tuple[int, bytes]]:
    """Fetch rows [skip, skip+top) as Parquet segments.

    OpenFEMA's Parquet export truncates the response when a page contains certain
    records (seen at NfipClaims offset 146033 in Nov 2026). When that happens, split
    the range by 10 until the failing record is isolated, then capture that single
    record as JSONL so it is kept and reported rather than silently dropped.
    """
    body = try_parquet(base, skip, top, filter_expr, retries)
    if body is not None:
        return [(skip, body)]
    if top == 1:
        line = fetch(page_url(base, skip, 1, "jsonl", filter_expr)).decode("utf-8").strip()
        record_id = json.loads(line).get("id") if line else None
        rejected.append({"offset": skip, "id": record_id, "jsonl": line,
                         "reason": "server Parquet export truncated; captured as JSONL"})
        print(f"    rejected offset {skip} (id {record_id}): Parquet export fails for this record")
        return []
    step = max(1, top // 10)
    segments: list[tuple[int, bytes]] = []
    for sub in range(skip, skip + top, step):
        segments += fetch_range(base, sub, min(step, skip + top - sub), filter_expr, 2, rejected)
    return segments


def download(dataset: str, out_root: Path, ingest_date: str, page_size: int,
             filter_expr: str | None) -> Path:
    base = DATASETS[dataset]
    target = out_root / "landing" / dataset / f"ingest_date={ingest_date}"
    if (target / "_manifest.json").exists():
        raise SystemExit(f"{target} is already complete; delete it or pick another --ingest-date")
    # No manifest means an interrupted run: finished pages are kept and skipped below.
    target.mkdir(parents=True, exist_ok=True)
    rejected_dir = target / "_rejected"

    total = record_count(base, filter_expr)
    pages = (total + page_size - 1) // page_size
    print(f"{dataset}: {total:,} records in {pages} pages -> {target}")

    started = dt.datetime.now(dt.timezone.utc)
    for page in range(pages):
        part = target / f"part-{page:05d}.parquet"
        split_marker = target / f"_split-{page:05d}.json"
        if split_marker.exists() or (part.exists() and is_complete_parquet(part.read_bytes())):
            print(f"  page {page + 1}/{pages}  already downloaded, skipping")
            continue

        rejected: list[dict] = []
        segments = fetch_range(base, page * page_size, page_size, filter_expr, 5, rejected)
        if len(segments) == 1 and not rejected:
            part.write_bytes(segments[0][1])
            print(f"  page {page + 1}/{pages}  {len(segments[0][1]) / 1_048_576:.1f} MB")
            continue

        # Split page: write each segment, then the rejected records, then the marker last
        # so an interrupted split is retried in full on the next run.
        for seg_skip, body in segments:
            (target / f"part-{page:05d}-{seg_skip:09d}.parquet").write_bytes(body)
        if rejected:
            rejected_dir.mkdir(exist_ok=True)
            for item in rejected:
                (rejected_dir / f"offset-{item['offset']:09d}.jsonl").write_text(item["jsonl"] + "\n")
        split_marker.write_text(json.dumps(
            {"page": page, "segments": [s for s, _ in segments],
             "rejected": [{k: v for k, v in r.items() if k != "jsonl"} for r in rejected]}, indent=2))
        print(f"  page {page + 1}/{pages}  split into {len(segments)} segments, {len(rejected)} rejected")

    rejected_all = [r for marker in sorted(target.glob("_split-*.json"))
                    for r in json.loads(marker.read_text())["rejected"]]
    total_bytes = sum(p.stat().st_size for p in target.glob("*.parquet"))
    manifest = {
        "dataset": dataset,
        "source": base,
        "filter": filter_expr,
        "record_count": total,
        "rejected_count": len(rejected_all),
        "rejected": rejected_all,
        "pages": pages,
        "page_size": page_size,
        "bytes": total_bytes,
        "ingest_date": ingest_date,
        "started_utc": started.isoformat(),
        "finished_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
    }
    # Underscore prefix: serverless SQL wildcards like *.parquet won't pick it up.
    (target / "_manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"  done: {total_bytes / 1_048_576:.1f} MB")
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("datasets", nargs="*", metavar="dataset",
                        help=f"datasets to download: {', '.join(DATASETS)} (default: all)")
    parser.add_argument("--out", type=Path, default=Path("data"), help="local root folder")
    parser.add_argument("--ingest-date", default=dt.date.today().isoformat(),
                        help="snapshot date used in the folder name (YYYY-MM-DD)")
    parser.add_argument("--page-size", type=int, default=10_000, help="rows per API page (max 10000)")
    parser.add_argument("--filter", dest="filter_expr",
                        help="OData filter, e.g. \"yearOfLoss ge 2015\" for a smaller sample")
    args = parser.parse_args()

    unknown = set(args.datasets) - set(DATASETS)
    if unknown:
        parser.error(f"unknown dataset(s): {', '.join(sorted(unknown))}")
    dt.date.fromisoformat(args.ingest_date)  # validate format early
    for dataset in args.datasets or DATASETS:
        download(dataset, args.out, args.ingest_date, args.page_size, args.filter_expr)


if __name__ == "__main__":
    main()
