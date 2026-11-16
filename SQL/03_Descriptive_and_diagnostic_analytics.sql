SET search_path TO hospital_readmission;

SELECT * FROM diabetic_readmission;
SELECT * FROM admission_type;
SELECT * FROM admission_source;
SELECT * FROM discharge_disposition;
SELECT * FROM vw_features;

/* #########################################################################################################################################
================================================== A. Hospital Readmission Landscape ==========================================================

Business Question : How significant is the 30-day readmission problem among diabetic inpatient encounters?
  ########################################################################################################################################## */
-- What share of encounters are <30, >30 and NO? What is the baseline 30-day rate?
 -- a. share of encounters 
SELECT readmitted, COUNT(*) AS n_encounter,
	ROUND(100.0 * COUNT(*)/SUM(COUNT(*)) OVER(),2) AS share_pct
FROM diabetic_readmission GROUP BY readmitted ORDER BY n_encounter DESC

 -- b. The baseline 30-day rate
SELECT COUNT(*) AS Total_encounter , SUM(readmit_30d) AS readmitted,
	ROUND(AVG(readmit_30d)*100,2) AS baseline_30d_rate_pct
FROM diabetic_readmission

-- What is the 30-day rate at encounter level versus patient level (first encounter only)? 
WITH rank_by_encounter AS (
	SELECT *, ROW_NUMBER() OVER(PARTITION BY patient_nbr ORDER BY encounter_id) AS rn  FROM diabetic_readmission
   )
SELECT 'All Encounter' AS cohort , COUNT(*) AS encounters, ROUND(AVG(readmit_30d)*100,2) AS rate_pct FROM diabetic_readmission
UNION ALL
SELECT 'First Encounter Per Patient', COUNT(*), ROUND(AVG(readmit_30d)*100,2) FROM rank_by_encounter WHERE rn = 1

-- How many patients have more than one encounter? Do those patients have a higher 30-day rate?
WITH patient_encounter AS (
	SELECT patient_nbr,COUNT(*) as enc_count FROM diabetic_readmission GROUP BY patient_nbr
	)
SELECT 
	CASE WHEN enc_count = 1 THEN '1' WHEN pc.enc_count = 2 THEN '2' WHEN enc_count BETWEEN 3 AND 5 THEN '3-5'
		WHEN enc_count BETWEEN 6 AND 10 THEN '6-9' ELSE '9+' END AS encounters_per_patient,
	COUNT(*) AS total_encounter,
	SUM(readmit_30d) AS readmitted,
	ROUND(AVG(readmit_30d)*100,2) AS rate_pct,
	-- ROUND(AVG(readmit_30d)/(SELECT AVG(readmit_30d) FROM diabetic_readmission),2) AS lift,
	ROUND(AVG(dr.readmit_30d)/p0(),2) AS lift
FROM patient_encounter pc 
JOIN diabetic_readmission dr USING(patient_nbr)
GROUP BY 1 ORDER BY 1

-- Concentration of readmissions in frequent patients
-- Whether a small group of patients drives a large share of the 30-day readmissions.
WITH pt AS (
  SELECT patient_nbr, 
  	COUNT(*) AS total_encounter, 
	SUM(readmit_30d) AS n_readmit_in_30days
  FROM diabetic_readmission 
  GROUP BY patient_nbr)
SELECT 
	CASE WHEN total_encounter = 1 THEN '1 encounter' 
		 WHEN total_encounter = 2 THEN '2 encounters'
         WHEN total_encounter <= 5 THEN '3-5 encounters' 
		 ELSE '6+ encounters' 
	END AS patient_volume,
	COUNT(patient_nbr) AS patients,
	SUM(total_encounter) AS n_encounters,
	SUM(n_readmit_in_30days) AS total_readmits_30d,
 ROUND(100.0*SUM(total_encounter)/SUM(SUM(total_encounter)) OVER (),1) AS pct_of_encounters,
 ROUND(100.0*SUM(n_readmit_in_30days)/SUM(SUM(n_readmit_in_30days)) OVER (),1) AS pct_of_all_30d_readmits
FROM pt 
GROUP BY 1 ORDER BY MIN(total_encounter);

-- Segment Templete
	-- a. Create a 'VIEW' table for Hospital Readmission Landscape
CREATE VIEW vw_landscape AS
SELECT *,
       ROW_NUMBER() OVER (PARTITION BY patient_nbr ORDER BY encounter_id) AS enc_seq,
       COUNT(*) OVER (PARTITION BY patient_nbr)AS patient_enc_cnt
FROM diabetic_readmission ;

SELECT * FROM vw_landscape
	-- b.  Create some Segment Templete as a landscape
