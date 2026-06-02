# Activate renv for LOCAL reproducible development -- but only if renv is
# installed and an activate script exists. This is deliberately defensive so it
# never interferes with Posit Connect Cloud (which builds from manifest.json,
# not renv) or with a plain `shiny::runApp()` on a machine without renv.
local({
  activate <- file.path("renv", "activate.R")
  if (file.exists(activate) && requireNamespace("renv", quietly = TRUE)) {
    source(activate)
  }
})
