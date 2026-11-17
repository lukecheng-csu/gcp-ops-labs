#!/usr/bin/env bash
# 用法: URL=https://lab10-api-xxxxx.a.run.app bash scripts/smoke.sh
# 6 个断言全过才算部署成功（含统一错误结构验证）
# 练习 10 里它同时是 CI 的门禁：这一步红了，流水线就算失败。
#
# 设计要点（踩过的坑，别改回去）：
#   1) 每条断言只发一次请求，body 和 http_code 从同一次响应里取
#      —— 发两次会被不稳定的本地代理拆散，出现「body 对但 code=000」
#   2) 提示信息全用 ASCII 标点，变量全加花括号
#      —— Mac 自带 bash 3.2 会把紧贴中文标点的 $var 解析崩
#   3) 失败重试：先直连（--noproxy），再原样重试
#      —— 本地 7897 之类代理对 *.run.app 常半通
#   4) curl 失败时 -w 已输出 000，不能再 printf 一个 000 兜底（会变成 000000）

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

: "${URL:?用法: URL=https://<你的Cloud Run域名> bash scripts/smoke.sh}"
# 去掉所有结尾斜杠（粘 url 经常带 / 或 //）
while [[ "${URL}" == */ ]]; do URL="${URL%/}"; done

TMPDIR_SMOKE="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_SMOKE}"' EXIT

pass=0
fail=0
last_err=""

# 发请求：$1=方法(GET/POST) $2=路径 $3=可选的 JSON body
# 结果放 R_CODE / R_BODY_FILE / R_ERR
# 注意：不要用数组拼 curl 参数。bash 3.2 在 set -u 下展开空数组
# 会报 "extra[@]: unbound variable"，必须写显式分支。
do_request() {
  local method="$1" path="$2" data="${3:-}"
  local body_file="${TMPDIR_SMOKE}/body.$$" err_file="${TMPDIR_SMOKE}/err.$$"

  R_CODE="000"; R_ERR=""
  # 第 1 次：按当前环境（可能走代理）；第 2 次：强制直连；第 3 次：再试一次
  local attempt direct
  for attempt in 1 2 3; do
    direct=0
    [[ "${attempt}" == "2" ]] && direct=1
    if [[ "${method}" == "POST" ]]; then
      if [[ "${direct}" == "1" ]]; then
        R_CODE=$(curl -sS -m 20 --noproxy '*' -o "${body_file}" -w '%{http_code}' \
          -X POST -H 'Content-Type: application/json' -d "${data}" "${URL}${path}" 2>"${err_file}")
      else
        R_CODE=$(curl -sS -m 20 -o "${body_file}" -w '%{http_code}' \
          -X POST -H 'Content-Type: application/json' -d "${data}" "${URL}${path}" 2>"${err_file}")
      fi
    else
      if [[ "${direct}" == "1" ]]; then
        R_CODE=$(curl -sS -m 20 --noproxy '*' -o "${body_file}" -w '%{http_code}' "${URL}${path}" 2>"${err_file}")
      else
        R_CODE=$(curl -sS -m 20 -o "${body_file}" -w '%{http_code}' "${URL}${path}" 2>"${err_file}")
      fi
    fi
    R_ERR=$(head -c 200 "${err_file}" 2>/dev/null)
    # curl 失败时 http_code 是 000；成功才是 2xx/4xx/5xx
    if [[ "${R_CODE}" != "000" && -n "${R_CODE}" ]]; then
      break
    fi
    sleep 1
  done
  R_BODY_FILE="${body_file}"
}

show_body() { head -c 120 "${R_BODY_FILE}" 2>/dev/null; }

check_get() {  # 名称 期望码 body关键字 路径
  local name="$1" want_code="$2" want="$3" path="$4"
  do_request GET "${path}"
  if [[ "${R_CODE}" == "${want_code}" ]] && grep -q -- "${want}" "${R_BODY_FILE}" 2>/dev/null; then
    printf '  PASS  %s -> %s\n' "${name}" "${R_CODE}"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s (want %s containing [%s], got HTTP %s)\n' \
      "${name}" "${want_code}" "${want}" "${R_CODE}"
    printf '        body: %s\n' "$(show_body)"
    [[ -n "${R_ERR}" ]] && printf '        curl: %s\n' "${R_ERR}"
    fail=$((fail + 1))
  fi
}

printf '== smoke test: %s ==\n' "${URL}"
check_get health          200 '"status":"ok"' /health
check_get root-info       200 '"service"'     /
check_get task-list       200 '"tasks"'       /api/tasks
check_get 404-shape       404 '"error"'       /api/tasks/999
check_get validation-400  400 '"error"'       '/api/slow?seconds=abc'

# 第 6 项：POST 空 title 应 400 + 统一结构
do_request POST /api/tasks '{"title":""}'
if [[ "${R_CODE}" == "400" ]] && grep -q -- '"error"' "${R_BODY_FILE}" 2>/dev/null; then
  printf '  PASS  POST-empty-title -> 400 shape\n'
  pass=$((pass + 1))
else
  printf '  FAIL  POST-empty-title (want 400 + error, got HTTP %s)\n' "${R_CODE}"
  printf '        body: %s\n' "$(show_body)"
  [[ -n "${R_ERR}" ]] && printf '        curl: %s\n' "${R_ERR}"
  fail=$((fail + 1))
fi

printf '== result: %s passed, %s failed ==\n' "${pass}" "${fail}"
[[ "${fail}" == "0" ]] || exit 1
