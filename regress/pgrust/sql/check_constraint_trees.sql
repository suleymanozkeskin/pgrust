--
-- CHECK constraints evaluated by INSERT and UPDATE after the constraints of
-- the relation change in the same session: added, dropped, replaced under
-- the same name, rolled back, not enforced, rewritten by a column type
-- change, and depending on a function or a virtual generated column. Each
-- statement must use the constraints in effect at that statement.
--

CREATE TABLE cct (id integer, v integer, note text,
    CONSTRAINT cct_v CHECK (v > 0));
INSERT INTO cct VALUES (1, 5, 'a');
INSERT INTO cct VALUES (2, -1, 'b');
UPDATE cct SET v = 0 WHERE id = 1;

-- Same constraint name, different expression.
ALTER TABLE cct DROP CONSTRAINT cct_v;
ALTER TABLE cct ADD CONSTRAINT cct_v CHECK (v < 100);
INSERT INTO cct VALUES (3, -1, 'c');
INSERT INTO cct VALUES (4, 100, 'd');

-- Constraint added and removed.
ALTER TABLE cct ADD CONSTRAINT cct_note CHECK (note <> 'x');
INSERT INTO cct VALUES (5, 1, 'x');
ALTER TABLE cct DROP CONSTRAINT cct_note;
INSERT INTO cct VALUES (5, 1, 'x');

-- A constraint added in a transaction that rolls back.
BEGIN;
ALTER TABLE cct ADD CONSTRAINT cct_id CHECK (id < 10);
INSERT INTO cct VALUES (10, 1, 'e');
ROLLBACK;
INSERT INTO cct VALUES (10, 1, 'e');

-- The same with a savepoint; the statement after the rollback to the
-- savepoint uses the constraints of the outer transaction.
BEGIN;
ALTER TABLE cct ADD CONSTRAINT cct_id2 CHECK (id < 20);
SAVEPOINT s1;
ALTER TABLE cct DROP CONSTRAINT cct_id2;
INSERT INTO cct VALUES (30, 1, 'f');
ROLLBACK TO SAVEPOINT s1;
INSERT INTO cct VALUES (15, 1, 'g');
COMMIT;
INSERT INTO cct VALUES (32, 1, 'h');
ALTER TABLE cct DROP CONSTRAINT cct_id2;
INSERT INTO cct VALUES (32, 1, 'h');

-- Not enforced, then enforced (NOT VALID keeps the existing rows).
ALTER TABLE cct ADD CONSTRAINT cct_ne CHECK (v <> 7) NOT ENFORCED;
INSERT INTO cct VALUES (40, 7, 'i');
ALTER TABLE cct DROP CONSTRAINT cct_ne;
ALTER TABLE cct ADD CONSTRAINT cct_ne CHECK (v <> 7) NOT VALID;
INSERT INTO cct VALUES (41, 7, 'j');
UPDATE cct SET note = 'k' WHERE id = 40;
SELECT id, v, note FROM cct ORDER BY id;

-- Prepared statement across a constraint change.
PREPARE cct_ins(integer, integer) AS INSERT INTO cct VALUES ($1, $2, 'p');
EXECUTE cct_ins(50, 8);
ALTER TABLE cct ADD CONSTRAINT cct_even CHECK (v % 2 = 0) NOT VALID;
EXECUTE cct_ins(51, 9);
EXECUTE cct_ins(52, 10);
DEALLOCATE cct_ins;

-- Column type change rewrites the stored expression.
ALTER TABLE cct DROP CONSTRAINT cct_ne;
ALTER TABLE cct ALTER COLUMN v TYPE bigint;
INSERT INTO cct VALUES (60, 3000000000, 'q');
INSERT INTO cct VALUES (61, 3, 'r');
INSERT INTO cct VALUES (62, 4, 'r');
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'cct'::regclass ORDER BY conname;

-- Column rename: same constraint, new column name in the definition.
ALTER TABLE cct RENAME COLUMN v TO w;
INSERT INTO cct VALUES (63, 5, 's');
INSERT INTO cct VALUES (64, 6, 's');