WITH seg AS (
  SELECT '1. Overall' AS dimension,
  	'All encounters' AS segment,
  	 readmit_30d, readmitted 
  FROM vw_landscape
  UNION ALL
  SELECT '2. Encounter sequence',
         CASE WHEN enc_seq = 1 THEN 'First encounter' ELSE 'Repeat encounter (2nd+)' END,
         readmit_30d, readmitted
  FROM vw_landscape
  UNION ALL
  SELECT '3. Position in patient history',
         CASE WHEN enc_seq = 1 THEN '1st' WHEN enc_seq = 2 THEN '2nd' WHEN enc_seq = 3 THEN '3rd' ELSE '4th+' END,
         readmit_30d, readmitted
  FROM vw_landscape
  UNION ALL
  SELECT '4. Patient volume',
         CASE WHEN patient_enc_cnt = 1 THEN '1 encounter' WHEN patient_enc_cnt = 2 THEN '2 encounters'
              WHEN patient_enc_cnt <= 5 THEN '3-5 encounters' ELSE '6+ encounters' END,
         readmit_30d, readmitted
  FROM vw_landscape
  UNION ALL
  SELECT '5. Index vs returning',
         CASE WHEN number_inpatient = 0 THEN 'No inpatient stay in prior year' ELSE '1+ inpatient stay in prior year' END,
         readmit_30d, readmitted
  FROM vw_landscape
)
SELECT dimension, segment,
       COUNT(*) AS n_encounter,
       SUM(readmit_30d) AS readmits_30d,
       ROUND(100*AVG(readmit_30d),2) AS rate_30d_pct,
       ROUND(AVG(readmit_30d)/p0(),2) AS lift,
       ROUND(100*wilson_low(SUM(readmit_30d), COUNT(*)),2) AS ci_low,
       ROUND(100*wilson_high(SUM(readmit_30d), COUNT(*)),2) AS ci_high,
       ROUND(100.0*COUNT(*) FILTER (WHERE readmitted = '>30')/COUNT(*),2) AS pct_after_30d,
       ROUND(100.0*COUNT(*) FILTER (WHERE readmitted = 'NO') /COUNT(*),2) AS pct_not_readmitted
FROM seg
GROUP BY dimension, segment
ORDER BY dimension, segment;


/* #######################################################################################################################################
============================================= B. Patient Profile & 30-Day Readmission =======================================================

Business Question : Which patient characteristics are associated with higher historical 30-day readmission rates?
Objective: Determine whether demographic and payer characteristics are associated with differences in historical 30-day readmission rates.
 ######################################################################################################################################### */
 
-- # How does the historical 30-day readmission rate vary across age groups, and which age groups have readmission rates above the overall baseline?
SELECT age_grp, COUNT(*) AS n_encounter,
	SUM(readmit_30d) AS n_readmission,
	ROUND(AVG(readmit_30d)*100,2) AS readmit_rate_pct,
	ROUND(100.0*AVG(readmit_30d)/p0(),2) AS lift,
	ROUND(100*wilson_low(SUM(readmit_30d), COUNT(*)),2) AS ci_low,
	ROUND(100*wilson_high(SUM(readmit_30d), COUNT(*)),2) AS ci_high
FROM vw_features
GROUP BY age_grp
ORDER BY MIN(age_grp)

-- # How do historical 30-day readmission rates differ across gender and race groups, and which observed differences remain meaningful 
--   after considering the confidence intervals and the size of each group?

   -- a. 30-day rate by gender
SELECT 'Gender' AS dimesion, COALESCE(gender,'Invalid') AS Segment,
	COUNT(*) AS n_encounter,
	SUM(readmit_30d) AS n_readmission,
	ROUND(AVG(readmit_30d)*100,2) AS readmit_rate_pct,
	ROUND(100.0*AVG(readmit_30d)/p0(),2) AS lift,
	ROUND(100*wilson_low(SUM(readmit_30d), COUNT(*)),2) AS ci_low,
	ROUND(100*wilson_high(SUM(readmit_30d), COUNT(*)),2) AS ci_high
FROM diabetic_readmission 
GROUP BY gender ORDER BY MIN(gender)

   -- b. 30-day rate by race
SELECT 'Race', COALESCE(race,'Missing'),
	COUNT(*) AS n_encounter,
	SUM(readmit_30d) AS n_readmission,
	ROUND(AVG(readmit_30d)*100,2) AS readmit_rate_pct,
	ROUND(100.0*AVG(readmit_30d)/p0(),2) AS lift,
	ROUND(100*wilson_low(SUM(readmit_30d), COUNT(*)),2) AS ci_low,
	ROUND(100*wilson_high(SUM(readmit_30d), COUNT(*)),2) AS ci_high
FROM diabetic_readmission 
GROUP BY race ORDER BY MIN(race)

-- # How does the historical 30-day readmission rate vary across payer groups such as Medicare, Medicaid, commercial/private insurance, 
--   self-pay, and other coverage types, and which payer groups are above or below the overall baseline?

-- And separately: Not Done Yet
-- What proportion of encounters has missing or unknown payer information, 
-- and how might this limitation affect the interpretation of payer-level results?

SELECT payer_grp,
	COUNT(*) AS n_encounter,
	SUM(readmit_30d) AS n_readmission,
	ROUND(AVG(readmit_30d)*100,2) AS readmit_rate_pct,
	ROUND(100.0*AVG(readmit_30d)/p0(),2) AS lift,
	ROUND(100*wilson_low(SUM(readmit_30d), COUNT(*)),2) AS ci_low,
	ROUND(100*wilson_high(SUM(readmit_30d), COUNT(*)),2) AS ci_high
