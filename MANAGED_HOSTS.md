# 被管理机器台账

> 这个仓库里所有「能连上去、能监控」的机器都登记在这。新增机器先补这张表，再写练习材料。
> 最后核对：**2026-11-09 21:00（清场后）** —— 上一轮混合云纳管验证跑通后已全部拆除，
> 云上监控资源、专用服务账号、生产机上的 Agent/凭证/采集脚本/定时器都已归零，等待手敲一遍。
> 机器本身（三容器、Caddy、squid、Hysteria2）全程未动。

## 总览

| 别名 | 角色 | 云 / 区域 | 公网 IP | 连接方式 | 监控覆盖 | 到期 |
| --- | --- | --- | --- | --- | --- | --- |
| `jump-us` | **主力 n8n + GCP 操作跳板机**（生产） | 腾讯云轻量 / `na-ashburn` / `lhins-js6lgbt` | `43.165.125.114` | `ssh jump-us`（root） | **当前未接（清场）**；目标：日志 + 5 个系统指标 + 外部拨测全进 `lukechengtest`，手敲见 07 README 扩展章 B0~B6 | **2026-11-21 ⚠️** |
| `practice-web` | 练习靶机（练习 1/2/3/7 共用） | GCP Compute / `us-central1-a` / e2-micro | `35.194.5.128` | `ssh -i ~/.ssh/google_compute_engine lukecheng@35.194.5.128` | Ops Agent **未装**（练习 7 第 0.3 步装） | 长期（Always Free） |

---

## 1. `jump-us` · 主力 n8n（腾讯云轻量）

### 身份

| 项 | 值 |
| --- | --- |
| 云厂商 / 产品 | 腾讯云轻量应用服务器 |
| 区域 / 实例 ID | `na-ashburn` / `lhins-js6lgbt` |
| 公网 IP | `43.165.125.114` |
| 系统 | Rocky Linux 9.4 (Blue Onyx) |
| 域名 | `cloudworkflowdone.com`（Cloudflare 代理，边缘 IP `104.21.12.178` / `172.67.195.43`） |
| 根盘 | 40G，已用 12G（31%，2026-11-09 实测） |
| **到期** | **2026-11-21** —— 只剩 12 天，续费或迁移要先定，别把长期监控绑死在这台 |

### 连接

```bash
ssh jump-us          # ~/.ssh/config 已有别名，User root、密钥 ~/.ssh/id_ed25519
```

> **坑**：系统里**只有 root 账户**。`ssh 43.165.125.114` 不带用户名会用本机账号 `lukecheng`，
> 服务端直接回 `Invalid user`。必须写 `root@` 或走别名 `jump-us`。
> 密钥认证已实测可用（`~/.ssh/id_ed25519`），不需要密码。

### 跑着什么（2026-11-09 实测）

| 服务 | 状态 | 端口 |
| --- | --- | --- |
| `n8n-core` | Up 11 hours | `127.0.0.1:5678`（只对本机，由 Caddy 反代） |
| `n8n-postgres` | Up 11 hours (healthy) | 容器内网 |
| `n8n-caddy` | Up 11 hours | `0.0.0.0:80` / `0.0.0.0:443` |
| `squid` | 运行中 | **`127.0.0.1:3128`（只绑本机，公网不通）** |
| `hysteria` server | 运行中 | UDP `443` |
| `xray` | 运行中 | `8443` |
| `sshd` | 运行中 | `0.0.0.0:22` |

健康端点：`https://cloudworkflowdone.com/healthz` → `200` / `{"status":"ok"}`。
响应头 `cf-cache-status: DYNAMIC`，**Cloudflare 不缓存这个路径**，所以拨测能真实反映源站死活，不会「源站挂了还返缓存 200」。
绕过 CF 直连源站（`--resolve ...:43.165.125.114`）也返回 200，说明 Caddy 本身正常。

### 跳板机用途（和练习 6 的代理报错对上了）

squid 只监听 `127.0.0.1:3128`，Mac 上是通过 SSH 转发 / Hysteria2 隧道把它映射成本地 `127.0.0.1:3128` 再用。
练习 6 里 `gcloud` 报 `Unable to connect to proxy 127.0.0.1:3128 Connection refused`，**根因是这条转发没起来**，
不是 Clash 端口写错（后来改用 Clash Verge 的 `7897` 是另一条路）。以后再看到 3128 报错，先查 `jump-us` 上的 squid 和本地转发。

### 监控怎么接（混合云深度纳管 · 当前未部署，等待手敲）

**目标架构**：三条链路汇到同一个 GCP 项目 `lukechengtest`，跟 `practice-web` 在同一套监控里。

| 数据 | 采集方 | 落到哪 |
| --- | --- | --- |
| syslog / 系统日志 | Ops Agent 的 Fluent Bit（默认 logging pipeline） | Cloud Logging，`resource.type=generic_node` |
| CPU / 内存 / 根盘 / 负载 / n8n 容器数 | `hybrid-metrics` 每 60 秒（`systemd timer`） | `custom.googleapis.com/host/*` on `generic_node` |
| 站点可用性 | 外部 uptime check `prod-n8n-health` | `monitoring.googleapis.com/uptime_check/check_passed` |

**为什么内置指标不能用**（上一轮实测，不是猜）：Ops Agent 装好后凭证有效、日志正常，但它检测不到
GCE metadata（`resourcedetector.UnrecognizedPlatformResource`），把内置 `agent.googleapis.com/*` 指标挂到
`generic_node`，Cloud Monitoring 以 `unknown metric type` 拒收——200 个点里 195 个失败，
CPU/内存/磁盘 **0 条入库**。这些内置指标绑定 `gce_instance` 资源，是产品限制。

