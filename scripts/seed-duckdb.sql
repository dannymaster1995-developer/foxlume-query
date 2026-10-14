-- Sample DuckDB database for Foxlume Query driver and UI tests. Run against a fresh file:
--   .build/debug/fqprobe --kind duckdb --file ../../.dbtest/sample.duckdb query "$(cat scripts/seed-duckdb.sql)"
-- DuckDB does not allow foreign keys across schemas, so sales.orders references sales.customers,
-- and sales.customers.user_id points at main.users without a constraint.

CREATE SCHEMA sales;

CREATE SEQUENCE main.users_id_seq START 1;
CREATE TABLE main.users (
    id INTEGER PRIMARY KEY DEFAULT nextval('main.users_id_seq'),
    email VARCHAR NOT NULL UNIQUE,
    name VARCHAR NOT NULL,
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMP NOT NULL DEFAULT TIMESTAMP '2024-01-01 09:00:00'
);
COMMENT ON TABLE main.users IS 'Application users';
COMMENT ON COLUMN main.users.email IS 'Login e-mail, unique';
INSERT INTO main.users (email, name, active, created_at) VALUES
    ('zoe@example.com', 'Zoë Müller', true, TIMESTAMP '2024-01-05 08:30:00'),
    ('bjorn@example.com', 'Björn Larsen', true, TIMESTAMP '2024-02-11 14:00:00'),
    ('carlos@example.com', 'Carlos Mendes', false, TIMESTAMP '2024-03-20 19:45:00'),
    ('dana@example.com', 'Dana Kim', true, TIMESTAMP '2024-04-02 07:15:00');

CREATE TABLE sales.customers (
    id INTEGER PRIMARY KEY,
    name VARCHAR NOT NULL,
    user_id INTEGER,
    city VARCHAR
);
COMMENT ON COLUMN sales.customers.user_id IS 'main.users.id (cross-schema, not enforced)';
INSERT INTO sales.customers VALUES
    (1, 'Zoë Coffee', 1, 'Zürich'),
    (2, 'Björn Books', 2, 'Oslo'),
    (3, 'Carlos Studio', 3, 'Lisbon'),
    (4, 'Walk-in', NULL, NULL);

CREATE TABLE sales.orders (
    id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES sales.customers (id),
    ordered_at DATE NOT NULL,
    status VARCHAR NOT NULL DEFAULT 'new',
    total DECIMAL(12, 2) NOT NULL,
    note VARCHAR
);
COMMENT ON TABLE sales.orders IS 'Ten thousand generated orders';
CREATE INDEX orders_ordered_at_idx ON sales.orders (ordered_at);
CREATE INDEX orders_customer_status_idx ON sales.orders (customer_id, status);
INSERT INTO sales.orders
SELECT
    i,
    1 + i % 4,
    DATE '2024-01-01' + CAST(i % 366 AS INTEGER),
    CASE i % 5 WHEN 0 THEN 'cancelled' WHEN 1 THEN 'new' WHEN 2 THEN 'paid' ELSE 'shipped' END,
    CAST(round(10 + (i * 7919 % 100000) / 100.0, 2) AS DECIMAL(12, 2)),
    CASE WHEN i % 97 = 0 THEN 'gift wrap' END
FROM range(1, 10001) AS r(i);

-- No primary key: edits match rows by every column.
CREATE TABLE main.event_log (
    logged_at TIMESTAMP NOT NULL,
    level VARCHAR NOT NULL,
    message VARCHAR
);
INSERT INTO main.event_log VALUES
    (TIMESTAMP '2024-05-01 10:00:00', 'info', 'server started'),
    (TIMESTAMP '2024-05-01 10:05:00', 'warn', 'slow query: 1.2 s'),
    (TIMESTAMP '2024-05-01 10:07:30', 'error', 'disk almost full'),
    (TIMESTAMP '2024-05-01 10:07:30', 'error', 'disk almost full');

