# =============================================================================
# 05_models.R
# Survey-weighted regression with multiply imputed household income.
#
# NSCH imputes household income as % of the federal poverty level six times
# (FPL_I1-FPL_I6). Using one implicate understates uncertainty. Here each
# model is fit on all six completed datasets under the full design and the
# results are combined with Rubin's rules (mitools::MIcombine).
# =============================================================================

if (!exists("des")) source(file.path(PROJECT_DIR, "R", "01_prepare.R"))

message("\n== 05 Models with multiply imputed income ==")

# One completed dataset per implicate, each with `pov` from that implicate
imp_list <- lapply(seq_along(FPL_IMPLICATES), function(m) {
  d <- nsch
  d$pov <- d[[paste0("pov_", m)]]
  d
})

des_mi <- svydesign(ids     = as.formula(paste0("~", CLUSTER_VAR)),
                    strata  = ~ strata_id,
                    weights = as.formula(paste0("~", WEIGHT_VAR)),
                    data    = imputationList(imp_list),
                    nest    = TRUE)

# ---- A. Prevalence by income, combined across implicates -------------------------
prev_mi <- MIcombine(with(des_mi,
  svyby(~ heart_current, ~ pov, svymean, na.rm = TRUE)))
ci <- confint(prev_mi)
prev_pov_mi <- data.frame(
  income = sub("^pov", "", names(coef(prev_mi))),
  estimate_pct = 100 * coef(prev_mi),
  se_pct = 100 * sqrt(diag(vcov(prev_mi))),
  lcl_pct = 100 * ci[, 1], ucl_pct = 100 * ci[, 2],
  fraction_missing_info = prev_mi$missinfo,
  row.names = NULL)
write_out(round_df(prev_pov_mi, 3), "05a_prevalence_by_income_MI.csv")

# ---- B. Logistic models ---------------------------------------------------------------
rhs <- "heart_grp + age_grp + sex + race_eth + pov + uninsured"

fit_mi <- function(outcome) {
  f <- as.formula(paste(outcome, "~", rhs))
  fits <- with(des_mi, svyglm(f, family = quasibinomial()))
  MIcombine(fits)
}

tidy_or <- function(mi, outcome_label) {
  b  <- coef(mi)
  se <- sqrt(diag(vcov(mi)))
  df <- mi$df
  t  <- b / se
  data.frame(outcome = outcome_label,
             term = names(b),
             odds_ratio = exp(b),
             lcl = exp(b - qt(0.975, df) * se),
             ucl = exp(b + qt(0.975, df) * se),
             p_value = 2 * pt(-abs(t), df),
             fraction_missing_info = mi$missinfo,
             row.names = NULL)[-1, ]   # drop intercept
}

m_forgone <- fit_mi("forgone_care")
m_health  <- fit_mi("fair_poor_health")

or_tab <- rbind(tidy_or(m_forgone, "Needed care not received"),
                tidy_or(m_health,  "Fair or poor general health"))
or_tab$term <- sub("^heart_grp", "", or_tab$term)
or_tab$term <- sub("^age_grp", "Age ", or_tab$term)
or_tab$term <- sub("^sex|^race_eth", "", or_tab$term)
or_tab$term <- sub("^pov", "Income ", or_tab$term)
or_tab$term <- sub("^uninsured$", "Uninsured", or_tab$term)
write_out(round_df(or_tab, 3), "05b_adjusted_odds_ratios_MI.csv")

# ---- C. Why combine implicates: single implicate vs Rubin's rules -------------------
single <- svyglm(as.formula(paste("forgone_care ~", rhs)), des, family = quasibinomial())
pov_terms <- grep("^pov", names(coef(single)), value = TRUE)
mi_vs_single <- data.frame(
  term = pov_terms,
  log_or_single = coef(single)[pov_terms],
  se_single     = SE(single)[pov_terms],
  log_or_mi     = coef(m_forgone)[pov_terms],
  se_mi         = sqrt(diag(vcov(m_forgone)))[pov_terms],
  row.names = NULL)
mi_vs_single$se_inflation_pct <- 100 * (mi_vs_single$se_mi / mi_vs_single$se_single - 1)
write_out(round_df(mi_vs_single, 4), "05c_single_implicate_vs_MI.csv")

# Figure: adjusted ORs for forgone care
fo <- or_tab[or_tab$outcome == "Needed care not received", ]
png(file.path(OUTPUT_DIR, "fig2_forgone_care_odds_ratios.png"),
    width = 1800, height = 1300, res = 200)
par(mar = c(5, 15, 3, 2))
y <- rev(seq_len(nrow(fo)))
plot(fo$odds_ratio, y, log = "x", xlim = range(c(fo$lcl, fo$ucl)), yaxt = "n",
     pch = 19, xlab = "Adjusted odds ratio (95% CI, log scale)", ylab = "",
     main = "Needed care not received: survey-weighted logistic model\n(income combined over 6 implicates)")
mtext("Reference: no heart condition, age 0-5, male, NH White, <100% FPL, insured",
      side = 3, line = 0.2, cex = 0.75)
segments(fo$lcl, y, fo$ucl, y, lwd = 2)
abline(v = 1, lty = 2)
axis(2, at = y, labels = fo$term, las = 1, cex.axis = 0.8)
dev.off()
message("  wrote output/fig2_forgone_care_odds_ratios.png")
