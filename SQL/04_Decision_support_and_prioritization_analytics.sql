SET search_path TO hospital_readmission;

SELECT * FROM diabetic_readmission;
SELECT * FROM admission_type;
SELECT * FROM admission_source;
SELECT * FROM discharge_disposition;
SELECT * FROM vw_features;

/* #########################################################################################################################################
======================================================= Follow-up Prioritization ==========================================================
Objective: Translate the strongest historical associations into a transparent, capacity-aware follow-up prioritization framework for hospital 
           care-management teams.
=========================================================================================================================================== */
SELECT * FROM diabetic_readmission
SELECT DISTINCT inpt_bkt FROM vw_features

-- 1 — Transparent Historical Priority Score
-- Can we construct a transparent, rule-based prioritization score using only patient and encounter characteristics that demonstrated 
-- meaningful historical associations with 30-day readmission in the earlier analyses?

-- Rule evidence
WITH r AS (
 SELECT 'Prior inpatient stay (1+)' AS rules, CASE WHEN number_inpatient  >= 1 THEN 1 ELSE 0 END AS hit, readmit_30d FROM vw_features
 UNION ALL 
 SELECT 'Prior ER visit (1+)', CASE WHEN number_emergency >= 1 THEN 1 ELSE 0 END, readmit_30d FROM vw_features
 UNION ALL 
 SELECT 'Prior outpatient visit (1+)', CASE WHEN number_outpatient >= 1 THEN 1 ELSE 0 END, readmit_30d FROM vw_features
 UNION ALL 
 SELECT 'Discharged to non-home setting', CASE WHEN discharge_disposition_grp IN (
 						'Rehab / long-term care','Other inpatient / transfer','SNF / nursing facility','Home health','Left AMA') 
 							THEN 1 ELSE 0 END, readmit_30d FROM vw_features
 UNION ALL 
 SELECT 'Stay of 4+ days', CASE WHEN time_in_hospital >= 4 THEN 1 ELSE 0 END, readmit_30d FROM vw_features
 UNION ALL 
 SELECT '9+ diagnoses', CASE WHEN number_diagnoses >= 9 THEN 1 ELSE 0 END, readmit_30d FROM vw_features
 UNION ALL 
 SELECT '16+ medications', CASE WHEN num_medications >= 16 THEN 1 ELSE 0 END, readmit_30d FROM vw_features
 UNION ALL 
 SELECT 'Insulin dose changed (Up/Down)', CASE WHEN insulin IN ('Up','Down') THEN 1 ELSE 0 END, readmit_30d FROM vw_features
 UNION ALL 
 SELECT 'Primary diagnosis = diabetes', CASE WHEN dg1_grp = 'Diabetes' THEN 1 ELSE 0 END, readmit_30d FROM vw_features
 UNION ALL 
 SELECT 'Age 70+', CASE WHEN age_grp = '70+' THEN 1 ELSE 0 END, readmit_30d FROM vw_features)
SELECT rules, SUM(hit) AS n_with,SUM(1-hit),
       ROUND(100.0*SUM(CASE WHEN hit = 1 THEN readmit_30d ELSE 0 END)/SUM(hit),2)   AS rate_with_pct,
       ROUND(100.0*SUM(CASE WHEN hit = 0 THEN readmit_30d ELSE 0 END)/SUM(1-hit),2) AS rate_without_pct,
       ROUND((1.0*SUM(CASE WHEN hit = 1 THEN readmit_30d ELSE 0 END)/SUM(hit)) /
             (1.0*SUM(CASE WHEN hit = 0 THEN readmit_30d ELSE 0 END)/SUM(1-hit)),2) AS rate_ratio
FROM r GROUP BY rules ORDER BY rate_ratio DESC;

-- Actual Query: The score. Strong factors get graded points and weak ones get 1 point
CREATE OR REPLACE VIEW vw_scored AS
WITH pts AS (
  SELECT f.*,
    CASE WHEN number_inpatient >= 3 THEN 3 ELSE number_inpatient END AS pts_prior_inpatient,  -- 0-3
    CASE WHEN number_emergency >= 2 THEN 2 ELSE number_emergency END AS pts_prior_er, -- 0-2
    CASE WHEN number_outpatient >= 1 THEN 1 ELSE 0 END AS pts_prior_outpatient,  -- 0-1
    CASE WHEN discharge_disposition_grp IN ('Rehab / long-term care','Other inpatient / transfer') THEN 2
         WHEN discharge_disposition_grp IN ('SNF / nursing facility','Home health','Left AMA') THEN 1
         ELSE 0 END AS pts_discharge,        -- 0-2
    CASE WHEN time_in_hospital >= 4 THEN 1 ELSE 0 END AS pts_stay_4plus,
    CASE WHEN number_diagnoses >= 9 THEN 1 ELSE 0 END AS pts_dx_count_9plus,
    CASE WHEN num_medications >= 16 THEN 1 ELSE 0 END AS pts_meds_16plus,
    CASE WHEN insulin IN ('Up','Down') THEN 1 ELSE 0 END AS pts_insulin_change,
    CASE WHEN dg1_grp = 'Diabetes' THEN 1 ELSE 0 END AS pts_primary_dx_diabetes,
    CASE WHEN age_grp = '70+' THEN 1 ELSE 0 END AS pts_age_70plus
  FROM vw_features f)
