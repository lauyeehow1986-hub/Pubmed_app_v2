#!/usr/bin/env python3
"""
Download SCImago Journal Rank (SJR) data for every year (1999 -> current) from
scimagojr.com and write a single combined, gzipped CSV at data/sjr_all.csv.gz.

Why Python + Termux (and not GitHub Actions):
  scimagojr.com returns HTTP 403 to datacenter / CI IPs, so a GitHub Actions
  runner cannot download it. A normal mobile / Wi-Fi IP is not blocked. This
  script uses ONLY the Python standard library, so it runs on a phone in
  Termux with no pip installs (no pandas / pyarrow needed).

Why CSV.gz (and not parquet):
  Writing parquet needs heavy native deps that don't install cleanly on
  Termux. DuckDB inside the Shiny app reads gzipped CSV natively, so app.R
  treats this file exactly as it treated the old parquet.

Output schema (snake_case, matches what app.R's DuckDB query expects):
  year, rank, sourceid, title, type, issn, sjr, sjr_best_quartile, h_index,
  total_docs, total_docs_3years, total_refs, total_cites_3years,
  citable_docs_3years, cites_doc_2years, ref_doc, country, region, publisher,
  coverage, categories, areas   (extra columns from newer years are kept too)

The 8 columns the app strictly relies on are:
  year, rank, sjr, sjr_best_quartile, h_index, cites_doc_2years, title, issn

Usage:
  python3 scripts/refresh_sjr.py                 # 1999 -> current year
  python3 scripts/refresh_sjr.py --start 2015    # narrower range (testing)
  python3 scripts/refresh_sjr.py --out data/sjr_all.csv.gz
"""

import argparse
import csv
import datetime
import gzip
import hashlib
import io
import os
import re
import sys
import time
import urllib.error
import urllib.request

FIRST_YEAR = 1999
USER_AGENT = (
    "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Mobile Safari/537.36"
)

# Canonical snake_case names for the SCImago export headers. We match on a
# normalized form of each header so year-specific / punctuation differences
# don't matter. Anything not listed is still kept, with a best-effort
# snake_case name.
HEADER_MAP = {
    "rank": "rank",
    "sourceid": "sourceid",
    "title": "title",
    "type": "type",
    "issn": "issn",
    "sjr": "sjr",
    "sjrbestquartile": "sjr_best_quartile",
    "hindex": "h_index",
    "totaldocs": "total_docs",            # "Total Docs. (2023)" -> total_docs
    "totaldocs3years": "total_docs_3years",
    "totalrefs": "total_refs",
    "totalcites3years": "total_cites_3years",
    "totalcitations3years": "total_cites_3years",
    "citabledocs3years": "citable_docs_3years",
    "citesdoc2years": "cites_doc_2years",
    "refdoc": "ref_doc",
    "female": "female_pct",
    "overton": "overton",
    "sdg": "sdg",
    "country": "country",
    "region": "region",
    "publisher": "publisher",
    "coverage": "coverage",
    "categories": "categories",
    "areas": "areas",
    "openaccess": "open_access",
}

# Columns the Shiny app strictly needs present in the output.
REQUIRED = [
    "year", "rank", "sjr", "sjr_best_quartile",
    "h_index", "cites_doc_2years", "title", "issn",
]

# Target dtypes for the parquet writer. Anything not listed stays string.
# DuckDB / app.R needs the numeric SJR fields typed (it divides ranks, etc.),
# and `issn` MUST stay a string so leading zeros survive.
INT_COLS = ["year", "rank", "h_index", "sourceid",
            "total_docs", "total_docs_3years", "total_refs",
            "total_cites_3years", "citations_doc_3years",
            "citable_docs_3years"]
FLOAT_COLS = ["sjr", "cites_doc_2years", "ref_doc"]
STR_COLS = ["issn", "title", "type", "sjr_best_quartile", "country",
            "region", "publisher", "coverage", "categories", "areas",
            "open_access", "open_access_diamond"]


def normalize_header(h):
    """Lowercase, strip a trailing year, drop all non-alphanumerics."""
    h = h.strip().lower()
    h = re.sub(r"\(?\b(19|20)\d{2}\b\)?", "", h)  # drop a year like (2023)
    h = re.sub(r"[^a-z0-9]+", "", h)               # drop spaces/dots/%/parens
    return h


def clean_name(canonical_norm, original):
    if canonical_norm in HEADER_MAP:
        return HEADER_MAP[canonical_norm]
    # Fallback: snake_case the original header.
    s = original.strip().lower()
    s = re.sub(r"\(?\b(19|20)\d{2}\b\)?", "", s)
    s = re.sub(r"[^a-z0-9]+", "_", s).strip("_")
    return s or "col"


def fetch_year(year, attempts=4, pause=2.0):
    url = f"https://www.scimagojr.com/journalrank.php?year={year}&out=xls"
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "text/csv,application/vnd.ms-excel,*/*",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": "https://www.scimagojr.com/journalrank.php",
        },
    )
    last = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=180) as resp:
                raw = resp.read()
            if len(raw) < 1000:
                last = f"too small ({len(raw)} bytes)"
            else:
                # SCImago exports latin-1-ish; decode leniently.
                return raw.decode("utf-8", errors="replace")
        except urllib.error.HTTPError as e:
            last = f"HTTP {e.code}"
        except Exception as e:  # noqa: BLE001
            last = str(e)
        if attempt < attempts:
            time.sleep(pause * attempt)  # 2s, 4s, 6s ...
    print(f"  [{year}] FAILED: {last}", file=sys.stderr)
    return None


