# =============================================================================
# 00_setup.R
# Configuration, packages and helper functions shared by all scripts.
#
# Project: Children with heart conditions in the National Survey of
#          Children's Health (NSCH) -- design-based estimation, variance
#          estimation, weighting and multiple-imputation inference.
# =============================================================================

suppressPackageStartupMessages({
  library(survey)   # design-based estimation (Lumley)
  library(mitools)  # combining estimates across imputed datasets (Rubin's rules)
})

# ---- Paths ------------------------------------------------------------------
# PROJECT_DIR is the folder that contains R/, data/ and output/.
# Run scripts from that folder (run_all.R does this), or set PROJECT_DIR first.
if (!exists("PROJECT_DIR")) PROJECT_DIR <- getwd()
DATA_DIR   <- file.path(PROJECT_DIR, "data")
OUTPUT_DIR <- file.path(PROJECT_DIR, "output")
dir.create(OUTPUT_DIR, showWarnings = FALSE, recursive = TRUE)

# ---- Data source ------------------------------------------------------------
# Real data: download the NSCH Topical public-use file (Stata .dta or SAS
# .sas7bdat) from the U.S. Census Bureau NSCH datasets page and save it in
# data/. Set NSCH_FILE to its name.
# No download? Run R/make_synthetic_nsch.R first; it writes a structurally
# identical synthetic file so every script runs end to end.
NSCH_FILE <- Sys.getenv("NSCH_FILE", unset = "nsch_synthetic.csv")
NSCH_YEAR <- Sys.getenv("NSCH_YEAR", unset = "synthetic")

# ---- Survey design variables (Census Bureau guidance for NSCH) --------------
#   weight  : FWC     child-level final weight
#   strata  : FIPSST x STRATUM  (state by sampling stratum)
#   cluster : HHID    household (one child sampled per household)
WEIGHT_VAR  <- "FWC"
STRATA_VARS <- c("FIPSST", "STRATUM")
CLUSTER_VAR <- "HHID"

# Imputed federal-poverty-level variables (Census multiply imputes income).
FPL_IMPLICATES <- paste0("FPL_I", 1:6)

# Variables the analysis needs. Verify codes against the codebook for the
# survey year you download; recodes live in 01_prepare.R.
REQUIRED_VARS <- c(WEIGHT_VAR, STRATA_VARS, CLUSTER_VAR, FPL_IMPLICATES,
                   "SC_AGE_YEARS", "SC_SEX", "SC_RACE_R", "SC_HISPANIC_R",
                   "HEART", "HEART_CURR", "K2Q01", "K4Q27", "CURRCOV")

# Strata containing a single PSU after domain subsetting: centre at the
# grand mean rather than failing (conservative, standard practice).
options(survey.lonely.psu = "adjust")

set.seed(20261014)

# ---- Helpers ----------------------------------------------------------------
`%||%` <- function(a, b) if (is.null(a)) b else a

read_nsch <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext == "csv") {
    return(read.csv(path, stringsAsFactors = FALSE))
  }
  if (!requireNamespace("haven", quietly = TRUE)) {
    stop("Reading .", ext, " files requires the 'haven' package: install.packages('haven')")
  }
  df <- switch(ext,
               dta      = haven::read_dta(path),
               sas7bdat = haven::read_sas(path),
               stop("Unsupported file type: ", ext))
  df <- haven::zap_labels(df)
  names(df) <- toupper(names(df))
  as.data.frame(df)
}

check_required <- function(df, vars = REQUIRED_VARS) {
  missing_vars <- setdiff(vars, names(df))
  if (length(missing_vars)) {
    stop("Variables not found in the NSCH file (check the codebook for this year): ",
         paste(missing_vars, collapse = ", "))
  }
  invisible(TRUE)
}

# Keep only valid codes; anything else (skips, refusals, don't know) -> NA.
keep_codes <- function(x, valid) ifelse(x %in% valid, x, NA)

# Build the NSCH design object for a given analysis data frame.
make_design <- function(df, weights = WEIGHT_VAR) {
  svydesign(ids     = as.formula(paste0("~", CLUSTER_VAR)),
            strata  = ~ strata_id,
            weights = as.formula(paste0("~", weights)),
            data    = df,
            nest    = TRUE)
}

# Tidy a svymean / svyciprop style result into a data frame of %.
pct_table <- function(est, label = NULL) {
  ci <- confint(est)
  out <- data.frame(
    estimate_pct = 100 * coef(est),
    se_pct       = 100 * SE(est),
    lcl_pct      = 100 * ci[, 1],
    ucl_pct      = 100 * ci[, 2],
    row.names    = NULL
  )
  if (!is.null(label)) out <- cbind(term = label, out)
  out
}

write_out <- function(df, name) {
  path <- file.path(OUTPUT_DIR, name)
  write.csv(df, path, row.names = FALSE)
  message("  wrote output/", name)
  invisible(path)
}

round_df <- function(df, digits = 2) {
  num <- vapply(df, is.numeric, logical(1))
  df[num] <- lapply(df[num], round, digits)
  df
}
