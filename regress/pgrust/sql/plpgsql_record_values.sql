--
-- Values held by PL/pgSQL record variables after a row assignment:
-- by-reference fields, large and TOASTed values, values that outlive a
-- COMMIT in a procedure, defaults of columns added later, field
-- assignment after a row assignment, and trigger rows.
--

CREATE TABLE prv_t (id integer, small text, big text, n numeric, b bytea);
ALTER TABLE prv_t ALTER COLUMN big SET STORAGE EXTERNAL;
INSERT INTO prv_t
SELECT g, 's' || g, repeat(md5(g::text), 200), g * 1.5, decode(repeat('ab', g), 'hex')
FROM generate_series(1, 5) g;

-- Row and record targets keep every field after the next statements run.
CREATE FUNCTION prv_hold() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prv_t; r record; out text;
BEGIN
    SELECT * INTO v FROM prv_t WHERE id = 2;
    SELECT * INTO r FROM prv_t WHERE id = 3;
    PERFORM count(*) FROM prv_t;
    out := format('%s %s %s %s %s|', v.id, v.small, length(v.big), v.n, v.b);
    out := out || format('%s %s %s %s %s', r.id, r.small, length(r.big), r.n, r.b);
    RETURN out || ' ' || md5(v.big) || ' ' || md5(r.big);
END $$;
SELECT prv_hold();
SELECT md5(big) FROM prv_t WHERE id IN (2, 3) ORDER BY id;

-- Field assignment after a row assignment, then another row assignment.
CREATE FUNCTION prv_fields() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prv_t; r record; out text;
BEGIN
    SELECT * INTO v FROM prv_t WHERE id = 1;
    v.small := v.small || '-changed';
    v.big := 'replaced';
    out := v.small || ' ' || v.big || ' ' || v.n;
    SELECT * INTO v FROM prv_t WHERE id = 4;
    out := out || ' / ' || v.small || ' ' || length(v.big);
    SELECT * INTO r FROM prv_t WHERE id = 5;
    r.small := upper(r.small);
    RETURN out || ' / ' || r.small || ' ' || length(r.big);
END $$;
SELECT prv_fields();

-- FOR loops keep the current row's values across statements in the body.
CREATE FUNCTION prv_loop() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prv_t; r record; acc text := '';
BEGIN
    FOR v IN SELECT * FROM prv_t ORDER BY id LOOP
        PERFORM 1;
        acc := acc || v.small || ':' || length(v.big) || ' ';
    END LOOP;
    FOR r IN SELECT id, big, b FROM prv_t ORDER BY id DESC LOOP
        acc := acc || r.id || ':' || left(r.big, 4) || ':' || r.b || ' ';
    END LOOP;
    RETURN acc;
END $$;
SELECT prv_loop();

-- A procedure commits while records hold TOASTed values, then changes the
-- rows; the records keep the values they read.
CREATE PROCEDURE prv_commit() LANGUAGE plpgsql AS $$
DECLARE v prv_t; r record;
BEGIN
    SELECT * INTO v FROM prv_t WHERE id = 1;
    SELECT * INTO r FROM prv_t WHERE id = 2;
    COMMIT;
    UPDATE prv_t SET big = 'gone' WHERE id IN (1, 2);
    DELETE FROM prv_t WHERE id = 5;
    COMMIT;
    RAISE NOTICE 'v % %, r % %', v.id, md5(v.big), r.id, md5(r.big);
    FOR v IN SELECT * FROM prv_t WHERE id = 3 LOOP
        COMMIT;
        RAISE NOTICE 'loop % %', v.id, md5(v.big);
    END LOOP;
END $$;
SELECT md5(big) FROM prv_t WHERE id IN (1, 2) ORDER BY id;
CALL prv_commit();
SELECT id, left(big, 8) FROM prv_t ORDER BY id;

-- Columns added with a default after rows were stored.
ALTER TABLE prv_t ADD COLUMN late text DEFAULT 'late-default';
ALTER TABLE prv_t ADD COLUMN late_n integer DEFAULT 42;
INSERT INTO prv_t (id, small, late, late_n) VALUES (9, 'new', 'late-set', 7);
CREATE FUNCTION prv_late() RETURNS text LANGUAGE plpgsql AS $$
DECLARE v prv_t; r record; acc text := '';
BEGIN
    FOR v IN SELECT * FROM prv_t WHERE id IN (3, 9) ORDER BY id LOOP
        acc := acc || v.id || ':' || v.late || ':' || v.late_n || ' ';
    END LOOP;
    SELECT * INTO r FROM prv_t WHERE id = 4;
    PERFORM 1;
    RETURN acc || r.late || ':' || r.late_n;
END $$;
SELECT prv_late();

-- Trigger rows: NEW is changed and returned; OLD is read.
CREATE FUNCTION prv_trig() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        NEW.small := OLD.small || '>' || NEW.small;
        NEW.big := left(OLD.big, 4) || '|' || length(OLD.big);
    ELSE
        NEW.small := NEW.small || '!';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER prv_trig BEFORE INSERT OR UPDATE ON prv_t
    FOR EACH ROW EXECUTE FUNCTION prv_trig();
UPDATE prv_t SET small = 'u' || id WHERE id IN (3, 4);
INSERT INTO prv_t (id, small, big) VALUES (10, 'ins', repeat('z', 5000));
SELECT id, small, left(big, 12), length(big), late, late_n FROM prv_t ORDER BY id;

DROP TRIGGER prv_trig ON prv_t;
DROP FUNCTION prv_trig(), prv_hold(), prv_fields(), prv_loop(), prv_late();
DROP PROCEDURE prv_commit();
DROP TABLE prv_t;
