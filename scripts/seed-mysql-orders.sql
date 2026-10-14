-- Sample shop database "orders" for trying Foxlume Query against MySQL.
SET NAMES utf8mb4;
DROP DATABASE IF EXISTS orders;
CREATE DATABASE orders CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE orders;
SET SESSION cte_max_recursion_depth = 5000;

CREATE TABLE customers (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL,
    email VARCHAR(190) NOT NULL UNIQUE,
    phone VARCHAR(20),
    city VARCHAR(60) NOT NULL,
    tier ENUM('regular', 'silver', 'gold', 'vip') NOT NULL DEFAULT 'regular',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY customers_city_idx (city)
) ENGINE=InnoDB COMMENT='Shop customers';

CREATE TABLE products (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    sku VARCHAR(20) NOT NULL UNIQUE,
    name VARCHAR(160) NOT NULL,
    category VARCHAR(60) NOT NULL,
    price DECIMAL(10, 2) NOT NULL COMMENT 'USD',
    stock INT NOT NULL DEFAULT 0,
    is_active TINYINT(1) NOT NULL DEFAULT 1,
    KEY products_category_idx (category)
) ENGINE=InnoDB;

CREATE TABLE orders (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    order_no VARCHAR(20) NOT NULL UNIQUE,
    customer_id INT UNSIGNED NOT NULL,
    status ENUM('pending', 'paid', 'shipped', 'delivered', 'cancelled') NOT NULL DEFAULT 'pending',
    shipping_city VARCHAR(60) NOT NULL,
    note TEXT,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY orders_status_idx (status),
    KEY orders_created_idx (created_at),
    CONSTRAINT orders_customer_fk FOREIGN KEY (customer_id) REFERENCES customers (id) ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE order_items (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    order_id INT UNSIGNED NOT NULL,
    product_id INT UNSIGNED NOT NULL,
    quantity SMALLINT UNSIGNED NOT NULL,
    unit_price DECIMAL(10, 2) NOT NULL,
    line_total DECIMAL(12, 2) GENERATED ALWAYS AS (quantity * unit_price) STORED,
    CONSTRAINT items_order_fk FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE,
    CONSTRAINT items_product_fk FOREIGN KEY (product_id) REFERENCES products (id)
) ENGINE=InnoDB;

CREATE TABLE payments (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    order_id INT UNSIGNED NOT NULL,
    method ENUM('cash', 'card', 'paypal', 'apple_pay', 'bank_transfer') NOT NULL,
    amount DECIMAL(12, 2) NOT NULL,
    paid_at DATETIME NOT NULL,
    reference VARCHAR(40),
    CONSTRAINT payments_order_fk FOREIGN KEY (order_id) REFERENCES orders (id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- 60 customers spread over a few cities.
INSERT INTO customers (full_name, email, phone, city, tier, created_at)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 60)
SELECT
    CONCAT(ELT(1 + n % 12, 'Olivia', 'Liam', 'Emma', 'Noah', 'Ava', 'Lucas', 'Mia', 'Ethan', 'Sofia', 'Mateo', 'Chloé', 'Jonas'), ' ',
           ELT(1 + n % 10, 'Smith', 'García', 'Müller', 'Rossi', 'Dubois', 'Kowalski', 'Andersen', 'Tanaka', 'Silva', 'O''Brien')),
    CONCAT('customer', n, '@example.com'),
    CONCAT('+1 555 ', LPAD(n * 7919 % 10000000, 7, '0')),
    ELT(1 + n % 6, 'New York', 'London', 'Berlin', 'Tokyo', 'Sydney', 'Toronto'),
    ELT(1 + n % 9, 'regular', 'regular', 'regular', 'regular', 'silver', 'silver', 'gold', 'gold', 'vip'),
    TIMESTAMP('2025-01-01') + INTERVAL n * 5 DAY
FROM seq;

INSERT INTO products (sku, name, category, price, stock, is_active) VALUES
('CF-001', 'Iced latte', 'Drinks', 4.50, 500, 1),
('CF-002', 'Espresso', 'Drinks', 2.75, 500, 1),
('CF-003', 'Flat white', 'Drinks', 4.25, 400, 1),
('TE-001', 'Peach iced tea', 'Drinks', 3.95, 300, 1),
('TE-002', 'Bubble milk tea', 'Drinks', 5.25, 350, 1),
('BK-001', 'Grilled sandwich', 'Food', 6.50, 200, 1),
('BK-002', 'Egg and cheese bagel', 'Food', 5.75, 200, 1),
('BK-003', 'Pork bun', 'Food', 3.80, 150, 1),
('NO-001', 'Beef noodle soup', 'Food', 12.90, 120, 1),
('NO-002', 'Spicy ramen', 'Food', 11.50, 120, 1),
('NO-003', 'Pad thai', 'Food', 10.95, 100, 1),
('RC-001', 'Chicken rice bowl', 'Food', 9.80, 150, 1),
('SN-001', 'Fruit cup', 'Desserts', 3.50, 80, 1),
('SN-002', 'Greek yogurt', 'Desserts', 3.25, 90, 1),
('SN-003', 'Crème caramel', 'Desserts', 2.95, 100, 1),
('MR-001', 'Foxlume Query travel mug', 'Merchandise', 18.00, 40, 1),
('MR-002', 'Foxlume Query T-shirt', 'Merchandise', 22.00, 25, 1),
('MR-003', 'Canvas tote bag', 'Merchandise', 12.00, 60, 1),
('CF-004', 'Orange cold brew', 'Drinks', 5.50, 0, 0),
('TE-003', 'Lychee tea (discontinued)', 'Drinks', 4.00, 0, 0);

-- 600 orders over the past year.
INSERT INTO orders (order_no, customer_id, status, shipping_city, note, created_at)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 600)
SELECT
    CONCAT('ORD', LPAD(n, 6, '0')),
    1 + (n * 37) % 60,
    ELT(1 + (n * 13) % 10, 'delivered', 'delivered', 'delivered', 'shipped', 'shipped', 'paid', 'paid', 'pending', 'cancelled', 'delivered'),
    ELT(1 + (n * 7) % 6, 'New York', 'London', 'Berlin', 'Tokyo', 'Sydney', 'Toronto'),
    CASE WHEN n % 11 = 0 THEN 'Deliver during business hours' WHEN n % 17 = 0 THEN 'Call before delivery' WHEN n % 29 = 0 THEN 'Less ice, less sugar' ELSE NULL END,
    TIMESTAMP('2025-10-01 08:00:00') + INTERVAL (n * 14) HOUR + INTERVAL (n * 7) % 60 MINUTE
FROM seq;

-- 1 to 4 items per order.
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
WITH RECURSIVE line(k) AS (SELECT 1 UNION ALL SELECT k + 1 FROM line WHERE k < 4)
SELECT o.id, p.id, 1 + (o.id + line.k) % 3, p.price
FROM orders o
JOIN line ON line.k <= 1 + o.id % 4
JOIN products p ON p.id = 1 + (o.id * 3 + line.k * 5) % 18;

-- Payments for every order that is not pending or cancelled.
INSERT INTO payments (order_id, method, amount, paid_at, reference)
SELECT o.id,
       ELT(1 + o.id % 5, 'cash', 'card', 'paypal', 'apple_pay', 'bank_transfer'),
       (SELECT SUM(line_total) FROM order_items i WHERE i.order_id = o.id),
       o.created_at + INTERVAL 30 MINUTE,
       IF(o.id % 5 = 0, NULL, CONCAT('TX', LPAD(o.id * 97, 8, '0')))
FROM orders o
WHERE o.status NOT IN ('pending', 'cancelled');

CREATE VIEW order_totals AS
SELECT o.id, o.order_no, c.full_name AS customer, o.status, o.shipping_city,
       COUNT(i.id) AS item_count, SUM(i.line_total) AS total, o.created_at
FROM orders o
JOIN customers c ON c.id = o.customer_id
LEFT JOIN order_items i ON i.order_id = o.id
GROUP BY o.id, o.order_no, c.full_name, o.status, o.shipping_city, o.created_at;

CREATE VIEW revenue_by_month AS
SELECT DATE_FORMAT(o.created_at, '%Y-%m') AS month, COUNT(DISTINCT o.id) AS orders, SUM(p.amount) AS revenue
FROM orders o JOIN payments p ON p.order_id = o.id
GROUP BY DATE_FORMAT(o.created_at, '%Y-%m');
