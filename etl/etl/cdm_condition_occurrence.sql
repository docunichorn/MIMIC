-- -------------------------------------------------------------------
-- @2020, Odysseus Data Services, Inc. All rights reserved
-- MIMIC IV CDM Conversion
-- -------------------------------------------------------------------
-- -------------------------------------------------------------------
-- Populate cdm_condition_occurrence table
-- 
-- Dependencies: run after 
--      st_core.sql,
--      st_hosp.sql,
--      cdm_person.sql,
--      cdm_visit_occurrence,
--      cdm_visit_detail(?)
--
-- Remove dots from icd_code
-- -------------------------------------------------------------------

-- -------------------------------------------------------------------
-- Known issues / Open points:
--
-- TRUNCATE TABLE is not supported, organize create or replace
--
-- Why not mimic_id as in III? 
--      Because source rows can be multiplied during the ETL.
-- seq_num in custom mapping (seq_num_to_concept): 
--      There is no need of custom mapping because we can just parse target concept name
-- condition_status_source_value / concept_id
--      investigate if there is data for conditons status
-- -------------------------------------------------------------------

-- 4,520 rows on demo

-- -------------------------------------------------------------------
-- tmp_gcpt_seq_num_to_concept
-- seq_num -> condition_type_concept_id
-- -------------------------------------------------------------------

CREATE OR REPLACE TABLE `@etl_project`.@etl_dataset.tmp_seq_num_to_concept AS
SELECT
    CAST(REGEXP_EXTRACT(c1.concept_name, r"[\d]+") AS INT64) AS seq_num,
    c1.concept_id       AS target_concept_id,
    c1.concept_name     AS target_concept_name
FROM
    `@etl_project`.@etl_dataset.voc_concept AS c1
WHERE
    c1.concept_name LIKE 'Inpatient detail %'
    AND c1.vocabulary_id = 'Condition Type'
    AND REGEXP_CONTAINS(c1.concept_name, r"[\d]+")
;

-- -------------------------------------------------------------------
-- lk_diagnoses_icd_clean
-- -------------------------------------------------------------------

CREATE OR REPLACE TABLE `@etl_project`.@etl_dataset.lk_diagnoses_icd_clean AS
SELECT
    src.subject_id                              AS subject_id,
    src.hadm_id                                 AS hadm_id,
    CASE 
        WHEN src.seq_num > 20 THEN 20
        ELSE src.seq_num
    END                                         AS seq_num, -- to fit "Inpatient detail %" concepts provided by OMOP
    COALESCE(adm.edregtime, adm.admittime)      AS start_datetime, -- always exists
    dischtime                                   AS end_datetime,
    src.icd_code                                AS source_code,
    CASE 
        WHEN src.icd_version = 9 THEN 'ICD9CM'
        WHEN src.icd_version = 10 THEN 'ICD10CM'
        ELSE NULL
    END                                         AS source_vocabulary_id,
    --
    'diagnoses_icd'         AS unit_id,
    src.load_table_id       AS load_table_id,
    src.load_row_id         AS load_row_id,
    src.trace_id            AS trace_id
FROM
    `@etl_project`.@etl_dataset.src_diagnoses_icd src
INNER JOIN
    `@etl_project`.@etl_dataset.src_admissions adm
        ON  src.hadm_id = adm.hadm_id
;

-- -------------------------------------------------------------------
-- lk_djagnoses_icd_mapped
-- Since Condition_occurrence is quite simple, skip creating a separate codes table,
-- but create mapped table, which goes to Condition and Drug as well
-- -------------------------------------------------------------------

CREATE OR REPLACE TABLE `@etl_project`.@etl_dataset.lk_diagnoses_icd_mapped AS
SELECT
    src.subject_id                  AS subject_id,
    src.hadm_id                     AS hadm_id,
    src.seq_num                     AS seq_num,
    src.start_datetime              AS start_datetime,
    src.end_datetime                AS end_datetime,
    --
    src.source_code             AS source_code,
    src.source_vocabulary_id    AS source_vocabulary_id,
    vc.concept_id               AS source_concept_id,
    vc.domain_id                AS source_domain_id,
    vc2.concept_id              AS target_concept_id,
    vc2.domain_id               AS target_domain_id,
    --
    CONCAT('cond.', src.unit_id) AS unit_id,
    src.load_table_id       AS load_table_id,
    src.load_row_id         AS load_row_id,
    src.trace_id            AS trace_id  
