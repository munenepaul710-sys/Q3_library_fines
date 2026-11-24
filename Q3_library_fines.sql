-- =====================================================================
-- ICT371 Advanced Database | Question 3: Library Returns and Overdue Fines
-- Dialect: PostgreSQL (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Fine rule: K2 per day after due_on; returning on the due date = K0.
-- =====================================================================

-- (a) DATABASE AND SEED DATA ------------------------------------------
DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

CREATE TABLE books (
    book_id SERIAL       PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL        PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books (book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL    PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans (loan_id),
    old_returned_on  DATE,
    new_returned_on  DATE,
    changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE          PRIMARY KEY,
    overdue_count INTEGER       NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Operating System Concepts');

-- Dates are relative to today so the examples stay valid whenever run.
-- Returned loans carry their final fine (K2 x days late).
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Chanda Mwila',  CURRENT_DATE - 30, CURRENT_DATE - 16, NULL,             0),  -- open, overdue
    (1, 'Mutale Banda',  CURRENT_DATE -  5, CURRENT_DATE +  9, NULL,             0),  -- open, on time
    (2, 'Natasha Phiri', CURRENT_DATE - 40, CURRENT_DATE - 26, CURRENT_DATE - 20, 12), -- returned 6 days late
    (2, 'Bwalya Zulu',   CURRENT_DATE - 20, CURRENT_DATE -  6, CURRENT_DATE -  8, 0),  -- returned early
    (3, 'Kelvin Tembo',  CURRENT_DATE - 25, CURRENT_DATE - 11, CURRENT_DATE - 11, 0),  -- returned on due date
    (3, 'Mwansa Lungu',  CURRENT_DATE - 18, CURRENT_DATE -  4, NULL,             0);  -- open, overdue

-- (b) FUNCTION ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_due       DATE;
    v_returned  DATE;
    v_end       DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'The as-of date must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- Earlier of the as-of date and the return date (if any)
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);       -- minimum of zero
END;
$$;

-- (c) PROCEDURE --------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'The return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
    END IF;

    -- One UPDATE stores the return date and the final fine together.
    -- The row still has returned_on NULL here, so fn_loan_fine uses p_returned_on as the end date.
    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) TRIGGER ----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- Demonstration: return the on-time open loan (loan 2) today
SELECT fn_loan_fine(1, CURRENT_DATE) AS fine_for_open_overdue_loan_1;
CALL pr_return_loan(2, CURRENT_DATE);
SELECT loan_id, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit;

-- Rejected calls:
-- CALL pr_return_loan(2, CURRENT_DATE);        -- already returned
-- CALL pr_return_loan(99, CURRENT_DATE);       -- unknown loan
-- CALL pr_return_loan(1, CURRENT_DATE - 100);  -- before borrowed_on

-- (e) VIEW -------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) INDEX ------------------------------------------------------------
-- Justification: a partial index holds only unreturned loans (a small
-- fraction of all loans) keyed by book_id, so "unreturned loans of this
-- book" is answered from a compact index.
CREATE INDEX idx_loans_unreturned_by_book ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;   -- only so the plan is visible on a tiny table
EXPLAIN
SELECT *
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) SCHEDULED JOB ----------------------------------------------------
-- Counts loans that are overdue and still unreturned on p_as_of and sums
-- their fines as at that date. The upsert replaces the same snapshot_date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'The as-of date must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)   -- still unreturned as of that date
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);   -- rerun replaces the same snapshot row
SELECT * FROM overdue_summary;

-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_overdue_daily',
    '10 0 * * *',                                   -- every day at 00:10
    $job$CALL pr_refresh_overdue(CURRENT_DATE)$job$
);