def parse_year(text, year):
    """Parse the semicolon-delimited export into list-of-dicts (snake_case)."""
    reader = csv.reader(io.StringIO(text), delimiter=";")
    rows = list(reader)
    if not rows:
        return [], []
    header = rows[0]
    names = [clean_name(normalize_header(h), h) for h in header]

    out = []
    for r in rows[1:]:
        if not any(cell.strip() for cell in r):
            continue
        rec = {}
        for i, name in enumerate(names):
            val = r[i].strip() if i < len(r) else ""
            rec[name] = val
        # Normalize the numeric-ish fields the app uses.
        if "sjr" in rec:
            rec["sjr"] = rec["sjr"].replace(",", ".")  # EU decimal -> dot
        if "cites_doc_2years" in rec:
            rec["cites_doc_2years"] = rec["cites_doc_2years"].replace(",", ".")
        # ISSNs come as e.g. "15424863, 00079235" (no hyphens) -- keep as-is;
        # the app splits on comma and strips hyphens itself.
        rec["year"] = str(year)
        out.append(rec)
    return names, out


def write_csv_gz(rows, ordered, out):
    """Write a gzipped CSV with the Python standard library (no deps)."""
    with gzip.open(out, "wt", newline="", encoding="utf-8") as gz:
        writer = csv.DictWriter(gz, fieldnames=ordered, extrasaction="ignore")
        writer.writeheader()
        for rec in rows:
            writer.writerow({k: rec.get(k, "") for k in ordered})


def write_parquet(rows, ordered, out):
    """Write a typed parquet via pandas. Needs pandas + pyarrow/fastparquet.

    Numeric columns are cast (nullable Int64 / float64) and ISSN stays string,
    so DuckDB reads correct types and leading-zero ISSNs survive. Falls back
    with a clear message if the parquet engine isn't installed.
    """
    try:
        import pandas as pd
    except ImportError as e:  # pragma: no cover
        raise SystemExit(
            "ERROR: --out is .parquet but pandas is not installed.\n"
            "  Install it (Termux):  pip install pandas pyarrow\n"
            "  Or output CSV.gz instead:  --out data/sjr_all.csv.gz\n"
            f"  ({e})"
        )

    df = pd.DataFrame([{k: r.get(k, "") for k in ordered} for r in rows],
                      columns=ordered)

    # Empty strings -> NA before numeric casting.
    df = df.replace({"": pd.NA})

    for col in INT_COLS:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").astype("Int64")
    for col in FLOAT_COLS:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce").astype("float64")
    for col in STR_COLS:
        if col in df.columns:
            df[col] = df[col].astype("string")

    try:
        df.to_parquet(out, index=False, compression="zstd")
    except Exception:  # pyarrow missing zstd, or fastparquet -> fall back
        df.to_parquet(out, index=False)


def main():
    ap = argparse.ArgumentParser(
        description="Build the combined SJR data file (parquet or csv.gz)")
    ap.add_argument("--start", type=int, default=FIRST_YEAR)
    ap.add_argument("--end", type=int,
                    default=datetime.date.today().year)
    ap.add_argument(
        "--out", default="data/sjr_all.parquet",
        help="output path; .parquet uses pandas (smaller, typed), "
             ".csv.gz uses the stdlib (no deps). Default: data/sjr_all.parquet")
    ap.add_argument("--pause", type=float, default=1.0,
                    help="seconds between years (politeness)")
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)

    all_rows = []
    all_cols = []  # preserve first-seen column order
    ok_years = []
    seen_payloads = {}  # sha1(raw body) -> the year we first accepted it under
    for year in range(args.start, args.end + 1):
        print(f"Downloading SJR {year} ...", flush=True)
        text = fetch_year(year)
        if text is None:
            continue

        # SCImago does NOT 404 a year it hasn't published yet -- it silently
        # returns the latest available year's data (e.g. asking for 2026 before
        # it exists yields 2025's rows). Detect that by hashing the raw payload:
        # if this year's body is byte-identical to one we've already accepted,
        # it's a phantom duplicate -- skip it so we don't store the same data
        # under two different years (and don't inflate max year).
        digest = hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()
        if digest in seen_payloads:
            print(f"  [{year}] SKIPPED -- identical to {seen_payloads[digest]} "
                  f"(SCImago has not published {year} yet)")
            continue

        names, rows = parse_year(text, year)
        if not rows:
            print(f"  [{year}] no rows parsed", file=sys.stderr)
            continue
        seen_payloads[digest] = year
        for n in (["year"] + names):
            if n not in all_cols:
                all_cols.append(n)
        all_rows.extend(rows)
        ok_years.append(year)
        print(f"  [{year}] OK ({len(rows)} journals)")
        time.sleep(args.pause)

    if not all_rows:
        print("ERROR: no SJR years could be downloaded. "
              "Are you on a non-datacenter IP (mobile/Wi-Fi, no VPN)?",
              file=sys.stderr)
        sys.exit(1)

    # Ensure required columns exist (older years may lack some extras).
    for col in REQUIRED:
        if col not in all_cols:
            all_cols.append(col)

    # Put the important columns first for readability.
    front = [c for c in REQUIRED if c in all_cols]
    rest = [c for c in all_cols if c not in front]
    ordered = front + rest

    if args.out.lower().endswith(".parquet"):
        write_parquet(all_rows, ordered, args.out)
    else:
        write_csv_gz(all_rows, ordered, args.out)

    size = os.path.getsize(args.out)
    print("=" * 50)
    print(f"Wrote {args.out}")
    print(f"  Years:   {min(ok_years)} - {max(ok_years)} "
          f"({len(ok_years)} of {args.end - args.start + 1} requested)")
    print(f"  Rows:    {len(all_rows):,}")
    print(f"  Columns: {', '.join(ordered)}")
    print(f"  Size:    {size:,} bytes")
    print("=" * 50)


if __name__ == "__main__":
    main()
