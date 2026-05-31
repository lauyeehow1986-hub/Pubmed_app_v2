#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Termux SJR refresh -- runs on your phone, commits data/sjr_all.csv.gz
# =============================================================================
#
# Why this exists: scimagojr.com blocks datacenter/CI IPs (HTTP 403), but your
# phone's mobile/Wi-Fi IP is NOT blocked. So we download on-device here and push
# the result to GitHub; Posit Connect Cloud then redeploys from the new commit.
#
# This script:
#   1. cd into the repo and git pull (fast-forward)
#   2. run scripts/refresh_sjr.py (Python standard library only -- no pip,
#      no R) which downloads every year 1999..current and writes
#      data/sjr_all.csv.gz
#   3. commit & push only if the data file changed
#
# One-time Termux setup:
#   pkg update && pkg upgrade -y
#   pkg install -y python git
#   git clone https://github.com/lauyeehow1986-hub/Pubmed_app_v2.git
#   cd Pubmed_app_v2
#   git config credential.helper store   # caches your GitHub token on first push
#
# Then run:  bash scripts/termux_refresh_sjr.sh
# (Make sure you are on mobile data / normal Wi-Fi, NOT a VPN.)
# =============================================================================

set -u

# ---- CONFIG: point this at your local clone -----------------------------------
REPO_DIR="${REPO_DIR:-$HOME/Pubmed_app_v2}"
# -------------------------------------------------------------------------------

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Android schedulers (termux-job-scheduler) fire on intervals, not calendar
# dates, and may wake late. So schedule this DAILY and let the script act only
# on the 1st of the month. Override with: ONLY_ON_DAY=0 (run every time) or
# ONLY_ON_DAY=15 (some other day). Manual runs: ONLY_ON_DAY=0 bash <script>.
ONLY_ON_DAY="${ONLY_ON_DAY:-1}"
TODAY_DOM="$(date +%-d)"
if [ "$ONLY_ON_DAY" != "0" ] && [ "$TODAY_DOM" != "$ONLY_ON_DAY" ]; then
  log "Today is day $TODAY_DOM; refresh only runs on day $ONLY_ON_DAY. Skipping."
  exit 0
fi

cd "$REPO_DIR" || { log "ERROR: REPO_DIR not found: $REPO_DIR"; exit 1; }

# Pick a python interpreter.
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  log "ERROR: python not found. Run: pkg install python"
  exit 1
fi

log "Repo: $REPO_DIR"
log "Pulling latest..."
git pull --ff-only 2>&1 | sed 's/^/    /'

log "Downloading SJR data (1999 -> current) via refresh_sjr.py ..."
if ! "$PY" scripts/refresh_sjr.py --out data/sjr_all.csv.gz; then
  log "ERROR: refresh_sjr.py failed (no years downloaded?). Are you on a"
  log "       non-datacenter IP -- mobile data or normal Wi-Fi, no VPN?"
  exit 1
fi

if git diff --quiet -- data/sjr_all.csv.gz; then
  log "No change in data/sjr_all.csv.gz -- nothing to commit."
  exit 0
fi

log "Committing and pushing updated data/sjr_all.csv.gz ..."
git add data/sjr_all.csv.gz
git commit -m "data: refresh SJR from scimagojr.com ($(date +%Y-%m-%d))" \
  2>&1 | sed 's/^/    /'

# Retry push a few times in case the phone connection blips.
for attempt in 1 2 3 4; do
  if git push 2>&1 | sed 's/^/    /'; then
    log "Pushed. Posit Connect Cloud will redeploy from the new commit."
    exit 0
  fi
  log "push failed (attempt $attempt) -- retrying in $((attempt*3))s"
  sleep $((attempt*3))
done

log "ERROR: could not push after retries. Re-run later or push by hand."
exit 1
