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

- `scripts/build_sjr_parquet.R` downloads **every year, 1999 → current**, directly from
  [scimagojr.com](https://www.scimagojr.com/journalrank.php) and writes one combined file,
  `data/sjr_all.parquet` (with a `year` column).
- A GitHub Actions workflow (`.github/workflows/update-sjr.yml`) rebuilds and commits that
  parquet **monthly** (and on demand). SCImago itself only updates roughly once a year, so
  monthly is comfortably fresh.
- `app.R` reads the local `data/sjr_all.parquet` and matches each publication to its SJR row by
  **ISSN and publication year across all years** (a strict improvement over the old single-year
  lookup). Every column, tab, and feature of the original app is preserved.

## Repository layout

```
app.R                              # the Shiny app (server-side)
data/sjr_all.parquet               # combined SJR data, 1999 -> current (built by CI)
scripts/build_sjr_parquet.R        # downloader / parquet builder
.github/workflows/update-sjr.yml   # monthly refresh of the parquet
.github/workflows/generate-manifest.yml  # (re)generate manifest.json for Posit Connect Cloud
manifest.json                      # dependency manifest for Posit Connect Cloud
```

## First-time setup

Because the parquet and the Connect Cloud `manifest.json` are produced by R (not committed by
hand), seed them once via GitHub Actions:

1. **Build the SJR data:** Actions → **Update SJR parquet** → **Run workflow**. This downloads
   ~27 years from scimagojr.com (a few minutes) and commits `data/sjr_all.parquet`.
2. **Generate the manifest:** Actions → **Generate Connect manifest** → **Run workflow**. This
   installs the app's packages, runs `rsconnect::writeManifest()`, and commits `manifest.json`.

(If you have R locally you can instead run `Rscript scripts/build_sjr_parquet.R` and
`Rscript -e 'rsconnect::writeManifest(appPrimaryDoc="app.R")'` and commit the results.)

## Deploy on Posit Connect Cloud

1. Sign in at <https://connect.posit.cloud> and link your GitHub account.
2. **Publish → Shiny (R)** and select this repository.
3. Choose the branch (`claude/scimagojr-github-deployment-5Hud3`, or `main` after you merge) and
   set the primary file to **`app.R`**.
4. Deploy. Connect Cloud installs the packages listed in `manifest.json`, deploys the whole
   repository (including `data/sjr_all.parquet`, which the app reads locally), and **redeploys
   automatically when you push** to the linked branch.

## Running locally

```r
# install.packages(c("shiny","shinydashboard","xml2","httr","jsonlite","dplyr",
#                     "tidyr","stringr","DT","lubridate","duckdb","DBI"))
shiny::runApp(".")
```

Make sure `data/sjr_all.parquet` exists first (run `scripts/build_sjr_parquet.R`).

## Data sources

- PubMed via NCBI E-utilities API
- Directory of Open Access Journals (DOAJ) API v4
- SCImago Journal & Country Rank (SJR), downloaded directly from scimagojr.com
