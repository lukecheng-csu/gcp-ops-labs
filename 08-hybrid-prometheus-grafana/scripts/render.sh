#!/usr/bin/env bash
# 在监控机 lab08-mon 上跑：把模板里的 IP / 邮箱占位符换成真实值
# 用法：GCE_PRIVATE_IP=10.x.x.x TENCENT_PUBLIC_IP=43.165.125.114 bash scripts/render.sh
# 可选：SKIP_N8N=1 临时摘掉两条 n8n /healthz 拨测目标（生产机故障时让练习照常开敲）
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GCE_PRIVATE_IP:?缺 GCE_PRIVATE_IP（practice-web 的内网 IP）}"
: "${TENCENT_PUBLIC_IP:?缺 TENCENT_PUBLIC_IP（jump-us 的公网 IP）}"
ALERT_EMAIL="${ALERT_EMAIL:-lab08@example.com}"
SMTP_PASSWORD="${SMTP_PASSWORD:-CHANGE_ME}"
# SMTP 服务器可切换：GCP 封出站 25 端口，163 的 587 又不支持 STARTTLS，
# 真发信用 QQ SMTP：SMTP_HOST='smtp.qq.com:587' SMTP_REQUIRE_TLS=true ALERT_FROM='xxx@qq.com'
SMTP_HOST="${SMTP_HOST:-smtp.163.com:25}"
SMTP_REQUIRE_TLS="${SMTP_REQUIRE_TLS:-false}"
ALERT_FROM="${ALERT_FROM:-$ALERT_EMAIL}"

python3 - "$GCE_PRIVATE_IP" "$TENCENT_PUBLIC_IP" "$ALERT_EMAIL" "$SMTP_PASSWORD" <<'PY'
import os, pathlib, re, sys
gce, tencent, email, smtp = sys.argv[1:5]
skip_n8n = os.environ.get("SKIP_N8N", "") == "1"
pairs = [
    ("prometheus/prometheus.yml.template", "prometheus/prometheus.yml"),
    ("alertmanager/alertmanager.yml.template", "alertmanager/alertmanager.yml"),
]
repl = {
    "__GCE_PRIVATE_IP__": gce,
    "__TENCENT_PUBLIC_IP__": tencent,
    "__ALERT_EMAIL__": email,
    "__SMTP_PASSWORD__": smtp,
    "__SMTP_HOST__": os.environ.get("SMTP_HOST", "smtp.163.com:25"),
    "__SMTP_REQUIRE_TLS__": os.environ.get("SMTP_REQUIRE_TLS", "false"),
    "__ALERT_FROM__": os.environ.get("ALERT_FROM", email),
}
for src, dst in pairs:
    text = pathlib.Path(src).read_text(encoding="utf-8")
    for key, val in repl.items():
        text = text.replace(key, val)
    if skip_n8n and src.endswith("prometheus.yml.template"):
        # 两个 n8n target 是完整的 4 行块，整块摘掉才能保持 static_configs 的 YAML 结构
        block = re.compile(
            r"      - targets: \['https://cloudworkflowdone\.com/healthz'\]\n"
            r"        labels:\n"
            r"          app: n8n\n"
            r"          check: [^\n]+\n"
        )
        text, n = block.subn("", text)
        if n != 2:
            raise SystemExit(
                "SKIP_N8N: 期望摘除 2 个 n8n 目标，实际 %d 个；模板结构可能变了，请核对" % n
            )
        print("SKIP_N8N=1: 已摘除 2 个 n8n 拨测目标（GCS 两条 + 两台主机不受影响）")
    pathlib.Path(dst).write_text(text, encoding="utf-8")
    print("wrote", dst)
left = [k for k in repl if any(k in pathlib.Path(d).read_text(encoding="utf-8") for _, d in pairs)]
print("unreplaced placeholders:", left or "none")
PY
