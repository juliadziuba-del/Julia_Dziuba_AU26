/*
================================================================================
SQL SELECT HW - dvdrental database
================================================================================

GENERAL ASSUMPTIONS / INTERPRETATION OF BUSINESS LOGIC
------------------------------------------------------
* "rate" of a film (Part 1, task 1) = film.rental_rate (the only rate-like
  numeric column in film). "rate more than 1" => rental_rate > 1.
* "between 2017 and 2019" is inclusive on both ends (release_year BETWEEN 2017 AND 2019).
* "since 2015" => release_year >= 2015.
* "after March 2017 (since April)" => payment_date >= '2017-04-01'.
  Revenue = SUM(payment.amount). A payment belongs to the store that owns the
  rented copy: payment -> rental -> inventory -> store.
* Store "address and address2 as one column" => CONCAT_WS(', ', address, address2);
  CONCAT_WS skips NULLs (address2 is NULL for some rows), NULLIF turns '' into NULL.
* Top-N lists use a deterministic tie-breaker (name/title) and LIMIT. If several
  rows tie for the last place, only the first one by the tie-breaker is shown.
* Category names ('Animation', 'Drama', ...) are matched by name, IDs are never hardcoded.
* Part 2, task 1: only payment_date is used to decide the year (2017).
  "Store the staff worked in (the last one)" = store of the staff's LAST payment
  in 2017 (latest payment_date, payment_id as tie-breaker), because if a staff
  member processed a payment, he works in the store that owns the rented
  inventory item (payment -> rental -> inventory.store_id).
* Part 2, task 2: MPA rating -> expected audience age:
    G = all ages, PG = 8+ (parental guidance), PG-13 = 13+,
    R = 17+ (under 17 only with an adult), NC-17 = 18+.
  "Rented more than others" = number of rows in rental (all rentals of any
  inventory copy of the film).
* Part 3: release_year has year precision only, so a "gap" is measured in years.
  - V1: current year (from CURRENT_DATE) - MAX(release_year) of the actor.
  - V2: for each actor the distinct release years are sorted; the gap is the
    difference between two NEIGHBOURING years (no window functions, so the
    neighbour is found with NOT EXISTS / anti-join / MIN of greater year).
    Films of the same year give gap 0 and are ignored (distinct years).
    The report shows the LONGEST gap per actor; actors with just one release
    year have no gap and are not shown.
* INNER JOIN is used wherever a missing match would make the row meaningless
  (a film without category, an actor without films ...). LEFT JOIN is used only
  where rows with no matches must stay (stores without payments, years without
  a given genre). The effect of each join is described in the comments.
* No window functions are used (LIMIT is used only for "top N").

HOW EACH TASK IS DOCUMENTED
---------------------------
Every task is solved 3 times: JOIN, SUBQUERY, CTE. Pros/cons and the
production choice are in the comment block above the three queries.
================================================================================
*/


/*
================================================================================
PART 1
================================================================================
*/

-- ----------------------------------------------------------------------------
-- TASK 1.1
-- The marketing team needs a list of animation movies between 2017 and 2019 to
-- promote family-friendly content in an upcoming season in stores. Show all
-- animation movies released during this period with rate more than 1, sorted
-- alphabetically.
--
-- JOIN:     + simplest, most readable, optimizer is free to reorder joins;
--           - a film in many categories would be repeated (not the case when
--             filtering on one category, still true for the join shape).
-- SUBQUERY: + no duplicates possible by design (IN), shows the logic
--             "film belongs to Animation";
--           - nested, harder to read; the category part is hidden from output.
-- CTE:      + named step (animation_films) is readable and reusable;
--           - for a single use brings nothing over JOIN (in PostgreSQL 12+
--             a simple CTE is inlined, so performance is the same).
-- PRODUCTION: JOIN - shortest, clear, and the planner optimises it best.
-- ----------------------------------------------------------------------------

-- Q1.1 JOIN
-- INNER JOIN film_category / category: films without a category (or categories
-- other than Animation) disappear from the result - exactly what we want.
SELECT f.title,
       f.release_year,
       f.rental_rate