FROM vw_features
GROUP BY payer_grp ORDER BY payer_grp

-- # Within each major payer group, particularly Medicare, does the historical 30-day readmission rate vary across age groups, 
--   and which age–payer combinations show the highest observed readmission rates?

  -- a. MATRIX Table
SELECT payer_grp,age_grp,
	COUNT(*) AS n_encounter,
	SUM(readmit_30d) AS n_readmission,
	ROUND(AVG(readmit_30d)*100,2) AS readmit_rate_pct,
	ROUND(100.0*AVG(readmit_30d)/p0(),2) AS lift
FROM vw_features
GROUP BY payer_grp,age_grp HAVING COUNT(*) >= 200
ORDER BY MIN(payer_grp),MIN(age_grp)

  -- b. PIVOT Table (highest observed readmission rates)
SELECT COALESCE(age_grp,'Invalid') AS age_group,
	 ROUND(100.0*AVG(readmit_30d) FILTER (WHERE payer_grp = 'Commercial / Private'),2) AS "Comercial Or Private",
	 ROUND(100.0*AVG(readmit_30d) FILTER (WHERE payer_grp = 'Government'),2) AS "Government",
	 ROUND(100.0*AVG(readmit_30d) FILTER (WHERE payer_grp = 'Other / Special Coverage'),2) AS "Other / Special Coverage",
	 ROUND(100.0*AVG(readmit_30d) FILTER (WHERE payer_grp = 'Self-pay'),2) AS "Self-pay",
	 ROUND(100.0*AVG(readmit_30d) FILTER (WHERE payer_grp = 'Unknown / Missing'),2) AS "Unknown / Missing"
FROM vw_features GROUP BY age_grp
ORDER BY MIN(age_grp)

/* ################################################################################################################################
================================================== C. Prior Healthcare Utilization & Readmission =====================================

Business Question : Does previous healthcare utilization identify patient groups with higher historical 30-day readmission rates?
Objective: Determine whether a patient's recorded healthcare utilization during the previous year is associated with 
           higher historical 30-day readmission rates.
################################################################################################################################### */
 
-- $$ How does the historical 30-day readmission rate change as the number of inpatient admissions recorded during the previous year increases, 
-- and which prior-inpatient utilization groups have the highest lift versus the overall baseline?
SELECT inpt_bkt AS prior_inpatient_visits,
	COUNT(*) AS n_encounter,
	SUM(readmit_30d) AS n_readmission,
	ROUND(AVG(readmit_30d)*100,2) AS readmit_rate_pct,
	ROUND(100.0*AVG(readmit_30d)/p0(),2) AS lift
FROM vw_features
GROUP BY inpt_bkt ORDER BY MIN(inpt_bkt);

-- $$ Which type of prior-year healthcare utilization—emergency visits, outpatient visits, or inpatient admissions—shows the strongest separation 
--    in historical 30-day readmission rates across utilization levels?
SELECT 'inpatient' AS measure, LEAST(number_inpatient,5) AS visits, COUNT(*) AS n_encounter,
       ROUND(100*AVG(readmit_30d),2) AS rate_pct
FROM diabetic_readmission GROUP BY 2
UNION ALL
SELECT 'emergency', LEAST(number_emergency,3), COUNT(*), ROUND(100*AVG(readmit_30d),2)
FROM diabetic_readmission GROUP BY 2
UNION ALL
SELECT 'outpatient', LEAST(number_outpatient,3), COUNT(*), ROUND(100*AVG(readmit_30d),2)
FROM diabetic_readmission GROUP BY 2
ORDER BY measure, visits;

-- $$ Does overall recorded healthcare utilization during the previous year, measured by combining outpatient, emergency, and inpatient encounters, 
--    distinguish groups with different historical 30-day readmission rates?
SELECT utilization_tier,MIN(prior_total) AS min_visit, MAX(prior_total) AS max_visit,
	COUNT(*) AS n_encounter,
	SUM(readmit_30d) AS n_readmission,
	ROUND(AVG(readmit_30d)*100,2) AS readmit_rate_pct,
	ROUND(100.0*AVG(readmit_30d)/p0(),2) AS lift
FROM vw_features
GROUP BY utilization_tier;

-- $$ Among patients with heavy prior-year healthcare utilization, does the historical 30-day readmission rate differ between patients whose 
--    utilization is primarily inpatient-driven and those whose utilization is primarily emergency-driven?
SELECT 
	CASE 
		WHEN number_inpatient >= number_emergency AND number_inpatient >= number_outpatient THEN 'Inpatient-led'
        WHEN number_emergency >= number_outpatient AND number_emergency >= number_inpatient THEN 'Emergency-led'
        ELSE 'Outpatient-led' 
	END AS heavy_user_type,
    COUNT(*) AS n_encounter, 
	ROUND(100*AVG(readmit_30d),2) AS rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS lift
FROM vw_features
WHERE utilization_tier = 'Heavy'
GROUP BY 1 ORDER BY rate_pct DESC;

