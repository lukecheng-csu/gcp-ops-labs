# 被管理机器台账

> 这个仓库里所有「能连上去、能监控」的机器都登记在这。新增机器先补这张表，再写练习材料。
> 最后核对：**2026-11-09**（只读探测，未改动任何机器）。

## 总览

| 别名 | 角色 | 云 / 区域 | 公网 IP | 连接方式 | 监控覆盖 | 到期 |
| --- | --- | --- | --- | --- | --- | --- |
| `jump-us` | **主力 n8n + GCP 操作跳板机**（生产） | 腾讯云轻量 / `na-ashburn` / `lhins-js6lgbt` | `43.165.125.114` | `ssh jump-us`（root） | 外部拨测 `/healthz`，**只读** | **2026-11-21 ⚠️** |
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

### 监控怎么接（零侵入）

**不装 Ops Agent。** 它不是 GCE 实例，没有 GCE 的服务账号自动鉴权；要装就得把 GCP 服务账号**私钥 JSON 放到这台腾讯云生产机**上
（官方 Bare Metal / 非 GCP 主机走 ADC + `GOOGLE_APPLICATION_CREDENTIALS` 的路子）。对一台 12 天后到期的生产主力机，这笔安全账不划算。

改用**外部拨测**：Google 全球节点直接拨 `https://cloudworkflowdone.com/healthz`，内容匹配 `ok`，失败发邮件。
机器上一个字节都不用改，配置全在 GCP 侧，随时可删。命令见 `07-monitoring-alerting/README.md`「扩展」章。

代价说清楚：这样只能知道**「活着 / 挂了」**，看不到 CPU、内存、磁盘。要那些指标就得走上面那条装 Agent 的路，另外评估。

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
- **凭证不落盘、不入库**：台账只记别名和密钥**路径**，不记密钥内容、密码、Token。
- **先只读探测再登记**：每台新机器接入时先跑一遍 `ssh` 只读巡检（OS / 容器 / 磁盘 / 监听端口 / 健康端点），把实测值写进表，别抄配置文档。

## 巡检速查

```bash
# 生产机（只读）
ssh jump-us 'cat /etc/os-release | grep PRETTY_NAME; \
  docker ps --format "{{.Names}} {{.Status}}"; df -h / | tail -1; \
  curl -fsS http://127.0.0.1:5678/healthz; echo'

# 练习靶机（只读）
ssh -i ~/.ssh/google_compute_engine -o StrictHostKeyChecking=no \
  lukecheng@35.194.5.128 'df -h / | tail -1; systemctl is-active google-cloud-ops-agent'

# 拨测配置当前状态（GCP 侧）
gcloud monitoring uptime list-configs --format='table(displayName,name)'   # 看完整目标加 --format=yaml
```
