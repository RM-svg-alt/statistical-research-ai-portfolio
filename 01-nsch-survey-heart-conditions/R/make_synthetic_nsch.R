# =============================================================================
# make_synthetic_nsch.R
# Writes data/nsch_synthetic.csv: a SYNTHETIC file with the same variable
# names, codes and design structure (FWC weights, FIPSST x STRATUM strata,
# HHID clusters, six FPL implicates) as the NSCH Topical public-use file.
#
# Purpose: lets the pipeline run end to end without downloading data, and
# lets reviewers reproduce every table. It is NOT real NSCH data and its
# estimates must not be interpreted substantively.
#
# The generator deliberately builds in differential nonresponse by income
# and age, so the weighted and unweighted estimates differ -- which is the
# point the analysis demonstrates.
# =============================================================================

if (!exists("PROJECT_DIR")) PROJECT_DIR <- getwd()
dir.create(file.path(PROJECT_DIR, "data"), showWarnings = FALSE)
set.seed(4242)

N_POP <- 150000   # pool from which "respondents" are drawn

state_fips <- c(1, 2, 4:6, 8:13, 15:42, 44:51, 53:56)       # 50 states + DC
state_size <- rgamma(length(state_fips), shape = 1.2, rate = 1)

pop <- data.frame(
  FIPSST  = sample(state_fips, N_POP, replace = TRUE, prob = state_size),
  STRATUM = sample(c("1", "2A"), N_POP, replace = TRUE, prob = c(0.85, 0.15)),
  SC_AGE_YEARS = sample(0:17, N_POP, replace = TRUE),
  SC_SEX = sample(1:2, N_POP, replace = TRUE, prob = c(0.51, 0.49))
)

# Race (SC_RACE_R) and Hispanic origin (SC_HISPANIC_R: 1 = Hispanic, 2 = not)
pop$SC_HISPANIC_R <- sample(1:2, N_POP, replace = TRUE, prob = c(0.26, 0.74))
pop$SC_RACE_R <- sample(1:7, N_POP, replace = TRUE,
                        prob = c(0.62, 0.14, 0.01, 0.05, 0.003, 0.04, 0.137))

# True household income as % of the federal poverty level, then top/bottom
# coded at 400 / 50 as in the public file.
log_fpl <- 5.3 - 0.35 * (pop$SC_HISPANIC_R == 1) - 0.40 * (pop$SC_RACE_R == 2) +
           0.10 * (pop$SC_RACE_R == 4) + rnorm(N_POP, 0, 0.75)
true_fpl <- pmin(pmax(round(exp(log_fpl)), 50), 400)
poor     <- true_fpl < 100
nearpoor <- true_fpl >= 100 & true_fpl < 200

# Insurance (CURRCOV: 1 = covered, 2 = not)
p_ins <- plogis(3.2 - 1.0 * poor - 0.6 * nearpoor - 0.5 * (pop$SC_HISPANIC_R == 1))
pop$CURRCOV <- ifelse(runif(N_POP) < p_ins, 1, 2)

# Heart condition: ever told (HEART) and current (HEART_CURR, asked if ever)
p_heart <- plogis(-3.6 + 0.25 * poor - 0.02 * pop$SC_AGE_YEARS)
pop$HEART <- ifelse(runif(N_POP) < p_heart, 1, 2)
pop$HEART_CURR <- ifelse(pop$HEART == 1,
                         ifelse(runif(N_POP) < 0.60, 1, 2), NA)
heart_now <- pop$HEART == 1 & pop$HEART_CURR %in% 1

# General health (K2Q01: 1 excellent ... 5 poor)
lin <- -0.2 + 1.3 * heart_now + 0.6 * poor + 0.3 * nearpoor + rnorm(N_POP, 0, 1)
pop$K2Q01 <- as.integer(cut(lin, c(-Inf, 0.4, 1.4, 2.4, 3.2, Inf)))

# Forgone needed care in past 12 months (K4Q27: 1 = yes, 2 = no)
p_forgone <- plogis(-3.7 + 0.9 * heart_now + 0.5 * poor + 0.3 * nearpoor +
                    1.1 * (pop$CURRCOV == 2) + 0.02 * pop$SC_AGE_YEARS)
pop$K4Q27 <- ifelse(runif(N_POP) < p_forgone, 1, 2)

# ---- Differential nonresponse: lower-income and older children respond less
p_resp <- plogis(-0.9 + 0.5 * log(true_fpl / 100) - 0.02 * pop$SC_AGE_YEARS)
resp   <- runif(N_POP) < p_resp
nsch   <- pop[resp, ]
true_fpl_resp <- true_fpl[resp]
n <- nrow(nsch)

# Weight = inverse response propensity x state/stratum factor, with noise,
# scaled to roughly the U.S. child population (~73 million).
w <- (1 / p_resp[resp]) *
     ifelse(nsch$STRATUM == "2A", 0.6, 1.1) *
     exp(rnorm(n, 0, 0.25))
nsch$FWC <- round(w / sum(w) * 73e6, 4)

# One child per household -> HHID unique
nsch$HHID <- sprintf("%08d", 1e7 + sample.int(8e7, n))

# ---- Six FPL implicates: ~20% of cases have imputed income --------------
imputed <- runif(n) < 0.20
for (m in 1:6) {
  draw <- round(true_fpl_resp * exp(rnorm(n, 0, 0.35)))
  nsch[[paste0("FPL_I", m)]] <- ifelse(imputed, pmin(pmax(draw, 50), 400),
                                       true_fpl_resp)
}

# ---- Item nonresponse --------------------------------------------------------
nsch$K2Q01[runif(n) < 0.010] <- NA
nsch$K4Q27[runif(n) < 0.020] <- NA
nsch$HEART[runif(n) < 0.005] <- NA
nsch$HEART_CURR[is.na(nsch$HEART)] <- NA

nsch <- nsch[, c("HHID", "FIPSST", "STRATUM", "FWC", "SC_AGE_YEARS", "SC_SEX",
                 "SC_RACE_R", "SC_HISPANIC_R", paste0("FPL_I", 1:6),
                 "CURRCOV", "HEART", "HEART_CURR", "K2Q01", "K4Q27")]

out <- file.path(PROJECT_DIR, "data", "nsch_synthetic.csv")
write.csv(nsch, out, row.names = FALSE, na = "")
message("Synthetic NSCH-structured file written: ", out, " (n = ", n, ")")
