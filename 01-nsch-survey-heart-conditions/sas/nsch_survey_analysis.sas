/*=============================================================================
  nsch_survey_analysis.sas
  SAS counterpart of the R pipeline: design-based estimation for children
  with a current heart condition in the National Survey of Children's Health.

  Design (Census Bureau guidance for the NSCH Topical file):
    WEIGHT  FWC              child-level final weight
    STRATA  FIPSST STRATUM   state x sampling stratum
    CLUSTER HHID             household

  Sections
    0. Setup and data step recodes
    1. Weighted vs unweighted prevalence
    2. Prevalence by subgroup (Rao-Scott chi-square)
    3. Outcomes in the heart-condition domain (DOMAIN analysis, not WHERE)
    4. Design effects
    5. Survey logistic models over the six FPL implicates + PROC MIANALYZE
    6. Replicate-weight (bootstrap) variance for comparison
    7. Raking demonstration with a reusable macro

  Verify variable codes against the codebook for the survey year you use.
=============================================================================*/

%let nsch_path = /path/to/data;          /* folder holding the NSCH SAS file   */
%let nsch_file = nsch_2023e_topical;     /* dataset name without extension     */
%let out_path  = /path/to/output;

libname nschlib "&nsch_path";
ods graphics on;

/*-----------------------------------------------------------------------------
  0. Recodes. Keep the FULL sample: subpopulations are analysed as domains.
-----------------------------------------------------------------------------*/
proc format;
    value heartf   0 = 'No current heart condition'
                   1 = 'Current heart condition';
    value yesnof   0 = 'No' 1 = 'Yes';
    value agegrpf  1 = '0-5' 2 = '6-11' 3 = '12-17';
    value racef    1 = 'NH White' 2 = 'Hispanic' 3 = 'NH Black'
                   4 = 'NH Asian' 5 = 'NH Other/Multiple';
    value povf     1 = '<100% FPL' 2 = '100-199% FPL'
                   3 = '200-399% FPL' 4 = '400%+ FPL';
run;

data nsch;
    set nschlib.&nsch_file;

    /* Current heart condition. Children never told (HEART=2) are
       legitimately skipped out of HEART_CURR and coded 0.             */
    if      HEART = 2                     then heart_current = 0;
    else if HEART = 1 and HEART_CURR = 1  then heart_current = 1;
    else if HEART = 1 and HEART_CURR = 2  then heart_current = 0;
    else                                       heart_current = .;

    /* Outcomes: explicit valid-code checks so missing never
       falls into a category (in SAS, missing < any number).          */
    if K2Q01 in (1,2,3)      then fair_poor_health = 0;
    else if K2Q01 in (4,5)   then fair_poor_health = 1;
    else                          fair_poor_health = .;

    if      K4Q27 = 1 then forgone_care = 1;
    else if K4Q27 = 2 then forgone_care = 0;
    else                   forgone_care = .;

    if      CURRCOV = 2 then uninsured = 1;
    else if CURRCOV = 1 then uninsured = 0;
    else                     uninsured = .;

    /* Covariates */
    if      0  <= SC_AGE_YEARS <= 5  then age_grp = 1;
    else if 6  <= SC_AGE_YEARS <= 11 then age_grp = 2;
    else if 12 <= SC_AGE_YEARS <= 17 then age_grp = 3;

    if SC_SEX in (1,2) then female = (SC_SEX = 2);

    if      SC_HISPANIC_R = 1        then race_eth = 2;
    else if SC_RACE_R = 1            then race_eth = 1;
    else if SC_RACE_R = 2            then race_eth = 3;
    else if SC_RACE_R = 4            then race_eth = 4;
    else if SC_RACE_R in (3,5,6,7)   then race_eth = 5;

    /* Poverty category for each of the six income implicates */
    array fpl {6} FPL_I1-FPL_I6;
    array pov {6} pov1-pov6;
    do m = 1 to 6;
        if      missing(fpl{m})  then pov{m} = .;
        else if fpl{m} < 100     then pov{m} = 1;
        else if fpl{m} < 200     then pov{m} = 2;
        else if fpl{m} < 400     then pov{m} = 3;
        else                          pov{m} = 4;
    end;
    drop m;

    format heart_current heartf. fair_poor_health forgone_care uninsured yesnof.
           age_grp agegrpf. race_eth racef. pov1-pov6 povf.;
run;

/* Design checks: positive weights, one child per household */
proc sql;
    select count(*)                        as n_records,
           sum(FWC <= 0 or missing(FWC))   as bad_weights,
           count(distinct HHID)            as n_households,
           sum(FWC)                        as sum_weights format=comma15.
    from nsch;
quit;

