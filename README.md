# Statistical Research Portfolio

Biostatistician with 12+ years in pediatric health research. This portfolio covers design-based survey analysis, clinical registry analysis, and evaluation-focused AI.

| Project | Focus | Tools |
|---|---|---|
| [01 · NSCH survey analysis](01-nsch-survey-heart-conditions/) | Complex survey design, weighting, raking, nonresponse adjustment, Taylor vs replicate variance, domain estimation, multiple-imputation inference | R (`survey`, `mitools`), SAS (`PROC SURVEY*`, `MIANALYZE`) |
| [02 · CHD registry analysis](02-chd-registry-sas/) | Cohort derivation, automated Table 1, hospital-clustered mixed models, splines, trend and volume-outcome analysis | SAS (`GLIMMIX`, `GENMOD`, `GAM`, macros) |
| [03 · CHD Family Copilot](03-chd-family-copilot/) | Multi-agent LLM assistant with rule-based safety triage, evidence grounding, claim verification, and governance logging | Python |

## Highlights

- **Survey statistics end to end.** The NSCH project uses the national survey's own design (weights, state × stratum strata, household clusters, six income implicates). It shows how each analytic choice changes estimates and standard errors.
- **Reproducible without restricted data.** A structurally identical synthetic NSCH file is generated on demand, so every table and figure can be rebuilt with one command.
- **Clinical depth.** Registry analyses account for case mix and hospital clustering and use pre-specified models, not data-driven selection.

## Contact

www.linkedin.com/in/rittalmehta    · [Google Scholar](https://scholar.google.com/rittalmehta)
