-- ---------------------------------------------------------------------------
-- 08  rep - conformed dimensions
-- ---------------------------------------------------------------------------
-- dim_date and dim_time. Both are generated: they have no source table, take
-- nothing from PolicePro, and are not part of the nightly run. Facts join to
-- them on integer surrogate keys rather than on native date and time values,
-- so a fact row with an unparseable time still joins to something.
--
-- Extending the date range is the only routine maintenance. Edit the two dates
-- in the bounds block below and re-run this file: the insert is ON CONFLICT DO
-- NOTHING, so existing rows are left alone and only the new days are added.
-- Nothing here rebuilds, so a fact row can never be orphaned by a re-run.
--
-- Each dimension carries a sentinel row, key -1, labelled Unknown. A fact date
-- that is NULL, or outside the range, resolves to it rather than to nothing -
-- so the record still counts, and shows as Unknown instead of disappearing
-- from the report. rep.date_key() and rep.time_key() do that resolution and
-- are the only place the rule lives.
--
-- Check coverage with rep.v_dim_coverage, at the end of this file, before the
-- range runs out rather than after.
--
-- Safe to re-run. Run as an administrator, connected to pp_rdw, after 07.
-- ---------------------------------------------------------------------------

ALTER TABLE IF EXISTS rep.dim_date OWNER TO pp_owner;
ALTER TABLE IF EXISTS rep.dim_time OWNER TO pp_owner;

SET ROLE pp_owner;

-- ---------------------------------------------------------------------------
-- rep.dim_date
-- ---------------------------------------------------------------------------
-- One row per calendar day. date_key is YYYYMMDD as an integer, so a fact
-- carries a readable key and the natural sort is chronological.
--
-- Fiscal year runs July to June. fiscal_year is the year the period ENDS in,
-- which is the Tongan and Australasian convention: 1 July 2026 to 30 June 2027
-- is fiscal_year 2027, labelled "2026/27". Anything reporting by fiscal year
-- should use these columns rather than deriving the offset again.
CREATE TABLE IF NOT EXISTS rep.dim_date (
    date_key            integer PRIMARY KEY,   -- YYYYMMDD, -1 = Unknown
    -- Nullable only so the sentinel row can exist; the CHECK at the end of
    -- the table ties a NULL date to key -1 and nothing else. Written as an
    -- equivalence rather than "key > 0" because midnight is key 0.
    date                date    UNIQUE,
    year                integer NOT NULL,
    quarter             integer NOT NULL,
    quarter_label       text    NOT NULL,      -- 2026 Q3
    month               integer NOT NULL,      -- sort column for month_name
    month_name          text    NOT NULL,
    month_short         text    NOT NULL,
    year_month          integer NOT NULL,      -- YYYYMM, sort column for month_label
    month_label         text    NOT NULL,      -- Sep 2026
    day                 integer NOT NULL,
    day_of_week         integer NOT NULL,      -- ISO: Monday = 1, Sunday = 7
    day_name            text    NOT NULL,
    day_short           text    NOT NULL,
    day_of_year         integer NOT NULL,
    iso_year            integer NOT NULL,
    iso_week            integer NOT NULL,
    iso_week_label      text    NOT NULL,      -- 2026-W39
    is_weekend          boolean NOT NULL,
    month_start         date,
    month_end           date,
    fiscal_year         integer NOT NULL,      -- the year the fiscal year ends
    fiscal_year_label   text    NOT NULL,      -- 2026/27
    fiscal_quarter      integer NOT NULL,      -- Jul-Sep = 1
    fiscal_quarter_label text   NOT NULL,      -- 2026/27 Q1
    CONSTRAINT dim_date_sentinel_ck CHECK ((date_key = -1) = (date IS NULL))
);

-- For a table created before the sentinel row was introduced.
ALTER TABLE rep.dim_date ALTER COLUMN date        DROP NOT NULL;
ALTER TABLE rep.dim_date ALTER COLUMN month_start DROP NOT NULL;
ALTER TABLE rep.dim_date ALTER COLUMN month_end   DROP NOT NULL;
-- Dropped and re-added rather than skipped when present, so a table built by
-- an earlier version of this file is corrected rather than left as it was.
ALTER TABLE rep.dim_date DROP CONSTRAINT IF EXISTS dim_date_sentinel_ck;
ALTER TABLE rep.dim_date ADD  CONSTRAINT dim_date_sentinel_ck CHECK ((date_key = -1) = (date IS NULL));

-- The sentinel. Everything a report might group by reads Unknown, and every
-- numeric attribute is -1, so a mis-keyed date can never be mistaken for a
-- real one or quietly averaged into anything.
INSERT INTO rep.dim_date VALUES (
    -1, NULL, -1, -1, 'Unknown', -1, 'Unknown', 'Unk', -1, 'Unknown', -1,
    -1, 'Unknown', 'Unk', -1, -1, -1, 'Unknown', false, NULL, NULL,
    -1, 'Unknown', -1, 'Unknown')
ON CONFLICT (date_key) DO NOTHING;

