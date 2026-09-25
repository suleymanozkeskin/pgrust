--
-- Context lines of reports raised inside SQL statements run by PL/pgSQL:
-- GET DIAGNOSTICS PG_CONTEXT, notices, errors with and without a cursor
-- position, cursors, and dynamic SQL.
--

\set SHOW_CONTEXT always

CREATE TABLE pec_t (id integer PRIMARY KEY, v text);
INSERT INTO pec_t VALUES (1, 'one'), (2, 'two');

CREATE FUNCTION pec_inner() RETURNS text LANGUAGE plpgsql AS $$
DECLARE ctx text;
BEGIN
    GET DIAGNOSTICS ctx = PG_CONTEXT;
    RAISE NOTICE 'inner context: %', ctx;
    RETURN 'ok';
END $$;

CREATE FUNCTION pec_outer() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r text;
BEGIN
    -- a long statement: the context line must carry its full text
    SELECT pec_inner() || '/' || v INTO r FROM pec_t WHERE id = 1 AND v <> 'a long comparison value that makes this statement text longer than usual';
    PERFORM pec_inner();
    r := r || '/' || pec_inner();
    RETURN r;
END $$;
SELECT pec_outer();

-- Notices raised by a function called from inside a query.
CREATE FUNCTION pec_notice(p integer) RETURNS integer LANGUAGE plpgsql AS $$
BEGIN
    RAISE NOTICE 'row %', p;
    RETURN p;
END $$;
CREATE FUNCTION pec_query_notices() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    SELECT sum(pec_notice(id)) INTO n FROM pec_t;
    RETURN n;
END $$;
SELECT pec_query_notices();

-- Errors inside statements: runtime error, error with a position, and a
-- caught error followed by the same statement again.
CREATE FUNCTION pec_div(p integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    SELECT 10 / p INTO n FROM pec_t WHERE id = 1;
    RETURN n;
END $$;
SELECT pec_div(0);
SELECT pec_div(5);
CREATE FUNCTION pec_badcol() RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    SELECT no_such_column INTO n FROM pec_t;
    RETURN n;
END $$;
SELECT pec_badcol();
CREATE FUNCTION pec_caught() RETURNS text LANGUAGE plpgsql AS $$
DECLARE acc text := '';
BEGIN
    FOR i IN 0..2 LOOP
        BEGIN
            acc := acc || pec_div(i) || ' ';
        EXCEPTION WHEN division_by_zero THEN
            acc := acc || 'div0 ';
        END;
    END LOOP;
    RETURN acc;
END $$;
SELECT pec_caught();

-- Cursors and dynamic SQL.
CREATE FUNCTION pec_cursor() RETURNS text LANGUAGE plpgsql AS $$
DECLARE c refcursor; r record; acc text := '';
BEGIN
    OPEN c FOR SELECT id, 10 / (id - 2) AS q FROM pec_t ORDER BY id;
    LOOP
        FETCH c INTO r;
        EXIT WHEN NOT FOUND;
        acc := acc || r.q || ' ';
    END LOOP;
    CLOSE c;
    RETURN acc;
END $$;
SELECT pec_cursor();
CREATE FUNCTION pec_dynamic(q text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE n integer;
BEGIN
    EXECUTE q INTO n;
    RETURN n;
END $$;
SELECT pec_dynamic('SELECT count(*) FROM pec_t');
SELECT pec_dynamic('SELECT 1 / 0');
SELECT pec_dynamic('SELECT nope FROM pec_t');

DROP FUNCTION pec_outer(), pec_inner(), pec_notice(integer), pec_query_notices(),
    pec_div(integer), pec_badcol(), pec_caught(), pec_cursor(), pec_dynamic(text);
DROP TABLE pec_t;
