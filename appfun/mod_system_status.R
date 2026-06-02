# ============================================================================
# Shiny module: System Status  (demonstrates NS / moduleServer pattern)
# ============================================================================
# A fully self-contained, namespaced module. It is ADDITIVE -- it introduces no
# new inputs/outputs into the existing tabs and therefore cannot affect any
# table field. It surfaces the startup data validation and the runtime
# configuration (NCBI identification, optional packages) so you can see at a
# glance that the "good citizen" and resilience features are active.

# ---- UI ----
systemStatusUI <- function(id) {
  ns <- NS(id)
  tabItem(
    tabName = id,
    fluidRow(
      box(
        title = "Data Integrity", status = "info", solidHeader = TRUE,
        width = 12,
        actionButton(ns("recheck"), "Re-check SJR data file",
                     class = "btn-primary"),
        br(), br(),
        verbatimTextOutput(ns("data_status"))
      )
    ),
    fluidRow(
      box(
        title = "Runtime Configuration", status = "info", solidHeader = TRUE,
        width = 12,
        verbatimTextOutput(ns("runtime_config"))
      )
    )
  )
}

# ---- Server ----
systemStatusServer <- function(id) {
  moduleServer(id, function(input, output, session) {
    data_status <- reactive({
      input$recheck # re-run when button pressed
      validate_sjr_file()
    })

    output$data_status <- renderText({
      v <- data_status()
      mark <- switch(v$level, ok = "OK  ", warning = "WARN", error = "FAIL")
      paste0("[", mark, "] ", v$message)
    })

    output$runtime_config <- renderText({
      has_pkg <- function(p) {
        if (requireNamespace(p, quietly = TRUE)) "available" else "not installed"
      }
      paste0(
        "NCBI identification (good-citizen):\n",
        "  tool   : ", NCBI_TOOL, "\n",
        "  email  : ", if (nzchar(NCBI_EMAIL)) NCBI_EMAIL else
          "(unset -- set NCBI_EMAIL)", "\n",
        "  api_key: ", if (nzchar(NCBI_API_KEY)) "set (10 req/s)" else
          "(unset -- 3 req/s)", "\n\n",
        "Optional packages:\n",
        "  httr::RETRY     : ",
        if (exists("RETRY", where = asNamespace('httr'),
                   inherits = FALSE)) "available" else "not available", "\n",
        "  memoise (cache) : ", has_pkg("memoise"), "\n",
        "  waiter (spinner): ", has_pkg("waiter"), "\n",
        "  future (async)  : ", has_pkg("future"), "\n",
        "  promises (async): ", has_pkg("promises")
      )
    })
  })
}
