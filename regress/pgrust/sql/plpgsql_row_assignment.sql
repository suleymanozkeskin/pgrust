--
-- PL/pgSQL assignment of query rows to row, record, and scalar-list targets:
-- values must not depend on how the result row is deformed.
--

CREATE TABLE pra_wide (
    id integer PRIMARY KEY,
    t1 text, i1 bigint, b1 bytea, ts timestamptz, flag boolean, u uuid, t2 text, n numeric
);
INSERT INTO pra_wide
SELECT g, 'text-' || g, g * 7, decode(md5(g::text), 'hex'),
       TIMESTAMPTZ '2026-01-01 00:00:00+00' + g * INTERVAL '1 minute',
       g % 2 = 0, md5(g::text)::uuid,
       CASE WHEN g % 3 = 0 THEN NULL ELSE repeat('x', g % 5) END,
       CASE WHEN g % 4 = 0 THEN NULL ELSE g / 3.0 END
FROM generate_series(1, 12) g;

-- %ROWTYPE target.
CREATE FUNCTION pra_rowtype(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v pra_wide%ROWTYPE;
BEGIN
    SELECT * INTO v FROM pra_wide WHERE id = p;
    RETURN format('%s|%s|%s|%s|%s|%s|%s|%s|%s', v.id, v.t1, v.i1, v.b1, v.ts, v.flag, v.u, v.t2, v.n);
END $$;
SELECT g, pra_rowtype(g) FROM generate_series(1, 5) g;

-- RECORD target, and a record reused for rows of two different shapes.
CREATE FUNCTION pra_record(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE r record; out text;
BEGIN
    SELECT * INTO r FROM pra_wide WHERE id = p;
    out := format('%s|%s|%s', r.id, r.t2, r.n);
    SELECT p AS a, 'second' AS b INTO r;
    RETURN out || ' / ' || format('%s|%s', r.a, r.b);
END $$;
SELECT pra_record(3), pra_record(4);

-- Scalar-list targets: exact, fewer, and more source columns.
CREATE FUNCTION pra_scalars(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE a integer; b text; c bigint; d text; e text;
BEGIN
    SELECT id, t1, i1 INTO a, b, c FROM pra_wide WHERE id = p;
    SELECT t2, t1, id INTO d, e FROM pra_wide WHERE id = p;
    RETURN format('%s|%s|%s|%s|%s', a, b, c, d, e);
END $$;
SELECT pra_scalars(2), pra_scalars(3);
CREATE FUNCTION pra_short(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE a integer; b text; c text;
BEGIN
    SELECT id, t1 INTO a, b, c FROM pra_wide WHERE id = p;
    RETURN format('%s|%s|%s', a, b, c IS NULL);
END $$;
SELECT pra_short(1);

-- FOR loop over a query into a row variable and into a record.
CREATE FUNCTION pra_loop() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v pra_wide%ROWTYPE; r record; acc text := '';
BEGIN
    FOR v IN SELECT * FROM pra_wide ORDER BY id LOOP
        acc := acc || coalesce(v.t2, '-') || ',';
    END LOOP;
    FOR r IN SELECT id, n FROM pra_wide WHERE id <= 4 ORDER BY id LOOP
        acc := acc || coalesce(r.n::text, 'null') || ';';
    END LOOP;
    RETURN acc;
END $$;
SELECT pra_loop();

-- Dropped columns in the source row type.
ALTER TABLE pra_wide DROP COLUMN b1;
ALTER TABLE pra_wide DROP COLUMN u;
SELECT g, pra_record(g) FROM generate_series(1, 2) g;
CREATE FUNCTION pra_rowtype2(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v pra_wide%ROWTYPE;
BEGIN
    SELECT * INTO v FROM pra_wide WHERE id = p;
    RETURN format('%s|%s|%s|%s|%s', v.id, v.t1, v.flag, v.t2, v.n);
END $$;
SELECT g, pra_rowtype2(g) FROM generate_series(1, 3) g;

-- Rows stored before ADD COLUMN ... DEFAULT (missing-attribute values).
ALTER TABLE pra_wide ADD COLUMN late text DEFAULT 'filled';
ALTER TABLE pra_wide ADD COLUMN late_n integer DEFAULT 7;
INSERT INTO pra_wide (id, t1, late, late_n) VALUES (100, 'new', 'explicit', 8);
CREATE FUNCTION pra_late(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v pra_wide%ROWTYPE; r record; x text; y integer;
BEGIN
    SELECT * INTO v FROM pra_wide WHERE id = p;
    SELECT * INTO r FROM pra_wide WHERE id = p;
    SELECT late, late_n INTO x, y FROM pra_wide WHERE id = p;
    RETURN format('%s|%s|%s|%s|%s|%s', v.id, v.late, v.late_n, r.late, x, y);
END $$;
SELECT pra_late(1), pra_late(100);

-- strict_multi_assignment reports a column-count mismatch.
SET plpgsql.extra_warnings = 'strict_multi_assignment';
CREATE FUNCTION pra_strict(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE a integer; b text;
BEGIN
    SELECT id, t1, t2 INTO a, b FROM pra_wide WHERE id = p;
    RETURN format('%s|%s', a, b);
END $$;
SELECT pra_strict(1);
RESET plpgsql.extra_warnings;

DROP FUNCTION pra_rowtype(integer), pra_record(integer), pra_scalars(integer),
    pra_short(integer), pra_loop(), pra_rowtype2(integer), pra_late(integer),
    pra_strict(integer);
DROP TABLE pra_wide;
