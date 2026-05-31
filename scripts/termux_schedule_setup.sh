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

REPO_DIR="${REPO_DIR:-$HOME/Pubmed_app_v2}"
JOB_ID="${JOB_ID:-1001}"
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
  --network unmetered \
  --script "$RUNNER"

echo "Registered daily job #$JOB_ID -> $RUNNER"
echo "It will refresh SJR only on the 1st of each month (see ONLY_ON_DAY)."
echo "Tip: --network unmetered runs only on Wi-Fi; change to 'any' for mobile data."
