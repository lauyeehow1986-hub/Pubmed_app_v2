#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Job-scheduler entry point: hold a wake lock, run the refresh, log output.
# =============================================================================
# This is the --script that termux_schedule_setup.sh registers. Keep it tiny
# and robust; all real logic (date guard, download, commit, push) lives in
# termux_refresh_sjr.sh.

REPO_DIR="${REPO_DIR:-$HOME/Pubmed_app_v2}"
LOG="$HOME/sjr_refresh.log"

# Load optional alerting secrets (healthchecks/Telegram) if present. Kept
# outside the repo so tokens are never committed. See sjr_refresh.env.example.
if [ -f "$HOME/.sjr_refresh.env" ]; then
  set -a; . "$HOME/.sjr_refresh.env"; set +a
fi

# Keep the CPU awake for the duration (best-effort; needs termux-api).
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock

{
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') job fired ====="
  bash "$REPO_DIR/scripts/termux_refresh_sjr.sh"
  echo "===== exit $? ====="
} >> "$LOG" 2>&1

command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock
