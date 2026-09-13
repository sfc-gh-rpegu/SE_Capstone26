-- =============================================================
-- SE Capstone: FAA Reference Data - Load with INFER_SCHEMA
-- =============================================================
-- Prerequisites:
--   1. Download ReleasableAircraft.zip from https://registry.faa.gov/database/ReleasableAircraft.zip
--   2. Unzip it locally - you'll get several .txt files (MASTER.txt, ACFTREF.txt, ENGINE.txt, DEREG.txt, etc.)
--   3. Run this script section by section
-- =============================================================

USE DATABASE CAPSTONE_ADSB;
USE SCHEMA RAW;
USE WAREHOUSE CAPSTONE_LOAD_WH;

-- =============================================================
-- 1. Create an internal stage for FAA files
-- =============================================================
CREATE OR REPLACE STAGE STG_FAA_DATA
    COMMENT = 'Internal stage for FAA reference data files';

-- =============================================================
-- 2. Upload FAA text files to the stage
--    Run these PUT commands from SnowSQL CLI (not Snowsight worksheet)
--    Adjust the local path to where you unzipped the files
-- =============================================================

-- FROM SNOWSQL CLI:
-- PUT file:///path/to/ReleasableAircraft/MASTER.txt @CAPSTONE_ADSB.RAW.STG_FAA_DATA/master/ AUTO_COMPRESS=TRUE;
-- PUT file:///path/to/ReleasableAircraft/ACFTREF.txt @CAPSTONE_ADSB.RAW.STG_FAA_DATA/acftref/ AUTO_COMPRESS=TRUE;
-- PUT file:///path/to/ReleasableAircraft/ENGINE.txt @CAPSTONE_ADSB.RAW.STG_FAA_DATA/engine/ AUTO_COMPRESS=TRUE;
-- PUT file:///path/to/ReleasableAircraft/DEREG.txt @CAPSTONE_ADSB.RAW.STG_FAA_DATA/dereg/ AUTO_COMPRESS=TRUE;

-- FROM SNOWSIGHT WORKSHEET (drag and drop alternative):
-- You can also use Snowsight: go to Data > Databases > CAPSTONE_ADSB > RAW > Stages > STG_FAA_DATA
-- Click "+ Files" and upload each .txt file into subfolders

-- =============================================================
-- 3. Verify files are staged
-- =============================================================
LIST @STG_FAA_DATA;

-- =============================================================
-- 4. Create a file format for FAA text files
--    FAA files are comma-delimited text with headers
--    Some fields have leading/trailing spaces, so TRIM_SPACE = TRUE
-- =============================================================
CREATE OR REPLACE FILE FORMAT FF_FAA_CSV
    TYPE = 'CSV'
    FIELD_DELIMITER = ','
    RECORD_DELIMITER = '\n'
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    TRIM_SPACE = TRUE
    ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE
    ENCODING = 'UTF8'
    NULL_IF = ('', 'NULL', 'null');

-- =============================================================
-- 5. Preview data from each file to see what's there
-- =============================================================

-- Preview MASTER.txt
SELECT $1, $2, $3, $4, $5
FROM @STG_FAA_DATA/master/
(FILE_FORMAT => FF_FAA_CSV)
LIMIT 5;

-- Preview ACFTREF.txt
SELECT $1, $2, $3, $4, $5
FROM @STG_FAA_DATA/acftref/
(FILE_FORMAT => FF_FAA_CSV)
LIMIT 5;

-- Preview ENGINE.txt
SELECT $1, $2, $3, $4, $5
FROM @STG_FAA_DATA/engine/
(FILE_FORMAT => FF_FAA_CSV)
LIMIT 5;

-- Preview DEREG.txt
SELECT $1, $2, $3, $4, $5
FROM @STG_FAA_DATA/dereg/
(FILE_FORMAT => FF_FAA_CSV)
LIMIT 5;

-- =============================================================
-- 6. Use INFER_SCHEMA to detect column names and types
-- =============================================================

-- Infer MASTER.txt schema
SELECT *
FROM TABLE(
    INFER_SCHEMA(
        LOCATION => '@STG_FAA_DATA/master/',
        FILE_FORMAT => 'FF_FAA_CSV',
        IGNORE_CASE => TRUE
    )
);

-- Infer ACFTREF.txt schema
SELECT *
FROM TABLE(
    INFER_SCHEMA(
        LOCATION => '@STG_FAA_DATA/acftref/',
        FILE_FORMAT => 'FF_FAA_CSV',
        IGNORE_CASE => TRUE
    )
);

-- Infer ENGINE.txt schema
SELECT *
FROM TABLE(
    INFER_SCHEMA(
        LOCATION => '@STG_FAA_DATA/engine/',
        FILE_FORMAT => 'FF_FAA_CSV',
        IGNORE_CASE => TRUE
    )
);

-- Infer DEREG.txt schema
SELECT *
FROM TABLE(
    INFER_SCHEMA(
        LOCATION => '@STG_FAA_DATA/dereg/',
        FILE_FORMAT => 'FF_FAA_CSV',
        IGNORE_CASE => TRUE
    )
);

-- =============================================================
-- 7. Auto-create tables using INFER_SCHEMA with CREATE TABLE ... USING TEMPLATE
--    This creates tables with column names and types detected from the files
-- =============================================================

-- MASTER table (aircraft registration)
CREATE OR REPLACE TABLE CAPSTONE_ADSB.RAW.FAA_MASTER
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@STG_FAA_DATA/master/',
                FILE_FORMAT => 'FF_FAA_CSV',
                IGNORE_CASE => TRUE
            )
        )
    );

