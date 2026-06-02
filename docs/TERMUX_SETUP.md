# Termux SJR refresh — full setup guide

This is the complete, step-by-step guide for running the monthly **SCImago Journal Rank (SJR)**
data refresh on an Android phone with [Termux](https://termux.dev), including the optional
**Healthchecks.io** dead-man's switch and **Telegram** status alerts.

For the *why* (scimagojr.com blocks datacenter/CI IPs, so the download runs on a phone) and the
overall architecture, see the main [README](../README.md). This document is the hands-on runbook.

> **Install Termux from [F-Droid](https://f-droid.org/packages/com.termux/)**, not the Play
> Store — the Play Store build is outdated and the package manager misbehaves.

---

## Phase 1 — One-time base setup

```bash
pkg update && pkg upgrade -y
pkg install -y python git curl

# Optional but recommended: smaller, typed parquet output.
# If these won't install on your device, skip them -- the downloader falls back
# to a gzipped CSV using only the Python standard library.
pip install pandas pyarrow
```

Clone the repo (use the branch Posit Connect Cloud deploys from — normally `main`):

```bash
cd ~
git clone https://github.com/lauyeehow1986-hub/Pubmed_app_v2.git
cd Pubmed_app_v2
git config user.name  "Your Name"
git config user.email "lauyeehow1986@gmail.com"
git config credential.helper store   # caches your token after the first push
```

**GitHub authentication.** Pushes from a scheduled job can't stop to ask for a password, so the
first manual push caches a token:

1. GitHub → **Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate**.
2. Repository access: only `Pubmed_app_v2`. Permissions: **Contents → Read and write**.
3. The first `git push` prompts once: username = your GitHub login, password = **paste the token**.
   `credential.helper store` writes it to `~/.git-credentials`; every later push is non-interactive.

> ⚠️ **Never edit tracked files in this clone.** It only generates and pushes data. A hand edit
> to a tracked file makes `git pull` fail ("cannot pull with rebase / unstaged changes"). All
> behaviour is configured through `~/.sjr_refresh.env` (below) instead. See
> [Troubleshooting](#troubleshooting) if you hit this.

---

## Phase 2 — Healthchecks.io (dead-man's switch)

This emails you if a monthly run ever *fails to happen* (phone off, no signal, job didn't fire).

1. Sign up free at **<https://healthchecks.io>**.
2. **Add Check**, name it e.g. `SJR monthly refresh`.
3. Set the schedule so it expects one ping per month, on the 1st:
   - Schedule type: **Cron**
   - Expression: `0 12 1 * *` (noon, 1st of the month)
   - Grace time: **2–3 days** (Android may fire the job a little late)
   - Timezone: your local zone (e.g. `Asia/Singapore`)
4. Copy the check's **ping URL** — looks like `https://hc-ping.com/<uuid>`. That's your
   `HEALTHCHECKS_URL`.

The script pings `<URL>/start` when it begins, `<URL>` on success (including "no change"), and
`<URL>/fail` on failure — so you learn both *that it ran* and *whether it worked*.

---

## Phase 3 — Telegram bot (status messages)

This sends you a ✅ / ℹ️ / ❌ message after each run.

1. In Telegram, open a chat with **@BotFather** → send `/newbot` → follow prompts (name +
   username ending in `bot`). It returns a **token** like `123456789:ABCdef...` →
   that's your `TELEGRAM_BOT_TOKEN`.
2. Get your numeric chat id: open a chat with **@userinfobot** and send `/start`. It replies
   with your **Id** → that's your `TELEGRAM_CHAT_ID`.
3. Open a chat with **your new bot** and send it `/start` (or any message).

> **Your bot will never reply to you — that's normal.** A bot only "responds" if a program is
> running to answer it; yours has none. Its only job here is to let the *script* send messages
> to you. But Telegram blocks bots from messaging people who've never opened a chat with them,
> so sending your bot `/start` once is required even though you get no reply.

**Verify the send path directly** (the real test — don't judge by whether the bot replies):

```bash
curl -s "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/sendMessage" \
  --data-urlencode "chat_id=<YOUR_CHAT_ID>" \
  --data-urlencode "text=test from termux"
```

- ✅ You get a Telegram notification + terminal shows `{"ok":true,...}` → working.
- ❌ `"ok":false` with `"chat not found"` → wrong chat id, or you haven't sent your bot `/start`.
- ❌ `"ok":false` with `"Unauthorized"` → wrong/incomplete token (it has two parts joined by a
  colon: `123456789:ABCdef...` — make sure you copied both).

---

## Phase 4 — Put your settings in `~/.sjr_refresh.env`

This file lives **outside** the repo so secrets are never committed. Both the refresh script and
the scheduler load it automatically.

```bash
cd ~/Pubmed_app_v2
cp scripts/sjr_refresh.env.example ~/.sjr_refresh.env
nano ~/.sjr_refresh.env
chmod 600 ~/.sjr_refresh.env
```

Fill in the values you want (uncomment the lines):

```bash
# Dead-man's switch
HEALTHCHECKS_URL=https://hc-ping.com/your-uuid-here

# Telegram status messages
TELEGRAM_BOT_TOKEN=123456789:ABCdefGhIJKlmNoPQRstuVWxyz
TELEGRAM_CHAT_ID=123456789

# Scheduler network: unmetered = Wi-Fi only (default), any = Wi-Fi or mobile data,
# cellular = mobile data only
JOB_NETWORK=any
```

Everything here is **opt-in** — leave a line commented/unset to disable that feature.

---

## Phase 5 — Test it now (don't wait for the 1st)

```bash
cd ~/Pubmed_app_v2
set -a; . ~/.sjr_refresh.env; set +a      # load settings into this shell
ONLY_ON_DAY=0 bash scripts/termux_refresh_sjr.sh
```

`ONLY_ON_DAY=0` bypasses the "only on the 1st" guard. Make sure you're on **mobile data or normal
Wi-Fi (no VPN)** — scimagojr.com blocks datacenter IPs.

**Success looks like:** logs showing pull → download 1999→current → commit & push (or "no change"),
a **Telegram message**, and your Healthchecks check turning **green**.

---

## Phase 6 — Schedule it monthly (survives reboot & sleep)

Android kills plain `cron` during Doze, so use the OS job scheduler plus the boot hook.

1. Install the **Termux:API** app from F-Droid, then:
   ```bash
   pkg install -y termux-api
   ```
2. Install the **Termux:Boot** app from F-Droid and **open it once** (lets it run at boot).
3. Register the job and make it re-register on reboot:
   ```bash
   cd ~/Pubmed_app_v2
   mkdir -p ~/.termux/boot
   cp scripts/termux_schedule_setup.sh ~/.termux/boot/
   bash scripts/termux_schedule_setup.sh
   ```
   You should see `Registered daily job #1001 ... (network: any)`.

**How the timing works:** it registers a *daily* job; the script only acts on the **1st of the
month** (the `ONLY_ON_DAY=1` guard) and exits quietly otherwise. Net effect: one real refresh per
month, surviving reboots and sleep. Android batches jobs to save battery, so it fires
*approximately* daily, not at an exact clock time.

### Manage the job

```bash
termux-job-scheduler --pending                  # list scheduled jobs
termux-job-scheduler --cancel --job-id 1001     # remove it
tail -f ~/sjr_refresh.log                        # watch run output
```

To change the network later, edit `JOB_NETWORK` in `~/.sjr_refresh.env` and re-run
`bash scripts/termux_schedule_setup.sh` (and re-copy it to `~/.termux/boot/`).

---

## Troubleshooting

**`git pull` fails: "cannot pull with rebase: You have unstaged changes".**
Something edited a tracked file in this clone. See what changed and discard it:
```bash
cd ~/Pubmed_app_v2
git status
git checkout -- .        # discard local edits (this clone should have none)
git pull --ff-only
```
Configure behaviour via `~/.sjr_refresh.env`, never by editing tracked scripts.

**Download fails / "no years downloaded" / HTTP 403.**
You're likely on a VPN or a blocked network. scimagojr.com only accepts normal mobile/residential
IPs. Turn off any VPN and retry on mobile data or home Wi-Fi.

**No Telegram message.** Re-run the `curl` test from Phase 3 and read the `description` field.
Most often: you haven't sent your bot `/start`, or the chat id/token is wrong.

**Healthchecks never turns green.** It only pings on the 1st (or when you run with
`ONLY_ON_DAY=0`). Run the Phase 5 test once to confirm the ping URL works.

**Push fails with auth error.** Your token isn't cached or lacks **Contents: Read and write**.
Re-do the token step in Phase 1 and run `git pull` once to re-trigger the prompt.

---

## What runs, in order

`termux_schedule_setup.sh` registers a daily job → on each fire, `termux_run_refresh.sh` loads
`~/.sjr_refresh.env`, takes a wake lock, and runs `termux_refresh_sjr.sh`, which: guards on the
day of month → `git pull` → runs `refresh_sjr.py` (downloads 1999→current, dedups, writes
`data/sjr_all.parquet` or `.csv.gz`) → commits & pushes only if changed → pings Healthchecks and
sends a Telegram message. Posit Connect Cloud then redeploys from the new commit.