CREATE VIEW main.user_summary AS
SELECT u.id, u.name, u.email, count(o.id) AS order_count, coalesce(sum(o.total), 0) AS total_spent
FROM main.users AS u
LEFT JOIN sales.customers AS c ON c.user_id = u.id
LEFT JOIN sales.orders AS o ON o.customer_id = c.id
GROUP BY u.id, u.name, u.email;
COMMENT ON VIEW main.user_summary IS 'Orders per user';

CREATE TYPE main.mood AS ENUM ('sad', 'ok', 'happy');
CREATE TABLE main.types_demo (
    id INTEGER PRIMARY KEY,
    b BOOLEAN,
    i8 TINYINT,
    i16 SMALLINT,
    i32 INTEGER,
    i64 BIGINT,
    u8 UTINYINT,
    u16 USMALLINT,
    u32 UINTEGER,
    u64 UBIGINT,
    i128 HUGEINT,
    u128 UHUGEINT,
    f FLOAT,
    d DOUBLE,
    dec DECIMAL(12, 4),
    dec38 DECIMAL(38, 10),
    s VARCHAR,
    bl BLOB,
    dt DATE,
    tm TIME,
    ts TIMESTAMP,
    ts_s TIMESTAMP_S,
    ts_ms TIMESTAMP_MS,
    ts_ns TIMESTAMP_NS,
    tstz TIMESTAMPTZ,
    ttz TIMETZ,
    iv INTERVAL,
    u UUID,
    l INTEGER[],
    arr DOUBLE[3],
    st STRUCT(a INTEGER, b VARCHAR),
    m MAP(VARCHAR, INTEGER),
    e mood,
    j JSON,
    bits BIT,
    un UNION(num INTEGER, str VARCHAR)
);
INSERT INTO main.types_demo VALUES
    (1, true, -128, 32767, -2147483648, 9223372036854775807, 255, 65535, 4294967295, 18446744073709551615,
     -170141183460469231731687303715884105728, 340282366920938463463374607431768211455,
     3.14, 0.1 + 0.2, 12345678.9012, 1234567890123456789012345678.0123456789,
     'Zoë ✓', '\xDE\xAD\xBE\xEF'::BLOB, DATE '2024-02-29', TIME '13:45:30.123456',
     TIMESTAMP '2024-02-29 13:45:30.5', TIMESTAMP_S '2024-02-29 13:45:30', TIMESTAMP_MS '2024-02-29 13:45:30.123',
     TIMESTAMP_NS '2024-02-29 13:45:30.123456789', TIMESTAMPTZ '2024-02-29 13:45:30+00', TIMETZ '13:45:30+05:30',
     INTERVAL '1 year 2 months 3 days 04:05:06.789', '550e8400-e29b-41d4-a716-446655440000',
     [1, 2, NULL], [1.5, 2.5, 3.5], {'a': 1, 'b': 'x, y'}, MAP {'one': 1, 'two': 2}, 'happy',
     '{"k": [1, 2, {"n": null}]}', '10110', union_value(str := 'text')),
    (2, false, 127, -32768, 2147483647, -9223372036854775808, 0, 0, 0, 0,
     170141183460469231731687303715884105727, 0,
     -1.5e-10, 1e300, -0.0001, -0.0000000001,
     '', ''::BLOB, DATE '0044-03-15 (BC)', TIME '00:00:00',
     TIMESTAMP '1969-12-31 23:59:59.999999', TIMESTAMP_S '1970-01-01 00:00:00', TIMESTAMP_MS '1970-01-01 00:00:00.001',
     TIMESTAMP_NS '1970-01-01 00:00:00.000000001', TIMESTAMPTZ '2024-07-01 00:00:00+00', TIMETZ '00:00:00-03:30',
     INTERVAL '-36 hours 30 minutes', '00000000-0000-0000-0000-000000000000',
     [], [0.0, -0.5, 1e20], {'a': NULL, 'b': 'it''s'}, MAP {}, 'sad',
     '[]', '0', union_value(num := 42)),
    (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);
COMMENT ON TABLE main.types_demo IS 'One column per DuckDB type; row 3 is all NULL';

CHECKPOINT;