-- ACFTREF table (aircraft reference)
CREATE OR REPLACE TABLE CAPSTONE_ADSB.RAW.FAA_ACFTREF
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@STG_FAA_DATA/acftref/',
                FILE_FORMAT => 'FF_FAA_CSV',
                IGNORE_CASE => TRUE
            )
        )
    );

-- ENGINE table (engine reference)
CREATE OR REPLACE TABLE CAPSTONE_ADSB.RAW.FAA_ENGINE
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@STG_FAA_DATA/engine/',
                FILE_FORMAT => 'FF_FAA_CSV',
                IGNORE_CASE => TRUE
            )
        )
    );

-- DEREG table (deregistered aircraft)
CREATE OR REPLACE TABLE CAPSTONE_ADSB.RAW.FAA_DEREG
    USING TEMPLATE (
        SELECT ARRAY_AGG(OBJECT_CONSTRUCT(*))
        FROM TABLE(
            INFER_SCHEMA(
                LOCATION => '@STG_FAA_DATA/dereg/',
                FILE_FORMAT => 'FF_FAA_CSV',
                IGNORE_CASE => TRUE
            )
        )
    );

-- =============================================================
-- 8. Verify the auto-created table structures
-- =============================================================
DESCRIBE TABLE CAPSTONE_ADSB.RAW.FAA_MASTER;
DESCRIBE TABLE CAPSTONE_ADSB.RAW.FAA_ACFTREF;
DESCRIBE TABLE CAPSTONE_ADSB.RAW.FAA_ENGINE;
DESCRIBE TABLE CAPSTONE_ADSB.RAW.FAA_DEREG;

-- =============================================================
-- 9. Load data into the auto-created tables
--    MATCH_BY_COLUMN_NAME ensures columns match by header name
-- =============================================================

-- Load MASTER
COPY INTO CAPSTONE_ADSB.RAW.FAA_MASTER
FROM @STG_FAA_DATA/master/
FILE_FORMAT = (FORMAT_NAME = 'FF_FAA_CSV')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
PURGE = FALSE
ON_ERROR = 'CONTINUE';

-- Load ACFTREF
COPY INTO CAPSTONE_ADSB.RAW.FAA_ACFTREF
FROM @STG_FAA_DATA/acftref/
FILE_FORMAT = (FORMAT_NAME = 'FF_FAA_CSV')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
PURGE = FALSE
ON_ERROR = 'CONTINUE';

-- Load ENGINE
COPY INTO CAPSTONE_ADSB.RAW.FAA_ENGINE
FROM @STG_FAA_DATA/engine/
FILE_FORMAT = (FORMAT_NAME = 'FF_FAA_CSV')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
PURGE = FALSE
ON_ERROR = 'CONTINUE';

-- Load DEREG
COPY INTO CAPSTONE_ADSB.RAW.FAA_DEREG
FROM @STG_FAA_DATA/dereg/
FILE_FORMAT = (FORMAT_NAME = 'FF_FAA_CSV')
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
PURGE = FALSE
ON_ERROR = 'CONTINUE';

-- =============================================================
-- 10. Verify row counts
-- =============================================================
SELECT 'FAA_MASTER' AS table_name, COUNT(*) AS row_count FROM CAPSTONE_ADSB.RAW.FAA_MASTER
UNION ALL
SELECT 'FAA_ACFTREF', COUNT(*) FROM CAPSTONE_ADSB.RAW.FAA_ACFTREF
UNION ALL
SELECT 'FAA_ENGINE', COUNT(*) FROM CAPSTONE_ADSB.RAW.FAA_ENGINE
UNION ALL
SELECT 'FAA_DEREG', COUNT(*) FROM CAPSTONE_ADSB.RAW.FAA_DEREG;

-- =============================================================
-- 11. Sample data from each table
-- =============================================================
SELECT * FROM CAPSTONE_ADSB.RAW.FAA_MASTER LIMIT 10;
SELECT * FROM CAPSTONE_ADSB.RAW.FAA_ACFTREF LIMIT 10;
SELECT * FROM CAPSTONE_ADSB.RAW.FAA_ENGINE LIMIT 10;
SELECT * FROM CAPSTONE_ADSB.RAW.FAA_DEREG LIMIT 10;

-- =============================================================
-- NOTES:
-- =============================================================
-- If INFER_SCHEMA has trouble with a specific file:
--   1. Check the delimiter - some FAA files may use ',' and some may use '\t'
--      If tab-delimited, create a separate file format:
--      CREATE OR REPLACE FILE FORMAT FF_FAA_TAB
--          TYPE = 'CSV'
--          FIELD_DELIMITER = '\t'
--          SKIP_HEADER = 1
--          TRIM_SPACE = TRUE;
--
--   2. If column count mismatch errors occur, the file may have trailing
--      commas. Try setting ERROR_ON_COLUMN_COUNT_MISMATCH = FALSE (already set above)
--
--   3. If INFER_SCHEMA detects wrong types (e.g., treats a zip code as NUMBER),
--      you can manually ALTER TABLE to fix specific columns:
--      ALTER TABLE FAA_MASTER ALTER COLUMN ZIP_CODE SET DATA TYPE VARCHAR;
--
-- For monthly refresh process (discuss in POC ReadOut):
--   1. Download new ReleasableAircraft.zip
--   2. PUT new files to stage (overwrite)
--   3. TRUNCATE existing FAA tables
--   4. Re-run COPY INTO with FORCE = TRUE
--   OR use MERGE for incremental updates based on N-NUMBER as key
