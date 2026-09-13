-- =============================================================
-- SE Capstone: Parse ardata.pdf using AI_PARSE_DOCUMENT
-- =============================================================

USE ROLE CAPSTONE26_RPEGU;
USE DATABASE CAPSTONE26_DB;
USE SCHEMA RAW;
USE WAREHOUSE CAP26_WH;

-- =============================================================
-- 1. Quick OCR extraction (text only, fast)
-- =============================================================
SELECT AI_PARSE_DOCUMENT(
    TO_FILE('@STG_FAA', 'ardata.pdf'),
    {'mode': 'OCR'}
) AS faa_data_dictionary;

-- =============================================================
-- 2. LAYOUT mode with page splitting (preserves tables/structure)
-- =============================================================
SELECT AI_PARSE_DOCUMENT(
    TO_FILE('@STG_FAA', 'ardata.pdf'),
    {'mode': 'LAYOUT', 'page_split': true}
) AS faa_data_dictionary_layout;

-- =============================================================
-- 3. Parse and store as a table (one row per page)
-- =============================================================
CREATE OR REPLACE TABLE FAA_DATA_DICTIONARY AS
SELECT
    p.value:index::INT        AS page_index,
    p.value:content::STRING   AS page_content,
    CURRENT_TIMESTAMP()       AS parsed_at
FROM (
    SELECT PARSE_JSON(
        AI_PARSE_DOCUMENT(
            TO_FILE('@STG_FAA', 'ardata.pdf'),
            {'mode': 'LAYOUT', 'page_split': true}
        )
    ) AS parsed
) doc,
LATERAL FLATTEN(input => doc.parsed:pages) p;

-- =============================================================
-- 4. View all pages
-- =============================================================
SELECT page_index, page_content
FROM FAA_DATA_DICTIONARY
ORDER BY page_index;

-- =============================================================
-- 5. Search for specific terms in the data dictionary
-- =============================================================
SELECT page_index, page_content
FROM FAA_DATA_DICTIONARY
WHERE page_content ILIKE '%MODE S%'
ORDER BY page_index;

-- Search for column definitions
SELECT page_index, page_content
FROM FAA_DATA_DICTIONARY
WHERE page_content ILIKE '%N-NUMBER%'
ORDER BY page_index;
