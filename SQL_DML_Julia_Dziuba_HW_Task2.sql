/* =====================================================================
   SQL_DML_Julia_Dziuba_HW_Task2.sql
   Task 2: DELETE vs VACUUM FULL vs TRUNCATE (PostgreSQL)
   ===================================================================== */


/* ---------------------------------------------------------------------
   1. Create 'table_to_delete' and fill it with 10^7 rows
   (DROP IF EXISTS first so the script is re-runnable)
   --------------------------------------------------------------------- */
DROP TABLE IF EXISTS public.table_to_delete;

CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1, (10^7)::int) x;   -- generate_series() creates 10^7 rows (1 .. 10000000)


/* ---------------------------------------------------------------------
   2. Space consumed by the table  [MEASUREMENT 1: after CREATE, before DELETE]
   --------------------------------------------------------------------- */
SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS INDEX,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS TABLE
FROM ( SELECT *, total_bytes - index_bytes - COALESCE(toast_bytes, 0) AS table_bytes
       FROM (SELECT c.oid, nspname AS table_schema,
                    relname AS TABLE_NAME,
                    c.reltuples AS row_estimate,
                    pg_total_relation_size(c.oid) AS total_bytes,
                    pg_indexes_size(c.oid) AS index_bytes,
                    pg_total_relation_size(reltoastrelid) AS toast_bytes
             FROM pg_class c
             LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE relkind = 'r'
            ) a
     ) a
WHERE table_name LIKE '%table_to_delete%';


/* ---------------------------------------------------------------------
   3. DELETE operation
   --------------------------------------------------------------------- */
-- 3a. DELETE (removes 1/3 of all rows)  -> note the execution time
DELETE FROM public.table_to_delete
WHERE REPLACE(col, 'veeeeeeery_long_string', '')::int % 3 = 0;   -- removes 1/3 of all rows

-- 3b. Space after DELETE  [MEASUREMENT 2]
SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS INDEX,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS TABLE
FROM ( SELECT *, total_bytes - index_bytes - COALESCE(toast_bytes, 0) AS table_bytes
       FROM (SELECT c.oid, nspname AS table_schema,
                    relname AS TABLE_NAME,
                    c.reltuples AS row_estimate,
                    pg_total_relation_size(c.oid) AS total_bytes,
                    pg_indexes_size(c.oid) AS index_bytes,
                    pg_total_relation_size(reltoastrelid) AS toast_bytes
             FROM pg_class c
             LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE relkind = 'r'
            ) a
     ) a
WHERE table_name LIKE '%table_to_delete%';

-- 3c. VACUUM FULL
VACUUM FULL VERBOSE public.table_to_delete;

-- 3d. Space after VACUUM FULL  [MEASUREMENT 3]
SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS INDEX,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS TABLE
FROM ( SELECT *, total_bytes - index_bytes - COALESCE(toast_bytes, 0) AS table_bytes
       FROM (SELECT c.oid, nspname AS table_schema,
                    relname AS TABLE_NAME,
                    c.reltuples AS row_estimate,
                    pg_total_relation_size(c.oid) AS total_bytes,
                    pg_indexes_size(c.oid) AS index_bytes,
                    pg_total_relation_size(reltoastrelid) AS toast_bytes
             FROM pg_class c
             LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE relkind = 'r'
            ) a
     ) a
WHERE table_name LIKE '%table_to_delete%';

-- 3e. Recreate the table (identical to step 1)
DROP TABLE IF EXISTS public.table_to_delete;

CREATE TABLE public.table_to_delete AS
SELECT 'veeeeeeery_long_string' || x AS col
FROM generate_series(1, (10^7)::int) x;


/* ---------------------------------------------------------------------
   4. TRUNCATE operation
   --------------------------------------------------------------------- */
-- 4a. TRUNCATE -> note the execution time
TRUNCATE public.table_to_delete;

-- 4b/4c. Space after TRUNCATE  [MEASUREMENT 4]
SELECT *, pg_size_pretty(total_bytes) AS total,
          pg_size_pretty(index_bytes) AS INDEX,
          pg_size_pretty(toast_bytes) AS toast,
          pg_size_pretty(table_bytes) AS TABLE
FROM ( SELECT *, total_bytes - index_bytes - COALESCE(toast_bytes, 0) AS table_bytes
       FROM (SELECT c.oid, nspname AS table_schema,
                    relname AS TABLE_NAME,
                    c.reltuples AS row_estimate,
                    pg_total_relation_size(c.oid) AS total_bytes,
                    pg_indexes_size(c.oid) AS index_bytes,
                    pg_total_relation_size(reltoastrelid) AS toast_bytes
             FROM pg_class c
             LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE relkind = 'r'
            ) a
     ) a
