/*
  schema.sql
  Database Systems term project 2569, topic 27: Market Stall Rental & Reservation
  Target: SQL Server 2019 Express
  Schema version 0.1 (frozen, please don't change table structure without telling the team)
  Author: Data Architect & DBA

  Order to run things: schema.sql, then data.sql, logic.sql, queries.sql

    sqlcmd -S .\SQLEXPRESS -E -f 65001 -i schema.sql

  Safe to re-run. It drops all 9 tables (data goes with them) and rebuilds
  them, so you have to run data.sql and logic.sql again afterwards.

  Heads up: the "code" columns (stalls.status, leases.status,
  utility_charges.utility_type, payments.payment_type) use a binary collation,
  so they're case-sensitive. Only lowercase values pass, 'Rented' will fail.

  Constraint names follow this pattern:
    pk_<table>            primary key
    fk_<table>_<column>   foreign key
    uq_<table>_<column>   unique / alternate key
    ck_<table>_<rule>     check
    df_<table>_<column>   default
    ix_<table>_<column>   index
*/

SET NOCOUNT ON;
GO

-- create the database the first time only
IF DB_ID(N'market_db') IS NULL
    CREATE DATABASE market_db COLLATE Thai_CI_AS;
GO

USE market_db;
GO

-- drop children before parents, otherwise the FKs get in the way
DROP TABLE IF EXISTS dbo.payments;
DROP TABLE IF EXISTS dbo.fine_logs;
DROP TABLE IF EXISTS dbo.utility_charges;
DROP TABLE IF EXISTS dbo.leases;
DROP TABLE IF EXISTS dbo.stalls;
DROP TABLE IF EXISTS dbo.staff;
DROP TABLE IF EXISTS dbo.market_days;
DROP TABLE IF EXISTS dbo.merchants;
DROP TABLE IF EXISTS dbo.stall_zones;
GO


