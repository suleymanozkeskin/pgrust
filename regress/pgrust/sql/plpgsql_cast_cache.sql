--
-- Assignment casts in PL/pgSQL across calls and transactions: domains whose
-- constraints change, typmods, text input/output casts, recursion through
-- the same cast, and a cast function that is replaced.
--

CREATE DOMAIN pcc_small AS integer CHECK (VALUE < 100);
CREATE FUNCTION pcc_to_small(p numeric) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v pcc_small;
BEGIN
    v := p;
    RETURN v::text;
END $$;
SELECT pcc_to_small(5.4), pcc_to_small(99);
SELECT pcc_to_small(100);
BEGIN;
SELECT pcc_to_small(7), pcc_to_small(8);
COMMIT;

-- The domain constraint changes between transactions.
ALTER DOMAIN pcc_small DROP CONSTRAINT pcc_small_check;
ALTER DOMAIN pcc_small ADD CONSTRAINT pcc_small_check CHECK (VALUE < 10);
SELECT pcc_to_small(9);
SELECT pcc_to_small(50);
ALTER DOMAIN pcc_small DROP CONSTRAINT pcc_small_check;
SELECT pcc_to_small(500);

-- Typmods and text input/output casts, many calls in one statement.
CREATE FUNCTION pcc_typmod(p text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v varchar(3); n numeric(5,1); i integer;
BEGIN
    n := length(p) * 1.25;
    i := n;
    v := p;
    RETURN v || '|' || n || '|' || i;
END $$;
SELECT string_agg(pcc_typmod(repeat('x', g)), ' ' ORDER BY g) FROM generate_series(1, 3) g;
SELECT pcc_typmod('toolong');
CREATE FUNCTION pcc_text_int(p text) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE i integer;
BEGIN
    i := p;
    RETURN i;
END $$;
SELECT sum(pcc_text_int(g::text)) FROM generate_series(1, 2000) g;
SELECT pcc_text_int('12x');

-- Recursion: each level assigns through the same cast while outer levels
-- are inside it.
CREATE FUNCTION pcc_depth(n integer) RETURNS numeric LANGUAGE plpgsql AS $$
DECLARE v numeric(10,2);
BEGIN
    IF n = 0 THEN
        RETURN 0;
    END IF;
    v := n + pcc_depth(n - 1);
    RETURN v;
END $$;
SELECT pcc_depth(20);

-- A user-defined cast whose function is replaced between transactions.
CREATE TYPE pcc_pair AS (a integer, b integer);
CREATE FUNCTION pcc_pair_to_int(p pcc_pair) RETURNS integer LANGUAGE sql IMMUTABLE
    AS 'SELECT p.a + p.b';
CREATE CAST (pcc_pair AS integer) WITH FUNCTION pcc_pair_to_int(pcc_pair) AS ASSIGNMENT;
CREATE FUNCTION pcc_use_pair(x integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE i integer;
BEGIN
    i := ROW(x, 10)::pcc_pair;
    RETURN i;
END $$;
SELECT pcc_use_pair(1), pcc_use_pair(2);
CREATE OR REPLACE FUNCTION pcc_pair_to_int(p pcc_pair) RETURNS integer LANGUAGE sql IMMUTABLE
    AS 'SELECT p.a * p.b';
SELECT pcc_use_pair(1), pcc_use_pair(2);

DROP FUNCTION pcc_to_small(numeric), pcc_typmod(text), pcc_text_int(text),
    pcc_depth(integer), pcc_use_pair(integer);
DROP CAST (pcc_pair AS integer);
DROP FUNCTION pcc_pair_to_int(pcc_pair);
DROP TYPE pcc_pair;
DROP DOMAIN pcc_small;
