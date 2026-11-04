# 路线图：练习 4–13（对齐 v2 阶梯 + Upwork 技能映射）

> 本文件是 gcp-ops-labs 的官方练习路线图。练习 0–3 已完成（见上表），练习 4 起按此走。
> 铁律（沿用 v2 阶梯三条总原则）：每练习两段式「先跑通 → 再破坏-修复」，破坏环节不许跳；免费红线内折腾；练完立刻拆资源。

## 一、总路线（练习 4–13，对齐 v2 阶梯原文）

| 练习 | 主题 | GCP 服务 | 难度 | 交付物 |
|------|------|----------|------|--------|
| 4 | Terraform 基础 | Terraform (provider=google) | ★★★ | `apply` 一键重建练习 1 的 VM + firewall，`destroy` 干净销毁 |
| 5 | Terraform 进阶 | GCS backend + modules + workspaces | ★★★☆ | state 存 GCS（带锁）、dev/prod 两环境同一 module |
| 6 | 托管数据库 + 容灾 | Cloud SQL (PostgreSQL) + PITR + HA | ★★★ | 实测 RPO/RTO 的一次 PITR 恢复 |
| 7 | 监控告警日志 | Cloud Monitoring + Logging + Uptime | ★★★ | 配好 dashboard + 告警，真触发一次收邮件 |
| 8 | 无服务器 API | Cloud Run | ★★★ | serverless API，统一错误结构 |
| 9 | CI/CD | GitHub Actions + Artifact Registry + Cloud Run | ★★★ | push main → 自动部署新 revision |
| 10 | IAM / 安全纵深 | IAM + SA + audit logs | ★★★ | 「只能读特定 bucket」的 SA，拒绝记录进 audit log |
| 11 | 跨区域 HA + LB | MIG + LB + health check，两 region | ★★★★ | 关一个 region 服务仍可用，记切换耗时 |
| 12 | GKE 容器编排 | GKE (zonal) | ★★★★ | 练习 8 的容器跑 GKE，改副本数验证扩缩 |
| 13 | VMware 迁移（模拟） | Compute Engine + Import Virtual Disk | ★★★★ | VMDK/OVA 导入 GCP 起 VM |

阶段划分（阶梯原文）：**阶段二 4–7**（实施核心，单价翻倍）→ **阶段三 8–13**（进阶高单价）。

## 二、Upwork 技能映射

把岗位拆解出的技能叠到阶梯上，标出 ROI 分层：

| 练习 | 对应 Upwork 岗/技能 | ROI | 提案/面试可引用的卖点 |
|------|--------------------|-----|----------------------|
| 4 | Terraform / IaC | **高** | 「IaC 是云实施分水岭」——手点 DevOps $32/hr vs IaC 架构师 $50+/hr |
| 5 | IaC / DevOps | **高** | remote state + modules + workspaces（$50+/h 分水岭） |
| 6 | 备份 / 容灾 | **高（老本行）** | 实测 RPO/RTO，直接回 Commvault/NBU 背景 |
| 7 | 监控 / 运维 | 中高 | 真触发过告警、会读日志定位 |
| 8 | API 集成 / 自动化 | 中 | 自己写代码的 serverless API，比纯 n8n 更底层 |
| 9 | DevOps / CI/CD | **高** | WIF 无密钥认证 + push 即部署 |
| 10 | 安全 / IAM | 中高 | 最小权限 + audit log 排「为什么 403」 |
| 11 | 高可用 / 容灾 | **高** | 关一个 region 服务仍可用，health check 配错是典型事故 |
| 12 | 容器 / K8s | 中高（差异化） | K8s vs Cloud Run 取舍 |
| 13 | VMware 迁移 | **高（当下行情）** | Broadcom 涨价后的迁移需求，VCP 老底子是硬通货 |

### 战略分层（按 ROI 分配时间，不改顺序）

- **主线（cloud infra / 架构 / 迁移，高 ROI）**：4 → 5 → 6 → 9 → 11 → 13。这是「cloud/solution architecture」岗（中位 $50/hr）和「VMware 迁移」岗的硬证据，直接对着 15 年售前/解决方案 + 私有云背景。
- **n8n / 自动化辅助线**：已有 n8n 作品集（n8n-inbox-agent-demo），练习 8 补一个「自己写代码的 API」即可，别再往 n8n 卷岗加码。
- **顺序不动**：阶梯的「建议顺序」已经对，只是**时间投入向高 ROI 练习倾斜**。

### 缺口（Upwork 有需求、阶梯没覆盖）

1. **CRM 集成（HubSpot / Clay / Salesforce）**——岗位里反复出现（招聘线索 Clay、CRM 自动化）。阶梯完全没覆盖。建议：若决定保留「n8n + CRM」这条线，就加一个 0.5 级小练习（HubSpot API 自动化 demo，可复用 n8n）；若战略以 cloud 架构为主，**跳过**，别分散。
2. **M365 / 招聘入职**——有需求，但属微软栈 + 权限风险（已判定「不碰」），不做。

