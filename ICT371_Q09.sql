-- ICT371 Advanced Database | Question 9: Farmer Cooperative Maize Deliveries
-- Name: Nawa Sumbwanyambe | Student number: 202308788
-- DBMS: PostgreSQL (PL/pgSQL; scheduling with the pg_cron extension)

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- ==== (a) Database: create the tables
CREATE TABLE farmers (
    farmer_id     SERIAL       PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL        PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL,
    unit_rate    NUMERIC(10,2) NOT NULL,      -- always filled in by the trigger
    total_value  NUMERIC(12,2) NOT NULL,      -- always filled in by the trigger
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE          PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

-- ==== (b) Function fn_maize_rate: A = K5, B = K4, C = K3 per kg
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$;

-- ==== (d) Trigger first: BEFORE INSERT OR UPDATE pricing rule
CREATE OR REPLACE FUNCTION trg_fn_deliveries_price()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);                   -- overrides any supplied value
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);    -- overrides any supplied value
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_deliveries_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_deliveries_price();

-- ==== (c) Procedure pr_receive_delivery
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade VARCHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;

    PERFORM fn_maize_rate(p_grade);          -- validates the grade (NULL or unsupported => error)

    -- Only the basic fields: the trigger supplies unit_rate and total_value.
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- ==== (e) View v_farmer_amount_due
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0)::NUMERIC(12,2) AS amount_due
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id
      AND d.is_paid = FALSE                -- in ON so farmers with no unpaid deliveries still appear
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- ==== (f) Composite index: farmer_id (equality) then delivered_on (range)
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

-- ==== (g) Scheduled job: pr_refresh_purchases
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE          -- replace, never add on top of old totals
    SET total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

-- Requires: CREATE EXTENSION pg_cron;
SELECT cron.schedule(
    'refresh_purchases_daily',
    '30 1 * * *',                                      -- every day at 01:30
    $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$    -- previous day
);

-- ==== (a) Seed data: loaded AFTER the trigger exists (3 farmers, 6 deliveries, all grades, both payment states)
INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Mwansa Kapambwe'),
    ('F002', 'Lweendo Mulenga'),
    ('F003', 'Bupe Chola');

-- three through the procedure (always unpaid)
CALL pr_receive_delivery(1, 'A', 200.00, '2026-11-23');
CALL pr_receive_delivery(2, 'B', 150.50, '2026-11-24');
CALL pr_receive_delivery(1, 'C', 300.00, '2026-11-24');

-- three through direct SQL; rate/value omitted (trigger fills them) and is_paid TRUE for some
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (3, 'A', 120.00, '2026-11-23', TRUE),
    (2, 'A',  80.00, '2026-11-24', TRUE),
    (3, 'B', 100.00, '2026-11-24', TRUE);

SELECT * FROM farmers ORDER BY farmer_id;
SELECT * FROM deliveries ORDER BY delivery_id;

-- ==== (b) Function tests
SELECT g AS grade, fn_maize_rate(g) AS rate FROM (VALUES ('A'), ('B'), ('C')) AS t(g);
DO $$ BEGIN PERFORM fn_maize_rate(NULL); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (c) Procedure tests
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'D', 10, '2026-11-25');  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, NULL, 10, '2026-11-25'); EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 0, '2026-11-25');   EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, '2026-11-25');  EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 10, NULL);          EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (d) Trigger tests: direct SQL follows the same pricing rule
-- Supplying a wrong rate/value is ignored: the trigger overwrites them.
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (2, 'C', 50.00, 99.00, 99999.00, '2026-11-25');
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries ORDER BY delivery_id DESC LIMIT 1;  -- 3.00 / 150.00
DO $$ BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on) VALUES (1, 'A', 0, '2026-11-25');
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;
-- Changing the grade or weight with UPDATE re-prices the row
UPDATE deliveries SET grade = 'B' WHERE delivery_id = 7;
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;   -- 4.00 / 200.00
DO $$ BEGIN UPDATE deliveries SET weight_kg = -1 WHERE delivery_id = 7;
       EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'REJECTED: %', SQLERRM; END $$;

-- ==== (e) View: Bupe (F003, only paid deliveries) shows 0
SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- ==== (f) EXPLAIN
ANALYZE deliveries;
SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index plan
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN '2026-11-23' AND '2026-11-25';
RESET enable_seqscan;

-- ==== (g) Run the job twice: totals replaced, not added
CALL pr_refresh_purchases('2026-11-24');
SELECT * FROM daily_purchases ORDER BY purchase_date;
CALL pr_refresh_purchases('2026-11-24');
CALL pr_refresh_purchases('2026-11-23');
SELECT * FROM daily_purchases ORDER BY purchase_date;
SELECT jobname, schedule, command FROM cron.job WHERE jobname = 'refresh_purchases_daily';
