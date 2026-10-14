# =============================================================================
# 04_weighting.R
# Weighting methods, demonstrated on the NSCH sample.
#
#   Part 1  Raking (iterative proportional fitting) to control totals,
#           weight diagnostics, and trimming with re-raking.
#   Part 2  Simulated unit nonresponse with a response-propensity
#           weighting-class adjustment followed by calibration (raking).
#
# NSCH already ships final weights; here they serve as the "truth" that the
# weighting steps should recover, which makes the bias of each step visible.
# =============================================================================

if (!exists("des")) source(file.path(PROJECT_DIR, "R", "01_prepare.R"))

message("\n== 04 Weighting ==")

rake_vars <- c("age_grp", "sex", "race_eth", "pov")
wd <- nsch[complete.cases(nsch[, rake_vars]), ]
wd$age_sex <- interaction(wd$age_grp, wd$sex, drop = TRUE)

weight_diag <- function(w, label) {
  data.frame(weights = label, n = length(w), min = min(w), median = median(w),
             max = max(w), max_to_min = max(w) / min(w),
             cv = sd(w) / mean(w), kish_deff = 1 + (sd(w) / mean(w))^2,
             kish_n_eff = length(w) / (1 + (sd(w) / mean(w))^2))
}

# Population control totals = margins of the final NSCH weights
control <- function(var) {
  t <- tapply(wd[[WEIGHT_VAR]], wd[[var]], sum)
  setNames(data.frame(names(t), as.numeric(t)), c(var, "Freq"))
}
pop_margins <- list(control("age_sex"), control("race_eth"), control("pov"))

# ---- Part 1: rake equal base weights to control totals ---------------------------
wd$w_base <- sum(wd[[WEIGHT_VAR]]) / nrow(wd)       # equal weights, same total
des_base  <- make_design(wd, weights = "w_base")

des_raked <- rake(des_base,
                  sample.margins = list(~ age_sex, ~ race_eth, ~ pov),
                  population.margins = pop_margins,
                  control = list(maxit = 50, epsilon = 1e-7, verbose = FALSE))

des_final <- make_design(wd)   # official NSCH weights, same records

# Trimming: cap the (much more variable) official weights at 3x the median,
# redistribute the excess, then re-rake so the controls still hold. This
# trades a little potential bias for lower variance (smaller Kish deff).
cap <- 3 * median(weights(des_final))
des_trim <- trimWeights(des_final, upper = cap, strict = TRUE)
des_trim <- rake(des_trim,
                 sample.margins = list(~ age_sex, ~ race_eth, ~ pov),
                 population.margins = pop_margins,
                 control = list(maxit = 50, epsilon = 1e-7))
n_capped <- sum(weights(des_final) > cap)
message("  Trimming capped ", n_capped, " weights (",
        round(100 * n_capped / nrow(wd), 2), "%) at 3x the median")

# Margin check: raked totals should reproduce the controls exactly
margin_check <- do.call(rbind, lapply(seq_along(pop_margins), function(i) {
  v   <- names(pop_margins[[i]])[1]
  got <- svytotal(as.formula(paste0("~", v)), des_raked)
  data.frame(margin = v, level = pop_margins[[i]][[v]],
             control_total = pop_margins[[i]]$Freq,
             raked_total = as.numeric(coef(got)),
             pct_diff = 100 * (as.numeric(coef(got)) / pop_margins[[i]]$Freq - 1))
}))
write_out(round_df(margin_check, 4), "04a_raking_margin_check.csv")

diag_tab <- rbind(
  weight_diag(weights(des_base),  "Equal base weights"),
  weight_diag(weights(des_raked), "Raked to age x sex, race/ethnicity, income"),
  weight_diag(weights(des_final), "Official NSCH final weight (FWC)"),
  weight_diag(weights(des_trim),  "FWC trimmed at 3x median, re-raked")
)
write_out(round_df(diag_tab, 3), "04b_weight_diagnostics.csv")

