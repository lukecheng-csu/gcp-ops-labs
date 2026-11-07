-- 练习 6 · 验证：连【恢复实例 lab06-pg-restored】的 lab06 库执行
-- psql 用户：先 \connect lab06；Studio 用户：先把数据库切到 lab06。

SELECT current_database() AS db, now() AT TIME ZONE 'UTC' AS checked_at;
SELECT count(*) AS restored_rows FROM orders;   -- 应为 8
SELECT * FROM orders ORDER BY id;

-- 期望：8 行（5 条种子 + T1 前插入的 3 条）。
-- T1 之后写入的 herb-005 / tea-005 那 2 条不在，这就是 RPO 实测丢掉的部分。
-- 若看到 10 行，说明恢复时间点选在了 DROP 之后；若少于 8 行，说明 T1 记早了。