-- A function used by a constraint is replaced.
CREATE FUNCTION cct_ok(n integer) RETURNS boolean LANGUAGE sql IMMUTABLE
    AS 'SELECT n <> 13';
CREATE TABLE cct_f (n integer CHECK (cct_ok(n)));
INSERT INTO cct_f VALUES (13);
INSERT INTO cct_f VALUES (14);
CREATE OR REPLACE FUNCTION cct_ok(n integer) RETURNS boolean LANGUAGE sql IMMUTABLE
    AS 'SELECT n <> 14';
INSERT INTO cct_f VALUES (13);
INSERT INTO cct_f VALUES (14);
CREATE OR REPLACE FUNCTION cct_ok(n integer) RETURNS boolean LANGUAGE plpgsql IMMUTABLE
    AS $$ BEGIN RETURN n <> 15; END $$;
INSERT INTO cct_f VALUES (15);
INSERT INTO cct_f VALUES (14);
SELECT n FROM cct_f ORDER BY n;

-- A constraint on a virtual generated column.
CREATE TABLE cct_g (a integer, b integer GENERATED ALWAYS AS (a * 2) VIRTUAL,
    CONSTRAINT cct_g_b CHECK (b < 20));
INSERT INTO cct_g (a) VALUES (5);
INSERT INTO cct_g (a) VALUES (10);
ALTER TABLE cct_g DROP CONSTRAINT cct_g_b;
ALTER TABLE cct_g ADD CONSTRAINT cct_g_b CHECK (b < 30);
INSERT INTO cct_g (a) VALUES (10);
UPDATE cct_g SET a = 20 WHERE a = 5;
SELECT a, b FROM cct_g ORDER BY a;

-- Partitions: inherited and own constraints.
CREATE TABLE cct_p (k integer, v integer, CONSTRAINT cct_p_v CHECK (v >= 0))
    PARTITION BY RANGE (k);
CREATE TABLE cct_p1 PARTITION OF cct_p FOR VALUES FROM (0) TO (10);
CREATE TABLE cct_p2 PARTITION OF cct_p FOR VALUES FROM (10) TO (20);
ALTER TABLE cct_p2 ADD CONSTRAINT cct_p2_v CHECK (v < 5);
INSERT INTO cct_p VALUES (1, 7);
INSERT INTO cct_p VALUES (11, 7);
INSERT INTO cct_p VALUES (12, -1);
UPDATE cct_p SET k = 15 WHERE k = 1;
ALTER TABLE cct_p DROP CONSTRAINT cct_p_v;
INSERT INTO cct_p VALUES (2, -1);
SELECT tableoid::regclass, k, v FROM cct_p ORDER BY k;

-- A dropped table and a new table with the same name.
DROP TABLE cct_f;
CREATE TABLE cct_f (n integer CHECK (n > 100));
INSERT INTO cct_f VALUES (13);
INSERT INTO cct_f VALUES (113);

-- More relations with constraints than a session keeps parsed at once; the
-- first relation is used again at the end.
DO $$
DECLARE
    failures integer := 0;
BEGIN
    FOR i IN 1..300 LOOP
        EXECUTE format('CREATE TABLE cct_many_%s (x integer CHECK (x <> %s))', i, i);
        EXECUTE format('INSERT INTO cct_many_%s VALUES (0)', i);
        BEGIN
            EXECUTE format('INSERT INTO cct_many_%s VALUES (%s)', i, i);
        EXCEPTION WHEN check_violation THEN
            failures := failures + 1;
        END;
    END LOOP;
    RAISE NOTICE 'check violations: %', failures;
END $$;
INSERT INTO cct_many_1 VALUES (1);
INSERT INTO cct_many_1 VALUES (2);
DO $$
BEGIN
    FOR i IN 1..300 LOOP
        EXECUTE format('DROP TABLE cct_many_%s', i);
    END LOOP;
END $$;

DROP TABLE cct, cct_f, cct_g, cct_p;
DROP FUNCTION cct_ok(integer);
