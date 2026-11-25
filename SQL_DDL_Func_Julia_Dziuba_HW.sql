/*
 SQL_DDL_Func_Julia_Dziuba_HW.sql - DVD rental database, tasks 1-5 (PostgreSQL)
 Author: Julia Dziuba

 - New objects are in schema "core"; source tables are in "public".
 - Rerunnable. No hardcoded IDs.
 - Tests keep no test data: expected errors are caught and printed as notices,
   inserts are rolled back (sequence values may therefore have gaps).
*/

CREATE SCHEMA IF NOT EXISTS core;


/*
 TASK 1. VIEW core.sales_revenue_by_category_qtr

 Logic: a sale is a payment (payment -> rental -> inventory -> film_category ->
   category). Revenue = SUM(amount) per category. Each film has one category
   here, so no payment is counted twice.
 Current quarter and year: date_trunc('quarter', CURRENT_DATE) gives the first
   day of the quarter, including the year. The range is from that day (included)
   to 3 months later (excluded), in the session time zone. payment_date is not
   wrapped in a function, so indexes and partition pruning can be used.
 Dynamic: CURRENT_DATE is evaluated on every query, so a new quarter is picked
   up automatically.
 Only categories with sales: with INNER JOINs from payment, a category without
   sales forms no group. HAVING SUM(amount) > 0 also removes categories that
   have only 0.00 payments.
 Incorrect input: the view has no parameters; a wrong column name causes an
   error.
 Missing data: without current payments or related rows, sales are left out
   (possibly 0 rows), with no error.
 No current-year data: the default database has only 2017 payments. Verified by
   test 1C (temporary payments, rolled back) and by running the same logic on
   2017 data with the task 2 function.
 Must NOT appear: earlier quarters or years (e.g. 2017), including one second
   before this quarter; categories with no sales or only 0.00 payments.
*/
CREATE OR REPLACE VIEW core.sales_revenue_by_category_qtr AS
SELECT c.name        AS category,
       SUM(p.amount) AS total_sales_revenue
FROM public.payment       AS p
JOIN public.rental        AS r  ON r.rental_id     = p.rental_id
JOIN public.inventory     AS i  ON i.inventory_id  = r.inventory_id
JOIN public.film_category AS fc ON fc.film_id      = i.film_id
JOIN public.category      AS c  ON c.category_id   = fc.category_id
WHERE p.payment_date >= date_trunc('quarter', CURRENT_DATE)
  AND p.payment_date <  date_trunc('quarter', CURRENT_DATE) + INTERVAL '3 months'
GROUP BY c.category_id, c.name
HAVING SUM(p.amount) > 0
ORDER BY total_sales_revenue DESC, category;

-- Test 1A (valid): expected one row per category with sales this quarter;
-- 0 rows on the unchanged database.
SELECT * FROM core.sales_revenue_by_category_qtr;

-- Test 1B (edge): 2017 payments exist but must add nothing to the view.
SELECT COUNT(*)                                                     AS payments_in_2017,
       (SELECT COUNT(*) FROM core.sales_revenue_by_category_qtr)    AS categories_in_view
FROM public.payment
WHERE payment_date >= DATE '2017-01-01'
  AND payment_date <  DATE '2018-01-01';

-- Test 1C (temporary data, rolled back): Comedy 10.00 now must be added;
-- Horror 20.00 last quarter and Drama 0.00 now must add nothing.
-- Temporary partitions are created if needed.
DO $test$
DECLARE
    v_quarter_start  timestamptz := date_trunc('quarter', CURRENT_DATE);
    v_range_start    timestamptz;
    v_is_partitioned boolean;
    v_case           record;
    v_before         numeric[] := '{}';
    v_delta          numeric;
    v_index          integer := 0;
