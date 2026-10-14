/*=============================================================================
  chd_registry_analysis.sas
  Birth weight and operative mortality after congenital heart surgery:
  cohort derivation, Table 1, mixed-effects models, trends, hospital volume.

  Data      : de-identified congenital heart surgery registry extract.
              Paths, dataset names and institution identifiers are
              generalised; no patient-level output is included.
  Outcome   : operative mortality (MtOpD; 1 = died, 2 = survived)
  Exposure  : birth weight (categorical and flexible continuous)
  Clustering: patients nested within hospitals (STS_HospID)

=============================================================================*/

/*---------------------------------------------------------------------------
  0. Settings
---------------------------------------------------------------------------*/
%let in_file    = [de-identified-path]/registry_puf.csv;
%let out_path   = [output-path];

/* Hospital-volume threshold (cases/year). Pre-specify from prior
   volume-outcome literature; the continuous form is the primary analysis
   and the dichotomy is reported for comparability only.               */
%let vol_cutoff = 48;

options mprint nofmterr;
ods graphics on / width=7in height=5in;

proc format;
    value mortf   0 = 'Survived' 1 = 'Died';
    value yesnof  0 = 'No' 1 = 'Yes';
run;

/*---------------------------------------------------------------------------
  1. Import
---------------------------------------------------------------------------*/
proc import out=work.registry_raw
            datafile="&in_file"
            dbms=csv replace;
    getnames=yes;
    datarow=2;
    guessingrows=max;     /* avoid truncation / type errors from a short scan */
run;

/*---------------------------------------------------------------------------
  2. Hospital volume -- computed on ALL index operations, before any
     procedure-specific restriction, so it reflects true program volume.
---------------------------------------------------------------------------*/
proc sql;
    create table hosp_volume as
    select STS_HospID,
           count(*)                  as total_procedures,
           count(distinct SurgYear)  as years_participating,
           calculated total_procedures / calculated years_participating
                                     as avg_annual_volume
    from registry_raw
    where IndexProc = 1
    group by STS_HospID;
quit;

title 'Distribution of average annual hospital volume';
proc means data=hosp_volume n p10 p25 median p75 p90 maxdec=1;
    var avg_annual_volume;
run;

/*---------------------------------------------------------------------------
  3. Cohort derivation
     - LENGTH set before first assignment: otherwise SAS fixes the length
       from the first value ('VSD' = 3) and truncates every later label.
     - Every derived variable handles missing explicitly: in SAS a
       missing numeric is smaller than any number, so "x < 2.5" is TRUE
       for missing x.
---------------------------------------------------------------------------*/
data cohort_all;
    length procedure_desc $50 weight_category $10;
    set registry_raw;
    where IndexProc = 1;

    /* Syndrome: any SY_ flag = 1. All flags missing -> missing, not 0. */
    if n(of SY_:) = 0      then syndrome_ = .;
    else if max(of SY_:) = 1 then syndrome_ = 1;
    else                          syndrome_ = 0;

    /* Primary procedure groups */
    select;
        when (primproc in (110, 5001))                          procedure_desc = 'VSD repair';
        when (primproc in (350, 360, 370, 3330, 3340, 5004))   procedure_desc = 'TOF repair';
        when (primproc = 170)                                   procedure_desc = 'AVSD repair';
        when (primproc = 1110)                                  procedure_desc = 'Arterial switch';
        when (primproc = 1120)                                  procedure_desc = 'Arterial switch + VSD repair';
        when (primproc = 230)                                   procedure_desc = 'Truncus repair';
        when (primproc = 870)                                   procedure_desc = 'Norwood';
        when (primproc in (1210,1220,1230,1240,1250,1280,3460,3470))
                                                                procedure_desc = 'Coarctation repair';
        when (primproc in (1670,1680,1690,1700,2130))           procedure_desc = 'Glenn';
        when (primproc in (970,980,1000,1010,2780,2790,3310,3320))
                                                                procedure_desc = 'Fontan';
        otherwise                                               procedure_desc = '';
    end;

    /* Outcome as 0/1 */
    if      MtOpD = 1 then mortality = 1;
    else if MtOpD = 2 then mortality = 0;
    else                   mortality = .;

    /* Birth-weight categories with an explicit missing level */
    if missing(BirthWtKg) or BirthWtKg <= 0 then weight_category = 'Missing';
    else if BirthWtKg < 1 then weight_category = '0-1 kg';
    else if BirthWtKg < 2 then weight_category = '1-2 kg';
    else if BirthWtKg < 3 then weight_category = '2-3 kg';
    else if BirthWtKg < 4 then weight_category = '3-4 kg';
    else if BirthWtKg < 5 then weight_category = '4-5 kg';
    else                       weight_category = '>=5 kg';

    if BirthWtKg > 0 then low_birth_weight = (BirthWtKg < 2.5);
    else                  low_birth_weight = .;

    if not missing(AgeDays) then neonate = (AgeDays <= 28);
    else                         neonate = .;

    /* Bypass and cross-clamp times: zero is a real value (off-bypass),
       so log() would silently set those cases to missing. Use an
       on-bypass indicator plus log(1 + minutes).                      */
    if not missing(CPBTm) then do;
        on_cpb   = (CPBTm > 0);
        log_cpb  = log(1 + CPBTm);
    end;
    if not missing(XClampTm) then log_xclamp = log(1 + XClampTm);

    if WeightKg  > 0 then log_weight   = log(WeightKg);
    if BirthWtKg > 0 then log_birthwt  = log(BirthWtKg);

    /* Age at discharge (days) -- previously labelled TLOS */
    if nmiss(LOS, AgeDays) = 0 then age_at_discharge = LOS + AgeDays;

    /* mortality and syndrome_ stay unformatted: models reference raw codes */
    format low_birth_weight neonate on_cpb yesnof.;
