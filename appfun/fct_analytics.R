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

# ---- Interactive filtering + deeper-insight summaries -----------------------

# Filter article/author rows by year range, department(s), quartile(s) and OA.
# Any argument left NULL/empty is not applied. Works on both the article-level
# (collapsed) and author-level (combined) frames.
filter_articles <- function(df, years = NULL, depts = NULL,
                            quartiles = NULL, oa = NULL) {
  if (is.null(df) || !nrow(df)) return(df)
  keep <- rep(TRUE, nrow(df))
  if (!is.null(years) && length(years) == 2 &&
        "CY_Published_Reported" %in% names(df)) {
    y <- suppressWarnings(as.integer(df$CY_Published_Reported))
    keep <- keep & !is.na(y) & y >= years[1] & y <= years[2]
  }
  if (!is.null(depts) && length(depts) && "Department" %in% names(df)) {
    keep <- keep & vapply(df$Department,
                          function(d) any(split_departments(d) %in% depts),
                          logical(1))
  }
  if (!is.null(quartiles) && length(quartiles) &&
        "SJR_Best_Quartile" %in% names(df)) {
    q <- toupper(trimws(as.character(df$SJR_Best_Quartile)))
    q[!q %in% c("Q1", "Q2", "Q3", "Q4")] <- "Unranked"
    keep <- keep & q %in% quartiles
  }
  if (!is.null(oa) && oa %in% c("Yes", "No") && "Open_Access" %in% names(df)) {
    v <- ifelse(is.na(df$Open_Access), "No", as.character(df$Open_Access))
    keep <- keep & v == oa
  }
  df[keep, , drop = FALSE]
}

# Per-year metrics: publication count, Open Access % and Q1 %.
yearly_metrics <- function(df) {
  empty <- data.frame(Year = integer(), Publications = integer(),
                      `OA_%` = integer(), `Q1_%` = integer(),
                      check.names = FALSE)
  if (is.null(df) || !nrow(df) || !"CY_Published_Reported" %in% names(df)) {
    return(empty)
  }
  y <- suppressWarnings(as.integer(df$CY_Published_Reported))
  ok <- !is.na(y)
  if (!any(ok)) return(empty)
  y <- y[ok]; df <- df[ok, , drop = FALSE]
  oa <- ifelse(is.na(df$Open_Access), "No", as.character(df$Open_Access)) == "Yes"
  q1 <- toupper(trimws(as.character(df$SJR_Best_Quartile))) == "Q1"
  ag <- aggregate(data.frame(Publications = 1L, OA = oa, Q1 = q1),
                  by = list(Year = y), FUN = sum)
  data.frame(
    Year = ag$Year,
    Publications = ag$Publications,
    `OA_%` = round(100 * ag$OA / ag$Publications),
    `Q1_%` = round(100 * ag$Q1 / ag$Publications),
    check.names = FALSE
  )[order(ag$Year), ]
}

# NHCS author role distribution (First / Middle / Last) from author-level data.
author_role_counts <- function(df) {
  if (is.null(df) || !nrow(df) || !"Author_Status" %in% names(df)) {
    return(integer(0))
  }
  s <- trimws(as.character(df$Author_Status))
  role <- ifelse(s == "First", "First", ifelse(s == "Last", "Last", "Middle"))
  table(factor(role, levels = c("First", "Middle", "Last")))
}

# Top-N journals by publication count.
top_journals_df <- function(df, n = 10) {
  col <- if ("Abbreviated_Title" %in% names(df)) "Abbreviated_Title" else "Title"
  if (is.null(df) || !nrow(df) || !col %in% names(df)) {
    return(data.frame(Journal = character(), Publications = integer()))
  }
  j <- .an_nonempty(df[[col]])
  if (!length(j)) return(data.frame(Journal = character(), Publications = integer()))
  tb <- utils::head(sort(table(j), decreasing = TRUE), n)
  data.frame(Journal = names(tb), Publications = as.integer(tb),
             row.names = NULL)
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
