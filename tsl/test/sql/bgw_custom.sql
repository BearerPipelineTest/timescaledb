-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

CREATE TABLE custom_log(job_id int, args jsonb, extra text, runner NAME DEFAULT CURRENT_ROLE);

CREATE OR REPLACE FUNCTION custom_func(jobid int, args jsonb) RETURNS VOID LANGUAGE SQL AS
$$
  INSERT INTO custom_log VALUES($1, $2, 'custom_func');
$$;

CREATE OR REPLACE FUNCTION custom_func_definer(jobid int, args jsonb) RETURNS VOID LANGUAGE SQL AS
$$
  INSERT INTO custom_log VALUES($1, $2, 'security definer');
$$ SECURITY DEFINER;

CREATE OR REPLACE PROCEDURE custom_proc(job_id int, args jsonb) LANGUAGE SQL AS
$$
  INSERT INTO custom_log VALUES($1, $2, 'custom_proc');
$$;

-- procedure with transaction handling
CREATE OR REPLACE PROCEDURE custom_proc2(job_id int, args jsonb) LANGUAGE PLPGSQL AS
$$
BEGIN
  INSERT INTO custom_log VALUES($1, $2, 'custom_proc 1 COMMIT');
  COMMIT;
  INSERT INTO custom_log VALUES($1, $2, 'custom_proc 2 ROLLBACK');
  ROLLBACK;
  INSERT INTO custom_log VALUES($1, $2, 'custom_proc 3 COMMIT');
  COMMIT;
END
$$;

\set ON_ERROR_STOP 0
-- test bad input
SELECT add_job(NULL, '1h');
SELECT add_job(0, '1h');
-- this will return an error about Oid 4294967295
-- while regproc is unsigned int postgres has an implicit cast from int to regproc
SELECT add_job(-1, '1h');
SELECT add_job('invalid_func', '1h');
SELECT add_job('custom_func', NULL);
SELECT add_job('custom_func', 'invalid interval');
\set ON_ERROR_STOP 1

SELECT add_job('custom_func','1h', config:='{"type":"function"}'::jsonb);
SELECT add_job('custom_proc','1h', config:='{"type":"procedure"}'::jsonb);
SELECT add_job('custom_proc2','1h', config:= '{"type":"procedure"}'::jsonb);

SELECT add_job('custom_func', '1h', config:='{"type":"function"}'::jsonb);
SELECT add_job('custom_func_definer', '1h', config:='{"type":"function"}'::jsonb);

SELECT * FROM timescaledb_information.jobs WHERE job_id != 1 ORDER BY 1;

SELECT count(*) FROM _timescaledb_config.bgw_job WHERE config->>'type' IN ('procedure', 'function');

\set ON_ERROR_STOP 0
-- test bad input
CALL run_job(NULL);
CALL run_job(-1);
\set ON_ERROR_STOP 1

CALL run_job(1000);
CALL run_job(1001);
CALL run_job(1002);
CALL run_job(1003);
CALL run_job(1004);

SELECT * FROM custom_log ORDER BY job_id, extra;

\set ON_ERROR_STOP 0
-- test bad input
SELECT delete_job(NULL);
SELECT delete_job(-1);
\set ON_ERROR_STOP 1

-- We keep job 1000 for some additional checks.
SELECT delete_job(1001);
SELECT delete_job(1002);
SELECT delete_job(1003);
SELECT delete_job(1004);

-- check jobs got removed
SELECT count(*) FROM timescaledb_information.jobs WHERE job_id >= 1001;

\c :TEST_DBNAME :ROLE_SUPERUSER

\set ON_ERROR_STOP 0
-- test bad input
SELECT alter_job(NULL, if_exists => false);
SELECT alter_job(-1, if_exists => false);
\set ON_ERROR_STOP 1
-- test bad input but don't fail
SELECT alter_job(NULL, if_exists => true);
SELECT alter_job(-1, if_exists => true);