run;

/* Apply exclusions one at a time and record the cohort flow */
data cohort
     excl_noproc excl_singlevent excl_bw excl_outcome;
    set cohort_all;
    if procedure_desc = ''                           then output excl_noproc;
    else if procedure_desc in ('Glenn', 'Fontan')    then output excl_singlevent;
    else if weight_category in ('Missing', '>=5 kg') then output excl_bw;
    else if missing(mortality)                       then output excl_outcome;
    else                                                  output cohort;
run;

proc sql;
    title 'Cohort flow';
    select 'Index operations'                    as step, count(*) as n from cohort_all
    union all select 'Excluded: non-target procedure',      count(*) from excl_noproc
    union all select 'Excluded: Glenn/Fontan',              count(*) from excl_singlevent
    union all select 'Excluded: birth weight missing/>=5kg',count(*) from excl_bw
    union all select 'Excluded: missing operative outcome', count(*) from excl_outcome
    union all select 'Analytic cohort',                     count(*) from cohort;
quit;

/* Attach hospital volume */
proc sql;
    create table cohort_vol as
    select a.*, b.avg_annual_volume,
           case when b.avg_annual_volume >= &vol_cutoff then 'High'
                when not missing(b.avg_annual_volume)   then 'Low'
                else ''                                   end as volume_group length=4,
           b.avg_annual_volume / 10 as volume_per10
    from cohort as a
    left join hosp_volume as b
      on a.STS_HospID = b.STS_HospID;
quit;

data cohort;
    set cohort_vol;
run;

title 'Analytic cohort by procedure';
proc freq data=cohort;
    tables procedure_desc / missing;
run;

/*---------------------------------------------------------------------------
  4. Targeted descriptive questions
---------------------------------------------------------------------------*/
/* Norwood: weight at surgery at least double birth weight, among
   patients operated at <= 90 days (denominator restricted to the same
   age window as the numerator).                                        */
title 'Norwood: weight at surgery >= 2 x birth weight (operated <= 90 days)';
proc sql;
    select count(*)                                          as n_norwood_le90d,
           sum(WeightKg >= 2 * BirthWtKg)                    as n_doubled,
           calculated n_doubled / calculated n_norwood_le90d * 100
                                                             as pct_doubled format=8.1
    from cohort
    where procedure_desc = 'Norwood'
      and 0 <= AgeDays <= 90
      and BirthWtKg > 0 and WeightKg > 0;
