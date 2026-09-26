--
-- PL/pgSQL assignments and simple expressions across plan invalidation,
-- search_path changes, transaction boundaries, recursion, and errors.
--

CREATE SCHEMA pse_a;
CREATE SCHEMA pse_b;
CREATE FUNCTION pse_a.k() RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT 1';
CREATE FUNCTION pse_b.k() RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT 100';

-- An assignment that calls an unqualified function follows search_path.
CREATE FUNCTION public.pse_sum(n integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v integer := 0;
BEGIN
    FOR i IN 1..n LOOP
        v := v + k();
    END LOOP;
    RETURN v;
END $$;
SET search_path = pse_a, public;
SELECT pse_sum(3);
SET search_path = pse_b, public;
SELECT pse_sum(3);
SET search_path = pse_a, public;
SELECT pse_sum(3);

-- The called function is replaced between calls in one session.
CREATE OR REPLACE FUNCTION pse_a.k() RETURNS integer LANGUAGE sql IMMUTABLE AS 'SELECT 7';
SELECT pse_sum(3);

-- search_path changes inside the function, between two assignments.
CREATE FUNCTION public.pse_switch() RETURNS text LANGUAGE plpgsql AS $$
DECLARE x integer; y integer;
BEGIN
    x := k();
    PERFORM set_config('search_path', 'pse_b, public', true);
    y := k();
    RETURN x || ',' || y;
END $$;
BEGIN;
SELECT pse_switch();
ROLLBACK;
SHOW search_path;

-- Assignments in a procedure loop across COMMIT and ROLLBACK.
CREATE TABLE public.pse_log (i integer, v integer);
CREATE PROCEDURE public.pse_commits(n integer) LANGUAGE plpgsql AS $$
DECLARE v integer := 0;
BEGIN
    FOR i IN 1..n LOOP
        v := v * 2 + i;
        INSERT INTO pse_log VALUES (i, v);
        IF i % 2 = 0 THEN
            COMMIT;
        ELSE
            ROLLBACK;
        END IF;
        v := v + k();
    END LOOP;
END $$;
CALL pse_commits(6);
SELECT * FROM pse_log ORDER BY i;

-- Recursion: the same assignment expression is evaluated while an outer
-- evaluation of it is in progress.
CREATE FUNCTION public.pse_fib(n integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE r integer;
BEGIN
    IF n < 2 THEN
        RETURN n;
    END IF;
    r := pse_fib(n - 1) + pse_fib(n - 2);
    RETURN r;
END $$;
SELECT pse_fib(15);

-- Errors raised inside assignments, caught, then the same assignment again.
CREATE FUNCTION public.pse_errors() RETURNS text LANGUAGE plpgsql AS $$
DECLARE d integer; acc text := '';
BEGIN
    FOR i IN -2..2 LOOP
        BEGIN
            d := 10 / i;
            acc := acc || d || ' ';
        EXCEPTION WHEN division_by_zero THEN
            acc := acc || 'div0 ';
        END;
    END LOOP;
    RETURN acc;
END $$;
SELECT pse_errors();
SELECT pse_errors();

-- A variable type that needs a cast in the assignment.
CREATE FUNCTION public.pse_cast() RETURNS text LANGUAGE plpgsql AS $$
DECLARE n numeric(6,2); t varchar(3); i integer;
BEGIN
    n := 1.005;
    i := n * 3;
    t := 'abc';
    RETURN n || '|' || i || '|' || t;
END $$;
SELECT pse_cast();

RESET search_path;
DROP PROCEDURE public.pse_commits(integer);
DROP FUNCTION public.pse_sum(integer), public.pse_switch(), public.pse_fib(integer),
    public.pse_errors(), public.pse_cast();
DROP TABLE public.pse_log;
DROP SCHEMA pse_a, pse_b CASCADE;