WHERE table_name LIKE '%table_to_delete%';


/* ---------------------------------------------------------------------
   5. RESULTS OF THE INVESTIGATION

   (Numbers measured on PostgreSQL 16 running in a local Docker container, 10^7 rows,
    default settings. Sizes are deterministic; the times (DELETE ~2.4-2.5 s, VACUUM FULL
    ~1.2 s, TRUNCATE ~15 ms) vary with hardware and server configuration, the ratio
    between DELETE and TRUNCATE does not.)

   a) Space consumption of 'table_to_delete' (total = table + index + toast)

      | moment                      | rows       | total   | table   | index   |
      |-----------------------------|------------|---------|---------|---------|
      | after CREATE (before DELETE)| 10 000 000 | 575 MB  | 575 MB  | 0 bytes |
      | after DELETE (1/3 removed)  |  6 666 667 | 575 MB  | 575 MB  | 0 bytes |
      | after VACUUM FULL           |  6 666 667 | 383 MB  | 383 MB  | 0 bytes |
      | after TRUNCATE (new table)  |          0 | 8 kB    | 0 bytes | 0 bytes |
      (toast is 8 kB in every case: the 'veeeeeeery_long_string' values are too short to be
       moved out of line, the 8 kB is only the empty toast table.)

   b) DELETE vs TRUNCATE
      | criterion          | DELETE (1/3 of rows)                          | TRUNCATE (all rows)                          |
      |--------------------|-----------------------------------------------|----------------------------------------------|
      | execution time     | ~2.5 s (3 333 333 rows, evaluates REPLACE+cast| ~15 ms (does not look at rows)               |
      |                    | for every row and writes a delete mark per row)|                                              |
      | disk space usage   | NOT freed (575 MB -> 575 MB); dead tuples stay| freed immediately (575 MB -> 8 kB): the old  |
      |                    | in the file until (auto)VACUUM / VACUUM FULL  | file is replaced with a new empty one        |
      | transaction        | normal DML: row-level work, WAL for each row, | DDL-like: takes ACCESS EXCLUSIVE lock, very  |
      | behaviour          | row locks, fires row triggers, can use WHERE  | little WAL, no row triggers, cannot filter   |
      |                    | MVCC: other transactions still see old rows   | rows; blocks all readers/writers meanwhile   |
      | rollback           | yes - fully rollbackable (before COMMIT)      | yes in PostgreSQL if inside BEGIN...ROLLBACK |
      | possibility        | and the cheapest to undo (rows just become    | (transactional, unlike in Oracle/MySQL);     |
      |                    | visible again)                                | after COMMIT the data is gone for good       |

   c) Explanation
      - Why DELETE does not free space immediately: because of MVCC, DELETE only marks the
        row versions as dead (sets xmax). Other transactions that started earlier may still
        need to see them, and the rows are also needed for a possible ROLLBACK. The physical
        pages stay allocated in the table file; plain VACUUM / autovacuum later marks that
        space as reusable INSIDE the same table (it normally does not shrink the file), so
        the size is still 575 MB right after the DELETE.
      - Why VACUUM FULL changes table size: VACUUM FULL rewrites the whole table into a new
        file containing only live rows (6 666 667 of them, 73 536 pages scanned) and swaps
        the files, so the dead space is returned to the operating system: 575 MB -> 383 MB
        (= 2/3 of the original, exactly the share of rows that survived). The price: an
        ACCESS EXCLUSIVE lock for the whole time (~1.2 s here, minutes/hours on big tables),
        extra disk space during the rewrite (old + new copy) and lots of I/O/WAL.
      - Why TRUNCATE behaves differently: it does not delete row by row at all - it creates
        a new empty data file for the table (and its indexes/toast) and drops the old one,
        which is why it takes milliseconds regardless of the row count, does not leave
        dead tuples (no VACUUM needed) and returns the space (575 MB -> 8 kB) at once.
        It cannot have a WHERE clause, needs an ACCESS EXCLUSIVE lock and does not fire
        ON DELETE row triggers.
      - Effect on performance and storage: DELETE of many rows is slow, generates a lot of
        WAL, leaves "bloat" (dead tuples) so sequential scans still read all 575 MB and
        the table/indexes stay oversized until VACUUM FULL (or pg_repack) is run - which
        itself blocks the table. TRUNCATE is the best choice to empty a whole table
        (fast, no bloat, space freed), DELETE is the only choice when only some rows must
        go or row triggers / fine-grained locking matter; after a big DELETE autovacuum
        (or a manual VACUUM) should run so the free space is reused by new inserts.
   --------------------------------------------------------------------- */
