# ============================================================================
# SJR Journal Data - locates the locally bundled combined SJR file
# ============================================================================
#
# The SJR data is OWNED by this repository. It is downloaded for every year
# (1999 -> current) directly from scimagojr.com by scripts/refresh_sjr.py
# (run on a phone via Termux, because scimagojr.com blocks datacenter/CI IPs)
# and stored as a single gzipped CSV at data/sjr_all.csv.gz with a `year`
# column. DuckDB reads CSV.gz natively, so the rest of the app is unchanged.

# Candidate paths for the bundled combined SJR data file (relative to the app
# directory). Parquet is preferred (smaller, typed); a gzipped CSV is the
# fallback because it can be produced with the Python standard library on a
# phone. DuckDB reads both natively.
SJR_DATA_CANDIDATES <- c("data/sjr_all.parquet", "data/sjr_all.csv.gz")

# Resolve to whichever bundled SJR file actually exists (parquet first).
resolve_sjr_path <- function() {
  for (p in SJR_DATA_CANDIDATES) {
    if (file.exists(p)) return(p)
  }
  return(NA_character_)
}

# Default label used in messages when no file is present yet.
SJR_DATA_PATH <- SJR_DATA_CANDIDATES[[1]]

# Build the DuckDB table source expression for the SJR file. For CSV/CSV.gz we
# use read_csv_auto and force `issn` to VARCHAR so leading-zero ISSNs are not
# mangled into integers; for parquet we reference the path directly.
sjr_duckdb_source <- function(path) {
  p <- gsub("\\\\", "/", path)
  if (grepl("\\.csv(\\.gz)?$", p, ignore.case = TRUE)) {
    paste0(
      "read_csv_auto('", p, "', header=true, types={'issn': 'VARCHAR'})"
    )
  } else {
    paste0("'", p, "'")
  }
}

get_sjr_data <- function() {
  tryCatch(
    {
      sjr_path <- resolve_sjr_path()
      if (is.na(sjr_path)) {
        message("SJR data file not found (looked for: ",
                paste(SJR_DATA_CANDIDATES, collapse = ", "), ")")
        message(
          "Run scripts/refresh_sjr.py (Termux) to download and commit it."
        )
        return(NULL)
      }

      src <- sjr_duckdb_source(sjr_path)

      # Determine the max year available (for status messaging). Best-effort.
      max_year <- tryCatch(
        {
          con <- dbConnect(duckdb::duckdb())
          on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
          res <- dbGetQuery(
            con,
            paste0("SELECT MAX(year) AS max_year FROM ", src)
          )
          as.integer(res$max_year[1])
        },
        error = function(e) NA_integer_
      )

      message("Using local SJR data file: ", sjr_path)
      message("File size: ", file.size(sjr_path), " bytes")
      message("Max year in SJR data: ", max_year)

      return(list(
        path = sjr_path,
        year = max_year
      ))
    },
    error = function(e) {
      message("Error locating SJR data file: ", e$message)
      return(NULL)
    }
  )
}

# Function to query SJR data using DuckDB with LIKE for relevant ISSNs
query_sjr_with_duckdb <- function(sjr_parquet_path, relevant_issns) {
  tryCatch(
    {
      if (is.null(sjr_parquet_path) || length(relevant_issns) == 0) {
        message("SJR query aborted: path is NULL or no ISSNs provided")
        return(NULL)
      }
      
      # Ensure path uses forward slashes for DuckDB
      sjr_parquet_path <- gsub("\\\\", "/", sjr_parquet_path)
      message("SJR parquet path: ", sjr_parquet_path)
      
      # Check if file exists
      if (!file.exists(sjr_parquet_path)) {
        message("SJR parquet file does not exist: ", sjr_parquet_path)
        return(NULL)
      }
      
      message("Number of ISSNs to query: ", length(relevant_issns))
      message("Sample ISSNs (from publications): ", paste(head(relevant_issns, 5), collapse = ", "))
      
      # relevant_issns are already without hyphens (e.g., "12345678")
      # SJR parquet ALSO has ISSNs without hyphens (e.g., "12345678")
      # So we can use them directly!
      
      # Create LIKE conditions for each ISSN
      # The parquet issn column can contain multiple ISSNs (comma-separated)
      # so we use LIKE '%issn%' to match
      like_conditions <- sapply(relevant_issns, function(issn) {
        paste0("issn LIKE '%", issn, "%'")
      })
      
      # Combine conditions with OR
      where_clause <- paste(like_conditions, collapse = " OR ")
      
      # Build the DuckDB source expression (handles .csv.gz or .parquet)
      sjr_source <- sjr_duckdb_source(sjr_parquet_path)

      # Build complete query - note column is 'cites_doc_2years' (not 'citations')
      query <- paste0(
        "SELECT year, rank, sjr, sjr_best_quartile, h_index, cites_doc_2years, title, issn FROM ",
        sjr_source,
        " WHERE ",
        where_clause
      )

      message("DuckDB query length: ", nchar(query))
      message("Sample WHERE clause: ", substr(where_clause, 1, 300), "...")

      # Connect to DuckDB and execute query
      con <- dbConnect(duckdb::duckdb())
      on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

      # First test: check if we can read the SJR file at all
      test_query <- paste0("SELECT COUNT(*) as cnt FROM ", sjr_source)
      test_result <- dbGetQuery(con, test_query)
      message("Total rows in parquet: ", test_result$cnt)
      
      # Execute the main query
      sjr_df <- dbGetQuery(con, query)
      
      message("DuckDB query returned ", nrow(sjr_df), " rows")
      if (nrow(sjr_df) > 0) {
        message("SJR columns: ", paste(names(sjr_df), collapse = ", "))
        message("Sample matched ISSNs: ", paste(head(sjr_df$issn, 3), collapse = ", "))
      }
      
      # Process the results - rename columns and add percentile
      if (nrow(sjr_df) > 0) {
        # Rename cites_doc_2years if it exists
        if ("cites_doc_2years" %in% names(sjr_df)) {
          sjr_df <- sjr_df %>%
            rename(citations_doc_2years = cites_doc_2years)
        }
        
        # Create annual rank percentile as categorical (deciles)
        sjr_df <- sjr_df %>%
          group_by(year) %>%
          mutate(
            total_journals = n(),
            numeric_percentile = (rank / max(rank, na.rm = TRUE)) * 100,
            annual_rank_percentile = case_when(
              numeric_percentile <= 10 ~ "Top 1-10%",
              numeric_percentile <= 20 ~ "Top 11-20%",
              numeric_percentile <= 30 ~ "Top 21-30%",
              numeric_percentile <= 40 ~ "Top 31-40%",
              numeric_percentile <= 50 ~ "Top 41-50%",
              numeric_percentile <= 60 ~ "Top 51-60%",
              numeric_percentile <= 70 ~ "Top 61-70%",
              numeric_percentile <= 80 ~ "Top 71-80%",
              numeric_percentile <= 90 ~ "Top 81-90%",
              TRUE ~ "Top 91-100%"
            )
          ) %>%
          ungroup() %>%
          select(-total_journals, -numeric_percentile)
      }
      
      return(sjr_df)
    },
    error = function(e) {
      message("Error querying SJR with DuckDB: ", e$message)
      return(NULL)
    }
  )
}
