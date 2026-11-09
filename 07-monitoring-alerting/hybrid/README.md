# 混合云主机指标采集（非 GCE → Cloud Monitoring）

> **状态：2026-11-09 已在 `jump-us` 实装并跑通。** 5 个指标每 60 秒写入 GCP，
> `generic_node` / `node_id=jump-us`；云上拨测、dashboard、两条告警策略均已创建。
> 下面的「安装」章节是复现与迁移用的记录，不需要再跑一遍。

## 为什么需要它

`jump-us`（腾讯云轻量）不是 Compute Engine 实例。官方 Ops Agent 虽然能用服务账号私钥在
非 GCP 机器上跑，但它的内置指标 `agent.googleapis.com/*` **绑定 `gce_instance` 资源**；
Agent 检测不到 GCE metadata 时会退化成 `generic_node`，Cloud Monitoring 直接以
`unknown metric type` 拒收。

2026-11-09 实测：Agent 2.73.0 装上、凭证有效（认证通过，不是 401），
但 200 个点里 195 个被拒，CPU / 内存 / 磁盘 **0 条入库**；
**日志侧成功**——syslog 正常进 Cloud Logging（`resource.type=generic_node`）。

于是分工：

| 数据 | 谁负责 | 落到哪 |
| --- | --- | --- |
| syslog / 系统日志 | Ops Agent（Fluent Bit，默认 logging pipeline） | Cloud Logging |
| CPU / 内存 / 磁盘 / 负载 / n8n 容器数 | 本脚本，每 60 秒 | Cloud Monitoring `custom.googleapis.com/host/*` on `generic_node` |
| 站点可用性 | 外部 uptime check（`prod-n8n-health`） | Cloud Monitoring |

`generic_node` 的四个标签把这台机器在混合云视图里钉死：
`project_id=lukechengtest` / `location=global` / `namespace=tencentcloud-na-ashburn` / `node_id=jump-us`。

> **坑**：`location` 只接受 Google Cloud 的区域名或 `global`。填腾讯云的 `na-ashburn`
> 会被 API 以 `Unrecognized region or location` 拒收（第一次实测踩到）。
> 云厂商和区域信息放在 `namespace` 里，dashboard / 告警按 `node_id=jump-us` 过滤即可。

## 文件

| 文件 | 装到生产机 |
| --- | --- |
| `collect.py` | `/opt/hybrid-metrics/collect.py` |
| `hybrid-metrics.service` | `/etc/systemd/system/hybrid-metrics.service` |
| `hybrid-metrics.timer` | `/etc/systemd/system/hybrid-metrics.timer` |
| `ops-agent-config.yaml` | `/etc/google-cloud-ops-agent/config.yaml`（关内置指标） |

**仓库里不含任何密钥。** 凭证由 GCP 侧生成后单独放到
`/etc/google/auth/application_default_credentials.json`（`0400 root:root`）。

## 安装（在生产机上，root）

```bash
# 1. 放文件
mkdir -p /opt/hybrid-metrics
# 从 Mac：scp collect.py hybrid-metrics.service hybrid-metrics.timer root@jump-us:/opt/hybrid-metrics/
cd /opt/hybrid-metrics
cp hybrid-metrics.service /etc/systemd/system/
cp hybrid-metrics.timer /etc/systemd/system/
chmod 0644 collect.py

# 2. 隔离的 Python 环境（只装两个包，不污染系统 Python）
python3 -m venv /opt/hybrid-metrics/venv
/opt/hybrid-metrics/venv/bin/pip install -q psutil google-auth requests \
  -i https://mirrors.tencent.com/pypi/simple/
# requests 不能省：google-auth 的 Request transport 依赖它，缺了 import 直接失败

# 3. 关掉 Ops Agent 内置指标（否则每分钟刷屏），日志保留
cp /opt/hybrid-metrics/ops-agent-config.yaml /etc/google-cloud-ops-agent/config.yaml
systemctl restart google-cloud-ops-agent

# 4. 起定时器
systemctl daemon-reload
systemctl enable --now hybrid-metrics.timer
systemctl start hybrid-metrics.service
```

## 验证

```bash
# 本机：看服务有没有报错
systemctl status hybrid-metrics.service --no-pager
journalctl -u hybrid-metrics.service -n 20 --no-pager
systemctl list-timers hybrid-metrics.timer --no-pager

# GCP 侧：查最近 10 分钟的时间序列（Mac 上跑）
TOKEN=$(gcloud auth print-access-token)
START=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ); END=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sS -G -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'filter=metric.type="custom.googleapis.com/host/disk_used_percent"' \
  --data-urlencode "interval.startTime=$START" --data-urlencode "interval.endTime=$END" \
  "https://monitoring.googleapis.com/v3/projects/lukechengtest/timeSeries" \
  | python3 -c "import json,sys;d=json.load(sys.stdin);print(d['timeSeries'][0]['resource'] if d.get('timeSeries') else d)"
```

期望看到 `resource.type = generic_node`、`node_id = jump-us`，且有点数据。

## 五个指标

| 指标 | 含义 | 典型告警 |
| --- | --- | --- |
| `custom.googleapis.com/host/cpu_utilization` | CPU 使用率 % | > 90% 持续 5 分钟 |
| `custom.googleapis.com/host/memory_utilization` | 内存使用率 % | > 90% 持续 5 分钟 |
| `custom.googleapis.com/host/disk_used_percent` | 根盘使用率 % | **> 85% 持续 5 分钟** |
| `custom.googleapis.com/host/load1` | 1 分钟负载 | > CPU 核数 × 2 |
| `custom.googleapis.com/host/n8n_containers_up` | 运行中的 `n8n-*` 容器数 | **< 3 持续 2 分钟**（`-1` 表示 docker 查询失败） |

## 排错

| 现象 | 查什么 |
| --- | --- |
| 服务报 401/403 | 凭证文件权限、SA 是否有 `roles/monitoring.metricWriter`、key 是否被删 |
| 报 `unknown metric type` | 指标前缀必须是 `custom.googleapis.com/`；不要改回 `agent.googleapis.com/` |
| 报 `points ... too frequent` | 手动跑紧挨 timer 时会触发；脚本已对这种 400 打 `WARN` 并返回 0（幂等跳过），不是故障。采样间隔别低于 60s |
| 时间序列里没有点 | `systemctl list-timers` 看 timer 是否 active；`journalctl -u hybrid-metrics.service` 看退出码 |
| `n8n_containers_up = -1` | 服务以 root 跑吗、`docker` 在不在 PATH、docker daemon 是否活着 |
| Ops Agent 又开始刷 export 错误 | `config.yaml` 的 `default_pipeline.receivers` 被覆盖了，重新 scp 该文件并重启 |

## 卸载 / 迁移

```bash
systemctl disable --now hybrid-metrics.timer
rm -f /etc/systemd/system/hybrid-metrics.{service,timer}
rm -rf /opt/hybrid-metrics
# 凭证：确认没有别的服务在用再删
rm -f /etc/google/auth/application_default_credentials.json
# systemd 全局 DefaultEnvironment 那行也要手工去掉，然后 daemon-reload
```

> 这台轻量服务器 **2026-11-21 到期**。迁移到新机器时：换 `HYBRID_NODE_ID` / `HYBRID_NAMESPACE`
> 两个环境变量即可（`HYBRID_LOCATION` 保持 `global`），指标定义和 dashboard filter 跟着改 `node_id`。
> 别忘了在 GCP 侧给新机器重新发一份服务账号 key（旧 key 建议同时删除）。
