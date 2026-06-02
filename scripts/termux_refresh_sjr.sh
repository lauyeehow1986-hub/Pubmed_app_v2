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
# pipefail so `cmd | sed` reflects cmd's exit status, not sed's -- otherwise the
# push-retry loop below would treat every push as successful.
set -o pipefail

# ---- CONFIG: point this at your local clone -----------------------------------
REPO_DIR="${REPO_DIR:-$HOME/Pubmed_app_v2}"
# -------------------------------------------------------------------------------
#
# Optional alerting (all opt-in via environment variables; unset = disabled):
#   HEALTHCHECKS_URL   Dead-man's switch ping URL from healthchecks.io. We ping
#                      <URL>/start at the beginning, <URL> on success, and
#                      <URL>/fail on failure. If a monthly run never happens,
#                      healthchecks.io emails you that the check is late.
#   TELEGRAM_BOT_TOKEN Telegram bot token (from @BotFather).
#   TELEGRAM_CHAT_ID   Your chat id (from @userinfobot). Both must be set to
#                      receive success/failure messages with row counts.
# Put these in ~/.sjr_refresh.env and `source` it from your scheduler, or export
# them in ~/.bashrc.
HEALTHCHECKS_URL="${HEALTHCHECKS_URL:-}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Ping healthchecks.io (no-op if HEALTHCHECKS_URL unset). $1 = "" | "/start" | "/fail".
hc_ping() {
  [ -n "$HEALTHCHECKS_URL" ] || return 0
  curl -fsS -m 10 --retry 3 "${HEALTHCHECKS_URL}${1:-}" >/dev/null 2>&1 || true
}

# Send a Telegram message (no-op unless both token and chat id are set).
tg_send() {
  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || return 0
  curl -fsS -m 15 \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=$1" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    >/dev/null 2>&1 || true
}

# Called on any failure path: ping /fail and message, then exit non-zero.
fail_out() {
  log "ERROR: $1"
  hc_ping "/fail"
  tg_send "❌ SJR refresh FAILED: $1"
  exit 1
}

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

cd "$REPO_DIR" || { log "ERROR: REPO_DIR not found: $REPO_DIR"; hc_ping "/fail"; exit 1; }

# Signal the start of a run to healthchecks.io (measures run duration too).
hc_ping "/start"

# Pick a python interpreter.
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  fail_out "python not found. Run: pkg install python"
fi

log "Repo: $REPO_DIR"
log "Pulling latest..."
# Explicit fast-forward-only, never rebase (even if the user's git has
# pull.rebase=true), so a stray local edit can't trigger the "cannot pull with
# rebase" error. If the working tree has local edits to tracked files, the pull
# is blocked -- explain how to recover instead of failing cryptically.
if ! git pull --ff-only --no-rebase 2>&1 | sed 's/^/    /'; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    fail_out "git pull is blocked by local changes on this clone. This clone only generates and pushes data -- it should never have hand edits. Recover with: git -C '$REPO_DIR' stash  (or discard with: git -C '$REPO_DIR' checkout -- .), then re-run. Configure behaviour via ~/.sjr_refresh.env, not by editing tracked files."
  fi
  fail_out "git pull failed (network down, or history diverged). Check: git -C '$REPO_DIR' status"
fi

# Prefer parquet (smaller, typed) when pandas is available; fall back to the
# dependency-free gzipped CSV. app.R reads whichever one is committed.
OUT_PARQUET="data/sjr_all.parquet"
OUT_CSVGZ="data/sjr_all.csv.gz"

if "$PY" -c "import pandas, pyarrow" >/dev/null 2>&1; then
  OUT="$OUT_PARQUET"
  OTHER="$OUT_CSVGZ"
  log "pandas+pyarrow found -> building parquet"
else
  OUT="$OUT_CSVGZ"
  OTHER="$OUT_PARQUET"
  log "pandas/pyarrow not found -> building gzipped CSV (no extra deps)"
fi

log "Downloading SJR data (1999 -> current) via refresh_sjr.py ..."
if ! "$PY" scripts/refresh_sjr.py --out "$OUT"; then
  fail_out "refresh_sjr.py failed (no years downloaded? non-datacenter IP -- mobile data or normal Wi-Fi, no VPN?)"
fi

# If we switched formats, drop the other one from the repo so only one SJR
# file is tracked (app.R prefers parquet, then csv.gz).
if [ -f "$OTHER" ]; then
  git rm -q --ignore-unmatch "$OTHER" 2>/dev/null || rm -f "$OTHER"
fi

# Stage first, THEN check for a difference. `git diff` (unstaged) ignores
# untracked files, so a brand-new data file would wrongly look like "no
# change" on the first run. `git diff --cached` compares staged vs HEAD and
# correctly detects a new file and content changes.
git add "$OUT"
if git diff --cached --quiet; then
  log "No change in SJR data -- nothing to commit."
  hc_ping ""   # still a healthy run: signal success so the dead-man's switch is happy
  tg_send "ℹ️ SJR refresh ran: no change (SCImago data unchanged)."
  exit 0
fi

# Row count for the success message (best-effort).
ROWS="$("$PY" - "$OUT" <<'PYEOF' 2>/dev/null || true
import sys
p = sys.argv[1]
try:
    if p.endswith(".parquet"):
        import pandas as pd
        print(f"{len(pd.read_parquet(p)):,}")
    else:
        import gzip
        with gzip.open(p, "rt") as f:
            print(f"{sum(1 for _ in f) - 1:,}")
except Exception:
    print("?")
PYEOF
)"

log "Committing and pushing updated $OUT ..."
git commit -m "data: refresh SJR from scimagojr.com ($(date +%Y-%m-%d))" \
  2>&1 | sed 's/^/    /'

# Retry push a few times in case the phone connection blips.
for attempt in 1 2 3 4; do
  if git push 2>&1 | sed 's/^/    /'; then
    log "Pushed. Posit Connect Cloud will redeploy from the new commit."
    hc_ping ""
    tg_send "✅ SJR refresh pushed: ${OUT##*/} updated (${ROWS:-?} rows). Connect Cloud will redeploy."
    exit 0
  fi
  log "push failed (attempt $attempt) -- retrying in $((attempt*3))s"
  sleep $((attempt*3))
done

fail_out "could not push after retries. Re-run later or push by hand."
