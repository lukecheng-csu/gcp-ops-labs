-- 练习 6 · 验证：连【恢复实例】的 lab06 库执行
-- psql 用户：先 \connect lab06；Studio 用户：先把数据库切到 lab06。
-- 第二轮「保守点 T1」和第三轮「审计定锚」共用这份脚本，期望值不同，按下表判读。

SELECT current_database() AS db, now() AT TIME ZONE 'UTC' AS checked_at;
SELECT count(*) AS restored_rows FROM orders;
SELECT * FROM orders ORDER BY id;

-- 判读表
--   8 行   = 恢复到 T1（第二轮）：5 条种子 + T1 前插的 3 条；
--           herb-005 / tea-005 不在，这两行就是实测丢掉的数据（RPO）。
--   10 行  = 恢复到 DROP 前一瞬（第三轮审计定锚）：连最后 2 条也回来了，零丢失。
--   报错 relation "orders" does not exist = 恢复点越过了 DROP，
--           DROP 本身也写 WAL，前滚会把它一起重放（第三轮恢复 B 的预期结果）。
--   少于 8 行 = 时间点记早了 / 恢复窗口没追上，往前挪一点再试。
--
-- 注意：恢复到 DROP 之后「不会」是 10 行，那时表已经不存在。
--       （旧版注释把「看到 10 行」误判成「恢复点在 DROP 之后」，2026-11-08 更正）
