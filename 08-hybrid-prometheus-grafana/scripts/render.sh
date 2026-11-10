#!/usr/bin/env bash
# 在监控机 lab08-mon 上跑：把模板里的 IP / 邮箱占位符换成真实值
# 用法：GCE_PRIVATE_IP=10.x.x.x TENCENT_PUBLIC_IP=43.165.125.114 bash scripts/render.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${GCE_PRIVATE_IP:?缺 GCE_PRIVATE_IP（practice-web 的内网 IP）}"
: "${TENCENT_PUBLIC_IP:?缺 TENCENT_PUBLIC_IP（jump-us 的公网 IP）}"
ALERT_EMAIL="${ALERT_EMAIL:-lab08@example.com}"
SMTP_PASSWORD="${SMTP_PASSWORD:-CHANGE_ME}"

python3 - "$GCE_PRIVATE_IP" "$TENCENT_PUBLIC_IP" "$ALERT_EMAIL" "$SMTP_PASSWORD" <<'PY'
import pathlib, sys
gce, tencent, email, smtp = sys.argv[1:5]
pairs = [
    ("prometheus/prometheus.yml.template", "prometheus/prometheus.yml"),
    ("alertmanager/alertmanager.yml.template", "alertmanager/alertmanager.yml"),
]
repl = {
    "__GCE_PRIVATE_IP__": gce,
    "__TENCENT_PUBLIC_IP__": tencent,
    "__ALERT_EMAIL__": email,
    "__SMTP_PASSWORD__": smtp,
}
for src, dst in pairs:
    text = pathlib.Path(src).read_text(encoding="utf-8")
    for key, val in repl.items():
        text = text.replace(key, val)
    pathlib.Path(dst).write_text(text, encoding="utf-8")
    print("wrote", dst)
left = [k for k in repl if any(k in pathlib.Path(d).read_text(encoding="utf-8") for _, d in pairs)]
print("unreplaced placeholders:", left or "none")
PY