-- test altering job with NULL config
SELECT job_id FROM alter_job(1000,scheduled:=false);
SELECT scheduled, config FROM timescaledb_information.jobs WHERE job_id = 1000;

-- test updating job settings
SELECT job_id FROM alter_job(1000,config:='{"test":"test"}');
SELECT scheduled, config FROM timescaledb_information.jobs WHERE job_id = 1000;
SELECT job_id FROM alter_job(1000,scheduled:=true);
SELECT scheduled, config FROM timescaledb_information.jobs WHERE job_id = 1000;
SELECT job_id FROM alter_job(1000,scheduled:=false);
SELECT scheduled, config FROM timescaledb_information.jobs WHERE job_id = 1000;

-- Done with job 1000 now, so remove it.
SELECT delete_job(1000);

--test for #2793
\c :TEST_DBNAME :ROLE_DEFAULT_PERM_USER
-- background workers are disabled, so the job will not run --
SELECT add_job( proc=>'custom_func',
     schedule_interval=>'1h', initial_start =>'2018-01-01 10:00:00-05');

SELECT job_id, next_start, scheduled, schedule_interval
FROM timescaledb_information.jobs WHERE job_id > 1000;
\x
SELECT * FROM timescaledb_information.job_stats WHERE job_id > 1000;
\x

-- tests for #3545
CREATE FUNCTION wait_for_job_to_run(job_param_id INTEGER, expected_runs INTEGER, spins INTEGER=:TEST_SPINWAIT_ITERS) RETURNS BOOLEAN LANGUAGE PLPGSQL AS
$BODY$
DECLARE
    r RECORD;
BEGIN
    FOR i in 1..spins
    LOOP
    SELECT total_successes, total_failures FROM _timescaledb_internal.bgw_job_stat WHERE job_id=job_param_id INTO r;
    IF (r.total_failures > 0) THEN
        RAISE INFO 'wait_for_job_to_run: job execution failed';
        RETURN false;
    ELSEIF (r.total_successes = expected_runs) THEN
        RETURN true;
    ELSEIF (r.total_successes > expected_runs) THEN
        RAISE 'num_runs > expected';
    ELSE
        PERFORM pg_sleep(0.1);
    END IF;
    END LOOP;
    RAISE INFO 'wait_for_job_to_run: timeout after % tries', spins;
    RETURN false;
END
$BODY$;

TRUNCATE custom_log;

-- Nested procedure call
CREATE OR REPLACE PROCEDURE custom_proc_nested(job_id int, args jsonb) LANGUAGE PLPGSQL AS
$$
BEGIN
  INSERT INTO custom_log VALUES($1, $2, 'custom_proc_nested 1 COMMIT');
  COMMIT;
  INSERT INTO custom_log VALUES($1, $2, 'custom_proc_nested 2 ROLLBACK');
  ROLLBACK;
  INSERT INTO custom_log VALUES($1, $2, 'custom_proc_nested 3 COMMIT');
  COMMIT;
END
$$;

CREATE OR REPLACE PROCEDURE custom_proc3(job_id int, args jsonb) LANGUAGE PLPGSQL AS
$$
BEGIN
    CALL custom_proc_nested(job_id, args);
END
$$;

CREATE OR REPLACE PROCEDURE custom_proc4(job_id int, args jsonb) LANGUAGE PLPGSQL AS
$$
BEGIN
    INSERT INTO custom_log VALUES($1, $2, 'custom_proc4 1 COMMIT');
    COMMIT;
    INSERT INTO custom_log VALUES($1, $2, 'custom_proc4 2 ROLLBACK');
    ROLLBACK;
    RAISE EXCEPTION 'forced exception';
    INSERT INTO custom_log VALUES($1, $2, 'custom_proc4 3 ABORT');
    COMMIT;
END
$$;

