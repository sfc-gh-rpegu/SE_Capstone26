-- ============================================================================
-- SE CAPSTONE AUDIT SETUP SCRIPT
-- Account: SFPSCOGS-RPEGU | Database: CAPSTONE26_DB
-- Creates: AUDIT schema, AUDIT_USER, warehouse, external tables, views, grants
-- ============================================================================
-- Run this script as ACCOUNTADMIN (or your CAPSTONE26_RPEGU role for most objects).
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- ============================================================================
-- SECTION 1: WAREHOUSE — CAPSTONE_AUDIT_WH (XSmall)
-- ============================================================================

CREATE WAREHOUSE IF NOT EXISTS CAPSTONE_AUDIT_WH
  WAREHOUSE_SIZE   = 'XSMALL'
  AUTO_SUSPEND     = 60
  AUTO_RESUME      = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT          = 'XSmall warehouse for capstone audit user';

-- ============================================================================
-- SECTION 2: AUDIT SCHEMA
-- ============================================================================

USE ROLE CAPSTONE26_RPEGU;

CREATE SCHEMA IF NOT EXISTS CAPSTONE26_DB.AUDIT
  COMMENT = 'Schema for capstone audit views and external tables';

-- ============================================================================
-- SECTION 3: FILE FORMATS FOR EXTERNAL TABLES
-- ============================================================================

-- kapa files are gzipped JSON, one record per line (STRIP_OUTER_ARRAY handles arrays)
CREATE FILE FORMAT IF NOT EXISTS CAPSTONE26_DB.AUDIT.FF_EXT_KAPA_JSON
  TYPE = JSON
  STRIP_OUTER_ARRAY = TRUE
  COMPRESSION       = AUTO;

-- kbfi files are uncompressed JSON, single object per file (aircraft array inside)
CREATE FILE FORMAT IF NOT EXISTS CAPSTONE26_DB.AUDIT.FF_EXT_KBFI_JSON
  TYPE = JSON
  COMPRESSION = NONE;

-- ============================================================================
-- SECTION 4: EXTERNAL TABLES
-- ============================================================================

-- 4a. KAPA external table — Hive-style partitioning: year=YYYY/month=MM/day=DD
-- NOTE: External table partition exprs don't support DATE_FROM_PARTS, LPAD, or REGEXP_SUBSTR.
--       Use CAST(SPLIT_PART(...) AS DATE) instead.
CREATE OR REPLACE EXTERNAL TABLE CAPSTONE26_DB.AUDIT.EXT_ADSB_KAPA (
  RECORD_DT DATE AS CAST(
    SPLIT_PART(SPLIT_PART(METADATA$FILENAME, '/', 2), '=', 2) || '-' ||
    SPLIT_PART(SPLIT_PART(METADATA$FILENAME, '/', 3), '=', 2) || '-' ||
    SPLIT_PART(SPLIT_PART(METADATA$FILENAME, '/', 4), '=', 2)
    AS DATE
  )
)
  PARTITION BY (RECORD_DT)
  WITH LOCATION = @CAPSTONE26_DB.PROD.CAPSTONE_S3_STAGE/kapa-0001/
  AUTO_REFRESH    = FALSE
  FILE_FORMAT     = (FORMAT_NAME = 'CAPSTONE26_DB.AUDIT.FF_EXT_KAPA_JSON')
  COMMENT         = 'External table over kapa-0001 ADS-B S3 data, partitioned by date';

-- 4b. KBFI external table — simple path partitioning: YYYY/MM/DD
CREATE OR REPLACE EXTERNAL TABLE CAPSTONE26_DB.AUDIT.EXT_ADSB_KBFI (
  RECORD_DT DATE AS CAST(
    SPLIT_PART(METADATA$FILENAME, '/', 2) || '-' ||
    SPLIT_PART(METADATA$FILENAME, '/', 3) || '-' ||
    SPLIT_PART(METADATA$FILENAME, '/', 4)
    AS DATE
  )
)
  PARTITION BY (RECORD_DT)
  WITH LOCATION = @CAPSTONE26_DB.PROD.CAPSTONE_S3_STAGE/kbfi-0001/
  AUTO_REFRESH    = FALSE
  FILE_FORMAT     = (FORMAT_NAME = 'CAPSTONE26_DB.AUDIT.FF_EXT_KBFI_JSON')
  COMMENT         = 'External table over kbfi-0001 ADS-B S3 data, partitioned by date';

-- Refresh partition metadata so Snowflake knows about the files
ALTER EXTERNAL TABLE CAPSTONE26_DB.AUDIT.EXT_ADSB_KAPA REFRESH;
ALTER EXTERNAL TABLE CAPSTONE26_DB.AUDIT.EXT_ADSB_KBFI REFRESH;

-- ============================================================================
-- SECTION 5: EXTERNAL TABLE VIEWS
-- ============================================================================

