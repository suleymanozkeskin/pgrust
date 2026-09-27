--
-- PL/pgSQL assignment of query rows to %ROWTYPE and composite-type
-- variables: compatible rows, rows that need casts, changes of the row type
-- between and during calls, composite domains, and new sessions.
--

CREATE TABLE prs_t (id integer, name text, amount numeric(8,2));
INSERT INTO prs_t VALUES (1, 'one', 1.50), (2, NULL, 2.25), (3, 'three', NULL);

CREATE FUNCTION prs_read(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prs_t%ROWTYPE;
BEGIN
    SELECT * INTO v FROM prs_t WHERE id = p;
    RETURN format('%s|%s|%s|%s', v.id, v.name, v.amount, v IS NULL);
END $$;
SELECT prs_read(1), prs_read(2), prs_read(3), prs_read(99);

-- Whole-record RETURN and record comparison after the assignment.
CREATE FUNCTION prs_whole(p integer) RETURNS prs_t LANGUAGE plpgsql AS $$
DECLARE v prs_t;
BEGIN
    SELECT * INTO v FROM prs_t WHERE id = p;
    RETURN v;
END $$;
SELECT * FROM prs_whole(1);
SELECT prs_whole(2) = ROW(2, NULL, 2.25)::prs_t AS same;

-- Source column types that differ from the declared types (casts per field).
CREATE FUNCTION prs_cast() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prs_t;
BEGIN
    SELECT 7::bigint, 42, '3.456' INTO v;
    RETURN format('%s|%s|%s', v.id, v.name, v.amount);
END $$;
SELECT prs_cast();

-- Fewer and more source columns, with strict_multi_assignment.
CREATE FUNCTION prs_count() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prs_t;
BEGIN
    SELECT 1, 'x' INTO v;
    RETURN format('%s|%s|%s', v.id, v.name, v.amount IS NULL);
END $$;
SELECT prs_count();
SET plpgsql.extra_warnings = 'strict_multi_assignment';
SELECT prs_count();
RESET plpgsql.extra_warnings;

-- Two functions share one row type; loops assign the same variable.
CREATE FUNCTION prs_loop() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prs_t; acc text := '';
BEGIN
    FOR v IN SELECT * FROM prs_t ORDER BY id LOOP
        acc := acc || v.id || ':' || coalesce(v.name, '-') || ';';
    END LOOP;
    RETURN acc;
END $$;
SELECT prs_loop(), prs_read(1);

-- The row type changes between calls in one session.
ALTER TABLE prs_t ADD COLUMN extra text DEFAULT 'dflt';
SELECT prs_read(1), prs_loop();
CREATE OR REPLACE FUNCTION prs_read_extra(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prs_t%ROWTYPE;
BEGIN
    SELECT * INTO v FROM prs_t WHERE id = p;
    RETURN format('%s|%s|%s', v.id, v.name, v.extra);
END $$;
SELECT prs_read_extra(1);
ALTER TABLE prs_t DROP COLUMN name;
SELECT prs_read_extra(1);
SELECT * FROM prs_whole(3);
ALTER TABLE prs_t ALTER COLUMN amount TYPE numeric(10,3);
SELECT * FROM prs_whole(1);

-- The row type changes during a call, between two assignments.
CREATE FUNCTION prs_alter_inside() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prs_t; before_count text;
BEGIN
    SELECT * INTO v FROM prs_t WHERE id = 1;
    before_count := v::text;
    ALTER TABLE prs_t ADD COLUMN late integer DEFAULT 5;
    SELECT * INTO v FROM prs_t WHERE id = 1;
    RETURN before_count || ' / ' || v::text;
END $$;
SELECT prs_alter_inside();

-- Composite domain target: the check runs, and a failed assignment keeps
-- the old value.
CREATE TYPE prs_pair AS (x integer, y text);
CREATE DOMAIN prs_pos_pair AS prs_pair CHECK ((VALUE).x > 0);
CREATE TABLE prs_src (x integer, y text);
INSERT INTO prs_src VALUES (1, 'good'), (-1, 'bad');
CREATE FUNCTION prs_domain(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prs_pos_pair;
BEGIN
    SELECT * INTO v FROM prs_src WHERE x = 1;
    BEGIN
        SELECT * INTO v FROM prs_src WHERE x = p;
    EXCEPTION WHEN check_violation THEN
        RETURN 'rejected, kept ' || v::text;
    END;
    RETURN 'stored ' || v::text;
END $$;
SELECT prs_domain(1), prs_domain(-1);

-- A new session reuses nothing from the old row type of a recreated table.
CREATE TABLE prs_again_t (a integer, b text);
INSERT INTO prs_again_t VALUES (1, 'first');
CREATE FUNCTION prs_again(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prs_again_t%ROWTYPE;
BEGIN
    SELECT * INTO v FROM prs_again_t WHERE a = p;
    RETURN v::text;
END $$;
SELECT prs_again(1);
\c -
DROP TABLE prs_again_t;
CREATE TABLE prs_again_t (a integer, c boolean, b text);
INSERT INTO prs_again_t VALUES (1, true, 'second');
SELECT prs_again(1);

DROP FUNCTION prs_read(integer), prs_whole(integer), prs_cast(), prs_count(),
    prs_loop(), prs_read_extra(integer), prs_alter_inside(), prs_domain(integer),
    prs_again(integer);
DROP TABLE prs_t, prs_src, prs_again_t;
DROP DOMAIN prs_pos_pair;
DROP TYPE prs_pair;
