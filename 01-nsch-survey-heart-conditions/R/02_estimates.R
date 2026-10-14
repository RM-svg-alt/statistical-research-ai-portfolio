# =============================================================================
# 02_estimates.R
# Design-based descriptive estimates.
#   A. Prevalence of a current heart condition: unweighted vs weighted
#   B. Prevalence by subgroup (logit-transformed CIs, Rao-Scott tests)
#   C. Health and access outcomes compared across heart-condition domains
#   D. Design effects
#   E. Why domain analysis matters: correct vs incorrect subpopulation SEs
# =============================================================================

if (!exists("des")) source(file.path(PROJECT_DIR, "R", "01_prepare.R"))

message("\n== 02 Descriptive estimates ==")

# ---- A. Unweighted vs weighted prevalence -------------------------------------
unw  <- mean(nsch$heart_current, na.rm = TRUE)
unw_se <- sqrt(unw * (1 - unw) / sum(!is.na(nsch$heart_current)))
wtd  <- svyciprop(~ heart_current, des, method = "logit", na.rm = TRUE)

prev_compare <- data.frame(
  approach     = c("Unweighted (ignores design)", "Design-based (weights, strata, clusters)"),
  estimate_pct = 100 * c(unw, coef(wtd)),
  se_pct       = 100 * c(unw_se, SE(wtd)),
  lcl_pct      = 100 * c(unw - 1.96 * unw_se, confint(wtd)[1]),
  ucl_pct      = 100 * c(unw + 1.96 * unw_se, confint(wtd)[2])
)
write_out(round_df(prev_compare, 3), "02a_prevalence_weighted_vs_unweighted.csv")

# ---- B. Prevalence by subgroup -------------------------------------------------
by_vars <- c(age_grp = "Age group", sex = "Sex", race_eth = "Race/ethnicity",
             pov = "Household income (implicate 1)", uninsured = "Uninsured")

subgroup_rows <- lapply(names(by_vars), function(v) {
  f   <- as.formula(paste0("~", v))
  est <- svyby(~ heart_current, f, des, svyciprop, method = "logit",
               vartype = c("se", "ci"), na.rm = TRUE)
  # Rao-Scott second-order corrected test of association
  test <- svychisq(as.formula(paste0("~ heart_current + ", v)), des,
                   statistic = "F")
  data.frame(characteristic = by_vars[[v]],
             level          = as.character(est[[v]]),
             estimate_pct   = 100 * as.numeric(coef(est)),
             se_pct         = 100 * as.numeric(SE(est)),
             lcl_pct        = 100 * est$ci_l,
             ucl_pct        = 100 * est$ci_u,
             rao_scott_p    = c(test$p.value, rep(NA, nrow(est) - 1)))
})
prev_subgroup <- do.call(rbind, subgroup_rows)
is_ins <- prev_subgroup$characteristic == "Uninsured"
prev_subgroup$level[is_ins] <- c("0" = "No", "1" = "Yes")[prev_subgroup$level[is_ins]]
write_out(round_df(prev_subgroup, 3), "02b_prevalence_by_subgroup.csv")

# Figure: prevalence by income with 95% CIs
pov_rows <- prev_subgroup[prev_subgroup$characteristic == by_vars[["pov"]], ]
png(file.path(OUTPUT_DIR, "fig1_prevalence_by_income.png"),
    width = 1600, height = 1000, res = 200)
par(mar = c(5, 9, 3, 2))
y <- rev(seq_len(nrow(pov_rows)))
plot(pov_rows$estimate_pct, y, xlim = c(0, max(pov_rows$ucl_pct) * 1.15),
     yaxt = "n", pch = 19, xlab = "Weighted prevalence, % (95% CI)", ylab = "",
     main = "Current heart condition by household income")
segments(pov_rows$lcl_pct, y, pov_rows$ucl_pct, y, lwd = 2)
axis(2, at = y, labels = pov_rows$level, las = 1)
grid(ny = NA)
dev.off()
message("  wrote output/fig1_prevalence_by_income.png")

# ---- C. Outcomes by heart-condition domain -------------------------------------
outcomes <- c(fair_poor_health = "Fair or poor general health",
              forgone_care     = "Needed care not received (past 12 months)",
              uninsured        = "Currently uninsured")

domain_rows <- lapply(names(outcomes), function(y) {
  est  <- svyby(as.formula(paste0("~", y)), ~ heart_grp, des, svyciprop,
                method = "logit", vartype = c("se", "ci"), na.rm = TRUE)
  test <- svychisq(as.formula(paste0("~", y, " + heart_grp")), des,
                   statistic = "F")
  data.frame(outcome      = outcomes[[y]],
             group        = as.character(est$heart_grp),
             estimate_pct = 100 * as.numeric(coef(est)),
             se_pct       = 100 * as.numeric(SE(est)),
             lcl_pct      = 100 * est$ci_l,
             ucl_pct      = 100 * est$ci_u,
             rao_scott_p  = c(test$p.value, NA))
})
domain_tab <- do.call(rbind, domain_rows)
write_out(round_df(domain_tab, 3), "02c_outcomes_by_heart_condition.csv")

# ---- D. Design effects -------------------------------------------------------------
deff_rows <- lapply(c("heart_current", names(outcomes)), function(y) {
  m <- svymean(as.formula(paste0("~", y)), des, na.rm = TRUE, deff = TRUE)
  data.frame(variable = y, estimate_pct = 100 * as.numeric(coef(m)),
             se_pct = 100 * as.numeric(SE(m)), deff = as.numeric(deff(m)))
})
deff_tab <- do.call(rbind, deff_rows)
write_out(round_df(deff_tab, 3), "02d_design_effects.csv")

# ---- E. Domain estimation: right vs wrong ---------------------------------------------
# Estimate: % with forgone care among children WITH a current heart condition.
#   Correct  : subset() the full design -> all strata/PSUs retained for variance
#   Incorrect: drop rows first, then build a new design on the subset
#   Naive    : unweighted binomial SE
dom_ok   <- subset(des, heart_current == 1)
right    <- svyciprop(~ forgone_care, dom_ok, method = "logit", na.rm = TRUE)

sub_df   <- nsch[nsch$heart_current %in% 1, ]
des_bad  <- make_design(sub_df)
wrong    <- svyciprop(~ forgone_care, des_bad, method = "logit", na.rm = TRUE)

p_naive  <- mean(sub_df$forgone_care, na.rm = TRUE)
se_naive <- sqrt(p_naive * (1 - p_naive) / sum(!is.na(sub_df$forgone_care)))

domain_demo <- data.frame(
  approach = c("Domain estimation on full design (correct)",
               "Design rebuilt on subset (strata dropped)",
               "Unweighted binomial (ignores design)"),
  estimate_pct = 100 * c(coef(right), coef(wrong), p_naive),
  se_pct       = 100 * c(SE(right), SE(wrong), se_naive),
  strata_in_variance = c(nlevels(nsch$strata_id),
                         length(unique(as.character(sub_df$strata_id))),
                         NA)
)
write_out(round_df(domain_demo, 4), "02e_domain_estimation_demo.csv")