BEGIN
    SELECT EXISTS (SELECT 1
                   FROM pg_catalog.pg_partitioned_table
                   WHERE partrelid = 'public.payment'::regclass)
    INTO v_is_partitioned;

    IF v_is_partitioned THEN
        FOREACH v_range_start IN ARRAY ARRAY[v_quarter_start - INTERVAL '3 months',
                                             v_quarter_start]
        LOOP
            BEGIN
                EXECUTE format(
                    'CREATE TABLE core.%I PARTITION OF public.payment FOR VALUES FROM (%L) TO (%L)',
                    'payment_verify_' || to_char(v_range_start, 'YYYY_"q"Q'),
                    v_range_start,
                    v_range_start + INTERVAL '3 months');
            EXCEPTION
                WHEN invalid_object_definition THEN
                    RAISE NOTICE 'A partition already covers dates from %', v_range_start;
            END;
        END LOOP;
    END IF;

    FOR v_case IN
        SELECT *
        FROM (VALUES ('Comedy'),
                     ('Horror'),
                     ('Drama')) AS t(category_name)
    LOOP
        v_before := v_before || COALESCE(
            (SELECT total_sales_revenue
             FROM core.sales_revenue_by_category_qtr
             WHERE category = v_case.category_name), 0);
    END LOOP;

    FOR v_case IN
        SELECT *
        FROM (VALUES ('Comedy', 10.00, CURRENT_TIMESTAMP),
                     ('Horror', 20.00, v_quarter_start - INTERVAL '1 second'),
                     ('Drama',   0.00, CURRENT_TIMESTAMP)) AS t(category_name, amount, paid_at)
    LOOP
        INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
        SELECT r.customer_id, r.staff_id, r.rental_id, v_case.amount, v_case.paid_at
        FROM public.rental        AS r
        JOIN public.inventory     AS i  ON i.inventory_id = r.inventory_id
        JOIN public.film_category AS fc ON fc.film_id     = i.film_id
        JOIN public.category      AS c  ON c.category_id  = fc.category_id
        WHERE c.name = v_case.category_name
        ORDER BY r.rental_date, r.rental_id
        LIMIT 1;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Test setup failed: no rental found for category %', v_case.category_name;
        END IF;
    END LOOP;

    FOR v_case IN
        SELECT *
        FROM (VALUES ('Comedy', 10.00),
                     ('Horror',  0.00),
                     ('Drama',   0.00)) AS t(category_name, expected_delta)
    LOOP
        v_index := v_index + 1;
        v_delta := COALESCE(
            (SELECT total_sales_revenue
             FROM core.sales_revenue_by_category_qtr
             WHERE category = v_case.category_name), 0) - v_before[v_index];

        IF v_delta <> v_case.expected_delta THEN
            RAISE EXCEPTION 'View test FAILED for %: expected change %, got %',
                v_case.category_name, v_case.expected_delta, v_delta;
        END IF;

        RAISE NOTICE 'View test passed for %: revenue changed by %', v_case.category_name, v_delta;
    END LOOP;

    -- A category with zero sales must be absent, not listed with a total of 0.
    -- (If Drama had no other sales, only its 0.00 payment exists at this point.)
    IF EXISTS (SELECT 1
               FROM core.sales_revenue_by_category_qtr
               WHERE total_sales_revenue <= 0) THEN
        RAISE EXCEPTION 'View test FAILED: a zero-sales category is displayed';
    END IF;

    RAISE NOTICE 'View test passed: no zero-sales category is displayed';

    RAISE EXCEPTION USING ERRCODE = 'ZZ001', MESSAGE = 'rollback of test data';
EXCEPTION
    WHEN SQLSTATE 'ZZ001' THEN
        RAISE NOTICE 'Test data and temporary partitions were rolled back';
END
$test$;


