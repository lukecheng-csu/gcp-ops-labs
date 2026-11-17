#!/usr/bin/env bash
# 用法：URL=https://lab09-api-xxxxx-uc.a.run.app bash scripts/smoke.sh
# 6 个断言全过才算部署成功（含统一错误结构验证）
set -euo pipefail
cd "$(dirname "$0")/.."

: "${URL:?用法: URL=https://<你的Cloud Run域名> bash scripts/smoke.sh}"
# 去掉所有结尾斜杠（用户粘 url 经常带 / 或 //）
while [[ "${URL}" == */ ]]; do URL="${URL%/}"; done

pass=0
fail=0

check_get() {  # 名称 期望码 body关键字 路径
  local name="$1" code="$2" want="$3" path="$4"
  local body real
  body=$(curl -sS -m 15 "${URL}${path}" 2>/dev/null || printf '%s' '{"error":{"message":"request failed"}}')
  real=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' "${URL}${path}" 2>/dev/null || printf '000')
  if [[ "${real}" == "${code}" ]] && printf '%s' "${body}" | grep -q -- "${want}"; then
    printf '  PASS  %s -> %s\n' "${name}" "${code}"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s (expected %s containing [%s], got HTTP %s body: %s)\n' \
      "${name}" "${code}" "${want}" "${real}" "$(printf '%s' "${body}" | head -c 120)"
    fail=$((fail + 1))
  fi
}

printf '== smoke test: %s ==\n' "${URL}"
check_get healthz          200 '"status":"ok"' /healthz
check_get root-info        200 '"service"'     /
check_get task-list        200 '"tasks"'       /api/tasks
check_get 404-shape        404 '"error"'       /api/tasks/999
check_get validation-400   400 '"error"'       '/api/slow?seconds=abc'

# POST 校验：空 title 应返回 400 + 统一结构
post_body=$(curl -sS -m 15 -X POST -H 'Content-Type: application/json' \
  -d '{"title":""}' "${URL}/api/tasks" 2>/dev/null || printf '')
post_code=$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -X POST \
  -H 'Content-Type: application/json' -d '{"title":""}' "${URL}/api/tasks")
if [[ "${post_code}" == '400' ]] && printf '%s' "${post_body}" | grep -q -- '"error"'; then
  printf '  PASS  POST-empty-title -> 400 shape\n'
  pass=$((pass + 1))
else
  printf '  FAIL  POST-empty-title (expected 400 + error, got %s body: %s)\n' \
    "${post_code}" "$(printf '%s' "${post_body}" | head -c 120)"
  fail=$((fail + 1))
fi

printf '== result: %s passed, %s failed ==\n' "${pass}" "${fail}"
[[ "${fail}" == '0' ]] || exit 1