/*-----------------------------------------------------------------------------
  1. Weighted vs unweighted prevalence of a current heart condition
-----------------------------------------------------------------------------*/
title '1a. Unweighted prevalence (ignores the design)';
proc freq data=nsch;
    tables heart_current / binomial(level='Current heart condition');
run;

title '1b. Design-based prevalence (logit CI)';
proc surveyfreq data=nsch;
    strata  FIPSST STRATUM;
    cluster HHID;
    weight  FWC;
    tables heart_current / cl(type=logit) deff;
run;

/*-----------------------------------------------------------------------------
  2. Prevalence by subgroup with Rao-Scott second-order chi-square
-----------------------------------------------------------------------------*/
title '2. Current heart condition by subgroup';
proc surveyfreq data=nsch;
    strata  FIPSST STRATUM;
    cluster HHID;
    weight  FWC;
    tables (age_grp female race_eth pov1 uninsured) * heart_current
           / row cl(type=logit) chisq(secondorder);
    ods output CrossTabs = prev_by_subgroup ChiSq = prev_chisq;
run;

/*-----------------------------------------------------------------------------
  3. Outcomes by heart-condition domain.
     The domain is a ROW variable of the table (equivalently a DOMAIN
     statement in SURVEYMEANS). Never use WHERE/BY to drop rows: that
     discards strata and PSUs and gives wrong standard errors.
-----------------------------------------------------------------------------*/
title '3a. Outcomes by heart-condition domain';
proc surveyfreq data=nsch;
    strata  FIPSST STRATUM;
    cluster HHID;
    weight  FWC;
    tables heart_current * (fair_poor_health forgone_care uninsured)
           / row cl(type=logit) chisq(secondorder);
    ods output CrossTabs = outcomes_by_domain;
run;

title '3b. Same estimates via DOMAIN statement';
proc surveymeans data=nsch mean clm nobs;
    strata  FIPSST STRATUM;
    cluster HHID;
    weight  FWC;
    var    fair_poor_health forgone_care uninsured;
    domain heart_current;
run;

/*-----------------------------------------------------------------------------
  4. Design effects
-----------------------------------------------------------------------------*/
title '4. Design effects';
proc surveymeans data=nsch mean stderr deff;
    strata  FIPSST STRATUM;
    cluster HHID;
    weight  FWC;
    var heart_current fair_poor_health forgone_care uninsured;
run;

/*-----------------------------------------------------------------------------
  5. Survey logistic regression over the six income implicates, combined
     with Rubin's rules in PROC MIANALYZE. Fitting one implicate only
     understates the uncertainty from imputed income.
-----------------------------------------------------------------------------*/
%macro mi_combine(outcome=, out=);
    %local m plist;
    %do m = 1 %to 6;
        proc surveylogistic data=nsch;
            strata  FIPSST STRATUM;
            cluster HHID;
            weight  FWC;
            /* Unformatted numeric levels keep parameter names short and
               identical across implicates (e.g. pov_1, race_eth_3).     */
            format heart_current age_grp race_eth pov&m;
            class heart_current(ref='0') age_grp(ref='1') race_eth(ref='1')
                  pov&m(ref='4') / param=ref;
            model &outcome(event='1') = heart_current age_grp female race_eth
                                        pov&m uninsured;
            ods output ParameterEstimates = _pe&m;
        run;

        data _pe&m;
            set _pe&m;
            length Parameter $32;
            _Imputation_ = &m;
            if missing(ClassVal0) then Parameter = tranwrd(Variable, "pov&m", "pov");
            else Parameter = cats(tranwrd(Variable, "pov&m", "pov"), '_', ClassVal0);
            keep _Imputation_ Parameter Estimate StdErr;
        run;
    %end;

    data &out._stack;
        set _pe1-_pe6;
    run;
    proc sort data=&out._stack;
        by _Imputation_;
    run;

    /* Parameter names, in model order, for the MODELEFFECTS statement */
    proc sql noprint;
        select distinct Parameter into :plist separated by ' '
        from &out._stack;
    quit;

    /* Rubin's rules */
    proc mianalyze parms=&out._stack;
        modeleffects &plist;
        ods output ParameterEstimates = &out VarianceInfo = &out._varinfo;
    run;

    data &out;
        set &out;
        odds_ratio = exp(Estimate);
        or_lcl     = exp(LCLMean);
        or_ucl     = exp(UCLMean);
    run;

    title "5. &outcome: adjusted odds ratios, income combined over 6 implicates";
    title2 "Reference levels: no heart condition, age 0-5, NH White, 400%+ FPL";
    proc print data=&out noobs;
        where Parm ne 'Intercept';
        var Parm odds_ratio or_lcl or_ucl DF Probt;
        format odds_ratio or_lcl or_ucl 8.3 Probt pvalue6.4;
    run;
    title2;