/*
 TASK 2. SQL FUNCTION core.get_sales_revenue_by_category_qtr(p_period_date)

 Why a parameter: to report any quarter, not only the current one. One DATE
   holds both year and quarter; any day in the quarter works. It is optional
   (default CURRENT_DATE, same result as the view).
 Calculation: same logic as the view, with p_period_date instead of today.
 Invalid input: '2017-13-01', '2017-Q5' or 'abc' cannot become a DATE, and a
   number such as 5 matches no function; PostgreSQL raises an error.
 NULL: returns 0 rows (LANGUAGE sql has no RAISE EXCEPTION).
 No data (also a future quarter or missing related rows): 0 rows, no error.
*/
CREATE OR REPLACE FUNCTION core.get_sales_revenue_by_category_qtr(
    p_period_date date DEFAULT CURRENT_DATE
)
RETURNS TABLE (category text, total_sales_revenue numeric)
LANGUAGE sql
STABLE
AS $function$
    SELECT c.name        AS category,
           SUM(p.amount) AS total_sales_revenue
    FROM public.payment       AS p
    JOIN public.rental        AS r  ON r.rental_id     = p.rental_id
    JOIN public.inventory     AS i  ON i.inventory_id  = r.inventory_id
    JOIN public.film_category AS fc ON fc.film_id      = i.film_id
    JOIN public.category      AS c  ON c.category_id   = fc.category_id
    WHERE p.payment_date >= date_trunc('quarter', p_period_date)
      AND p.payment_date <  date_trunc('quarter', p_period_date) + INTERVAL '3 months'
    GROUP BY c.category_id, c.name
    HAVING SUM(p.amount) > 0
    ORDER BY 2 DESC, 1;
$function$;

-- Test 2A (valid): Q1 2017, highest revenue first.
SELECT * FROM core.get_sales_revenue_by_category_qtr(DATE '2017-02-15');

-- Test 2B (default parameter): expected 0 differences from the view.
SELECT COUNT(*) AS differences_from_view
FROM (
    (SELECT * FROM core.get_sales_revenue_by_category_qtr()
     EXCEPT
     SELECT * FROM core.sales_revenue_by_category_qtr)
    UNION ALL
    (SELECT * FROM core.sales_revenue_by_category_qtr
     EXCEPT
     SELECT * FROM core.get_sales_revenue_by_category_qtr())
) AS diff;

-- Test 2C (edge): a quarter without data. Expected: 0 rows, no error.
SELECT * FROM core.get_sales_revenue_by_category_qtr(DATE '1999-05-10');

-- Test 2D (invalid): both values fail the conversion to DATE.
DO $test$
DECLARE
    v_bad_value text;
BEGIN
    FOREACH v_bad_value IN ARRAY ARRAY['2017-13-01', '2017-Q5']
    LOOP
        BEGIN
            PERFORM * FROM core.get_sales_revenue_by_category_qtr(v_bad_value::date);
            RAISE EXCEPTION 'Test FAILED: "%" was accepted', v_bad_value;
        EXCEPTION
            WHEN datetime_field_overflow OR invalid_datetime_format THEN
                RAISE NOTICE 'Expected error for "%": %', v_bad_value, SQLERRM;
        END;
    END LOOP;
END
$test$;


