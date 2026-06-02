# ============================================================================
# Startup integrity validation
# ============================================================================
# Validate the bundled SJR data file at app startup. Philosophy:
#   * A MISSING file is tolerated (the app still loads; SJR columns come back
#     empty with a clear in-app warning, exactly as before).
#   * A PRESENT-but-CORRUPT file fails fast with a clear message, rather than
#     surfacing as a confusing mid-search error.
# Returns a list(ok, level, message) so the UI/status module can display it.

validate_sjr_file <- function() {
  path <- resolve_sjr_path()

  if (is.na(path)) {
    return(list(
      ok = FALSE, level = "warning",
      message = paste0(
        "No SJR data file found (looked for ",
        paste(SJR_DATA_CANDIDATES, collapse = ", "),
        "). The app will run, but SJR columns will be empty until you ",
        "run scripts/refresh_sjr.py (Termux) and commit the data file."
      )
    ))
  }

  size <- file.size(path)
  if (is.na(size) || size < 1000) {
    return(list(
      ok = FALSE, level = "error",
      message = paste0("SJR data file '", path,
                       "' is present but too small (", size,
                       " bytes) -- it is likely truncated/corrupt.")
    ))
  }

  # Try a cheap DuckDB read of the required columns. If the file is corrupt or
  # missing required columns, fail clearly.
  required <- c("year", "rank", "sjr", "sjr_best_quartile",
                "h_index", "cites_doc_2years", "title", "issn")
  res <- tryCatch(
    {
      con <- dbConnect(duckdb::duckdb())
      on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
      src <- sjr_duckdb_source(gsub("\\\\", "/", path))
      cols <- dbGetQuery(con, paste0("DESCRIBE SELECT * FROM ", src))$column_name
      missing <- setdiff(required, cols)
      n <- dbGetQuery(con, paste0("SELECT COUNT(*) AS n FROM ", src))$n
      list(cols = cols, missing = missing, n = n)
    },
    error = function(e) list(error = e$message)
  )

  if (!is.null(res$error)) {
    return(list(
      ok = FALSE, level = "error",
      message = paste0("SJR data file '", path,
                       "' could not be read by DuckDB: ", res$error)
    ))
  }
  if (length(res$missing) > 0) {
    return(list(
      ok = FALSE, level = "error",
      message = paste0("SJR data file '", path,
                       "' is missing required columns: ",
                       paste(res$missing, collapse = ", "))
    ))
  }

  list(
    ok = TRUE, level = "ok",
    message = paste0("SJR data file OK: '", path, "' (",
                     format(res$n, big.mark = ","), " rows, ",
                     format(size, big.mark = ","), " bytes).")
  )
}

# Hard guard intended for non-interactive / startup use. Stops the process with
# a clear message ONLY when a file is present but corrupt (level == "error").
assert_sjr_or_warn <- function() {
  v <- validate_sjr_file()
  if (identical(v$level, "error")) {
    stop("[startup validation] ", v$message, call. = FALSE)
  }
  if (identical(v$level, "warning")) {
    message("[startup validation] ", v$message)
  } else {
    message("[startup validation] ", v$message)
  }
  invisible(v)
}