INSERT INTO rep.dim_date
WITH bounds AS (
    -- >>> the only lines to edit when extending the range <<<
    SELECT DATE '2025-01-01' AS from_date,
           DATE '2027-12-31' AS to_date
),
days AS (
    SELECT generate_series(from_date, to_date, INTERVAL '1 day')::date AS d
    FROM   bounds
)
SELECT to_char(d, 'YYYYMMDD')::integer,
       d,
       extract(year    FROM d)::integer,
       extract(quarter FROM d)::integer,
       to_char(d, 'YYYY') || ' Q' || extract(quarter FROM d)::integer,
       extract(month FROM d)::integer,
       trim(to_char(d, 'Month')),
       to_char(d, 'Mon'),
       to_char(d, 'YYYYMM')::integer,
       to_char(d, 'Mon YYYY'),
       extract(day FROM d)::integer,
       extract(isodow FROM d)::integer,
       trim(to_char(d, 'Day')),
       to_char(d, 'Dy'),
       extract(doy FROM d)::integer,
       extract(isoyear FROM d)::integer,
       extract(week    FROM d)::integer,
       to_char(d, 'IYYY-"W"IW'),
       extract(isodow FROM d) >= 6,
       date_trunc('month', d)::date,
       (date_trunc('month', d) + INTERVAL '1 month - 1 day')::date,
       fy.fy,
       (fy.fy - 1) || '/' || right(fy.fy::text, 2),
       fq.fq,
       (fy.fy - 1) || '/' || right(fy.fy::text, 2) || ' Q' || fq.fq
FROM   days
CROSS  JOIN LATERAL (
    SELECT CASE WHEN extract(month FROM d) >= 7
                THEN extract(year FROM d)::integer + 1
                ELSE extract(year FROM d)::integer END AS fy) fy
CROSS  JOIN LATERAL (
    SELECT ((extract(month FROM d)::integer + 5) % 12) / 3 + 1 AS fq) fq