%mend mi_combine;

%mi_combine(outcome=forgone_care,     out=or_forgone);
%mi_combine(outcome=fair_poor_health, out=or_health);

/*-----------------------------------------------------------------------------
  6. Replicate-weight variance (bootstrap) for comparison with Taylor
     linearization. SAS builds the replicates from the strata/cluster design.
     Strata with a single PSU must be collapsed first for replicate methods.
-----------------------------------------------------------------------------*/
title '6. Bootstrap replicate variance';
proc surveymeans data=nsch varmethod=bootstrap(reps=200 seed=20261014) mean stderr;
    strata  FIPSST STRATUM;
    cluster HHID;
    weight  FWC;
    var    heart_current forgone_care fair_poor_health;
    domain heart_current;
run;

/*-----------------------------------------------------------------------------
  7. Raking (iterative proportional fitting) to control totals.
     Demonstrates the calibration step: equal base weights are raked to
     margins computed from the official weights, which they should recover.
-----------------------------------------------------------------------------*/
%macro rake(data=, out=, wt_in=, wt_out=, margins=, maxit=50, tol=1e-6);
    /* &margins: space-separated list of margin variables. For each
       variable V a control dataset CTRL_V must exist with columns V and
       target (the population total for that level).                    */
    %local i n v iter done _notconv;
    %let n = %sysfunc(countw(&margins));

    data &out;
        set &data;
        &wt_out = &wt_in;
    run;

    %let done = 0;
    %do iter = 1 %to &maxit;
        %if &done = 0 %then %do;
            %let done = 1;
            %do i = 1 %to &n;
                %let v = %scan(&margins, &i);

                proc sql noprint;
                    create table _adj as
                    select c.&v, c.target / sum(o.&wt_out) as factor
                    from &out as o inner join ctrl_&v as c on o.&v = c.&v
                    group by c.&v, c.target;

                    /* converged when every adjustment factor is ~1 */
                    select (max(abs(factor - 1)) > &tol) into :_notconv trimmed
                    from _adj;
                quit;
                %if &_notconv = 1 %then %let done = 0;

                proc sql;
                    create table _raked as
                    select o.*, o.&wt_out * a.factor as _w
                    from &out as o left join _adj as a on o.&v = a.&v;
                quit;
                data &out;
                    set _raked;
                    &wt_out = _w;
                    drop _w;
                run;
            %end;
            %if &done = 1 %then %put NOTE: Raking converged after &iter iterations.;
        %end;
    %end;
    %if &done = 0 %then %put WARNING: Raking did not converge in &maxit iterations.;
%mend rake;

/* Complete cases on raking variables, equal base weights */
data rake_in;
    set nsch;
    where not missing(age_grp) and not missing(female)
          and not missing(race_eth) and not missing(pov1);
    age_sex = cats(age_grp, '_', female);
run;

proc sql noprint;
    select sum(FWC) / count(*) into :w_equal from rake_in;
quit;

data rake_in;
    set rake_in;
    w_base = &w_equal;
run;

/* Control totals from the official weight */
proc sql;
    create table ctrl_age_sex  as select age_sex,  sum(FWC) as target from rake_in group by age_sex;
    create table ctrl_race_eth as select race_eth, sum(FWC) as target from rake_in group by race_eth;
    create table ctrl_pov1     as select pov1,     sum(FWC) as target from rake_in group by pov1;
quit;

%rake(data=rake_in, out=raked, wt_in=w_base, wt_out=w_raked,
      margins=age_sex race_eth pov1);

/* Weight diagnostics: CV and Kish design effect due to weighting */
title '7a. Weight diagnostics';
proc sql;
    select 'Equal base' as weights,  min(w_base) as min, max(w_base) as max,
           std(w_base)/mean(w_base)  as cv, 1 + (std(w_base)/mean(w_base))**2 as kish_deff
    from raked
    union all
    select 'Raked',  min(w_raked), max(w_raked),
           std(w_raked)/mean(w_raked), 1 + (std(w_raked)/mean(w_raked))**2
    from raked
    union all
    select 'Official FWC', min(FWC), max(FWC),
           std(FWC)/mean(FWC), 1 + (std(FWC)/mean(FWC))**2
    from raked;
quit;

title '7b. Prevalence under each weight';
%macro est_under(wt=);
    proc surveymeans data=raked mean stderr;
        strata  FIPSST STRATUM;
        cluster HHID;
        weight  &wt;
        var heart_current forgone_care fair_poor_health uninsured;
    run;
%mend est_under;
%est_under(wt=w_base);
%est_under(wt=w_raked);
%est_under(wt=FWC);

title;
