library(shiny)
library(shinydashboard)
library(xml2)
library(httr)
library(jsonlite)
library(dplyr)
library(tidyr)
library(stringr)
library(DT)
library(lubridate)
library(duckdb)
library(DBI)

# Optional packages (graceful if absent): waiter (loading spinners),
# memoise (DOAJ cache). Async (future/promises) is opt-in via USE_ASYNC below.
HAS_WAITER <- requireNamespace("waiter", quietly = TRUE)
if (HAS_WAITER) library(waiter)

# ============================================================================
# Modular sources (see appfun/). Field-producing logic is extracted VERBATIM
# from the original monolithic app; see README "Architecture" for the map.
# ============================================================================
# Resolve the app directory so sourcing works under Connect Cloud and locally.
.app_dir <- tryCatch(dirname(sys.frame(1)$ofile), error = function(e) NULL)
if (is.null(.app_dir) || !nzchar(.app_dir)) .app_dir <- getwd()
.src <- function(f) source(file.path(.app_dir, "appfun", f), local = FALSE)

.src("fct_api.R")          # PubMed + DOAJ (RETRY, NCBI id, memoise cache)
.src("fct_helpers.R")      # jri_institutes + helper functions (verbatim)
.src("fct_pubmed_parse.R") # XML parsing -> all table fields (verbatim)
.src("fct_sjr.R")          # SJR data file + DuckDB query (verbatim)
.src("fct_pipeline.R")     # search pipeline -> rv (verbatim body)
.src("fct_validate.R")     # startup integrity validation
.src("fct_analytics.R")    # Analytics tab summaries (pure helpers)
.src("mod_system_status.R")# NS/moduleServer demo module (additive)

# Startup integrity check: warn if no data file; stop only if present-but-corrupt.
assert_sjr_or_warn()

# ============================================================================
# Shiny UI
# ============================================================================

