/* =====================================================================
   SQL_DML_Julia_Dziuba_HW_Task1.sql
   Task: applying TCL & DML statements to the DVD rental database (PostgreSQL)

   General notes
   - Every table is prefixed with its schema name (public.).
   - Every new / updated record gets last_update = current_date.
   - Each sub-task is its own transaction (BEGIN ... COMMIT).
   - No ID is hard-coded: IDs are always looked up with INSERT ... SELECT / sub-selects.
   - The whole script is re-runnable: re-running it does not create duplicates.

   WHY INSERT ... SELECT instead of INSERT ... VALUES (advantage):
   - foreign keys (language_id, film_id, actor_id, inventory_id, staff_id ...) are resolved
     by the database at run time, so the script works in any copy of the DB where
     surrogate keys differ (no "magic numbers", no FK violations from a wrong ID);
   - the SELECT can contain WHERE NOT EXISTS, so the same statement is also the
     duplicate check (VALUES cannot be filtered);
   - it is set-based: one statement handles all rows, and it inserts nothing when a
     lookup finds nothing (instead of failing or inserting a wrong reference).

   !! Replace the three favourite films / actors below if your real favourites differ
      (search for the "FAVOURITES" marker). Keep different years and different genres.
   ===================================================================== */


/* =====================================================================
   SUB-TASK 1.1  Add 3 favourite films to public.film
                 (+ rental_rate 4.99 / 9.99 / 19.99 and rental_duration 1 / 2 / 3 weeks)
   ===================================================================== */
-- Why a separate transaction: the film rows are the parent rows for everything that
--   follows (category, actors, inventory). Committing them on their own means later
--   steps can fail and be repeated without touching the films.
-- If the transaction fails: nothing is written (atomicity) - either all 3 films or none.
-- Rollback: possible until COMMIT; only public.film would be affected (3 new rows
--   disappear, sequence values are not rolled back, which is harmless).
-- Referential integrity: language_id is looked up from public.language by name,
--   so it always points to an existing row (FK film.language_id -> language).
-- Duplicates: WHERE NOT EXISTS on the (upper-cased) title -> a second run inserts 0 rows.
-- Note: rental_duration in this schema is measured in DAYS, so 1/2/3 weeks = 7/14/21 days.
-- Note: the 'fulltext' column is filled by the table's own trigger.
BEGIN;

INSERT INTO public.film (title, description, release_year, language_id, rental_duration,
                         rental_rate, length, replacement_cost, rating, last_update)
SELECT v.title,
       v.description,
       v.release_year,
       (SELECT l.language_id FROM public.language l WHERE upper(l.name) = 'ENGLISH' LIMIT 1),
       v.weeks * 7,                       -- weeks -> days
       v.rental_rate,
       v.length,
       19.99,
       v.rating::public.mpaa_rating,
       current_date
FROM (VALUES
        -- FAVOURITES: title, description, year, weeks, rate, length(min), rating
        ('THE SHAWSHANK REDEMPTION', 'Two imprisoned men bond over years, finding solace and redemption through acts of decency.', 1994, 1,  4.99, 142, 'R'),
        ('INCEPTION',                'A thief who steals secrets through dream-sharing is offered a chance to have his past erased.', 2010, 2,  9.99, 148, 'PG-13'),
        ('SPIRITED AWAY',            'A young girl wanders into a world of spirits and must work in a bathhouse to free her parents.', 2001, 3, 19.99, 125, 'PG')
     ) AS v(title, description, release_year, weeks, rental_rate, length, rating)
WHERE NOT EXISTS (SELECT 1 FROM public.film f WHERE upper(f.title) = v.title)
RETURNING film_id, title, release_year, rental_duration, rental_rate, last_update;

COMMIT;


/* =====================================================================
   SUB-TASK 1.1b  Link the films to their (different) genres: public.film_category
   ===================================================================== */
