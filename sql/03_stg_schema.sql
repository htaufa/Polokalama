-- ---------------------------------------------------------------------------
-- 03  stg - staging
-- ---------------------------------------------------------------------------
-- Source data as extracted. Every column is text, deliberately: FileMaker
-- permits values PostgreSQL does not - a Time field may hold more than 24
-- hours - and a typed staging column would turn one bad value into a failed
-- load. Typing happens on the way into rep, where a failure costs one field
-- and is logged.
--
-- stg holds history and is append-only in normal running. It is never granted
-- TRUNCATE. Emptying it is an administrative act, and the extractor then
-- reloads it in full because no watermark floor exists.
-- ---------------------------------------------------------------------------

-- Everything below is created as pp_owner, so that ownership is consistent and
-- ALTER DEFAULT PRIVILEGES below applies to it. Default privileges attach to a
-- granting role, not to a schema: declared while running as someone else, they
-- silently do not cover tables pp_owner creates - which shows up months later
-- as a new table with no grants on it.
SET ROLE pp_owner;

CREATE SCHEMA IF NOT EXISTS stg;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
-- Tables are seeded from dsc. The script seed_from_dsc.sql generates a SQL
-- script to reduce the scope of the staging to consider only non-blank cols
-- and generates a consistent json config for extraction. The generated SQL
-- script must be run as a once-off in a standalone script.
--
-- ---------------------------------------------------------------------------
-- Required per-table indexes
-- ---------------------------------------------------------------------------
-- Note there is NO index on the watermark column. An expression index on 
-- (modification_date_timestamp::timestamp) cannot be created at all: casting
-- text to timestamp is STABLE, not IMMUTABLE, because it depends on DateStyle,
-- and PostgreSQL refuses stable functions in index expressions.
-- Marking a wrapper IMMUTABLE to get around that would silently corrupt the
-- index if the setting ever changed.
--
-- The extractor reads its floor from elt.extract_watermark, a
-- one-row-per-table lookup, rather than scanning this table. See 04.
--
-- The transform reads by loaded_at, so that wants a plain index:
--
   CREATE INDEX IF NOT EXISTS ix_stg_pp_loaded_at ON stg.pp (loaded_at);
   CREATE INDEX IF NOT EXISTS ix_stg_arr_loaded_at ON stg.arr (loaded_at);
   CREATE INDEX IF NOT EXISTS ix_stg_charges_loaded_at ON stg.charges (loaded_at);
   CREATE INDEX IF NOT EXISTS ix_stg_law_loaded_at ON stg.law (loaded_at);
   CREATE INDEX IF NOT EXISTS ix_stg_cont_loaded_at ON stg.cont (loaded_at);
   CREATE INDEX IF NOT EXISTS ix_stg_names_loaded_at ON stg.names (loaded_at);
--
-- And the upsert into rep needs the key to be unique:
--
CREATE UNIQUE INDEX IF NOT EXISTS ux_stg_pp_key_loaded
    ON stg.pp ("__pkeypolicepro_id", loaded_at);

CREATE UNIQUE INDEX IF NOT EXISTS ux_stg_arr_key_loaded
	ON stg.arr ("__pkeyarrest_id", loaded_at);

CREATE UNIQUE INDEX IF NOT EXISTS ux_stg_charges_key_loaded
	ON stg.charges ("__pkeycharge_id",loaded_at);

CREATE UNIQUE INDEX IF NOT EXISTS ux_stg_law_key_loaded
	ON stg.law ("__pkey_law_id", loaded_at);

CREATE UNIQUE INDEX IF NOT EXISTS ux_stg_cont_key_loaded
	ON stg.cont ("__pkeycontact_id", loaded_at);

CREATE UNIQUE INDEX IF NOT EXISTS ux_stg_names_key_loaded
	ON stg.names ("__pkeyname_id", loaded_at);
-- ---------------------------------------------------------------------------
-- Guarded casts
-- ---------------------------------------------------------------------------
-- Used by the transformation into rep. Each returns NULL rather than raising,
-- so a value FileMaker allowed but PostgreSQL will not accept degrades a
-- single field instead of failing a statement.
--
-- numeric, not integer: FileMaker's Number type is float-based, so every
-- numeric value arrives as a float - COUNT(*) returns 11136.0, not 11136.

CREATE OR REPLACE FUNCTION stg.try_ts(t text) RETURNS timestamp AS $$
BEGIN RETURN t::timestamp; EXCEPTION WHEN others THEN RETURN NULL; END $$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION stg.try_date(t text) RETURNS date AS $$
BEGIN RETURN t::date; EXCEPTION WHEN others THEN RETURN NULL; END $$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION stg.try_time(t text) RETURNS time AS $$
BEGIN RETURN t::time; EXCEPTION WHEN others THEN RETURN NULL; END $$
LANGUAGE plpgsql IMMUTABLE;

CREATE OR REPLACE FUNCTION stg.try_numeric(t text) RETURNS numeric AS $$
BEGIN RETURN t::numeric; EXCEPTION WHEN others THEN RETURN NULL; END $$
LANGUAGE plpgsql IMMUTABLE;

-- ---------------------------------------------------------------------------
-- Parse exceptions
-- ---------------------------------------------------------------------------
-- Written by stg.register_parse_failures, below. run_id attributes a row to
-- the run that found it; the default is set in 05, where the function that
-- resolves the current run from elt.load_run is defined. No default here, so
-- a register row inserted before 05 has been applied records no run rather
-- than a wrong one.

