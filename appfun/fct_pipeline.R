# ============================================================================
# Search pipeline (VERBATIM from original app.R) -- produces every table field
# ============================================================================
# run_search_pipeline(full_query, rv): runs the PubMed -> DOAJ -> SJR pipeline
# and writes results into the shared reactiveValues 'rv', exactly as the
# original monolithic observeEvent did. Field-producing code is unchanged.

run_search_pipeline <- function(full_query, rv) {
    withProgress(message = 'Processing...', value = 0, {
      tryCatch(
        {
          # Step 1: Search PubMed
          incProgress(0.1, detail = "Querying PubMed...")

          search_result <- search_pubmed(full_query)

          if (search_result$count == 0) {
            showNotification(
              "No articles found for this query.",
              type = "warning"
            )
            rv$progress_message <- ""
            return()
          }

          incProgress(
            0.2,
            detail = paste(
              "Found",
              search_result$count,
              "articles. Fetching records..."
            )
          )

          # Step 2: Fetch records
          Sys.sleep(0.5) # Rate limiting
          xml_data <- fetch_pubmed_records(search_result)

          incProgress(0.3, detail = "Parsing XML records...")

          # Step 3: Parse XML
          all_results <- parse_pubmed_xml(xml_data)

          if (length(all_results) == 0) {
            showNotification(
              "No NHCS-affiliated authors found in the results.",
              type = "warning"
            )
            rv$progress_message <- ""
            return()
          }

          incProgress(0.2, detail = "Building results table...")

          # Convert to data frame
          results_df <- bind_rows(lapply(
            all_results,
            as.data.frame,
            stringsAsFactors = FALSE
          ))
          
          rv$results_df <- results_df

          # Step 4: Fetch DOAJ data
          incProgress(0.1, detail = "Fetching DOAJ Open Access data...")

          unique_titles <- unique(results_df$Title)
          unique_titles <- unique_titles[!is.na(unique_titles)]

          oa_results <- list()
          n_titles <- length(unique_titles)

          for (i in seq_along(unique_titles)) {
            incProgress(
              0.03 / max(n_titles, 1),
              detail = paste("DOAJ lookup", i, "of", n_titles)
            )
            oa_results[[i]] <- fetch_doaj_oa_start(unique_titles[i])
            Sys.sleep(0.3) # Rate limiting for DOAJ
          }

          oa_df <- bind_rows(oa_results)
          rv$oa_df <- oa_df

          # Step 5: Locate the bundled combined SJR data file
          incProgress(0.05, detail = "Loading SJR journal ranking data...")

          sjr_parquet_info <- get_sjr_data()
          rv$sjr_parquet_path <- if(!is.null(sjr_parquet_info)) sjr_parquet_info$path else NULL

          # Step 6: Create combined table with Open Access field
          incProgress(
            0.05,
            detail = "Creating combined table with Open Access status..."
          )

          combined_df <- results_df %>%
            left_join(oa_df, by = c("Title" = "title")) %>%
            mutate(
              pub_year = as.numeric(CY_Published_Reported),
              oa_start_year = as.numeric(oa_start),
              Open_Access = case_when(
                is.na(oa_start) ~ "No",
                is.na(pub_year) ~ "No",
                pub_year >= oa_start_year ~ "Yes",
                pub_year < oa_start_year ~ "No",
                TRUE ~ "No"
              ),
              # Create issn_rev by removing hyphens from ISSN
              issn_rev = gsub("-", "", ISSN)
            ) %>%
            select(-oa_start_year)

          # Step 7: Query SJR data using DuckDB with LIKE for relevant ISSNs
          if (!is.null(sjr_parquet_info)) {
            incProgress(
              0.02,
              detail = "Querying SJR journal rankings using DuckDB..."
            )

            # Get unique issn_rev values from combined_df
            relevant_issns <- unique(combined_df$issn_rev[
              !is.na(combined_df$issn_rev) & combined_df$issn_rev != ""
            ])
            
            rv$relevant_issns <- relevant_issns
            message("Number of relevant ISSNs: ", length(relevant_issns))

            # Query SJR data using DuckDB with LIKE statements from local parquet file
            sjr_df <- query_sjr_with_duckdb(sjr_parquet_info$path, relevant_issns)
            rv$sjr_df <- sjr_df
            # NOTE: do NOT unlink the data file here -- it is the repo-bundled
            # data/sjr_all.csv.gz, not a throwaway temp file.

            if (!is.null(sjr_df) && nrow(sjr_df) > 0 && "issn" %in% names(sjr_df)) {
              incProgress(
                0.02,
                detail = "Joining with SJR journal rankings..."
              )

              # Separate SJR rows based on ISSN (split comma-separated ISSNs into separate rows)
              sjr_separated <- sjr_df %>%
                mutate(issn = as.character(issn)) %>%
                separate_rows(issn, sep = ",\\s*") %>%
                mutate(
                  issn = trimws(issn),
                  issn = gsub("-", "", issn), # Remove hyphens to match issn_rev format
                  year = as.numeric(year)
                ) %>%
                filter(!is.na(issn) & issn != "")

              # Get the max year available in SJR data
              max_sjr_year <- max(sjr_separated$year, na.rm = TRUE)

              # Filter SJR data to only relevant ISSNs
              sjr_filtered <- sjr_separated %>%
                filter(issn %in% relevant_issns)

              # Store for debugging
              rv$sjr_filtered <- sjr_filtered
              rv$sjr_separated <- sjr_separated
              rv$max_sjr_year <- max_sjr_year

              # Debug: Print structure info
              message("=== SJR Join Debug Info ===")
              message("sjr_df rows from DuckDB: ", nrow(sjr_df))
              message("sjr_separated rows: ", nrow(sjr_separated))
              message(
                "sjr_separated columns: ",
                paste(names(sjr_separated), collapse = ", ")
              )
              message("relevant_issns count: ", length(relevant_issns))
              message("sjr_filtered rows: ", nrow(sjr_filtered))
              message("max_sjr_year: ", max_sjr_year)

              # Prepare combined_df with adjusted pub_year for joining
              combined_for_join <- combined_df %>%
                mutate(
                  issn_rev = as.character(issn_rev),
                  pub_year = as.numeric(pub_year),
                  # Create adjusted pub_year: if pub_year > max SJR year, use max SJR year
                  adjusted_pub_year = ifelse(
                    pub_year > max_sjr_year,
                    max_sjr_year,
                    pub_year
                  )
                )

              # Perform left join from combined_df to filtered SJR table
              joined_df <- tryCatch(
                {
                  result <- combined_for_join %>%
                    left_join(
                      sjr_filtered,
                      by = c("issn_rev" = "issn", "adjusted_pub_year" = "year")
                    )
                  message("Join successful, rows: ", nrow(result))

                  # Clean up columns - rename only if columns exist
                  result <- result %>%
                    select(-pub_year, -adjusted_pub_year)

                  # Rename SJR columns if they exist
                  if ("rank" %in% names(result)) {
                    result <- result %>% rename(SJR_Rank = rank)
                  }
                  if ("sjr" %in% names(result)) {
                    result <- result %>% rename(SJR = sjr)
                  }
                  if ("sjr_best_quartile" %in% names(result)) {
                    result <- result %>%
                      rename(SJR_Best_Quartile = sjr_best_quartile)
                  }
                  if ("h_index" %in% names(result)) {
                    result <- result %>% rename(H_Index = h_index)
                  }
                  if ("citations_doc_2years" %in% names(result)) {
                    result <- result %>%
                      rename(`Citation_Doc_2Years(JIF)` = citations_doc_2years)
                  }
                  if ("annual_rank_percentile" %in% names(result)) {
                    result <- result %>%
                      rename(Annual_Rank_Percentile = annual_rank_percentile)
                  }

                  # Add SJR_ISSN column
                  result <- result %>% mutate(SJR_ISSN = issn_rev)

                  # Add JIF_Category based on Citation_Doc_2Years(JIF) values
                  if ("Citation_Doc_2Years(JIF)" %in% names(result)) {
                    result <- result %>%
                      mutate(
                        JIF_Category = case_when(
                          is.na(`Citation_Doc_2Years(JIF)`) ~ NA_character_,
                          `Citation_Doc_2Years(JIF)` >= 2 ~ "JIF>=2",
                          TRUE ~ "JIF<2"
                        )
                      )
                  } else {
                    result$JIF_Category <- NA_character_
                  }

                  # If SJR columns don't exist (empty join), add them as NA
                  if (!"SJR_Rank" %in% names(result)) {
                    result$SJR_Rank <- NA_integer_
                  }
                  if (!"SJR" %in% names(result)) {
                    result$SJR <- NA_real_
                  }
                  if (!"SJR_Best_Quartile" %in% names(result)) {
                    result$SJR_Best_Quartile <- NA_character_
                  }
                  if (!"H_Index" %in% names(result)) {
                    result$H_Index <- NA_integer_
                  }
                  if (!"Citation_Doc_2Years(JIF)" %in% names(result)) {
                    result$`Citation_Doc_2Years(JIF)` <- NA_real_
                  }
                  if (!"JIF_Category" %in% names(result)) {
                    result$JIF_Category <- NA_character_
                  }
                  if (!"Annual_Rank_Percentile" %in% names(result)) {
                    result$Annual_Rank_Percentile <- NA_character_
                  }

                  # Remove title column from SJR if it exists (conflicts with publication Title)
                  if ("title" %in% names(result)) {
                    result <- result %>% select(-title)
                  }

                  result
                },
                error = function(e) {
                  message("Error in left join: ", e$message)
                  showNotification(
                    paste("Debug - Join error:", e$message),
                    type = "error",
                    duration = 15
                  )
                  NULL
                }
              )

              if (!is.null(joined_df)) {
                combined_df <- joined_df
              } else {
                # Fallback if join fails
                combined_df <- combined_df %>%
                  select(-pub_year) %>%
                  mutate(
                    SJR_Rank = NA_integer_,
                    SJR = NA_real_,
                    SJR_Best_Quartile = NA_character_,
                    H_Index = NA_integer_,
                    `Citation_Doc_2Years(JIF)` = NA_real_,
                    JIF_Category = NA_character_,
                    Annual_Rank_Percentile = NA_character_,
                    SJR_ISSN = NA_character_
                  )
                showNotification(
                  "Left join on ISSN failed. SJR columns will be empty.",
                  type = "warning"
                )
              }
            } else {
              combined_df <- combined_df %>%
                select(-pub_year) %>%
                mutate(
                  SJR_Rank = NA_integer_,
                  SJR = NA_real_,
                  SJR_Best_Quartile = NA_character_,
                  H_Index = NA_integer_,
                  `Citation_Doc_2Years(JIF)` = NA_real_,
                  JIF_Category = NA_character_,
                  Annual_Rank_Percentile = NA_character_,
                  SJR_ISSN = NA_character_
                )
              showNotification(
                "DuckDB query returned no SJR data. SJR columns will be empty.",
                type = "warning"
              )
            }
          } else {
            combined_df <- combined_df %>%
              select(-pub_year) %>%
              mutate(
                SJR_Rank = NA_integer_,
                SJR = NA_real_,
                SJR_Best_Quartile = NA_character_,
                H_Index = NA_integer_,
                `Citation_Doc_2Years(JIF)` = NA_real_,
                JIF_Category = NA_character_,
                Annual_Rank_Percentile = NA_character_,
                SJR_ISSN = NA_character_
              )
            showNotification(
              "SJR parquet download failed. SJR columns will be empty.",
              type = "warning"
            )
          }

          rv$combined_df <- combined_df

          # Reorder columns to put JIF_Category after Citation_Doc_2Years(JIF)
          if (
            all(
              c("Citation_Doc_2Years(JIF)", "JIF_Category") %in%
                names(combined_df)
            )
          ) {
            # Get current column order
            cols <- names(combined_df)
            # Find position of Citation_Doc_2Years(JIF)
            jif_pos <- which(cols == "Citation_Doc_2Years(JIF)")
            # Remove JIF_Category from its current position
            cols <- cols[cols != "JIF_Category"]
            # Insert JIF_Category right after Citation_Doc_2Years(JIF)
            if (jif_pos < length(cols)) {
              cols <- c(
                cols[1:jif_pos],
                "JIF_Category",
                cols[(jif_pos + 1):length(cols)]
              )
            } else {
              cols <- c(cols, "JIF_Category")
            }
            combined_df <- combined_df %>% select(all_of(cols))
            rv$combined_df <- combined_df
          }

          # Create collapsed/article-level table
          # Group by PMID and collapse NHCS authors, affiliations, and author status
          collapsed_df <- combined_df %>%
            group_by(PMID) %>%
            summarise(
              NHCS_Authors = paste(unique(NHCS_Author), collapse = "; "),
              Author_Statuses = paste(unique(Author_Status), collapse = "; "),
              Affiliations_Combined = paste(
                unique(Affiliations_List),
                collapse = " | "
              ),
              # Keep first value for other columns (they should be same within PMID)
              Author_List = first(Author_List),
              Publications = first(Publications),
              Type_of_Publication = first(Type_of_Publication),
              Epub_Date = first(Epub_Date),
              Epub_Date_Formatted = first(Epub_Date_Formatted),
              Print_Date = first(Print_Date),
              Print_Date_Formatted = first(Print_Date_Formatted),
              Publication_Date = first(Publication_Date),
              Publication_Date_Formatted = first(Publication_Date_Formatted),
              CY_Published_Reported = first(CY_Published_Reported),
              Financial_Year_Reported = first(Financial_Year_Reported),
              Epub_Flag = first(Epub_Flag),
              Published_Month = first(Published_Month),
              DOI = first(DOI),
              ISSN = first(ISSN),
              Journal = first(Journal),
              Title = first(Title),
              Abbreviated_Title = first(Abbreviated_Title),
              PubMed_Link = first(PubMed_Link),
              Open_Access = first(Open_Access),
              Duke_NUS_Affiliation = first(Duke_NUS_Affiliation),
              JRI_Affiliation = first(JRI_Affiliation),
              Department = paste(unique(na.omit(Department)), collapse = "; "),
              SJR_Rank = first(SJR_Rank),
              SJR = first(SJR),
              SJR_Best_Quartile = first(SJR_Best_Quartile),
              H_Index = first(H_Index),
              `Citation_Doc_2Years(JIF)` = first(`Citation_Doc_2Years(JIF)`),
              JIF_Category = first(JIF_Category),
              Annual_Rank_Percentile = first(Annual_Rank_Percentile),
              SJR_ISSN = first(SJR_ISSN),
              .groups = "drop"
            ) %>%
            # Reorder columns to have key identifiers first
            select(
              PMID,
              Publications,
              NHCS_Authors,
              Author_Statuses,
              Author_List,
              Affiliations_Combined,
              Department,
              Duke_NUS_Affiliation,
              JRI_Affiliation,
              Type_of_Publication,
              Epub_Date,
              Epub_Date_Formatted,
              Print_Date,
              Print_Date_Formatted,
              Publication_Date,
              Publication_Date_Formatted,
              CY_Published_Reported,
              Financial_Year_Reported,
              Epub_Flag,
              Published_Month,
              DOI,
              ISSN,
              Journal,
              Title,
              Abbreviated_Title,
              PubMed_Link,
              Open_Access,
              SJR_Rank,
              SJR,
              SJR_Best_Quartile,
              H_Index,
              `Citation_Doc_2Years(JIF)`,
              JIF_Category,
              Annual_Rank_Percentile,
              SJR_ISSN
            )

          rv$collapsed_df <- collapsed_df

          rv$search_complete <- TRUE
          rv$progress_message <- ""

          showNotification(
            paste(
              "Success! Processed",
              nrow(results_df),
              "NHCS author records from",
              length(unique(results_df$PMID)),
              "articles."
            ),
            type = "message",
            duration = 5
          )
        },
        error = function(e) {
          showNotification(
            paste("Error:", e$message),
            type = "error",
            duration = 10
          )
          rv$progress_message <- ""
        }
      )
    })
}