/* ##############################################################################################################################
=============================================== D. Clinical Complexity & Treatment Patterns ========================================

Business Question : Are more clinically complex patient profiles associated with higher historical 30-day readmission rates?
Objective: Identify whether clinical complexity, disease characteristics, laboratory testing, procedures, 
           and diabetes treatment patterns are associated with historical 30-day readmission.
################################################################################################################################# */

-- 1. Diagnoses and Medication Burden
-- How does the historical 30-day readmission rate vary with the number of recorded diagnoses and the number of medications during the encounter, 
-- and do higher-complexity groups show higher readmission rates?
WITH qurt_cuts AS 
(SELECT 
	PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY number_diagnoses) AS dg_q1,
	PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY number_diagnoses) AS dg_q2,
	PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY number_diagnoses) AS dg_q3,
	PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY num_medications) AS med_q1,
	PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY num_medications) AS med_q2,
	PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY num_medications) AS med_q3
FROM diabetic_readmission),
quartile_bucket AS (SELECT dr.number_diagnoses, dr.num_medications, dr.readmit_30d,
	CASE 
		WHEN dr.number_diagnoses <= dg_q1 THEN 'Q1'
		WHEN dr.number_diagnoses <= dg_q2 THEN 'Q2'
		WHEN dr.number_diagnoses <= dg_q3 THEN 'Q3'
		ELSE 'Q4'
	END AS dg_quartile,
	CASE 
		WHEN dr.num_medications <= med_q1 THEN 'Q1'
		WHEN dr.num_medications <= med_q2 THEN 'Q2'
		WHEN dr.num_medications <= med_q3 THEN 'Q3'
		ELSE 'Q4'
	END AS med_quartile
FROM diabetic_readmission dr CROSS JOIN qurt_cuts qc)
SELECT 'Num-Diagnosis' AS metric, dg_quartile AS quartile, MIN(number_diagnoses) AS min_value, MAX(number_diagnoses) AS max_value,
	COUNT(*) AS n_encounter,
    SUM(readmit_30d) AS readmits_30d,
    ROUND(100*AVG(readmit_30d),2) AS rate_30d_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS lift,
    ROUND(100*wilson_low(SUM(readmit_30d), COUNT(*)),2) AS ci_low,
    ROUND(100*wilson_high(SUM(readmit_30d), COUNT(*)),2) AS ci_high
FROM quartile_bucket GROUP BY dg_quartile
UNION ALL 
SELECT 'Num-Medication', med_quartile , MIN(num_medications), MAX(num_medications),
	COUNT(*) AS n_encounter,
    SUM(readmit_30d) AS readmits_30d,
    ROUND(100*AVG(readmit_30d),2) AS rate_30d_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS lift,
    ROUND(100*wilson_low(SUM(readmit_30d), COUNT(*)),2) AS ci_low,
    ROUND(100*wilson_high(SUM(readmit_30d), COUNT(*)),2) AS ci_high
FROM quartile_bucket GROUP BY med_quartile
ORDER BY metric,quartile
-- 2. Which broad primary diagnosis groups have historical 30-day readmission rates above the overall baseline, and which of those groups have 
-- sufficient encounter volume to represent a meaningful hospital population?

SELECT dg1_group,
	COUNT(*) AS n_encounter,
    SUM(readmit_30d) AS readmits_30d,
    ROUND(100*AVG(readmit_30d),2) AS rate_30d_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS lift,
	ROUND(100.0 * SUM(readmit_30d)/(SELECT SUM(readmit_30d) FROM diabetic_readmission),2) AS pct_of_all_readmit
FROM vw_features 
GROUP BY dg1_group HAVING COUNT(*) >= 200
ORDER BY rate_30d_pct

-- 3. Does the presence of a circulatory, respiratory, or diabetes-related diagnosis anywhere among the first three recorded 
-- diagnosis fields (diag_1, diag_2, diag_3) correspond to a different historical 30-day readmission rate?
-- Create View
CREATE OR REPLACE VIEW vw_diagnosis_uses_group AS 
WITH dx AS (
  SELECT encounter_id, dg1_grp AS diagnosis_group FROM vw_features
  UNION SELECT encounter_id, dg2_grp FROM vw_features
  UNION SELECT encounter_id, dg3_grp FROM vw_features
  ),
diag_groups AS (
	SELECT DISTINCT diagnosis_group  FROM dx WHERE diagnosis_group <> 'Unknown'
	)
SELECT gr.diagnosis_group,fr.encounter_id AS og_encounter_id,d.encounter_id,fr.dg1_grp,fr.dg2_grp,fr.dg3_grp,readmit_30d
FROM diag_groups gr
CROSS JOIN vw_features fr
LEFT JOIN dx d ON d.encounter_id = fr.encounter_id 
		AND d.diagnosis_group = gr.diagnosis_group

-- Main Query
SELECT diagnosis_group, 
  COUNT(*) FILTER (WHERE encounter_id IS NOT NULL) AS n_encounter_with,
  ROUND(100*AVG(readmit_30d) FILTER (WHERE encounter_id IS NOT NULL),2) AS readmit_rate_with_diag,
  COUNT(*) FILTER(WHERE encounter_id IS NULL) AS n_encounter_without,
  ROUND(100*AVG(readmit_30d) FILTER (WHERE encounter_id IS NULL),2) AS readmit_rate_without_diag
