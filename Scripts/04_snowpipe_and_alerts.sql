-- =============================================================
-- SE Capstone: Snowpipe Auto-Ingest for ADS-B Trickle Feed
-- Two pipes (kapa-0001, kbfi-0001) + monitoring alert
-- =============================================================
-- Prerequisites:
--   1. External stage CAPSTONE26_DB.PROD.CAPSTONE_S3_STAGE exists (s3://capstone-rpegu/)
--   2. Storage integration INTG_S3_CAPSTONE is configured
--   3. S3 event notifications must be configured on your bucket (see Step 3 below)
-- =============================================================

USE ROLE CAPSTONE26_RPEGU;
USE DATABASE CAPSTONE26_DB;
USE SCHEMA RAW;
USE WAREHOUSE CAP26_WH;

-- =============================================================
-- 1. Create separate landing tables for each station's trickle feed
-- =============================================================

CREATE TABLE IF NOT EXISTS ADSB_RAW_KAPA_PIPE (
    RAW_DATA         VARIANT       NOT NULL,
    SOURCE_FILENAME  VARCHAR       NOT NULL,
    SOURCE_ROW_NUM   NUMBER        NOT NULL,
    STATION_ID       VARCHAR       DEFAULT 'kapa-0001',
    LOAD_TIMESTAMP   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Snowpipe landing table for kapa-0001 trickle-feed data';

CREATE TABLE IF NOT EXISTS ADSB_RAW_KBFI_PIPE (
    RAW_DATA         VARIANT       NOT NULL,
    SOURCE_FILENAME  VARCHAR       NOT NULL,
    SOURCE_ROW_NUM   NUMBER        NOT NULL,
    STATION_ID       VARCHAR       DEFAULT 'kbfi-0001',
    LOAD_TIMESTAMP   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Snowpipe landing table for kbfi-0001 trickle-feed data';

-- =============================================================
-- 2. Create Snowpipes (auto-ingest from S3 event notifications)
-- =============================================================

-- Pipe for kapa-0001 (newer firmware, currently streaming)
CREATE OR REPLACE PIPE CAPSTONE26_DB.RAW.PIPE_ADSB_KAPA
    AUTO_INGEST = TRUE
    COMMENT = 'Auto-ingest pipe for kapa-0001 ADS-B trickle-feed'
AS
COPY INTO CAPSTONE26_DB.RAW.ADSB_RAW_KAPA_PIPE (RAW_DATA, SOURCE_FILENAME, SOURCE_ROW_NUM)
FROM (
    SELECT
        $1,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER
    FROM @CAPSTONE26_DB.PROD.CAPSTONE_S3_STAGE/kapa-0001/
)
FILE_FORMAT = (FORMAT_NAME = 'CAPSTONE26_DB.RAW.FF_JSON')
PURGE = FALSE;

-- Pipe for kbfi-0001 (older firmware, historical)
CREATE OR REPLACE PIPE CAPSTONE26_DB.RAW.PIPE_ADSB_KBFI
    AUTO_INGEST = TRUE
    COMMENT = 'Auto-ingest pipe for kbfi-0001 ADS-B trickle-feed'
AS
COPY INTO CAPSTONE26_DB.RAW.ADSB_RAW_KBFI_PIPE (RAW_DATA, SOURCE_FILENAME, SOURCE_ROW_NUM)
FROM (
    SELECT
        $1,
        METADATA$FILENAME,
        METADATA$FILE_ROW_NUMBER
    FROM @CAPSTONE26_DB.PROD.CAPSTONE_S3_STAGE/kbfi-0001/
)
FILE_FORMAT = (FORMAT_NAME = 'CAPSTONE26_DB.RAW.FF_JSON')
PURGE = FALSE;

-- =============================================================
-- 3. Get the SQS queue ARN for S3 event notification setup
--    You need this to configure your S3 bucket notifications
-- =============================================================

SHOW PIPES IN CAPSTONE26_DB.RAW;

-- Copy the notification_channel value for each pipe
-- Then go to AWS Console > S3 > your bucket > Properties > Event notifications
-- Create an event notification:
--   Event types: s3:ObjectCreated:*
--   Prefix filter: kapa-0001/   (for PIPE_ADSB_KAPA)
--   Destination: SQS queue ARN from SHOW PIPES
-- Repeat for kbfi-0001/ prefix with PIPE_ADSB_KBFI's SQS ARN

-- Or get the ARN directly:
SELECT SYSTEM$PIPE_STATUS('CAPSTONE26_DB.RAW.PIPE_ADSB_KAPA');
SELECT SYSTEM$PIPE_STATUS('CAPSTONE26_DB.RAW.PIPE_ADSB_KBFI');

-- =============================================================
-- 4. Verify pipes are running
-- =============================================================

-- Check pipe status
SELECT SYSTEM$PIPE_STATUS('CAPSTONE26_DB.RAW.PIPE_ADSB_KAPA') AS kapa_status;
SELECT SYSTEM$PIPE_STATUS('CAPSTONE26_DB.RAW.PIPE_ADSB_KBFI') AS kbfi_status;

-- Check recent pipe load history
SELECT *
FROM TABLE(INFORMATION_SCHEMA.PIPE_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
    PIPE_NAME => 'CAPSTONE26_DB.RAW.PIPE_ADSB_KAPA'
));

SELECT *
FROM TABLE(INFORMATION_SCHEMA.PIPE_USAGE_HISTORY(
    DATE_RANGE_START => DATEADD('hour', -24, CURRENT_TIMESTAMP()),
    PIPE_NAME => 'CAPSTONE26_DB.RAW.PIPE_ADSB_KBFI'
));

-- Check COPY history for the pipe tables
SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
    TABLE_NAME => 'CAPSTONE26_DB.RAW.ADSB_RAW_KAPA_PIPE',
    START_TIME => DATEADD('hour', -24, CURRENT_TIMESTAMP())
))
ORDER BY LAST_LOAD_TIME DESC
LIMIT 20;

