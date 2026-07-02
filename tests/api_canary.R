#!/usr/bin/env Rscript
# =============================================================================
# API contract canary -- detects breaking changes in the NCBI PubMed and DOAJ
# APIs that the app depends on.
# =============================================================================
#
# It reuses the app's OWN modules (appfun/fct_api.R + fct_pubmed_parse.R +
# fct_helpers.R), so it fails exactly when the real field-extraction path would
# break -- not against a parallel guess of the response shape.
#
# Unlike the SJR refresh (scimagojr.com blocks datacenter IPs), NCBI and DOAJ
# are reachable from CI, so this runs in GitHub Actions on a schedule. A
# non-zero exit fails the job; GitHub then emails you (and the workflow can also
# send a Telegram message).
#
# Run locally:  Rscript tests/api_canary.R
# =============================================================================

suppressWarnings(suppressMessages({
  library(xml2)
  library(httr)
  library(jsonlite)
  library(lubridate)
}))

# ---- locate repo root (works under `Rscript tests/api_canary.R`) ------------
script_path <- sub("^--file=", "",
                   grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1])
root <- if (!is.na(script_path) && nzchar(script_path)) {
  normalizePath(file.path(dirname(script_path), ".."), mustWork = FALSE)
} else {
  normalizePath(getwd(), mustWork = FALSE)
}
if (!dir.exists(file.path(root, "appfun"))) root <- normalizePath(getwd(), mustWork = FALSE)

src <- function(f) source(file.path(root, "appfun", f))
src("fct_helpers.R")
src("fct_pubmed_parse.R")
src("fct_api.R")

# ---- fixed, stable inputs ---------------------------------------------------
# The app's own NHCS affiliation query (mirrors app.R), so the canary exercises
# the same search -> parse -> NHCS-author path the app uses.
NHCS_QUERY <- paste0(
  '"national heart center singapore"[ad] OR ',
  '"national heart centre singapore"[ad]'
)
# A long-lived journal that is indexed in DOAJ (open access), used to confirm
# the DOAJ contract (the `bibjson.oa_start` field the app reads).
DOAJ_TEST_JOURNAL <- "PLoS ONE"
DOAJ_SPEC_URLS <- c(
  "https://doaj.org/api/v4/swagger.json",
  "https://doaj.org/api/swagger.json"
)
BASELINE <- file.path(root, "tests", "doaj_openapi.baseline.json")

# ---- tiny result harness ----------------------------------------------------
.results <- list()
nz <- function(x) !is.null(x) && length(x) == 1 && !is.na(x) && nzchar(as.character(x))
record <- function(name, ok, detail = "", hard = TRUE) {
  tag <- if (isTRUE(ok)) "PASS" else if (hard) "FAIL" else "WARN"
  cat(sprintf("[%s] %s%s\n", tag, name, if (nzchar(detail)) paste0(" -- ", detail) else ""))
  .results[[length(.results) + 1]] <<- list(ok = isTRUE(ok), hard = hard)
}

# =============================================================================
# NCBI PubMed (E-utilities)
# =============================================================================
xml <- NULL
sr <- tryCatch(search_pubmed(NHCS_QUERY, retmax = 20), error = function(e) e)
if (inherits(sr, "error")) {
  record("NCBI esearch reachable", FALSE, conditionMessage(sr))
} else {
  record("NCBI esearch returns hits",
         nz(sr$count) && as.integer(sr$count) > 0 && length(sr$ids) > 0,
         sprintf("count=%s, ids=%d", sr$count, length(sr$ids)))

  xml <- tryCatch(fetch_pubmed_records(sr, retmax = 20), error = function(e) e)
  if (inherits(xml, "error")) {
    record("NCBI efetch reachable", FALSE, conditionMessage(xml)); xml <- NULL
  } else {
    record("NCBI efetch returns XML", is.character(xml) && nchar(xml) > 0)
  }
}

if (!is.null(xml)) {
  doc <- tryCatch(read_xml(xml), error = function(e) e)
  if (inherits(doc, "error")) {
    record("NCBI XML parses", FALSE, conditionMessage(doc))
  } else {
    # Structural contract: the elements parse_single_article() relies on must
    # still exist. A schema change at NCBI shows up here.
    needed <- c(
      "PubmedArticle"      = ".//PubmedArticle",
      "PMID"               = ".//PMID",
      "ArticleTitle"       = ".//ArticleTitle",
      "Author/LastName"    = ".//Author/LastName",
      "Affiliation"        = ".//AffiliationInfo/Affiliation",
      "Journal/Title"      = ".//Journal/Title",
      "ISSN"               = ".//ISSN",
      "PubDate/Year"       = ".//PubDate/Year"
    )
    for (nm in names(needed)) {
      record(paste0("NCBI XML still has <", nm, ">"),
             length(xml_find_all(doc, needed[[nm]])) > 0)
    }
  }

  # End-to-end: the real parser must still yield an NHCS row with core fields.
  rows <- tryCatch(parse_pubmed_xml(xml), error = function(e) e)
  if (inherits(rows, "error")) {
    record("PubMed parser runs", FALSE, conditionMessage(rows))
  } else {
    record("PubMed parser yields >=1 NHCS row", length(rows) > 0,
           sprintf("rows=%d", length(rows)))
    if (length(rows) > 0) {
      r <- rows[[1]]
      record("Parsed row has core fields",
             nz(r$PMID) && nz(r$Publications) && nz(r$Title) && nz(r$CY_Published_Reported),
             sprintf("PMID=%s, year=%s", r$PMID, r$CY_Published_Reported))
    }
  }
}

