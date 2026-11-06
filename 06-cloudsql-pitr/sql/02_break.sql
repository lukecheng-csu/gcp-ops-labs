-- 练习 6 · 破坏：模拟生产误删
-- 执行前先记 T_break（UTC）：
-- python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00","Z"))'
-- 确认当前连的是【主实例 lab06-pg】的 lab06 库，别连错到恢复实例。

DROP TABLE orders;

SELECT count(*) FROM orders;   -- 预期报错：relation "orders" does not exist
