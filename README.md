## About :
SE captsone Project . 

## Outcome: Built and validated an end-to-end, event-driven ADS-B pipeline on Snowflake. 

Two firmware formats normalised into one model, enriched with FAA data, 15-minute SLA met. Recommendation: Dynamic Tables — same SLA, 4 objects reduced to 1.


## What was delivered
Automated ingest — Snowpipe fires on S3 events; no scheduling, no polling
Schema unification — flat JSON (KAPA) + nested array JSON (KBFI) into one conformed table
FAA enrichment — owner, manufacturer and model on every flight record
Full traceability — every row carries source file name and row number