FROM public.film AS f
INNER JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
INNER JOIN public.category AS c
    ON c.category_id = fc.category_id
WHERE c.name = 'Animation'
  AND f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
ORDER BY f.title;

-- Q1.1 SUBQUERY
SELECT f.title,
       f.release_year,
       f.rental_rate
FROM public.film AS f
WHERE f.film_id IN (SELECT fc.film_id
                    FROM public.film_category AS fc
                    WHERE fc.category_id IN (SELECT c.category_id
                                             FROM public.category AS c
                                             WHERE c.name = 'Animation'))
  AND f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
ORDER BY f.title;

-- Q1.1 CTE
-- INNER JOIN inside the CTE keeps only films that have the Animation category.
WITH animation_films AS (
    SELECT fc.film_id
    FROM public.film_category AS fc
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name = 'Animation'
)
SELECT f.title,
       f.release_year,
       f.rental_rate
FROM public.film AS f
INNER JOIN animation_films AS af
    ON af.film_id = f.film_id
WHERE f.release_year BETWEEN 2017 AND 2019
  AND f.rental_rate > 1
ORDER BY f.title;


-- ----------------------------------------------------------------------------
-- TASK 1.2
-- The finance department requires a report on store performance to assess
-- profitability and plan resource allocation for stores after March 2017.
-- Calculate the revenue earned by each rental store after March 2017 (since
-- April) (include columns: address and address2 - as one column, revenue).
--
-- JOIN:     + one pass, everything visible in one place;
--           - big join chain (store-inventory-rental-payment) and the date
--             filter must sit in the ON clause of the LEFT JOIN, otherwise the
--             LEFT JOIN silently becomes an INNER JOIN (easy mistake).
-- SUBQUERY: + correlated scalar subquery is easy to read, store always shown;
--           - executed once per store (fine for few stores, bad for thousands).
-- CTE:      + aggregate first (small result), then join to store/address:
--           the cheapest shape for big data and the easiest to debug;
--           - one more named block.
-- PRODUCTION: CTE - aggregation on the fact table first, then dimensions.
-- ----------------------------------------------------------------------------

