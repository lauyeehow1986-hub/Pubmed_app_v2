# NHCS PubMed Tracker

A Shiny dashboard that searches PubMed for **National Heart Centre Singapore (NHCS)**
publications and enriches each record with:

- author position, affiliations, Duke-NUS and JRI institute tagging, NHCS department
- DOAJ **Open Access** status
- **SCImago Journal Rank (SJR)** metrics — rank, SJR score, best quartile, H-index,
  cites/doc (2 years) "JIF", JIF category, and annual rank percentile

It runs server-side (R), so it makes live calls to the NCBI E-utilities and DOAJ APIs and
queries the SJR data with DuckDB.

## What changed vs. the original app

The original app pulled SJR data at runtime from a third-party, **static** repository and only
ever loaded a **single year** (current year − 1). This project instead **owns its SJR data**:

- The SJR data is downloaded for **every year, 1999 → current**, directly from
  [scimagojr.com](https://www.scimagojr.com/journalrank.php) and combined into one file,
  `data/sjr_all.parquet` (with a `year` column).
- `app.R` reads the local `data/sjr_all.parquet` and matches each publication to its SJR row by
  **ISSN and publication year across all years** (a strict improvement over the old single-year
  lookup). Every column, tab, and feature of the original app is preserved.

> **Why the data is refreshed from a phone (Termux), not GitHub Actions.**
> scimagojr.com returns **HTTP 403 to datacenter/CI IPs**, so a GitHub Actions runner cannot
> download it. A normal mobile/Wi-Fi IP is **not** blocked, so the refresh runs on your phone via
> [Termux](https://termux.dev) and pushes the rebuilt parquet to GitHub. Posit Connect Cloud then
> redeploys from the new commit. SCImago only updates ~once a year, so this is needed rarely.

## Repository layout

```
app.R                              # the Shiny app (server-side)
manifest.json                      # dependency manifest for Posit Connect Cloud
data/sjr_all.parquet               # combined SJR data, 1999 -> current
scripts/termux_refresh_sjr.sh      # phone-side: download all years + commit parquet
scripts/build_sjr_from_csvs.R      # base-R + nanoparquet combiner (Termux-friendly)
scripts/build_sjr_parquet.R        # full-tidyverse builder (for a desktop/laptop with R)
```

## Refreshing the SJR data on your phone (Termux)

You only need to do this once to seed the data, then ~yearly when SCImago updates.

### One-time Termux setup

```bash
pkg update && pkg upgrade -y
pkg install -y git r-base curl openssh
# nanoparquet is the only R package needed for the phone-side build:
Rscript -e 'install.packages("nanoparquet", repos="https://cloud.r-project.org")'
```

Clone your repo and let git remember your credentials (use a GitHub
**Personal Access Token** as the password when prompted):

```bash
cd ~
git clone https://github.com/lauyeehow1986-hub/Pubmed_app_v2.git
cd Pubmed_app_v2
git config credential.helper store      # caches the token after first push
git config user.name  "Your Name"
git config user.email "lauyeehow1986@gmail.com"
```

### Run the refresh

```bash
# make sure you are on mobile data or a normal Wi-Fi IP (NOT a VPN/datacenter)
bash scripts/termux_refresh_sjr.sh
```

It downloads every year 1999→current from scimagojr.com, rebuilds
`data/sjr_all.parquet`, and commits + pushes it only if it changed.

### Schedule it (optional, monthly bot)

Install the Termux:Tasks/Boot add-ons and the scheduler, then:

```bash
pkg install -y termux-api cronie
# start cron:
crond
# edit schedule:
crontab -e
```

Add a line to run on the 1st of each month at 09:00 (adjust the path if your
clone is elsewhere):

```
0 9 1 * * bash ~/Pubmed_app_v2/scripts/termux_refresh_sjr.sh >> ~/sjr_refresh.log 2>&1
```

> Keep the phone awake/charging for scheduled runs, or just run the script by
> hand each spring when the new SCImago year is published — it only changes
> once a year.

## Building the data on a desktop/laptop instead

If you have R on a computer (and a non-blocked IP), you can skip Termux:

```r
# install.packages(c("httr","readr","dplyr","janitor","nanoparquet"))
# from the repo root:
# Rscript scripts/build_sjr_parquet.R
```

Then `git add data/sjr_all.parquet && git commit && git push`.

## Deploy on Posit Connect Cloud

> **Free tier deploys from _public_ GitHub repos only** (private repos need a paid plan), and the
> free tier allows up to 5 apps. Make this repository public before deploying.

1. Sign in at <https://connect.posit.cloud> and link your GitHub account.
2. **Publish → Shiny (R)** and select this repository.
3. Choose the branch and set the primary file to **`app.R`**.
4. Deploy. Connect Cloud installs the packages from `manifest.json`, ships the **entire**
   repository (via `git archive` — including `data/sjr_all.parquet`, which the app reads locally),
   and **redeploys automatically when you push** to the linked branch — including the parquet
   pushes from your phone.

### About `manifest.json`

Connect Cloud reads the **R version and package set** from `manifest.json`; it ignores the
manifest's file list/checksums for git deploys (it uses `git archive`). So:

- Refreshing `data/sjr_all.parquet` does **not** require touching the manifest.
- Only regenerate it when you change the app's **R package dependencies** (or R version):

  ```r
  rsconnect::writeManifest(appDir = ".", appPrimaryDoc = "app.R")
  ```

  then commit the updated `manifest.json`.

## Running the app locally

```r
# install.packages(c("shiny","shinydashboard","xml2","httr","jsonlite","dplyr",
#                     "tidyr","stringr","DT","lubridate","duckdb","DBI"))
shiny::runApp(".")
```

Make sure `data/sjr_all.parquet` exists first.

## Data sources

- PubMed via NCBI E-utilities API
- Directory of Open Access Journals (DOAJ) API v4
- SCImago Journal & Country Rank (SJR), downloaded directly from scimagojr.com