quit;

title 'Operative mortality, birth weight < 1 kg';
proc freq data=cohort;
    where weight_category = '0-1 kg';
    tables mortality / binomial(level='1' cl=wilson);
    format mortality mortf.;
run;

/*---------------------------------------------------------------------------
  5. Table 1 macros
     Each macro appends rows to a single long dataset and returns a wide,
     publication-ready table: Overall + one column per group + p-value.
     - Categorical: n (%) ; chi-square, or Fisher exact when any expected
       cell count is < 5
     - Continuous : median [IQR] ; Kruskal-Wallis
---------------------------------------------------------------------------*/
%macro t1_cat(data=, by=, vars=, out=t1_cat_long);
    %local i v minexp;
    proc datasets lib=work nolist nowarn; delete &out; quit;

    %do i = 1 %to %sysfunc(countw(&vars));
        %let v = %scan(&vars, &i);

        /* by-group counts, column %, expected counts */
        proc freq data=&data noprint;
            where not missing(&v) and not missing(&by);
            tables &v * &by / chisq outpct outexpect sparse out=_f;
            output out=_chi chisq;
        run;

        proc sql noprint;
            select min(expected) into :minexp trimmed from _f;
        quit;

        %if %sysevalf(&minexp < 5) %then %do;
            proc freq data=&data noprint;
                where not missing(&v) and not missing(&by);
                tables &v * &by / fisher;
                output out=_p fisher;
            run;
            data _p; length test $15; set _p; p_value = XP2_FISH; test = 'Fisher exact'; keep p_value test; run;
        %end;
        %else %do;
            data _p; length test $15; set _chi; p_value = P_PCHI; test = 'Chi-square'; keep p_value test; run;
        %end;

        /* overall column */
        proc freq data=&data noprint;
            where not missing(&v) and not missing(&by);
            tables &v / out=_tot;
        run;

        data _rows;
            length variable $32 level $50 group $50 stat $30 test $15;
            set _f(in=ingrp) _tot(in=intot);
            variable = "&v";
            level    = strip(vvalue(&v));
            if ingrp then do; group = strip(vvalue(&by)); pct = pct_col; end;
            else          do; group = 'Overall';           pct = percent; end;
            stat = strip(put(count, comma8.)) || ' (' || strip(put(pct, 5.1)) || '%)';
            keep variable level group stat;
        run;

        data _rows;
            if _n_ = 1 then set _p;
            set _rows;
        run;

        proc append base=&out data=_rows force; run;
    %end;
%mend t1_cat;

%macro t1_cont(data=, by=, vars=, out=t1_cont_long);
    %local i v;
    proc datasets lib=work nolist nowarn; delete &out; quit;

    %do i = 1 %to %sysfunc(countw(&vars));
        %let v = %scan(&vars, &i);

        proc means data=&data noprint;
            where not missing(&by);
            class &by;
            var &v;
            output out=_m n=n median=med q1=q1 q3=q3;
        run;

        proc npar1way data=&data wilcoxon noprint;
            where not missing(&by);
            class &by;
            var &v;
            output out=_kw wilcoxon;
        run;

        data _rows;
            length variable $32 level $50 group $50 stat $30 test $15;
            if _n_ = 1 then set _kw(keep=P_KW);
            set _m;
            variable = "&v";
            level    = 'Median [IQR]';
            if _type_ = 0 then group = 'Overall';
            else               group = strip(vvalue(&by));
            stat    = catx(' ', put(med, 8.2), cats('[', put(q1, 8.2), ',', put(q3, 8.2), ']'));
            p_value = P_KW;
            test    = 'Kruskal-Wallis';
            keep variable level group stat p_value test;
        run;

        proc append base=&out data=_rows force; run;
    %end;
%mend t1_cont;

