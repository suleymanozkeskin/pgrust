--
-- A cached PL/pgSQL function must resolve unqualified names against the
-- search_path that is active at each call, not the one at compile time.
--

CREATE SCHEMA spc_a;
CREATE SCHEMA spc_b;
CREATE TABLE spc_a.t (v text);
CREATE TABLE spc_b.t (v text);
INSERT INTO spc_a.t VALUES ('a');
INSERT INTO spc_b.t VALUES ('b');

CREATE FUNCTION public.spc_read() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
    SELECT v INTO r FROM t;
    RETURN r;
END $$;

-- Path A, then B, then A again.
SET search_path = spc_a, public;
SELECT spc_read();
SELECT spc_read();
SET search_path = spc_b, public;
SELECT spc_read();
SET search_path = spc_a, public;
SELECT spc_read();

-- A temporary table shadows the permanent one when pg_temp comes first.
CREATE TEMP TABLE t (v text);
INSERT INTO t VALUES ('temp');
SET search_path = pg_temp, spc_a, public;
SELECT spc_read();
SET search_path = spc_a, pg_temp, public;
SELECT spc_read();
DROP TABLE pg_temp.t;

-- SET LOCAL inside a transaction, then rollback.
SET search_path = spc_a, public;
BEGIN;
SET LOCAL search_path = spc_b, public;
SELECT spc_read();
ROLLBACK;
SELECT spc_read();

-- "$user" resolves to a different schema after SET ROLE.
CREATE ROLE spc_user;
CREATE SCHEMA spc_user AUTHORIZATION spc_user;
CREATE TABLE spc_user.t (v text);
INSERT INTO spc_user.t VALUES ('user');
GRANT USAGE ON SCHEMA spc_a, spc_user TO spc_user;
GRANT SELECT ON spc_a.t, spc_user.t TO spc_user;
SET search_path = "$user", spc_a, public;
SELECT spc_read();
SET ROLE spc_user;
SELECT spc_read();
RESET ROLE;
SELECT spc_read();

-- A function with its own SET search_path clause ignores the caller's path.
CREATE FUNCTION public.spc_read_fixed() RETURNS text LANGUAGE plpgsql
SET search_path = spc_b, public AS $$
DECLARE r text;
BEGIN
    SELECT v INTO r FROM t;
    RETURN r;
END $$;
SET search_path = spc_a, public;
SELECT spc_read_fixed(), spc_read();
SET search_path = spc_b, public;
SELECT spc_read_fixed(), spc_read();

RESET search_path;
DROP FUNCTION public.spc_read(), public.spc_read_fixed();
DROP TABLE spc_user.t;
DROP OWNED BY spc_user;
DROP ROLE spc_user;
DROP SCHEMA spc_a, spc_b CASCADE;