ui <- dashboardPage(
  dashboardHeader(title = "NHCS PubMed Tracker"),

  dashboardSidebar(
    sidebarMenu(
      menuItem("Search PubMed", tabName = "search", icon = icon("search")),
      menuItem("Results", tabName = "results", icon = icon("table")),
      menuItem("Analytics", tabName = "analytics", icon = icon("chart-bar")),
      menuItem("Debug SJR", tabName = "debug", icon = icon("bug")),
      menuItem("About", tabName = "about", icon = icon("info-circle")),
      menuItem("System Status", tabName = "system_status", icon = icon("heartbeat"))
    )
  ),

  dashboardBody(
    if (HAS_WAITER) waiter::useWaiter(),
    tags$head(
      tags$style(HTML(
        "
        .content-wrapper {
          background-color: #f4f6f9;
        }
        .box {
          border-radius: 10px;
          box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .btn-primary {
          background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
          border: none;
        }
        .btn-primary:hover {
          background: linear-gradient(135deg, #5a6fd6 0%, #6a4190 100%);
        }
        .query-display {
          background-color: #e8f4f8;
          padding: 15px;
          border-radius: 8px;
          border-left: 4px solid #17a2b8;
          font-family: monospace;
          margin: 10px 0;
          word-wrap: break-word;
        }
        .info-box {
          border-radius: 10px;
        }
        .progress-text {
          font-style: italic;
          color: #666;
          padding: 10px;
          background-color: #fff3cd;
          border-radius: 5px;
          margin-top: 10px;
        }
        .btn-success {
          background: linear-gradient(135deg, #28a745 0%, #20c997 100%);
          border: none;
        }
      "
      ))
    ),

    tabItems(
      # Search Tab
      tabItem(
        tabName = "search",
        fluidRow(
          box(
            title = "Search Parameters",
            status = "primary",
            solidHeader = TRUE,
            width = 12,

            # Query Mode Selection
            radioButtons(
              "query_mode",
              "Query Mode:",
              choices = c(
                "Date Range Query" = "date_range",
                "Custom Query" = "custom"
              ),
              selected = "date_range",
              inline = TRUE
            ),

            hr(),

            # Date Range Query Panel
            conditionalPanel(
              condition = "input.query_mode == 'date_range'",

              fluidRow(
                column(
                  6,
                  textInput(
                    "query_term",
                    "Additional Query Term (optional):",
                    placeholder = "e.g., cardiovascular OR heart failure"
                  )
                ),
                column(
                  3,
                  dateInput(
                    "start_date",
                    "Start Date:",
                    value = floor_date(Sys.Date(), "month"),
                    format = "yyyy-mm-dd",
                    startview = "month",
                    weekstart = 0
                  )
                ),
                column(
                  3,
                  dateInput(
                    "end_date",
                    "End Date:",
                    value = Sys.Date(),
                    format = "yyyy-mm-dd",
                    startview = "month",
                    weekstart = 0
                  )
                )
              ),

              br(),

              h4("Base Query (always included):"),
              div(
                class = "query-display",
                '"national heart center singapore"[ad] OR "national heart centre singapore"[ad]'
              ),

              h4("Finalized Query:"),
              verbatimTextOutput("final_query")
            ),

            # Custom Query Panel
            conditionalPanel(
              condition = "input.query_mode == 'custom'",

              h4("Enter Your Custom PubMed Query:"),
              p(
                "You can enter any valid PubMed query. Use standard PubMed search syntax.",
                style = "color: #666; font-size: 12px;"
              ),

              textAreaInput(
                "custom_query",
                label = NULL,
                placeholder = 'e.g., "national heart centre singapore"[ad] AND "2024/01/01"[dp] : "2024/12/31"[dp]',
                width = "100%",
                height = "100px",
                rows = 4
              ),

              h4("Query to be executed:"),
              verbatimTextOutput("custom_query_display")
            ),

            hr(),

            actionButton(
              "search_btn",
              "Search PubMed",
              class = "btn-primary btn-lg",
              icon = icon("search")
            ),

            br(),
            br(),

            uiOutput("progress_ui")
          )
        ),

        fluidRow(
          infoBoxOutput("total_records", width = 4),
          infoBoxOutput("nhcs_authors", width = 4),
          infoBoxOutput("unique_articles", width = 4)
        )
      ),

      # Results Tab
      tabItem(
        tabName = "results",
        fluidRow(
          box(
            title = "NHCS Publication Records with Open Access & SJR Status (Author-Level)",
            status = "primary",
            solidHeader = TRUE,
            width = 12,

            downloadButton(
              "download_combined",
              "Download Results (CSV)",
              class = "btn-success"
            ),
            br(),
            br(),
            DTOutput("combined_table")
          )
        ),

        fluidRow(
          box(
            title = "NHCS Publication Records (Article-Level - Collapsed)",
            status = "success",
            solidHeader = TRUE,
            width = 12,
            collapsible = TRUE,
            collapsed = FALSE,

            p(
              "This table collapses multiple NHCS authors per article into a single row. NHCS Authors, Author Statuses, and Affiliations are combined with semicolons/pipes."
            ),
            downloadButton(
              "download_collapsed",
              "Download Collapsed Results (CSV)",
              class = "btn-success"
            ),
            br(),
            br(),
            DTOutput("collapsed_table")
          )
        ),

        fluidRow(
          box(
            title = "SJR Journal Rankings Data (Reference Table)",
            status = "info",
            solidHeader = TRUE,
            width = 12,
            collapsible = TRUE,
            collapsed = TRUE,

            p(
              "This table shows the SJR journal rankings data that was loaded. Use this to verify the data source is working correctly."
            ),
            verbatimTextOutput("sjr_status"),
            br(),
            DTOutput("sjr_table")
          )
        )
      ),

      # Analytics Tab
      tabItem(
        tabName = "analytics",
        fluidRow(
          valueBoxOutput("kpi_pubs", width = 3),
          valueBoxOutput("kpi_oa", width = 3),
          valueBoxOutput("kpi_q1", width = 3),
          valueBoxOutput("kpi_depts", width = 3)
        ),
        fluidRow(
          box(
            title = "Publications by year", status = "primary",
            solidHeader = TRUE, width = 6,
            plotOutput("plot_year", height = 300)
          ),
          box(
            title = "Journal quartile (Q1-Q4)", status = "info",
            solidHeader = TRUE, width = 6,
            plotOutput("plot_quartile", height = 300)
          )
        ),
        fluidRow(
          box(
            title = "Open Access", status = "success",
            solidHeader = TRUE, width = 6,
            plotOutput("plot_oa", height = 300)
          ),
          box(
            title = "Top departments", status = "warning",
            solidHeader = TRUE, width = 6,
            plotOutput("plot_dept", height = 320)
          )
        ),
        fluidRow(
          box(
            title = "Summary export", status = "primary",
            solidHeader = TRUE, width = 12,
            p(
              "A tidy summary (counts by year, Open Access, journal quartile, ",
              "and department) for your poster or report. Charts above update ",
              "after each search."
            ),
            downloadButton(
              "download_summary", "Download Summary (CSV)",
              class = "btn-success"
            )
          )
        )
      ),

      # Debug Tab
      tabItem(
        tabName = "debug",
        fluidRow(
          box(
            title = "DuckDB Parquet Test",
            status = "info",
            solidHeader = TRUE,
            width = 12,
            collapsible = TRUE,
            collapsed = FALSE,
            
            p("Test if DuckDB can load and query the local bundled SJR data file (data/sjr_all.csv.gz)."),
            actionButton("test_duckdb", "Test DuckDB Connection", class = "btn-primary"),
            br(),
            br(),
            verbatimTextOutput("duckdb_test_result")
          )
        ),
        
        fluidRow(
          box(
            title = "SJR Join Debug Information",
            status = "warning",
            solidHeader = TRUE,
            width = 12,

            h4("Debug Summary"),
            verbatimTextOutput("debug_summary"),

            hr(),

            h4("SJR Filtered Table (filtered to relevant ISSNs)"),
            p(
              "This shows the SJR data after separating rows by ISSN and filtering to only ISSNs present in your publications."
            ),
            DTOutput("debug_sjr_filtered"),

            hr(),

            h4(
              "Sample of combined_df (first 20 rows with issn_rev and pub_year)"
            ),
            DTOutput("debug_combined_sample"),

            hr(),

            h4("Sample of SJR Separated (first 50 rows)"),
            p(
              "This shows the SJR data after separating comma-delimited ISSNs into individual rows."
            ),
            DTOutput("debug_sjr_separated")
          )
        )
      ),

      # About Tab
      tabItem(
        tabName = "about",
        fluidRow(
          box(
            title = "About This Application",
            status = "primary",
            solidHeader = TRUE,
            width = 12,

            h4("NHCS PubMed Article Tracker"),
            p(
              "This application searches PubMed for articles affiliated with the National Heart Centre Singapore (NHCS) and extracts detailed publication information."
            ),

            h4("Features:"),
            tags$ul(
              tags$li("Search PubMed by date range or custom query"),
              tags$li(
                "Extract author information and affiliations (supports multiple affiliations per author)"
              ),
              tags$li(
                "Identify NHCS-affiliated authors and their positions in authorship"
              ),
              tags$li("List authors with Duke-NUS Medical School affiliations"),
              tags$li(
                "Identify SingHealth Duke-NUS Joint Research Institute (JRI) affiliations"
              ),
              tags$li(
                "Extract department/unit information from NHCS affiliations"
              ),
              tags$li(
                "Calculate Financial Year based on publication date (FY starts April)"
              ),
              tags$li("Query DOAJ for Open Access status"),
              tags$li(
                "Generate Open Access status (Yes/No) based on journal OA start date"
              ),
              tags$li(
                "Fetch SJR journal rankings including rank, SJR score, quartile, H-index, and annual rank percentile"
              )
            ),

            h4("JRI Institutes Tracked (effective 2023):"),
            tags$ul(
              tags$li("Artificial Intelligence in Medicine Institute (AIMI)"),
              tags$li("Health Services Research Institute (HSRI)"),
              tags$li("Infectious Diseases Research Institute (IDRI)"),
              tags$li(
                "SingHealth Duke-NUS Institute of Precision Medicine (PRISM)"
              ),
              tags$li("Translational Immunology Institute (TII)"),
              tags$li(
                "National Cancer Research Institute of Singapore (NCRIS)"
              ),
              tags$li("National Dental Research Institute Singapore (NDRIS)"),
              tags$li("National Heart Research Institute Singapore (NHRIS)"),
              tags$li(
                "National Neuroscience Research Institute Singapore (NNRIS)"
              ),
              tags$li("Institute of Biodiversity Medicine (BD-MED)")
            ),

            h4("Data Sources:"),
            tags$ul(
              tags$li("PubMed via NCBI E-utilities API (direct)"),
              tags$li("Directory of Open Access Journals (DOAJ) API v4"),
              tags$li(
                "SCImago Journal & Country Rank (SJR) data downloaded directly from scimagojr.com for all years (1999 to current), stored as this project's own combined data file (data/sjr_all.csv.gz) and refreshed from a phone via Termux"
              )
            ),

            h4("Technical Notes:"),
            tags$ul(
              tags$li(
                "This app uses NCBI E-utilities API directly instead of R packages for maximum compatibility"
              ),
              tags$li("Rate limiting is applied to respect API guidelines"),
              tags$li("Maximum 1000 articles per search (NCBI limit)"),
              tags$li(
                "SJR rankings are matched to each publication by ISSN and publication year across all available years (1999 to current)"
              ),
              tags$li(
                "The SJR parquet is owned by this repository and rebuilt monthly by a GitHub Actions workflow (.github/workflows/update-sjr.yml)"
              )
            )
          )
        )
      ),

      # System Status tab (NS/moduleServer module -- additive)
      systemStatusUI("system_status")
    )
  )
)

# ============================================================================
# Shiny Server
# ============================================================================

server <- function(input, output, session) {
  rv <- reactiveValues(
    results_df = NULL,
    oa_df = NULL,
    sjr_df = NULL,
    combined_df = NULL,
    search_complete = FALSE,
    progress_message = ""
  )

  # Generate finalized query display for date range mode
  output$final_query <- renderText({
    req(input$start_date, input$end_date)

    base_query <- '"national heart center singapore"[ad] OR "national heart centre singapore"[ad]'

    # Format dates for PubMed query (YYYY/MM/DD format)
    # Using [dp] (date of publication) to search by publication date
    start_formatted <- format(input$start_date, "%Y/%m/%d")
    end_formatted <- format(input$end_date, "%Y/%m/%d")
    date_filter <- paste0(
      '"',
      start_formatted,
      '"[dp] : "',
      end_formatted,
      '"[dp]'
    )

    if (nchar(trimws(input$query_term)) > 0) {
      full_query <- paste0(
        "(",
        base_query,
        ") AND (",
        input$query_term,
        ") AND (",
        date_filter,
        ")"
      )
    } else {
      full_query <- paste0("(", base_query, ") AND (", date_filter, ")")
    }

    full_query
  })

  # Display custom query
  output$custom_query_display <- renderText({
    if (nchar(trimws(input$custom_query)) > 0) {
      input$custom_query
    } else {
      "(No query entered)"
    }
  })

  # Progress UI
  output$progress_ui <- renderUI({
    if (nchar(rv$progress_message) > 0) {
      div(
        class = "progress-text",
        icon("spinner", class = "fa-spin"),
        " ",
        rv$progress_message
      )
    }
  })

  # Search action
  observeEvent(input$search_btn, {
    # Build query based on mode
    if (input$query_mode == "date_range") {
      req(input$start_date, input$end_date)

      # Validate date range
      if (input$end_date < input$start_date) {
        showNotification("End date must be after start date.", type = "error")
        return()
      }

      base_query <- '"national heart center singapore"[ad] OR "national heart centre singapore"[ad]'

      # Format dates for PubMed query
      # Using [dp] (date of publication) to search by publication date
      start_formatted <- format(input$start_date, "%Y/%m/%d")
      end_formatted <- format(input$end_date, "%Y/%m/%d")
      date_filter <- paste0(
        '"',
        start_formatted,
        '"[dp] : "',
        end_formatted,
        '"[dp]'
      )

      if (nchar(trimws(input$query_term)) > 0) {
        full_query <- paste0(
          "(",
          base_query,
          ") AND (",
          input$query_term,
          ") AND (",
          date_filter,
          ")"
        )
      } else {
        full_query <- paste0("(", base_query, ") AND (", date_filter, ")")
      }
    } else {
      # Custom query mode
      req(input$custom_query)

      if (nchar(trimws(input$custom_query)) == 0) {
        showNotification("Please enter a custom query.", type = "error")
        return()
      }

      full_query <- trimws(input$custom_query)
    }

    rv$progress_message <- "Searching PubMed..."
    rv$search_complete <- FALSE

    # Visual feedback while the (synchronous) pipeline runs. The pipeline itself
    # uses withProgress() internally exactly as before; waiter adds a full-screen
    # spinner so the user sees an immediate "working" state. No-op if waiter
    # isn't installed.
    if (HAS_WAITER) {
      w <- waiter::Waiter$new(
        html = tagList(waiter::spin_3(),
                       br(), "Searching PubMed, DOAJ and SJR ..."),
        color = "rgba(40,44,52,0.85)"
      )
      w$show()
      on.exit(w$hide(), add = TRUE)
    }

    # Run the verbatim search pipeline (writes all table fields into rv).
    run_search_pipeline(full_query, rv)
  })

  # Info boxes
  output$total_records <- renderInfoBox({
    count <- ifelse(is.null(rv$results_df), 0, nrow(rv$results_df))
    infoBox(
      "Total Records",
      count,
      icon = icon("file-alt"),
      color = "blue"
    )
  })

  output$nhcs_authors <- renderInfoBox({
    count <- ifelse(
      is.null(rv$results_df),
      0,
      length(unique(rv$results_df$NHCS_Author))
    )
    infoBox(
      "Unique NHCS Authors",
      count,
      icon = icon("user-md"),
      color = "green"
    )
  })

  output$unique_articles <- renderInfoBox({
    count <- ifelse(
      is.null(rv$results_df),
      0,
      length(unique(rv$results_df$PMID))
    )
    infoBox(
      "Unique Articles",
      count,
      icon = icon("newspaper"),
      color = "yellow"
    )
  })

  # Combined data table
  output$combined_table <- renderDT({
    req(rv$combined_df)

    datatable(
      rv$combined_df,
      options = list(
        pageLength = 25,
        scrollX = TRUE,
        dom = 'Bfrtip',
        buttons = c('copy', 'csv', 'excel')
      ),
      extensions = 'Buttons',
      rownames = FALSE
    )
  })

  # Collapsed article-level data table
  output$collapsed_table <- renderDT({
    req(rv$collapsed_df)

    datatable(
      rv$collapsed_df,
      options = list(
        pageLength = 25,
        scrollX = TRUE,
        dom = 'Bfrtip',
        buttons = c('copy', 'csv', 'excel')
      ),
      extensions = 'Buttons',
      rownames = FALSE
    )
  })

  # --------------------------------------------------------------------------
  # Analytics tab: KPI cards + charts from the article-level (collapsed) table.
  # --------------------------------------------------------------------------
  analytics_data <- reactive({
    req(rv$collapsed_df)
    rv$collapsed_df
  })

  # Empty-safe base-R barplot helper (no extra package dependency).
  bar_or_msg <- function(tb, col = "#3c8dbc", horiz = FALSE, las = 1, ...) {
    if (is.null(tb) || !length(tb) || sum(tb) == 0) {
      plot.new()
      text(0.5, 0.5, "No data yet - run a search.", col = "grey40")
      return(invisible())
    }
    op <- par(mar = if (horiz) c(4, 11, 1, 1) else c(5, 4, 1, 1))
    on.exit(par(op), add = TRUE)
    bp <- barplot(tb, col = col, border = NA, horiz = horiz, las = las, ...)
    if (!horiz) text(bp, tb, labels = tb, pos = 3, xpd = TRUE, cex = 0.9)
    invisible(bp)
  }

  output$kpi_pubs <- shinydashboard::renderValueBox({
    shinydashboard::valueBox(
      analytics_kpis(analytics_data())$n_pubs, "Publications",
      icon = icon("file-lines"), color = "aqua"
    )
  })
  output$kpi_oa <- shinydashboard::renderValueBox({
    shinydashboard::valueBox(
      paste0(analytics_kpis(analytics_data())$pct_oa, "%"), "Open Access",
      icon = icon("unlock"), color = "green"
    )
  })
  output$kpi_q1 <- shinydashboard::renderValueBox({
    shinydashboard::valueBox(
      paste0(analytics_kpis(analytics_data())$pct_q1, "%"), "Q1 journals",
      icon = icon("trophy"), color = "yellow"
    )
  })
  output$kpi_depts <- shinydashboard::renderValueBox({
    shinydashboard::valueBox(
      analytics_kpis(analytics_data())$n_depts, "Departments",
      icon = icon("sitemap"), color = "purple"
    )
  })

  output$plot_year <- renderPlot(
    bar_or_msg(year_counts(analytics_data()), col = "#3c8dbc")
  )
  output$plot_quartile <- renderPlot(
    bar_or_msg(
      quartile_counts(analytics_data()),
      col = c("#1a9850", "#91cf60", "#fee08b", "#fc8d59", "#bdbdbd")
    )
  )
  output$plot_oa <- renderPlot(
    bar_or_msg(oa_counts(analytics_data()), col = c("#1a9850", "#bdbdbd"))
  )
  output$plot_dept <- renderPlot(
    bar_or_msg(
      rev(dept_counts(analytics_data(), top = 10)),
      col = "#dd8f3c", horiz = TRUE
    )
  )

  output$download_summary <- downloadHandler(
    filename = function() paste0("nhcs_pubmed_summary_", Sys.Date(), ".csv"),
    content = function(file) {
      write.csv(analytics_summary_long(analytics_data()), file, row.names = FALSE)
    }
  )

  # SJR status output
  output$sjr_status <- renderText({
    if (is.null(rv$sjr_df)) {
      "SJR data not yet loaded. Run a search to load the data."
    } else {
      # Report the actual span of years present in the matched SJR data
      year_range <- if ("year" %in% names(rv$sjr_df) && nrow(rv$sjr_df) > 0) {
        yrs <- suppressWarnings(as.integer(rv$sjr_df$year))
        yrs <- yrs[!is.na(yrs)]
        if (length(yrs) > 0) {
          paste0(min(yrs), " - ", max(yrs))
        } else {
          "unknown"
        }
      } else {
        "unknown"
      }
      paste0(
        "✓ SJR data loaded successfully (source: SCImago, your own data file)!\n",
        "  - Source file: ",
        ifelse(is.na(resolve_sjr_path()), SJR_DATA_PATH, resolve_sjr_path()),
        "\n",
        "  - Years covered (matched rows): ",
        year_range,
        "\n",
        "  - Total matched rows: ",
        format(nrow(rv$sjr_df), big.mark = ","),
        "\n",
        "  - Columns: ",
        paste(names(rv$sjr_df), collapse = ", ")
      )
    }
  })

  # SJR data table
  output$sjr_table <- renderDT({
    req(rv$sjr_df)

    # Show first 100 rows as a sample
    sample_df <- head(rv$sjr_df, 100)

    datatable(
      sample_df,
      caption = "Showing first 100 journals (sorted by rank)",
      options = list(
        pageLength = 10,
        scrollX = TRUE
      ),
      rownames = FALSE
    )
  })

  # DuckDB Test Handler
  rv$duckdb_test_result <- NULL
  
  observeEvent(input$test_duckdb, {
    rv$duckdb_test_result <- tryCatch({
      results <- list()
      
      # Step 1: Locate the bundled combined SJR data file (parquet or csv.gz)
      temp_file <- resolve_sjr_path()
      results$path <- if (is.na(temp_file)) "(none found)" else temp_file
      results$step1 <- paste0("✓ Looking for local SJR data file: ",
                              paste(SJR_DATA_CANDIDATES, collapse = " or "))

      # Step 2: Check the file exists and looks valid
      if (is.na(temp_file) || !file.exists(temp_file)) {
        results$step2 <- paste0(
          "✗ File not found (looked for ",
          paste(SJR_DATA_CANDIDATES, collapse = ", "),
          ") - run scripts/refresh_sjr.py (Termux) to download and commit it."
        )
        return(paste(unlist(results), collapse = "\n"))
      }

      file_size <- file.size(temp_file)
      results$step2 <- paste0("✓ File found: ", format(file_size, big.mark = ","), " bytes")

      if (file_size < 1000) {
        results$step2b <- "✗ File too small - likely incomplete or empty"
        return(paste(unlist(results), collapse = "\n"))
      }

      # Step 3: Connect to DuckDB
      con <- tryCatch({
        dbConnect(duckdb::duckdb())
      }, error = function(e) {
        results$duckdb_error <<- e$message
        NULL
      })
      
      if (is.null(con)) {
        results$step3 <- paste0("✗ DuckDB connection failed: ", results$duckdb_error)
        return(paste(unlist(results), collapse = "\n"))
      }
      results$step3 <- "✓ DuckDB connection established"
      
      # Step 4: Count rows in the SJR file
      temp_file_clean <- gsub("\\\\", "/", temp_file)
      sjr_src <- sjr_duckdb_source(temp_file_clean)
      count_query <- paste0("SELECT COUNT(*) as cnt FROM ", sjr_src)
      
      row_count <- tryCatch({
        dbGetQuery(con, count_query)$cnt
      }, error = function(e) {
        results$count_error <<- e$message
        NULL
      })
      
      if (is.null(row_count)) {
        results$step4 <- paste0("✗ Count query failed: ", results$count_error)
        dbDisconnect(con, shutdown = TRUE)
        return(paste(unlist(results), collapse = "\n"))
      }
      results$step4 <- paste0("✓ Total rows in parquet: ", format(row_count, big.mark = ","))
      
      # Step 5: Get column names
      schema_query <- paste0("DESCRIBE SELECT * FROM ", sjr_src)
      schema <- tryCatch({
        dbGetQuery(con, schema_query)
      }, error = function(e) {
        results$schema_error <<- e$message
        NULL
      })
      
      if (!is.null(schema)) {
        results$step5 <- paste0("✓ Columns: ", paste(schema$column_name, collapse = ", "))
      } else {
        results$step5 <- paste0("✗ Schema query failed: ", results$schema_error)
      }
      
      # Step 6: Sample ISSN values
      issn_query <- paste0("SELECT DISTINCT issn FROM ", sjr_src, " WHERE issn IS NOT NULL LIMIT 5")
      issn_sample <- tryCatch({
        dbGetQuery(con, issn_query)
      }, error = function(e) {
        results$issn_error <<- e$message
        NULL
      })
      
      if (!is.null(issn_sample) && nrow(issn_sample) > 0) {
        results$step6 <- paste0("✓ Sample ISSNs: ", paste(issn_sample$issn, collapse = ", "))
      } else {
        results$step6 <- paste0("✗ ISSN sample failed: ", results$issn_error)
      }
      
      # Step 7: Test LIKE query with a known ISSN (Circulation: 00097322 - no hyphens)
      like_query <- paste0("SELECT COUNT(*) as cnt FROM ", sjr_src, " WHERE issn LIKE '%00097322%'")
      like_result <- tryCatch({
        dbGetQuery(con, like_query)$cnt
      }, error = function(e) {
        results$like_error <<- e$message
        NULL
      })
      
      if (!is.null(like_result)) {
        results$step7 <- paste0("✓ LIKE query for '00097322' (Circulation) returned ", like_result, " rows")
      } else {
        results$step7 <- paste0("✗ LIKE query failed: ", results$like_error)
      }
      
      # Cleanup (do NOT delete the bundled parquet)
      dbDisconnect(con, shutdown = TRUE)

      results$final <- "\n=== Test Complete ==="
      
      paste(unlist(results), collapse = "\n")
      
    }, error = function(e) {
      paste0("Error during test: ", e$message)
    })
  })
  
  output$duckdb_test_result <- renderText({
    if (is.null(rv$duckdb_test_result)) {
      "Click 'Test DuckDB Connection' to run the test."
    } else {
      rv$duckdb_test_result
    }
  })

  # Debug outputs
  output$debug_summary <- renderText({
    paste0(
      "=== Debug Summary ===\n",
      "sjr_df loaded: ",
      !is.null(rv$sjr_df),
      "\n",
      "sjr_separated rows: ",
      ifelse(!is.null(rv$sjr_separated), nrow(rv$sjr_separated), "NA"),
      "\n",
      "sjr_filtered rows: ",
      ifelse(!is.null(rv$sjr_filtered), nrow(rv$sjr_filtered), "NA"),
      "\n",
      "max_sjr_year: ",
      ifelse(!is.null(rv$max_sjr_year), rv$max_sjr_year, "NA"),
      "\n",
      "relevant_issns count: ",
      ifelse(!is.null(rv$relevant_issns), length(rv$relevant_issns), "NA"),
      "\n",
      "\n--- Sample relevant ISSNs ---\n",
      ifelse(
        !is.null(rv$relevant_issns),
        paste(head(rv$relevant_issns, 10), collapse = ", "),
        "NA"
      ),
      "\n",
      "\n--- sjr_filtered columns ---\n",
      ifelse(
        !is.null(rv$sjr_filtered),
        paste(names(rv$sjr_filtered), collapse = ", "),
        "NA"
      ),
      "\n",
      "\n--- sjr_separated columns ---\n",
      ifelse(
        !is.null(rv$sjr_separated),
        paste(names(rv$sjr_separated), collapse = ", "),
        "NA"
      )
    )
  })

  output$debug_sjr_filtered <- renderDT({
    req(rv$sjr_filtered)

    datatable(
      rv$sjr_filtered,
      caption = paste("SJR Filtered - Total rows:", nrow(rv$sjr_filtered)),
      options = list(
        pageLength = 25,
        scrollX = TRUE
      ),
      rownames = FALSE
    )
  })

  output$debug_combined_sample <- renderDT({
    req(rv$combined_df)

    # Show relevant columns for debugging
    sample_cols <- c(
      "PMID",
      "NHCS_Author",
      "Title",
      "ISSN",
      "issn_rev",
      "CY_Published_Reported"
    )
    available_cols <- intersect(sample_cols, names(rv$combined_df))

    sample_df <- rv$combined_df %>%
      select(all_of(available_cols)) %>%
      head(20)

    datatable(
      sample_df,
      caption = "Sample of combined_df (first 20 rows)",
      options = list(
        pageLength = 10,
        scrollX = TRUE
      ),
      rownames = FALSE
    )
  })

  output$debug_sjr_separated <- renderDT({
    req(rv$sjr_separated)

    sample_df <- head(rv$sjr_separated, 50)

    datatable(
      sample_df,
      caption = paste(
        "SJR Separated - Total rows:",
        nrow(rv$sjr_separated),
        "(showing first 50)"
      ),
      options = list(
        pageLength = 10,
        scrollX = TRUE
      ),
      rownames = FALSE
    )
  })

  # Download handler
  output$download_combined <- downloadHandler(
    filename = function() {
      timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
      if (input$query_mode == "date_range") {
        start_str <- format(input$start_date, "%Y%m%d")
        end_str <- format(input$end_date, "%Y%m%d")
        paste0(
          "NHCS_PubMed_Results_",
          start_str,
          "_to_",
          end_str,
          "_",
          timestamp,
          ".csv"
        )
      } else {
        paste0("NHCS_PubMed_Results_CustomQuery_", timestamp, ".csv")
      }
    },
    content = function(file) {
      req(rv$combined_df)
      write.csv(rv$combined_df, file, row.names = FALSE)
    }
  )

  # Download handler for collapsed article-level table
  output$download_collapsed <- downloadHandler(
    filename = function() {
      timestamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
      if (input$query_mode == "date_range") {
        start_str <- format(input$start_date, "%Y%m%d")
        end_str <- format(input$end_date, "%Y%m%d")
        paste0(
          "NHCS_PubMed_Results_Collapsed_",
          start_str,
          "_to_",
          end_str,
          "_",
          timestamp,
          ".csv"
        )
      } else {
        paste0("NHCS_PubMed_Results_Collapsed_CustomQuery_", timestamp, ".csv")
      }
    },
    content = function(file) {
      req(rv$collapsed_df)
      write.csv(rv$collapsed_df, file, row.names = FALSE)
    }
  )

  # Stop app when session ends
  # Note: Do NOT use stopApp() on shinyapps.io - it crashes the shared instance
  # session$onSessionEnded is not needed for cleanup on shinyapps.io

  # System Status module (NS/moduleServer)
  systemStatusServer("system_status")
}

# Run the app
shinyApp(ui = ui, server = server)
