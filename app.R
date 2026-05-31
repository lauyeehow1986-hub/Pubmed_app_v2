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

# ============================================================================
# NCBI E-utilities API Functions
# ============================================================================

# Base URLs for NCBI E-utilities
NCBI_ESEARCH_URL <- "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
NCBI_EFETCH_URL <- "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"

# Function to search PubMed and get PMIDs
search_pubmed <- function(query, retmax = 1000) {
  tryCatch(
    {
      response <- GET(
        NCBI_ESEARCH_URL,
        query = list(
          db = "pubmed",
          term = query,
          retmax = retmax,
          retmode = "json",
          usehistory = "y"
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
        response <- GET(
          NCBI_EFETCH_URL,
          query = list(
            db = "pubmed",
            query_key = search_result$query_key,
            WebEnv = search_result$webenv,
            rettype = "xml",
            retmode = "xml",
            retmax = retmax
          )
        )
      } else {
        # Fallback to using IDs directly
        ids_string <- paste(search_result$ids, collapse = ",")
        response <- GET(
          NCBI_EFETCH_URL,
          query = list(
            db = "pubmed",
            id = ids_string,
            rettype = "xml",
            retmode = "xml"
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

# ============================================================================
# JRI Institutes (effective 2023)
# ============================================================================

jri_institutes <- c(
  "Artificial Intelligence in Medicine Institute",
  "AIMI",
  "Health Services Research Institute",
  "HSRI",
  "Infectious Diseases Research Institute",
  "IDRI",
  "SingHealth Duke-NUS Institute of Precision Medicine",
  "PRISM",
  "Translational Immunology Institute",
  "TII",
  "National Cancer Research Institute of Singapore",
  "National Cancer Research Institute Singapore",
  "NCRIS",
  "National Dental Research Institute Singapore",
  "NDRIS",
  "National Heart Research Institute Singapore",
  "NHRIS",
  "National Neuroscience Research Institute Singapore",
  "NNRIS",
  "Institute of Biodiversity Medicine",
  "BD-MED"
)

# ============================================================================
# Helper Functions
# ============================================================================

# Function to check for JRI affiliation
check_jri_affiliation <- function(affiliations) {
  if (
    is.null(affiliations) ||
      length(affiliations) == 0 ||
      all(is.na(affiliations))
  ) {
    return(NA_character_)
  }

  jri_found <- character(0)
  for (aff in affiliations) {
    if (!is.na(aff)) {
      for (jri in jri_institutes) {
        if (grepl(jri, aff, ignore.case = TRUE)) {
          jri_found <- c(jri_found, jri)
        }
      }
    }
  }

  if (length(jri_found) > 0) {
    return(paste(unique(jri_found), collapse = "; "))
  }
  return(NA_character_)
}

# Function to extract department/unit from NHCS affiliation
# Extracts the unit that appears immediately before "National Heart Centre Singapore"
extract_nhcs_department <- function(affiliations) {
  if (
    is.null(affiliations) ||
      length(affiliations) == 0 ||
      all(is.na(affiliations))
  ) {
    return(NA_character_)
  }

  departments <- character(0)

  for (aff in affiliations) {
    if (!is.na(aff) && grepl("national heart cent", aff, ignore.case = TRUE)) {
      # Normalize separators - handle both comma and semicolon separated affiliations
      # Also handle cases where there might be periods as separators

      # First, try to find the segment containing NHCS
      # Split by common separators (semicolon, period followed by space and capital)
      segments <- unlist(strsplit(aff, ";|(?<=\\.)\\s+(?=[A-Z])", perl = TRUE))

      for (segment in segments) {
        segment <- trimws(segment)

        if (grepl("national heart cent", segment, ignore.case = TRUE)) {
          # This segment contains NHCS - extract what comes before it
          # Pattern: extract everything before "National Heart Centre Singapore" or "National Heart Center Singapore"

          # Remove email addresses first
          segment_clean <- gsub(
            "\\. Electronic address:.*$",
            "",
            segment,
            ignore.case = TRUE
          )
          segment_clean <- gsub(
            "Electronic address:.*$",
            "",
            segment_clean,
            ignore.case = TRUE
          )

          # Split by comma to get parts
          parts <- unlist(strsplit(segment_clean, ","))
          parts <- trimws(parts)

          # Find which part contains NHCS
          nhcs_index <- which(grepl(
            "national heart cent",
            parts,
            ignore.case = TRUE
          ))[1]

          if (!is.na(nhcs_index) && nhcs_index > 1) {
            # Get the part immediately before NHCS
            dept_candidate <- parts[nhcs_index - 1]
            dept_candidate <- trimws(dept_candidate)

            # Check if it's a valid department/unit (not just a country/city)
            # Exclude common non-department entries
            exclude_patterns <- c(
              "^Singapore$",
              "^Republic of Singapore$",
              "^China$",
              "^USA$",
              "^United States$",
              "^UK$",
              "^United Kingdom$",
              "^[0-9]+$",
              "^SG$",
              "^[A-Z]{2}$" # Country codes
            )

            is_excluded <- any(sapply(exclude_patterns, function(p) {
              grepl(p, dept_candidate, ignore.case = TRUE)
            }))

            if (!is_excluded && nchar(dept_candidate) > 2) {
              departments <- c(departments, dept_candidate)
            }
          } else if (!is.na(nhcs_index) && nhcs_index == 1) {
            # NHCS is the first part - check if there's anything meaningful in the NHCS part itself
            # e.g., "National Heart Research Institute Singapore National Heart Centre Singapore"
            nhcs_part <- parts[nhcs_index]

            # Try to extract unit before "National Heart Centre"
            before_nhcs <- sub(
              "(?i)\\s*,?\\s*National Heart Cent(re|er) Singapore.*$",
              "",
              nhcs_part
            )
            before_nhcs <- trimws(before_nhcs)

            if (
              nchar(before_nhcs) > 0 &&
                !grepl("^National Heart Cent", before_nhcs, ignore.case = TRUE)
            ) {
              departments <- c(departments, before_nhcs)
            }
          }
        }
      }
    }
  }

  if (length(departments) > 0) {
    return(paste(unique(departments), collapse = "; "))
  }
  return(NA_character_)
}

# Function to check if author is from NHCS
is_nhcs_author <- function(affiliations) {
  if (
    is.null(affiliations) ||
      length(affiliations) == 0 ||
      all(is.na(affiliations))
  ) {
    return(FALSE)
  }
  any(
    grepl("national heart cent", affiliations, ignore.case = TRUE),
    na.rm = TRUE
  )
}

# Function to determine financial year (FY starts April)
get_financial_year <- function(date) {
  if (is.na(date)) {
    return(NA_character_)
  }

  year <- year(date)
  month <- month(date)

  if (month >= 4) {
    return(paste0("FY", year))
  } else {
    return(paste0("FY", year - 1))
  }
}

# Function to get author position
get_author_position <- function(index, total) {
  if (index == 1) {
    return("First")
  }
  if (index == total) {
    return("Last")
  }

  positions <- c(
    "First",
    "Second",
    "Third",
    "Fourth",
    "Fifth",
    "Sixth",
    "Seventh",
    "Eighth",
    "Ninth",
    "Tenth"
  )

  if (index <= 10) {
    return(positions[index])
  } else {
    return(paste0(index, "th"))
  }
}

# Safe XML text extraction
safe_xml_text <- function(node) {
  if (length(node) == 0 || is.null(node)) {
    return(NA_character_)
  }
  text <- xml_text(node)
  if (length(text) == 0 || text == "") {
    return(NA_character_)
  }
  return(text)
}

# Safe XML attribute extraction
safe_xml_attr <- function(node, attr_name) {
  if (length(node) == 0 || is.null(node)) {
    return(NA_character_)
  }
  attr_val <- xml_attr(node, attr_name)
  if (is.na(attr_val) || attr_val == "") {
    return(NA_character_)
  }
  return(attr_val)
}

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

# ============================================================================
# DOAJ API Function
# ============================================================================

fetch_doaj_oa_start <- function(journal_title) {
  tryCatch(
    {
      encoded_title <- URLencode(journal_title, reserved = TRUE)
      url <- paste0("https://doaj.org/api/v4/search/journals/", encoded_title)

      res <- GET(url, timeout(10))

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

# ============================================================================
# SJR Journal Data Function - Downloads parquet and returns local path
# ============================================================================

download_sjr_parquet <- function() {
  tryCatch(
    {
      # Try current year - 1 first, then fall back to earlier years if not found
      current_year <- as.integer(format(Sys.Date(), "%Y"))
      
      for (year_offset in 1:3) {
        sjr_year <- current_year - year_offset
        
        # Construct filename and URL
        filename <- paste0("sjr_journals-", sjr_year, ".parquet")
        url <- paste0(
          "https://github.com/ikashnitsky/sjrdata/raw/master/data-raw/sjr-journal/",
          filename
        )
        
        message("Trying SJR parquet URL: ", url)
        
        # Create temp file for download
        temp_file <- tempfile(fileext = ".parquet")
        
        # Download the parquet file
        download_result <- tryCatch(
          {
            download.file(url, temp_file, mode = "wb", quiet = TRUE)
            TRUE
          },
          error = function(e) {
            message("Error downloading SJR data for year ", sjr_year, ": ", e$message)
            FALSE
          }
        )
        
        if (download_result && file.exists(temp_file) && file.size(temp_file) > 1000) {
          message("SJR parquet downloaded successfully!")
          message("Year: ", sjr_year)
          message("File path: ", temp_file)
          message("File size: ", file.size(temp_file), " bytes")
          
          return(list(
            path = temp_file,
            year = sjr_year
          ))
        } else {
          message("Download failed or file too small for year ", sjr_year, ", trying previous year...")
          if (file.exists(temp_file)) unlink(temp_file)
        }
      }
      
      message("Could not download SJR parquet for any recent year")
      return(NULL)
    },
    error = function(e) {
      message("Error in download_sjr_parquet: ", e$message)
      return(NULL)
    }
  )
}

# Function to query SJR data using DuckDB with LIKE for relevant ISSNs
query_sjr_with_duckdb <- function(sjr_parquet_path, relevant_issns) {
  tryCatch(
    {
      if (is.null(sjr_parquet_path) || length(relevant_issns) == 0) {
        message("SJR query aborted: path is NULL or no ISSNs provided")
        return(NULL)
      }
      
      # Ensure path uses forward slashes for DuckDB
      sjr_parquet_path <- gsub("\\\\", "/", sjr_parquet_path)
      message("SJR parquet path: ", sjr_parquet_path)
      
      # Check if file exists
      if (!file.exists(sjr_parquet_path)) {
        message("SJR parquet file does not exist: ", sjr_parquet_path)
        return(NULL)
      }
      
      message("Number of ISSNs to query: ", length(relevant_issns))
      message("Sample ISSNs (from publications): ", paste(head(relevant_issns, 5), collapse = ", "))
      
      # relevant_issns are already without hyphens (e.g., "12345678")
      # SJR parquet ALSO has ISSNs without hyphens (e.g., "12345678")
      # So we can use them directly!
      
      # Create LIKE conditions for each ISSN
      # The parquet issn column can contain multiple ISSNs (comma-separated)
      # so we use LIKE '%issn%' to match
      like_conditions <- sapply(relevant_issns, function(issn) {
        paste0("issn LIKE '%", issn, "%'")
      })
      
      # Combine conditions with OR
      where_clause <- paste(like_conditions, collapse = " OR ")
      
      # Build complete query - note column is 'cites_doc_2years' in parquet (not 'citations')
      query <- paste0(
        "SELECT year, rank, sjr, sjr_best_quartile, h_index, cites_doc_2years, title, issn FROM '",
        sjr_parquet_path,
        "' WHERE ",
        where_clause
      )
      
      message("DuckDB query length: ", nchar(query))
      message("Sample WHERE clause: ", substr(where_clause, 1, 300), "...")
      
      # Connect to DuckDB and execute query
      con <- dbConnect(duckdb::duckdb())
      on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)
      
      # First test: check if we can read the parquet at all
      test_query <- paste0("SELECT COUNT(*) as cnt FROM '", sjr_parquet_path, "'")
      test_result <- dbGetQuery(con, test_query)
      message("Total rows in parquet: ", test_result$cnt)
      
      # Execute the main query
      sjr_df <- dbGetQuery(con, query)
      
      message("DuckDB query returned ", nrow(sjr_df), " rows")
      if (nrow(sjr_df) > 0) {
        message("SJR columns: ", paste(names(sjr_df), collapse = ", "))
        message("Sample matched ISSNs: ", paste(head(sjr_df$issn, 3), collapse = ", "))
      }
      
      # Process the results - rename columns and add percentile
      if (nrow(sjr_df) > 0) {
        # Rename cites_doc_2years if it exists
        if ("cites_doc_2years" %in% names(sjr_df)) {
          sjr_df <- sjr_df %>%
            rename(citations_doc_2years = cites_doc_2years)
        }
        
        # Create annual rank percentile as categorical (deciles)
        sjr_df <- sjr_df %>%
          group_by(year) %>%
          mutate(
            total_journals = n(),
            numeric_percentile = (rank / max(rank, na.rm = TRUE)) * 100,
            annual_rank_percentile = case_when(
              numeric_percentile <= 10 ~ "Top 1-10%",
              numeric_percentile <= 20 ~ "Top 11-20%",
              numeric_percentile <= 30 ~ "Top 21-30%",
              numeric_percentile <= 40 ~ "Top 31-40%",
              numeric_percentile <= 50 ~ "Top 41-50%",
              numeric_percentile <= 60 ~ "Top 51-60%",
              numeric_percentile <= 70 ~ "Top 61-70%",
              numeric_percentile <= 80 ~ "Top 71-80%",
              numeric_percentile <= 90 ~ "Top 81-90%",
              TRUE ~ "Top 91-100%"
            )
          ) %>%
          ungroup() %>%
          select(-total_journals, -numeric_percentile)
      }
      
      return(sjr_df)
    },
    error = function(e) {
      message("Error querying SJR with DuckDB: ", e$message)
      return(NULL)
    }
  )
}

# ============================================================================
# Shiny UI
# ============================================================================

ui <- dashboardPage(
  dashboardHeader(title = "NHCS PubMed Tracker"),

  dashboardSidebar(
    sidebarMenu(
      menuItem("Search PubMed", tabName = "search", icon = icon("search")),
      menuItem("Results", tabName = "results", icon = icon("table")),
      menuItem("Debug SJR", tabName = "debug", icon = icon("bug")),
      menuItem("About", tabName = "about", icon = icon("info-circle"))
    )
  ),

  dashboardBody(
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
            
            p("Test if DuckDB can load and query the local bundled SJR parquet file (data/sjr_all.parquet)."),
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
                "SCImago Journal & Country Rank (SJR) data downloaded directly from scimagojr.com for all years (1999 to current), stored as this project's own combined parquet (data/sjr_all.parquet) and refreshed monthly via GitHub Actions"
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
      )
    )
  )
)

# ============================================================================
# Shiny Server
# ============================================================================

server <- function(input, output, session) {
  # Reactive values
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

          # Step 5: Locate the bundled combined SJR parquet file
          incProgress(0.05, detail = "Loading SJR journal ranking data...")

          sjr_parquet_info <- get_sjr_parquet()
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
            # NOTE: do NOT unlink the parquet here -- it is the repo-bundled
            # data/sjr_all.parquet, not a throwaway temp file.

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
        "✓ SJR data loaded successfully (source: SCImago, your own parquet)!\n",
        "  - Source file: ",
        SJR_PARQUET_PATH,
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
      
      # Step 1: Locate the bundled combined SJR parquet
      temp_file <- SJR_PARQUET_PATH
      results$path <- temp_file
      results$step1 <- paste0("✓ Looking for local SJR parquet: ", temp_file)

      # Step 2: Check the file exists and looks valid
      if (!file.exists(temp_file)) {
        results$step2 <- paste0(
          "✗ File not found: ", temp_file,
          " - run scripts/build_sjr_parquet.R or the update-sjr GitHub Action."
        )
        return(paste(unlist(results), collapse = "\n"))
      }

      file_size <- file.size(temp_file)
      results$step2 <- paste0("✓ File found: ", format(file_size, big.mark = ","), " bytes")

      if (file_size < 1000) {
        results$step2b <- "✗ File too small - likely incomplete, not a valid parquet file"
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
      
      # Step 4: Count rows in parquet
      temp_file_clean <- gsub("\\\\", "/", temp_file)
      count_query <- paste0("SELECT COUNT(*) as cnt FROM '", temp_file_clean, "'")
      
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
      schema_query <- paste0("DESCRIBE SELECT * FROM '", temp_file_clean, "'")
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
      issn_query <- paste0("SELECT DISTINCT issn FROM '", temp_file_clean, "' WHERE issn IS NOT NULL LIMIT 5")
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
      like_query <- paste0("SELECT COUNT(*) as cnt FROM '", temp_file_clean, "' WHERE issn LIKE '%00097322%'")
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
}

# Run the app
shinyApp(ui = ui, server = server)