CREATE OR REPLACE PROCEDURE custom_proc5(job_id int, args jsonb) LANGUAGE PLPGSQL AS
$$
BEGIN
    CALL refresh_continuous_aggregate('conditions_summary_daily', '2021-08-01 00:00', '2021-08-31 00:00');
END
$$;

-- Remove any default jobs, e.g., telemetry
\c :TEST_DBNAME :ROLE_SUPERUSER
TRUNCATE _timescaledb_config.bgw_job RESTART IDENTITY CASCADE;

\c :TEST_DBNAME :ROLE_DEFAULT_PERM_USER

SELECT add_job('custom_proc2', '1h', config := '{"type":"procedure"}'::jsonb, initial_start := now()) AS job_id_1 \gset
SELECT add_job('custom_proc3', '1h', config := '{"type":"procedure"}'::jsonb, initial_start := now()) AS job_id_2 \gset

\c :TEST_DBNAME :ROLE_SUPERUSER
-- Start Background Workers
SELECT _timescaledb_internal.start_background_workers();

-- Wait for jobs
SELECT wait_for_job_to_run(:job_id_1, 1);
SELECT wait_for_job_to_run(:job_id_2, 1);

-- Check results
SELECT * FROM custom_log ORDER BY job_id, extra;

-- Delete previous jobs
SELECT delete_job(:job_id_1);
SELECT delete_job(:job_id_2);
TRUNCATE custom_log;

-- Forced Exception
SELECT add_job('custom_proc4', '1h', config := '{"type":"procedure"}'::jsonb, initial_start := now()) AS job_id_3 \gset
SELECT wait_for_job_to_run(:job_id_3, 1);

-- Check results
SELECT * FROM custom_log ORDER BY job_id, extra;

-- Delete previous jobs
SELECT delete_job(:job_id_3);

CREATE TABLE conditions (
  time TIMESTAMP NOT NULL,
  location TEXT NOT NULL,
  location2 char(10) NOT NULL,
  temperature DOUBLE PRECISION NULL,
  humidity DOUBLE PRECISION NULL
) WITH (autovacuum_enabled = FALSE);

SELECT create_hypertable('conditions', 'time', chunk_time_interval := '15 days'::interval);

ALTER TABLE conditions
  SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'location',
    timescaledb.compress_orderby = 'time'
);
INSERT INTO conditions
SELECT generate_series('2021-08-01 00:00'::timestamp, '2021-08-31 00:00'::timestamp, '1 day'), 'POR', 'klick', 55, 75;

-- Chunk compress stats
SELECT * FROM _timescaledb_internal.compressed_chunk_stats ORDER BY chunk_name;

-- Compression policy
SELECT add_compression_policy('conditions', interval '1 day') AS job_id_4 \gset
SELECT wait_for_job_to_run(:job_id_4, 1);

-- Chunk compress stats
SELECT * FROM _timescaledb_internal.compressed_chunk_stats ORDER BY chunk_name;

--TEST compression job after inserting data into previously compressed chunk
INSERT INTO conditions
SELECT generate_series('2021-08-01 00:00'::timestamp, '2021-08-31 00:00'::timestamp, '1 day'), 'NYC', 'nycity', 40, 40;

SELECT id, table_name, status from _timescaledb_catalog.chunk 
where hypertable_id = (select id from _timescaledb_catalog.hypertable 
                       where table_name = 'conditions')
order by id; 

--running job second time, wait for it to complete 
select t.schedule_interval FROM alter_job(:job_id_4, next_start=> now() ) t;
SELECT wait_for_job_to_run(:job_id_4, 2);

SELECT id, table_name, status from _timescaledb_catalog.chunk 
where hypertable_id = (select id from _timescaledb_catalog.hypertable 
                       where table_name = 'conditions')
order by id; 


-- Decompress chunks before create the cagg
SELECT decompress_chunk(c) FROM show_chunks('conditions') c;

