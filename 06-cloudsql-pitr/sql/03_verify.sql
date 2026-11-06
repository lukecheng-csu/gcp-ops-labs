-- 练习 6 · 验证：连【恢复实例 lab06-pg-restored】的 lab06 库执行
-- psql 用户：先 \connect lab06；Studio 用户：先把数据库切到 lab06。

SELECT current_database() AS db, now() AT TIME ZONE 'UTC' AS checked_at;
SELECT count(*) AS restored_rows FROM orders;   -- 应等于事故前的行数
SELECT * FROM orders ORDER BY id;

-- 期望：T1 之前的 5 条种子数据都在；T1 之后新增的业务数据不在（那就是 RPO 丢掉的部分）。