-- 5a. ADS_B_KAPA_EXT_VW — raw variant + audit columns from external table
CREATE OR REPLACE VIEW CAPSTONE26_DB.AUDIT.ADS_B_KAPA_EXT_VW AS
SELECT
  VALUE                         AS RAW_DATA,
  RECORD_DT,
  METADATA$FILENAME             AS FILE_NAME,
  METADATA$FILE_ROW_NUMBER      AS FILE_ROW_NUM
FROM CAPSTONE26_DB.AUDIT.EXT_ADSB_KAPA;

-- 5b. ADS_B_KBFI_EXT_VW — raw variant + audit columns from external table
CREATE OR REPLACE VIEW CAPSTONE26_DB.AUDIT.ADS_B_KBFI_EXT_VW AS
SELECT
  VALUE                         AS RAW_DATA,
  RECORD_DT,
  METADATA$FILENAME             AS FILE_NAME,
  METADATA$FILE_ROW_NUMBER      AS FILE_ROW_NUM
FROM CAPSTONE26_DB.AUDIT.EXT_ADSB_KBFI;

-- ============================================================================
-- SECTION 6: STAGING VIEWS (over raw tables)
-- ============================================================================

-- 6a. STAGE_ADS_B_KAPA_VW — raw kapa table with RECORD_TS from JSON clock field
CREATE OR REPLACE VIEW CAPSTONE26_DB.AUDIT.STAGE_ADS_B_KAPA_VW AS
SELECT
  TO_TIMESTAMP(RAW_DATA:clock::NUMBER)  AS RECORD_TS,
  RAW_DATA,
  SOURCE_FILENAME                       AS FILE_NAME,
  SOURCE_ROW_NUM                        AS FILE_ROW_NUM
FROM CAPSTONE26_DB.RAW.ADSB_RAW_KAPA;

-- 6b. STAGE_ADS_B_KBFI_VW — raw kbfi table with RECORD_TS from JSON now field
CREATE OR REPLACE VIEW CAPSTONE26_DB.AUDIT.STAGE_ADS_B_KBFI_VW AS
SELECT
  TO_TIMESTAMP(RAW_DATA:now::NUMBER)    AS RECORD_TS,
  RAW_DATA,
  SOURCE_FILENAME                       AS FILE_NAME,
  SOURCE_ROW_NUM                        AS FILE_ROW_NUM
FROM CAPSTONE26_DB.RAW.ADSB_RAW_KBFI;

-- ============================================================================
-- SECTION 7: CONFORMED MODEL VIEWS
-- ============================================================================

-- 7a. AIRCRAFT_FLIGHT_VW — conformed model from Stream+Task table joined with FAA
CREATE OR REPLACE VIEW CAPSTONE26_DB.AUDIT.AIRCRAFT_FLIGHT_VW AS
SELECT
  EVENT_TIME                            AS RECORD_TS,
  ICAO_HEX,
  CALLSIGN,
  LATITUDE,
  LONGITUDE,
  ALTITUDE_BARO,
  ALTITUDE_GEO,
  GROUND_SPEED,
  HEADING,
  SQUAWK,
  STATION_ID,
  FAA_N_NUMBER,
  FAA_NAME,
  FAA_MFR_MDL_CODE,
  FAA_TYPE_AIRCRAFT,
  SOURCE_FILENAME                       AS FILE_NAME,
  SOURCE_ROW_NUM                        AS FILE_ROW_NUM
FROM CAPSTONE26_DB.STAGING.ADSB_CONFORMED_VIA_STREAM;

-- 7b. AIRCRAFT_FLIGHT_DT_VW — same shape, from Dynamic Table
CREATE OR REPLACE VIEW CAPSTONE26_DB.AUDIT.AIRCRAFT_FLIGHT_DT_VW AS
SELECT
  EVENT_TIME                            AS RECORD_TS,
  ICAO_HEX,
  CALLSIGN,
  LATITUDE,
  LONGITUDE,
  ALTITUDE_BARO,
  ALTITUDE_GEO,
  GROUND_SPEED,
  HEADING,
  SQUAWK,
  STATION_ID,
  FAA_N_NUMBER,
  FAA_NAME,
  FAA_MFR_MDL_CODE,
  FAA_TYPE_AIRCRAFT,
  SOURCE_FILENAME                       AS FILE_NAME,
  SOURCE_ROW_NUM                        AS FILE_ROW_NUM
FROM CAPSTONE26_DB.STAGING.ADSB_CONFORMED_VIA_DT;

-- ============================================================================
-- SECTION 8: AUDIT ROLE & USER
-- ============================================================================

USE ROLE ACCOUNTADMIN;

-- Create the audit role
CREATE ROLE IF NOT EXISTS CAPSTONE_AUDIT_ROLE
  COMMENT = 'Role for capstone audit user with read-only access to audit views';