FROM
    `@etl_project`.@etl_dataset.lk_diagnoses_icd_clean src
LEFT JOIN
    `@etl_project`.@etl_dataset.voc_concept vc
        ON REPLACE(vc.concept_code, '.', '') = REPLACE(TRIM(src.source_code), '.', '')
        AND vc.vocabulary_id = src.source_vocabulary_id
LEFT JOIN
    `@etl_project`.@etl_dataset.voc_concept_relationship vcr
        ON  vc.concept_id = vcr.concept_id_1
        AND vcr.relationship_id = 'Maps to'
LEFT JOIN
    `@etl_project`.@etl_dataset.voc_concept vc2
        ON vc2.concept_id = vcr.concept_id_2
        AND vc2.standard_concept = 'S'
        AND vc2.invalid_reason IS NULL
;

-- -------------------------------------------------------------------
-- gcpt_admissions_diagnosis_to_concept 
--      do not use since there is no diagnosis in core.admissions
-- -------------------------------------------------------------------

-- -------------------------------------------------------------------
-- cdm_condition_occurrence
-- -------------------------------------------------------------------

--HINT DISTRIBUTE_ON_KEY(person_id)
CREATE OR REPLACE TABLE `@etl_project`.@etl_dataset.cdm_condition_occurrence
(
    condition_occurrence_id       INT64     not null ,
    person_id                     INT64     not null ,
    condition_concept_id          INT64     not null ,
    condition_start_date          DATE      not null ,
    condition_start_datetime      DATETIME           ,
    condition_end_date            DATE               ,
    condition_end_datetime        DATETIME           ,
    condition_type_concept_id     INT64     not null ,
    stop_reason                   STRING             ,
    provider_id                   INT64              ,
    visit_occurrence_id           INT64              ,
    visit_detail_id               INT64              ,
    condition_source_value        STRING             ,
    condition_source_concept_id   INT64              ,
    condition_status_source_value STRING             ,
    condition_status_concept_id   INT64              ,
    -- 
    unit_id                       STRING,
    load_table_id                 STRING,
    load_row_id                   INT64,
    trace_id                      STRING
)
;

INSERT INTO `@etl_project`.@etl_dataset.cdm_condition_occurrence
SELECT
    FARM_FINGERPRINT(GENERATE_UUID())       AS condition_occurrence_id,
    per.person_id                           AS person_id,
    COALESCE(src.target_concept_id, 0)      AS condition_concept_id,
    CAST(src.start_datetime AS DATE)        AS condition_start_date,
    src.start_datetime                      AS condition_start_datetime,
    CAST(src.end_datetime AS DATE)          AS condition_end_date,
    src.end_datetime                        AS condition_end_datetime,
    COALESCE(ct.target_concept_id, 0)       AS condition_type_concept_id,
    CAST(NULL AS STRING)                    AS stop_reason,
    CAST(NULL AS INT64)                     AS provider_id,
    vis.visit_occurrence_id                 AS visit_occurrence_id,
    CAST(NULL AS INT64)                     AS visit_detail_id,
    src.source_code                         AS condition_source_value,
    COALESCE(src.source_concept_id, 0)      AS condition_source_concept_id,
    CAST(NULL AS STRING)                    AS condition_status_source_value,
    CAST(NULL AS INT64)                     AS condition_status_concept_id,
    --
    CONCAT('condition.', src.unit_id) AS unit_id,
    src.load_table_id               AS load_table_id,
    src.load_row_id                 AS load_row_id,
    src.trace_id                    AS trace_id
FROM
    `@etl_project`.@etl_dataset.lk_diagnoses_icd_mapped src
LEFT JOIN   
    `@etl_project`.@etl_dataset.tmp_seq_num_to_concept ct
        ON  src.seq_num = ct.seq_num
INNER JOIN
    `@etl_project`.@etl_dataset.cdm_person per
        ON CAST(src.subject_id AS STRING) = per.person_source_value
INNER JOIN
    `@etl_project`.@etl_dataset.cdm_visit_occurrence vis
        ON  vis.visit_source_value = 
            CONCAT(CAST(src.subject_id AS STRING), '|', COALESCE(CAST(src.hadm_id AS STRING), 'None'))
;

-- -------------------------------------------------------------------
-- cleanup
-- -------------------------------------------------------------------

DROP TABLE IF EXISTS `@etl_project`.@etl_dataset.tmp_seq_num_to_concept;