SELECT *,
       pts_prior_inpatient + pts_prior_er + pts_prior_outpatient + pts_discharge
     + pts_stay_4plus + pts_dx_count_9plus + pts_meds_16plus + pts_insulin_change
     + pts_primary_dx_diabetes + pts_age_70plus AS risk_score -- 0 to 14
FROM pts;

-- 2 — Score Performance
-- How effectively does the rule-based score separate encounters into Low, Medium, and High historical readmission-rate groups, 
-- and how does the observed 30-day readmission rate change across score levels and score deciles?

-- By score level (the exact view, free of tie issues)
SELECT risk_score, 
	COUNT(*) AS n_encounter, 
	SUM(readmit_30d) AS readmits_30d,
    ROUND(100.0*AVG(readmit_30d),2) AS rate_pct,
    ROUND(AVG(readmit_30d)/(SELECT AVG(readmit_30d) FROM vw_scored),2) AS lift
FROM vw_scored GROUP BY risk_score ORDER BY risk_score DESC;


-- Tier
SELECT 
	CASE WHEN risk_score >= 7 THEN 'High (7+)' 
		 WHEN risk_score >= 4 THEN 'Medium (4-6)' 
		 ELSE 'Low (0-3)' 
	END AS risk_tier,
    COUNT(*) AS n_encounter,
    ROUND(100.0*COUNT(*)/(SELECT COUNT(*) FROM vw_scored),1) AS pct_of_encounters,
    SUM(readmit_30d) AS readmits_30d,
    ROUND(100.0*AVG(readmit_30d),2) AS readmit_rate_pct,
    ROUND(AVG(readmit_30d)/(SELECT AVG(readmit_30d) FROM vw_scored),2) AS lift,
    ROUND(100.0*SUM(readmit_30d)/(SELECT SUM(readmit_30d) FROM vw_scored),2) AS pct_of_all_readmits
FROM vw_scored GROUP BY 1 ORDER BY MIN(risk_score) DESC;

-- Deciles (decile 1 is the highest-scored 10%):
WITH d AS (
  SELECT risk_score, readmit_30d,
         NTILE(10) OVER (ORDER BY risk_score DESC, encounter_id) AS decile
  FROM vw_scored)
SELECT decile, COUNT(*) AS n, MAX(risk_score) AS max_score, MIN(risk_score) AS min_score,
       SUM(readmit_30d) AS readmits_30d,
       ROUND(100.0*AVG(readmit_30d),2) AS rate_pct,
       ROUND(AVG(readmit_30d)/(SELECT AVG(readmit_30d) FROM vw_scored),2) AS lift,
       ROUND(100.0*SUM(readmit_30d)/SUM(SUM(readmit_30d)) OVER (),1) AS pct_of_all_readmits,
       ROUND(100.0*SUM(SUM(readmit_30d)) OVER (ORDER BY decile)/SUM(SUM(readmit_30d)) OVER (),1) AS cumulative_pct
FROM d GROUP BY decile ORDER BY decile;
-- 3 — Follow-up Capacity / Gains
-- If the hospital could provide intensive follow-up to only the top 10%, 20%, or 30% of encounters ranked by the historical 
-- priority score, what proportion of all observed 30-day readmissions would fall within those groups?

-- Follow-up capacity (gains)
WITH ranked AS (
  SELECT risk_score, readmit_30d,
         ROW_NUMBER() OVER (ORDER BY risk_score DESC, encounter_id) AS rn,
         COUNT(*) OVER () AS total_n,
         SUM(readmit_30d) OVER () AS total_x
  FROM vw_scored),
cov AS (SELECT 10 AS pct UNION ALL SELECT 20 UNION ALL SELECT 30)
SELECT c.pct AS pct_of_encounters_followed_up,
       COUNT(*) AS encounters_followed,
       MIN(r.risk_score) AS lowest_score_included,
       SUM(r.readmit_30d) AS readmits_captured,
       ROUND(100.0*AVG(r.readmit_30d),2) AS rate_in_group_pct,
       ROUND(100.0*SUM(r.readmit_30d)/MAX(r.total_x),1) AS pct_of_all_readmits_captured,
       ROUND((100.0*SUM(r.readmit_30d)/MAX(r.total_x))/c.pct,2) AS gain_vs_random
