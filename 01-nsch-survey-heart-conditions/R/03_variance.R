# =============================================================================
# 03_variance.R
# Variance estimation: Taylor-series linearization vs replicate weights.
#
# NSCH public files support linearization (strata + clusters). Many NORC
# deliverables instead ship replicate weights, so this script converts the
# design to Rao-Wu-Yue-Beaumont subsample bootstrap replicates and compares
# standard errors for the same estimands.
# =============================================================================

if (!exists("des")) source(file.path(PROJECT_DIR, "R", "01_prepare.R"))

message("\n== 03 Variance estimation ==")

N_REPS <- as.integer(Sys.getenv("N_BOOT_REPS", unset = "200"))

# Replicate methods need >= 2 PSUs per stratum. Collapse any undersized
# stratum into the other stratum of the same state (standard practice when
# building replicate weights), then build BOTH designs on the collapsed
# strata so the comparison isolates the variance method.
psu_per_stratum <- tapply(nsch[[CLUSTER_VAR]], nsch$strata_id,
                          function(x) length(unique(x)))
small <- names(psu_per_stratum)[psu_per_stratum < 2]
nsch$strata_coll <- as.character(nsch$strata_id)
for (s in small) {
  state <- sub("\\..*$", "", s)
  partners <- setdiff(grep(paste0("^", state, "\\."), names(psu_per_stratum), value = TRUE), s)
  if (length(partners)) nsch$strata_coll[nsch$strata_coll == s] <- partners[1]
}
nsch$strata_coll <- factor(nsch$strata_coll)
message("  Collapsed ", length(small), " single-PSU strata for replicate weights")

des_coll <- svydesign(ids = as.formula(paste0("~", CLUSTER_VAR)), strata = ~ strata_coll,
                      weights = as.formula(paste0("~", WEIGHT_VAR)),
                      data = nsch, nest = TRUE)
rep_des <- as.svrepdesign(des_coll, type = "subbootstrap", replicates = N_REPS)

collapse_log <- data.frame(original_stratum = small,
                           collapsed_into = vapply(small, function(s)
                             as.character(nsch$strata_coll[nsch$strata_id == s][1]), ""))
write_out(collapse_log, "03_strata_collapsing_log.csv")

estimands <- list(
  list(label = "Current heart condition, all children",
       f = ~ heart_current, dom = NULL),
  list(label = "Current heart condition, <100% FPL",
       f = ~ heart_current, dom = quote(pov == "<100% FPL")),
  list(label = "Forgone care, children with a current heart condition",
       f = ~ forgone_care, dom = quote(heart_current == 1)),
  list(label = "Fair/poor health, children with a current heart condition",
       f = ~ fair_poor_health, dom = quote(heart_current == 1))
)

est_one <- function(design, e) {
  d <- if (is.null(e$dom)) design else do.call(subset, list(design, e$dom))
  svymean(e$f, d, na.rm = TRUE)
}

rows <- lapply(estimands, function(e) {
  tl <- est_one(des_coll, e)
  bs <- est_one(rep_des, e)
  # SRS reference: same weighted point estimate, binomial SE on the domain n
  dom_rows <- if (is.null(e$dom)) rep(TRUE, nrow(nsch)) else
    eval(e$dom, nsch) %in% TRUE
  y <- nsch[dom_rows, all.vars(e$f)]
  n <- sum(!is.na(y))
  p <- as.numeric(coef(tl))
  data.frame(estimand       = e$label,
             n_unweighted   = n,
             estimate_pct   = 100 * p,
             se_srs_pct     = 100 * sqrt(p * (1 - p) / n),
             se_taylor_pct  = 100 * as.numeric(SE(tl)),
             se_bootstrap_pct = 100 * as.numeric(SE(bs)),
             ratio_boot_to_taylor = as.numeric(SE(bs) / SE(tl)))
})
var_tab <- do.call(rbind, rows)
write_out(round_df(var_tab, 4), "03_variance_taylor_vs_bootstrap.csv")

message("  Taylor and bootstrap SEs agree within ",
        round(100 * max(abs(var_tab$ratio_boot_to_taylor - 1)), 1),
        "% across estimands (", N_REPS, " replicates)")
