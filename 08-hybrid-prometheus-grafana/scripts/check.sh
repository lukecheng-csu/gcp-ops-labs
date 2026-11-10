#!/usr/bin/env bash
# 在监控机 lab08-mon 上跑：cd ~/lab08 && bash scripts/check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

echo "=== 1. 容器 ==="
sudo docker compose ps --format 'table {{.Name}}  {{.Status}}'

echo
echo "=== 2. scrape targets ==="
curl -fsS http://127.0.0.1:9090/api/v1/targets > /tmp/lab08-targets.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/lab08-targets.json'))
ts = d['data']['activeTargets']
for t in sorted(ts, key=lambda x: (x['labels'].get('job',''), x['scrapeUrl'])):
    name = t['labels'].get('host') or t['labels'].get('check') or '-'
    print('%-4s %-18s %-18s %s' % (t['health'], t['labels'].get('job','-'), name, t['scrapeUrl']))
down = [t for t in ts if t['health'] != 'up']
print('total=%d  up=%d  down=%d' % (len(ts), len(ts)-len(down), len(down)))
for t in down:
    print('   DOWN reason:', t.get('lastError','(no detail)'))
PY

echo
echo "=== 3. 已加载告警规则 ==="
curl -fsS http://127.0.0.1:9090/api/v1/rules > /tmp/lab08-rules.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/lab08-rules.json'))
n = 0
for g in d['data']['groups']:
    for r in g['rules']:
        firing = sum(1 for a in r.get('alerts', []) if a['state'] == 'firing')
        print('%-22s health=%-6s firing=%d' % (r['name'], r['health'], firing))
        n += 1
print('rules =', n)
PY

echo
echo "=== 4. 当前告警 ==="
curl -fsS http://127.0.0.1:9090/api/v1/alerts > /tmp/lab08-alerts.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/lab08-alerts.json'))
al = d['data']['alerts']
for a in al:
    who = a['labels'].get('host') or a['labels'].get('app') or '-'
    print('%-22s %-10s %s' % (a['labels'].get('alertname','-'), a['state'], who))
print('firing =', sum(1 for a in al if a['state'] == 'firing'))
PY

echo
echo "提示: 有 DOWN 先查 S6 的腾讯云控制台白名单；FIRING 不为 0 说明破坏演练生效中。"