CREATE TABLE IF NOT EXISTS stg.parse_errors (
    error_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        BIGINT,   -- default set in 05: elt.current_run_id()
    source_table  TEXT NOT NULL,
    source_column TEXT NOT NULL,
    raw_value     TEXT,
    error_type    TEXT NOT NULL,
    logged_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

-- ---------------------------------------------------------------------------
-- Parse exception register
-- ---------------------------------------------------------------------------
-- A standing worklist, not a log. One row per record per column whose value
-- will not cast into the type the reporting layer needs, carrying the staging
-- primary key and the value itself.
--
-- Why per record rather than per distinct value. A failed cast coalesces to
-- NULL, and NULL is also what an empty source field becomes, so the reporting
-- layer cannot tell the two apart on its own. This register is what separates
-- them: a NULL in rep with a row here, for that key and column, was a value
-- that would not parse; a NULL with no row here was empty at source. That only
-- holds if every affected record is present, so the grain is the record.

ALTER TABLE stg.parse_errors
    ADD COLUMN IF NOT EXISTS pk_value text;

-- The key of the register, and what makes the insert idempotent across runs.
-- Keyless staging rows are included deliberately - a bad value is a source
-- data quality fact whether or not the record reaches rep - but they have no
-- identity, so NULLS DISTINCT (the default) gives each occurrence its own row
-- and a re-seed will register them again. There is nothing to deduplicate them
-- on; the alternative is to drop them, which hides the value entirely.
CREATE UNIQUE INDEX IF NOT EXISTS ux_stg_parse_errors_record
    ON stg.parse_errors (source_table, source_column, pk_value);

CREATE OR REPLACE PROCEDURE stg.register_parse_failures(
    p_source     text,       -- qualified staging table, e.g. 'stg.pp'
    p_key_column text,       -- primary key column, e.g. '__pkeypolicepro_id'
    p_from       timestamp,  -- exclusive floor (>), the transform's watermark
    p_to         timestamp,  -- inclusive ceiling (=<), the transform's batch_to
    p_casts      text[]      -- ARRAY[['date_occurred','date'],['counts','numeric']]
)
LANGUAGE plpgsql AS $$
DECLARE
    i      integer;
    col    text;
    kind   text;
    fn     text;
    added  integer;
    total  integer := 0;
BEGIN
    FOR i IN 1 .. coalesce(array_length(p_casts, 1), 0) LOOP
        col  := p_casts[i][1];
        kind := lower(p_casts[i][2]);
        fn   := CASE kind
                    WHEN 'timestamp' THEN 'try_ts'
                    WHEN 'date'      THEN 'try_date'
                    WHEN 'time'      THEN 'try_time'
                    WHEN 'numeric'   THEN 'try_numeric'
                END;
        IF fn IS NULL THEN
            RAISE EXCEPTION 'register_parse_failures: unknown type % for column %. '
                            'Expected one of timestamp, date, time, numeric.', kind, col;
        END IF;


        EXECUTE format(
            'INSERT INTO stg.parse_errors
                    (source_table, source_column, pk_value, raw_value, error_type)
             SELECT %1$L, %2$L, %3$I::text, %2$I::text, %4$L
             FROM   %5$s
             WHERE  ($1 IS NULL OR loaded_at >  $1)
               AND  ($2 IS NULL OR loaded_at <= $2)
               AND  nullif(btrim(%2$I::text), '''') IS NOT NULL
               AND  stg.%6$I(%2$I::text) IS NULL
             ON CONFLICT (source_table, source_column, pk_value) DO NOTHING',
            p_source, col, p_key_column, kind, p_source, fn)
        USING p_from, p_to;

        GET DIAGNOSTICS added = ROW_COUNT;
        total := total + added;
        IF added > 0 THEN
            RAISE NOTICE '% %: % record(s) registered, value will not cast to %',
                  p_source, col, added, kind;
        END IF;
    END LOOP;

    IF total > 0 THEN
        RAISE NOTICE '% : % record(s) added to the parse register', p_source, total;
    END IF;
END $$;

-- The register as an administrator reads it. Each row is one record whose value
-- coalesced to NULL in rep. Clear a row with DELETE once a rule handles the
-- value or the source has been corrected:

CREATE OR REPLACE VIEW stg.v_parse_register AS
SELECT source_table,
       source_column,
       error_type AS expected,
       raw_value,
       pk_value,
       run_id    AS registered_in_run,
       logged_at AS registered_at
FROM   stg.parse_errors
ORDER  BY source_table, source_column, raw_value, pk_value;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
-- Last in the file so that ALL TABLES covers the tables created above.
--
-- SELECT and INSERT only. No TRUNCATE, DELETE or UPDATE: the extractor reads
-- the watermark, counts rows and appends. Emptying this schema is an
-- administrative act and stays outside what the service account can do.

GRANT USAGE ON SCHEMA stg TO svc_py;
GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA stg TO svc_py;
ALTER DEFAULT PRIVILEGES FOR ROLE pp_owner IN SCHEMA stg GRANT SELECT, INSERT ON TABLES TO svc_py;

-- The guarded casts are called by the transformation, which runs as its owner,
-- but granting EXECUTE costs nothing and keeps ad-hoc use working.
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA stg TO svc_py;
-- Procedures are routines, not functions: ALL FUNCTIONS does not cover them.
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA stg TO svc_py;

RESET ROLE;