ON CONFLICT (date_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- rep.dim_time
-- ---------------------------------------------------------------------------
-- One row per minute of the day: 1,440 rows, fixed. time_key is HHMM as an
-- integer, so 14:35 is 1435 and the natural sort is chronological.
--
-- day_period is a reporting band, not an operational one. The boundaries below
-- are an assumption and should be confirmed with the business owner:
--   Overnight 00:00-05:59, Morning 06:00-11:59,
--   Afternoon 12:00-17:59, Evening 18:00-23:59.
--
-- shift is deliberately left NULL. It is reserved for the actual patrol shift
-- structure, which is not yet documented; populating it with a guess would be
-- worse than leaving it visibly empty.
CREATE TABLE IF NOT EXISTS rep.dim_time (
    time_key        integer PRIMARY KEY,       -- HHMM, -1 = Unknown
    time_of_day     time    UNIQUE,            -- NULL on the sentinel only
    hour            integer NOT NULL,
    minute          integer NOT NULL,
    hour_label      text    NOT NULL,          -- 14:00
    hour_12         integer NOT NULL,
    am_pm           text    NOT NULL,
    time_label      text    NOT NULL,          -- 2:35 PM
    day_period      text    NOT NULL,
    shift           text,                      -- reserved, see above
    CONSTRAINT dim_time_sentinel_ck CHECK ((time_key = -1) = (time_of_day IS NULL))
);

ALTER TABLE rep.dim_time ALTER COLUMN time_of_day DROP NOT NULL;
-- Dropped and re-added rather than skipped when present, so a table built by
-- an earlier version of this file is corrected rather than left as it was.
ALTER TABLE rep.dim_time DROP CONSTRAINT IF EXISTS dim_time_sentinel_ck;
ALTER TABLE rep.dim_time ADD  CONSTRAINT dim_time_sentinel_ck CHECK ((time_key = -1) = (time_of_day IS NULL));

INSERT INTO rep.dim_time VALUES
    (-1, NULL, -1, -1, 'Unknown', -1, 'Unknown', 'Unknown', 'Unknown', NULL)
ON CONFLICT (time_key) DO NOTHING;

INSERT INTO rep.dim_time
SELECT to_char(t, 'HH24MI')::integer,
       t::time,
       extract(hour   FROM t)::integer,
       extract(minute FROM t)::integer,
       to_char(t, 'HH24:00'),
       extract(hour FROM t)::integer % 12 + CASE WHEN extract(hour FROM t)::integer % 12 = 0 THEN 12 ELSE 0 END,
       to_char(t, 'AM'),
       to_char(t, 'FMHH12:MI AM'),
       CASE WHEN extract(hour FROM t) < 6  THEN 'Overnight'
            WHEN extract(hour FROM t) < 12 THEN 'Morning'
            WHEN extract(hour FROM t) < 18 THEN 'Afternoon'
            ELSE                                'Evening' END,
       NULL
FROM   generate_series(TIMESTAMP '2000-01-01 00:00',
                       TIMESTAMP '2000-01-01 23:59',
                       INTERVAL '1 minute') AS t
ON CONFLICT (time_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Key resolution
-- ---------------------------------------------------------------------------
-- Every transform resolves a date or a time to a key through these, so the
-- rule for a missing or out-of-range value lives in one place rather than
-- being repeated - and differently - in each fact.
--
-- A lookup, not arithmetic. to_char(d,'YYYYMMDD')::integer would happily
-- produce 19850712 for a mis-keyed date of birth, pointing at a row that does
-- not exist; the lookup returns -1 instead, and the foreign keys below make
-- that the only possible outcome.
--
-- STABLE, not IMMUTABLE: the answer depends on the rows in the dimension,
-- which change when the range is extended.
CREATE OR REPLACE FUNCTION rep.date_key(p_date date) RETURNS integer
LANGUAGE sql STABLE AS $$
    SELECT coalesce((SELECT d.date_key FROM rep.dim_date d WHERE d.date = p_date), -1);
$$;

CREATE OR REPLACE FUNCTION rep.time_key(p_time time) RETURNS integer
LANGUAGE sql STABLE AS $$
    -- Seconds are discarded: the dimension is one row per minute.
    SELECT coalesce((SELECT t.time_key FROM rep.dim_time t
                     WHERE t.time_of_day = date_trunc('minute', p_time)::time), -1);
$$;

-- Referential integrity, declared here because the facts in 07 are created
-- before the dimensions exist. Guarded so the file stays re-runnable, and
-- skipped if a fact table has not been created yet.
DO $$
DECLARE
    fk record;
BEGIN
    FOR fk IN
        SELECT * FROM (VALUES
            ('rep.fact_incident',        'date_occurred_key',   'dim_date'),
            ('rep.fact_incident',        'date_reported_key',   'dim_date'),
            ('rep.fact_incident',        'time_occurred_key',   'dim_time'),
            ('rep.fact_incident',        'time_received_key',   'dim_time'),
            ('rep.fact_incident',        'time_dispatched_key', 'dim_time'),
            ('rep.fact_incident_charge', 'disp_date_key',       'dim_date')
        ) AS v(tbl, col, dim)
    LOOP
        CONTINUE WHEN to_regclass(fk.tbl) IS NULL;
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM information_schema.columns
                                  WHERE table_schema = 'rep'
                                    AND table_name = split_part(fk.tbl, '.', 2)
                                    AND column_name = fk.col);
        CONTINUE WHEN EXISTS (SELECT 1 FROM pg_constraint
                              WHERE conname = split_part(fk.tbl, '.', 2) || '_' || fk.col || '_fk');
        EXECUTE format('ALTER TABLE %s ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES rep.%I(%s)',
                       fk.tbl,
                       split_part(fk.tbl, '.', 2) || '_' || fk.col || '_fk',
                       fk.col, fk.dim,
                       CASE fk.dim WHEN 'dim_date' THEN 'date_key' ELSE 'time_key' END);
        RAISE NOTICE 'added foreign key on %.%', fk.tbl, fk.col;
    END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- Coverage
-- ---------------------------------------------------------------------------
-- A generated dimension expires quietly: the facts keep arriving, the join
-- finds nothing, and the report shows blanks rather than an error. This view
-- makes the end of the range visible before it is reached. It reports both
-- ends: an incident older than dim_from is just as unjoinable as one beyond
-- dim_to, and back-dated records make that the likelier of the two. Check it
-- with the other operational views; act when months_remaining gets short or
-- unjoined_incidents is not zero.
-- Dropped and recreated rather than CREATE OR REPLACE: replacing a view
-- cannot rename or reorder its columns, so a later change to what this
-- reports would fail on a re-run. The grant below puts the privileges back.
DROP VIEW IF EXISTS rep.v_dim_coverage;
CREATE VIEW rep.v_dim_coverage AS
SELECT (SELECT min(date) FROM rep.dim_date)                AS dim_from,
       (SELECT max(date) FROM rep.dim_date)                AS dim_to,
       f.earliest_incident,
       f.latest_incident,
       f.earliest_incident < (SELECT min(date) FROM rep.dim_date) AS facts_before_dim,
       f.latest_incident   > (SELECT max(date) FROM rep.dim_date) AS facts_beyond_dim,
       f.dates_out_of_range,
       f.dates_missing,
       round(((SELECT max(date) FROM rep.dim_date) - current_date) / 30.44, 1)
                                                           AS months_remaining
FROM  (SELECT min(date_occurred) AS earliest_incident,
              max(date_occurred) AS latest_incident,
              count(*) FILTER (WHERE date_occurred_key = -1
                               AND date_occurred IS NOT NULL) AS dates_out_of_range,
              count(*) FILTER (WHERE date_occurred IS NULL)   AS dates_missing
       FROM   rep.fact_incident i) f;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rpt_reader') THEN
        EXECUTE 'GRANT SELECT ON rep.dim_date, rep.dim_time, rep.v_dim_coverage TO rpt_reader';
        EXECUTE 'GRANT EXECUTE ON FUNCTION rep.date_key(date), rep.time_key(time) TO rpt_reader';
    END IF;
END $$;

RESET ROLE;
