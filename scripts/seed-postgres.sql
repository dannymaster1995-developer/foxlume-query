DROP SCHEMA IF EXISTS shop CASCADE;
DROP TABLE IF EXISTS public.users, public.orders, public.types_demo CASCADE;
DROP VIEW IF EXISTS public.order_summary;

CREATE TABLE public.users (
    id serial PRIMARY KEY,
    email varchar(255) NOT NULL UNIQUE,
    full_name text,
    country char(2) DEFAULT 'VN',
    is_active boolean NOT NULL DEFAULT true,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE public.users IS 'Application users';

CREATE TABLE public.orders (
    id bigserial PRIMARY KEY,
    user_id integer NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'pending',
    total numeric(10,2) NOT NULL,
    currency char(3) NOT NULL DEFAULT 'USD',
    shipping_address text,
    notes text,
    paid_at timestamptz
);
CREATE INDEX orders_user_id_idx ON public.orders(user_id);
CREATE INDEX orders_status_idx ON public.orders(status);

CREATE TABLE public.types_demo (
    id integer PRIMARY KEY,
    small smallint,
    big bigint,
    real_value real,
    double_value double precision,
    money_value numeric(12,4),
    flag boolean,
    day date,
    moment timestamp,
    doc jsonb,
    tags text[],
    raw bytea,
    uid uuid,
    quote_text text
);

INSERT INTO public.users (email, full_name, country) VALUES
 ('zoe.muller@example.com', 'Zoë Müller', 'DE'),
 ('bjorn.larsen@example.com', 'Björn Larsen', 'NO'),
 ('alice@example.com', 'Alice Martin', 'US'),
 ('bob@example.com', 'Bob Smith', 'GB'),
 ('yuki@example.com', 'Yuki Tanaka', 'JP');

INSERT INTO public.orders (user_id, status, total, currency, shipping_address, notes, paid_at)
SELECT 1 + (g % 5),
       (ARRAY['pending','paid','shipped','delivered','cancelled'])[1 + (g % 5)],
       round((10 + g * 3.17)::numeric, 2),
       (ARRAY['USD','VND','EUR','JPY'])[1 + (g % 4)],
       g || ' Le Loi, District 1, Ho Chi Minh City',
       CASE WHEN g % 3 = 0 THEN NULL ELSE 'Note #' || g END,
       CASE WHEN g % 4 = 0 THEN NULL ELSE now() - (g || ' hours')::interval END
FROM generate_series(1, 250) AS g;

INSERT INTO public.types_demo VALUES
 (1, 7, 9007199254740993, 1.5, 3.141592653589793, 1234.5678, true, '2026-10-13', '2026-10-13 08:30:00',
  '{"a": 1, "b": [true, null]}', '{red,green}', '\xdeadbeef', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 'It''s a "quote" \ backslash'),
 (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

CREATE VIEW public.order_summary AS
SELECT u.email, count(o.id) AS order_count, sum(o.total) AS total_spent
FROM public.users u LEFT JOIN public.orders o ON o.user_id = u.id
GROUP BY u.email;

CREATE SCHEMA shop;
CREATE TABLE shop.products (
    sku text PRIMARY KEY,
    name text NOT NULL,
    price numeric(8,2) NOT NULL
);
INSERT INTO shop.products VALUES ('SKU-1', 'Iced latte', 2.50), ('SKU-2', 'Grilled sandwich', 1.75);

CREATE TABLE public.no_pk_log (message text, logged_at timestamptz DEFAULT now());
INSERT INTO public.no_pk_log (message) VALUES ('first'), ('second');
