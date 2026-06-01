#!/bin/bash
# SessionStart hook for Claude Code on the web.
#
# Installs R and the Shiny app's CRAN dependencies (as Ubuntu apt binaries,
# which are pre-compiled and cached with the container) plus `lintr`, so that
# web sessions can statically parse and lint the R sources. This closes the gap
# where the app's R code otherwise can't be checked at all in the container.
#
# NOTE: `duckdb` is intentionally NOT installed -- it has no apt binary and
# compiling it from source is very heavy. The parse/lint checks below do not
# need it (they don't load packages), and the production app runs on Posit
# Connect Cloud, not here. Run scripts/setup_duckdb.sh by hand if you ever need
# to actually boot the app in a session.
set -euo pipefail

# Only do this in the remote (web) environment; never touch a contributor's
# local machine / RStudio setup.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive

# Refresh package lists (cheap, idempotent) then install. apt is a no-op for
# anything already present, so re-running the hook is safe and fast.
#
# Some base container images ship third-party PPAs (e.g. deadsnakes, ondrej/php)
# that can 403 / fail to verify. Those are unrelated to the R packages we need
# from the main Ubuntu archive, so we tolerate a non-zero `update` exit: the
# main archive lists still refresh and the install below pulls from them.
apt-get update -qq || echo "apt-get update reported errors (likely unrelated PPAs); continuing"

apt-get install -y --no-install-recommends \
  r-base-core \
  r-cran-lintr \
  r-cran-shiny \
  r-cran-shinydashboard \
  r-cran-dt \
  r-cran-dbi \
  r-cran-httr \
  r-cran-xml2 \
  r-cran-jsonlite \
  r-cran-dplyr \
  r-cran-tidyr \
  r-cran-stringr \
  r-cran-lubridate \
  >/dev/null

echo "R toolchain ready: $(R --version | head -n1)"
echo "Lint:  Rscript -e 'lintr::lint(\"app.R\")'"
echo "Smoke: Rscript tests/parse_check.R"
