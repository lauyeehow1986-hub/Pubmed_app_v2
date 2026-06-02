# ============================================================================
# Analytics helpers (pure, testable -- no Shiny/reactive dependencies)
# ============================================================================
# Summaries for the Analytics tab, computed from the article-level (collapsed)
# data frame: one row per PMID, with columns CY_Published_Reported,
# Open_Access ("Yes"/"No"), SJR_Best_Quartile, Department (semicolon-joined),
# and NHCS_Authors. All helpers are empty-safe so the UI degrades gracefully
# before a search has run.

.an_nonempty <- function(x) {
  x <- trimws(as.character(x))
  x[!is.na(x) & nzchar(x) & x != "NA"]
}

# Split a semicolon-joined department string into individual departments.
split_departments <- function(dept_col) {
  if (is.null(dept_col) || !length(dept_col)) return(character(0))
  .an_nonempty(unlist(strsplit(as.character(dept_col), "\\s*;\\s*")))
}

# Publications per calendar year (contiguous year axis).
year_counts <- function(df) {
  if (is.null(df) || !"CY_Published_Reported" %in% names(df)) return(integer(0))
  y <- suppressWarnings(as.integer(df$CY_Published_Reported))
  y <- y[!is.na(y)]
  if (!length(y)) return(integer(0))
  table(factor(y, levels = seq(min(y), max(y))))
}

# Open Access Yes/No counts.
oa_counts <- function(df) {
  if (is.null(df) || !"Open_Access" %in% names(df) || !nrow(df)) return(integer(0))
  v <- ifelse(is.na(df$Open_Access), "No", as.character(df$Open_Access))
  table(factor(v, levels = c("Yes", "No")))
}

# Journal quartile mix; anything not Q1-Q4 is "Unranked".
quartile_counts <- function(df) {
  if (is.null(df) || !"SJR_Best_Quartile" %in% names(df) || !nrow(df)) return(integer(0))
  q <- toupper(trimws(as.character(df$SJR_Best_Quartile)))
  q[!q %in% c("Q1", "Q2", "Q3", "Q4")] <- "Unranked"
  table(factor(q, levels = c("Q1", "Q2", "Q3", "Q4", "Unranked")))
}

# Articles with Duke-NUS- and JRI-affiliated authors (collaboration view).
affiliation_counts <- function(df) {
  if (is.null(df) || !nrow(df)) return(integer(0))
  has <- function(col) {
    if (!col %in% names(df)) return(rep(FALSE, nrow(df)))
    v <- trimws(as.character(df[[col]]))
    !is.na(df[[col]]) & nzchar(v) & toupper(v) != "NA"
  }
  dn <- has("Duke_NUS_Affiliation")
  jri <- has("JRI_Affiliation")
  c("Duke-NUS" = sum(dn), "JRI" = sum(jri), "Neither" = sum(!dn & !jri))
}

# Top-N departments by number of publications.
dept_counts <- function(df, top = 10) {
  if (is.null(df) || !"Department" %in% names(df) || !nrow(df)) return(integer(0))
  d <- unlist(lapply(df$Department, split_departments))
  if (!length(d)) return(integer(0))
  utils::head(sort(table(d), decreasing = TRUE), top)
}

# Headline numbers for the KPI cards.
analytics_kpis <- function(df) {
  if (is.null(df) || !nrow(df)) {
    return(list(n_pubs = 0, pct_oa = 0, pct_q1 = 0, n_depts = 0, n_authors = 0))
  }
  oa <- ifelse(is.na(df$Open_Access), "No", as.character(df$Open_Access))
  q <- toupper(trimws(as.character(df$SJR_Best_Quartile)))
  depts <- unique(unlist(lapply(df$Department, split_departments)))
  authors <- if ("NHCS_Authors" %in% names(df)) {
    unique(.an_nonempty(unlist(strsplit(paste(df$NHCS_Authors, collapse = ";"),
                                        "\\s*;\\s*"))))
  } else {
    character(0)
  }
  # Mean co-authors per article from the full author list.
  avg_authors <- if ("Author_List" %in% names(df)) {
    n <- vapply(df$Author_List, function(s) {
      length(.an_nonempty(strsplit(as.character(s), "\\s*;\\s*")[[1]]))
    }, integer(1))
    if (length(n)) round(mean(n), 1) else 0
  } else {
    0
  }
  list(
    n_pubs      = nrow(df),
    pct_oa      = round(100 * mean(oa == "Yes")),
    pct_q1      = round(100 * mean(q == "Q1")),
    n_depts     = length(depts),
    n_authors   = length(authors),
    avg_authors = avg_authors
  )
}

# Tidy long-format summary (Metric, Category, Count) for CSV export.
analytics_summary_long <- function(df) {
  mk <- function(metric, tb) {
    if (!length(tb)) return(NULL)
    data.frame(Metric = metric, Category = names(tb),
               Count = as.integer(tb), stringsAsFactors = FALSE)
  }
  out <- do.call(rbind, list(
    mk("Publications by year", year_counts(df)),
    mk("Open Access", oa_counts(df)),
    mk("Journal quartile", quartile_counts(df)),
    mk("Affiliation tagging", affiliation_counts(df)),
    mk("Top departments", dept_counts(df, 15))
  ))
  if (is.null(out)) {
    out <- data.frame(Metric = character(), Category = character(),
                      Count = integer(), stringsAsFactors = FALSE)
  }
  out
}