FROM vw_diagnosis_uses_group
GROUP BY diagnosis_group 
ORDER BY readmit_rate_with_diag DESC;

--============================================ An Another Way (Try it later) ===================================================
/*
CREATE VIEW vw_comorb AS
WITH g AS (
  SELECT encounter_id, readmit_30d,
         diag_group(diag_1) AS g1,
         diag_group(diag_2) AS g2,
         diag_group(diag_3) AS g3
  FROM diabetic_readmission)
SELECT encounter_id, readmit_30d,
       ('Circulatory'     IN (g1,g2,g3))::int AS circulatory,
       ('Respiratory'     IN (g1,g2,g3))::int AS respiratory,
       ('Digestive'       IN (g1,g2,g3))::int AS digestive,
       ('Genitourinary'   IN (g1,g2,g3))::int AS genitourinary,
       ('Neoplasms'       IN (g1,g2,g3))::int AS neoplasms,
       ('Musculoskeletal' IN (g1,g2,g3))::int AS musculoskeletal,
       ('Injury'          IN (g1,g2,g3))::int AS injury,
       ('Diabetes'        IN (g1,g2,g3))::int AS diabetes_dx
FROM g;

SELECT f.condition,
       COUNT(*) FILTER (WHERE f.present = 1)                                  AS n_with,
       ROUND(100*AVG(c.readmit_30d) FILTER (WHERE f.present = 1),2)           AS rate_with_pct,
       COUNT(*) FILTER (WHERE f.present = 0)                                  AS n_without,
       ROUND(100*AVG(c.readmit_30d) FILTER (WHERE f.present = 0),2)           AS rate_without_pct,
       ROUND(100*(AVG(c.readmit_30d) FILTER (WHERE f.present = 1)
                - AVG(c.readmit_30d) FILTER (WHERE f.present = 0)),2)         AS diff_pct_points,
       ROUND(AVG(c.readmit_30d) FILTER (WHERE f.present = 1) / p0(),2)        AS lift_with
FROM vw_comorb c
CROSS JOIN LATERAL (VALUES
    ('Circulatory',     c.circulatory),
    ('Respiratory',     c.respiratory),
    ('Digestive',       c.digestive),
    ('Genitourinary',   c.genitourinary),
    ('Neoplasms',       c.neoplasms),
    ('Musculoskeletal', c.musculoskeletal),
    ('Injury',          c.injury),
    ('Diabetes dx',     c.diabetes_dx)
) AS f(condition, present)
GROUP BY f.condition
ORDER BY diff_pct_points DESC;

SELECT circulatory + respiratory + digestive + genitourinary
     + neoplasms + musculoskeletal + injury AS comorbid_condition_count,
       COUNT(*)                              AS n,
       ROUND(100*AVG(readmit_30d),2)         AS rate_pct,
       ROUND(AVG(readmit_30d)/p0(),2)        AS lift
FROM vw_comorb
GROUP BY 1 ORDER BY 1;
*/

-- 4. How does the historical 30-day readmission rate vary by HbA1c testing result and maximum glucose serum result, 
--    including encounters where testing was not performed, and is testing status associated with differences in readmission rates?
WITH test_result_cte AS 
	(SELECT 'HbA1C' AS test_type, COALESCE( "A1Cresult",'Not Performed/recoded') AS test_result,readmit_30d FROM diabetic_readmission
	UNION ALL
	SELECT 'Maximum Glucose Serum', COALESCE( max_glu_serum,'Not Performed/recoded'),readmit_30d FROM diabetic_readmission)
SELECT test_type, test_result,
	COUNT(*) AS n_encounter, 
	SUM(readmit_30d) AS n_readmissions,
	ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS readmission_lift
FROM test_result_cte
GROUP BY test_type, test_result
ORDER BY test_type, test_result

-- A1C result × whether medication was changed
SELECT COALESCE( "A1Cresult",'Not Performed/Recoded'), change, 
	COUNT(*) AS n_encounter, 
	ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct
FROM diabetic_readmission 
GROUP BY 1,2 ORDER BY 1,2;

-- Maximum Glucose Serum result × whether medication was changed
SELECT COALESCE( max_glu_serum,'Not Performed/Recoded'), change, 
	COUNT(*) AS n_encounter, 
	ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct
FROM diabetic_readmission 
GROUP BY 1,2 ORDER BY 1,2;

-- 5. How do diabetes treatment status and medication changes relate to historical 30-day readmission rates, and how does the rate 
--    differ among encounters where insulin treatment was recorded as No, Steady, Up, or Down?

-- Recorded Diabetes Treatment Status and Medication Change vs Historical 30 days Readmission rate
WITH med_diab_status AS
	(SELECT 'Medication Changes' AS feild_type, change AS feild_value, readmit_30d FROM diabetic_readmission
	UNION ALL 
	SELECT 'Diabetes Treatment Status', "diabetesMed", readmit_30d FROM diabetic_readmission)