-- TEST Continuous Aggregate job
CREATE MATERIALIZED VIEW conditions_summary_daily
WITH (timescaledb.continuous) AS
SELECT location,
   time_bucket(INTERVAL '1 day', time) AS bucket,
   AVG(temperature),
   MAX(temperature),
   MIN(temperature)
FROM conditions
GROUP BY location, bucket
WITH NO DATA;

-- Refresh Continous Aggregate by Job
SELECT add_job('custom_proc5', '1h', config := '{"type":"procedure"}'::jsonb, initial_start := now()) AS job_id_5 \gset
SELECT wait_for_job_to_run(:job_id_5, 1);
SELECT count(*) FROM conditions_summary_daily;

-- TESTs for alter_job_set_hypertable_id API

SELECT _timescaledb_internal.alter_job_set_hypertable_id( :job_id_5, NULL);
SELECT id, proc_name, hypertable_id 
FROM _timescaledb_config.bgw_job WHERE id = :job_id_5;

-- error case, try to associate with a PG relation
\set ON_ERROR_STOP 0
SELECT _timescaledb_internal.alter_job_set_hypertable_id( :job_id_5, 'custom_log');
\set ON_ERROR_STOP 1

-- TEST associate the cagg with the job
SELECT _timescaledb_internal.alter_job_set_hypertable_id( :job_id_5, 'conditions_summary_daily'::regclass);

SELECT id, proc_name, hypertable_id 
FROM _timescaledb_config.bgw_job WHERE id = :job_id_5;

--verify that job is dropped when cagg is dropped
DROP MATERIALIZED VIEW conditions_summary_daily;

SELECT id, proc_name, hypertable_id 
FROM _timescaledb_config.bgw_job WHERE id = :job_id_5;

-- Stop Background Workers
SELECT _timescaledb_internal.stop_background_workers();

SELECT _timescaledb_internal.restart_background_workers();

\set ON_ERROR_STOP 0
-- add test for custom jobs with custom check functions
-- create the functions/procedures to be used as checking functions
CREATE OR REPLACE PROCEDURE test_config_check_proc(config jsonb)
LANGUAGE PLPGSQL
AS $$
DECLARE
  drop_after interval;
BEGIN 
    SELECT jsonb_object_field_text (config, 'drop_after')::interval INTO STRICT drop_after;
    IF drop_after IS NULL THEN 
        RAISE EXCEPTION 'Config must be not NULL and have drop_after';
    END IF ;
END
$$;

CREATE OR REPLACE FUNCTION test_config_check_func(config jsonb) RETURNS VOID
AS $$
DECLARE
  drop_after interval;
BEGIN 
    IF config IS NULL THEN
        RETURN;
    END IF;
    SELECT jsonb_object_field_text (config, 'drop_after')::interval INTO STRICT drop_after;
    IF drop_after IS NULL THEN 
        RAISE EXCEPTION 'Config can be NULL but must have drop_after if not';
    END IF ;
END
$$ LANGUAGE PLPGSQL;

-- step 2, create a procedure to run as a custom job
CREATE OR REPLACE PROCEDURE test_proc_with_check(job_id int, config jsonb)
LANGUAGE PLPGSQL
AS $$
BEGIN
  RAISE NOTICE 'Will only print this if config passes checks, my config is %', config; 
END
$$;

-- step 3, add the job with the config check function passed as argument
-- test procedures
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_config_check_proc'::regproc);
select add_job('test_proc_with_check', '5 secs', config => NULL, check_config => 'test_config_check_proc'::regproc);
select add_job('test_proc_with_check', '5 secs', config => '{"drop_after": "chicken"}', check_config => 'test_config_check_proc'::regproc);
select add_job('test_proc_with_check', '5 secs', config => '{"drop_after": "2 weeks"}', check_config => 'test_config_check_proc'::regproc)
as job_with_proc_check_id \gset