%macro t1_assemble(cat=t1_cat_long, cont=t1_cont_long, out=table1);
    data _all;
        set &cont &cat;
        order = _n_;
    run;

    proc sql;
        create table _keys as
        select variable, level, min(order) as order,
               max(p_value) as p_value, max(test) as test length=15
        from _all group by variable, level;
    quit;

    proc sort data=_all; by variable level; run;
    proc transpose data=_all out=_wide(drop=_name_);
        by variable level;
        id group;
        idlabel group;
        var stat;
    run;

    proc sql;
        create table &out as
        select w.*, k.test,
               case when k.order = (select min(order) from _keys k2
                                    where k2.variable = k.variable)
                    then put(k.p_value, pvalue6.3) else '' end as p_value length=8
        from _wide as w inner join _keys as k
          on w.variable = k.variable and w.level = k.level
        order by k.order;
    quit;
%mend t1_assemble;

data t1_data / view=t1_data;
    set cohort;
    format mortality mortf. syndrome_ yesnof.;
run;

%t1_cont(data=t1_data, by=weight_category,
         vars=BirthWtKg GestAgeWeeks AgeDays WeightKg Heightcm CPBTm XClampTm LOS PLOS);
%t1_cat (data=t1_data, by=weight_category,
         vars=Gender Premature AntenatalDiag syndrome_ OpType ReOpInAdm AgeCat
              Emergency Readmit30 procedure_desc mortality);
%t1_assemble();

title 'Table 1. Patient and operative characteristics by birth-weight category';
proc print data=table1 noobs label;
run;

proc export data=table1 outfile="&out_path/table1.csv" dbms=csv replace; run;

/*---------------------------------------------------------------------------
  6. Mortality models
     - Covariates pre-specified (no stepwise selection, which biases
       coefficients and understates standard errors).
     - Procedure group included to adjust for case mix.
     - Random hospital intercept: patients in the same hospital are not
       independent, and between-hospital variation is of interest itself.
     - Intra-operative times (bypass, cross-clamp) are downstream of
       complexity and birth weight, so adjusting for them can absorb part
       of the exposure effect. They enter a sensitivity model only.
---------------------------------------------------------------------------*/
data model_data;
    set cohort;
    where Premature ne 3;              /* 3 = unknown prematurity status */
run;

%let base_cov = AgeCat Premature syndrome_ procedure_desc;
%let class_cov = AgeCat(ref='Infant') Premature(ref='2') syndrome_(ref='0')
                 procedure_desc(ref='VSD repair');

/* Model A: categorical birth weight */
title 'Model A. Birth-weight category and operative mortality (hospital random intercept)';
proc glimmix data=model_data method=laplace;
    class STS_HospID weight_category(ref='3-4 kg') &class_cov;
    model mortality(event='1') = weight_category &base_cov
          / dist=binary link=logit solution cl oddsratio(label);
    random intercept / subject=STS_HospID;
    covtest zerog;   /* likelihood-ratio test of no between-hospital variance */
    ods output OddsRatios = or_modelA CovParms = cov_modelA;
run;

/* Intraclass correlation on the latent logistic scale */
data icc_modelA;
    set cov_modelA;
    where CovParm = 'Intercept';
    icc = Estimate / (Estimate + constant('pi')**2 / 3);
run;
title 'Hospital-level ICC (latent scale)';
proc print data=icc_modelA noobs; var Estimate icc; format icc 6.3; run;

/* Model B: flexible continuous birth weight (natural cubic spline).
   Prediction grid rows (missing outcome) are appended so GLIMMIX scores
   them without using them in estimation; NOBLUP gives the population-
   average (fixed-effects) prediction, independent of the hospital.     */
data bw_grid;
    if _n_ = 1 then set model_data(keep=STS_HospID AgeCat obs=1);
    grid = 1;
    mortality = .;
    /* Reference profile -- verify codes against the data dictionary */
    AgeCat = 'Neonate'; Premature = 2; syndrome_ = 0;
    procedure_desc = 'Arterial switch';
    do BirthWtKg = 0.6 to 4.9 by 0.1;
        output;
    end;
run;

data model_b_in;
    set model_data bw_grid;
run;

