#!/usr/bin/env Rscript
# Smoke test: parse every R source file in the app and fail loudly on any
# syntax error. This is a fast, dependency-free integrity check (parse() does
# not load packages, so it works even without duckdb installed) and is the
# closest thing this repo has to a unit test. Run with:
#
#   Rscript tests/parse_check.R
#
# Exits non-zero if anything fails to parse.

# Locate the repo root robustly whether invoked as `Rscript tests/parse_check.R`
# (from the repo root) or sourced. Prefer the script path from commandArgs, then
# fall back to the working directory.
script_path <- sub("^--file=", "",
                   grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)[1])
root <- if (!is.na(script_path) && nzchar(script_path)) {
  normalizePath(file.path(dirname(script_path), ".."), mustWork = FALSE)
} else {
  normalizePath(getwd(), mustWork = FALSE)
}
# Final fallback: if appfun/ isn't under the detected root, use the cwd.
if (!dir.exists(file.path(root, "appfun"))) root <- normalizePath(getwd(), mustWork = FALSE)

files <- c(
  file.path(root, "app.R"),
  list.files(file.path(root, "appfun"), pattern = "\\.R$", full.names = TRUE)
)
files <- files[file.exists(files)]

cat(sprintf("Parsing %d R file(s)...\n", length(files)))

failures <- character(0)
for (f in files) {
  rel <- sub(paste0("^", root, "/?"), "", f)
  res <- tryCatch({
    parse(file = f)
    cat(sprintf("  ok    %s\n", rel))
    TRUE
  }, error = function(e) {
    cat(sprintf("  FAIL  %s: %s\n", rel, conditionMessage(e)))
    FALSE
  })
  if (!isTRUE(res)) failures <- c(failures, rel)
}

if (length(failures) > 0) {
  cat(sprintf("\n%d file(s) failed to parse.\n", length(failures)))
  quit(status = 1)
}

cat("\nAll files parsed successfully.\n")
