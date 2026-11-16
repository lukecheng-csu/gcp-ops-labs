#!/usr/bin/env bash
# 用法：URL=https://lab09-api-xxxxx-uc.a.run.app bash scripts/smoke.sh
# 6 个断言全过才算部署成功（含统一错误结构验证）
set -euo pipefail
cd "$(dirname "$0")/.."

: "${URL:?用法: URL=https://<你的Cloud Run域名> bash scripts/smoke.sh}"
URL="${URL%/}"   # 去掉结尾斜杠

pass=0; fail=0

check_get() {  # 名称 期望码 body关键字 路径
  local name="$1" code="$2" want="$3" path="$4"
  local body real
  body=$(curl -sS -m 15 "$URL$path" 2>/dev/null || echo '{"error":{"message":"请求失败"}}')
  real=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "$URL$path" 2>/dev/null || echo 000)
  if [ "$real" = "$code" ] && echo "$body" | grep -q "$want"; then
    echo "  PASS  $name -> $code"
    pass=$((pass+1))
  else
    echo "  FAIL  $name (期望 $code 含「$want」，实际 $code: $(echo "$body" | head -c 100))"
    echo "        期望 $code, 实际 HTTP $real"
    fail=$((fail+1))
  fi
}

echo "== smoke test: $URL =="
check_get "healthz"       200 '"status":"ok"' /healthz
check_get "根信息"        200 '"service"'     /
check_get "任务列表"      200 '"tasks"'       /api/tasks
check_get "404统一结构"   404 '"error"'       /api/tasks/999
check_get "校验错误"      400 '"error"'       "/api/slow?seconds=abc"  # 非法参数→400统一结构

# POST 校验：空 title 应返回 400 + 统一结构
post_body=$(curl -sS -m 15 -X POST -H 'Content-Type: application/json' \
  -d '{"title":""}' "$URL/api/tasks" 2>/dev/null || echo '')
post_code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d '{"title":""}' "$URL/api/tasks")
if [ "$post_code" = "400" ] && echo "$post_body" | grep -q '"error"'; then
  echo "  PASS  POST空title -> 400 统一结构"
  pass=$((pass+1))
else
  echo "  FAIL  POST空title (期望 400 含 error, 实际 $post_code: $(echo "$post_body" | head -c 100))"
  fail=$((fail+1))
fi

echo "== 结果: $pass 通过, $fail 失败 =="
[ "$fail" = "0" ] || exit 1