title 'Model B. Birth weight as a restricted cubic spline';
proc glimmix data=model_b_in method=laplace;
    class STS_HospID &class_cov;
    effect bw_spline = spline(BirthWtKg / naturalcubic basis=tpf(noint)
                                          knotmethod=percentiles(4));
    model mortality(event='1') = bw_spline &base_cov
          / dist=binary link=logit solution;
    random intercept / subject=STS_HospID;
    output out=model_b_out pred(noblup ilink)=xb lcl(noblup ilink)=lcl
                           ucl(noblup ilink)=ucl;
run;

data bw_pred;
    set model_b_out;
    where grid = 1;
run;

title 'Predicted operative mortality by birth weight (Model B, reference covariates)';
proc sgplot data=bw_pred;
    band x=BirthWtKg lower=lcl upper=ucl / transparency=0.6;
    series x=BirthWtKg y=xb / lineattrs=(thickness=2);
    xaxis label='Birth weight (kg)';
    yaxis label='Predicted probability of operative mortality';
run;

/* Model C: hospital volume, continuous (per 10 cases/year) and dichotomous */
title 'Model C. Hospital volume and mortality';
proc glimmix data=model_data method=laplace;
    class STS_HospID weight_category(ref='3-4 kg') &class_cov;
    model mortality(event='1') = volume_per10 weight_category &base_cov
          / dist=binary link=logit solution cl oddsratio(label);
    random intercept / subject=STS_HospID;
run;

title "Model C2. High (>= &vol_cutoff/yr) vs low volume";
proc glimmix data=model_data method=laplace;
    class STS_HospID volume_group(ref='Low') weight_category(ref='3-4 kg') &class_cov;
    model mortality(event='1') = volume_group weight_category &base_cov
          / dist=binary link=logit solution cl oddsratio(label);
    random intercept / subject=STS_HospID;
run;

/* Sensitivity: add intra-operative times */
title 'Sensitivity. Model A + bypass and cross-clamp times';
proc glimmix data=model_data method=laplace;
    class STS_HospID weight_category(ref='3-4 kg') &class_cov;
    model mortality(event='1') = weight_category &base_cov on_cpb log_cpb log_xclamp
          / dist=binary link=logit solution cl oddsratio(label);
    random intercept / subject=STS_HospID;
run;

/* Forest plot of Model A odds ratios */
title 'Adjusted odds ratios for operative mortality (Model A)';
proc sgplot data=or_modelA noautolegend;
    scatter y=Label x=Estimate / xerrorlower=Lower xerrorupper=Upper
            markerattrs=(symbol=circlefilled size=9);
    refline 1 / axis=x lineattrs=(pattern=shortdash);
    xaxis type=log logbase=10 grid label='Adjusted odds ratio (95% CI)';
    yaxis display=(nolabel) discreteorder=data;
run;

/*---------------------------------------------------------------------------
  7. Temporal trends
     Replaces the first-year vs last-year % change, which depends on two
     noisy points, ignores intervening years, and divides by zero when a
     procedure is absent in its first year.
---------------------------------------------------------------------------*/
/* Annual counts per procedure in the 1.5-2.0 kg stratum, zeros included */
proc freq data=cohort noprint;
    where 1.5 <= WeightKg <= 2.0;
    tables procedure_desc * SurgYear / sparse out=proc_counts(keep=procedure_desc SurgYear count);
run;

proc sort data=proc_counts; by procedure_desc SurgYear; run;

/* Log-linear trend: annual % change with Pearson-scaled SEs for
   overdispersion                                                       */
title 'Annual % change in procedure counts, 1.5-2.0 kg (Poisson, Pearson scale)';
proc genmod data=proc_counts;
    by procedure_desc;
    model count = SurgYear / dist=poisson link=log scale=pearson;
    estimate 'Annual trend (log rate ratio)' SurgYear 1;
    ods output Estimates = trend_est;
run;

data trend_est;
    set trend_est;
    annual_pct_change = (exp(LBetaEstimate) - 1) * 100;
    lcl_pct = (exp(LBetaLowerCL) - 1) * 100;
    ucl_pct = (exp(LBetaUpperCL) - 1) * 100;
