# =============================================================================
# 01_prepare.R
# Read the NSCH file, validate it, derive analysis variables, and build the
# survey design object. Produces `nsch` (data frame) and `des` (design).
#
# Key principle: the FULL sample stays in the design. Subpopulations
# (e.g. children with a current heart condition) are analysed as domains
# with subset()/svyby() so variance estimation keeps every stratum and PSU.
# =============================================================================

source(file.path(PROJECT_DIR, "R", "00_setup.R"))

path <- file.path(DATA_DIR, NSCH_FILE)
if (!file.exists(path)) {
  stop("Data file not found: ", path,
       "\nDownload the NSCH Topical file into data/ or run R/make_synthetic_nsch.R")
}

raw <- read_nsch(path)
check_required(raw)
message("Read ", nrow(raw), " records from ", NSCH_FILE)

# ---- Design-variable checks --------------------------------------------------
stopifnot(
  "Missing or non-positive weights" = all(!is.na(raw$FWC) & raw$FWC > 0),
  "HHID should identify one child per household" = !anyDuplicated(raw$HHID)
)

nsch <- raw
nsch$strata_id <- interaction(nsch$FIPSST, nsch$STRATUM, drop = TRUE)

# ---- Outcomes and exposure ----------------------------------------------------
heart_ever <- keep_codes(nsch$HEART, 1:2)
heart_curr <- keep_codes(nsch$HEART_CURR, 1:2)

# Current heart condition: told ever AND currently has it. Children never
# told (HEART = 2) are legitimately skipped out of HEART_CURR -> code 0.
nsch$heart_current <- ifelse(is.na(heart_ever), NA,
                       ifelse(heart_ever == 2, 0,
                       ifelse(heart_curr %in% 1, 1,
                       ifelse(heart_curr %in% 2, 0, NA))))
nsch$heart_grp <- factor(nsch$heart_current, levels = c(0, 1),
                         labels = c("No current heart condition",
                                    "Current heart condition"))

k2q01 <- keep_codes(nsch$K2Q01, 1:5)
nsch$fair_poor_health <- ifelse(is.na(k2q01), NA, as.numeric(k2q01 >= 4))

k4q27 <- keep_codes(nsch$K4Q27, 1:2)
nsch$forgone_care <- ifelse(is.na(k4q27), NA, as.numeric(k4q27 == 1))

currcov <- keep_codes(nsch$CURRCOV, 1:2)
nsch$uninsured <- ifelse(is.na(currcov), NA, as.numeric(currcov == 2))

# ---- Covariates ---------------------------------------------------------------
nsch$age_grp <- cut(nsch$SC_AGE_YEARS, c(-1, 5, 11, 17),
                    labels = c("0-5", "6-11", "12-17"))
nsch$sex <- factor(keep_codes(nsch$SC_SEX, 1:2), levels = 1:2,
                   labels = c("Male", "Female"))

race <- keep_codes(nsch$SC_RACE_R, 1:7)
hisp <- keep_codes(nsch$SC_HISPANIC_R, 1:2)
nsch$race_eth <- factor(
  ifelse(hisp %in% 1, "Hispanic",
  ifelse(race %in% 1, "NH White",
  ifelse(race %in% 2, "NH Black",
  ifelse(race %in% 4, "NH Asian",
  ifelse(!is.na(race), "NH Other/Multiple", NA))))),
  levels = c("NH White", "Hispanic", "NH Black", "NH Asian", "NH Other/Multiple"))

# Poverty category from ONE implicate. Point estimates in descriptive
# tables use implicate 1 for simplicity; all poverty-related inference in
# 04_models.R combines all six implicates with Rubin's rules.
fpl_cat <- function(x) {
  cut(x, c(-Inf, 99, 199, 399, Inf),
      labels = c("<100% FPL", "100-199% FPL", "200-399% FPL", "400%+ FPL"))
}
for (m in seq_along(FPL_IMPLICATES)) {
  nsch[[paste0("pov_", m)]] <- fpl_cat(nsch[[FPL_IMPLICATES[m]]])
}
nsch$pov <- nsch$pov_1

# ---- Item-missingness report ---------------------------------------------------
analysis_vars <- c("heart_current", "fair_poor_health", "forgone_care",
                   "uninsured", "age_grp", "sex", "race_eth")
miss <- data.frame(
  variable    = analysis_vars,
  n_missing   = vapply(analysis_vars, function(v) sum(is.na(nsch[[v]])), numeric(1)),
  pct_missing = vapply(analysis_vars, function(v) 100 * mean(is.na(nsch[[v]])), numeric(1))
)
write_out(round_df(miss), "00_item_missingness.csv")

# ---- Design object --------------------------------------------------------------
des <- make_design(nsch)

design_summary <- data.frame(
  n_records        = nrow(nsch),
  n_strata         = nlevels(nsch$strata_id),
  n_psu            = length(unique(nsch[[CLUSTER_VAR]])),
  sum_weights      = sum(nsch[[WEIGHT_VAR]]),
  kish_deff_weight = 1 + (sd(nsch[[WEIGHT_VAR]]) / mean(nsch[[WEIGHT_VAR]]))^2
)
write_out(round_df(design_summary, 3), "00_design_summary.csv")
message("Design built: ", design_summary$n_strata, " strata, ",
        design_summary$n_psu, " PSUs; Kish weighting deff = ",
        round(design_summary$kish_deff_weight, 2))
