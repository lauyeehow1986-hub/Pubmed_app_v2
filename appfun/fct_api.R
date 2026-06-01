# ============================================================================
# Network API module: PubMed (NCBI E-utilities) + DOAJ
# ============================================================================
#
# Same public functions and return shapes as the original monolithic app
# (search_pubmed, fetch_pubmed_records, fetch_doaj_oa_start) so the downstream
# field-producing pipeline is unchanged. Enhancements added here:
#   * httr::RETRY() for automatic recovery from transient network errors
#   * NCBI "good citizen" identification (tool, email, api_key) via env vars
#   * memoise caching of DOAJ lookups (near-instant on repeat titles)
# All enhancements degrade gracefully if optional packages/env vars are absent.

# Base URLs for NCBI E-utilities
NCBI_ESEARCH_URL <- "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
NCBI_EFETCH_URL <- "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"

# Identify this application to NCBI/DOAJ. NCBI asks every client to send a
# `tool` and `email`; an `api_key` (optional) raises the rate limit from 3 to
# 10 requests/sec. Configure via environment variables (see README / .Renviron):
#   NCBI_TOOL, NCBI_EMAIL, NCBI_API_KEY
NCBI_TOOL  <- Sys.getenv("NCBI_TOOL", "NHCS_PubMed_Tracker")
NCBI_EMAIL <- Sys.getenv("NCBI_EMAIL", "")
NCBI_API_KEY <- Sys.getenv("NCBI_API_KEY", "")

# Build the identification query params NCBI expects (only non-empty ones).
ncbi_id_params <- function() {
  p <- list(tool = NCBI_TOOL)
  if (nzchar(NCBI_EMAIL)) p$email <- NCBI_EMAIL
  if (nzchar(NCBI_API_KEY)) p$api_key <- NCBI_API_KEY
  p
}

# A descriptive User-Agent so servers can see who is calling (good citizen).
app_user_agent <- function() {
  ua <- paste0(
    "NHCS_PubMed_Tracker/1.0 (R httr; ",
    if (nzchar(NCBI_EMAIL)) NCBI_EMAIL else "no-contact-email",
    ")"
  )
  ua
}

# GET with automatic retry on transient failures. Falls back to httr::GET if
# httr::RETRY is somehow unavailable. Signature mirrors httr::GET(url, query=).
http_get_retry <- function(url, query = NULL, times = 4, ...) {
  if (exists("RETRY", where = asNamespace("httr"), inherits = FALSE)) {
    httr::RETRY(
      "GET",
      url,
      query = query,
      httr::user_agent(app_user_agent()),
      times = times,
      pause_base = 1,
      pause_cap = 16,
      # Retry on these HTTP statuses in addition to connection errors
      terminate_on = NULL,
      quiet = TRUE,
      ...
    )
  } else {
    httr::GET(url, query = query, httr::user_agent(app_user_agent()), ...)
  }
}

# Function to search PubMed and get PMIDs
search_pubmed <- function(query, retmax = 1000) {
  tryCatch(
    {
      response <- http_get_retry(
        NCBI_ESEARCH_URL,
        query = c(
          list(
            db = "pubmed",
            term = query,
            retmax = retmax,
            retmode = "json",
            usehistory = "y"
          ),
          ncbi_id_params()
        )
      )

      if (status_code(response) != 200) {
        stop("PubMed search failed with status: ", status_code(response))
      }

      content_text <- content(response, "text", encoding = "UTF-8")
      result <- fromJSON(content_text)

      list(
        count = as.integer(result$esearchresult$count),
        ids = result$esearchresult$idlist,
        webenv = result$esearchresult$webenv,
        query_key = result$esearchresult$querykey
      )
    },
    error = function(e) {
      stop("Error searching PubMed: ", e$message)
    }
  )
}

