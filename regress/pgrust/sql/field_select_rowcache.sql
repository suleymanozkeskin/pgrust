--
-- Field selection from composite values (FieldSelect): results must not
-- depend on whether the row type's descriptor is cached in the expression.
--

-- Named composite: a table row type with mixed fixed-length and varlena
-- columns, expanded field by field over many rows.
CREATE TABLE fsr_wide (
    id integer PRIMARY KEY,
    t1 text, i1 bigint, b1 bytea, ts timestamptz, flag boolean, u uuid, t2 text
);
INSERT INTO fsr_wide
SELECT g, 'text-' || g, g * 7, decode(md5(g::text), 'hex'),
       TIMESTAMPTZ '2026-01-01 00:00:00+00' + g * INTERVAL '1 minute',
       g % 2 = 0, md5(g::text)::uuid, repeat('x', g % 5)
FROM generate_series(1, 20) g;

SELECT (w).id, (w).t1, (w).i1, (w).b1, (w).flag, (w).t2
FROM (SELECT w FROM fsr_wide w ORDER BY id) s
WHERE (w).id <= 3;

SELECT sum((w).i1), count((w).t2), string_agg((w).t1, ',' ORDER BY (w).id)
FROM (SELECT w FROM fsr_wide w) s;

-- A composite returned by a PL/pgSQL function and expanded with (d.r).*.
CREATE FUNCTION fsr_get(p integer) RETURNS TABLE(location text, r fsr_wide)
LANGUAGE plpgsql STABLE AS $$
DECLARE v fsr_wide%ROWTYPE;
BEGIN
    SELECT w.* INTO v FROM fsr_wide w WHERE w.id = p;
    RETURN QUERY SELECT 'HISTORY'::text, v;
END $$;

SELECT location, (d.r).* FROM fsr_get(4) AS d;
SELECT (d.r).id, (d.r).t1 FROM generate_series(1, 5) g, LATERAL fsr_get(g) AS d ORDER BY 1;

-- The same prepared statement across row-type changes (its selected fields
-- survive every change), and the full expansion after each change.
PREPARE fsr_prep(integer) AS
    SELECT (w).id, (w).flag, (w).t2 FROM (SELECT w FROM fsr_wide w WHERE id = $1) s;
EXECUTE fsr_prep(2);
SELECT (w).* FROM (SELECT w FROM fsr_wide w WHERE id = 2) s;
ALTER TABLE fsr_wide ADD COLUMN extra integer DEFAULT 42;
EXECUTE fsr_prep(2);
SELECT (w).* FROM (SELECT w FROM fsr_wide w WHERE id = 2) s;
ALTER TABLE fsr_wide DROP COLUMN t1;
EXECUTE fsr_prep(2);
SELECT (w).* FROM (SELECT w FROM fsr_wide w WHERE id = 2) s;
ALTER TABLE fsr_wide ALTER COLUMN i1 TYPE numeric;
EXECUTE fsr_prep(2);
SELECT (w).* FROM (SELECT w FROM fsr_wide w WHERE id = 2) s;
DEALLOCATE fsr_prep;
SELECT location, (d.r).* FROM fsr_get(5) AS d;

-- Anonymous records (RECORD with a blessed descriptor).
SELECT (x).f1, (x).f2
FROM (SELECT ROW(g, 'r' || g) AS x FROM generate_series(1, 3) g) s(x)
ORDER BY 1;
SELECT (y).*
FROM (SELECT ROW(1, 'a'::text, 2.5::numeric) AS y) s;

-- Domain over a composite type.
CREATE TYPE fsr_pair AS (lo integer, hi integer);
CREATE DOMAIN fsr_ordered AS fsr_pair CHECK ((VALUE).lo <= (VALUE).hi);
SELECT ((ROW(g, g + 1)::fsr_pair)::fsr_ordered).hi FROM generate_series(1, 3) g;
SELECT ((ROW(3, 1)::fsr_pair)::fsr_ordered).lo;

-- NULL composites and NULL fields.
SELECT (w).id IS NULL AS id_null, (w).t2 IS NULL AS t2_null
FROM (SELECT NULL::fsr_wide AS w) s;
SELECT (p).lo, (p).hi FROM (VALUES (ROW(1, NULL)::fsr_pair), (NULL::fsr_pair)) v(p);

DROP FUNCTION fsr_get(integer);
DROP DOMAIN fsr_ordered;
DROP TYPE fsr_pair;
DROP TABLE fsr_wide;
