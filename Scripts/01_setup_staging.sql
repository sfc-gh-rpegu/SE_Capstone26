-- =============================================================
-- SE Capstone: Database, Schema, Stage, and Staging Table Setup
-- =============================================================

-- 1. Create Database
CREATE DATABASE IF NOT EXISTS CAPSTONE_db;

-- 2. Create Schemas (medallion architecture)
CREATE SCHEMA IF NOT EXISTS CAPSTONE_db.RAW;       -- landing zone for raw JSON
CREATE SCHEMA IF NOT EXISTS CAPSTONE_db.STAGING;    -- staged/cleansed data
CREATE SCHEMA IF NOT EXISTS CAPSTONE_db.CURATED;    -- final target tables

-- 3. Create a dedicated load warehouse
CREATE WAREHOUSE IF NOT EXISTS CAPSTONE_LOAD_WH
    WAREHOUSE_SIZE = 'MEDIUM'
    AUTO_SUSPEND   = 60
    AUTO_RESUME    = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'Warehouse for capstone data loading - resize to XSMALL after bulk load';

-- 4. Use context
USE DATABASE CAPSTONE_db;
USE SCHEMA RAW;
USE WAREHOUSE CAPSTONE_LOAD_WH;

-- 5. Create JSON file format
CREATE OR REPLACE FILE FORMAT FF_ADSB_JSON
    TYPE = 'JSON'
    STRIP_OUTER_ARRAY = TRUE
    COMPRESSION = 'AUTO';

-- 6. Create External Stage pointing to your S3 bucket
--    Uses your existing storage integration INTG_S3_CAPSTONE
CREATE OR REPLACE STAGE STG_S3_ADSB
    STORAGE_INTEGRATION = INTG_S3_CAPSTONE
    URL = 's3://capstone-rpegu/'
    FILE_FORMAT = FF_ADSB_JSON
    COMMENT = 'External stage for ADS-B aviation data from S3';

-- 7. Verify stage - list a few files to confirm connectivity
LIST @STG_S3_ADSB/kbfi-0001/ PATTERN = '.*2021/01/01.*';
LIST @STG_S3_ADSB/kapa-0001/ PATTERN = '.*2021/01/01.*';

-- =============================================================
-- 8. Staging Table - captures raw JSON + audit columns
-- =============================================================
CREATE OR REPLACE TABLE CAPSTONE_db.RAW.ADSB_RAW (
    raw_data         VARIANT       NOT NULL,
    source_filename  STRING        NOT NULL,
    source_row_num   NUMBER        NOT NULL,
    station_id       STRING        COMMENT 'Derived from filename: kapa-0001 or kbfi-0001',
    load_timestamp   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Raw ADS-B data with full source traceability';

-- =============================================================
-- 9. Sample COPY command - load kbfi-0001 first (smaller dataset)
--    Run this to test your pipeline before loading kapa-0001
-- =============================================================

-- Load kbfi-0001 (all data, ~1 year)
COPY INTO CAPSTONE_db.RAW.ADSB_RAW (raw_data, source_filename, source_row_num, station_id)
FROM (
    SELECT
        $1,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        SPLIT_PART(METADATA$FILENAME, '/', 1)   -- extracts 'kbfi-0001'
    FROM @STG_S3_ADSB/kbfi-0001/
)
PURGE = FALSE
FORCE = FALSE
ON_ERROR = 'CONTINUE';

-- Check what loaded
SELECT COUNT(*) AS row_count,
       COUNT(DISTINCT source_filename) AS file_count,
       MIN(load_timestamp) AS first_loaded,
       MAX(load_timestamp) AS last_loaded
FROM CAPSTONE_db.RAW.ADSB_RAW
WHERE station_id = 'kbfi-0001';

-- =============================================================
-- 10. Load kapa-0001 year by year (larger dataset)
--     Run each block one at a time, verify, then move to next
-- =============================================================

-- kapa-0001: 2021
COPY INTO CAPSTONE_db.RAW.ADSB_RAW (raw_data, source_filename, source_row_num, station_id)
FROM (
    SELECT
        $1,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        SPLIT_PART(METADATA$FILENAME, '/', 1)
    FROM @STG_S3_ADSB/kapa-0001/2021/
)
PURGE = FALSE
FORCE = FALSE
ON_ERROR = 'CONTINUE';

-- kapa-0001: 2022
COPY INTO CAPSTONE_db.RAW.ADSB_RAW (raw_data, source_filename, source_row_num, station_id)
FROM (
    SELECT
        $1,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        SPLIT_PART(METADATA$FILENAME, '/', 1)
    FROM @STG_S3_ADSB/kapa-0001/2022/
)
PURGE = FALSE
FORCE = FALSE
ON_ERROR = 'CONTINUE';

-- kapa-0001: 2023
COPY INTO CAPSTONE_db.RAW.ADSB_RAW (raw_data, source_filename, source_row_num, station_id)
FROM (
    SELECT
        $1,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        SPLIT_PART(METADATA$FILENAME, '/', 1)
    FROM @STG_S3_ADSB/kapa-0001/2023/
)
PURGE = FALSE
FORCE = FALSE
ON_ERROR = 'CONTINUE';

-- kapa-0001: 2024
COPY INTO CAPSTONE_db.RAW.ADSB_RAW (raw_data, source_filename, source_row_num, station_id)
FROM (
    SELECT
        $1,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        SPLIT_PART(METADATA$FILENAME, '/', 1)
    FROM @STG_S3_ADSB/kapa-0001/2024/
)
PURGE = FALSE
FORCE = FALSE
ON_ERROR = 'CONTINUE';

-- kapa-0001: 2025 (through May)
COPY INTO CAPSTONE_db.RAW.ADSB_RAW (raw_data, source_filename, source_row_num, station_id)
FROM (
    SELECT
        $1,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER,
        SPLIT_PART(METADATA$FILENAME, '/', 1)
    FROM @STG_S3_ADSB/kapa-0001/2025/
)
PURGE = FALSE
FORCE = FALSE
ON_ERROR = 'CONTINUE';

-- =============================================================
-- 11. Final verification
-- =============================================================
SELECT
    station_id,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT source_filename) AS total_files,
    MIN(source_filename) AS earliest_file,
    MAX(source_filename) AS latest_file
FROM CAPSTONE_db.RAW.ADSB_RAW
GROUP BY station_id
ORDER BY station_id;

-- Sample a few rows to inspect JSON structure
SELECT raw_data, source_filename, source_row_num
FROM CAPSTONE_db.RAW.ADSB_RAW
LIMIT 10;

-- Audit query: trace any row back to source
-- SELECT * FROM CAPSTONE_db.RAW.ADSB_RAW
-- WHERE source_filename = '<filename>' AND source_row_num = <N>;

-- =============================================================
-- 12. After bulk load is done, resize warehouse down
-- =============================================================
-- ALTER WAREHOUSE CAPSTONE_LOAD_WH SET WAREHOUSE_SIZE = 'XSMALL';
