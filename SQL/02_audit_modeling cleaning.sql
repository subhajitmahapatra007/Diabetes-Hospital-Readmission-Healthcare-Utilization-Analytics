SET search_path TO hospital_readmission;

SELECT * FROM diabetic_data;
SELECT * FROM admission_type;
SELECT * FROM discharge_disposition;
SELECT * FROM admission_source;

-- 1. Audit
SELECT COUNT(*) AS total_rows,
  COUNT(*) - COUNT(DISTINCT encounter_id) AS duplicate_encounters,
  COUNT(DISTINCT patient_nbr) AS distinct_patients,
  ROUND(100.0*COUNT(*) FILTER (WHERE race = '?')/COUNT(*),2) AS race_missing_pct,
  ROUND(100.0*COUNT(*) FILTER (WHERE weight = '?')/COUNT(*),2) AS weight_missing_pct,
  ROUND(100.0*COUNT(*) FILTER (WHERE payer_code = '?')/COUNT(*),2) AS payer_missing_pct,
  ROUND(100.0*COUNT(*) FILTER (WHERE medical_specialty = '?')/COUNT(*),2) AS specialty_missing_pct,
  ROUND(100.0*COUNT(*) FILTER (WHERE diag_1 = '?')/COUNT(*),4) AS diag1_missing_pct,
  ROUND(100.0*COUNT(*) FILTER (WHERE diag_2 = '?')/COUNT(*),4) AS diag2_missing_pct,
  ROUND(100.0*COUNT(*) FILTER (WHERE diag_3 = '?')/COUNT(*),4) AS diag3_missing_pct,
  ROUND(100.0*COUNT(*) FILTER (WHERE "A1Cresult" IS NULL)/COUNT(*),1) AS a1c_not_tested_pct,
  ROUND(100.0*COUNT(*) FILTER (WHERE max_glu_serum IS NULL)/COUNT(*),1) AS glu_not_tested_pct,
  COUNT(*) FILTER (WHERE gender NOT IN ('Male','Female')) AS invalid_gender,
  COUNT(*) FILTER (WHERE time_in_hospital NOT BETWEEN 1 AND 14) AS bad_length_of_stay
SELECT DISTINCT gender FROM diabetic_data;
/* ===============================================================================================
Decisions to document in the README:

 * gender has 3 'Unknown/Invalid' value
 * weight: drop it (about 97% missing).
 * payer_code and medical_specialty: keep them but report "Missing" as its own category.
 * A1C and glucose IS NULL: this means not tested, a real category and not missing data.
 * examide and citoglipton: they are constant No in this dataset, so ignore them.
-- =============================================================================================== */ 

-- 2. Exclude expired/hospice discharges (they cannot be readmitted)
CREATE TABLE diabetic_readmission AS -- create a new table for further analysis
SELECT * FROM diabetic_data
WHERE discharge_disposition_id NOT IN (11,13,14,19,20,21);

-- What was removed, by rule
SELECT l.discharge_disposition_id,
	m.discharge_disposition_description,
	COUNT(encounter_id) AS encounters,
	COUNT(DISTINCT l.patient_nbr) AS patients
FROM diabetic_data l
INNER JOIN discharge_disposition m
ON l.discharge_disposition_id = m.discharge_disposition_id
WHERE l.discharge_disposition_id IN (11,13,14,19,20,21)
GROUP BY 1,2 ORDER BY encounters DESC

-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
-- It's delete from main table diabetic_data but I remain it as it is 
-- DELETE FROM diabetic_data WHERE discharge_disposition_id IN (11, 13, 14, 19, 20, 21, 26);
-- ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

-- 3.  '?' is a placeholder, not 'NULL'. So replace '?' to actual null
UPDATE diabetic_readmission
SET race = NULLIF(race,'?'),
	weight = NULLIF(weight, '?'),
    payer_code = NULLIF(payer_code, '?'),
    medical_specialty = NULLIF(medical_specialty, '?'),
    diag_1 = NULLIF(diag_1, '?'),
    diag_2 = NULLIF(diag_2, '?'),
    diag_3 = NULLIF(diag_3, '?');

-- 4.  Convert 'Unknown/Invalid' values into 'NULL' for gender column
UPDATE diabetic_readmission
SET gender = NULL 
	WHERE gender NOT IN ('Female','Male');

-- 5.  Create a 30-day readmission flag column
ALTER TABLE diabetic_readmission
ADD COLUMN readmit_30d INT
GENERATED ALWAYS AS ((readmitted  = '<30')::INT)
STORED;


-- 6. Cohot Watefall 
SELECT 'in_raw_data' as step, COUNT(*) AS encounters, COUNT(DISTINCT patient_nbr) AS patients FROM diabetic_data
UNION ALL
SELECT 'after_exclusion_data' as step, COUNT(*), COUNT(DISTINCT patient_nbr) FROM diabetic_readmission


-- ==================================== CREATE SOME USEFUL FUNCTIONS ===============================================
-- . Helpers(function) used in every later section
-- =================================================================================================================
-- overall 30-day readmission rate
CREATE FUNCTION p0() 
RETURNS numeric AS
$$ 
	SELECT AVG(readmit_30d) FROM diabetic_readmission 
