#!/usr/bin/env Rscript

# =============================================================================
# Build the combined SCImago Journal Rank (SJR) parquet
# =============================================================================
#
# Downloads the SJR journal rankings for EVERY available year (1999 -> current)
# directly from https://www.scimagojr.com/journalrank.php and writes a single
# combined parquet at data/sjr_all.parquet with an added `year` column.
#
# This reproduces the column schema used by the original `sjrdata` package
# (read_csv2 + janitor::clean_names) so that app.R's DuckDB query works
# unchanged. The export endpoint returns a SEMICOLON-delimited CSV with COMMA
# decimals (European format) and 403s non-browser clients, so we send a
# browser User-Agent.
#
# Run from the repository root:
#     Rscript scripts/build_sjr_parquet.R
# =============================================================================

suppressPackageStartupMessages({
  library(httr)
  library(readr)
  library(dplyr)
  library(janitor)
  library(nanoparquet)
})

# ---- Configuration ----------------------------------------------------------

FIRST_YEAR <- 1999
CURRENT_YEAR <- as.integer(format(Sys.Date(), "%Y"))
OUT_DIR <- "data"
OUT_PATH <- file.path(OUT_DIR, "sjr_all.parquet")

# A realistic browser User-Agent is required; scimagojr.com 403s plain clients.
USER_AGENT <- paste0(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ",
  "AppleWebKit/537.36 (KHTML, like Gecko) ",
  "Chrome/124.0.0.0 Safari/537.36"
)

# ---- Helpers ----------------------------------------------------------------

# European integer (thousands separator may be ".") -> integer
int_eu <- function(x) {
  suppressWarnings(as.integer(gsub("\\.", "", x)))
}

# European decimal ("." thousands, "," decimal) -> numeric
num_dec <- function(x) {
  suppressWarnings(as.numeric(gsub(",", ".", gsub("\\.", "", x))))
}

download_year <- function(year) {
  url <- paste0(
    "https://www.scimagojr.com/journalrank.php?year=", year, "&out=xls"
  )
  tmp <- tempfile(fileext = ".csv")
  on.exit(unlink(tmp), add = TRUE)

  message("Downloading SJR ", year, " ... ", appendLF = FALSE)

  # Retry transient failures (network blips, rate limiting) with backoff.
  max_attempts <- 4
  ok <- FALSE
  for (attempt in seq_len(max_attempts)) {
    resp <- tryCatch(
      GET(
        url,
        add_headers(
          `User-Agent` = USER_AGENT,
          Accept = "text/csv,application/vnd.ms-excel,*/*",
          `Accept-Language` = "en-US,en;q=0.9"
        ),
        write_disk(tmp, overwrite = TRUE),
        timeout(180)
      ),
      error = function(e) {
        message("[attempt ", attempt, " request error: ", e$message, "] ",
                appendLF = FALSE)
        NULL
      }
    )

    if (
      !is.null(resp) &&
        status_code(resp) == 200 &&
        file.exists(tmp) &&
        file.size(tmp) >= 1000
    ) {
      ok <- TRUE
      break
    }

    if (!is.null(resp) && status_code(resp) != 200) {
      message("[attempt ", attempt, " HTTP ", status_code(resp), "] ",
              appendLF = FALSE)
    }
    if (attempt < max_attempts) Sys.sleep(2^attempt) # 2s, 4s, 8s
  }

  if (!ok) {
    message("FAILED (after ", max_attempts, " attempts)")
    return(NULL)
  }

  # Read everything as character; we control numeric parsing ourselves so that
  # the European comma/dot conventions never surprise us.
  df <- tryCatch(
    read_delim(
      tmp,
      delim = ";",
      col_types = cols(.default = col_character()),
      trim_ws = TRUE,
      progress = FALSE
    ),
    error = function(e) {
      message("FAILED (parse error: ", e$message, ")")
      return(NULL)
    }
  )
  if (is.null(df) || nrow(df) == 0) {
    message("FAILED (no rows)")
    return(NULL)
  }

  df <- clean_names(df)

  # The year-specific docs column ("Total Docs. (2023)") cleans to
  # "total_docs_2023" -> normalise to "total_docs".
  yr_doc_col <- grep("^total_docs_\\d{4}$", names(df), value = TRUE)
  if (length(yr_doc_col) > 0) {
    names(df)[names(df) == yr_doc_col[1]] <- "total_docs"
  }

  df$year <- as.character(year)

  message("OK (", nrow(df), " journals)")
  df
}

# ---- Download all years -----------------------------------------------------

if (!dir.exists(OUT_DIR)) dir.create(OUT_DIR, recursive = TRUE)

years <- FIRST_YEAR:CURRENT_YEAR
frames <- list()

for (y in years) {
  df <- download_year(y)
  if (!is.null(df)) {
    frames[[as.character(y)]] <- df
  }
  Sys.sleep(1) # be polite to scimagojr.com
}

if (length(frames) == 0) {
  stop("No SJR years could be downloaded. Aborting without writing parquet.")
}

# Bind (all columns are character, so binding never hits a type clash; missing
# columns in older years are filled with NA).
all <- bind_rows(frames)

# ---- Cast the columns the app relies on -------------------------------------

# Required by app.R's DuckDB query:
#   year, rank, sjr, sjr_best_quartile, h_index, cites_doc_2years, title, issn
all <- all %>%
  mutate(
    year = as.integer(year),
    rank = int_eu(rank),
    h_index = int_eu(h_index),
    sjr = num_dec(sjr),
    cites_doc_2years = num_dec(cites_doc_2years),
    # title / issn / sjr_best_quartile stay character (issn = hyphen-free,
    # comma-separated, exactly what app.R expects)
    issn = as.character(issn),
    title = as.character(title),
    sjr_best_quartile = as.character(sjr_best_quartile)
  ) %>%
  arrange(year, rank)

# Sanity check: the 8 columns the app needs must be present.
required <- c(
  "year", "rank", "sjr", "sjr_best_quartile",
  "h_index", "cites_doc_2years", "title", "issn"
)
missing <- setdiff(required, names(all))
if (length(missing) > 0) {
  stop("Combined SJR data is missing required columns: ",
       paste(missing, collapse = ", "))
}

# ---- Write parquet ----------------------------------------------------------

write_parquet(all, OUT_PATH)

message("")
message("==================================================")
message("Wrote ", OUT_PATH)
message("  Years:   ", min(all$year, na.rm = TRUE), " - ",
        max(all$year, na.rm = TRUE),
        " (", length(frames), " of ", length(years), " requested)")
message("  Rows:    ", format(nrow(all), big.mark = ","))
message("  Columns: ", paste(names(all), collapse = ", "))
message("  Size:    ", format(file.size(OUT_PATH), big.mark = ","), " bytes")
message("==================================================")