-- ---------------------------------------------------------------------
-- Parent tables (these don't reference anything)
-- ---------------------------------------------------------------------

-- Zones of the market. Each zone sets its own rent and deposit % (BR4).
CREATE TABLE dbo.stall_zones (
    zone_id          INT IDENTITY(1,1) NOT NULL,
    zone_name        NVARCHAR(50)      NOT NULL,
    base_rent        DECIMAL(10,2)     NOT NULL,   -- per market day
    deposit_percent  DECIMAL(5,2)      NOT NULL,   -- deposit = rent * percent / 100
    CONSTRAINT pk_stall_zones PRIMARY KEY (zone_id),
    CONSTRAINT uq_stall_zones_zone_name UNIQUE (zone_name),
    CONSTRAINT ck_stall_zones_base_rent CHECK (base_rent >= 0),
    CONSTRAINT ck_stall_zones_deposit_percent CHECK (deposit_percent BETWEEN 0 AND 100)
);
GO

-- Merchants who rent stalls. Phone has to be unique since it's how we tell people apart.
CREATE TABLE dbo.merchants (
    merchant_id    INT IDENTITY(1,1) NOT NULL,
    merchant_name  NVARCHAR(100)     NOT NULL,
    phone          VARCHAR(15)       NOT NULL,
    goods_type     NVARCHAR(50)      NULL,
    CONSTRAINT pk_merchants PRIMARY KEY (merchant_id),
    CONSTRAINT uq_merchants_phone UNIQUE (phone)
);
GO

-- One row for each day the market runs (BR2)
CREATE TABLE dbo.market_days (
    market_day_id  INT IDENTITY(1,1) NOT NULL,
    market_date    DATE              NOT NULL,
    is_open        BIT               NOT NULL
        CONSTRAINT df_market_days_is_open DEFAULT (1),
    CONSTRAINT pk_market_days PRIMARY KEY (market_day_id),
    CONSTRAINT uq_market_days_market_date UNIQUE (market_date)
);
GO

-- BR6
CREATE TABLE dbo.staff (
    staff_id    INT IDENTITY(1,1) NOT NULL,
    staff_name  NVARCHAR(100)     NOT NULL,
    position    NVARCHAR(50)      NULL,
    CONSTRAINT pk_staff PRIMARY KEY (staff_id)
);
GO


-- ---------------------------------------------------------------------
-- Child tables
-- ---------------------------------------------------------------------

-- stalls.status only describes the physical stall (BR2).
-- Whether it's rented or not is tracked in leases.status, not here.
CREATE TABLE dbo.stalls (
    stall_id    INT IDENTITY(1,1) NOT NULL,
    zone_id     INT               NOT NULL,
    stall_code  NVARCHAR(10)      NOT NULL,
    size_sqm    DECIMAL(5,2)      NULL,
    status      VARCHAR(15) COLLATE Latin1_General_100_BIN2 NOT NULL
        CONSTRAINT df_stalls_status DEFAULT ('available'),
    CONSTRAINT pk_stalls PRIMARY KEY (stall_id),
    CONSTRAINT uq_stalls_stall_code UNIQUE (stall_code),
    CONSTRAINT fk_stalls_zone_id FOREIGN KEY (zone_id)
        REFERENCES dbo.stall_zones (zone_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT ck_stalls_size_sqm CHECK (size_sqm > 0),
    CONSTRAINT ck_stalls_status CHECK (status IN ('available', 'maintenance'))
);
GO

-- A lease is one stall for one market day.
-- rent_price / deposit_amount are copied at booking time so later price
-- changes in stall_zones don't rewrite history (BR4).
-- Double booking (BR1) is stopped by trg_prevent_double_stall_booking in
-- logic.sql instead of a unique index, since a cancelled lease is allowed
-- to share the same stall + day with a new one.
CREATE TABLE dbo.leases (
    lease_id        INT IDENTITY(1,1) NOT NULL,
    stall_id        INT               NOT NULL,
    merchant_id     INT               NOT NULL,
    market_day_id   INT               NOT NULL,
    staff_id        INT               NOT NULL,
    rent_price      DECIMAL(10,2)     NOT NULL,
    deposit_amount  DECIMAL(10,2)     NOT NULL,
    status          VARCHAR(15) COLLATE Latin1_General_100_BIN2 NOT NULL
        CONSTRAINT df_leases_status DEFAULT ('rented'),
    created_at      DATETIME2(0)      NOT NULL
        CONSTRAINT df_leases_created_at DEFAULT (SYSDATETIME()),
    cancelled_at    DATETIME2(0)      NULL,
    CONSTRAINT pk_leases PRIMARY KEY (lease_id),
    CONSTRAINT fk_leases_stall_id FOREIGN KEY (stall_id)
        REFERENCES dbo.stalls (stall_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT fk_leases_merchant_id FOREIGN KEY (merchant_id)
        REFERENCES dbo.merchants (merchant_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT fk_leases_market_day_id FOREIGN KEY (market_day_id)
        REFERENCES dbo.market_days (market_day_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT fk_leases_staff_id FOREIGN KEY (staff_id)
        REFERENCES dbo.staff (staff_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT ck_leases_rent_price CHECK (rent_price >= 0),
    CONSTRAINT ck_leases_deposit_amount CHECK (deposit_amount >= 0),
    CONSTRAINT ck_leases_status CHECK (status IN ('rented', 'cancelled')),
    -- BR5: cancelled needs a cancelled_at, rented must not have one
    CONSTRAINT ck_leases_cancelled_at CHECK (
        (status = 'rented'    AND cancelled_at IS NULL) OR
        (status = 'cancelled' AND cancelled_at IS NOT NULL)
    )
);
GO

-- Water / electricity per lease (BR4).
-- unit_rate is whatever the rate was on the day we recorded it.
-- charge_amount is computed on the fly (not PERSISTED), so never try to
-- insert or update it directly.
CREATE TABLE dbo.utility_charges (
    charge_id      INT IDENTITY(1,1) NOT NULL,
    lease_id       INT               NOT NULL,
    utility_type   VARCHAR(12) COLLATE Latin1_General_100_BIN2 NOT NULL,
    units_used     DECIMAL(8,2)      NOT NULL,
    unit_rate      DECIMAL(8,2)      NOT NULL,
    charge_amount  AS CAST(units_used * unit_rate AS DECIMAL(18,2)),
    recorded_at    DATETIME2(0)      NOT NULL
        CONSTRAINT df_utility_charges_recorded_at DEFAULT (SYSDATETIME()),
    CONSTRAINT pk_utility_charges PRIMARY KEY (charge_id),
    CONSTRAINT uq_utility_charges_lease_id_utility_type UNIQUE (lease_id, utility_type),
    CONSTRAINT fk_utility_charges_lease_id FOREIGN KEY (lease_id)
        REFERENCES dbo.leases (lease_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT ck_utility_charges_utility_type CHECK (utility_type IN ('water', 'electricity')),
    CONSTRAINT ck_utility_charges_units_used CHECK (units_used >= 0),
    CONSTRAINT ck_utility_charges_unit_rate CHECK (unit_rate >= 0)
);
GO

-- BR6
CREATE TABLE dbo.fine_logs (
    fine_id   INT IDENTITY(1,1) NOT NULL,
    lease_id  INT               NOT NULL,
    staff_id  INT               NOT NULL,
    reason    NVARCHAR(200)     NOT NULL,
    amount    DECIMAL(10,2)     NOT NULL,
    fined_at  DATETIME2(0)      NOT NULL
        CONSTRAINT df_fine_logs_fined_at DEFAULT (SYSDATETIME()),
    CONSTRAINT pk_fine_logs PRIMARY KEY (fine_id),
    CONSTRAINT fk_fine_logs_lease_id FOREIGN KEY (lease_id)
        REFERENCES dbo.leases (lease_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT fk_fine_logs_staff_id FOREIGN KEY (staff_id)
        REFERENCES dbo.staff (staff_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT ck_fine_logs_amount CHECK (amount > 0)
);
GO

-- Every bit of money that moves, in or out (BR3, BR5, BR6).
-- payment_type tells you the direction:
--   in:  rent, deposit, utility, fine
--   out: deposit_refund
-- (there used to be a fine_id column here, dropped in v0.1)
CREATE TABLE dbo.payments (
    payment_id    INT IDENTITY(1,1) NOT NULL,
    lease_id      INT               NOT NULL,
    staff_id      INT               NOT NULL,
    payment_type  VARCHAR(15) COLLATE Latin1_General_100_BIN2 NOT NULL,
    amount        DECIMAL(10,2)     NOT NULL,
    paid_at       DATETIME2(0)      NOT NULL
        CONSTRAINT df_payments_paid_at DEFAULT (SYSDATETIME()),
    CONSTRAINT pk_payments PRIMARY KEY (payment_id),
    CONSTRAINT fk_payments_lease_id FOREIGN KEY (lease_id)
        REFERENCES dbo.leases (lease_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT fk_payments_staff_id FOREIGN KEY (staff_id)
        REFERENCES dbo.staff (staff_id)
        ON DELETE NO ACTION ON UPDATE NO ACTION,
    CONSTRAINT ck_payments_payment_type CHECK (
        payment_type IN ('rent', 'deposit', 'utility', 'fine', 'deposit_refund')
    ),
    CONSTRAINT ck_payments_amount CHECK (amount > 0)
);
GO


-- ---------------------------------------------------------------------
-- FK indexes (first pass, checklist 3.2)
-- SQL Server doesn't index foreign keys for you, so we do it by hand.
-- More indexes will be added after the 10 queries are finished.
-- ---------------------------------------------------------------------

CREATE INDEX ix_stalls_zone_id ON dbo.stalls (zone_id);

-- the double-booking trigger looks up leases by stall + day, so it needs this one
CREATE INDEX ix_leases_stall_id_market_day_id
    ON dbo.leases (stall_id, market_day_id) INCLUDE (status);
CREATE INDEX ix_leases_market_day_id ON dbo.leases (market_day_id);
CREATE INDEX ix_leases_merchant_id   ON dbo.leases (merchant_id);
CREATE INDEX ix_leases_staff_id      ON dbo.leases (staff_id);

-- no separate index for utility_charges.lease_id: the unique key
-- uq_utility_charges_lease_id_utility_type already starts with it

CREATE INDEX ix_fine_logs_lease_id ON dbo.fine_logs (lease_id);
CREATE INDEX ix_fine_logs_staff_id ON dbo.fine_logs (staff_id);

CREATE INDEX ix_payments_lease_id ON dbo.payments (lease_id);
CREATE INDEX ix_payments_staff_id ON dbo.payments (staff_id);
GO

-- quick sanity check: list the tables with their column and FK counts
SELECT t.name AS table_name,
       (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id) AS column_count,
       (SELECT COUNT(*) FROM sys.foreign_keys f WHERE f.parent_object_id = t.object_id) AS fk_count
FROM sys.tables t
ORDER BY t.name;
GO

PRINT 'schema.sql finished: 9 tables created.';
GO
