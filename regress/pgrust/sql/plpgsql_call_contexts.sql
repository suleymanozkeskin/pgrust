--
-- PL/pgSQL calls and SPI connections that start and end in many ways:
-- deep recursion, nested calls from queries, errors caught at several
-- levels, and transaction control in procedures. Values must not leak
-- from one call into the next.
--

CREATE TABLE pcc_t (id integer PRIMARY KEY, v text);
INSERT INTO pcc_t SELECT g, 'v' || g FROM generate_series(1, 50) g;

-- Recursion deeper than any small reuse bound, with text values per level.
CREATE FUNCTION pcc_depth(n integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text;
BEGIN
    SELECT v INTO s FROM pcc_t WHERE id = n;
    IF n <= 1 THEN
        RETURN s;
    END IF;
    RETURN s || ',' || pcc_depth(n - 1);
END $$;
SELECT pcc_depth(30);
SELECT pcc_depth(3), pcc_depth(2);

-- Many calls from one query; each call starts with fresh variables.
CREATE FUNCTION pcc_fresh(p integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text; n integer;
BEGIN
    IF p % 2 = 0 THEN
        SELECT v, id INTO s, n FROM pcc_t WHERE id = p;
    END IF;
    RETURN coalesce(s, 'null') || '/' || coalesce(n::text, 'null');
END $$;
SELECT string_agg(pcc_fresh(g), ' ' ORDER BY g) FROM generate_series(1, 8) g;
SELECT count(*), count(DISTINCT pcc_fresh(g)) FROM generate_series(1, 2000) g;

-- An error in a nested call, caught at different levels.
CREATE FUNCTION pcc_fail(n integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text;
BEGIN
    SELECT v INTO s FROM pcc_t WHERE id = n;
    IF n = 0 THEN
        RAISE EXCEPTION 'failed at depth %', n;
    END IF;
    RETURN s || '>' || pcc_fail(n - 1);
END $$;
CREATE FUNCTION pcc_catch(n integer) RETURNS text LANGUAGE plpgsql AS $$
DECLARE s text;
BEGIN
    BEGIN
        s := pcc_fail(n);
    EXCEPTION WHEN raise_exception THEN
        s := 'caught: ' || SQLERRM;
    END;
    -- SPI works after the caught error.
    RETURN s || ' | ' || (SELECT v FROM pcc_t WHERE id = n + 1);
END $$;
SELECT pcc_catch(5);
SELECT pcc_catch(12);
SELECT pcc_fail(3);
SELECT pcc_depth(4);

-- Errors caught inside a loop, many times.
CREATE FUNCTION pcc_loop_catch(n integer) RETURNS integer LANGUAGE plpgsql AS $$
DECLARE caught integer := 0; s text;
BEGIN
    FOR i IN 1..n LOOP
        BEGIN
            s := pcc_fail(i % 4);
        EXCEPTION WHEN raise_exception THEN
            caught := caught + 1;
        END;
    END LOOP;
    RETURN caught;
END $$;
SELECT pcc_loop_catch(40);

-- Procedures with transaction control.
CREATE TABLE pcc_log (step integer, note text);
CREATE PROCEDURE pcc_commit_steps(n integer) LANGUAGE plpgsql AS $$
BEGIN
    FOR i IN 1..n LOOP
        INSERT INTO pcc_log VALUES (i, pcc_depth(i));
        IF i % 2 = 0 THEN
            COMMIT;
        ELSE
            ROLLBACK;
        END IF;
    END LOOP;
END $$;
CALL pcc_commit_steps(6);
SELECT * FROM pcc_log ORDER BY step;

-- A trigger function called for each row.
CREATE FUNCTION pcc_trig() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.note := NEW.note || '+' || pcc_depth(2);
    RETURN NEW;
END $$;
CREATE TRIGGER pcc_trig BEFORE INSERT ON pcc_log FOR EACH ROW EXECUTE FUNCTION pcc_trig();
INSERT INTO pcc_log SELECT g, 'row' || g FROM generate_series(10, 13) g;
SELECT * FROM pcc_log WHERE step >= 10 ORDER BY step;

DROP TABLE pcc_log;
DROP PROCEDURE pcc_commit_steps(integer);
DROP FUNCTION pcc_trig(), pcc_depth(integer), pcc_fresh(integer), pcc_fail(integer),
    pcc_catch(integer), pcc_loop_catch(integer);
DROP TABLE pcc_t;
