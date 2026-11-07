#!/usr/bin/env python3
"""
练习 6 · 免 psql 的 SQL 执行器（给装不上 libpq 的机器用，比如 Intel Mac）

用法：
  export PGHOST=<实例公网IP>
  export PGUSER=postgres
  export PGPASSWORD=<你的密码>
  export PGDATABASE=postgres        # 默认库；脚本里的 \\connect 会切库

  ./pg.py -f sql/01_seed.sql        # 整段跑一个文件（支持 \\connect / -- 注释）
  ./pg.py -c "SELECT count(*) FROM orders"
  ./pg.py -f sql/03_verify.sql --db lab06

行为：
  - 自动提交（autocommit），CREATE DATABASE 不会被事务卡住
  - 逐条执行，单条报错不中断，最后汇总（方便看 DROP TABLE 之后那条"预期报错"）
  - 查询结果直接打成表格
"""
import argparse
import os
import re
import sys

try:
    import psycopg2
except ImportError:
    sys.exit("缺少 psycopg2：先跑 .venv-lab06/bin/pip install psycopg2-binary")


def conn_params(dbname=None):
    host = os.environ.get("PGHOST", "")
    if not host:
        sys.exit("请先 export PGHOST=<实例公网IP>（或 /cloudsql/<连接名>）")
    return dict(
        host=host,
        port=int(os.environ.get("PGPORT", "5432")),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", ""),
        dbname=dbname or os.environ.get("PGDATABASE", "postgres"),
        sslmode=os.environ.get("PGSSLMODE", "require"),
        connect_timeout=20,
    )


def split_sql(text):
    """按分号切语句，正确跳过注释、单/双引号、$tag$ 块。"""
    stmts, buf = [], []
    i, n = 0, len(text)
    quote = None
    dollar = None
    while i < n:
        ch = text[i]
        if dollar:
            if text.startswith(dollar, i):
                buf.append(dollar)
                i += len(dollar)
                dollar = None
                continue
            buf.append(ch)
            i += 1
            continue
        if quote:
            buf.append(ch)
            if quote == "'" and text.startswith("''", i):
                buf.append("'")
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        # psql 元命令（\connect 之类）：整行独立成一条，不带分号
        if ch == "\\" and not "".join(buf).strip():
            j = text.find("\n", i)
            j = n if j == -1 else j
            stmts.append(text[i:j].strip())
            buf = []
            i = j + 1
            continue
        if text.startswith("--", i):
            j = text.find("\n", i)
            i = n if j == -1 else j
            buf.append("\n")
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j == -1 else j + 2
            buf.append(" ")
            continue
        if ch in ("'", '"'):
            quote = ch
            buf.append(ch)
            i += 1
            continue
        if ch == "$":
            m = re.match(r"\$[A-Za-z_]*\$", text[i:])
            if m:
                dollar = m.group(0)
                buf.append(dollar)
                i += len(dollar)
                continue
        if ch == ";":
            stmts.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(ch)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        stmts.append(tail)
    return [s.strip() for s in stmts if s.strip()]


def print_result(cur, sql):
    if cur.description is None:
        print(f"  OK  ({cur.rowcount if cur.rowcount >= 0 else '?'} 行受影响)")
        return
    cols = [d[0] for d in cur.description]
    rows = cur.fetchall()
    width = [len(c) for c in cols]
    body = []
    for r in rows[:50]:
        line = [("" if v is None else str(v)) for v in r]
        body.append(line)
        width = [max(w, len(v)) for w, v in zip(width, line)]
    print("  " + " | ".join(c.ljust(w) for c, w in zip(cols, width)))
    print("  " + "-+-".join("-" * w for w in width))
    for line in body:
        print("  " + " | ".join(v.ljust(w) for v, w in zip(line, width)))
    if len(rows) > 50:
        print(f"  ... 共 {len(rows)} 行，只显示前 50")
    else:
        print(f"  ({len(rows)} 行)")


def main():
    ap = argparse.ArgumentParser(description="免 psql 的 Cloud SQL 执行器")
    ap.add_argument("-f", "--file", help="要执行的 .sql 文件")
    ap.add_argument("-c", "--command", help="要执行的单条 SQL")
    ap.add_argument("--db", help="初始连接的数据库（默认取 PGDATABASE 或 postgres）")
    args = ap.parse_args()

    if not args.file and not args.command:
        ap.error("要么用 -f <文件>，要么用 -c <SQL>")

    text = open(args.file, encoding="utf-8").read() if args.file else args.command
    statements = split_sql(text)
    if not statements:
        sys.exit("没有可执行的语句")

    params = conn_params(args.db)
    print(f"连接 {params['user']}@{params['host']}:{params['port']}/{params['dbname']} (sslmode={params['sslmode']})")
    conn = psycopg2.connect(**params)
    conn.autocommit = True
    cur = conn.cursor()

    errors = 0
    for idx, stmt in enumerate(statements, 1):
        # psql 元命令：\connect <db>
        m = re.match(r"^\\c(?:onnect)?\s+(\S+)", stmt)
        if stmt.startswith("\\"):
            if m:
                db = m.group(1)
                cur.close()
                conn.close()
                params["dbname"] = db
                conn = psycopg2.connect(**params)
                conn.autocommit = True
                cur = conn.cursor()
                print(f"[{idx}] \\connect {db}  -> 已切换")
            else:
                print(f"[{idx}] 跳过 psql 元命令：{stmt.splitlines()[0]}")
            continue

        head = " ".join(stmt.split())[:90]
        print(f"\n[{idx}] {head}{'...' if len(' '.join(stmt.split())) > 90 else ''}")
        try:
            cur.execute(stmt)
            print_result(cur, stmt)
        except Exception as exc:  # noqa: BLE001
            errors += 1
            print(f"  ERROR: {str(exc).strip()}")
            try:
                conn.rollback()
            except Exception:
                pass

    cur.close()
    conn.close()
    print(f"\n=== 执行完毕：{len(statements)} 条语句，{errors} 条报错 ===")
    if errors:
        print("（若报错来自 02_break.sql 里 DROP 之后的 count(*)，那是预期的「表已不存在」）")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