$$ 
LANGUAGE sql STABLE;

-- Lower bound of a Wilson confidence interval for a proportion
CREATE FUNCTION wilson_low(x numeric, n numeric) 
RETURNS numeric AS
$$ 
	SELECT ((x/n) + 3.8416/(2*n) - 1.96*sqrt(((x/n)*(1-x/n))/n + 3.8416/(4*n*n))) / (1 + 3.8416/n) 
$$ 
LANGUAGE sql IMMUTABLE;

-- Upper bound of a Wilson confidence interval for a proportion
CREATE FUNCTION wilson_high(x numeric, n numeric) 
RETURNS numeric AS
$$ 
	SELECT ((x/n) + 3.8416/(2*n) + 1.96*sqrt(((x/n)*(1-x/n))/n + 3.8416/(4*n*n))) / (1 + 3.8416/n)
$$ 
LANGUAGE sql IMMUTABLE;

-- Diagnosis Grouping (ICD - 9)
SELECT * FROM diabetic_data

CREATE OR REPLACE FUNCTION diag_group(code text) 
RETURNS text AS 
$$
  SELECT 
   CASE
    WHEN code IS NULL OR TRIM(code) = '' OR TRIM(code) = '?' THEN 'Unknown'
     -- ICD-9 E codes: external causes of injury
    WHEN trim(code) ~ '^E' THEN 'External Cause'
    -- ICD-9 V codes: factors influencing health status / encounters
    WHEN trim(code) ~ '^V'THEN 'Health Status / Encounter'
	-- The diabetes check comes before the circulatory range on purpose, so 250.xx never falls into another group.
    WHEN TRIM(code) LIKE '250%' THEN 'Diabetes' 
	-- Circulatory
    WHEN trim(code) ~ '^[0-9]+(\.[0-9]+)?$' AND (TRIM(code)::numeric BETWEEN 390 AND 459 OR TRIM(code)::numeric = 785) THEN 'Circulatory'
	-- Respiratory
    WHEN trim(code) ~ '^[0-9]+(\.[0-9]+)?$' AND (TRIM(code)::numeric BETWEEN 460 AND 519 OR TRIM(code)::numeric = 786) THEN 'Respiratory'
	-- Digestive
    WHEN trim(code) ~ '^[0-9]+(\.[0-9]+)?$' AND (TRIM(code)::numeric BETWEEN 520 AND 579 OR TRIM(code)::numeric = 787) THEN 'Digestive'
	-- Genitourinary
    WHEN trim(code) ~ '^[0-9]+(\.[0-9]+)?$' AND (TRIM(code)::numeric BETWEEN 580 AND 629 OR TRIM(code)::numeric = 788) THEN 'Genitourinary'
	-- Injury
    WHEN trim(code) ~ '^[0-9]+(\.[0-9]+)?$' AND (TRIM(code)::numeric BETWEEN 800 AND 999) THEN 'Injury'
	-- Musculoskeletal
    WHEN trim(code) ~ '^[0-9]+(\.[0-9]+)?$' AND (TRIM(code)::numeric BETWEEN 710 AND 739) THEN 'Musculoskeletal'
	-- Neoplasms
    WHEN trim(code) ~ '^[0-9]+(\.[0-9]+)?$' AND (TRIM(code)::numeric BETWEEN 140 AND 239) THEN 'Neoplasms'
	-- Unexpected non-numeric/non-E/V values
    ELSE 'Other' 
   END
$$ 
LANGUAGE SQL IMMUTABLE;