-- Why a separate transaction: it is a different table/relationship; failure here must
--   not undo the already committed films.
-- If it fails: no category links are written; the films stay without a genre and the
--   script can simply be run again.
-- Rollback: possible before COMMIT; only public.film_category is affected.
-- Referential integrity: film_id and category_id come from joins to public.film and
--   public.category, so both FKs always reference existing rows.
-- Duplicates: WHERE NOT EXISTS on (film_id, category_id) (also the PK of the table).
BEGIN;

INSERT INTO public.film_category (film_id, category_id, last_update)
SELECT f.film_id, c.category_id, current_date
FROM (VALUES                                      -- FAVOURITES: title, genre
        ('THE SHAWSHANK REDEMPTION', 'DRAMA'),
        ('INCEPTION',                'SCI-FI'),
        ('SPIRITED AWAY',            'ANIMATION')
     ) AS v(title, genre)
JOIN public.film     f ON upper(f.title) = v.title
JOIN public.category c ON upper(c.name)  = v.genre
WHERE NOT EXISTS (SELECT 1 FROM public.film_category fc
                  WHERE fc.film_id = f.film_id AND fc.category_id = c.category_id)
RETURNING film_id, category_id, last_update;

COMMIT;


/* =====================================================================
   SUB-TASK 1.2  Add the real leading actors to public.actor (6+ actors)
   ===================================================================== */
-- Why a separate transaction: actors are independent parents of film_actor; people may
--   already exist in the system, so this step is allowed to insert 0..N rows on its own.
-- If it fails: no actor is inserted; film_actor (next step) would simply find nobody.
-- Rollback: possible before COMMIT; only public.actor is affected.
-- Referential integrity: actor has no FK to other tables; the link to films is created
--   afterwards in film_actor using IDs looked up by name.
-- Duplicates: the table has no unique constraint on the name, so an actor is identified
--   by (first_name, last_name) compared case-insensitively; WHERE NOT EXISTS skips
--   actors that already exist (e.g. an existing 'TIM ROBBINS' is re-used, not duplicated).
--   SELECT DISTINCT protects against the same actor appearing twice in the list.
BEGIN;

INSERT INTO public.actor (first_name, last_name, last_update)
SELECT DISTINCT v.first_name, v.last_name, current_date
FROM (VALUES                                       -- FAVOURITES: first, last name (8 actors)
        ('TIM',      'ROBBINS'),
        ('MORGAN',   'FREEMAN'),
        ('LEONARDO', 'DICAPRIO'),
        ('JOSEPH',   'GORDON-LEVITT'),
        ('TOM',      'HARDY'),
        ('RUMI',     'HIIRAGI'),
        ('MIYU',     'IRINO'),
        ('MARI',     'NATSUKI')
     ) AS v(first_name, last_name)
WHERE NOT EXISTS (SELECT 1 FROM public.actor a
                  WHERE upper(a.first_name) = v.first_name
                    AND upper(a.last_name)  = v.last_name)
RETURNING actor_id, first_name, last_name, last_update;

COMMIT;


/* =====================================================================
   SUB-TASK 1.2b  Connect actors with films: public.film_actor
   ===================================================================== */
-- Why a separate transaction: it only creates relations, so it depends on 1.1 and 1.2
--   being committed (both parents must already exist).
-- If it fails: no links are written, parents remain; re-running the script fixes it.
-- Rollback: possible before COMMIT; only public.film_actor rows are affected.
-- Referential integrity: actor_id and film_id are obtained by joining to public.actor
--   and public.film, so the FKs can never point to a non-existing row; an actor/film
--   that was not found simply produces no row.
-- Duplicates: WHERE NOT EXISTS on (actor_id, film_id) - the primary key of film_actor.
BEGIN;

INSERT INTO public.film_actor (actor_id, film_id, last_update)
SELECT a.actor_id, f.film_id, current_date
FROM (VALUES                                       -- FAVOURITES: film title, actor first, actor last
        ('THE SHAWSHANK REDEMPTION', 'TIM',      'ROBBINS'),
        ('THE SHAWSHANK REDEMPTION', 'MORGAN',   'FREEMAN'),
        ('INCEPTION',                'LEONARDO', 'DICAPRIO'),
        ('INCEPTION',                'JOSEPH',   'GORDON-LEVITT'),
        ('INCEPTION',                'TOM',      'HARDY'),
        ('SPIRITED AWAY',            'RUMI',     'HIIRAGI'),
        ('SPIRITED AWAY',            'MIYU',     'IRINO'),
        ('SPIRITED AWAY',            'MARI',     'NATSUKI')
     ) AS v(title, first_name, last_name)