SELECT feild_type,feild_value,
	COUNT(*) AS n_encounter, 
	SUM(readmit_30d) AS n_readmissions,
	ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS readmission_lift
FROM med_diab_status
GROUP BY feild_type,feild_value

-- Recorded Insulin Treatment vs Historical 30 days Readmission rate
SELECT insulin As insuline_use,
	COUNT(*) AS n_encounter, 
	SUM(readmit_30d) AS n_readmissions,
	ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS readmission_lift,
	ROUND(100.0*wilson_low(SUM(readmit_30d), COUNT(*)),2) AS ci_low,
	ROUND(100.0*wilson_high(SUM(readmit_30d), COUNT(*)),2) AS ci_high
FROM diabetic_readmission
GROUP BY insulin

-- 6. Does the number of diabetes medication categories with a recorded status other than No show an association with historical 
--    30-day readmission rates, and does this relationship provide additional information beyond the overall number of medications?
/*
SELECT 
	PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY active_medication_count) AS amc_q1,
	PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY active_medication_count) AS amc_q2,
	PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY active_medication_count) AS amc_q3,
	PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY num_medications) AS num_med_q1,
	PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY num_medications) AS num_med_q2,
	PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY num_medications) AS num_med_q3
FROM vw_features
*/
SELECT active_medication_count AS active_diabetes_drugs,
	CASE 
		WHEN num_medications <= 10 THEN 'meds<=10' 
		WHEN num_medications <= 15 THEN 'meds<=15'
		WHEN num_medications <= 20 THEN 'meds<=20'
		ELSE 'meds21+' 
	END AS total_medications,
	COUNT(*) AS n_encounter, 
    ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct,
	ROUND(100.0*AVG(readmit_30d)/p0(),2) AS readmission_lift
FROM vw_features
GROUP BY 1,2 ORDER BY 2,1

 			-------------------- OR -----------------------
 
SELECT  active_medication_count AS active_diabatic_drugs,
	ROUND(100.0*AVG(readmit_30d) FILTER (WHERE num_medications <= 10),2) AS "meds<=10",
	ROUND(100.0*AVG(readmit_30d) FILTER (WHERE num_medications <= 15),2) AS "meds<=15",
	ROUND(100.0*AVG(readmit_30d) FILTER (WHERE num_medications <= 20),2) AS "meds<=20",
	ROUND(100.0*AVG(readmit_30d) FILTER (WHERE num_medications > 20),2) AS "meds21+"
FROM vw_features 
GROUP BY active_medication_count
ORDER BY active_medication_count

-- 7. How does the historical 30-day readmission rate vary across levels of laboratory procedures and procedures performed during 
--    the encounter, and do higher procedure-volume groups show meaningfully different readmission rates?
/*
SELECT 
	PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY num_lab_procedures) AS lab_q1,
	PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY num_lab_procedures) AS lab_q2,
	PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY num_lab_procedures) AS lab_q3,
	PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY num_procedures) AS norm_q1,
	PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY num_procedures) AS norm_q2,
	PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY num_procedures) AS norm_q3
FROM vw_features
*/

SELECT 'Lab Procedure' AS metric,
       CASE WHEN num_lab_procedures <= 30 THEN '<=30' WHEN num_lab_procedures <= 50 THEN '31-50'
            WHEN num_lab_procedures <= 70 THEN '51-70' ELSE '71+' END AS bucket,
       COUNT(*) AS n_encounter, 
	   SUM(readmit_30d) AS n_readmit_30d,
	   ROUND(100*AVG(readmit_30d),2) AS rate_pct
FROM diabetic_readmission GROUP BY 2
UNION ALL
SELECT 'Procedures', 
	LEAST(num_procedures,3)::text, 
	COUNT(*), 
	SUM(readmit_30d),
	ROUND(100*AVG(readmit_30d),2)
FROM diabetic_readmission GROUP BY 2
ORDER BY metric, bucket;
/* ############################################################################################################################################
========================================= E. Hospitalization & Discharge Characteristics ======================================================
Business Question : Which hospitalization characteristics are associated with higher historical 30-day readmission rates?
Objective: Understand whether characteristics of the current hospitalization and the patient's transition out of hospital are associated with 
           historical 30-day readmission.
################################################################################################################################################ */
SELECT * FROM diabetic_readmission
SELECT * FROM vw_features

-- $$ How does the historical 30-day readmission rate vary with length of hospital stay, and do very short or very long stays 
-- show elevated readmission rates compared with typical-length stays?
SELECT time_in_hospital AS days, 
	COUNT(*) AS n_encounter,
	ROUND(100*AVG(readmit_30d),2) AS rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS lift
FROM diabetic_readmission GROUP BY 1 ORDER BY 1;

-- $$ How does the historical 30-day readmission rate vary by admission type and admission source, 
--    and which pathways into the hospital are associated with higher historical readmission rates?

-- Admission Type vs Historical 30 days readmission
SELECT admission_type_description AS admission_type,
	COUNT(*) AS n_encounter,
	ROUND(100*AVG(readmit_30d),2) AS rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS lift