# -----------------------------------------------------------------------------
# Regression: known NHCS articles whose affiliation is written
# "National Heart Centre, Singapore" (comma/address-separated, not the exact
# "National Heart Centre Singapore" phrase). Each must still be fetched and
# tagged as an NHCS author. Guards the broadened search query + is_nhcs_author.
# -----------------------------------------------------------------------------
NHCS_REGRESSION_PMIDS <- c("42341796", "42331777", "42097582")
rx <- tryCatch(fetch_pubmed_records(list(ids = NHCS_REGRESSION_PMIDS), retmax = 10),
               error = function(e) e)
if (inherits(rx, "error")) {
  record("NHCS comma-affiliation regression fetch", FALSE, conditionMessage(rx))
} else {
  rrows <- tryCatch(parse_pubmed_xml(rx), error = function(e) e)
  if (inherits(rrows, "error")) {
    record("NHCS comma-affiliation regression parse", FALSE, conditionMessage(rrows))
  } else {
    got <- unique(vapply(rrows, function(r) as.character(r$PMID), character(1)))
    for (p in NHCS_REGRESSION_PMIDS) {
      record(paste("NHCS comma-affiliation captured:", p), p %in% got)
    }
  }
}

# =============================================================================
# DOAJ (Open Access lookup)
# =============================================================================
# Field-level: the app reads bibjson.oa_start via fetch_doaj_oa_start_impl().
doaj <- tryCatch(fetch_doaj_oa_start_impl(DOAJ_TEST_JOURNAL), error = function(e) e)
if (inherits(doaj, "error")) {
  record("DOAJ lookup runs", FALSE, conditionMessage(doaj))
} else {
  record("DOAJ oa_start resolved",
         is.data.frame(doaj) && nrow(doaj) == 1 && nz(doaj$oa_start),
         sprintf("oa_start=%s", doaj$oa_start))
}

# Raw contract: confirm the /api/v4 endpoint + JSON shape the app parses.
enc <- URLencode(DOAJ_TEST_JOURNAL, reserved = TRUE)
res <- tryCatch(
  http_get_retry(paste0("https://doaj.org/api/v4/search/journals/", enc),
                 times = 4, timeout(15)),
  error = function(e) e
)
if (inherits(res, "error")) {
  record("DOAJ /api/v4 reachable", FALSE, conditionMessage(res))
} else {
  record("DOAJ /api/v4 returns HTTP 200", status_code(res) == 200,
         paste("status", status_code(res)))
  if (status_code(res) == 200) {
    j <- tryCatch(fromJSON(content(res, "text", encoding = "UTF-8"), flatten = TRUE),
                  error = function(e) e)
    if (inherits(j, "error")) {
      record("DOAJ JSON parses", FALSE, conditionMessage(j))
    } else {
      record("DOAJ response has results", !is.null(j$results) && length(j$results) > 0)
      record("DOAJ results expose bibjson.oa_start",
             "bibjson.oa_start" %in% names(j$results))
    }
  }
}

# Spec drift (best-effort, soft): diff DOAJ's OpenAPI spec against a committed
# baseline. First run (no baseline) writes one for you to commit; an unreachable
# spec endpoint only warns. A real change once a baseline exists FAILS so you
# review it, then update tests/doaj_openapi.baseline.json.
spec_txt <- NULL
for (u in DOAJ_SPEC_URLS) {
  r <- tryCatch(http_get_retry(u, times = 2, timeout(15)), error = function(e) NULL)
  if (!is.null(r) && status_code(r) == 200) {
    spec_txt <- content(r, "text", encoding = "UTF-8"); break
  }
}
if (is.null(spec_txt)) {
  record("DOAJ OpenAPI spec drift", TRUE, "spec endpoint unreachable; skipped", hard = FALSE)
} else {
  canon <- tryCatch(
    toJSON(fromJSON(spec_txt, simplifyVector = TRUE), auto_unbox = TRUE, null = "null"),
    error = function(e) spec_txt
  )
  if (!file.exists(BASELINE)) {
    writeLines(as.character(canon), BASELINE)
    record("DOAJ OpenAPI spec drift", TRUE,
           "baseline created -- commit tests/doaj_openapi.baseline.json to enable drift detection",
           hard = FALSE)
  } else {
    same <- identical(readLines(BASELINE, warn = FALSE), strsplit(as.character(canon), "\n")[[1]])
    record("DOAJ OpenAPI spec unchanged", same,
           if (same) "" else "spec changed -- review, then update the baseline")
  }
}

# =============================================================================
# Summary / exit code
# =============================================================================
hard_fail <- sum(vapply(.results, function(x) !x$ok && x$hard, logical(1)))
warn      <- sum(vapply(.results, function(x) !x$ok && !x$hard, logical(1)))
pass      <- sum(vapply(.results, function(x) x$ok, logical(1)))
cat(sprintf("\nSummary: %d passed, %d failed, %d warnings.\n", pass, hard_fail, warn))
if (hard_fail > 0) {
  cat("API contract change detected -- the app's PubMed/DOAJ handling may be broken.\n")
  quit(status = 1)
}
cat("All API contracts intact.\n")
