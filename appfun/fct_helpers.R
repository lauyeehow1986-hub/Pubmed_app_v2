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