解法：按官方文档把内置 host metrics 关掉（`default_pipeline.receivers: []`，日志 pipeline 保留），
改由自建脚本把系统指标写成**自定义指标**——自定义指标允许挂 `generic_node`，语义也对。
`generic_node` 标签：`node_id=jump-us` / `namespace=tencentcloud-na-ashburn` / `location=global`
（`location` 只接受 GCP 区域或 `global`，填腾讯云的 `na-ashburn` 会被 `Unrecognized region or location` 拒收）。

**凭证模型（B1 会重建）**：专用服务账号 `hybrid-ops-agent@lukechengtest.iam.gserviceaccount.com`
（上一轮清场已删除），只授 `roles/monitoring.metricWriter` + `roles/logging.logWriter`；
key 放 `/etc/google/auth/application_default_credentials.json`（`0400 root:root`），
通过 `/etc/systemd/system.conf` 的 `DefaultEnvironment` 注入 Ops Agent 进程。**仓库不含任何密钥**。

**当前云上状态：全空**。手敲完成后应重建：`prod-n8n-health`（拨测）、`prod-n8n-overview`（dashboard）、
`prod-n8n-health-failed` + `prod-n8n-host-degraded`（告警）、`prod-email`（常驻邮件通道）。
完整步骤见 `07-monitoring-alerting/README.md` 扩展章 **B0~B6**，实现细节与排错见
`07-monitoring-alerting/hybrid/README.md`；想回到干净起点用主 runbook 的「完整归零」。

> 自定义指标按样本量计费：5 个序列 × 1 点/分钟 ≈ 21.6 万点/月，金额很小但**不是零**；
> 清场后无数据写入就不产生这部分费用。在 Metrics Management 页可看实际用量。

### 红线

- **生产机，不参与任何破坏演练**：不准 `dd` 灌盘、不准停容器、不准停 Ops Agent、不准改 Caddy/squid 配置。
  练习 7 的破坏只准在 `practice-web` 上做。
- 只做只读巡检（`docker ps`、`df -h`、`systemctl status`、`curl /healthz`）。
- 监控资源统一用 `prod-` 前缀，跟练习的 `lab07-` 前缀隔离；练习清理脚本只删 `lab07-`。

---

## 2. `practice-web` · GCP 练习靶机

| 项 | 值 |
| --- | --- |
| 项目 / 区域 | `lukechengtest` / `us-central1-a` |
| 规格 | e2-micro / Debian 12 / 20G 根盘（已用 40%）/ Always Free |
| 公网 IP | `35.194.5.128` |
| 服务账号 scopes | 含 `monitoring.write` + `logging.write`，装 Ops Agent 不用停机改 scopes |
| Ops Agent | 未安装（练习 7 第 0 步装） |
| 80 端口 | 练习 2 遗留的 Caddy，`/` 返 308、HTTPS 报 TLS 错，**不能当拨测目标** |
| 归属 | 练习 1 的资产，**不要删**；练习 3 的 GCS 桶 `lukecheng-static-site` 同理 |

`gcloud compute ssh` 在这台 Mac 上（走 Clash）会卡死，`--plain` 又会问 root 密码；
22 端口直连通，用 `~/.ssh/google_compute_engine` 密钥直连即可（练习 7 的 `SSH()` 封装）。

---

## 纳管原则

- **命名隔离**：练习临时资源 `lab07-*`，生产常驻资源 `prod-*`。清理脚本按前缀过滤，绝不误删。
- **破坏只打靶机**：所有「故意搞坏」的动作限定在 `practice-web`；生产机只观测、不扰动。
- **凭证不落盘、不入库**：台账只记别名和密钥**路径**，不记密钥内容、密码、Token。跨云主机的 GCP 凭证单独走最小权限服务账号，一台机器一把 key。
- **跨云分工**：非 GCE 主机不要指望云厂商 Agent 的内置指标（绑定自家资源类型）；日志可以用 Agent，系统指标改走自定义指标 + `generic_node`，外部拨测兜底可用性。
- **先只读探测再登记**：每台新机器接入时先跑一遍 `ssh` 只读巡检（OS / 容器 / 磁盘 / 监听端口 / 健康端点），把实测值写进表，别抄配置文档。
- **采集链路自己也要被监控**：主机指标断了之后阈值告警全都不会响，所以主机告警策略里专门设计了一条「采集断档 > 5 分钟」（配置在 `alert-host-production.json`，待手敲 B6 创建）。

## 巡检速查

```bash
# 生产机（只读）
ssh jump-us 'cat /etc/os-release | grep PRETTY_NAME; \
  docker ps --format "{{.Names}} {{.Status}}"; df -h / | tail -1; \
  curl -fsS http://127.0.0.1:5678/healthz; echo; \
  systemctl is-active google-cloud-ops-agent hybrid-metrics.timer; \
  journalctl -u hybrid-metrics.service -n 3 --no-pager | tail -3'
# ↑ 干净起点下这两项会报 inactive / not-found，属正常；跑完 B3/B4 才应是 active

# 练习靶机（只读）
ssh -i ~/.ssh/google_compute_engine -o StrictHostKeyChecking=no \
  lukecheng@35.194.5.128 'df -h / | tail -1; systemctl is-active google-cloud-ops-agent'

# 云上资源当前状态（干净起点下四条都应是空的）
gcloud monitoring dashboards list --format='table(displayName,name)'
gcloud monitoring policies list --format='table(displayName,enabled)'
gcloud monitoring uptime list-configs --format='table(displayName,name)'
gcloud iam service-accounts list --format='table(email,displayName)'
```