-- Grant warehouse usage
GRANT USAGE ON WAREHOUSE CAPSTONE_AUDIT_WH TO ROLE CAPSTONE_AUDIT_ROLE;

-- Grant database and schema usage
GRANT USAGE ON DATABASE CAPSTONE26_DB TO ROLE CAPSTONE_AUDIT_ROLE;
GRANT USAGE ON SCHEMA CAPSTONE26_DB.AUDIT TO ROLE CAPSTONE_AUDIT_ROLE;
GRANT USAGE ON SCHEMA CAPSTONE26_DB.RAW TO ROLE CAPSTONE_AUDIT_ROLE;
GRANT USAGE ON SCHEMA CAPSTONE26_DB.STAGING TO ROLE CAPSTONE_AUDIT_ROLE;
GRANT USAGE ON SCHEMA CAPSTONE26_DB.PROD TO ROLE CAPSTONE_AUDIT_ROLE;

-- Grant SELECT on all audit views
GRANT SELECT ON ALL VIEWS IN SCHEMA CAPSTONE26_DB.AUDIT TO ROLE CAPSTONE_AUDIT_ROLE;

-- Grant SELECT on external tables (needed for views to work)
GRANT SELECT ON ALL EXTERNAL TABLES IN SCHEMA CAPSTONE26_DB.AUDIT TO ROLE CAPSTONE_AUDIT_ROLE;

-- Grant SELECT on underlying tables (needed for staging/conformed views)
GRANT SELECT ON TABLE CAPSTONE26_DB.RAW.ADSB_RAW_KAPA TO ROLE CAPSTONE_AUDIT_ROLE;
GRANT SELECT ON TABLE CAPSTONE26_DB.RAW.ADSB_RAW_KBFI TO ROLE CAPSTONE_AUDIT_ROLE;
GRANT SELECT ON TABLE CAPSTONE26_DB.STAGING.ADSB_CONFORMED_VIA_STREAM TO ROLE CAPSTONE_AUDIT_ROLE;
GRANT SELECT ON TABLE CAPSTONE26_DB.STAGING.ADSB_CONFORMED_VIA_DT TO ROLE CAPSTONE_AUDIT_ROLE;

-- Grant USAGE on the stage (needed for external tables)
GRANT USAGE ON STAGE CAPSTONE26_DB.PROD.CAPSTONE_S3_STAGE TO ROLE CAPSTONE_AUDIT_ROLE;

-- Grant future views (in case you add more later)
GRANT SELECT ON FUTURE VIEWS IN SCHEMA CAPSTONE26_DB.AUDIT TO ROLE CAPSTONE_AUDIT_ROLE;

-- Allow audit role to monitor queries
GRANT MONITOR ON WAREHOUSE CAPSTONE_AUDIT_WH TO ROLE CAPSTONE_AUDIT_ROLE;

-- Create the AUDIT_USER
CREATE USER IF NOT EXISTS AUDIT_USER
  PASSWORD           = 'Capstone_Audit_2026!'
  DEFAULT_ROLE       = CAPSTONE_AUDIT_ROLE
  DEFAULT_WAREHOUSE  = CAPSTONE_AUDIT_WH
  DEFAULT_NAMESPACE  = CAPSTONE26_DB.AUDIT
  MUST_CHANGE_PASSWORD = FALSE
  COMMENT            = 'Audit user for SE Capstone evaluation';

-- Assign role to user
GRANT ROLE CAPSTONE_AUDIT_ROLE TO USER AUDIT_USER;

-- ============================================================================
-- SECTION 9: VERIFICATION QUERIES (run as AUDIT_USER to validate)
-- ============================================================================

-- Switch context to verify
-- USE ROLE CAPSTONE_AUDIT_ROLE;
-- USE WAREHOUSE CAPSTONE_AUDIT_WH;
-- USE SCHEMA CAPSTONE26_DB.AUDIT;

-- Test 1: External table view — should return in seconds with partition pruning
-- SELECT * FROM ADS_B_KAPA_EXT_VW WHERE RECORD_DT = '2021-12-25';
-- SELECT * FROM ADS_B_KBFI_EXT_VW WHERE RECORD_DT = '2021-10-14';

-- Test 2: Staging views
-- SELECT COUNT(*) FROM STAGE_ADS_B_KAPA_VW;
-- SELECT COUNT(*) FROM STAGE_ADS_B_KBFI_VW;

-- Test 3: Conformed views
-- SELECT * FROM AIRCRAFT_FLIGHT_VW LIMIT 10;
-- SELECT * FROM AIRCRAFT_FLIGHT_DT_VW LIMIT 10;

-- Test 4: Query history visibility
-- SELECT * FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY
-- WHERE USER_NAME = 'AUDIT_USER'
-- ORDER BY START_TIME DESC LIMIT 10;