compare_designs <- function(designs, vars) {
  do.call(rbind, lapply(names(designs), function(lbl) {
    do.call(rbind, lapply(vars, function(v) {
      m <- svymean(as.formula(paste0("~", v)), designs[[lbl]], na.rm = TRUE)
      data.frame(weights = lbl, variable = v,
                 estimate_pct = 100 * as.numeric(coef(m)), se_pct = 100 * as.numeric(SE(m)))
    }))
  }))
}

est_vars <- c("heart_current", "fair_poor_health", "forgone_care", "uninsured")
rake_est <- compare_designs(list(
  "Equal base weights" = des_base,
  "Raked"              = des_raked,
  "Official FWC"       = des_final,
  "FWC trimmed + re-raked" = des_trim), est_vars)
write_out(round_df(rake_est, 3), "04c_estimates_by_weighting_step.csv")

# ---- Part 2: simulated nonresponse + propensity-class adjustment -------------------
# Response depends on income, age and insurance -- variables correlated with
# the outcomes, so an unadjusted respondent analysis is biased.
set.seed(99)
lp <- 0.6 + 0.45 * (as.integer(wd$pov) - 1) - 0.04 * wd$SC_AGE_YEARS -
      0.8 * (wd$uninsured %in% 1)
wd$responded <- runif(nrow(wd)) < plogis(lp)

# Step 1: model response propensity on frame/sample-known variables
ps_fit <- suppressWarnings(glm(responded ~ age_grp + sex + race_eth + pov + uninsured,
              family = binomial, data = wd, weights = wd[[WEIGHT_VAR]] / mean(wd[[WEIGHT_VAR]])))  # non-integer weights warn harmlessly
wd$ps <- predict(ps_fit, newdata = wd, type = "response")

# Step 2: weighting classes = quintiles of estimated propensity
wd$ps_class <- cut(wd$ps, quantile(wd$ps, 0:5 / 5, na.rm = TRUE),
                   include.lowest = TRUE, labels = paste0("Q", 1:5))
adj <- tapply(wd[[WEIGHT_VAR]], wd$ps_class, sum) /
       tapply(wd[[WEIGHT_VAR]] * wd$responded, wd$ps_class, sum)
wd$w_nr <- ifelse(wd$responded, wd[[WEIGHT_VAR]] * adj[as.character(wd$ps_class)], NA)

resp <- wd[wd$responded & !is.na(wd$ps_class), ]
des_full     <- make_design(wd)                      # benchmark: no nonresponse
des_unadj    <- make_design(resp)                    # respondents, base weights
des_nradj    <- make_design(resp, weights = "w_nr")  # propensity-class adjusted
des_nr_raked <- rake(des_nradj,
                     sample.margins = list(~ age_sex, ~ race_eth, ~ pov),
                     population.margins = pop_margins,
                     control = list(maxit = 50, epsilon = 1e-7))

nr_est <- compare_designs(list(
  "Full sample (benchmark)"         = des_full,
  "Respondents, unadjusted"         = des_unadj,
  "Propensity-class NR adjustment"  = des_nradj,
  "NR adjustment + raking"          = des_nr_raked), est_vars)

bench <- nr_est[nr_est$weights == "Full sample (benchmark)", c("variable", "estimate_pct")]
names(bench)[2] <- "benchmark_pct"
nr_est <- merge(nr_est, bench, by = "variable", sort = FALSE)
nr_est$bias_pct_points <- nr_est$estimate_pct - nr_est$benchmark_pct
nr_est$relative_bias_pct <- 100 * nr_est$bias_pct_points / nr_est$benchmark_pct
nr_est <- nr_est[order(nr_est$variable, match(nr_est$weights, unique(nr_est$weights))), ]
write_out(round_df(nr_est, 3), "04d_nonresponse_adjustment_simulation.csv")

class_tab <- data.frame(
  class = names(adj),
  n_sampled = as.numeric(table(wd$ps_class)),
  n_responded = as.numeric(tapply(wd$responded, wd$ps_class, sum)),
  weighted_response_rate_pct = 100 / as.numeric(adj),
  adjustment_factor = as.numeric(adj)
)
write_out(round_df(class_tab, 3), "04e_nonresponse_weighting_classes.csv")

message("  Response rate in simulation: ", round(100 * mean(wd$responded), 1), "%")
