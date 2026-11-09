# 被管理机器台账

> 这个仓库里所有「能连上去、能监控」的机器都登记在这。新增机器先补这张表，再写练习材料。
> 最后核对：**2026-11-09**（只读探测，未改动任何机器）。

## 总览

| 别名 | 角色 | 云 / 区域 | 公网 IP | 连接方式 | 监控覆盖 | 到期 |
| --- | --- | --- | --- | --- | --- | --- |
| `jump-us` | **主力 n8n + GCP 操作跳板机**（生产） | 腾讯云轻量 / `na-ashburn` / `lhins-js6lgbt` | `43.165.125.114` | `ssh jump-us`（root） | **混合云深度纳管**：日志 + 5 个系统指标 + 外部拨测，全进 `lukechengtest` | **2026-11-21 ⚠️** |
| `practice-web` | 练习靶机（练习 1/2/3/7 共用） | GCP Compute / `us-central1-a` / e2-micro | `35.194.5.128` | `ssh -i ~/.ssh/google_compute_engine lukecheng@35.194.5.128` | Ops Agent（练习 7 装） | 长期（Always Free） |

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

### 监控怎么接（混合云深度纳管，2026-11-09 已实装）

三条链路全部汇到同一个 GCP 项目 `lukechengtest`，跟 `practice-web` 在同一套监控里：

| 数据 | 采集方 | 落到哪 |
| --- | --- | --- |
| syslog / 系统日志 | Ops Agent 2.73.0 的 Fluent Bit（默认 logging pipeline） | Cloud Logging，`resource.type=generic_node` |
| CPU / 内存 / 根盘 / 负载 / n8n 容器数 | `hybrid-metrics` 每 60 秒（`systemd timer`） | `custom.googleapis.com/host/*` on `generic_node` |
| 站点可用性 | 外部 uptime check `prod-n8n-health` | `monitoring.googleapis.com/uptime_check/check_passed` |

**为什么内置指标不能用**（实测，不是猜）：Ops Agent 装好后凭证有效、日志正常，但它检测不到 GCE metadata
（`resourcedetector.UnrecognizedPlatformResource`），把内置 `agent.googleapis.com/*` 指标挂到 `generic_node`，
Cloud Monitoring 以 `unknown metric type` 拒收——200 个点里 195 个失败，CPU/内存/磁盘 **0 条入库**。
这些内置指标绑定 `gce_instance` 资源，这是产品限制。

解法：按官方文档把内置 host metrics 关掉（`default_pipeline.receivers: []`，日志 pipeline 保留），
改由自建脚本把系统指标写成**自定义指标**——自定义指标允许挂 `generic_node`，语义也对。
`generic_node` 标签：`node_id=jump-us` / `namespace=tencentcloud-na-ashburn` / `location=global`
（`location` 只接受 GCP 区域或 `global`，填腾讯云的 `na-ashburn` 会被 `Unrecognized region or location` 拒收）。

**凭证**：专用服务账号 `hybrid-ops-agent@lukechengtest.iam.gserviceaccount.com`，
只有 `roles/monitoring.metricWriter` + `roles/logging.logWriter` 两个角色；
key 在 `/etc/google/auth/application_default_credentials.json`（`0400 root:root`），
通过 `/etc/systemd/system.conf` 的 `DefaultEnvironment` 注入 Ops Agent 进程。
**仓库不含任何密钥**；迁移或到期时记得删 GCP 侧的那把 key。

**云上已创建**：`prod-n8n-health`（拨测）、`prod-n8n-overview`（dashboard）、
`prod-n8n-health-failed` + `prod-n8n-host-degraded`（告警策略）。
告警暂时**没绑邮件通道**，控制台能看事件；收件邮箱定了再接 `prod-email`。
实现与卸载步骤见 `07-monitoring-alerting/hybrid/README.md`，命令见 07 README「扩展」章。

> 自定义指标按样本量计费：5 个序列 × 1 点/分钟 ≈ 21.6 万点/月，金额很小但**不是零**。
> 在 Cloud Monitoring 的 Metrics Management 页可以看到实际用量。

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
- **采集链路自己也要被监控**：主机指标断了之后阈值告警全都不会响，所以 `prod-n8n-host-degraded` 里专门有一条「采集断档 > 5 分钟」。

## 巡检速查

```bash
# 生产机（只读）
ssh jump-us 'cat /etc/os-release | grep PRETTY_NAME; \
  docker ps --format "{{.Names}} {{.Status}}"; df -h / | tail -1; \
  curl -fsS http://127.0.0.1:5678/healthz; echo; \
  systemctl is-active google-cloud-ops-agent hybrid-metrics.timer; \
  journalctl -u hybrid-metrics.service -n 3 --no-pager | tail -3'

# 练习靶机（只读）
ssh -i ~/.ssh/google_compute_engine -o StrictHostKeyChecking=no \
  lukecheng@35.194.5.128 'df -h / | tail -1; systemctl is-active google-cloud-ops-agent'

# 拨测配置当前状态（GCP 侧）
gcloud monitoring uptime list-configs --format='table(displayName,name)'   # 看完整目标加 --format=yaml
```