-- test functions
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_config_check_func'::regproc);
select add_job('test_proc_with_check', '5 secs', config => NULL, check_config => 'test_config_check_func'::regproc);
select add_job('test_proc_with_check', '5 secs', config => '{"drop_after": "chicken"}', check_config => 'test_config_check_func'::regproc);
select add_job('test_proc_with_check', '5 secs', config => '{"drop_after": "2 weeks"}', check_config => 'test_config_check_func'::regproc) 
as job_with_func_check_id \gset


--- test alter_job
select alter_job(:job_with_func_check_id, config => '{"drop_after":"chicken"}');
select alter_job(:job_with_func_check_id, config => '{"drop_after":"5 years"}');

select alter_job(:job_with_proc_check_id, config => '{"drop_after":"4 days"}');


-- test that jobs with an incorrect check function signature will not be registered
-- these are all incorrect function signatures 

CREATE OR REPLACE FUNCTION test_config_check_func_0args() RETURNS VOID
AS $$
BEGIN 
    RAISE NOTICE 'I take no arguments and will validate anything you give me!';
END
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION test_config_check_func_2args(config jsonb, intarg int) RETURNS VOID
AS $$
BEGIN 
    RAISE NOTICE 'I take two arguments (jsonb, int) and I should fail to run!';
END
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION test_config_check_func_intarg(config int) RETURNS VOID
AS $$
BEGIN 
    RAISE NOTICE 'I take one argument which is an integer and I should fail to run!';
END
$$ LANGUAGE PLPGSQL;

-- -- this should fail, it has an incorrect check function 
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_config_check_func_0args'::regproc);
-- -- so should this
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_config_check_func_2args'::regproc);
-- and this
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_config_check_func_intarg'::regproc);
-- and this fails as it calls a nonexistent function
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_nonexistent_check_func'::regproc);

-- when called with a valid check function and a NULL config no check should occur
CREATE OR REPLACE FUNCTION test_config_check_func(config jsonb) RETURNS VOID
AS $$
BEGIN 
    RAISE NOTICE 'This message will get printed for both NULL and not NULL config';
END
$$ LANGUAGE PLPGSQL;

SET client_min_messages = NOTICE;
-- check done for both NULL and non-NULL config
select add_job('test_proc_with_check', '5 secs', config => NULL, check_config => 'test_config_check_func'::regproc);
-- check done
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_config_check_func'::regproc) as job_id \gset

-- check function not returning void
CREATE OR REPLACE FUNCTION test_config_check_func_returns_int(config jsonb) RETURNS INT
AS $$
BEGIN 
    raise notice 'I print a message, and then I return least(1,2)';
    RETURN LEAST(1, 2);
END
$$ LANGUAGE PLPGSQL;
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_config_check_func_returns_int'::regproc) as job_id_int \gset

-- drop the registered check function, verify that alter_job will work and print a warning that 
-- the check is being skipped due to the check function missing
ALTER FUNCTION test_config_check_func RENAME TO renamed_func;
select alter_job(:job_id, schedule_interval => '1 hour');
DROP FUNCTION test_config_check_func_returns_int;
select alter_job(:job_id_int, config => '{"field":"value"}');

-- rename the check function and then call alter_job to register the new name
select alter_job(:job_id, check_config => 'renamed_func'::regproc);
-- run alter again, should get a config check
select alter_job(:job_id, config => '{}');
-- do not drop the current check function but register a new one
CREATE OR REPLACE FUNCTION substitute_check_func(config jsonb) RETURNS VOID
AS $$
BEGIN 
    RAISE NOTICE 'This message is a substitute of the previously printed one';
END
$$ LANGUAGE PLPGSQL;
-- register the new check
select alter_job(:job_id, check_config => 'substitute_check_func');
select alter_job(:job_id, config => '{}');

RESET client_min_messages;

-- test an oid that doesn't exist
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 17424217::regproc);

\c :TEST_DBNAME :ROLE_SUPERUSER
-- test a function with insufficient privileges
create schema test_schema;
create role user_noexec with login;
grant usage on schema test_schema to user_noexec;