-- =============================================================
-- 5. Manual refresh (if S3 events are not configured yet)
--    Use this to trigger pipe to scan for new files
-- =============================================================

-- Force a refresh to pick up files already in the bucket
ALTER PIPE CAPSTONE26_DB.RAW.PIPE_ADSB_KAPA REFRESH;
ALTER PIPE CAPSTONE26_DB.RAW.PIPE_ADSB_KBFI REFRESH;

-- =============================================================
-- 6. Row count monitoring query
-- =============================================================
SELECT
    'KAPA_PIPE' AS source,
    COUNT(*) AS total_rows,
    COUNT(DISTINCT SOURCE_FILENAME) AS total_files,
    MAX(LOAD_TIMESTAMP) AS last_loaded
FROM CAPSTONE26_DB.RAW.ADSB_RAW_KAPA_PIPE
UNION ALL
SELECT
    'KBFI_PIPE',
    COUNT(*),
    COUNT(DISTINCT SOURCE_FILENAME),
    MAX(LOAD_TIMESTAMP)
FROM CAPSTONE26_DB.RAW.ADSB_RAW_KBFI_PIPE;

-- =============================================================
-- 7. Create Alert: Monitor Snowpipe health
--    Fires if no new data loaded in last 30 minutes
--    (adjust threshold based on your trickle-feed frequency)
-- =============================================================

-- First, create a notification integration for email alerts
-- (requires ACCOUNTADMIN)
-- CREATE OR REPLACE NOTIFICATION INTEGRATION CAPSTONE_EMAIL_INT
--     TYPE = EMAIL
--     ENABLED = TRUE
--     ALLOWED_RECIPIENTS = ('ranjeeta.pegu@snowflake.com');