/*
 TASK 3. FUNCTION core.most_popular_films_by_countries(p_countries)

 Most popular: the most rentals by customers living in the country. A rental
   shows the customer's choice, while revenue depends on prices and fees.
   COUNT(DISTINCT rental_id) avoids double counting if a rental has several
   payments.
 Ties: one film per country (DISTINCT ON), ordered by rentals, then revenue
   (both highest first), then title and film_id.
 Input: case and outer spaces are ignored; repeated names give one row. Results
   are sorted by country.
 Incorrect input: NULL or empty array, NULL or blank name, or unknown country
   -> RAISE EXCEPTION.
 No data: a known country without rentals (or without the related city, address
   or customer rows) gets a NOTICE and no result row; other countries are still
   returned. A rental without payment counts, with revenue 0.
*/
CREATE OR REPLACE FUNCTION core.most_popular_films_by_countries(
    p_countries text[]
)
RETURNS TABLE (
    country      text,
    film         text,
    rating       text,
    language     text,
    length       smallint,
    release_year integer
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_unknown      text;
    v_without_data text;
BEGIN
    IF p_countries IS NULL OR cardinality(p_countries) = 0 THEN
        RAISE EXCEPTION 'The list of countries must not be NULL or empty'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF EXISTS (SELECT 1
               FROM unnest(p_countries) AS u(country_name)
               WHERE u.country_name IS NULL OR btrim(u.country_name) = '') THEN
        RAISE EXCEPTION 'The list of countries must not contain NULL or blank values'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT string_agg(DISTINCT u.country_name, ', ')
    INTO v_unknown
    FROM unnest(p_countries) AS u(country_name)
    WHERE NOT EXISTS (SELECT 1
                      FROM public.country AS co
                      WHERE lower(co.country) = lower(btrim(u.country_name)));

    IF v_unknown IS NOT NULL THEN
        RAISE EXCEPTION 'Unknown country: %', v_unknown
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT string_agg(co.country, ', ' ORDER BY co.country)
    INTO v_without_data
    FROM public.country AS co
    WHERE lower(co.country) IN (SELECT lower(btrim(u.country_name))
                                FROM unnest(p_countries) AS u(country_name))
      AND NOT EXISTS (SELECT 1
                      FROM public.city     AS ci
                      JOIN public.address  AS a  ON a.city_id      = ci.city_id
                      JOIN public.customer AS cu ON cu.address_id  = a.address_id
                      JOIN public.rental   AS r  ON r.customer_id  = cu.customer_id
                      WHERE ci.country_id = co.country_id);

    IF v_without_data IS NOT NULL THEN
        RAISE NOTICE 'No rental data for: %', v_without_data;
    END IF;

    RETURN QUERY
    WITH requested AS (
        SELECT co.country_id,
               co.country AS country_name
        FROM public.country AS co
        WHERE lower(co.country) IN (SELECT lower(btrim(u.country_name))
                                    FROM unnest(p_countries) AS u(country_name))
    ),
    film_stats AS (
        SELECT rq.country_id,
               rq.country_name,
               i.film_id,
               COUNT(DISTINCT r.rental_id) AS rental_count,
               COALESCE(SUM(p.amount), 0)  AS revenue
        FROM requested            AS rq
        JOIN public.city          AS ci ON ci.country_id  = rq.country_id
        JOIN public.address       AS a  ON a.city_id      = ci.city_id
        JOIN public.customer      AS cu ON cu.address_id  = a.address_id
        JOIN public.rental        AS r  ON r.customer_id  = cu.customer_id
        JOIN public.inventory     AS i  ON i.inventory_id = r.inventory_id
        LEFT JOIN public.payment  AS p  ON p.rental_id    = r.rental_id
        GROUP BY rq.country_id, rq.country_name, i.film_id
    ),
    top_films AS (
        SELECT DISTINCT ON (fs.country_id)
               fs.country_name,
               f.title,
               f.rating::text        AS film_rating,
               btrim(l.name)         AS language_name,
               f.length              AS film_length,
               f.release_year::integer AS film_release_year
        FROM film_stats      AS fs
        JOIN public.film     AS f ON f.film_id     = fs.film_id
        JOIN public.language AS l ON l.language_id = f.language_id
        ORDER BY fs.country_id,
                 fs.rental_count DESC,
                 fs.revenue DESC,
                 f.title,
                 f.film_id
    )
    SELECT tf.country_name,
           tf.title,
           tf.film_rating,
           tf.language_name,
           tf.film_length,
           tf.film_release_year
    FROM top_films AS tf
    ORDER BY tf.country_name;
END
$function$;

-- Test 3A (valid). Expected: 3 rows, one film for each country.
SELECT * FROM core.most_popular_films_by_countries(ARRAY['Afghanistan', 'Brazil', 'United States']);

-- Test 3B (edge): other letter case, extra spaces and a repeated name.
-- Expected: 1 row for Brazil.
SELECT * FROM core.most_popular_films_by_countries(ARRAY['brazil', '  BRAZIL ']);

-- Test 3C (missing data): Australia is in the country table, but in the default
-- database it has no rentals. Expected: a NOTICE and a row for Brazil only.
SELECT * FROM core.most_popular_films_by_countries(ARRAY['Australia', 'Brazil']);

-- Test 3D (invalid): unknown country, empty array, NULL.
-- Expected: every call raises an exception.
DO $test$
BEGIN
    BEGIN
        PERFORM * FROM core.most_popular_films_by_countries(ARRAY['Brazil', 'Narnia']);
        RAISE EXCEPTION 'Test FAILED: unknown country was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;

    BEGIN
        PERFORM * FROM core.most_popular_films_by_countries(ARRAY[]::text[]);
        RAISE EXCEPTION 'Test FAILED: empty array was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;

    BEGIN
        PERFORM * FROM core.most_popular_films_by_countries(NULL);
        RAISE EXCEPTION 'Test FAILED: NULL was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;
END
$test$;


/*
 TASK 4. FUNCTION core.films_in_stock_by_title(p_title_pattern)

 Result: one row per matching film with a copy in stock (no rental of that copy
   has return_date IS NULL; never-rented copies count). Customer and date show
   the latest rental among the available copies, or NULL if never rented.
   row_num is a counter starting at 1, in title order.
 Pattern: % = any number of characters, _ = exactly one. '%love%' matches
   anywhere (also "Glove"). Without any %, the function adds % on both sides.
 Case: LIKE is case-sensitive, so ILIKE (case-insensitive) is used.
 May be slow on large data: a leading % cannot use a normal B-tree index, so
   films are scanned; rental history lookups can also be costly. A pg_trgm GIN
   index on title and an index on inventory(film_id) would help (not created,
   to leave the base tables unchanged).
 Less processing: availability and history are needed only for matching titles;
   EXISTS stops at the first match; LIMIT 1 keeps one latest rental per film;
   inventory_in_stock() is not called for each copy.
 Multiple matches: all are returned, numbered 1..N.
 No matches or none in stock: one "not found" message row; other columns NULL.
 Incorrect input: NULL, blank or only % -> RAISE EXCEPTION.
 Missing rental history: the film is listed with NULL customer and date.
*/
CREATE OR REPLACE FUNCTION core.films_in_stock_by_title(
    p_title_pattern text
)
RETURNS TABLE (
    row_num       bigint,
    film_title    text,
    language      text,
    customer_name text,
    rental_date   timestamptz
)
LANGUAGE plpgsql
STABLE
AS $function$
DECLARE
    v_pattern text;
    v_row_num bigint := 0;
    v_film    record;
BEGIN
    IF p_title_pattern IS NULL OR btrim(p_title_pattern, ' %') = '' THEN
        RAISE EXCEPTION 'The title pattern must contain at least one character other than %% and space'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    v_pattern := btrim(p_title_pattern);

    IF strpos(v_pattern, '%') = 0 THEN
        v_pattern := '%' || v_pattern || '%';
    END IF;

    FOR v_film IN
        SELECT f.title,
               btrim(l.name) AS language_name,
               last_rental.renter_name,
               last_rental.rented_at
        FROM public.film     AS f
        JOIN public.language AS l ON l.language_id = f.language_id
        LEFT JOIN LATERAL (
            SELECT cu.first_name || ' ' || cu.last_name AS renter_name,
                   r.rental_date                        AS rented_at
            FROM public.inventory AS i
            JOIN public.rental    AS r  ON r.inventory_id = i.inventory_id
            JOIN public.customer  AS cu ON cu.customer_id = r.customer_id
            WHERE i.film_id = f.film_id
              AND NOT EXISTS (SELECT 1
                              FROM public.rental AS open_rental
                              WHERE open_rental.inventory_id = i.inventory_id
                                AND open_rental.return_date IS NULL)
            ORDER BY r.rental_date DESC, r.rental_id DESC
            LIMIT 1
        ) AS last_rental ON TRUE
        WHERE f.title ILIKE v_pattern
          AND EXISTS (SELECT 1
                      FROM public.inventory AS i
                      WHERE i.film_id = f.film_id
                        AND NOT EXISTS (SELECT 1
                                        FROM public.rental AS open_rental
                                        WHERE open_rental.inventory_id = i.inventory_id
                                          AND open_rental.return_date IS NULL))
        ORDER BY f.title, f.film_id
    LOOP
        v_row_num     := v_row_num + 1;
        row_num       := v_row_num;
        film_title    := v_film.title;
        language      := v_film.language_name;
        customer_name := v_film.renter_name;
        rental_date   := v_film.rented_at;
        RETURN NEXT;
    END LOOP;

    IF v_row_num = 0 THEN
        row_num       := NULL;
        film_title    := format('No film matching "%s" was found in stock', v_pattern);
        language      := NULL;
        customer_name := NULL;
        rental_date   := NULL;
        RETURN NEXT;
    END IF;
END
$function$;

-- Test 4A (valid, multiple matches). Expected: all films in stock with "love"
-- in the title, numbered from 1.
SELECT * FROM core.films_in_stock_by_title('%love%');

-- Test 4B (edge): upper case and no % signs. Expected: the same rows as 4A.
SELECT * FROM core.films_in_stock_by_title('LOVE');

-- Test 4C (no matches). Expected: one row with the "not found" message.
SELECT * FROM core.films_in_stock_by_title('%no such movie%');

-- Test 4D (invalid): only wildcards, then NULL. Expected: exceptions.
DO $test$
BEGIN
    BEGIN
        PERFORM * FROM core.films_in_stock_by_title('%%');
        RAISE EXCEPTION 'Test FAILED: wildcard-only pattern was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;

    BEGIN
        PERFORM * FROM core.films_in_stock_by_title(NULL);
        RAISE EXCEPTION 'Test FAILED: NULL was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;
END
$test$;


/*
 TASK 5. FUNCTION core.new_movie(p_title, p_release_year, p_language_name)

 Logic: inserts a film (rate 4.99, duration 3 days, replacement cost 19.99,
   set explicitly) and returns its ID. Year and language are optional (current
   year, 'Klingon'). Klingon is missing by default, so it is added once below.
 Unique ID: the film_id default uses a sequence, which is safe for concurrent
   sessions (unlike MAX + 1); RETURNING gives the value.
 No duplicates: titles are compared trimmed and case-insensitively, for any
   year or language. An advisory lock on the title makes concurrent calls wait
   (default READ COMMITTED). film.title has no UNIQUE constraint, so a direct
   INSERT is not protected.
 Movie exists: RAISE EXCEPTION (unique_violation); nothing changes.
 Language: looked up by name (trimmed, any case); if not found, including a
   missing Klingon row, RAISE EXCEPTION. The function does not create it.
 Incorrect input: NULL or blank title or language, or year NULL or outside
   1901-2155 -> RAISE EXCEPTION. A non-numeric year is rejected by PostgreSQL.
 Failed insert and consistency: errors reach the caller (no WHEN OTHERS) and
   the failed call changes no rows. Foreign key, NOT NULL and year domain rules
   apply; a trigger fills fulltext.
*/
INSERT INTO public.language (name)
SELECT 'Klingon'
WHERE NOT EXISTS (SELECT 1
                  FROM public.language
                  WHERE lower(btrim(name)) = 'klingon');

CREATE OR REPLACE FUNCTION core.new_movie(
    p_title         text,
    p_release_year  integer DEFAULT EXTRACT(YEAR FROM CURRENT_DATE)::integer,
    p_language_name text    DEFAULT 'Klingon'
)
RETURNS integer
LANGUAGE plpgsql
VOLATILE
AS $function$
DECLARE
    v_title       text := btrim(p_title);
    v_language_id public.language.language_id%TYPE;
    v_film_id     public.film.film_id%TYPE;
BEGIN
    IF v_title IS NULL OR v_title = '' THEN
        RAISE EXCEPTION 'Movie title must not be NULL or blank'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_release_year IS NULL OR p_release_year NOT BETWEEN 1901 AND 2155 THEN
        RAISE EXCEPTION 'Release year must be between 1901 and 2155, got %',
            COALESCE(p_release_year::text, 'NULL')
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_language_name IS NULL OR btrim(p_language_name) = '' THEN
        RAISE EXCEPTION 'Language name must not be NULL or blank'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT l.language_id
    INTO v_language_id
    FROM public.language AS l
    WHERE lower(btrim(l.name)) = lower(btrim(p_language_name))
    ORDER BY l.language_id
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Language "%" does not exist in the language table', btrim(p_language_name)
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('core.new_movie'), hashtext(lower(v_title)));

    IF EXISTS (SELECT 1
               FROM public.film AS f
               WHERE lower(btrim(f.title)) = lower(v_title)) THEN
        RAISE EXCEPTION 'Movie "%" already exists', v_title
            USING ERRCODE = 'unique_violation';
    END IF;

    INSERT INTO public.film (title, release_year, language_id,
                             rental_duration, rental_rate, replacement_cost)
    VALUES (v_title, p_release_year, v_language_id,
            3, 4.99, 19.99)
    RETURNING film_id INTO v_film_id;

    RETURN v_film_id;
