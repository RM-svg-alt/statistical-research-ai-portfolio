# Birth Weight and Operative Mortality after Congenital Heart Surgery

SAS analysis of a de-identified congenital heart surgery registry extract. It covers cohort derivation, automated Table 1, hospital-clustered mixed-effects models, flexible dose-response modeling, temporal trends, and volume-outcome analysis.

> Dataset names, file paths, and institution identifiers are generalized. No patient-level data or output is included.

## Question

How does birth weight relate to operative mortality across eight common congenital heart operations? Is that relationship modified by hospital volume once case mix and clustering of patients within hospitals are accounted for?

## Methods

**Cohort derivation**
- Index operations grouped into eight target procedures.
- Single-ventricle palliation (Glenn and Fontan) excluded.
- Every exclusion counted in a cohort-flow table.
- Derived variables handle missing values explicitly (in SAS, missing sorts below every number).
- Zero bypass times are kept as real values via an on-bypass indicator.

**Table 1 automation**
- Reusable macros (`%t1_cat`, `%t1_cont`, `%t1_assemble`) produce a publication-ready table: n (%) or median [IQR] by group, plus an overall column.
- Chi-square or Fisher's exact test is chosen automatically from expected cell counts; Kruskal-Wallis for continuous variables.
- Results are exported to CSV.

**Mortality models** (`PROC GLIMMIX`, Laplace estimation)
- Random hospital intercept, a likelihood-ratio test of between-hospital variance, and the intraclass correlation.
- Pre-specified covariates, including procedure group for case mix. No stepwise selection.
- Birth weight modeled both as categories and as a natural cubic spline, with population-average predicted mortality and a confidence band.
- Hospital volume modeled continuously (per 10 cases/year) and as a pre-specified dichotomy.
- Sensitivity model adding intra-operative times, which lie downstream of the exposure.

**Trends and description**
- Annual percent change in procedure counts from log-linear Poisson models with Pearson-scaled standard errors.
- Cochran-Armitage test for trend in prematurity.
- Binned mortality curves with Wilson intervals.
- Binomial GAMs for non-linear age-at-surgery effects in neonatal coarctation repair and Norwood.

## Skills demonstrated

| Area | Procedures |
|---|---|
| Data management | `PROC IMPORT`, DATA step, `SELECT/WHEN`, `PROC SQL` joins and aggregation |
| Macro programming | Parameterized, `%LOCAL`-scoped macros that build and assemble output datasets |
| Hypothesis testing | `PROC FREQ` (chi-square, Fisher, trend), `PROC NPAR1WAY` |
| Mixed models | `PROC GLIMMIX` with random effects, `EFFECT` splines, `COVTEST`, `OUTPUT` scoring |
| Count models | `PROC GENMOD` Poisson with overdispersion scaling |
| Smoothing | `PROC GAM` |
| Graphics | `PROC SGPLOT` / `SGPANEL` forest plots, prediction bands, panel plots |

## Running

1. Set `in_file`, `out_path`, and `vol_cutoff` at the top of `chd_registry_analysis.sas`.
2. Confirm the coding of `AgeCat`, `Premature`, and `MtOpD` against the registry data dictionary.