# Function to fetch PubMed records in XML format
fetch_pubmed_records <- function(search_result, retmax = 1000) {
  tryCatch(
    {
      # Use WebEnv and query_key for efficient retrieval
      if (!is.null(search_result$webenv) && !is.null(search_result$query_key)) {
        response <- http_get_retry(
          NCBI_EFETCH_URL,
          query = c(
            list(
              db = "pubmed",
              query_key = search_result$query_key,
              WebEnv = search_result$webenv,
              rettype = "xml",
              retmode = "xml",
              retmax = retmax
            ),
            ncbi_id_params()
          )
        )
      } else {
        # Fallback to using IDs directly
        ids_string <- paste(search_result$ids, collapse = ",")
        response <- http_get_retry(
          NCBI_EFETCH_URL,
          query = c(
            list(
              db = "pubmed",
              id = ids_string,
              rettype = "xml",
              retmode = "xml"
            ),
            ncbi_id_params()
          )
        )
      }

      if (status_code(response) != 200) {
        stop("PubMed fetch failed with status: ", status_code(response))
      }

      content(response, "text", encoding = "UTF-8")
    },
    error = function(e) {
      stop("Error fetching PubMed records: ", e$message)
    }
  )
}

# ----------------------------------------------------------------------------
# DOAJ Open Access lookup
# ----------------------------------------------------------------------------

# Underlying (uncached) DOAJ lookup. Same return shape as the original:
# a one-row data.frame(title, oa_start).
fetch_doaj_oa_start_impl <- function(journal_title) {
  tryCatch(
    {
      encoded_title <- URLencode(journal_title, reserved = TRUE)
      url <- paste0("https://doaj.org/api/v4/search/journals/", encoded_title)

      res <- http_get_retry(url, query = NULL, times = 4, timeout(10))

      if (status_code(res) == 200) {
        data <- fromJSON(
          content(res, "text", encoding = "UTF-8"),
          flatten = TRUE
        )

        if (!is.null(data$results) && length(data$results) > 0) {
          # Check for the oa_start field
          if ("bibjson.oa_start" %in% names(data$results)) {
            return(data.frame(
              title = journal_title,
              oa_start = as.character(data$results$bibjson.oa_start[1]),
              stringsAsFactors = FALSE
            ))
          }
        }
      }

      return(data.frame(
        title = journal_title,
        oa_start = NA_character_,
        stringsAsFactors = FALSE
      ))
    },
    error = function(e) {
      message("Error fetching DOAJ data for: ", journal_title, " - ", e$message)
      return(data.frame(
        title = journal_title,
        oa_start = NA_character_,
        stringsAsFactors = FALSE
      ))
    }
  )
}

# Public DOAJ function. Memoised when the `memoise` package is available so
# repeated lookups of the same journal title are near-instant; otherwise it is
# exactly the uncached implementation. Same name/return shape as before.
if (requireNamespace("memoise", quietly = TRUE)) {
  fetch_doaj_oa_start <- memoise::memoise(fetch_doaj_oa_start_impl)
} else {
  fetch_doaj_oa_start <- fetch_doaj_oa_start_impl
}

# ----------------------------------------------------------------------------
# OPTIONAL: parallel DOAJ lookups (opt-in, OFF by default)
# ----------------------------------------------------------------------------
# Set USE_ASYNC_DOAJ=true (env var) AND have `future` installed to look up many
# journal titles concurrently instead of one-at-a-time. This trades the polite
# per-request rate limiting for speed, so it is opt-in. The DEFAULT search
# pipeline remains the verbatim synchronous loop. Returns a combined data.frame
# with the same (title, oa_start) columns.
USE_ASYNC_DOAJ <- tolower(Sys.getenv("USE_ASYNC_DOAJ", "false")) %in%
  c("1", "true", "yes")

fetch_doaj_oa_start_many <- function(titles, workers = 4) {
  titles <- unique(titles[!is.na(titles)])
  if (length(titles) == 0) {
    return(data.frame(title = character(0), oa_start = character(0),
                      stringsAsFactors = FALSE))
  }
  if (USE_ASYNC_DOAJ && requireNamespace("future.apply", quietly = TRUE) &&
        requireNamespace("future", quietly = TRUE)) {
    future::plan(future::multisession, workers = workers)
    on.exit(future::plan(future::sequential), add = TRUE)
    rows <- future.apply::future_lapply(titles, fetch_doaj_oa_start_impl)
  } else {
    rows <- lapply(titles, fetch_doaj_oa_start)
  }
  do.call(rbind, rows)
}