JOIN public.film  f ON upper(f.title)      = v.title
JOIN public.actor a ON upper(a.first_name) = v.first_name
                   AND upper(a.last_name)  = v.last_name
WHERE NOT EXISTS (SELECT 1 FROM public.film_actor fa
                  WHERE fa.actor_id = a.actor_id AND fa.film_id = f.film_id)
RETURNING actor_id, film_id, last_update;

COMMIT;


/* =====================================================================
   SUB-TASK 1.3  Add the favourite films to a store's inventory: public.inventory
   ===================================================================== */
-- Why a separate transaction: inventory is the parent of rental; rentals in the later
--   steps need these rows to be committed and visible.
-- If it fails: no inventory row is written, the films stay in the catalogue only.
-- Rollback: possible before COMMIT; only public.inventory is affected (no rental
--   references the new rows yet).
-- Referential integrity: film_id comes from public.film and store_id from public.store
--   (the first store by id, no hard-coded value), so both FKs are valid.
-- Duplicates: WHERE NOT EXISTS on (film_id, store_id) -> one copy per film per store,
--   a re-run inserts nothing.
BEGIN;

INSERT INTO public.inventory (film_id, store_id, last_update)
SELECT f.film_id,
       (SELECT s.store_id FROM public.store s ORDER BY s.store_id LIMIT 1),
       current_date
FROM public.film f
WHERE upper(f.title) IN ('THE SHAWSHANK REDEMPTION', 'INCEPTION', 'SPIRITED AWAY')   -- FAVOURITES
  AND NOT EXISTS (SELECT 1 FROM public.inventory i
                  WHERE i.film_id  = f.film_id
                    AND i.store_id = (SELECT s.store_id FROM public.store s ORDER BY s.store_id LIMIT 1))
RETURNING inventory_id, film_id, store_id, last_update;

COMMIT;


/* =====================================================================
   SUB-TASK 1.4  Turn an existing customer (>= 43 rentals and >= 43 payments) into me
   ===================================================================== */
-- Pre-check (run before the UPDATE, as required "double-check with SELECT"):
SELECT cu.customer_id, cu.first_name, cu.last_name, cu.address_id,
       (SELECT count(*) FROM public.rental  r WHERE r.customer_id = cu.customer_id) AS rentals,
       (SELECT count(*) FROM public.payment p WHERE p.customer_id = cu.customer_id) AS payments
FROM public.customer cu
WHERE (SELECT count(*) FROM public.rental  r WHERE r.customer_id = cu.customer_id) >= 43
  AND (SELECT count(*) FROM public.payment p WHERE p.customer_id = cu.customer_id) >= 43
ORDER BY cu.customer_id;

-- Why a separate transaction: the identity change must be committed on its own, because
--   the following DELETE/INSERT steps look the customer up by the NEW name.
-- If it fails: the customer keeps the old personal data - nothing is half-updated.
-- Rollback: possible before COMMIT; only ONE row of public.customer is affected
--   (old first/last name, e-mail, address_id and last_update are restored).
-- Referential integrity: customer_id is not touched, so rental/payment links stay valid;
--   address_id is set to an EXISTING row of public.address that nobody uses yet
--   (customer, staff and store are checked); the address table itself is NOT modified.
-- Duplicates / re-runnable: the picked customer is the first one with >= 43 rentals and
--   payments, and the update is skipped (0 rows) if a customer 'JULIA DZIUBA' already
--   exists. Without that guard a re-run would hit another customer, because after step
--   1.5 my own customer has only 3 rentals.
BEGIN;