FROM diabetic_readmission
JOIN admission_type USING(admission_type_id)
GROUP BY admission_type_description

-- Admission Sources vs Historical 30 days readmission
SELECT admission_source_description AS admission_source,
	COUNT(*) AS n_encounter,
	ROUND(100*AVG(readmit_30d),2) AS rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS lift
FROM diabetic_readmission
JOIN admission_source USING(admission_source_id)
GROUP BY admission_source_description


-- $$ How does the historical 30-day readmission rate vary by discharge disposition, and which discharge destinations show 
--   the highest rates after excluding invalid or non-comparable dispositions?
SELECT dd.discharge_disposition_description AS discharge_disposition, 
	COUNT(*) AS n_encounter,
	ROUND(100*AVG(dr.readmit_30d),2) AS readmission_rate_pct, 
	ROUND(AVG(dr.readmit_30d)/p0(),2) AS lift,
    ROUND(100*wilson_low(SUM(dr.readmit_30d), COUNT(*)),2) AS ci_low
FROM diabetic_readmission dr 
JOIN discharge_disposition dd USING (discharge_disposition_id)
GROUP BY dd.discharge_disposition_description HAVING COUNT(*) >= 200
ORDER BY readmission_rate_pct DESC;
-- $$ Among encounters with recorded medical specialty information, which specialties have higher historical 30-day readmission rates, 
--    after applying a minimum encounter-volume threshold, and how much of the dataset has missing specialty information?

SELECT medical_specialty,
	COUNT(*) AS n_encounter,
	ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct, 
	ROUND(AVG(readmit_30d)/p0(),2) AS lift
FROM diabetic_readmission 
WHERE medical_specialty IS NOT NULL
GROUP BY 1 HAVING COUNT(*) >= 300 
ORDER BY readmission_rate_pct DESC;

--  Report the missing share.
SELECT ROUND(100.0*COUNT(*) FILTER (WHERE medical_specialty IS NULL)/COUNT(*),1) AS pct_missing 
FROM diabetic_readmission;
  
-- $$ Which combinations of admission source and discharge disposition are associated with the highest historical 30-day 
-- readmission rates, and do particular routes into and out of the hospital identify higher-priority populations for follow-up?
SELECT admission_sourc_grp, discharge_disposition_grp, 
	COUNT(*) AS n_encounter,
	ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct, 
	ROUND(AVG(readmit_30d)/p0(),2) AS lift
FROM vw_features
GROUP BY 1,2 HAVING COUNT(*) >= 200 
ORDER BY readmission_rate_pct DESC;

/* #################################################################################################################################################
=========================================== F. High-Risk Profile Identification =======================================================================
Business Question : Which combinations of patient characteristics, prior healthcare utilization and hospitalization characteristics are associated 
                    with the highest historical 30-day readmission rates?
Objective: Move from individual factors to combinations of characteristics and identify sufficiently large patient profiles with consistently 
           high historical readmission rates.
################################################################################################################################################### */
SELECT * FROM diabetic_readmission
SELECT * FROM vw_features

-- 1.Multi-Factor Profiles
-- Which combinations of age group, prior inpatient utilization, discharge disposition, and primary diagnosis group have the highest 
-- historical 30-day readmission rates among profiles with at least 200 encounters?

SELECT age_grp,
	inpt_bkt AS prior_inpatient_stays,
	discharge_disposition_grp AS discharge_group,
	dg1_grp AS primary_diagnosis_group, 
	COUNT(*) AS n_encounter,
    SUM(readmit_30d) AS readmits_30d,
    ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2) AS lift
FROM vw_features
WHERE dg1_grp <> 'Unknown' AND discharge_disposition_grp <> 'Unknown'
GROUP BY age_grp, inpt_bkt, discharge_disposition_grp, dg1_grp
HAVING COUNT(*) >= 200
ORDER BY readmission_rate_pct DESC
LIMIT 15;

-- 2. Multi-Level Segmentation
-- Can a single GROUPING SETS or ROLLUP analysis efficiently measure historical 30-day readmission rates across multiple 
-- levels of age, prior utilization, and discharge disposition, and what does each aggregation level reveal about the 
-- readmission landscape?
SELECT CASE WHEN GROUPING(age_grp)  = 1 THEN 'ALL' ELSE age_grp  END AS age_grp,
       CASE WHEN GROUPING(inpt_bkt) = 1 THEN 'ALL' ELSE inpt_bkt END AS prior_inpatient,
       CASE WHEN GROUPING(discharge_disposition_grp) = 1 THEN 'ALL' ELSE discharge_disposition_grp END AS discharge_group,
       3 - (GROUPING(age_grp) + GROUPING(inpt_bkt) + GROUPING(discharge_disposition_grp)) AS dims_used,
    COUNT(*)                                   AS n_encounter,
    SUM(readmit_30d)                           AS readmits_30d,
    ROUND(100*AVG(readmit_30d),2)              AS readmission_rate_pct,
    ROUND(AVG(readmit_30d)/p0(),2)             AS lift
