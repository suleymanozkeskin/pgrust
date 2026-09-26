--
-- Stored expressions (CHECK constraints, column defaults, views, rules) are
-- read back from node strings. Constants that contain the node string's
-- special bytes must come back unchanged.
--

CREATE TABLE nst_t (
    id integer,
    a text DEFAULT '{(a)} \ <> "q" \\ end',
    b text DEFAULT E'tab\there\nnewline',
    c text CHECK (c <> '(){}' AND c <> '\' AND c <> '<>'),
    d text CHECK (d IS NULL OR d NOT LIKE '%\{%' ESCAPE '!'),
    e integer CHECK (e BETWEEN -12 AND 12)
);
INSERT INTO nst_t (id, c, d, e) VALUES (1, 'x', 'y', 5);
INSERT INTO nst_t (id, c, d, e) VALUES (2, '(){}x', NULL, -12);
INSERT INTO nst_t (id, c) VALUES (3, '(){}');
INSERT INTO nst_t (id, c) VALUES (4, '\');
INSERT INTO nst_t (id, c) VALUES (5, '<>');
INSERT INTO nst_t (id, d) VALUES (6, 'a\{b');
INSERT INTO nst_t (id, e) VALUES (7, 13);
SELECT id, a, b, c, d, e FROM nst_t ORDER BY id;

SELECT pg_get_expr(adbin, adrelid) FROM pg_attrdef
WHERE adrelid = 'nst_t'::regclass ORDER BY adnum;
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'nst_t'::regclass ORDER BY conname;

CREATE VIEW nst_v AS
SELECT id, a || '|{x}|' AS a2, c = '(){}' AS special, '\' || id::text AS back,
       ARRAY['{', '}', '(', ')'] AS brackets
FROM nst_t;
SELECT * FROM nst_v ORDER BY id;
SELECT pg_get_viewdef('nst_v'::regclass, true);

CREATE TABLE nst_log (note text);
CREATE RULE nst_rule AS ON UPDATE TO nst_t
    DO ALSO INSERT INTO nst_log VALUES ('updated {' || old.id || '} \ (' || new.c || ')');
UPDATE nst_t SET c = 'new(){}' WHERE id = 1;
SELECT * FROM nst_log;

DROP RULE nst_rule ON nst_t;
DROP VIEW nst_v;
DROP TABLE nst_t, nst_log;