UPDATE public.customer
SET first_name  = 'JULIA',
    last_name   = 'DZIUBA',
    email       = 'juliadziuba@outlook.com',
    address_id  = (SELECT a.address_id
                   FROM public.address a
                   WHERE NOT EXISTS (SELECT 1 FROM public.customer c WHERE c.address_id = a.address_id)
                     AND NOT EXISTS (SELECT 1 FROM public.staff    s WHERE s.address_id = a.address_id)
                     AND NOT EXISTS (SELECT 1 FROM public.store    t WHERE t.address_id = a.address_id)
                   ORDER BY a.address_id
                   LIMIT 1),
    last_update = current_date
WHERE customer_id = (SELECT cu.customer_id
                     FROM public.customer cu
                     WHERE (SELECT count(*) FROM public.rental  r WHERE r.customer_id = cu.customer_id) >= 43
                       AND (SELECT count(*) FROM public.payment p WHERE p.customer_id = cu.customer_id) >= 43
                     ORDER BY cu.customer_id
                     LIMIT 1)
  AND NOT EXISTS (SELECT 1 FROM public.customer x
                  WHERE upper(x.first_name) = 'JULIA' AND upper(x.last_name) = 'DZIUBA')
RETURNING customer_id, store_id, first_name, last_name, email, address_id, last_update;

COMMIT;


/* =====================================================================
   SUB-TASK 1.5  Remove all records related to me from every table except
                 public.customer and public.inventory (-> payment and rental)
   ===================================================================== */
-- Pre-check (SELECT before DELETE): exactly what is going to be removed.
SELECT 'payment' AS tbl, count(*) AS rows_to_delete
FROM public.payment p JOIN public.customer c ON c.customer_id = p.customer_id
WHERE upper(c.first_name) = 'JULIA' AND upper(c.last_name) = 'DZIUBA'
UNION ALL
SELECT 'rental', count(*)
FROM public.rental r JOIN public.customer c ON c.customer_id = r.customer_id
WHERE upper(c.first_name) = 'JULIA' AND upper(c.last_name) = 'DZIUBA';

-- Why deleting is safe: only rows whose customer_id belongs to the customer 'JULIA DZIUBA'
--   (the one I just converted) are removed. No other customer, no film, store, staff
--   or inventory row is touched. payment is deleted BEFORE rental because
--   payment.rental_id references rental (child first, parent second -> no FK violation).
-- Why no unintended data loss: the filter is the customer_id found by my own name, both
--   DELETEs use the same filter, customer and inventory rows are kept, and the pre-check
--   SELECT above shows the exact number of rows before COMMIT.
-- Why a separate transaction: both deletes must succeed together or not at all - a
--   rental must never be removed while its payment survives (or the other way round).
-- If it fails: the whole transaction is aborted, neither payments nor rentals are lost.
-- Rollback: possible until COMMIT; payment + rental rows of this one customer come back.
--   After COMMIT the old history cannot be recovered (that is the intention of the task).
-- Referential integrity: children (payment) are deleted before parents (rental); no
--   other table references these rows.
-- Duplicates / re-runnable: a second run removes my 3 new rentals/payments too, but
--   sub-tasks 1.6/1.7 recreate them, so the end state is always the same.
BEGIN;

DELETE FROM public.payment
WHERE customer_id IN (SELECT c.customer_id FROM public.customer c
                      WHERE upper(c.first_name) = 'JULIA' AND upper(c.last_name) = 'DZIUBA')
RETURNING payment_id, customer_id, rental_id, amount;

DELETE FROM public.rental
WHERE customer_id IN (SELECT c.customer_id FROM public.customer c
                      WHERE upper(c.first_name) = 'JULIA' AND upper(c.last_name) = 'DZIUBA')
RETURNING rental_id, customer_id, inventory_id, rental_date;

COMMIT;


/* =====================================================================
   SUB-TASK 1.6  Rent my favourite films from the store they are in: public.rental
   ===================================================================== */
