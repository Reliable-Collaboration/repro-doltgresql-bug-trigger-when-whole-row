# DoltgreSQL 1.3.1: a trigger with `WHEN (old.* IS DISTINCT FROM new.*)` makes every UPDATE of its table fail

On DoltgreSQL 1.3.1, a row trigger whose `WHEN` clause compares the whole old and new rows,
`WHEN (old.* IS DISTINCT FROM new.*)`, is created without complaint, but from then on every `UPDATE`
that reaches a row of the table fails, and the row keeps its old value:

```
ERROR:  record "old" has no field "*"
```

PostgreSQL 18.6 evaluates the same clause, runs the trigger, and updates the row.

## Reproduce it

You need Docker and a POSIX shell: Linux, macOS, or Windows with WSL. The first run downloads the images.

```sh
git clone https://github.com/Reliable-Collaboration/repro-doltgresql-bug-trigger-when-whole-row.git
cd repro-doltgresql-bug-trigger-when-whole-row
./repro.sh
```

`repro.sh` starts PostgreSQL 18.6 and DoltgreSQL 1.3.1 in two throwaway containers, waits until both
accept connections, runs [`repro.sql`](repro.sql) on each with the `psql` client inside its container,
prints the two outputs side by side, and removes the containers. It exits 0 when DoltgreSQL's output is
identical to PostgreSQL's and 1 when it differs; with DoltgreSQL 1.3.1 it exits 1.

To try another DoltgreSQL release, name its image:

```sh
DOLTGRESQL_IMAGE=dolthub/doltgresql:latest ./repro.sh
```

### Without the script

The same steps by hand, from the repository directory:

```sh
docker run -d --name repro-doltgresql-bug-trigger-when-whole-row-postgres -e POSTGRES_PASSWORD=password postgres:18.6-bookworm
docker run -d --name repro-doltgresql-bug-trigger-when-whole-row-doltgresql -e DOLTGRES_PASSWORD=password dolthub/doltgresql:1.3.1
docker cp repro.sql repro-doltgresql-bug-trigger-when-whole-row-postgres:/tmp/repro.sql
docker cp repro.sql repro-doltgresql-bug-trigger-when-whole-row-doltgresql:/tmp/repro.sql
docker exec -t -e PGPASSWORD=password repro-doltgresql-bug-trigger-when-whole-row-postgres psql -X -P pager=off -h 127.0.0.1 -U postgres -d postgres --echo-all -f /tmp/repro.sql
docker exec -t -e PGPASSWORD=password repro-doltgresql-bug-trigger-when-whole-row-doltgresql psql -X -P pager=off -h 127.0.0.1 -U postgres -d postgres --echo-all -f /tmp/repro.sql
docker rm -f repro-doltgresql-bug-trigger-when-whole-row-postgres repro-doltgresql-bug-trigger-when-whole-row-doltgresql
```

If `docker exec` answers that the connection was refused, the server is still starting: wait a few
seconds and run it again.

## The test

[`repro.sql`](repro.sql):

```sql
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
```

## Expected behavior

The update changes the row, so the `WHEN` clause is true: the trigger function runs and prints its
notice, and the row is updated. This is what PostgreSQL 18.6 does, from the update on:

```
-- An update that changes the row.
UPDATE t SET a = 2;
psql:/tmp/repro.sql:16: NOTICE:  the trigger ran
UPDATE 1
SELECT * FROM t;
 a 
---
 2
(1 row)
```

## Actual behavior

The `CREATE TRIGGER` succeeds, but the `UPDATE` fails, no notice is printed, and the row keeps its old
value. This is what DoltgreSQL 1.3.1 does, from the update on:

```
-- An update that changes the row.
UPDATE t SET a = 2;
psql:/tmp/repro.sql:16: ERROR:  record "old" has no field "*"
SELECT * FROM t;
 a 
---
 1
(1 row)
```

## Side by side

The full output of `./repro.sh`. `diff` cuts lines that do not fit its columns, so DoltgreSQL's error
is shortened here; the whole line is under Actual behavior.

