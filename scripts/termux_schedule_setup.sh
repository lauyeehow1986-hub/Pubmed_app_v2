#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
# Register the monthly SJR refresh with Android's job scheduler (Termux)
# =============================================================================
#
# Android kills plain cron when the phone sleeps (Doze), so we use the OS-level
# termux-job-scheduler instead. It fires on an INTERVAL (not a calendar date),
# so we register a DAILY job; termux_refresh_sjr.sh then only acts on the 1st
# (see ONLY_ON_DAY in that script). Net effect: it refreshes ~noon on the 1st
# of each month, surviving reboots and sleep.
#
# One-time setup:
#   pkg install -y termux-api          # provides termux-job-scheduler
#   # install the "Termux:Boot" app from F-Droid, open it once, then:
#   mkdir -p ~/.termux/boot
#   cp scripts/termux_schedule_setup.sh ~/.termux/boot/  # re-registers on reboot
#   bash scripts/termux_schedule_setup.sh                 # register now
#
# Check it:    termux-job-scheduler --pending
# Cancel it:   termux-job-scheduler --cancel --job-id 1001
# =============================================================================

set -u

# Load optional overrides (JOB_NETWORK, JOB_ID, REPO_DIR) from the same env file
# used for alerting secrets, so you never have to edit this tracked script --
# editing tracked files breaks `git pull` on the refresh clone.
if [ -f "$HOME/.sjr_refresh.env" ]; then
  set -a; . "$HOME/.sjr_refresh.env"; set +a
fi

REPO_DIR="${REPO_DIR:-$HOME/Pubmed_app_v2}"
JOB_ID="${JOB_ID:-1001}"
# Which connections the job may run on: 'unmetered' = Wi-Fi only (default),
# 'any' = Wi-Fi or mobile data, 'cellular' = mobile data only. Override by
# setting JOB_NETWORK in ~/.sjr_refresh.env.
JOB_NETWORK="${JOB_NETWORK:-unmetered}"
RUNNER="$REPO_DIR/scripts/termux_run_refresh.sh"

if ! command -v termux-job-scheduler >/dev/null 2>&1; then
  echo "ERROR: termux-job-scheduler not found. Run: pkg install termux-api" >&2
  exit 1
fi

# period-ms = 24h. Android enforces a minimum (~15 min) and may batch jobs to
# save battery, so it can fire a bit after exactly 24h -- that's fine, the
# day-of-month guard keeps it to the 1st.
termux-job-scheduler \
  --job-id "$JOB_ID" \
  --period-ms 86400000 \
  --persisted true \
  --network "$JOB_NETWORK" \
  --script "$RUNNER"

echo "Registered daily job #$JOB_ID -> $RUNNER (network: $JOB_NETWORK)"
echo "It will refresh SJR only on the 1st of each month (see ONLY_ON_DAY)."
echo "Tip: network '$JOB_NETWORK' -- set JOB_NETWORK=any in ~/.sjr_refresh.env for mobile data."
