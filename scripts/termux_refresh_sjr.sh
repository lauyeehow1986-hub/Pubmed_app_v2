#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Termux SJR refresh — runs on your phone, commits data/sjr_all.parquet
# =============================================================================
#
# Why this exists: scimagojr.com blocks datacenter/CI IPs (HTTP 403), but your
# phone's mobile/Wi-Fi IP is NOT blocked. So we download on-device here and push
# the resulting parquet to GitHub; Posit Connect Cloud then redeploys from it.
#
# This script:
#   1. cd into the repo
#   2. git pull (fast-forward)
#   3. download every year 1999..current from scimagojr.com with the system curl
#      (browser User-Agent) into a temp folder
#   4. run scripts/build_sjr_from_csvs.R to combine them into data/sjr_all.parquet
#   5. commit & push only if the parquet changed
#
# Configure REPO_DIR below, then either run it by hand or schedule it with
# termux-job-scheduler / cron (see README).
# =============================================================================

set -u

# ---- CONFIG: point this at your local clone -----------------------------------
REPO_DIR="$HOME/Pubmed_app_v2"
# -------------------------------------------------------------------------------

UA='Mozilla/5.0 (Linux; Android 14; Pixel) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36'
FIRST_YEAR=1999
CURRENT_YEAR="$(date +%Y)"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

cd "$REPO_DIR" || { log "ERROR: REPO_DIR not found: $REPO_DIR"; exit 1; }

log "Repo: $REPO_DIR"
log "Pulling latest..."
git pull --ff-only 2>&1 | sed 's/^/    /'

RAW_DIR="$(mktemp -d)"
trap 'rm -rf "$RAW_DIR"' EXIT

ok_years=0
for year in $(seq "$FIRST_YEAR" "$CURRENT_YEAR"); do
  url="https://www.scimagojr.com/journalrank.php?year=${year}&out=xls"
  out="$RAW_DIR/sjr_${year}.csv"
  printf '    %s ... ' "$year"

  http=$(curl -sS -L \
    -A "$UA" \
    -H 'Accept: text/csv,application/vnd.ms-excel,*/*' \
    -H 'Accept-Language: en-US,en;q=0.9' \
    -H 'Referer: https://www.scimagojr.com/journalrank.php' \
    --max-time 180 --retry 3 --retry-delay 2 \
    -o "$out" -w '%{http_code}' \
    "$url" 2>/dev/null)

  sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
  if [ "$http" = "200" ] && [ "$sz" -gt 1000 ]; then
    echo "OK ($sz bytes)"
    ok_years=$((ok_years + 1))
  else
    echo "FAILED (HTTP $http, $sz bytes)"
    rm -f "$out"
  fi
  sleep 1
done

if [ "$ok_years" -eq 0 ]; then
  log "ERROR: no years downloaded (are you on mobile data / off a blocked network?). Aborting."
  exit 1
fi
log "Downloaded $ok_years year files. Building parquet..."

# Build the combined parquet from the CSVs we just fetched.
Rscript scripts/build_sjr_from_csvs.R "$RAW_DIR" || {
  log "ERROR: parquet build failed."
  exit 1
}

# Commit & push only if the parquet actually changed.
if git diff --quiet -- data/sjr_all.parquet; then
  log "No change in data/sjr_all.parquet — nothing to commit."
  exit 0
fi

git add data/sjr_all.parquet
git commit -m "chore(data): refresh SJR parquet from scimagojr.com (Termux)" 2>&1 | sed 's/^/    /'
log "Pushing..."
git push 2>&1 | sed 's/^/    /'
log "Done."
