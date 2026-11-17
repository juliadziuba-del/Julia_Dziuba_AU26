/*
================================================================================
 SQL_DDL_Julia_Dziuba_HW.sql
 Physical database for the Hotel Booking System (PostgreSQL, 3NF)
 Author : Julia Dziuba
================================================================================

 The script is rerunnable (IF NOT EXISTS, ON CONFLICT DO NOTHING, WHERE NOT
 EXISTS) and does not create duplicates.

 Changes to the logical model:
   * No tables, relations or business columns were added and no data type was
     changed. The only new column is record_ts (task step 9).
   * Trigger-based rules from the logical model are not created here; all
     declarative rules (PK, UNIQUE, composite FK, CHECK, EXCLUDE) are.

 DATA TYPES: WHY THESE TYPES AND WHAT CAN GO WRONG WITH A WRONG ONE
   integer / bigint (surrogate keys, GENERATED ALWAYS AS IDENTITY)
        bigint is used for high-volume tables (reservation, histories,
        payment). Risk of a too small type: smallint/integer overflows
        after 32 767 / 2.1 billion rows and inserts start to fail.
        Risk of a text key (varchar): slower joins, bigger indexes and a key
        that has to change when a name changes.
   varchar(n) (names, e-mail, codes of variable length)
        Risk of a too short n: valid data (a long hotel name) is rejected.
        Risk of unlimited text: junk of any size is accepted and layouts break.
   char(2) / char(3) (ISO country and currency codes)
        Fixed length. Risk of varchar here: 'P', 'PLN2' or 'pl ' would be
        accepted and joins/filters by code would silently miss rows.
   numeric(10,2) / numeric(12,2) (prices, amounts)
        Exact decimal arithmetic. Risk of real / double precision: rounding
        errors (0.1 + 0.2 <> 0.3), so invoices and payments would not add up.
        Risk of money/integer: lost cents or locale-dependent behaviour.
   smallint (capacity, guests_count, quantity)
        Small bounded counters. Risk of text: 'two' or '-1' could be stored.
   date (stay_start, stay_end, valid_from for prices, hire_date, service_date,
         record_ts)
        Whole days only. Risk of timestamp: a booking ending 14 Aug 00:00 would
        not match a booking starting 14 Aug 12:00 and day arithmetic breaks.
        Risk of varchar: '2026-13-45' or '14/08/2026' would be accepted and
        sorting/comparison of dates would be wrong.
   timestamptz (checked_in_at, paid_at, created_at, changed_at, valid_from of
                statuses, released_at, cancelled_at)
        A real moment in time, independent of the server time zone. Risk of
        timestamp without time zone: the same event is read as a different
        moment when the client or server time zone changes (daylight saving,
        guests in other countries), so the audit trail becomes unreliable.
================================================================================
*/

-- -----------------------------------------------------------------------------
-- 0. Database, schema and extension
-- -----------------------------------------------------------------------------

-- Separate physical database. It is run once, from the default "postgres"
-- database, and then this script is run inside it. It is commented out because
-- CREATE DATABASE has no IF NOT EXISTS and would fail on a rerun.
-- CREATE DATABASE hotel_booking_db;

-- Separate, domain-related schema for the project objects.
CREATE SCHEMA IF NOT EXISTS hotel_booking;

-- btree_gist lets an EXCLUDE constraint combine "=" on a column (room_id) with
-- "&&" (overlap) on a date range. It is needed for the no-double-booking rule.
CREATE EXTENSION IF NOT EXISTS btree_gist;

SET search_path TO hotel_booking, public;


-- -----------------------------------------------------------------------------
-- 1. Tables
--
-- WHY THE ORDER OF DDL MATTERS
--   A foreign key can only point to a table that already exists. Parent
--   (referenced) tables are therefore created before child (referencing)
--   tables:
--     hotel, room_type, service, guest      (no foreign keys)
--     employee                              (-> hotel, itself)
--     room_rate, room                       (-> hotel, room_type, employee)
--     room_status_history                   (-> room, employee)
--     reservation                           (-> hotel, guest, employee)
--     reservation_status_history            (-> reservation, employee)
--     reservation_room                      (-> reservation, room)
--     stay                                  (-> reservation_room, employee)
--     service_price                         (-> hotel, service, employee)
--     reservation_service                   (-> reservation, service_price,
--                                              employee)
--     payment                               (-> reservation, employee)
--   If a child table is created first, PostgreSQL stops with
--     ERROR: relation "hotel_booking.hotel" does not exist
--   and the rest of the script would not run. For inserts the same order is
--   used: inserting a child row before its parent row fails with
--     ERROR: insert or update on table "..." violates foreign key constraint.
--   (employee refers to itself; a row is valid because the supervisor row is
--   inserted earlier, managers first.)
--
-- WHAT HAPPENS IF A FOREIGN KEY IS MISSING
--   Without a foreign key the database does not check the link. A room could
--   point to a hotel_id that does not exist, a payment could belong to a
--   deleted/non-existing reservation ("orphan rows"), a parent row could be
--   deleted while children still use it, and JOINs would silently lose those
--   rows, so reports and invoices would be wrong. The composite foreign keys
--   below also stop a booking from mixing a room or an employee of another
--   hotel. All foreign keys use ON DELETE / ON UPDATE RESTRICT, because
--   historical rows must never lose their parents.
-- -----------------------------------------------------------------------------

-- 1.1 hotel -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.hotel (
    hotel_id     integer      GENERATED ALWAYS AS IDENTITY,
    hotel_name   varchar(100) NOT NULL,
    address_line varchar(200) NOT NULL,
    city         varchar(100) NOT NULL,
    country_code char(2)      NOT NULL,
    phone        varchar(30),
    CONSTRAINT pk_hotel PRIMARY KEY (hotel_id),
    -- UNIQUE: prevents two hotels with the same name. Without it a duplicate
    -- hotel could be loaded twice and rooms/prices would be split between them.
    CONSTRAINT uq_hotel_hotel_name UNIQUE (hotel_name),
    -- CHECK: prevents invalid country codes such as 'Poland', 'pl' or '1'.
    -- Without it reports grouped by country would show many spellings.
    CONSTRAINT chk_hotel_country_code CHECK (country_code ~ '^[A-Z]{2}$')
);

-- 1.2 room_type ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.room_type (
    room_type_id integer     GENERATED ALWAYS AS IDENTITY,
    type_name    varchar(50) NOT NULL,
    capacity     smallint    NOT NULL,
    CONSTRAINT pk_room_type PRIMARY KEY (room_type_id),
    -- UNIQUE: prevents two types called 'Suite'. Without it a room could be
    -- linked to either copy and the price lists would diverge.
    CONSTRAINT uq_room_type_type_name UNIQUE (type_name),
    -- CHECK: prevents a capacity of 0 or a negative number. Without it a
    -- "room for -2 guests" could exist and capacity checks would never pass.
    CONSTRAINT chk_room_type_capacity_positive CHECK (capacity > 0)
);

