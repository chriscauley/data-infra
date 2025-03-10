---
operator: operators.SqlToWarehouseOperator
dst_table_name: "views.gtfs_schedule_fact_daily_feed_files"

tests:
  check_null:
    - feed_key
    - file_key
    - date
  check_composite_unique:
    - feed_key
    - file_key
    - date

description: |
  Each row of this table is a file extracted from a feed on a given day. Note that on days where
  the extractor failed to download files for a feed, we interpolate by using the previous day's files.
  This is tracked using the is_interpolated column.

dependencies:
  - gtfs_schedule_dim_feeds
  - dim_date
---

WITH

-- calitp_files_updates tracks daily each file downloaded from a gtfs schedule
-- zip file. It has 1 entry feed downloaded, per file, per day
raw_daily_files AS (
    SELECT
        T2.feed_key
        , T1.name AS file_key
        , T1.calitp_extracted_at AS date
        , T1.size
        , T1.md5_hash
        , T1.is_loadable_file
        , T1.is_changed
        , T1.is_first_extraction
        , T1.is_validation
        , T1.is_agency_changed
        , T1.full_path
        , FALSE AS is_interpolated
        , T3.parse_error_encountered

        -- calculate the leading date, so we can fill in missing rows, where
        -- extraction failed to run.
        , LEAD(T1.calitp_extracted_at)
            OVER (PARTITION BY T1.calitp_itp_id, T1.calitp_url_number, T1.name ORDER BY T1.calitp_extracted_at)
            AS tmp_next_date

    FROM `gtfs_schedule_history.calitp_files_updates` T1
    JOIN `views.gtfs_schedule_dim_feeds` T2
        USING(calitp_itp_id, calitp_url_number)
    LEFT JOIN `gtfs_schedule_history.calitp_feed_tables_parse_result` T3
        ON
            T1.calitp_itp_id = T3.calitp_itp_id
            AND T1.calitp_url_number = T3.calitp_url_number
            AND T1.calitp_extracted_at = T3.calitp_extracted_at
            AND T1.name = T3.filename
    WHERE
        T1.calitp_extracted_at >= T2.calitp_extracted_at
        AND T1.calitp_extracted_at < T2.calitp_deleted_at
),

date_range AS (
    SELECT full_date
    FROM `views.dim_date`
    WHERE is_gtfs_schedule_range
),

interp_daily_files AS (
    SELECT
        feed_key
        , file_key
        , date AS date_original
        , full_date AS date
        , Files.date != D.full_date AS is_interpolated
    FROM raw_daily_files Files
    CROSS JOIN date_range D
    WHERE Files.date <= D.full_date
        AND COALESCE(Files.tmp_next_date, "2099-01-01") > D.full_date
)

SELECT * EXCEPT(date_original, tmp_next_date)
FROM interp_daily_files
FULL OUTER JOIN raw_daily_files
    USING(feed_key, file_key, date, is_interpolated)
ORDER BY feed_key, file_key, date
