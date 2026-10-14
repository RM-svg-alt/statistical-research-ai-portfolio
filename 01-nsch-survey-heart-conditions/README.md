# Children with Heart Conditions in the National Survey of Children's Health

Design-based analysis of a complex national survey: weighting, variance estimation, domain estimation, and inference with multiply imputed data. Every step is implemented in **R** (`survey`, `mitools`) and mirrored in **SAS** (`PROC SURVEY*`, `PROC MIANALYZE`).

## Research questions

1. What share of U.S. children have a current heart condition, and how does prevalence vary by age, sex, race/ethnicity, and household income?
2. Do children with a current heart condition differ in general health, forgone care, and insurance coverage?
3. Is a current heart condition associated with needed care not received, after adjusting for demographics, income, and insurance?

## Data

**NSCH Topical public-use file** (U.S. Census Bureau / HRSA MCHB). This is a nationally representative, address-based survey of children aged 0–17.

| Design element | Variable | Use |
|---|---|---|
| Final child weight | `FWC` | All estimates |
| Strata | `FIPSST` × `STRATUM` | State by sampling stratum |
| Clusters | `HHID` | One sampled child per household |
| Imputed income | `FPL_I1`–`FPL_I6` | Six implicates, combined with Rubin's rules |

**No download needed to reproduce.** `R/make_synthetic_nsch.R` writes a synthetic file with identical variable names, codes, and design structure. It builds in differential nonresponse by income and age, so the weighting methods have something to correct. The figures in `output/` come from that synthetic file and illustrate the methods; they are not substantive findings.

To use real data, place the NSCH Topical file (`.dta` or `.sas7bdat`) in `data/` and run:

```bash
NSCH_FILE=nsch_2023e_topical.dta NSCH_YEAR=2023 Rscript R/run_all.R
```

## Methods

| Script | What it demonstrates |
|---|---|
| `01_prepare.R` | Validates design variables. Recodes with explicit valid-code checks and a legitimate-skip rule for `HEART_CURR`. Reports item missingness and the Kish design effect from weighting. |
| `02_estimates.R` | Weighted vs unweighted prevalence, logit-transformed CIs, Rao-Scott chi-square tests, and design effects. Includes a side-by-side comparison of correct domain estimation (`subset()` on the full design) against two common mistakes. |
| `03_variance.R` | Taylor linearization vs subsample bootstrap replicate weights for the same estimands. Collapses single-PSU strata with a logged audit trail. |
| `04_weighting.R` | Raking to age × sex, race/ethnicity, and income controls with margin checks. Weight diagnostics (CV, Kish deff, effective n). Trimming followed by re-raking. A simulated nonresponse study comparing unadjusted, propensity-class adjusted, and adjusted + calibrated estimators against a known benchmark. |
| `05_models.R` | Survey-weighted logistic regression fit on all six income implicates and combined with Rubin's rules (fraction of missing information reported). Quantifies how much a single-implicate analysis understates standard errors. |

`sas/nsch_survey_analysis.sas` covers the same steps with `SURVEYFREQ`, `SURVEYMEANS` (`DOMAIN`, `DEFF`, `VARMETHOD=BOOTSTRAP`), `SURVEYLOGISTIC` + `MIANALYZE`, and a reusable raking macro.

## What the synthetic run shows

These are methodological points, using synthetic data:

- **Domain estimation.** Rebuilding the design on a subset kept only 78 of 102 strata in the variance calculation. Ignoring the design altogether understated the standard error by about 14%.
- **Variance methods.** Taylor and bootstrap standard errors agreed within roughly 10% across estimands. Design effects ranged from 1.2 to 1.3.
- **Weighting.** Raking equal base weights to three margins moved every estimate most of the way to the fully weighted value. Under simulated nonresponse, the propensity-class adjustment cut the bias in the uninsured rate roughly in half. Calibration to margins that excluded insurance could not remove the rest, which illustrates why the adjustment model must include the drivers of response.
- **Multiple imputation.** Combining six income implicates inflated the standard errors of the income coefficients by 4–17% compared with using implicate 1 alone.

Full tables are in `output/` as CSV files.

## Run

```bash
Rscript R/run_all.R      # about 10–15 minutes; generates synthetic data if none is present
```

Requires R ≥ 4.1 with `survey` and `mitools` (and `haven` to read the real `.dta`/`.sas7bdat` files). `output/sessionInfo.txt` records package versions.

## Structure

```
R/          analysis pipeline (run_all.R runs everything)
sas/        SAS implementation of the same analysis
data/       input data (git-ignored; synthetic file regenerated on demand)
output/     tables (CSV) and figures (PNG)
```
