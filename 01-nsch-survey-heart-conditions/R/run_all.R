# =============================================================================
# run_all.R  --  run the full pipeline from the project folder:
#
#   Rscript R/run_all.R                          # synthetic data (default)
#   NSCH_FILE=nsch_2023e_topical.dta NSCH_YEAR=2023 Rscript R/run_all.R
#
# All tables are written to output/ as CSV, figures as PNG.
# =============================================================================

PROJECT_DIR <- getwd()
if (!file.exists(file.path(PROJECT_DIR, "R", "00_setup.R"))) {
  stop("Run from the project folder (the one containing R/ and data/).")
}

if (Sys.getenv("NSCH_FILE", "nsch_synthetic.csv") == "nsch_synthetic.csv" &&
    !file.exists(file.path(PROJECT_DIR, "data", "nsch_synthetic.csv"))) {
  source(file.path(PROJECT_DIR, "R", "make_synthetic_nsch.R"))
}

t0 <- Sys.time()
for (s in c("01_prepare.R", "02_estimates.R", "03_variance.R",
            "04_weighting.R", "05_models.R")) {
  source(file.path(PROJECT_DIR, "R", s))
}

writeLines(capture.output(sessionInfo()), file.path(OUTPUT_DIR, "sessionInfo.txt"))
message("\nDone in ", round(as.numeric(difftime(Sys.time(), t0, units = "secs"))),
        " s. Data: ", NSCH_FILE, " (", NSCH_YEAR, ")")