-- Why a separate transaction: the rental is the parent of the payment, so it has to be
--   committed first and the payment step can then reference it.
-- If it fails: no rental is stored (all three or none), the customer stays as it is.
-- Rollback: possible before COMMIT; only the 3 new public.rental rows are affected.
-- Referential integrity: inventory_id comes from public.inventory (the store holding
--   the film), customer_id from public.customer (by my name), staff_id is a staff member
--   WORKING IN THAT STORE - every FK points to an existing row.
-- Duplicates: WHERE NOT EXISTS on (inventory_id, customer_id, rental_date) - which is also
--   the unique index of rental - so a re-run inserts nothing.
-- Dates: first half of 2017 (so the payment fits the existing 2017 partitions);
--   return_date = rental_date + rental_duration days of the film.
BEGIN;

INSERT INTO public.rental (rental_date, inventory_id, customer_id, return_date, staff_id, last_update)
SELECT v.rental_date::timestamp,
       i.inventory_id,
       c.customer_id,
       v.rental_date::timestamp + f.rental_duration * INTERVAL '1 day',
       (SELECT s.staff_id FROM public.staff s WHERE s.store_id = i.store_id ORDER BY s.staff_id LIMIT 1),
       current_date
FROM (VALUES                                       -- FAVOURITES: title, rental date
        ('THE SHAWSHANK REDEMPTION', '2017-02-10 10:00:00'),
        ('INCEPTION',                '2017-03-15 14:30:00'),
        ('SPIRITED AWAY',            '2017-04-20 18:45:00')
     ) AS v(title, rental_date)
JOIN public.film      f ON upper(f.title) = v.title
JOIN public.inventory i ON i.film_id = f.film_id
JOIN public.customer  c ON upper(c.first_name) = 'JULIA' AND upper(c.last_name) = 'DZIUBA'
WHERE NOT EXISTS (SELECT 1 FROM public.rental r
                  WHERE r.inventory_id = i.inventory_id
                    AND r.customer_id  = c.customer_id
                    AND r.rental_date  = v.rental_date::timestamp)
RETURNING rental_id, rental_date, inventory_id, customer_id, return_date, staff_id, last_update;

COMMIT;


/* =====================================================================
   SUB-TASK 1.7  Pay for the rentals: public.payment
   ===================================================================== */
-- Why a separate transaction: payment is the last child in the chain; if it fails the
--   (already committed) rentals stay valid and only this step is repeated.
-- If it fails: no payment is written; the rentals exist unpaid until the step is re-run.
-- Rollback: possible before COMMIT; only the new public.payment rows are affected.
-- Referential integrity: rental_id / customer_id / staff_id are copied from the rental
--   row itself, so payment always points to the rental it pays for; amount = the film's
--   rental_rate (4.99 / 9.99 / 19.99).
-- Duplicates: WHERE NOT EXISTS on rental_id -> one payment per rental, a re-run adds none.
-- Partitioning: payment_date (= rental date) falls into the first half of 2017, for
--   which partitions exist in the training database. If your copy lacks them, create
--   one first, e.g.
--     CREATE TABLE IF NOT EXISTS public.payment_p2017_01 PARTITION OF public.payment
--       FOR VALUES FROM ('2017-01-01') TO ('2017-02-01');   -- repeat for each month used
BEGIN;

INSERT INTO public.payment (customer_id, staff_id, rental_id, amount, payment_date)
SELECT r.customer_id, r.staff_id, r.rental_id, f.rental_rate, r.rental_date
FROM public.rental    r
JOIN public.customer  c ON c.customer_id  = r.customer_id
JOIN public.inventory i ON i.inventory_id = r.inventory_id
JOIN public.film      f ON f.film_id      = i.film_id
WHERE upper(c.first_name) = 'JULIA' AND upper(c.last_name) = 'DZIUBA'
  AND upper(f.title) IN ('THE SHAWSHANK REDEMPTION', 'INCEPTION', 'SPIRITED AWAY')   -- FAVOURITES
  AND NOT EXISTS (SELECT 1 FROM public.payment p WHERE p.rental_id = r.rental_id)
RETURNING payment_id, customer_id, staff_id, rental_id, amount, payment_date;

COMMIT;