run;
proc print data=trend_est noobs;
    var procedure_desc annual_pct_change lcl_pct ucl_pct ProbChiSq;
    format annual_pct_change lcl_pct ucl_pct 8.1 ProbChiSq pvalue6.4;
run;

/* Proportion preterm by year: Cochran-Armitage test for trend */
data preterm_trend;
    set cohort;
    where Premature in (1, 2);
    preterm = (Premature = 1);
run;

title 'Preterm birth by surgical year (Cochran-Armitage trend test)';
proc freq data=preterm_trend;
    tables preterm * SurgYear / trend nopercent norow;
    ods output TrendTest = preterm_trend_test;
run;

proc sql;
    create table preterm_by_year as
    select SurgYear, count(*) as n, mean(preterm) * 100 as pct_preterm
    from preterm_trend group by SurgYear;
quit;

proc sgplot data=preterm_by_year;
    series x=SurgYear y=pct_preterm / markers;
    xaxis label='Surgical year' integer;
    yaxis label='Preterm (%)';
run;

/*---------------------------------------------------------------------------
  8. Mortality by weight at surgery, by procedure
     Weight is binned (0.5 kg) so each point has a meaningful denominator;
     grouping by the raw continuous value gave one point per distinct
     weight. Wilson 95% intervals.
---------------------------------------------------------------------------*/
data cohort_bins;
    set cohort;
    if WeightKg > 0 then weight_bin = floor(WeightKg / 0.5) * 0.5 + 0.25;
run;

proc sql;
    create table mort_by_bin as
    select procedure_desc, weight_bin,
           count(*) as n, sum(mortality) as deaths,
           calculated deaths / calculated n as p
    from cohort_bins
    where not missing(weight_bin)
    group by procedure_desc, weight_bin
    having n >= 10;
quit;

data mort_by_bin;
    set mort_by_bin;
    z = 1.96;
    centre = (p + z**2 / (2 * n)) / (1 + z**2 / n);
    half   = z * sqrt(p * (1 - p) / n + z**2 / (4 * n**2)) / (1 + z**2 / n);
    pct = 100 * p; lcl = 100 * (centre - half); ucl = 100 * (centre + half);
run;

title 'Operative mortality by weight at surgery (bins with n >= 10)';
proc sgpanel data=mort_by_bin;
    panelby procedure_desc / columns=4 novarname;
    scatter x=weight_bin y=pct / yerrorlower=lcl yerrorupper=ucl
            markerattrs=(symbol=circlefilled);
    colaxis label='Weight at surgery (kg, 0.5 kg bins)';
    rowaxis label='Mortality (%)';
run;

title 'Age at surgery by operative outcome';
proc sgplot data=cohort;
    vbox AgeDays / category=mortality group=procedure_desc;
    xaxis label='Operative outcome';
    yaxis label='Age at surgery (days)';
run;

/*---------------------------------------------------------------------------
  9. Non-linear age effects (generalised additive models)
     A GAM with a binomial likelihood replaces LOESS on a 0/1 outcome,
     which ignores the binomial variance and can predict outside [0, 1].
---------------------------------------------------------------------------*/
title 'Neonatal coarctation repair: mortality by age at surgery (GAM)';
proc gam data=cohort plots=components(clm commonaxes);
    where procedure_desc = 'Coarctation repair' and 0 <= AgeDays <= 30;
    model mortality(event='1') = spline(AgeDays, df=3) / dist=binomial;
run;

title 'Norwood: mortality by age at surgery (GAM)';
proc gam data=cohort plots=components(clm);
    where procedure_desc = 'Norwood' and not missing(AgeDays);
    model mortality(event='1') = spline(AgeDays, df=3) / dist=binomial;
run;

/*---------------------------------------------------------------------------
  10. Prematurity and low birth weight by hospital-volume group
---------------------------------------------------------------------------*/
title 'Prematurity by hospital-volume group';
proc freq data=model_data;
    tables Premature * volume_group / chisq nopercent norow;
run;

title 'Low birth weight by hospital-volume group';
proc freq data=cohort;
    tables low_birth_weight * volume_group / chisq nopercent norow;
run;

title;