-- Alert: No KAPA data in 30 minutes
CREATE OR REPLACE ALERT CAPSTONE26_DB.RAW.ALERT_KAPA_PIPE_STALE
    WAREHOUSE = CAP26_WH
    SCHEDULE = '15 MINUTE'
    IF (EXISTS (
        SELECT 1
        WHERE (
            SELECT DATEDIFF('minute', MAX(LOAD_TIMESTAMP), CURRENT_TIMESTAMP())
            FROM CAPSTONE26_DB.RAW.ADSB_RAW_KAPA_PIPE
        ) > 30
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'CAPSTONE_EMAIL_INT',
            'ranjeeta.pegu@snowflake.com',
            'ALERT: Snowpipe KAPA stale - No new data in 30+ minutes',
            'The Snowpipe PIPE_ADSB_KAPA has not loaded new data in over 30 minutes. ' ||
            'Last load was at: ' ||
            (SELECT MAX(LOAD_TIMESTAMP)::VARCHAR FROM CAPSTONE26_DB.RAW.ADSB_RAW_KAPA_PIPE) ||
            '. Please check SYSTEM$PIPE_STATUS and S3 event notifications.'
        );

-- Alert: No KBFI data in 30 minutes
CREATE OR REPLACE ALERT CAPSTONE26_DB.RAW.ALERT_KBFI_PIPE_STALE
    WAREHOUSE = CAP26_WH
    SCHEDULE = '15 MINUTE'
    IF (EXISTS (
        SELECT 1
        WHERE (
            SELECT DATEDIFF('minute', MAX(LOAD_TIMESTAMP), CURRENT_TIMESTAMP())
            FROM CAPSTONE26_DB.RAW.ADSB_RAW_KBFI_PIPE
        ) > 30
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'CAPSTONE_EMAIL_INT',
            'ranjeeta.pegu@snowflake.com',
            'ALERT: Snowpipe KBFI stale - No new data in 30+ minutes',
            'The Snowpipe PIPE_ADSB_KBFI has not loaded new data in over 30 minutes. ' ||
            'Last load was at: ' ||
            (SELECT MAX(LOAD_TIMESTAMP)::VARCHAR FROM CAPSTONE26_DB.RAW.ADSB_RAW_KBFI_PIPE) ||
            '. Please check SYSTEM$PIPE_STATUS and S3 event notifications.'
        );

-- Alert: Pipe error detection (checks for failed files)
CREATE OR REPLACE ALERT CAPSTONE26_DB.RAW.ALERT_PIPE_ERRORS
    WAREHOUSE = CAP26_WH
    SCHEDULE = '15 MINUTE'
    IF (EXISTS (
        SELECT 1
        FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
            TABLE_NAME => 'CAPSTONE26_DB.RAW.ADSB_RAW_KAPA_PIPE',
            START_TIME => DATEADD('minute', -30, CURRENT_TIMESTAMP())
        ))
        WHERE STATUS = 'LOAD_FAILED'
    ))
    THEN
        CALL SYSTEM$SEND_EMAIL(
            'CAPSTONE_EMAIL_INT',
            'ranjeeta.pegu@snowflake.com',
            'ALERT: Snowpipe load failures detected',
            'One or more files failed to load via Snowpipe in the last 30 minutes. ' ||
            'Run COPY_HISTORY to investigate failed files.'
        );

-- =============================================================
-- 8. Resume alerts (they are created in suspended state)
-- =============================================================
ALTER ALERT CAPSTONE26_DB.RAW.ALERT_KAPA_PIPE_STALE RESUME;
ALTER ALERT CAPSTONE26_DB.RAW.ALERT_KBFI_PIPE_STALE RESUME;
ALTER ALERT CAPSTONE26_DB.RAW.ALERT_PIPE_ERRORS RESUME;

-- =============================================================
-- 9. Pause/suspend when not needed
-- =============================================================
-- ALTER ALERT CAPSTONE26_DB.RAW.ALERT_KAPA_PIPE_STALE SUSPEND;
-- ALTER ALERT CAPSTONE26_DB.RAW.ALERT_KBFI_PIPE_STALE SUSPEND;
-- ALTER ALERT CAPSTONE26_DB.RAW.ALERT_PIPE_ERRORS SUSPEND;

-- Pause pipes when not testing
-- ALTER PIPE CAPSTONE26_DB.RAW.PIPE_ADSB_KAPA SET PIPE_EXECUTION_PAUSED = TRUE;
-- ALTER PIPE CAPSTONE26_DB.RAW.PIPE_ADSB_KBFI SET PIPE_EXECUTION_PAUSED = TRUE;

-- Resume pipes
-- ALTER PIPE CAPSTONE26_DB.RAW.PIPE_ADSB_KAPA SET PIPE_EXECUTION_PAUSED = FALSE;
-- ALTER PIPE CAPSTONE26_DB.RAW.PIPE_ADSB_KBFI SET PIPE_EXECUTION_PAUSED = FALSE;

-- =============================================================
-- NOTES:
-- =============================================================
-- S3 Event Notification Setup (in AWS Console):
--   1. Go to S3 > capstone-rpegu > Properties > Event notifications
--   2. Create notification for kapa-0001:
--      - Name: snowpipe-kapa
--      - Prefix: kapa-0001/
--      - Event types: All object create events (s3:ObjectCreated:*)
--      - Destination: SQS queue
--      - SQS ARN: (from SHOW PIPES notification_channel column)
--   3. Create notification for kbfi-0001:
--      - Name: snowpipe-kbfi
--      - Prefix: kbfi-0001/
--      - Event types: All object create events
--      - SQS ARN: (from SHOW PIPES notification_channel column)
--
-- IMPORTANT:
--   - Both pipes share the same SQS queue ARN (Snowflake creates one per account)
--   - The prefix filter in S3 ensures each pipe only processes its station's files
--   - Snowpipe is serverless - no warehouse needed for loading (auto-scales)
--   - Alerts DO need a warehouse (CAP26_WH) for the scheduled check queries
--
-- Cost:
--   - Snowpipe charges per file loaded (credits based on file size)
--   - Alerts charge warehouse time every 15 minutes for the check query
--   - For the POC ReadOut: estimate ~0.06 credits/TB for Snowpipe loading
