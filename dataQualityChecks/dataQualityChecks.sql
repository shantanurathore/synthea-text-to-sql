 SELECT current_database();
 
 select  * from synthea_raw.allergies where stop is not null;
 
 select * from  synthea_raw.patients p limit 1000;
 
 -- Patient Data check
 
 SELECT 
  COUNT(*) FILTER (WHERE deathdate IS NOT NULL) AS deceased,
  COUNT(*) FILTER (WHERE deathdate IS NULL) AS living,
  MIN(birthdate) AS earliest_birth,
  MAX(birthdate) AS latest_birth
FROM synthea_raw.patients;

/*
Observations:
- Latest birth seems very recent however, I believe this is not ENT specific data but rather general data
- 1077 Dead , 10000 Living

*/

-- Encounter data

SELECT * FROM synthea_raw.encounters LIMIT 1;
-- Then for that encounter ID, count what hangs off it

--Patient
select * from synthea_raw.patients p  where p.id = '288427c5-ee03-f47e-6872-def5772f427c';

--Organization
select * from synthea_raw.organizations o where o.id = 'f8375abc-5f39-3993-a1aa-86497534b527';

--Provider
select * from synthea_raw.providers p where p.id = '70b074ab-2af6-3ce2-b4dc-4046d86241f8';

--Payer
select * from synthea_raw.payers p where p.id ='734afbd6-4794-363b-9bc0-6a3981533ed5';


--Provider columns
-- What provider columns exist on encounters?
SELECT column_name 
FROM information_schema.columns 
WHERE table_schema = 'synthea_raw' AND table_name = 'encounters';


--CPT codes and descriptions
SELECT 'conditions' AS tbl, COUNT(DISTINCT code) AS distinct_codes, COUNT(DISTINCT description) AS distinct_descriptions FROM synthea_raw.conditions
UNION ALL SELECT 'procedures', COUNT(DISTINCT code), COUNT(DISTINCT description) FROM synthea_raw.procedures
UNION ALL SELECT 'medications', COUNT(DISTINCT code), COUNT(DISTINCT description) FROM synthea_raw.medications
UNION ALL SELECT 'observations', COUNT(DISTINCT code), COUNT(DISTINCT description) FROM synthea_raw.observations;

-- transactions sanity
SELECT 
 AVG(outstanding1) AS avg_claim,
  MIN(outstanding1) AS min_claim,
  MAX(outstanding1) AS max_claim,
  PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY outstanding1) AS median_claim
FROM synthea_raw.claims;




SELECT column_name 
FROM information_schema.columns 
WHERE table_schema = 'synthea_raw' AND table_name = 'patients'
ORDER BY ordinal_position;

-- All columns in all tables

SELECT column_name, table_name  
FROM information_schema.columns 
WHERE table_schema = 'synthea_raw' --AND table_name = 'patients'
ORDER BY table_name, ordinal_position;

-- How many patients are dead or alive in the whole data set
SELECT 
  COUNT(*) FILTER (WHERE deathdate IS NULL OR deathdate = '') AS alive,
  COUNT(*) FILTER (WHERE deathdate IS NOT NULL AND deathdate <> '') AS deceased,
  COUNT(*) AS total
FROM synthea_raw.patients;


select * 
from synthea_raw.patients p  where deathdate is not null
order by deathdate;

-- Procedures happening after death date.
-- Data Quality Issue
-- 33 rows

with deadpatients as(
select * 
from synthea_raw.patients p  where deathdate is not null
)
select 
p2.id,
p2.deathdate ,
p.*
from synthea_raw."procedures" p 
join deadpatients p2 on p.patient = p2.id and DATE(p."start") >DATE(p2.deathdate)


-- Sample post death encounters
SELECT 
  p.id AS patient_id,
  p.deathdate,
  e.id AS encounter_id,
  e.start::date AS encounter_start,
  (e.start::date - p.deathdate::date) AS days_after_death,
  e.encounterclass,
  e.description
FROM synthea_raw.patients p
JOIN synthea_raw.encounters e ON e.patient = p.id
WHERE p.deathdate IS NOT NULL 
  AND p.deathdate <> ''
  AND e.start::date > p.deathdate::date
  and e.description <> 'Death Certification'
ORDER BY (e.start::date - p.deathdate::date) desc

LIMIT 20;

-- Death age distribution

SELECT 
  EXTRACT(YEAR FROM AGE(deathdate::date, birthdate::date))::int AS age_at_death,
  COUNT(*) AS patients
FROM synthea_raw.patients
WHERE deathdate IS NOT NULL AND deathdate <> ''
GROUP BY 1
ORDER BY 1;