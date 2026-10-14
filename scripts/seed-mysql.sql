SET NAMES utf8mb4;
DROP VIEW IF EXISTS order_summary;
DROP TABLE IF EXISTS orders, users, types_demo, no_pk_log;

CREATE TABLE users (
    id int unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
    email varchar(255) NOT NULL UNIQUE,
    full_name varchar(255),
    country char(2) DEFAULT 'VN',
    is_active tinyint(1) NOT NULL DEFAULT 1,
    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='Application users';

CREATE TABLE orders (
    id bigint unsigned NOT NULL AUTO_INCREMENT PRIMARY KEY,
    user_id int unsigned NOT NULL,
    status varchar(20) NOT NULL DEFAULT 'pending',
    total decimal(10,2) NOT NULL,
    currency char(3) NOT NULL DEFAULT 'USD',
    shipping_address varchar(500),
    notes text,
    paid_at datetime NULL,
    KEY orders_user_id_idx (user_id),
    KEY orders_status_idx (status),
    CONSTRAINT orders_user_fk FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE types_demo (
    id int NOT NULL PRIMARY KEY,
    small smallint,
    big bigint,
    real_value float,
    double_value double,
    money_value decimal(12,4),
    flag tinyint(1),
    day date,
    moment datetime(3),
    doc json,
    raw varbinary(16),
    blob_value blob,
    quote_text text
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO users (email, full_name, country) VALUES
 ('zoe.muller@example.com', 'Zoë Müller', 'DE'),
 ('bjorn.larsen@example.com', 'Björn Larsen', 'NO'),
 ('alice@example.com', 'Alice Martin', 'US'),
 ('bob@example.com', 'Bob Smith', 'GB'),
 ('yuki@example.com', 'Yuki Tanaka', 'JP');

INSERT INTO orders (user_id, status, total, currency, shipping_address, notes, paid_at)
WITH RECURSIVE seq(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM seq WHERE g < 250)
SELECT 1 + (g % 5),
       ELT(1 + (g % 5), 'pending','paid','shipped','delivered','cancelled'),
       ROUND(10 + g * 3.17, 2),
       ELT(1 + (g % 4), 'USD','VND','EUR','JPY'),
       CONCAT(g, ' Le Loi, District 1, Ho Chi Minh City'),
       IF(g % 3 = 0, NULL, CONCAT('Note #', g)),
       IF(g % 4 = 0, NULL, NOW() - INTERVAL g HOUR)
FROM seq;

INSERT INTO types_demo VALUES
 (1, 7, 9007199254740993, 1.5, 3.141592653589793, 1234.5678, 1, '2026-10-13', '2026-10-13 08:30:00.125',
  '{"a": 1, "b": [true, null]}', X'DEADBEEF', X'00FF10', 'It''s a "quote" \\ backslash'),
 (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

CREATE VIEW order_summary AS
SELECT u.email, COUNT(o.id) AS order_count, SUM(o.total) AS total_spent
FROM users u LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.email;

CREATE TABLE no_pk_log (message text, logged_at timestamp DEFAULT CURRENT_TIMESTAMP);
INSERT INTO no_pk_log (message) VALUES ('first'), ('second');