## 三、练习 4 详细分步（Terraform 基础）

> 重要更正：练习 4 是**重建练习 1 的 VM + firewall 规则**，不是重建练习 3 的静态站（那是练习 5 之后的形态才可能涉及）。

### 目标与交付物

`terraform apply` 一键重建练习 1 那台加固过的 VM（e2-micro、us-central1）+ firewall 规则，`destroy` 干净销毁。

### 步骤骨架

1. 写 `main.tf`：provider（google，项目 `lukechengtest`）+ e2-micro VM + firewall 规则（放行 tcp:80,443，沿用练习 1 的 `http-server` 标签思路）。
2. `terraform init` → `plan` → `apply`。
3. 改一个变量（如 machine_type）再 `plan`，观察 **in-place update vs replace** 的区别。
4. 抽出 `variables.tf` + `outputs.tf` 做可复用。

### 关键坑

- **现有 VM 命名冲突**：练习 1 的 VM `practice-web` 还在跑，是手搓的。Terraform apply 同名会冲突。处理二选一：① 新 VM 用不同名（如 `practice-web-tf`），练完 destroy 掉旧的；② 用 `terraform import` 把旧 VM 接进 state（顺带学会「接管已有资源」）。
- **免费红线**：e2-micro 只在 us-west1 / us-central1 / us-east1 免费；20GB pd-standard 在 30GB 内。region/machine_type 别写错。
- **state 本地默认**：练习 4 先用本地 state 理解概念；练习 5 才上 GCS remote state。别在练习 4 就跳去配 backend。
- **环境前置**：跳板机需先装 terraform（`brew install terraform` 或官方二进制），gcloud 应用授权沿用现有凭证。

### 破坏-修复（WorkBuddy 给骨架+方向，不替做完）

1. 控制台手动改 Terraform 管的资源（如删掉 firewall 规则）→ `plan` 看 **drift 检测**。
2. 备份后删 `terraform.tfstate` → `plan` 看到「全要重建」→ 学 `terraform import` 救。
3. 改错属性让 apply 中途失败 → 观察部分应用状态，`taint` / `replace` 修。

## 四、练习 5–13 要点速览（每练习背 3 个词就够）

- **5 TF 进阶**：GCS backend + state lock；modules；workspaces（dev/prod）。破坏：两终端同时 apply 看 lock 报错、注释 backend 后看「全要重建」恐怖场面。
- **6 Cloud SQL**：自动备份 + PITR + HA。破坏：DROP TABLE 后 PITR 恢复、failover 实测。**不在免费额度，练完立刻删。**
- **7 监控**：Ops Agent + dashboard + uptime + alerting。破坏：`dd` 灌满磁盘触发告警、停 Ops Agent 看断档。
- **8 Cloud Run**：FastAPI/Express + Dockerfile + Artifact Registry + Cloud Run。破坏：环境变量改错 500、sleep 超时/OOM、收 IAM 权限 403。
- **9 CI/CD**：GitHub Actions + Workload Identity Federation（无密钥）+ Cloud Run 部署。破坏：收 SA 权限看挂在哪步、部署坏版本用 traffic 回滚。
- **10 IAM**：resource-level 最小权限 + Data Access audit log。破坏：给 SA 加 editor 看它多能干、停用 SA 看报错。
- **11 HA**：instance template → MIG（两 region）→ LB + health check。破坏：health check 路径指错看实例被错误摘除、停一个 region 记切换耗时。
- **12 GKE**：zonal 集群 + Deployment + Service + scale。破坏：镜像名错 ImagePullBackOff、limits 太小 OOMKilled、删 pod 看自愈。**节点计费，练完删 cluster。**
- **13 VMware**：本地 VMware 造 VM → 导出 VMDK/OVA → 传 GCS → Import virtual disk → 起 VM。破坏：导入损坏 VMDK、virtio vs IDE 驱动不匹配。**别碰 VMware Engine（极贵）。**

## 五、执行要求（WorkBuddy 协作约定）

1. 每个练习先「跑通」再「破坏-修复」，破坏环节让 lukecheng 自己敲、自己定位，WorkBuddy 只给命令骨架和排错方向。
2. 每步先 `plan` 看 diff 再 `apply`；免费红线内的资源名、region、machine_type 别写错。
3. 交付物按 v2 阶梯的作品集模板：GitHub 仓库（`gcp-ops-labs` 按编号分目录）+ **英文 README + Mermaid 架构图**，「What I broke and how I fixed it」一节写真实经历。
4. 练习 4 完成后，写一段「手搓（练习 1）vs IaC（练习 4）」差异心得，这是作品集最能体现成长的内容。
