# 混合云主机指标采集（非 GCE → Cloud Monitoring）

> **状态：2026-11-09 21:00 已清场，当前未部署。** 上一轮为验证方案跑通过一次，随后把云上资源、
> 专用服务账号、生产机上的 Ops Agent / 凭证 / 采集脚本 / 定时器全部拆除，等你手敲一遍。
> 下面「从零安装」是**可以照敲的完整步骤**（主 runbook 里对应 B1~B4，见 [`../README.md`](../README.md) 扩展章）；
> 想再回到干净起点，用主 runbook 的「完整归零」。
> **跑之前先确认 `hybrid-ops-agent` 服务账号已被删掉** —— 别跳过第 0 步直接装 Agent，会 401。

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

## 从零安装（B1~B4，顺序别跳）

### 0. GCP 侧：建最小权限服务账号 + 发 key（Mac）

```bash
export PROJECT=lukechengtest
SA="hybrid-ops-agent@$PROJECT.iam.gserviceaccount.com"
gcloud iam service-accounts create hybrid-ops-agent \
  --display-name="Hybrid Ops Agent (jump-us)" --project=$PROJECT
for R in roles/monitoring.metricWriter roles/logging.logWriter; do
  gcloud projects add-iam-policy-binding $PROJECT \
    --member="serviceAccount:$SA" --role="$R" --quiet
done
KEY=/tmp/hybrid-ops-agent-key.json
umask 077
gcloud iam service-accounts keys create "$KEY" --iam-account="$SA" --project=$PROJECT
scp "$KEY" jump-us:/root/.hybrid-key.tmp.json
rm -f "$KEY"                       # 本地临时副本立刻删，仓库里不许出现 key
```

> 只给「写指标 + 写日志」两个角色。上一轮清场把这个 SA 删了，所以**每次重敲都要重新建、重新发 key**。

### 1. 生产机：凭证落位 + 注入 systemd（root）

```bash
ssh jump-us 'set -e
mkdir -p /etc/google/auth; chmod 0700 /etc/google/auth
mv /root/.hybrid-key.tmp.json /etc/google/auth/application_default_credentials.json
chown root:root /etc/google/auth/application_default_credentials.json
chmod 0400 /etc/google/auth/application_default_credentials.json
if ! grep -q GOOGLE_APPLICATION_CREDENTIALS /etc/systemd/system.conf; then
  printf "%s\n" "DefaultEnvironment=\"GOOGLE_APPLICATION_CREDENTIALS=/etc/google/auth/application_default_credentials.json\"" >> /etc/systemd/system.conf
fi
systemctl daemon-reload
ls -l /etc/google/auth/application_default_credentials.json'
```

### 2. 生产机：装 Ops Agent（只留日志）

```bash
ssh jump-us 'cd /root && curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh \
  && bash add-google-cloud-ops-agent-repo.sh --also-install'
```

> 此刻内置指标会刷 `failed to export metrics`，**是预期现象**，第 4 步关掉即可；日志侧已经通了。

### 3. 放采集文件 + 隔离的 Python 环境

```bash
# 从 Mac（目录 07-monitoring-alerting）
ssh jump-us 'mkdir -p /opt/hybrid-metrics'
scp collect.py hybrid-metrics.service hybrid-metrics.timer \
    ops-agent-config.yaml README.md jump-us:/opt/hybrid-metrics/

ssh jump-us 'set -e
cd /opt/hybrid-metrics
cp hybrid-metrics.service hybrid-metrics.timer /etc/systemd/system/
chmod 0644 collect.py
python3 -m venv /opt/hybrid-metrics/venv
/opt/hybrid-metrics/venv/bin/pip install -q --disable-pip-version-check \
  psutil google-auth requests -i https://mirrors.tencent.com/pypi/simple/'
```

> **`requests` 不能省**：google-auth 的 Request transport 依赖它，缺了 import 直接失败（上一轮踩过）。

### 4. 关内置指标 + 起定时器

```bash
ssh jump-us 'set -e
cp /opt/hybrid-metrics/ops-agent-config.yaml /etc/google-cloud-ops-agent/config.yaml
systemctl daemon-reload
systemctl restart google-cloud-ops-agent
systemctl enable --now hybrid-metrics.timer
systemctl start hybrid-metrics.service
sleep 2
journalctl -u hybrid-metrics.service -n 5 --no-pager | tail -5
systemctl list-timers hybrid-metrics.timer --no-pager | head -3'
```

> ✅ 首次成功会打印 `wrote 5 series`。手动跑紧挨 timer 时报 `points ... too frequent`
> 是正常的撞点，脚本已做幂等跳过（打 WARN、返回 0），不是故障。

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

## 卸载 / 完整归零

**云上那一半别漏**（拨测 / dashboard / 两条告警 / `prod-email` / 专用服务账号），完整可照敲脚本见
[主 runbook「完整归零」](../README.md)。下面是生产机这一半：

```bash
ssh jump-us 'set -e
systemctl disable --now hybrid-metrics.timer 2>/dev/null || true
systemctl stop google-cloud-ops-agent 2>/dev/null || true
systemctl disable google-cloud-ops-agent 2>/dev/null || true
dnf remove -y google-cloud-ops-agent >/dev/null 2>&1 || true
rm -f /etc/systemd/system/hybrid-metrics.service /etc/systemd/system/hybrid-metrics.timer
rm -rf /opt/hybrid-metrics /etc/google-cloud-ops-agent /etc/google/auth
rm -f /etc/yum.repos.d/google-cloud-ops-agent.repo /root/add-google-cloud-ops-agent-repo.sh
sed -i "/^DefaultEnvironment=.*GOOGLE_APPLICATION_CREDENTIALS/d" /etc/systemd/system.conf
systemctl daemon-reload
systemctl reset-failed hybrid-metrics.service 2>/dev/null || true'

# GCP 侧的服务账号（删了才会回到真正的干净起点）
gcloud iam service-accounts delete hybrid-ops-agent@lukechengtest.iam.gserviceaccount.com \
  --project=lukechengtest --quiet
```

> 复核：`rpm -qa | grep google-cloud-ops` 无、`systemctl list-units --all | grep -iE 'hybrid|ops-agent'` 无、
> `docker ps` 三个容器仍在、`curl /healthz` 仍返回 `{"status":"ok"}`。
> 自定义指标的**定义**不用删（API 不支持手删），没有数据写入就不计费，下次重敲继续写同名指标。

> 这台轻量服务器 **2026-11-21 到期**。迁移到新机器时：换 `HYBRID_NODE_ID` / `HYBRID_NAMESPACE`
> 两个环境变量即可（`HYBRID_LOCATION` 保持 `global`），指标定义和 dashboard filter 跟着改 `node_id`。
> 别忘了在 GCP 侧给新机器重新发一份服务账号 key（旧 key 建议同时删除）。