END
$function$;

-- Test 5A (valid, default year and language). Expected: one new film with the
-- current year, Klingon, 4.99, 3 days and 19.99. Rolled back afterwards.
BEGIN;
SELECT core.new_movie('Homework Test Movie Alpha');

SELECT f.film_id, f.title, f.release_year, btrim(l.name) AS language,
       f.rental_rate, f.rental_duration, f.replacement_cost
FROM public.film     AS f
JOIN public.language AS l ON l.language_id = f.language_id
WHERE f.title = 'Homework Test Movie Alpha';
ROLLBACK;

-- Test 5B (valid, optional parameters): both values by position, then only the
-- language by name. Expected: 2001 / English, and current year / French.
BEGIN;
SELECT core.new_movie('Homework Test Movie Beta', 2001, 'english');
SELECT core.new_movie('Homework Test Movie Gamma', p_language_name => 'French');

SELECT f.title, f.release_year, btrim(l.name) AS language
FROM public.film     AS f
JOIN public.language AS l ON l.language_id = f.language_id
WHERE f.title IN ('Homework Test Movie Beta', 'Homework Test Movie Gamma')
ORDER BY f.title;
ROLLBACK;

-- Test 5C (duplicate and invalid input). Expected: every call raises an
-- exception and nothing is inserted. The duplicate check uses a film created
-- inside this block, so it does not depend on the existing films.
DO $test$
BEGIN
    BEGIN
        PERFORM core.new_movie('Homework Duplicate Movie');
        PERFORM core.new_movie('  homework DUPLICATE movie ');
        RAISE EXCEPTION 'Test FAILED: duplicate title was accepted';
    EXCEPTION
        WHEN unique_violation THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;

    BEGIN
        PERFORM core.new_movie('Homework Test Movie Delta', p_language_name => 'Elvish');
        RAISE EXCEPTION 'Test FAILED: unknown language was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;

    BEGIN
        PERFORM core.new_movie('   ');
        RAISE EXCEPTION 'Test FAILED: blank title was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;

    BEGIN
        PERFORM core.new_movie('Homework Test Movie Epsilon', 1800);
        RAISE EXCEPTION 'Test FAILED: invalid year was accepted';
    EXCEPTION
        WHEN invalid_parameter_value THEN RAISE NOTICE 'Expected error: %', SQLERRM;
    END;
END
$test$;

-- Check after the tests. Expected: 0 rows, no test films were left behind.
SELECT title
FROM public.film
WHERE title ILIKE 'Homework %Movie%';
