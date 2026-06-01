# ============================================================================
# XML Parsing Functions
# ============================================================================

# Function to parse a single PubMed article from XML node
parse_single_article <- function(article_node) {
  tryCatch(
    {
      # Extract PMID
      pmid <- safe_xml_text(xml_find_first(article_node, ".//PMID"))

      # Extract article title
      article_title <- safe_xml_text(xml_find_first(
        article_node,
        ".//ArticleTitle"
      ))

      # Extract authors and affiliations
      author_nodes <- xml_find_all(article_node, ".//Author")

      authors_list <- character(0)
      affiliations_list <- list()

      for (i in seq_along(author_nodes)) {
        author_node <- author_nodes[[i]]

        lastname <- safe_xml_text(xml_find_first(author_node, ".//LastName"))
        forename <- safe_xml_text(xml_find_first(author_node, ".//ForeName"))
        initials <- safe_xml_text(xml_find_first(author_node, ".//Initials"))

        if (!is.na(lastname)) {
          if (!is.na(forename)) {
            author_name <- paste(forename, lastname)
          } else if (!is.na(initials)) {
            author_name <- paste(initials, lastname)
          } else {
            author_name <- lastname
          }
          authors_list <- c(authors_list, author_name)

          # Get all affiliations for this author
          aff_nodes <- xml_find_all(
            author_node,
            ".//AffiliationInfo/Affiliation"
          )
          author_affs <- sapply(aff_nodes, xml_text)
          if (length(author_affs) == 0) {
            author_affs <- NA_character_
          }
          affiliations_list[[author_name]] <- author_affs
        }
      }

      # Extract publication types
      pub_type_nodes <- xml_find_all(article_node, ".//PublicationType")
      pub_types <- paste(sapply(pub_type_nodes, xml_text), collapse = "; ")
      if (pub_types == "") {
        pub_types <- NA_character_
      }

      # Extract journal info
      journal_title <- safe_xml_text(xml_find_first(
        article_node,
        ".//Journal/Title"
      ))
      iso_abbreviation <- safe_xml_text(xml_find_first(
        article_node,
        ".//ISOAbbreviation"
      ))
      volume <- safe_xml_text(xml_find_first(article_node, ".//Volume"))
      issue <- safe_xml_text(xml_find_first(article_node, ".//Issue"))
      medline_pgn <- safe_xml_text(xml_find_first(
        article_node,
        ".//MedlinePgn"
      ))
      issn <- safe_xml_text(xml_find_first(article_node, ".//ISSN"))

      # Extract DOI
      doi <- safe_xml_text(xml_find_first(
        article_node,
        ".//ArticleId[@IdType='doi']"
      ))
      if (is.na(doi)) {
        doi <- safe_xml_text(xml_find_first(
          article_node,
          ".//ELocationID[@EIdType='doi']"
        ))
      }

      # Extract publication date - try multiple sources
      pub_year <- NA_character_
      pub_month <- NA_character_
      pub_day <- NA_character_
      
      # Extract ePub date (electronic publication date)
      epub_year <- NA_character_
      epub_month <- NA_character_
      epub_day <- NA_character_
      
      # Extract Print date (actual journal publication date)
      print_year <- NA_character_
      print_month <- NA_character_
      print_day <- NA_character_

      # Try to get ePub date from PubMedPubDate with epublish status
      epub_node <- xml_find_first(
        article_node,
        ".//PubMedPubDate[@PubStatus='epublish']"
      )
      if (length(epub_node) > 0) {
        epub_year <- safe_xml_text(xml_find_first(epub_node, ".//Year"))
        epub_month <- safe_xml_text(xml_find_first(epub_node, ".//Month"))
        epub_day <- safe_xml_text(xml_find_first(epub_node, ".//Day"))
      }
      
      # Also check aheadofprint status for epub
      if (is.na(epub_year)) {
        aop_node <- xml_find_first(
          article_node,
          ".//PubMedPubDate[@PubStatus='aheadofprint']"
        )
        if (length(aop_node) > 0) {
          epub_year <- safe_xml_text(xml_find_first(aop_node, ".//Year"))
          epub_month <- safe_xml_text(xml_find_first(aop_node, ".//Month"))
          epub_day <- safe_xml_text(xml_find_first(aop_node, ".//Day"))
        }
      }
      
      # Get Print date from ArticleDate with DateType="Electronic" or from Journal PubDate
      # First try ArticleDate
      article_date_node <- xml_find_first(article_node, ".//ArticleDate[@DateType='Electronic']")
      if (length(article_date_node) > 0 && is.na(epub_year)) {
        epub_year <- safe_xml_text(xml_find_first(article_date_node, ".//Year"))
        epub_month <- safe_xml_text(xml_find_first(article_date_node, ".//Month"))
        epub_day <- safe_xml_text(xml_find_first(article_date_node, ".//Day"))
      }
      
      # Get Print publication date from Journal/JournalIssue/PubDate
      journal_pubdate_node <- xml_find_first(article_node, ".//Journal/JournalIssue/PubDate")
      if (length(journal_pubdate_node) > 0) {
        print_year <- safe_xml_text(xml_find_first(journal_pubdate_node, ".//Year"))
        print_month <- safe_xml_text(xml_find_first(journal_pubdate_node, ".//Month"))
        print_day <- safe_xml_text(xml_find_first(journal_pubdate_node, ".//Day"))
        
        # Handle MedlineDate format (e.g., "2024 Jan-Feb")
        if (is.na(print_year)) {
          medline_date <- safe_xml_text(xml_find_first(journal_pubdate_node, ".//MedlineDate"))
          if (!is.na(medline_date)) {
            # Extract year from MedlineDate
            year_match <- regmatches(medline_date, regexpr("\\d{4}", medline_date))
            if (length(year_match) > 0) {
              print_year <- year_match
            }
          }
        }
      }

      # Try PubMedPubDate with various statuses for general pub_date (used for CY/FY)
      for (status in c("pubmed", "pmc-release", "entrez", "medline")) {
        date_node <- xml_find_first(
          article_node,
          paste0(".//PubMedPubDate[@PubStatus='", status, "']")
        )
        if (length(date_node) > 0) {
          pub_year <- safe_xml_text(xml_find_first(date_node, ".//Year"))
          pub_month <- safe_xml_text(xml_find_first(date_node, ".//Month"))
          pub_day <- safe_xml_text(xml_find_first(date_node, ".//Day"))
          if (!is.na(pub_year)) break
        }
      }

      # Fallback to PubDate
      if (is.na(pub_year)) {
        pubdate_node <- xml_find_first(article_node, ".//PubDate")
        if (length(pubdate_node) > 0) {
          pub_year <- safe_xml_text(xml_find_first(pubdate_node, ".//Year"))
          pub_month <- safe_xml_text(xml_find_first(pubdate_node, ".//Month"))
          pub_day <- safe_xml_text(xml_find_first(pubdate_node, ".//Day"))
        }
      }

      # Helper function to convert month name to number
      convert_month <- function(month_str) {
        if (is.na(month_str)) return(NA_character_)
        if (grepl("^\\d+$", month_str)) return(month_str)
        month_names <- c(
          "Jan" = "1", "Feb" = "2", "Mar" = "3", "Apr" = "4",
          "May" = "5", "Jun" = "6", "Jul" = "7", "Aug" = "8",
          "Sep" = "9", "Oct" = "10", "Nov" = "11", "Dec" = "12"
        )
        month_short <- substr(month_str, 1, 3)
        return(as.character(month_names[month_short]))
      }
      
      # Convert month names to numbers
      pub_month <- convert_month(pub_month)
      epub_month <- convert_month(epub_month)
      print_month <- convert_month(print_month)

      # Create publication dates
      create_date <- function(year, month, day) {
        if (is.na(year)) return(NA)
        if (is.na(month)) month <- "1"
        if (is.na(day)) day <- "1"
        tryCatch(
          ymd(paste(year, month, day, sep = "-")),
          error = function(e) NA,
          warning = function(w) NA
        )
      }
      
      pub_date <- create_date(pub_year, pub_month, pub_day)
      epub_date <- create_date(epub_year, epub_month, epub_day)
      print_date <- create_date(print_year, print_month, print_day)
      
      # If no epub date but we have print date, use print date
      # If no print date but we have epub date, that's normal (ahead of print)
      
      # For CY/FY calculation, prefer epub date if available, else print date, else pub_date
      effective_date <- if (!is.na(epub_date)) epub_date else if (!is.na(print_date)) print_date else pub_date

      # Extract publication status (epub flag)
      pub_status <- safe_xml_text(xml_find_first(
        article_node,
        ".//PublicationStatus"
      ))
      epub_flag <- ifelse(
        !is.na(pub_status) && grepl("epub", pub_status, ignore.case = TRUE),
        1,
        0
      )

      # Extract pubmodel
      article_elem <- xml_find_first(article_node, ".//Article")
      pubmodel <- safe_xml_attr(article_elem, "PubModel")

      pubmodel_text <- NA_character_
      if (!is.na(pubmodel)) {
        if (grepl("Print-Electronic", pubmodel, ignore.case = TRUE)) {
          pubmodel_text <- "Epub"
        } else if (
          grepl("Electronic-eCollection", pubmodel, ignore.case = TRUE)
        ) {
          pubmodel_text <- "Ecollection"
        } else if (grepl("Electronic", pubmodel, ignore.case = TRUE)) {
          pubmodel_text <- "Electronic"
        } else if (grepl("Print", pubmodel, ignore.case = TRUE)) {
          pubmodel_text <- "Print"
        }
      }

      # Build results for each NHCS author
      results <- list()
      total_authors <- length(authors_list)

      # First, collect ALL authors with Duke-NUS Medical School affiliation
      duke_nus_authors <- character(0)
      for (author_name in authors_list) {
        author_affs <- affiliations_list[[author_name]]
        if (!is.null(author_affs) && !all(is.na(author_affs))) {
          if (
            any(
              grepl("Duke-NUS Medical School", author_affs, ignore.case = TRUE),
              na.rm = TRUE
            )
          ) {
            duke_nus_authors <- c(duke_nus_authors, author_name)
          }
        }
      }
      duke_nus_authors_str <- if (length(duke_nus_authors) > 0) {
        paste(duke_nus_authors, collapse = "; ")
      } else {
        NA_character_
      }

      for (i in seq_along(authors_list)) {
        author_name <- authors_list[i]
        author_affs <- affiliations_list[[author_name]]

        if (is_nhcs_author(author_affs)) {
          author_position <- get_author_position(i, total_authors)
          jri_affiliation <- check_jri_affiliation(author_affs)
          nhcs_department <- extract_nhcs_department(author_affs)

          # Format dates
          pub_date_formatted <- NA_character_
          published_month <- NA_character_
          cy_published <- NA_character_
          fy_reported <- NA_character_
          epub_date_formatted <- NA_character_
          print_date_formatted <- NA_character_

          if (!is.na(effective_date)) {
            pub_date_formatted <- format(effective_date, "%Y-%b-%d")
            published_month <- format(effective_date, "%m-%Y")
            cy_published <- as.character(year(effective_date))
            fy_reported <- get_financial_year(effective_date)
          }
          
          if (!is.na(epub_date)) {
            epub_date_formatted <- format(epub_date, "%Y-%b-%d")
          }
          
          if (!is.na(print_date)) {
            print_date_formatted <- format(print_date, "%Y-%b-%d")
          }

          # Create journal citation
          journal_citation <- paste0(
            ifelse(!is.na(iso_abbreviation), iso_abbreviation, ""),
            ifelse(
              !is.na(pub_date_formatted),
              paste0(" ", pub_date_formatted),
              ""
            ),
            ";",
            ifelse(!is.na(volume), volume, ""),
            ifelse(!is.na(issue), paste0("(", issue, ")"), ""),
            ":",
            ifelse(!is.na(medline_pgn), medline_pgn, ""),
            ".",
            ifelse(!is.na(doi), paste0("doi:", doi), ""),
            ".",
            ifelse(!is.na(pubmodel_text), pubmodel_text, ""),
            ifelse(
              !is.na(pub_date_formatted),
              paste0(".", format(pub_date, "%Y %b %d")),
              ""
            )
          )

          result <- list(
            PMID = pmid,
            Author = author_name,
            Author_List = paste(authors_list, collapse = "; "),
            Affiliations_List = paste(author_affs, collapse = " | "),
            NHCS_Author = author_name,
            Author_Status = author_position,
            Duke_NUS_Affiliation = duke_nus_authors_str,
            JRI_Affiliation = jri_affiliation,
            Department = nhcs_department,
            Publications = article_title,
            Type_of_Publication = pub_types,
            Epub_Date = as.character(epub_date),
            Epub_Date_Formatted = epub_date_formatted,
            Print_Date = as.character(print_date),
            Print_Date_Formatted = print_date_formatted,
            Publication_Date = as.character(effective_date),
            Publication_Date_Formatted = pub_date_formatted,
            CY_Published_Reported = cy_published,
            Financial_Year_Reported = fy_reported,
            Epub_Flag = epub_flag,
            Published_Month = published_month,
            DOI = ifelse(
              !is.na(doi),
              paste0("https://doi.org/", doi),
              NA_character_
            ),
            ISSN = issn,
            Journal = journal_citation,
            Title = journal_title,
            Abbreviated_Title = iso_abbreviation,
            PubMed_ID = pmid,
            PubMed_Link = paste0("https://pubmed.ncbi.nlm.nih.gov/", pmid)
          )

          results[[length(results) + 1]] <- result
        }
      }

      return(results)
    },
    error = function(e) {
      message("Error parsing article: ", e$message)
      return(list())
    }
  )
}

# Function to parse all articles from XML string
parse_pubmed_xml <- function(xml_string) {
  tryCatch(
    {
      doc <- read_xml(xml_string)
      article_nodes <- xml_find_all(doc, ".//PubmedArticle")

      all_results <- list()

      for (article_node in article_nodes) {
        parsed <- parse_single_article(article_node)
        all_results <- c(all_results, parsed)
      }

      return(all_results)
    },
    error = function(e) {
      message("Error parsing XML: ", e$message)
      return(list())
    }
  )
}