-- Q1.2 JOIN
-- LEFT JOIN from store: a store without any payment after March 2017 is still
-- returned with revenue 0 (COALESCE). With INNER JOIN it would be dropped.
SELECT CONCAT_WS(', ', a.address, NULLIF(a.address2, '')) AS address,
       COALESCE(SUM(p.amount), 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
LEFT JOIN public.inventory AS i
    ON i.store_id = s.store_id
LEFT JOIN public.rental AS r
    ON r.inventory_id = i.inventory_id
LEFT JOIN public.payment AS p
    ON p.rental_id = r.rental_id
   AND p.payment_date >= DATE '2017-04-01'
GROUP BY s.store_id, a.address, a.address2
ORDER BY revenue DESC;

-- Q1.2 SUBQUERY
SELECT CONCAT_WS(', ', a.address, NULLIF(a.address2, '')) AS address,
       (SELECT COALESCE(SUM(p.amount), 0)
        FROM public.payment AS p
        INNER JOIN public.rental AS r
            ON r.rental_id = p.rental_id
        INNER JOIN public.inventory AS i
            ON i.inventory_id = r.inventory_id
        WHERE i.store_id = s.store_id
          AND p.payment_date >= DATE '2017-04-01') AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
ORDER BY revenue DESC;

-- Q1.2 CTE
-- INNER JOINs inside the CTE: only payments that really have rental/inventory.
-- LEFT JOIN of the CTE to store keeps stores without revenue (revenue = 0).
WITH store_revenue AS (
    SELECT i.store_id,
           SUM(p.amount) AS revenue
    FROM public.payment AS p
    INNER JOIN public.rental AS r
        ON r.rental_id = p.rental_id
    INNER JOIN public.inventory AS i
        ON i.inventory_id = r.inventory_id
    WHERE p.payment_date >= DATE '2017-04-01'
    GROUP BY i.store_id
)
SELECT CONCAT_WS(', ', a.address, NULLIF(a.address2, '')) AS address,
       COALESCE(sr.revenue, 0) AS revenue
FROM public.store AS s
INNER JOIN public.address AS a
    ON a.address_id = s.address_id
LEFT JOIN store_revenue AS sr
    ON sr.store_id = s.store_id
ORDER BY revenue DESC;


-- ----------------------------------------------------------------------------
-- TASK 1.3
-- The marketing department in our stores aims to identify the most successful
-- actors since 2015 to boost customer interest in their films. Show top-5
-- actors by number of movies (released since 2015) they took part in
-- (columns: first_name, last_name, number_of_movies, sorted by
-- number_of_movies in descending order).
--
-- JOIN:     + one aggregate, the planner can use the best join order;
--           - GROUP BY must contain actor_id too (two actors can share a name).
-- SUBQUERY: + no GROUP BY in the outer query, logic "count films of this
--             actor" is very explicit;
--           - correlated: runs once per actor (200 times), slowest for big data.
-- CTE:      + filters films first, then counts - steps are named and testable;
--           - more text than the JOIN.
-- PRODUCTION: JOIN (or CTE when the film filter becomes more complex).
-- ----------------------------------------------------------------------------

-- Q1.3 JOIN
-- INNER JOINs: actors with no film since 2015 are not returned (count would be 0
-- and they cannot reach the top 5 anyway).
SELECT a.first_name,
       a.last_name,
       COUNT(f.film_id) AS number_of_movies
FROM public.actor AS a
INNER JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
INNER JOIN public.film AS f
    ON f.film_id = fa.film_id
WHERE f.release_year >= 2015
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY number_of_movies DESC, a.last_name, a.first_name
LIMIT 5;

-- Q1.3 SUBQUERY
SELECT a.first_name,
       a.last_name,
       (SELECT COUNT(*)
        FROM public.film_actor AS fa
        WHERE fa.actor_id = a.actor_id
          AND fa.film_id IN (SELECT f.film_id
                             FROM public.film AS f
                             WHERE f.release_year >= 2015)) AS number_of_movies
FROM public.actor AS a
ORDER BY number_of_movies DESC, a.last_name, a.first_name
LIMIT 5;

-- Q1.3 CTE
WITH recent_films AS (
    SELECT f.film_id
    FROM public.film AS f
    WHERE f.release_year >= 2015
),
actor_movies AS (
    SELECT fa.actor_id,
           COUNT(*) AS number_of_movies
    FROM public.film_actor AS fa
    INNER JOIN recent_films AS rf
        ON rf.film_id = fa.film_id
    GROUP BY fa.actor_id
)
SELECT a.first_name,
       a.last_name,
       am.number_of_movies
FROM actor_movies AS am
INNER JOIN public.actor AS a
    ON a.actor_id = am.actor_id
ORDER BY am.number_of_movies DESC, a.last_name, a.first_name
LIMIT 5;


-- ----------------------------------------------------------------------------
-- TASK 1.4
-- The marketing team needs to track the production trends of Drama, Travel, and
-- Documentary films to inform genre-specific marketing strategies. Show number
-- of Drama, Travel, Documentary per year (include columns: release_year,
-- number_of_drama_movies, number_of_travel_movies,
-- number_of_documentary_movies), sorted by release year in descending order.
-- Dealing with NULL values is encouraged.
--
-- JOIN:     + one scan of the data, conditional aggregation (COUNT(CASE ...))
--             gives all three columns at once; LEFT JOINs keep years where a
--             genre does not exist and COUNT turns "no match" into 0 (not NULL);
--           - CASE-based pivot is less obvious for beginners.
-- SUBQUERY: + each column is a separate, easy-to-read scalar subquery;
--           - 3 correlated subqueries per year = 3 scans of film/category
--             per year, most expensive; adding a genre means a new subquery.
-- CTE:      + genre rows are prepared once, then pivoted; clear steps;
--           - needs a "years" list to keep years with no such genre.
-- PRODUCTION: JOIN with conditional aggregation (single pass, easy to extend).
-- ----------------------------------------------------------------------------

-- Q1.4 JOIN
-- LEFT JOIN film_category / category: a film that is not in these genres (or has
-- no category) still counts as a year row, so the year is not lost; the
-- genre counters are 0 for it. COUNT(CASE ...) ignores NULLs => 0, never NULL.
SELECT f.release_year,
       COUNT(CASE WHEN c.name = 'Drama' THEN 1 END)       AS number_of_drama_movies,
       COUNT(CASE WHEN c.name = 'Travel' THEN 1 END)      AS number_of_travel_movies,
       COUNT(CASE WHEN c.name = 'Documentary' THEN 1 END) AS number_of_documentary_movies
FROM public.film AS f
LEFT JOIN public.film_category AS fc
    ON fc.film_id = f.film_id
LEFT JOIN public.category AS c
    ON c.category_id = fc.category_id
GROUP BY f.release_year
ORDER BY f.release_year DESC;

-- Q1.4 SUBQUERY
-- The derived table of distinct years guarantees every year is listed;
-- COUNT(*) in a scalar subquery returns 0 (not NULL) when nothing matches.
SELECT y.release_year,
       (SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE f.release_year = y.release_year
          AND c.name = 'Drama') AS number_of_drama_movies,
       (SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE f.release_year = y.release_year
          AND c.name = 'Travel') AS number_of_travel_movies,
       (SELECT COUNT(*)
        FROM public.film AS f
        INNER JOIN public.film_category AS fc
            ON fc.film_id = f.film_id
        INNER JOIN public.category AS c
            ON c.category_id = fc.category_id
        WHERE f.release_year = y.release_year
          AND c.name = 'Documentary') AS number_of_documentary_movies
FROM (SELECT DISTINCT f.release_year
      FROM public.film AS f) AS y
ORDER BY y.release_year DESC;

-- Q1.4 CTE
-- INNER JOINs in genre_films keep only films of the 3 genres; the LEFT JOIN
-- from the years list brings back years without any of them (counters = 0).
WITH years AS (
    SELECT DISTINCT f.release_year
    FROM public.film AS f
),
genre_films AS (
    SELECT f.release_year,
           c.name AS genre
    FROM public.film AS f
    INNER JOIN public.film_category AS fc
        ON fc.film_id = f.film_id
    INNER JOIN public.category AS c
        ON c.category_id = fc.category_id
    WHERE c.name IN ('Drama', 'Travel', 'Documentary')
)
SELECT y.release_year,
       COUNT(CASE WHEN g.genre = 'Drama' THEN 1 END)       AS number_of_drama_movies,
       COUNT(CASE WHEN g.genre = 'Travel' THEN 1 END)      AS number_of_travel_movies,
       COUNT(CASE WHEN g.genre = 'Documentary' THEN 1 END) AS number_of_documentary_movies
FROM years AS y
LEFT JOIN genre_films AS g
    ON g.release_year = y.release_year
GROUP BY y.release_year
ORDER BY y.release_year DESC;


/*
================================================================================
PART 2
================================================================================
*/

-- ----------------------------------------------------------------------------
-- TASK 2.1
-- The HR department aims to reward top-performing employees in 2017 with
-- bonuses to recognize their contribution to stores revenue. Show which three
-- employees generated the most revenue in 2017?
-- Assumptions:
--  * staff could work in several stores in a year, please indicate which store
--    the staff worked in (the last one);
--  * if staff processed the payment then he works in the same store;
--  * take into account only payment_date.
--
-- (top-3 ties are broken by staff_id; see the assumptions at the top: store = store of the staff's last 2017
--  payment, found via payment -> rental -> inventory.store_id)
--
-- JOIN:     + pure joins; "last payment" found with an anti-join (no later
--             payment exists for the same staff);
--           - hardest to read, the anti-join (LEFT JOIN ... IS NULL) is
--             quadratic per staff member - slow on big payment tables.
-- SUBQUERY: + each column answers one question (last store / revenue);
--           ORDER BY ... LIMIT 1 in a subquery is a simple "last row";
--           - correlated subqueries run per staff (few staff = fine).
-- CTE:      + revenue and last-payment steps are separate, named, testable;
--           the best readability, linear amount of work;
--           - more lines.
-- PRODUCTION: CTE - each business rule is one named step.
-- ----------------------------------------------------------------------------

-- Q2.1 JOIN
-- p      = all 2017 payments of the staff member (used for revenue).
-- lp     = the LAST 2017 payment of the same staff member; the LEFT JOIN to
--          "later" + WHERE later.payment_id IS NULL leaves only the row for
--          which no later payment exists (so one row per staff, no duplication
--          of the SUM).
-- INNER JOINs: a staff member without a payment in 2017 is not in the result.
SELECT s.staff_id,
       s.first_name,
       s.last_name,
       il.store_id AS last_store_id,
       SUM(p.amount) AS revenue
FROM public.staff AS s
INNER JOIN public.payment AS p
    ON p.staff_id = s.staff_id
   AND p.payment_date >= DATE '2017-01-01'
   AND p.payment_date <  DATE '2018-01-01'
INNER JOIN public.payment AS lp
    ON lp.staff_id = s.staff_id
   AND lp.payment_date >= DATE '2017-01-01'
   AND lp.payment_date <  DATE '2018-01-01'
LEFT JOIN public.payment AS later
    ON later.staff_id = lp.staff_id
   AND later.payment_date >= DATE '2017-01-01'
   AND later.payment_date <  DATE '2018-01-01'
   AND (later.payment_date > lp.payment_date
        OR (later.payment_date = lp.payment_date AND later.payment_id > lp.payment_id))
INNER JOIN public.rental AS rl
    ON rl.rental_id = lp.rental_id
INNER JOIN public.inventory AS il
    ON il.inventory_id = rl.inventory_id
WHERE later.payment_id IS NULL
GROUP BY s.staff_id, s.first_name, s.last_name, il.store_id
ORDER BY revenue DESC, s.staff_id
LIMIT 3;

-- Q2.1 SUBQUERY
SELECT s.staff_id,
       s.first_name,
       s.last_name,
       (SELECT i.store_id
        FROM public.payment AS p
        INNER JOIN public.rental AS r
            ON r.rental_id = p.rental_id
        INNER JOIN public.inventory AS i
            ON i.inventory_id = r.inventory_id
        WHERE p.staff_id = s.staff_id
          AND p.payment_date >= DATE '2017-01-01'
          AND p.payment_date <  DATE '2018-01-01'
        ORDER BY p.payment_date DESC, p.payment_id DESC
        LIMIT 1) AS last_store_id,
       (SELECT SUM(p.amount)
        FROM public.payment AS p
        WHERE p.staff_id = s.staff_id
          AND p.payment_date >= DATE '2017-01-01'
          AND p.payment_date <  DATE '2018-01-01') AS revenue
FROM public.staff AS s
WHERE EXISTS (SELECT 1
              FROM public.payment AS p
              WHERE p.staff_id = s.staff_id
                AND p.payment_date >= DATE '2017-01-01'
                AND p.payment_date <  DATE '2018-01-01')
ORDER BY revenue DESC, s.staff_id
LIMIT 3;

-- Q2.1 CTE
-- INNER JOIN of staff to both CTEs: staff with no 2017 payments are excluded.
WITH payments_2017 AS (
    SELECT p.payment_id,
           p.staff_id,
           p.rental_id,
           p.amount,
           p.payment_date
    FROM public.payment AS p
    WHERE p.payment_date >= DATE '2017-01-01'
      AND p.payment_date <  DATE '2018-01-01'
),
staff_revenue AS (
    SELECT p.staff_id,
           SUM(p.amount) AS revenue
    FROM payments_2017 AS p
    GROUP BY p.staff_id
),
staff_last_date AS (
    SELECT p.staff_id,
           MAX(p.payment_date) AS last_payment_date
    FROM payments_2017 AS p
    GROUP BY p.staff_id
),
staff_last_payment AS (
    SELECT p.staff_id,
           MAX(p.payment_id) AS payment_id
    FROM payments_2017 AS p
    INNER JOIN staff_last_date AS sld
        ON sld.staff_id = p.staff_id
       AND sld.last_payment_date = p.payment_date
    GROUP BY p.staff_id
)
SELECT s.staff_id,
       s.first_name,
       s.last_name,
       i.store_id AS last_store_id,
       sr.revenue
FROM public.staff AS s
INNER JOIN staff_revenue AS sr
    ON sr.staff_id = s.staff_id
INNER JOIN staff_last_payment AS slp
    ON slp.staff_id = s.staff_id
INNER JOIN public.payment AS lp
    ON lp.payment_id = slp.payment_id
INNER JOIN public.rental AS r
    ON r.rental_id = lp.rental_id
INNER JOIN public.inventory AS i
    ON i.inventory_id = r.inventory_id
ORDER BY sr.revenue DESC, s.staff_id
LIMIT 3;


-- ----------------------------------------------------------------------------
-- TASK 2.2
-- The management team wants to identify the most popular movies and their
-- target audience age groups to optimize marketing efforts. Show which 5
-- movies were rented more than others (number of rentals), and what's the
-- expected age of the audience for these movies? To determine expected age
-- please use 'Motion Picture Association film rating system'.
--
-- JOIN:     + one aggregate over film-inventory-rental; simple;
--           - GROUP BY needs film_id, title and rating.
-- SUBQUERY: + counting is isolated in a scalar subquery;
--           - correlated per film (1000 runs), slowest.
-- CTE:      + count rentals per film first (small result), then add film
--           attributes and the age mapping; clear steps;
--           - longer.
-- NOTE: 4 films tie on 64 rentals for places 3-5; the title decides (alphabetical).
-- PRODUCTION: JOIN, or CTE if the age-mapping / output logic grows.
-- ----------------------------------------------------------------------------

-- Q2.2 JOIN
-- INNER JOINs: films that were never rented (no inventory or no rental) are
-- not returned - they cannot be in the top 5 anyway.
SELECT f.title,
       f.rating,
       CASE f.rating::TEXT
           WHEN 'G'     THEN 'All ages'
           WHEN 'PG'    THEN '8+ (parental guidance suggested)'
           WHEN 'PG-13' THEN '13+ (parents strongly cautioned under 13)'
           WHEN 'R'     THEN '17+ (under 17 only with an adult)'
           WHEN 'NC-17' THEN '18+ (adults only)'
       END AS expected_audience_age,
       COUNT(r.rental_id) AS number_of_rentals
FROM public.film AS f
INNER JOIN public.inventory AS i
    ON i.film_id = f.film_id
INNER JOIN public.rental AS r
    ON r.inventory_id = i.inventory_id
GROUP BY f.film_id, f.title, f.rating
ORDER BY number_of_rentals DESC, f.title
LIMIT 5;

-- Q2.2 SUBQUERY
SELECT f.title,
       f.rating,
       CASE f.rating::TEXT
           WHEN 'G'     THEN 'All ages'
           WHEN 'PG'    THEN '8+ (parental guidance suggested)'
           WHEN 'PG-13' THEN '13+ (parents strongly cautioned under 13)'
           WHEN 'R'     THEN '17+ (under 17 only with an adult)'
           WHEN 'NC-17' THEN '18+ (adults only)'
       END AS expected_audience_age,
       (SELECT COUNT(*)
        FROM public.rental AS r
        WHERE r.inventory_id IN (SELECT i.inventory_id
                                 FROM public.inventory AS i
                                 WHERE i.film_id = f.film_id)) AS number_of_rentals
FROM public.film AS f
ORDER BY number_of_rentals DESC, f.title
LIMIT 5;

-- Q2.2 CTE
WITH film_rentals AS (
    SELECT i.film_id,
           COUNT(r.rental_id) AS number_of_rentals
    FROM public.inventory AS i
    INNER JOIN public.rental AS r
        ON r.inventory_id = i.inventory_id
    GROUP BY i.film_id
)
SELECT f.title,
       f.rating,
       CASE f.rating::TEXT
           WHEN 'G'     THEN 'All ages'
           WHEN 'PG'    THEN '8+ (parental guidance suggested)'
           WHEN 'PG-13' THEN '13+ (parents strongly cautioned under 13)'
           WHEN 'R'     THEN '17+ (under 17 only with an adult)'
           WHEN 'NC-17' THEN '18+ (adults only)'
       END AS expected_audience_age,
       fr.number_of_rentals
FROM film_rentals AS fr
INNER JOIN public.film AS f
    ON f.film_id = fr.film_id
ORDER BY fr.number_of_rentals DESC, f.title
LIMIT 5;


/*
================================================================================
PART 3
Which actors/actresses didn't act for a longer period of time than the others?
================================================================================
*/

-- ----------------------------------------------------------------------------
-- TASK 3 - V1
-- Gap between the latest release_year and the current year per each actor.
-- (the longest inactivity first)
--
-- JOIN:     + one aggregate, shortest; MAX(release_year) per actor;
--           - nothing special; GROUP BY must include actor_id.
-- SUBQUERY: + "latest film year" is an explicit scalar subquery;
--           - correlated (200 runs) and the gap needs a wrapping query
--             because an alias cannot be reused in the same SELECT.
-- CTE:      + step "latest year per actor" is named and reusable;
--           - longer than JOIN for the same result.
-- PRODUCTION: JOIN (simple aggregate, one pass).
-- ----------------------------------------------------------------------------

-- Q3.V1 JOIN
-- INNER JOINs: actors without any film are not returned (no year to compare).
SELECT a.actor_id,
       a.first_name,
       a.last_name,
       MAX(f.release_year) AS latest_release_year,
       EXTRACT(YEAR FROM CURRENT_DATE)::INT - MAX(f.release_year) AS years_inactive
FROM public.actor AS a
INNER JOIN public.film_actor AS fa
    ON fa.actor_id = a.actor_id
INNER JOIN public.film AS f
    ON f.film_id = fa.film_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY years_inactive DESC, a.last_name, a.first_name, a.actor_id;

-- Q3.V1 SUBQUERY
SELECT t.actor_id,
       t.first_name,
       t.last_name,
       t.latest_release_year,
       EXTRACT(YEAR FROM CURRENT_DATE)::INT - t.latest_release_year AS years_inactive
FROM (SELECT a.actor_id,
             a.first_name,
             a.last_name,
             (SELECT MAX(f.release_year)
              FROM public.film AS f
              WHERE f.film_id IN (SELECT fa.film_id
                                  FROM public.film_actor AS fa
                                  WHERE fa.actor_id = a.actor_id)) AS latest_release_year
      FROM public.actor AS a) AS t
WHERE t.latest_release_year IS NOT NULL
ORDER BY years_inactive DESC, t.last_name, t.first_name, t.actor_id;

-- Q3.V1 CTE
WITH actor_latest AS (
    SELECT fa.actor_id,
           MAX(f.release_year) AS latest_release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
    GROUP BY fa.actor_id
)
SELECT a.actor_id,
       a.first_name,
       a.last_name,
       al.latest_release_year,
       EXTRACT(YEAR FROM CURRENT_DATE)::INT - al.latest_release_year AS years_inactive
FROM actor_latest AS al
INNER JOIN public.actor AS a
    ON a.actor_id = al.actor_id
ORDER BY years_inactive DESC, a.last_name, a.first_name, a.actor_id;


-- ----------------------------------------------------------------------------
-- TASK 3 - V2
-- Gaps between sequential films per each actor (longest gap per actor shown,
-- the longest break first). Window functions (LAG) are forbidden, so the
-- "next" release year of an actor is found without them.
--
-- JOIN:     + only joins; the "neighbouring year" is found with an anti-join
--             (no year of the same actor lies between the two);
--           - the hardest to read; self-joins of film_actor/film 3 times,
--             many intermediate rows (pairs of films per actor).
-- SUBQUERY: + "next year = MIN(year) greater than this year" is intuitive;
--           - correlated subquery per (actor, year) row, nested derived table.
-- CTE:      + distinct (actor, year) list is prepared once and reused by the
--             pair-finder and NOT EXISTS - clearest; fewer rows to join;
--           - the self-join on the CTE is still quadratic per actor
--             (in PostgreSQL a CTE used twice is materialised once - good).
-- PRODUCTION: CTE with window function LAG would be the best, but they are not
--             allowed here, so the CTE variant (deduplicated years) is the
--             most readable and cheapest of the three.
-- ----------------------------------------------------------------------------

-- Q3.V2 JOIN
-- fa1/f1 = earlier film, fa2/f2 = later film of the same actor,
-- LEFT JOIN (fa3/f3) = a film of the same actor released between them;
-- WHERE fa3.film_id IS NULL keeps only NEIGHBOURING pairs.
-- INNER JOINs: actors with a single release year have no pair and disappear.
SELECT a.actor_id,
       a.first_name,
       a.last_name,
       MAX(f2.release_year - f1.release_year) AS longest_gap_years
FROM public.actor AS a
INNER JOIN public.film_actor AS fa1
    ON fa1.actor_id = a.actor_id
INNER JOIN public.film AS f1
    ON f1.film_id = fa1.film_id
INNER JOIN public.film_actor AS fa2
    ON fa2.actor_id = a.actor_id
INNER JOIN public.film AS f2
    ON f2.film_id = fa2.film_id
   AND f2.release_year > f1.release_year
LEFT JOIN (public.film_actor AS fa3
           INNER JOIN public.film AS f3
               ON f3.film_id = fa3.film_id)
    ON fa3.actor_id = a.actor_id
   AND f3.release_year > f1.release_year
   AND f3.release_year < f2.release_year
WHERE fa3.film_id IS NULL
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_gap_years DESC, a.last_name, a.first_name, a.actor_id;

-- Q3.V2 SUBQUERY
-- Inner derived table: for every distinct (actor, year) the next year in which
-- the same actor appears (MIN of the greater years); NULL for the last year.
SELECT a.actor_id,
       a.first_name,
       a.last_name,
       MAX(t.next_year - t.release_year) AS longest_gap_years
FROM (SELECT DISTINCT fa.actor_id,
                      f.release_year,
                      (SELECT MIN(f2.release_year)
                       FROM public.film_actor AS fa2
                       INNER JOIN public.film AS f2
                           ON f2.film_id = fa2.film_id
                       WHERE fa2.actor_id = fa.actor_id
                         AND f2.release_year > f.release_year) AS next_year
      FROM public.film_actor AS fa
      INNER JOIN public.film AS f
          ON f.film_id = fa.film_id) AS t
INNER JOIN public.actor AS a
    ON a.actor_id = t.actor_id
WHERE t.next_year IS NOT NULL
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_gap_years DESC, a.last_name, a.first_name, a.actor_id;

-- Q3.V2 CTE
-- NOT EXISTS keeps only neighbouring years (nothing between cur and nxt).
WITH actor_years AS (
    SELECT DISTINCT fa.actor_id,
                    f.release_year
    FROM public.film_actor AS fa
    INNER JOIN public.film AS f
        ON f.film_id = fa.film_id
),
actor_gaps AS (
    SELECT cur.actor_id,
           nxt.release_year - cur.release_year AS gap_years
    FROM actor_years AS cur
    INNER JOIN actor_years AS nxt
        ON nxt.actor_id = cur.actor_id
       AND nxt.release_year > cur.release_year
    WHERE NOT EXISTS (SELECT 1
                      FROM actor_years AS mid
                      WHERE mid.actor_id = cur.actor_id
                        AND mid.release_year > cur.release_year
                        AND mid.release_year < nxt.release_year)
)
SELECT a.actor_id,
       a.first_name,
       a.last_name,
       MAX(g.gap_years) AS longest_gap_years
FROM actor_gaps AS g
INNER JOIN public.actor AS a
    ON a.actor_id = g.actor_id
GROUP BY a.actor_id, a.first_name, a.last_name
ORDER BY longest_gap_years DESC, a.last_name, a.first_name, a.actor_id;