-- ======================================= Feature Engineering ==================================================
-- DROP VIEW vw_features
CREATE OR REPLACE VIEW vw_features AS
SELECT *,
  CASE WHEN age = '[0-10)' THEN '0-9'
  	   WHEN age IN ('[10-20)','[20-30)') THEN '10-29'
  	   WHEN age IN ('[30-40)','[40-50)') THEN '30-49'
       WHEN age IN ('[50-60)','[60-70)') THEN '50-69' 
	   WHEN age IN ('[70-80)','[80-90)','[90-100)') THEN '70+'
	   ELSE 'Unknown'
  END AS age_grp, -- Create Age Group
  CASE WHEN age = '[0-10)'   THEN 5
       WHEN age = '[10-20)'  THEN 15
       WHEN age = '[20-30)'  THEN 25
       WHEN age = '[30-40)'  THEN 35
       WHEN age = '[40-50)'  THEN 45
       WHEN age = '[50-60)'  THEN 55
       WHEN age = '[60-70)'  THEN 65
       WHEN age = '[70-80)'  THEN 75
       WHEN age = '[80-90)'  THEN 85
       WHEN age = '[90-100)' THEN 95
  END age_midpoint,
  
  -- Create Payer Options Group
  CASE
    WHEN payer_code IS NULL THEN 'Unknown / Missing'
    WHEN payer_code IN ('MC', 'MD', 'MP', 'OG', 'DM', 'FR', 'CH') THEN 'Government'
    WHEN payer_code IN ('CM', 'BC', 'CP', 'HM', 'PO', 'SI') THEN 'Commercial / Private'
    WHEN payer_code = 'SP'THEN 'Self-pay'
    WHEN payer_code IN ('WC', 'OT') THEN 'Other / Special Coverage'
    WHEN payer_code = 'UN' THEN 'Unknown / Missing'
    ELSE 'Other'
  END AS payer_grp, 

  -- Create Admission Source Group
  CASE WHEN admission_source_id = 7 THEN 'Emergency room'
  	   WHEN admission_source_id = 8 THEN 'Court/Law Enforcement'
       WHEN admission_source_id IN (1,2,3) THEN 'Referral'
       WHEN admission_source_id IN (4,5,6,10,18,19,22,25,26) THEN 'Transfer'
       ELSE 'Unknown/Other' 
  END AS admission_sourc_grp, 

  -- Create Discharge Disposition Group
  CASE WHEN discharge_disposition_id = 1 THEN 'Home'
       WHEN discharge_disposition_id IN (6,8) THEN 'Home health'
       WHEN discharge_disposition_id IN (3,4,24) THEN 'SNF / nursing facility'
       WHEN discharge_disposition_id IN (22,23) THEN 'Rehab / long-term care'
       WHEN discharge_disposition_id IN (2,5,9,15,28,29,30) THEN 'Other inpatient / transfer'
       WHEN discharge_disposition_id = 7 THEN 'Left AMA'
       WHEN discharge_disposition_id IN (18,25,26) THEN 'Unknown'
       ELSE 'Other' 
  END AS discharge_disposition_grp, 
  
  diag_group(diag_1) AS dg1_grp, -- Create Drag Group
  diag_group(diag_2) AS dg2_grp, -- Create Drag Group
  diag_group(diag_3) AS dg3_grp, -- Create Drag Group
  
  -- Create Number of Inpaatient Bucket 
  CASE WHEN number_inpatient = 0 THEN '0'
  	   WHEN number_inpatient = 1 THEN '1'
  	   WHEN number_inpatient = 2 THEN '2'
 	   WHEN number_inpatient BETWEEN 3 and 4 THEN '3-4'
 	   WHEN number_inpatient BETWEEN 5 and 7 THEN '5-7'
	   ELSE '8+'
  END AS inpt_bkt,
 
  -- Total Prior utilization
  number_outpatient + number_emergency + number_inpatient AS prior_total,

  -- Create Utilization Tier
  CASE WHEN number_outpatient + number_emergency + number_inpatient = 0 THEN 'None'
       WHEN number_outpatient + number_emergency + number_inpatient <= 2 THEN 'Low'
       WHEN number_outpatient + number_emergency + number_inpatient <= 5 THEN 'Moderate'
  ELSE 'Heavy' END AS utilization_tier,
  
  -- Medication category count
  	COALESCE((metformin<>'No')::int,0) + COALESCE((repaglinide<>'No')::int,0) + COALESCE((nateglinide<>'No')::int,0) 
  + COALESCE((chlorpropamide<>'No')::int,0) + COALESCE((glimepiride<>'No')::int,0) + COALESCE((acetohexamide<>'No')::int,0)
  + COALESCE((glipizide<>'No')::int,0) + COALESCE((glyburide<>'No')::int,0) + COALESCE((tolbutamide<>'No')::int,0)
  + COALESCE((pioglitazone<>'No')::int,0) + COALESCE((rosiglitazone<>'No')::int,0) + COALESCE((acarbose<>'No')::int,0)
  + COALESCE((miglitol<>'No')::int,0) + COALESCE((troglitazone<>'No')::int,0) + COALESCE((tolazamide<>'No')::int,0)
  + COALESCE((insulin<>'No')::int,0) + COALESCE(("glyburide-metformin"<>'No')::int,0) + COALESCE(("glipizide-metformin"<>'No')::int,0)
  + COALESCE(("glimepiride-pioglitazone"<>'No')::int,0) + COALESCE(("metformin-rosiglitazone"<>'No')::int,0)
  + COALESCE(("metformin-pioglitazone"<>'No')::int,0) 
  		AS active_medication_count
FROM diabetic_readmission;

SELECT DISTINCT number_emergency FROM vw_features

SELECT * FROM vw_features
-- Government
-- ├── MC  Medicare
-- ├── MD  Medicaid
-- ├── MP  Medicare Part B
-- ├── OG  Other Government
-- ├── DM  Department of Defense / Military
-- ├── FR  Federal
-- └── CH  CHIP

-- Commercial / Private
-- ├── CM  Commercial
-- ├── BC  Blue Cross / Blue Shield
-- ├── CP  Commercial Payer
-- ├── HM  HMO
-- ├── PO  PPO
-- └── SI  Self-insured

-- Self-pay
-- └── SP

-- Other / Special Coverage
-- ├── WC  Workers' Compensation
-- └── OT  Other

-- Unknown / Missing
-- └── UN