CREATE OR REPLACE FUNCTION test_schema.test_config_check_func_privileges(config jsonb) RETURNS VOID
AS $$
BEGIN 
    RAISE NOTICE 'This message will only get printed if privileges suffice';
END
$$ LANGUAGE PLPGSQL;

revoke execute on function test_schema.test_config_check_func_privileges from public;
-- verify the user doesn't have execute permissions on the function
select has_function_privilege('user_noexec', 'test_schema.test_config_check_func_privileges(jsonb)', 'execute');

\c :TEST_DBNAME user_noexec
-- user_noexec should not have exec permissions on this function
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'test_schema.test_config_check_func_privileges'::regproc);

\c :TEST_DBNAME :ROLE_SUPERUSER

-- check that alter_job rejects a check function with invalid signature
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'renamed_func') as job_id_alter \gset
select alter_job(:job_id_alter, check_config => 'test_config_check_func_0args');
select alter_job(:job_id_alter);
-- test that we can unregister the check function
select alter_job(:job_id_alter, check_config => 0);
-- no message printed now
select alter_job(:job_id_alter, config => '{}'); 

-- test what happens if the check function contains a COMMIT
-- procedure with transaction handling
CREATE OR REPLACE PROCEDURE custom_proc2_jsonb(config jsonb) LANGUAGE PLPGSQL AS
$$
BEGIN
--   RAISE NOTICE 'Starting some transactions inside procedure';
  INSERT INTO custom_log VALUES(1, $1, 'custom_proc 1 COMMIT');
  COMMIT;
END
$$;

select add_job('test_proc_with_check', '5 secs', config => '{}') as job_id_err \gset
select alter_job(:job_id_err, check_config => 'custom_proc2_jsonb');
select alter_job(:job_id_err, schedule_interval => '3 minutes');
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'custom_proc2_jsonb') as job_id_commit \gset

-- test the case where we have a background job that registers jobs with a check fn
CREATE OR REPLACE PROCEDURE add_scheduled_jobs_with_check(job_id int, config jsonb) LANGUAGE PLPGSQL AS 
$$
BEGIN
    perform add_job('test_proc_with_check', schedule_interval => '10 secs', config => '{}', check_config => 'renamed_func');
END
$$;

select add_job('add_scheduled_jobs_with_check', schedule_interval => '1 hour') as last_job_id \gset
-- wait for enough time
SELECT wait_for_job_to_run(:last_job_id, 1);
select total_runs, total_successes, last_run_status from timescaledb_information.job_stats where job_id = :last_job_id;

-- test coverage for alter_job
-- registering an invalid oid
select alter_job(:job_id_alter, check_config => 123456789::regproc);
-- registering a function with insufficient privileges
\c :TEST_DBNAME user_noexec
select * from add_job('test_proc_with_check', '5 secs', config => '{}') as job_id_owner \gset
select * from alter_job(:job_id_owner, check_config => 'test_schema.test_config_check_func_privileges'::regproc);

\c :TEST_DBNAME :ROLE_SUPERUSER
DROP SCHEMA test_schema CASCADE;
DROP ROLE user_noexec;

-- test with aggregate check proc
create function jsonb_add (j1 jsonb, j2 jsonb) returns jsonb
AS $$
BEGIN 
    RETURN j1 || j2;
END
$$ LANGUAGE PLPGSQL;

create table jsonb_values (j jsonb, i int);
insert into jsonb_values values ('{"refresh_after":"2 weeks"}', 1), ('{"compress_after":"2 weeks"}', 2), ('{"drop_after":"2 weeks"}', 3);

CREATE AGGREGATE sum_jsb (jsonb)
(
    sfunc = jsonb_add,
    stype = jsonb,
    initcond = '{}'
);

-- for test coverage, check unsupported aggregate type
select add_job('test_proc_with_check', '5 secs', config => '{}', check_config => 'sum_jsb'::regproc);


