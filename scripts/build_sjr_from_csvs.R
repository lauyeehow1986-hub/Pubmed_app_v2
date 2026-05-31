#!/usr/bin/env Rscript

# =============================================================================
# Combine pre-downloaded SCImago year CSVs into data/sjr_all.parquet
# =============================================================================
#
# Companion to scripts/termux_refresh_sjr.sh. The shell script downloads each
# year's CSV (with the system curl, from a non-blocked mobile IP); this script
# parses and combines them.
#
# Deliberately uses ONLY base R + nanoparquet so it installs cleanly in Termux
# (no dplyr/readr/janitor/stringi compilation). The SCImago export is a
# semicolon-delimited CSV with comma decimals (European format).
#
# Usage:
#   Rscript scripts/build_sjr_from_csvs.R <dir-with-sjr_YYYY.csv-files>
# =============================================================================

suppressPackageStartupMessages(library(nanoparquet))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1) {
  stop("Usage: Rscript build_sjr_from_csvs.R <dir-with-csvs>")
}
raw_dir <- args[[1]]
out_dir <- "data"
out_path <- file.path(out_dir, "sjr_all.parquet")

# --- helpers -----------------------------------------------------------------

# janitor::clean_names-style snake_case, base R only.
clean_name <- function(x) {
  x <- tolower(trimws(x))
  x <- gsub("%", "percent", x, fixed = TRUE)
  x <- gsub("[^a-z0-9]+", "_", x)          # non-alnum -> underscore
  x <- gsub("_+", "_", x)
  x <- gsub("^_|_$", "", x)
  x
}

# European decimal ("1.234,56" -> 1234.56); blanks -> NA
num_dec <- function(x) {
  x <- trimws(x)
  x[x == "" | x == "-"] <- NA
  suppressWarnings(as.numeric(gsub(",", ".", gsub(".", "", x, fixed = TRUE))))
}
int_eu <- function(x) {
  x <- trimws(x)
  x[x == "" | x == "-"] <- NA
  suppressWarnings(as.integer(gsub(".", "", x, fixed = TRUE)))
}

read_year <- function(path, year) {
  df <- tryCatch(
    read.csv(
      path,
      sep = ";",
      dec = ",",                # not used (we parse manually) but harmless
      quote = "\"",
      header = TRUE,
      colClasses = "character",
      check.names = FALSE,
      stringsAsFactors = FALSE,
      encoding = "UTF-8",
      fill = TRUE
    ),
    error = function(e) {
      message("  ! parse error ", year, ": ", e$message)
      NULL
    }
  )
  if (is.null(df) || nrow(df) == 0) return(NULL)

  names(df) <- vapply(names(df), clean_name, character(1))

  # Year-specific docs column ("total_docs_2023") -> "total_docs"
  yd <- grep("^total_docs_[0-9]{4}$", names(df))
  if (length(yd) == 1) names(df)[yd] <- "total_docs"

  df$year <- as.character(year)
  df
}

# --- read all CSVs -----------------------------------------------------------

files <- list.files(raw_dir, pattern = "^sjr_[0-9]{4}\\.csv$", full.names = TRUE)
if (length(files) == 0) stop("No sjr_YYYY.csv files found in: ", raw_dir)

frames <- list()
for (f in sort(files)) {
  year <- sub("^sjr_([0-9]{4})\\.csv$", "\\1", basename(f))
  df <- read_year(f, year)
  if (!is.null(df)) {
    frames[[year]] <- df
    message("  + ", year, ": ", nrow(df), " journals, ", ncol(df), " cols")
  }
}
if (length(frames) == 0) stop("No CSVs parsed successfully.")

# Union columns across years (older years lack some newer columns).
all_cols <- unique(unlist(lapply(frames, names)))
frames <- lapply(frames, function(df) {
  miss <- setdiff(all_cols, names(df))
  for (m in miss) df[[m]] <- NA_character_
  df[all_cols]
})
all <- do.call(rbind, frames)

# --- cast the columns the app relies on --------------------------------------
# Required by app.R's DuckDB query:
#   year, rank, sjr, sjr_best_quartile, h_index, cites_doc_2years, title, issn
all$year <- as.integer(all$year)
if ("rank" %in% names(all))             all$rank <- int_eu(all$rank)
if ("h_index" %in% names(all))          all$h_index <- int_eu(all$h_index)
if ("sjr" %in% names(all))              all$sjr <- num_dec(all$sjr)
if ("cites_doc_2years" %in% names(all)) all$cites_doc_2years <- num_dec(all$cites_doc_2years)
# title / issn / sjr_best_quartile stay character.
# (issn here is hyphen-free and comma-separated, exactly what app.R expects.)

required <- c("year", "rank", "sjr", "sjr_best_quartile",
              "h_index", "cites_doc_2years", "title", "issn")
missing <- setdiff(required, names(all))
if (length(missing) > 0) {
  stop("Combined data missing required columns: ", paste(missing, collapse = ", "))
}

# Order rows for stable diffs.
all <- all[order(all$year, all$rank), , drop = FALSE]

if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE)
write_parquet(all, out_path)

cat("\n==================================================\n")
cat("Wrote", out_path, "\n")
cat("  Years:  ", min(all$year, na.rm = TRUE), "-", max(all$year, na.rm = TRUE),
    "(", length(frames), "files )\n")
cat("  Rows:   ", nrow(all), "\n")
cat("  Columns:", paste(names(all), collapse = ", "), "\n")
cat("  Size:   ", file.info(out_path)$size, "bytes\n")
cat("==================================================\n")