```
Starting postgres:18.6-bookworm@sha256:1c59e2c3c818eaa0f0628f695b36e7c9e362d6b219b36a54a32df645cbd7e1af
Starting dolthub/doltgresql:1.3.1@sha256:6c85cb1f35beabf47f094336a420255130b841b1645f36d79ef046276af36851

Left: PostgreSQL. Right: DoltgreSQL. Lines that differ are marked with |.

CREATE TABLE t (a int);                                       CREATE TABLE t (a int);
CREATE TABLE                                                  CREATE TABLE
INSERT INTO t VALUES (1);                                     INSERT INTO t VALUES (1);
INSERT 0 1                                                    INSERT 0 1
CREATE FUNCTION f() RETURNS trigger LANGUAGE plpgsql AS $$    CREATE FUNCTION f() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN                                                         BEGIN
  RAISE NOTICE 'the trigger ran';                               RAISE NOTICE 'the trigger ran';
  RETURN NEW;                                                   RETURN NEW;
END $$;                                                       END $$;
CREATE FUNCTION                                               CREATE FUNCTION
-- A trigger that fires only when an update changes a row.    -- A trigger that fires only when an update changes a row.
CREATE TRIGGER tr BEFORE UPDATE ON t FOR EACH ROW             CREATE TRIGGER tr BEFORE UPDATE ON t FOR EACH ROW
  WHEN (old.* IS DISTINCT FROM new.*)                           WHEN (old.* IS DISTINCT FROM new.*)
  EXECUTE FUNCTION f();                                         EXECUTE FUNCTION f();
CREATE TRIGGER                                                CREATE TRIGGER
-- An update that changes the row.                            -- An update that changes the row.
UPDATE t SET a = 2;                                           UPDATE t SET a = 2;
psql:/tmp/repro.sql:16: NOTICE:  the trigger ran            | psql:/tmp/repro.sql:16: ERROR:  record "old" has no field "
UPDATE 1                                                    <
SELECT * FROM t;                                              SELECT * FROM t;
 a                                                             a 
---                                                           ---
 2                                                          |  1
(1 row)                                                       (1 row)


Result: DoltgreSQL's output differs from PostgreSQL's on 2 line(s), marked with |.
```

## Other observations

Each variant was run on DoltgreSQL 1.3.1 and on PostgreSQL 18.6, and PostgreSQL ran every one without
an error:

- `WHEN (old.* IS NOT DISTINCT FROM new.*)`, `WHEN (ROW(old.*) IS DISTINCT FROM ROW(new.*))`,
  `WHEN (old.* <> new.*)` and `WHEN ((OLD.* IS DISTINCT FROM NEW.*))` fail with the same error.
- An `AFTER UPDATE` trigger, a table with a primary key and a second column, and a trigger function
  whose body is only `RETURN NEW;` fail the same way.
- An `UPDATE` that sets a column to its own value fails too. An `UPDATE` whose `WHERE` matches no row
  answers `UPDATE 0` without an error.
- The comparison inside the function body, `IF OLD.* IS DISTINCT FROM NEW.* THEN` or
  `IF ROW(OLD.*) IS DISTINCT FROM ROW(NEW.*) THEN`, with no `WHEN` clause, fails with the same error.
- Other events fail the same way: a `BEFORE INSERT` trigger with `WHEN (new.* IS NOT NULL)` refuses
  the `INSERT` with `ERROR:  record "new" has no field "*"`, and an `AFTER DELETE` trigger with
  `WHEN (old.* IS NOT NULL)` refuses the `DELETE`.
- Without the star, `WHEN (old IS DISTINCT FROM new)` also refuses the `UPDATE`, with a different error
  that begins `ERROR:  receiveMessage recovered panic: cannot find function:` and carries a Go stack
  trace. `IF OLD IS DISTINCT FROM NEW THEN` in the function body does the same.
- A per-column `WHEN (old.a IS DISTINCT FROM new.a)` works: the trigger runs and the row is updated.
- `INSERT` and `DELETE` on the table work while the `UPDATE` trigger exists, and after `DROP TRIGGER`
  updates work again.

## Environment

- DoltgreSQL 1.3.1, the newest release when this was written: image `dolthub/doltgresql:1.3.1`, digest
  `sha256:6c85cb1f35beabf47f094336a420255130b841b1645f36d79ef046276af36851`. Its bundled `psql` is 17.11.
- PostgreSQL 18.6: image `postgres:18.6-bookworm`, digest
  `sha256:1c59e2c3c818eaa0f0628f695b36e7c9e362d6b219b36a54a32df645cbd7e1af`. Its bundled `psql` is 18.6.
- Reproduced on 2026-09-10 with Docker 29.7.2 on Linux x86_64 (Ubuntu 26.04.1 LTS under WSL 2).
