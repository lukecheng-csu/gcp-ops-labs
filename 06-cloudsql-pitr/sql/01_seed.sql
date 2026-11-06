-- 练习 6 · 种子数据
-- psql 用户：整段直接贴。
-- Cloud SQL Studio 用户：先单独执行第 1 行 CREATE DATABASE，在 Studio 里把数据库切到 lab06，
--                       再从 CREATE TABLE 开始贴（Studio 不认 \connect 这类 psql 元命令）。

CREATE DATABASE lab06;

\connect lab06

CREATE TABLE orders (
  id          serial PRIMARY KEY,
  item        text NOT NULL,
  amount      numeric(10,2) NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO orders (item, amount) VALUES
  ('tea-001',  28.00),
  ('tea-002',  45.50),
  ('herb-001', 12.00),
  ('herb-002', 33.00),
  ('herb-003', 19.90);

SELECT count(*) AS seed_rows FROM orders;   -- 预期 5
SELECT now() AT TIME ZONE 'UTC' AS seed_finished_at;