-- 1.3 service -----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.service (
    service_id   integer      GENERATED ALWAYS AS IDENTITY,
    service_name varchar(100) NOT NULL,
    description  varchar(255),
    CONSTRAINT pk_service PRIMARY KEY (service_id),
    -- UNIQUE: prevents the same service from being added to the catalogue
    -- twice (two "Breakfast" rows would double count it in reports).
    CONSTRAINT uq_service_service_name UNIQUE (service_name)
);

-- 1.4 guest -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.guest (
    guest_id   integer      GENERATED ALWAYS AS IDENTITY,
    first_name varchar(80)  NOT NULL,
    last_name  varchar(80)  NOT NULL,
    email      varchar(255) NOT NULL,
    phone      varchar(30),
    CONSTRAINT pk_guest PRIMARY KEY (guest_id),
    -- [TASK CHECK 4: UNIQUE] prevents two guest accounts with one e-mail.
    -- Without it the same person gets several guest rows, the booking history
    -- is split and an e-mail update changes only one of the copies.
    CONSTRAINT uq_guest_email UNIQUE (email),
    -- CHECK: prevents strings that are not an e-mail ('john', 'a@b').
    -- Without it confirmations are sent to unusable addresses.
    CONSTRAINT chk_guest_email_format CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

-- 1.5 employee ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.employee (
    employee_id      integer      GENERATED ALWAYS AS IDENTITY,
    hotel_id         integer      NOT NULL,
    supervisor_id    integer,
    first_name       varchar(80)  NOT NULL,
    last_name        varchar(80)  NOT NULL,
    email            varchar(255) NOT NULL,
    job_title        varchar(60)  NOT NULL,
    hire_date        date         NOT NULL DEFAULT current_date,
    termination_date date,
    CONSTRAINT pk_employee PRIMARY KEY (employee_id),
    CONSTRAINT uq_employee_email UNIQUE (email),
    -- Target of the composite foreign keys (employee_id, hotel_id) used by the
    -- tables in which an employee acts: the employee must work in that hotel.
    CONSTRAINT uq_employee_employee_hotel UNIQUE (employee_id, hotel_id),
    CONSTRAINT fk_employee_hotel FOREIGN KEY (hotel_id)
        REFERENCES hotel_booking.hotel (hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- Self-reference: the supervisor must be an employee of the SAME hotel.
    -- supervisor_id NULL = top manager of the hotel (FK is skipped for NULL).
    CONSTRAINT fk_employee_supervisor FOREIGN KEY (supervisor_id, hotel_id)
        REFERENCES hotel_booking.employee (employee_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- [TASK CHECK 1: date after 1 January 2000]
    -- Prevents impossible hire dates (1900-01-01, 0001-01-01, typos like 1026).
    -- Without it wrong dates distort seniority, payroll and audit reports.
    CONSTRAINT chk_employee_hire_date_after_2000 CHECK (hire_date > DATE '2000-01-01'),
    -- CHECK: prevents an employee who left before being hired.
    CONSTRAINT chk_employee_termination_after_hire
        CHECK (termination_date IS NULL OR termination_date >= hire_date),
    -- CHECK: prevents an employee who is his/her own supervisor (loop of 1).
    CONSTRAINT chk_employee_not_own_supervisor
        CHECK (supervisor_id IS NULL OR supervisor_id <> employee_id),
    CONSTRAINT chk_employee_email_format CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);

-- 1.6 room_rate ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.room_rate (
    room_rate_id           bigint        GENERATED ALWAYS AS IDENTITY,
    hotel_id               integer       NOT NULL,
    room_type_id           integer       NOT NULL,
    price_per_night        numeric(10,2) NOT NULL,
    valid_from             date          NOT NULL,
    valid_to               date,
    created_by_employee_id integer       NOT NULL,
    CONSTRAINT pk_room_rate PRIMARY KEY (room_rate_id),
    -- UNIQUE: one price per hotel, room type and start date. Without it two
    -- prices could start on the same day and a booking could not decide which
    -- one to take.
    CONSTRAINT uq_room_rate_hotel_type_from UNIQUE (hotel_id, room_type_id, valid_from),
    CONSTRAINT fk_room_rate_hotel FOREIGN KEY (hotel_id)
        REFERENCES hotel_booking.hotel (hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_room_rate_room_type FOREIGN KEY (room_type_id)
        REFERENCES hotel_booking.room_type (room_type_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- Composite FK: the employee who set the price works in the same hotel.
    CONSTRAINT fk_room_rate_created_by FOREIGN KEY (created_by_employee_id, hotel_id)
        REFERENCES hotel_booking.employee (employee_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- [TASK CHECK 2: measured value not negative]
    -- Prevents a negative nightly price (e.g. -420.00). Without it revenue
    -- reports would go down when a booking is made, and a typo with a minus
    -- sign would silently pay the guest.
    CONSTRAINT chk_room_rate_price_not_negative CHECK (price_per_night >= 0),
    -- CHECK: prevents a period that ends before (or when) it starts.
    CONSTRAINT chk_room_rate_period CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- EXCLUDE: prevents two overlapping price periods for the same hotel and
    -- room type. Without it a night could have two valid prices.
    CONSTRAINT ex_room_rate_no_overlap EXCLUDE USING gist (
        hotel_id WITH =,
        room_type_id WITH =,
        daterange(valid_from, valid_to) WITH &&
    )
);

-- 1.7 room --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.room (
    room_id      integer     GENERATED ALWAYS AS IDENTITY,
    hotel_id     integer     NOT NULL,
    room_type_id integer     NOT NULL,
    room_number  varchar(10) NOT NULL,
    CONSTRAINT pk_room PRIMARY KEY (room_id),
    -- UNIQUE: prevents two rooms numbered "101" in one hotel (a guest would be
    -- sent to the wrong door and the room could be booked twice).
    CONSTRAINT uq_room_hotel_room_number UNIQUE (hotel_id, room_number),
    -- Target of the composite FK from reservation_room (room belongs to the
    -- hotel of the reservation).
    CONSTRAINT uq_room_room_hotel UNIQUE (room_id, hotel_id),
    CONSTRAINT fk_room_hotel FOREIGN KEY (hotel_id)
        REFERENCES hotel_booking.hotel (hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_room_room_type FOREIGN KEY (room_type_id)
        REFERENCES hotel_booking.room_type (room_type_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
);

-- 1.8 room_status_history -----------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.room_status_history (
    room_status_history_id bigint      GENERATED ALWAYS AS IDENTITY,
    room_id                integer     NOT NULL,
    status_code            varchar(20) NOT NULL,
    valid_from             timestamptz NOT NULL DEFAULT now(),
    valid_to               timestamptz,
    changed_by_employee_id integer     NOT NULL,
    CONSTRAINT pk_room_status_history PRIMARY KEY (room_status_history_id),
    CONSTRAINT uq_room_status_history_room_from UNIQUE (room_id, valid_from),
    CONSTRAINT fk_room_status_history_room FOREIGN KEY (room_id)
        REFERENCES hotel_booking.room (room_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_room_status_history_employee FOREIGN KEY (changed_by_employee_id)
        REFERENCES hotel_booking.employee (employee_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- CHECK: prevents unknown statuses ('BROKEN', typos). Without it filters
    -- like status_code = 'AVAILABLE' would miss rooms written as 'Availible'.
    CONSTRAINT chk_room_status_history_status CHECK (status_code IN
        ('AVAILABLE', 'CLEANING', 'MAINTENANCE', 'OUT_OF_SERVICE', 'DECOMMISSIONED')),
    CONSTRAINT chk_room_status_history_period CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- EXCLUDE: a room cannot have two statuses at the same moment.
    CONSTRAINT ex_room_status_history_no_overlap EXCLUDE USING gist (
        room_id WITH =,
        tstzrange(valid_from, valid_to) WITH &&
    )
);

-- 1.9 reservation -------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.reservation (
    reservation_id         bigint      GENERATED ALWAYS AS IDENTITY,
    hotel_id               integer     NOT NULL,
    guest_id               integer     NOT NULL,
    created_by_employee_id integer,
    created_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT pk_reservation PRIMARY KEY (reservation_id),
    -- Target of the composite FKs from reservation_room / reservation_service.
    CONSTRAINT uq_reservation_reservation_hotel UNIQUE (reservation_id, hotel_id),
    CONSTRAINT fk_reservation_hotel FOREIGN KEY (hotel_id)
        REFERENCES hotel_booking.hotel (hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_guest FOREIGN KEY (guest_id)
        REFERENCES hotel_booking.guest (guest_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- NULL = online booking (FK is skipped); otherwise the employee must work
    -- in the hotel of the reservation.
    CONSTRAINT fk_reservation_created_by FOREIGN KEY (created_by_employee_id, hotel_id)
        REFERENCES hotel_booking.employee (employee_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT
);

-- 1.10 reservation_status_history ---------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.reservation_status_history (
    reservation_status_history_id bigint      GENERATED ALWAYS AS IDENTITY,
    reservation_id                bigint      NOT NULL,
    status_code                   varchar(20) NOT NULL,
    changed_at                    timestamptz NOT NULL DEFAULT now(),
    changed_by_employee_id        integer,
    CONSTRAINT pk_reservation_status_history PRIMARY KEY (reservation_status_history_id),
    CONSTRAINT uq_reservation_status_history_res_at UNIQUE (reservation_id, changed_at),
    CONSTRAINT fk_reservation_status_history_reservation FOREIGN KEY (reservation_id)
        REFERENCES hotel_booking.reservation (reservation_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_status_history_employee FOREIGN KEY (changed_by_employee_id)
        REFERENCES hotel_booking.employee (employee_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- CHECK: prevents unknown life-cycle statuses. Without it "current status"
    -- queries could return a value no application knows how to handle.
    CONSTRAINT chk_reservation_status_history_status CHECK (status_code IN
        ('PENDING', 'CONFIRMED', 'CHECKED_IN', 'COMPLETED', 'CANCELLED', 'NO_SHOW'))
);

-- 1.11 reservation_room -------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.reservation_room (
    reservation_room_id bigint        GENERATED ALWAYS AS IDENTITY,
    reservation_id      bigint        NOT NULL,
    hotel_id            integer       NOT NULL,
    room_id             integer       NOT NULL,
    stay_start          date          NOT NULL,
    stay_end            date          NOT NULL,
    guests_count        smallint      NOT NULL DEFAULT 1,
    price_per_night     numeric(10,2) NOT NULL,
    released_at         timestamptz,
    CONSTRAINT pk_reservation_room PRIMARY KEY (reservation_room_id),
    -- UNIQUE: the same room cannot be added twice to one reservation with the
    -- same arrival date (a duplicate line would be charged twice).
    CONSTRAINT uq_reservation_room_res_room_start UNIQUE (reservation_id, room_id, stay_start),
    -- Composite FKs: the reservation and the room must belong to the same
    -- hotel. Without them a booking could contain a room of another hotel.
    CONSTRAINT fk_reservation_room_reservation FOREIGN KEY (reservation_id, hotel_id)
        REFERENCES hotel_booking.reservation (reservation_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_room_room FOREIGN KEY (room_id, hotel_id)
        REFERENCES hotel_booking.room (room_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- CHECK: prevents a stay that ends before or on the day it starts
    -- (zero or negative number of nights).
    CONSTRAINT chk_reservation_room_dates CHECK (stay_end > stay_start),
    -- CHECK: prevents a booking for 0 or negative number of guests.
    CONSTRAINT chk_reservation_room_guests_positive CHECK (guests_count > 0),
    CONSTRAINT chk_reservation_room_price_not_negative CHECK (price_per_night >= 0),
    -- EXCLUDE: prevents DOUBLE BOOKING. Two active (not released) lines of the
    -- same room cannot have overlapping date ranges. stay_end is exclusive, so
    -- a booking that ends on 14 Aug and one that starts on 14 Aug are allowed.
    -- Without it two guests could get the same room for the same night.
    CONSTRAINT ex_reservation_room_no_double_booking EXCLUDE USING gist (
        room_id WITH =,
        daterange(stay_start, stay_end) WITH &&
    ) WHERE (released_at IS NULL)
);

-- 1.12 stay -------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.stay (
    stay_id                    bigint      GENERATED ALWAYS AS IDENTITY,
    reservation_room_id        bigint      NOT NULL,
    checked_in_at              timestamptz NOT NULL DEFAULT now(),
    checked_out_at             timestamptz,
    checked_in_by_employee_id  integer     NOT NULL,
    checked_out_by_employee_id integer,
    CONSTRAINT pk_stay PRIMARY KEY (stay_id),
    -- UNIQUE makes the relationship 1 : 0..1. A booked room can be checked in
    -- only once; without it two stays could be recorded for one booked room.
    CONSTRAINT uq_stay_reservation_room UNIQUE (reservation_room_id),
    CONSTRAINT fk_stay_reservation_room FOREIGN KEY (reservation_room_id)
        REFERENCES hotel_booking.reservation_room (reservation_room_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_stay_checked_in_by FOREIGN KEY (checked_in_by_employee_id)
        REFERENCES hotel_booking.employee (employee_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_stay_checked_out_by FOREIGN KEY (checked_out_by_employee_id)
        REFERENCES hotel_booking.employee (employee_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- CHECK: prevents check-out before check-in.
    CONSTRAINT chk_stay_check_out_after_check_in
        CHECK (checked_out_at IS NULL OR checked_out_at > checked_in_at),
    -- CHECK: the check-out time and the check-out employee are filled together.
    -- Without it a check-out could exist without knowing who did it.
    CONSTRAINT chk_stay_check_out_pair
        CHECK ((checked_out_at IS NULL) = (checked_out_by_employee_id IS NULL))
);

-- 1.13 service_price ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.service_price (
    service_price_id       bigint        GENERATED ALWAYS AS IDENTITY,
    hotel_id               integer       NOT NULL,
    service_id             integer       NOT NULL,
    unit_price             numeric(10,2) NOT NULL,
    valid_from             date          NOT NULL,
    valid_to               date,
    created_by_employee_id integer       NOT NULL,
    CONSTRAINT pk_service_price PRIMARY KEY (service_price_id),
    CONSTRAINT uq_service_price_hotel_service_from UNIQUE (hotel_id, service_id, valid_from),
    -- Target of the composite FK from reservation_service: only a service
    -- offered by the hotel of the reservation can be ordered.
    CONSTRAINT uq_service_price_price_hotel UNIQUE (service_price_id, hotel_id),
    CONSTRAINT fk_service_price_hotel FOREIGN KEY (hotel_id)
        REFERENCES hotel_booking.hotel (hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_service_price_service FOREIGN KEY (service_id)
        REFERENCES hotel_booking.service (service_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_service_price_created_by FOREIGN KEY (created_by_employee_id, hotel_id)
        REFERENCES hotel_booking.employee (employee_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT chk_service_price_not_negative CHECK (unit_price >= 0),
    CONSTRAINT chk_service_price_period CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT ex_service_price_no_overlap EXCLUDE USING gist (
        hotel_id WITH =,
        service_id WITH =,
        daterange(valid_from, valid_to) WITH &&
    )
);

-- 1.14 reservation_service ----------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.reservation_service (
    reservation_service_id bigint        GENERATED ALWAYS AS IDENTITY,
    reservation_id         bigint        NOT NULL,
    hotel_id               integer       NOT NULL,
    service_price_id       bigint        NOT NULL,
    quantity               smallint      NOT NULL DEFAULT 1,
    unit_price             numeric(10,2) NOT NULL,
    service_date           date          NOT NULL,
    added_by_employee_id   integer       NOT NULL,
    added_at               timestamptz   NOT NULL DEFAULT now(),
    cancelled_at           timestamptz,
    CONSTRAINT pk_reservation_service PRIMARY KEY (reservation_service_id),
    -- All three composite FKs share hotel_id: the reservation, the service
    -- offer and the employee must all belong to the same hotel.
    CONSTRAINT fk_reservation_service_reservation FOREIGN KEY (reservation_id, hotel_id)
        REFERENCES hotel_booking.reservation (reservation_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_service_service_price FOREIGN KEY (service_price_id, hotel_id)
        REFERENCES hotel_booking.service_price (service_price_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_reservation_service_added_by FOREIGN KEY (added_by_employee_id, hotel_id)
        REFERENCES hotel_booking.employee (employee_id, hotel_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- CHECK: prevents ordering 0 or a negative number of units.
    CONSTRAINT chk_reservation_service_quantity_positive CHECK (quantity > 0),
    CONSTRAINT chk_reservation_service_price_not_negative CHECK (unit_price >= 0),
    CONSTRAINT chk_reservation_service_cancel_after_add
        CHECK (cancelled_at IS NULL OR cancelled_at >= added_at)
);

-- 1.15 payment ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS hotel_booking.payment (
    payment_id               bigint        GENERATED ALWAYS AS IDENTITY,
    reservation_id           bigint        NOT NULL,
    payment_type             varchar(10)   NOT NULL,
    payment_method           varchar(20)   NOT NULL,
    -- [TASK CHECK 5: NOT NULL] a payment without an amount is meaningless;
    -- without NOT NULL the balance (SUM of payments) would silently ignore it.
    amount                   numeric(12,2) NOT NULL,
    currency_code            char(3)       NOT NULL DEFAULT 'EUR',
    paid_at                  timestamptz   NOT NULL DEFAULT now(),
    processed_by_employee_id integer,
    CONSTRAINT pk_payment PRIMARY KEY (payment_id),
    CONSTRAINT fk_payment_reservation FOREIGN KEY (reservation_id)
        REFERENCES hotel_booking.reservation (reservation_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT fk_payment_employee FOREIGN KEY (processed_by_employee_id)
        REFERENCES hotel_booking.employee (employee_id)
        ON UPDATE RESTRICT ON DELETE RESTRICT,
    -- [TASK CHECK 3: value from a fixed list]
    -- Prevents unknown payment types ('GIFT', typos). Without it the balance
    -- logic (DEPOSIT/FINAL add, REFUND subtracts) would treat unknown values
    -- wrongly and totals would be wrong.
    CONSTRAINT chk_payment_payment_type CHECK (payment_type IN ('DEPOSIT', 'FINAL', 'REFUND')),
    CONSTRAINT chk_payment_payment_method CHECK (payment_method IN
        ('CARD', 'CASH', 'BANK_TRANSFER', 'ONLINE')),
    -- CHECK: the amount is always positive (a refund is a positive amount with
    -- type REFUND). Prevents zero and negative payments that would reverse the
    -- meaning of the type.
    CONSTRAINT chk_payment_amount_positive CHECK (amount > 0),
    -- CHECK: prevents invalid currency codes ('zl', 'PLN1').
    CONSTRAINT chk_payment_currency_code CHECK (currency_code ~ '^[A-Z]{3}$')
);


-- -----------------------------------------------------------------------------
-- 2. Indexes on foreign key columns and for availability search
--    PostgreSQL does not index the referencing side of a foreign key
--    automatically. Without these indexes, joins and parent-row checks scan
--    the whole child table. Columns already covered by the leading column of a
--    UNIQUE constraint are not indexed again.
-- -----------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_employee_hotel_id
    ON hotel_booking.employee (hotel_id);
CREATE INDEX IF NOT EXISTS idx_employee_supervisor_id
    ON hotel_booking.employee (supervisor_id);
CREATE INDEX IF NOT EXISTS idx_room_rate_room_type_id
    ON hotel_booking.room_rate (room_type_id);
CREATE INDEX IF NOT EXISTS idx_room_rate_created_by
    ON hotel_booking.room_rate (created_by_employee_id);
CREATE INDEX IF NOT EXISTS idx_room_room_type_id
    ON hotel_booking.room (room_type_id);
CREATE INDEX IF NOT EXISTS idx_room_status_history_changed_by
    ON hotel_booking.room_status_history (changed_by_employee_id);
CREATE INDEX IF NOT EXISTS idx_reservation_hotel_id
    ON hotel_booking.reservation (hotel_id);
CREATE INDEX IF NOT EXISTS idx_reservation_guest_id
    ON hotel_booking.reservation (guest_id);
CREATE INDEX IF NOT EXISTS idx_reservation_created_by
    ON hotel_booking.reservation (created_by_employee_id);
CREATE INDEX IF NOT EXISTS idx_reservation_status_history_changed_by
    ON hotel_booking.reservation_status_history (changed_by_employee_id);
-- Availability search: "is this room booked between two dates?"
CREATE INDEX IF NOT EXISTS idx_reservation_room_room_dates
    ON hotel_booking.reservation_room (room_id, stay_start, stay_end);
CREATE INDEX IF NOT EXISTS idx_stay_checked_in_by
    ON hotel_booking.stay (checked_in_by_employee_id);
CREATE INDEX IF NOT EXISTS idx_stay_checked_out_by
    ON hotel_booking.stay (checked_out_by_employee_id);
CREATE INDEX IF NOT EXISTS idx_service_price_service_id
    ON hotel_booking.service_price (service_id);
CREATE INDEX IF NOT EXISTS idx_service_price_created_by
    ON hotel_booking.service_price (created_by_employee_id);
CREATE INDEX IF NOT EXISTS idx_reservation_service_reservation_id
    ON hotel_booking.reservation_service (reservation_id);
CREATE INDEX IF NOT EXISTS idx_reservation_service_service_price_id
    ON hotel_booking.reservation_service (service_price_id);
CREATE INDEX IF NOT EXISTS idx_reservation_service_added_by
    ON hotel_booking.reservation_service (added_by_employee_id);
CREATE INDEX IF NOT EXISTS idx_payment_reservation_id
    ON hotel_booking.payment (reservation_id);
CREATE INDEX IF NOT EXISTS idx_payment_processed_by
    ON hotel_booking.payment (processed_by_employee_id);


-- -----------------------------------------------------------------------------
-- 3. Sample data
--
-- HOW CONSISTENCY AND RELATIONSHIPS ARE PRESERVED
--   * No surrogate key is typed by hand (the keys are GENERATED ALWAYS, so an
--     explicit value would even be rejected). Every foreign key is looked up
--     with JOIN on a natural, unique value (hotel name, e-mail, room number,
--     service name), so a child row always receives the real key of an
--     existing parent. If the parent is not found, the JOIN returns no row and
--     nothing is inserted instead of inserting a broken link.
--   * Parents are loaded before children (same order as the DDL).
--   * Agreed prices (reservation_room.price_per_night and
--     reservation_service.unit_price) are not typed in: they are read from the
--     price list valid on the stay / service date, so they always match it.
--   * The employee of every action is joined together with the hotel of the
--     record, so the composite foreign keys are always satisfied.
--   * Rerun safety (no duplicates): tables with a natural unique key use
--     ON CONFLICT DO NOTHING; tables without one use WHERE NOT EXISTS.
--   * All CHECK / EXCLUDE constraints are active during the load, so the sample
--     data itself proves they accept valid data.
-- -----------------------------------------------------------------------------

-- 3.1 hotel
INSERT INTO hotel_booking.hotel (hotel_name, address_line, city, country_code, phone)
VALUES
    ('Grand Baltic Hotel', 'ul. Dluga 15',    'Gdansk', 'PL', '+48 58 300 1000'),
    ('Vistula Riverside',  'ul. Wybrzeze 20', 'Warsaw', 'PL', '+48 22 500 2000')
ON CONFLICT (hotel_name) DO NOTHING;

-- 3.2 room_type
INSERT INTO hotel_booking.room_type (type_name, capacity)
VALUES
    ('Single', 1),
    ('Double', 2),
    ('Suite',  4)
ON CONFLICT (type_name) DO NOTHING;

-- 3.3 service
INSERT INTO hotel_booking.service (service_name, description)
VALUES
    ('Breakfast',  'Buffet breakfast per person'),
    ('Parking',    'Underground parking per day'),
    ('Spa access', 'Daily spa pass')
ON CONFLICT (service_name) DO NOTHING;

-- 3.4 guest
INSERT INTO hotel_booking.guest (first_name, last_name, email, phone)
VALUES
    ('John',  'Smith',  'john.smith@mail.com',  '+44 20 7946 0000'),
    ('Maria', 'Garcia', 'maria.garcia@mail.com', NULL)
ON CONFLICT (email) DO NOTHING;

-- 3.5 employee: top managers first (no supervisor), then their staff, because a
--     supervisor row must exist before it can be referenced.
INSERT INTO hotel_booking.employee
    (hotel_id, supervisor_id, first_name, last_name, email, job_title, hire_date)
SELECT h.hotel_id, NULL, v.first_name, v.last_name, v.email, v.job_title, v.hire_date
FROM (
    VALUES
        ('Grand Baltic Hotel', 'Anna',  'Kowalska',  'a.kowalska@gbh.pl',  'General Manager', DATE '2020-03-01'),
        ('Vistula Riverside',  'Marta', 'Zielinska', 'm.zielinska@vr.pl',  'General Manager', DATE '2024-01-10')
) AS v (hotel_name, first_name, last_name, email, job_title, hire_date)
INNER JOIN hotel_booking.hotel AS h
    ON h.hotel_name = v.hotel_name
ON CONFLICT (email) DO NOTHING;

INSERT INTO hotel_booking.employee
    (hotel_id, supervisor_id, first_name, last_name, email, job_title, hire_date)
SELECT h.hotel_id, s.employee_id, v.first_name, v.last_name, v.email, v.job_title, v.hire_date
FROM (
    VALUES
        ('Grand Baltic Hotel', 'a.kowalska@gbh.pl', 'Piotr',  'Nowak',       'p.nowak@gbh.pl',       'Receptionist', DATE '2023-05-15'),
        ('Vistula Riverside',  'm.zielinska@vr.pl', 'Tomasz', 'Wisniewski',  't.wisniewski@vr.pl',   'Receptionist', DATE '2024-02-01')
) AS v (hotel_name, supervisor_email, first_name, last_name, email, job_title, hire_date)
INNER JOIN hotel_booking.hotel AS h
    ON h.hotel_name = v.hotel_name
INNER JOIN hotel_booking.employee AS s
    ON s.email = v.supervisor_email
   AND s.hotel_id = h.hotel_id
ON CONFLICT (email) DO NOTHING;

-- 3.6 room_rate
INSERT INTO hotel_booking.room_rate
    (hotel_id, room_type_id, price_per_night, valid_from, valid_to, created_by_employee_id)
SELECT h.hotel_id, rt.room_type_id, v.price_per_night, v.valid_from, v.valid_to, e.employee_id
FROM (
    VALUES
        ('Grand Baltic Hotel', 'Double', 420.00, DATE '2026-01-01', DATE '2026-07-01',       'a.kowalska@gbh.pl'),
        ('Grand Baltic Hotel', 'Double', 460.00, DATE '2026-07-01', CAST(NULL AS date),      'a.kowalska@gbh.pl'),
        ('Grand Baltic Hotel', 'Suite',  900.00, DATE '2026-01-01', CAST(NULL AS date),      'a.kowalska@gbh.pl'),
        ('Vistula Riverside',  'Double', 500.00, DATE '2026-01-01', CAST(NULL AS date),      'm.zielinska@vr.pl')
) AS v (hotel_name, type_name, price_per_night, valid_from, valid_to, created_by_email)
INNER JOIN hotel_booking.hotel AS h
    ON h.hotel_name = v.hotel_name
INNER JOIN hotel_booking.room_type AS rt
    ON rt.type_name = v.type_name
INNER JOIN hotel_booking.employee AS e
    ON e.email = v.created_by_email
   AND e.hotel_id = h.hotel_id
ON CONFLICT DO NOTHING;

-- 3.7 room
INSERT INTO hotel_booking.room (hotel_id, room_type_id, room_number)
SELECT h.hotel_id, rt.room_type_id, v.room_number
FROM (
    VALUES
        ('Grand Baltic Hotel', 'Double', '101'),
        ('Grand Baltic Hotel', 'Double', '102'),
        ('Grand Baltic Hotel', 'Suite',  '501'),
        ('Vistula Riverside',  'Double', '201')
) AS v (hotel_name, type_name, room_number)
INNER JOIN hotel_booking.hotel AS h
    ON h.hotel_name = v.hotel_name
INNER JOIN hotel_booking.room_type AS rt
    ON rt.type_name = v.type_name
ON CONFLICT (hotel_id, room_number) DO NOTHING;

-- 3.8 room_status_history
INSERT INTO hotel_booking.room_status_history
    (room_id, status_code, valid_from, valid_to, changed_by_employee_id)
SELECT r.room_id, v.status_code, v.valid_from, v.valid_to, e.employee_id
FROM (
    VALUES
        ('Grand Baltic Hotel', '101', 'AVAILABLE',   TIMESTAMPTZ '2026-01-01 00:00:00+01', TIMESTAMPTZ '2026-03-10 09:00:00+01', 'p.nowak@gbh.pl'),
        ('Grand Baltic Hotel', '101', 'MAINTENANCE', TIMESTAMPTZ '2026-03-10 09:00:00+01', TIMESTAMPTZ '2026-03-12 15:00:00+01', 'p.nowak@gbh.pl'),
        ('Grand Baltic Hotel', '101', 'AVAILABLE',   TIMESTAMPTZ '2026-03-12 15:00:00+01', CAST(NULL AS timestamptz),            'p.nowak@gbh.pl'),
        ('Vistula Riverside',  '201', 'AVAILABLE',   TIMESTAMPTZ '2026-01-01 00:00:00+01', CAST(NULL AS timestamptz),            't.wisniewski@vr.pl')
) AS v (hotel_name, room_number, status_code, valid_from, valid_to, changed_by_email)
INNER JOIN hotel_booking.hotel AS h
    ON h.hotel_name = v.hotel_name
INNER JOIN hotel_booking.room AS r
    ON r.hotel_id = h.hotel_id
   AND r.room_number = v.room_number
INNER JOIN hotel_booking.employee AS e
    ON e.email = v.changed_by_email
   AND e.hotel_id = h.hotel_id
ON CONFLICT DO NOTHING;

-- 3.9 reservation (no natural unique key, so WHERE NOT EXISTS)
INSERT INTO hotel_booking.reservation (hotel_id, guest_id, created_by_employee_id, created_at)
SELECT h.hotel_id, g.guest_id, e.employee_id, v.created_at
FROM (
    VALUES
        ('Grand Baltic Hotel', 'john.smith@mail.com',   'p.nowak@gbh.pl',          TIMESTAMPTZ '2026-07-01 10:15:00+02'),
        ('Grand Baltic Hotel', 'maria.garcia@mail.com', CAST(NULL AS varchar),     TIMESTAMPTZ '2026-07-03 21:40:00+02')
) AS v (hotel_name, guest_email, created_by_email, created_at)
INNER JOIN hotel_booking.hotel AS h
    ON h.hotel_name = v.hotel_name
INNER JOIN hotel_booking.guest AS g
    ON g.email = v.guest_email
LEFT JOIN hotel_booking.employee AS e          -- NULL e-mail = online booking
    ON e.email = v.created_by_email
   AND e.hotel_id = h.hotel_id
WHERE NOT EXISTS (
    SELECT 1
    FROM hotel_booking.reservation AS r
    WHERE r.hotel_id = h.hotel_id
      AND r.guest_id = g.guest_id
      AND r.created_at = v.created_at
);

-- 3.10 reservation_status_history
INSERT INTO hotel_booking.reservation_status_history
    (reservation_id, status_code, changed_at, changed_by_employee_id)
SELECT r.reservation_id, v.status_code, v.changed_at, e.employee_id
FROM (
    VALUES
        ('john.smith@mail.com',   TIMESTAMPTZ '2026-07-01 10:15:00+02', 'PENDING',    TIMESTAMPTZ '2026-07-01 10:15:00+02', 'p.nowak@gbh.pl'),
        ('john.smith@mail.com',   TIMESTAMPTZ '2026-07-01 10:15:00+02', 'CONFIRMED',  TIMESTAMPTZ '2026-07-01 10:20:00+02', 'p.nowak@gbh.pl'),
        ('john.smith@mail.com',   TIMESTAMPTZ '2026-07-01 10:15:00+02', 'CHECKED_IN', TIMESTAMPTZ '2026-08-10 14:05:00+02', 'p.nowak@gbh.pl'),
        ('maria.garcia@mail.com', TIMESTAMPTZ '2026-07-03 21:40:00+02', 'PENDING',    TIMESTAMPTZ '2026-07-03 21:40:00+02', CAST(NULL AS varchar)),
        ('maria.garcia@mail.com', TIMESTAMPTZ '2026-07-03 21:40:00+02', 'CANCELLED',  TIMESTAMPTZ '2026-07-05 12:00:00+02', 'p.nowak@gbh.pl')
) AS v (guest_email, reservation_created_at, status_code, changed_at, changed_by_email)
INNER JOIN hotel_booking.guest AS g
    ON g.email = v.guest_email
INNER JOIN hotel_booking.reservation AS r
    ON r.guest_id = g.guest_id
   AND r.created_at = v.reservation_created_at
LEFT JOIN hotel_booking.employee AS e
    ON e.email = v.changed_by_email
ON CONFLICT DO NOTHING;

-- 3.11 reservation_room: the agreed price is taken from the price list that is
--      valid on the arrival date (snapshot), not typed by hand.
INSERT INTO hotel_booking.reservation_room
    (reservation_id, hotel_id, room_id, stay_start, stay_end, guests_count, price_per_night, released_at)
SELECT r.reservation_id, r.hotel_id, rm.room_id, v.stay_start, v.stay_end,
       v.guests_count, rr.price_per_night, v.released_at
FROM (
    VALUES
        ('john.smith@mail.com',   TIMESTAMPTZ '2026-07-01 10:15:00+02', '101', DATE '2026-08-10', DATE '2026-08-14', 2::smallint, CAST(NULL AS timestamptz)),
        ('john.smith@mail.com',   TIMESTAMPTZ '2026-07-01 10:15:00+02', '501', DATE '2026-08-10', DATE '2026-08-14', 3::smallint, CAST(NULL AS timestamptz)),
        ('maria.garcia@mail.com', TIMESTAMPTZ '2026-07-03 21:40:00+02', '102', DATE '2026-08-12', DATE '2026-08-15', 2::smallint, TIMESTAMPTZ '2026-07-05 12:00:00+02')
) AS v (guest_email, reservation_created_at, room_number, stay_start, stay_end, guests_count, released_at)
INNER JOIN hotel_booking.guest AS g
    ON g.email = v.guest_email
INNER JOIN hotel_booking.reservation AS r
    ON r.guest_id = g.guest_id
   AND r.created_at = v.reservation_created_at
INNER JOIN hotel_booking.room AS rm
    ON rm.hotel_id = r.hotel_id
   AND rm.room_number = v.room_number
INNER JOIN hotel_booking.room_rate AS rr
    ON rr.hotel_id = rm.hotel_id
   AND rr.room_type_id = rm.room_type_id
   AND v.stay_start >= rr.valid_from
   AND (rr.valid_to IS NULL OR v.stay_start < rr.valid_to)
ON CONFLICT DO NOTHING;

-- 3.12 stay
INSERT INTO hotel_booking.stay
    (reservation_room_id, checked_in_at, checked_out_at,
     checked_in_by_employee_id, checked_out_by_employee_id)
SELECT rro.reservation_room_id, v.checked_in_at, v.checked_out_at, ein.employee_id, eout.employee_id
FROM (
    VALUES
        ('john.smith@mail.com', TIMESTAMPTZ '2026-07-01 10:15:00+02', '101', DATE '2026-08-10',
            TIMESTAMPTZ '2026-08-10 14:05:00+02', TIMESTAMPTZ '2026-08-14 10:30:00+02', 'p.nowak@gbh.pl', 'p.nowak@gbh.pl'),
        ('john.smith@mail.com', TIMESTAMPTZ '2026-07-01 10:15:00+02', '501', DATE '2026-08-10',
            TIMESTAMPTZ '2026-08-10 14:10:00+02', CAST(NULL AS timestamptz),            'p.nowak@gbh.pl', CAST(NULL AS varchar))
) AS v (guest_email, reservation_created_at, room_number, stay_start,
        checked_in_at, checked_out_at, checked_in_by_email, checked_out_by_email)
INNER JOIN hotel_booking.guest AS g
    ON g.email = v.guest_email
INNER JOIN hotel_booking.reservation AS r
    ON r.guest_id = g.guest_id
   AND r.created_at = v.reservation_created_at
INNER JOIN hotel_booking.room AS rm
    ON rm.hotel_id = r.hotel_id
   AND rm.room_number = v.room_number
INNER JOIN hotel_booking.reservation_room AS rro
    ON rro.reservation_id = r.reservation_id
   AND rro.room_id = rm.room_id
   AND rro.stay_start = v.stay_start
INNER JOIN hotel_booking.employee AS ein
    ON ein.email = v.checked_in_by_email
LEFT JOIN hotel_booking.employee AS eout
    ON eout.email = v.checked_out_by_email
ON CONFLICT (reservation_room_id) DO NOTHING;

-- 3.13 service_price
INSERT INTO hotel_booking.service_price
    (hotel_id, service_id, unit_price, valid_from, valid_to, created_by_employee_id)
SELECT h.hotel_id, s.service_id, v.unit_price, v.valid_from, v.valid_to, e.employee_id
FROM (
    VALUES
        ('Grand Baltic Hotel', 'Breakfast', 60.00, DATE '2026-01-01', CAST(NULL AS date), 'a.kowalska@gbh.pl'),
        ('Grand Baltic Hotel', 'Parking',   50.00, DATE '2026-01-01', CAST(NULL AS date), 'a.kowalska@gbh.pl'),
        ('Vistula Riverside',  'Breakfast', 55.00, DATE '2026-01-01', CAST(NULL AS date), 'm.zielinska@vr.pl')
) AS v (hotel_name, service_name, unit_price, valid_from, valid_to, created_by_email)
INNER JOIN hotel_booking.hotel AS h
    ON h.hotel_name = v.hotel_name
INNER JOIN hotel_booking.service AS s
    ON s.service_name = v.service_name
INNER JOIN hotel_booking.employee AS e
    ON e.email = v.created_by_email
   AND e.hotel_id = h.hotel_id
ON CONFLICT DO NOTHING;

-- 3.14 reservation_service (no natural unique key, so WHERE NOT EXISTS).
--      The service must be offered by the hotel of the reservation: the price
--      list row is found by hotel + service + validity on the service date.
INSERT INTO hotel_booking.reservation_service
    (reservation_id, hotel_id, service_price_id, quantity, unit_price,
     service_date, added_by_employee_id, added_at, cancelled_at)
SELECT r.reservation_id, r.hotel_id, sp.service_price_id, v.quantity, sp.unit_price,
       v.service_date, e.employee_id, v.added_at, v.cancelled_at
FROM (
    VALUES
        ('john.smith@mail.com', TIMESTAMPTZ '2026-07-01 10:15:00+02', 'Breakfast', 2::smallint, DATE '2026-08-11',
            'p.nowak@gbh.pl', TIMESTAMPTZ '2026-08-10 18:00:00+02', CAST(NULL AS timestamptz)),
        ('john.smith@mail.com', TIMESTAMPTZ '2026-07-01 10:15:00+02', 'Parking',   1::smallint, DATE '2026-08-10',
            'p.nowak@gbh.pl', TIMESTAMPTZ '2026-08-10 18:05:00+02', TIMESTAMPTZ '2026-08-10 19:00:00+02')
) AS v (guest_email, reservation_created_at, service_name, quantity, service_date,
        added_by_email, added_at, cancelled_at)
INNER JOIN hotel_booking.guest AS g
    ON g.email = v.guest_email
INNER JOIN hotel_booking.reservation AS r
    ON r.guest_id = g.guest_id
   AND r.created_at = v.reservation_created_at
INNER JOIN hotel_booking.service AS s
    ON s.service_name = v.service_name
INNER JOIN hotel_booking.service_price AS sp
    ON sp.hotel_id = r.hotel_id
   AND sp.service_id = s.service_id
   AND v.service_date >= sp.valid_from
   AND (sp.valid_to IS NULL OR v.service_date < sp.valid_to)
INNER JOIN hotel_booking.employee AS e
    ON e.email = v.added_by_email
   AND e.hotel_id = r.hotel_id
WHERE NOT EXISTS (
    SELECT 1
    FROM hotel_booking.reservation_service AS rs
    WHERE rs.reservation_id = r.reservation_id
      AND rs.service_price_id = sp.service_price_id
      AND rs.service_date = v.service_date
      AND rs.added_at = v.added_at
);

-- 3.15 payment (no natural unique key, so WHERE NOT EXISTS).
--      John Smith: 1000 + 4560 = 5560 = 4 x 460 + 4 x 900 + 2 x 60.
--      Maria Garcia: deposit is refunded after the cancellation (new row).
INSERT INTO hotel_booking.payment
    (reservation_id, payment_type, payment_method, amount, currency_code, paid_at,
     processed_by_employee_id)
SELECT r.reservation_id, v.payment_type, v.payment_method, v.amount, v.currency_code,
       v.paid_at, e.employee_id
FROM (
    VALUES
        ('john.smith@mail.com',   TIMESTAMPTZ '2026-07-01 10:15:00+02', 'DEPOSIT', 'CARD',   1000.00, 'PLN',
            TIMESTAMPTZ '2026-07-01 10:25:00+02', 'p.nowak@gbh.pl'),
        ('john.smith@mail.com',   TIMESTAMPTZ '2026-07-01 10:15:00+02', 'FINAL',   'CARD',   4560.00, 'PLN',
            TIMESTAMPTZ '2026-08-14 10:35:00+02', 'p.nowak@gbh.pl'),
        ('maria.garcia@mail.com', TIMESTAMPTZ '2026-07-03 21:40:00+02', 'DEPOSIT', 'ONLINE',  460.00, 'PLN',
            TIMESTAMPTZ '2026-07-03 21:45:00+02', CAST(NULL AS varchar)),
        ('maria.garcia@mail.com', TIMESTAMPTZ '2026-07-03 21:40:00+02', 'REFUND',  'ONLINE',  460.00, 'PLN',
            TIMESTAMPTZ '2026-07-05 12:10:00+02', CAST(NULL AS varchar))
) AS v (guest_email, reservation_created_at, payment_type, payment_method, amount, currency_code,
        paid_at, processed_by_email)
INNER JOIN hotel_booking.guest AS g
    ON g.email = v.guest_email
INNER JOIN hotel_booking.reservation AS r
    ON r.guest_id = g.guest_id
   AND r.created_at = v.reservation_created_at
LEFT JOIN hotel_booking.employee AS e
    ON e.email = v.processed_by_email
   AND e.hotel_id = r.hotel_id
WHERE NOT EXISTS (
    SELECT 1
    FROM hotel_booking.payment AS p
    WHERE p.reservation_id = r.reservation_id
      AND p.payment_type = v.payment_type
      AND p.paid_at = v.paid_at
);


-- -----------------------------------------------------------------------------
-- 4. record_ts column (task step 9)
--    ADD COLUMN ... NOT NULL DEFAULT current_date: PostgreSQL fills the
--    default into every EXISTING row, so the NOT NULL rule is satisfied and the
--    statement does not fail on tables that already contain data.
--    IF NOT EXISTS makes the statements safe to rerun.
-- -----------------------------------------------------------------------------
ALTER TABLE hotel_booking.hotel
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.room_type
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.service
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.guest
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.employee
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.room_rate
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.room
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.room_status_history
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.reservation
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.reservation_status_history
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.reservation_room
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.stay
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.service_price
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.reservation_service
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;
ALTER TABLE hotel_booking.payment
    ADD COLUMN IF NOT EXISTS record_ts date NOT NULL DEFAULT current_date;


-- -----------------------------------------------------------------------------
-- 5. Checks
-- -----------------------------------------------------------------------------

-- 5.1 record_ts is set for all existing rows: rows_without_record_ts must be 0
--     in every line, total_rows must be >= 2 (20+ rows in all tables).
SELECT t.table_name,
       t.total_rows,
       t.rows_without_record_ts,
       t.earliest_record_ts
FROM (
    SELECT 'hotel' AS table_name, count(*) AS total_rows,
           count(*) FILTER (WHERE record_ts IS NULL) AS rows_without_record_ts,
           min(record_ts) AS earliest_record_ts
    FROM hotel_booking.hotel
    UNION ALL
    SELECT 'room_type', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.room_type
    UNION ALL
    SELECT 'service', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.service
    UNION ALL
    SELECT 'guest', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.guest
    UNION ALL
    SELECT 'employee', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.employee
    UNION ALL
    SELECT 'room_rate', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.room_rate
    UNION ALL
    SELECT 'room', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.room
    UNION ALL
    SELECT 'room_status_history', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.room_status_history
    UNION ALL
    SELECT 'reservation', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.reservation
    UNION ALL
    SELECT 'reservation_status_history', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.reservation_status_history
    UNION ALL
    SELECT 'reservation_room', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.reservation_room
    UNION ALL
    SELECT 'stay', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.stay
    UNION ALL
    SELECT 'service_price', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.service_price
    UNION ALL
    SELECT 'reservation_service', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.reservation_service
    UNION ALL
    SELECT 'payment', count(*), count(*) FILTER (WHERE record_ts IS NULL), min(record_ts)
    FROM hotel_booking.payment
) AS t
ORDER BY t.table_name;

-- 5.2 Column default and nullability of record_ts in every table
--     (expected: is_nullable = NO, column_default = CURRENT_DATE, 15 rows).
SELECT c.table_name, c.data_type, c.is_nullable, c.column_default
FROM information_schema.columns AS c
WHERE c.table_schema = 'hotel_booking'
  AND c.column_name = 'record_ts'
ORDER BY c.table_name;