FROM vw_features
WHERE discharge_disposition_grp <> 'Unknown'
GROUP BY CUBE (age_grp, inpt_bkt, discharge_disposition_grp)
HAVING COUNT(*) >= 200
ORDER BY dims_used, readmission_rate_pct DESC;

-- 3. op Historical Profiles
-- Among the highest-rate historical profiles, how large is the lift versus baseline, how many additional readmissions 
-- are observed compared with the baseline expectation, and what proportion of all 30-day readmissions is represented by 
-- each profile?
WITH seg_cte AS 
	(SELECT age_grp,inpt_bkt,discharge_disposition_grp,dg1_grp, 
		COUNT(*) AS n_encounter,
	    SUM(readmit_30d) AS readmits_30d,
	    ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct,
	    ROUND(AVG(readmit_30d)/p0(),2) AS lift
	FROM vw_features WHERE discharge_disposition_grp <> 'Unknown' AND dg1_grp <> 'Unknown'
	GROUP BY age_grp,inpt_bkt,discharge_disposition_grp,dg1_grp
	HAVING COUNT(*) >= 200 ),
total_readmit_30d AS (SELECT SUM(readmit_30d) AS overall_readmit_30d FROM diabetic_readmission),
readmit_30d_stats AS (SELECT age_grp,
	inpt_bkt  AS prior_inpatient_stays,
	discharge_disposition_grp AS discharge_group,
	dg1_grp AS primary_diagnosis_group,
	n_encounter,readmits_30d,readmission_rate_pct,lift,
    --  (total observed 30d readmission per group - total observed encounter per group * all over readmission avarage(baseline))
	ROUND(readmits_30d - n_encounter * p0(),2) AS excess_readmits,
	-- (total observed 30d readmission per group / All Over 30d Readmission of this Observed Dataset)
	ROUND(100.0*readmits_30d/overall_readmit_30d,2) AS pct_of_all_30d_readmits
FROM seg_cte CROSS JOIN total_readmit_30d)
SELECT *,
	ROUND(SUM(pct_of_all_30d_readmits) OVER(ORDER BY readmission_rate_pct DESC, n_encounter DESC),2) AS cumulative_pct
FROM readmit_30d_stats
ORDER BY readmission_rate_pct DESC LIMIT 15

-- 4. Profile Stability
-- Do the highest-readmission profiles identified across all encounters remain among the highest-rate profiles when 
-- the analysis is repeated using only each patient's first recorded encounter?
WITH first_enc AS -- 
	(SELECT * FROM
		(SELECT *, ROW_NUMBER() OVER(PARTITION BY patient_nbr ORDER BY encounter_id) AS row_rank FROM vw_features)
	WHERE row_rank = 1),
all_patient_enc AS --
	(SELECT age_grp,inpt_bkt,discharge_disposition_grp,dg1_grp,
		COUNT(*) AS n_encounter,
		ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct, 
		ROUND(AVG(readmit_30d)/p0(),2) AS lift
	FROM vw_features WHERE discharge_disposition_grp <> 'Unknown' AND dg1_grp <> 'Unknown'
	GROUP BY age_grp,inpt_bkt,discharge_disposition_grp,dg1_grp HAVING COUNT(*) >= 200),
first_patient_enc AS --
	(SELECT age_grp,inpt_bkt,discharge_disposition_grp,dg1_grp,
		COUNT(*) AS n_encounter,
		ROUND(100*AVG(readmit_30d),2) AS readmission_rate_pct, 
		ROUND(AVG(readmit_30d)/p0(),2) AS lift
	FROM first_enc WHERE discharge_disposition_grp <> 'Unknown' AND dg1_grp <> 'Unknown'
	GROUP BY age_grp,inpt_bkt,discharge_disposition_grp,dg1_grp HAVING COUNT(*) >= 100),
all_patient_enc_rank AS --
	(SELECT *,RANK() OVER(ORDER BY readmission_rate_pct) AS rank_all FROM all_patient_enc),
first_patient_enc_rank AS --
	(SELECT *,RANK() OVER(ORDER BY readmission_rate_pct) rank_first FROM first_patient_enc)
SELECT a.age_grp,a.inpt_bkt,a.discharge_disposition_grp,a.dg1_grp,
	-- All encounter stats
	a.n_encounter AS all_encounters, a.readmission_rate_pct AS readmission_rate_pct_allover,
	a.lift AS lift_allover, a.rank_all AS all_enc_rank,
	-- First encounter stats
	fi.n_encounter AS first_encounters, fi.readmission_rate_pct AS readmission_rate_pct_first,
	fi.lift As lift_first, fi.rank_first AS first_enc_rank,
	 CASE WHEN fi.rank_first IS NULL THEN 'Too few first encounters'
            WHEN fi.rank_first <= 10 THEN 'Stable (still top 10)'
            WHEN fi.rank_first <= 20 THEN 'Weakened (top 20)'
            ELSE 'Not stable'
	 END  AS stability
FROM all_patient_enc_rank a LEFT JOIN first_patient_enc_rank fi 
USING(age_grp,inpt_bkt,discharge_disposition_grp,dg1_grp)
WHERE a.rank_all <= 20
ORDER BY a.rank_all
