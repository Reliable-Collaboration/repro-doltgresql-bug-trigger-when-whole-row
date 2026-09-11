CREATE TABLE t (a int);
INSERT INTO t VALUES (1);

CREATE FUNCTION f() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  RAISE NOTICE 'the trigger ran';
  RETURN NEW;
END $$;

-- A trigger that fires only when an update changes a row.
CREATE TRIGGER tr BEFORE UPDATE ON t FOR EACH ROW
  WHEN (old.* IS DISTINCT FROM new.*)
  EXECUTE FUNCTION f();

-- An update that changes the row.
UPDATE t SET a = 2;

SELECT * FROM t;
