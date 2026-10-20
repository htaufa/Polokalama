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
-- TRUNCATE. Emptying it is an administrative act, done by hand, and the
-- extractor then reloads it in full because no watermark floor exists.
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
-- Tables are now seeded from dsc. The script seed_from_dsc.sql generates a 
-- SQL script to reduce the scope of the staging to consider only non-blank
-- cols and also generates a consistent json config for extraction. The
-- generated SQL script must be run as a once-off in a standalone script.
--
-- ---------------------------------------------------------------------------
-- Required per-table indexes
-- ---------------------------------------------------------------------------
-- Note there is deliberately NO index on the watermark column. An expression
-- index on (modification_date_timestamp::timestamp) cannot be created at all:
-- casting text to timestamp is STABLE, not IMMUTABLE, because it depends on
-- DateStyle, and PostgreSQL refuses stable functions in index expressions.
-- Marking a wrapper IMMUTABLE to get around that would silently corrupt the
-- index if the setting ever changed.
--
-- The extractor therefore reads its floor from elt.extract_watermark, a
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
-- And the upsert into rep needs the natural key to be unique, which is worth
-- asserting here rather than assuming:
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
-- Written by the transformation when a guarded cast returns NULL. run_id is
-- defaulted from a session variable the extractor sets before invoking the
-- transform, so exceptions are attributable to a run without filtering a
-- growing table by timestamp. The 'true' argument makes current_setting
-- return NULL rather than error when it is unset, so ad-hoc calls still work.

CREATE TABLE IF NOT EXISTS stg.parse_errors (
    error_id      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id        BIGINT DEFAULT NULLIF(current_setting('elt.run_id', true), '')::BIGINT,
    source_table  TEXT NOT NULL,
    source_column TEXT NOT NULL,
    raw_value     TEXT,
    error_type    TEXT NOT NULL,
    logged_at     TIMESTAMP NOT NULL DEFAULT clock_timestamp()
);

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

RESET ROLE;
