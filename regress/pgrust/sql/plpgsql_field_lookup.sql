--
-- PL/pgSQL record field reads by name must find the field in the record's
-- current shape: the same name at different positions, a table changed
-- between calls, records reassigned in a loop, and missing fields.
--

CREATE TABLE pfl_a (id integer, x text, y integer);
CREATE TABLE pfl_b (y integer, id integer, z text, x text);
INSERT INTO pfl_a VALUES (1, 'a-x', 10), (2, 'a-x2', 20);
INSERT INTO pfl_b VALUES (100, 1, 'b-z', 'b-x'), (200, 2, 'b-z2', 'b-x2');

-- One record, one field reference, rows of two shapes in turn.
CREATE FUNCTION pfl_alternate() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; acc text := '';
BEGIN
    FOR i IN 1..4 LOOP
        IF i % 2 = 1 THEN
            SELECT * INTO r FROM pfl_a WHERE id = (i + 1) / 2;
        ELSE
            SELECT * INTO r FROM pfl_b WHERE id = i / 2;
        END IF;
        acc := acc || format('[%s %s %s]', r.id, r.x, r.y);
    END LOOP;
    RETURN acc;
END $$;
SELECT pfl_alternate();

-- A field that exists in only one of the shapes.
CREATE FUNCTION pfl_missing() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; out text;
BEGIN
    SELECT * INTO r FROM pfl_b WHERE id = 1;
    out := r.z;
    SELECT * INTO r FROM pfl_a WHERE id = 1;
    RETURN out || ' ' || r.z;
END $$;
SELECT pfl_missing();

-- %ROWTYPE field reads across calls while the table changes.
CREATE FUNCTION pfl_rowtype(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v pfl_a%ROWTYPE;
BEGIN
    SELECT * INTO v FROM pfl_a WHERE id = p;
    RETURN format('%s %s', v.x, v.y);
END $$;
SELECT pfl_rowtype(1), pfl_rowtype(2);
ALTER TABLE pfl_a ADD COLUMN w text DEFAULT 'w';
SELECT pfl_rowtype(1);
ALTER TABLE pfl_a DROP COLUMN x;
ALTER TABLE pfl_a ADD COLUMN x text DEFAULT 'new-x';
SELECT pfl_rowtype(1), pfl_rowtype(2);
ALTER TABLE pfl_a DROP COLUMN y;
SELECT pfl_rowtype(1);

-- Field assignment by name after the shape changes.
CREATE FUNCTION pfl_assign() RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; acc text := '';
BEGIN
    SELECT * INTO r FROM pfl_b WHERE id = 1;
    r.x := 'set-b';
    acc := r::text;
    SELECT 5 AS id, 'q' AS x INTO r;
    r.x := 'set-anon';
    RETURN acc || ' ' || r::text;
END $$;
SELECT pfl_assign();

-- A new session reads the same field names from a recreated table.
CREATE TABLE pfl_c (a integer, b text);
INSERT INTO pfl_c VALUES (1, 'first');
CREATE FUNCTION pfl_again() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v pfl_c%ROWTYPE;
BEGIN
    SELECT * INTO v FROM pfl_c;
    RETURN v.b || ':' || v.a;
END $$;
SELECT pfl_again();
\c -
DROP TABLE pfl_c;
CREATE TABLE pfl_c (b text, pad integer, a integer);
INSERT INTO pfl_c VALUES ('second', 0, 2);
SELECT pfl_again();

DROP FUNCTION pfl_alternate(), pfl_missing(), pfl_rowtype(integer), pfl_assign(),
    pfl_again();
DROP TABLE pfl_a, pfl_b, pfl_c;