FROM cov c JOIN ranked r ON r.rn <= c.pct/100.0*r.total_n
GROUP BY c.pct ORDER BY c.pct;

-- 4 — Hypothetical Impact
-- Under an explicitly stated hypothetical assumption that post-discharge follow-up reduces readmission among followed-up patients by 10–20%,
-- how many 30-day readmissions could theoretically be avoided per 10,000 discharges at different follow-up coverage levels?

-- Assumption (state this in your README). Intensive follow-up reduces the 30-day readmission probability of each followed-up patient 
-- by a relative 10–20%, applied equally to everyone followed, with no spillover to others and no effect on the other patients. 
-- This is a hypothetical scenario, not an estimate from the data. 
-- The true effect is unknown and may well be smaller for lower-risk patients.

WITH ranked AS (
  SELECT readmit_30d,
         ROW_NUMBER() OVER (ORDER BY risk_score DESC, encounter_id) AS rn,
         COUNT(*) OVER () AS total_n,
         SUM(readmit_30d) OVER () AS total_x
  FROM vw_scored),
cov AS (SELECT 10 AS pct UNION ALL SELECT 20 UNION ALL SELECT 30 UNION ALL SELECT 40 UNION ALL SELECT 50),
g AS (
  SELECT c.pct, COUNT(*) AS n_followed, SUM(r.readmit_30d) AS x_captured,
         MAX(r.total_n) AS total_n, MAX(r.total_x) AS total_x
  FROM cov c JOIN ranked r ON r.rn <= c.pct/100.0*r.total_n
  GROUP BY c.pct)
SELECT pct AS coverage_pct,
       ROUND(10000.0*total_x/total_n)            AS baseline_readmits_per_10k,
       ROUND(10000.0*n_followed/total_n)         AS followed_up_per_10k,
       ROUND(10000.0*x_captured*0.10/total_n,1)  AS avoided_per_10k_at_10pct_effect,
       ROUND(10000.0*x_captured*0.15/total_n,1)  AS avoided_per_10k_at_15pct_effect,
       ROUND(10000.0*x_captured*0.20/total_n,1)  AS avoided_per_10k_at_20pct_effect,
       ROUND(1.0*n_followed/(x_captured*0.10),1) AS followups_per_avoided_at_10pct,
       ROUND(1.0*n_followed/(x_captured*0.20),1) AS followups_per_avoided_at_20pct
FROM g ORDER BY pct;

-- P7.5 — Final Priority Recommendations
-- Which patient profiles should the hospital consider for prioritized post-discharge follow-up based on historical readmission rate, 
-- lift versus baseline, population volume, share of readmissions captured, and the characteristics defining each profile?

-- Profiles are assigned in order, first match wins, so each encounter belongs to only one profile and the shares can be added together.
WITH base AS (
  SELECT COUNT(*) AS total_n, SUM(readmit_30d) AS total_x, AVG(readmit_30d) AS p0 FROM vw_scored),
prof AS (
  SELECT s.*,
    CASE
      WHEN number_inpatient >= 3
        THEN 'A. 3+ prior inpatient stays'
      WHEN discharge_disposition_grp IN ('Rehab / long-term care','Other inpatient / transfer')
        THEN 'B. Discharged to rehab / long-term care / other inpatient transfer'
      WHEN number_inpatient >= 1
       AND discharge_disposition_grp IN ('SNF / nursing facility','Home health','Left AMA')
        THEN 'C. 1-2 prior inpatient stays + SNF / home-health / AMA discharge'
      WHEN risk_score >= 7 OR number_emergency >= 2
        THEN 'D. Other: score 7+ or 2+ prior ER visits'
      ELSE 'Not prioritized' END AS profile
  FROM vw_scored s)
SELECT profile,
       COUNT(*) AS n,
       ROUND(100.0*COUNT(*)/b.total_n,1) AS pct_of_encounters,
       SUM(readmit_30d) AS readmits_30d,
       ROUND(100.0*AVG(readmit_30d),2) AS rate_pct,
       ROUND(AVG(readmit_30d)/b.p0,2) AS lift,
       ROUND(SUM(readmit_30d) - COUNT(*)*b.p0,0) AS excess_readmits,
       ROUND(100.0*SUM(readmit_30d)/b.total_x,1) AS pct_of_all_readmits,
       CASE WHEN AVG(readmit_30d)/b.p0 >= 2.0 THEN 'Tier 1 - intensive'
            WHEN AVG(readmit_30d)/b.p0 >= 1.4 THEN 'Tier 2 - enhanced'
            WHEN AVG(readmit_30d)/b.p0 >= 1.2 THEN 'Tier 3 - targeted'
            ELSE 'Standard care' END AS suggested_priority
FROM prof, base b
GROUP BY profile, b.total_n, b.total_x, b.p0
ORDER BY CASE WHEN profile = 'Not prioritized' THEN 1 ELSE 0 END, lift DESC;