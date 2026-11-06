# 练习 5：Terraform 进阶 —— remote state + modules + workspaces

> 练习 4 的三个痛点在这里根治：state 本地易丢（GCS backend + 版本化）、代码不可复用（module）、多环境挤一个 state（workspaces）。
> 路线见 `ROADMAP.md` 第四节。

## 前置（已完成）

- state 桶 `gs://lukechengtest-tfstate`（US 多区域 + 版本化 + 7 天软删除）已建好。

## 第一轮：remote state + module 跑通

```bash
cd 05-terraform-advanced

# 1. init 会读取 backend 块，连接 GCS（ADC 沿用练习 4 的授权）
terraform init

# 2. 建 dev 环境并部署
terraform workspace new dev
terraform workspace select dev
terraform apply        # 建 dev-practice-web

# 3. 切到 prod 再来一套
terraform workspace new prod
terraform workspace select prod
terraform apply        # 建 prod-practice-web
```

**观察点**：
- `terraform workspace list` 看 dev/prod/default 三条；
- `gcloud storage ls gs://lukechengtest-tfstate/labs/terraform-advanced/` —— 每个 workspace 一个 state 文件，互不干扰；
- VM 名自动带环境前缀（dev-practice-web / prod-practice-web），同一份代码两个环境不撞名。

**成本提醒**：两台 e2-micro 同时挂，免费额度只覆盖一台，另一台约 $0.008/小时。练完当天拆掉一个。

## 第二轮：体会 state lock

开两个终端，A 终端跑 `terraform apply`（停在确认提示别输 yes），B 终端也跑 `terraform apply`——看 B 报什么。

## 破坏-修复

1. **双终端抢锁**：如上，观察 `Error acquiring the state lock` 和锁文件 `default.tflock`；A 终端 Ctrl+C 释放后 B 恢复。这解决的是「两人同时改生产」的经典事故。
2. **注释 backend 块** → `terraform init`（会重新配置为本地 state）→ `plan` 看「全要新建」的恐怖场面（云上明明有机器）→ **千万别 apply** → 恢复 backend 块 → `terraform init` → `plan` 回到 `No changes`。体会：backend 配置决定 Terraform「在哪本账本上记账」，换账本 = 失忆。
3. **state 版本化验证**：`gcloud storage ls --versions gs://lukechengtest-tfstate/labs/terraform-advanced/` 看每次 apply 留下的 state 历史版本。

## 收尾

```bash
terraform workspace select dev   && terraform destroy
terraform workspace select prod  && terraform destroy
# 两个 workspace 都清了，state 文件保留（下一练习还能用），桶不删
```

## 实战记录（2026-11-06，全流程已跑完）

1. **remote state + module + workspaces 跑通**：dev/prod 各 apply 成功，GCS 上落 `default.tfstate / dev.tfstate / prod.tfstate` 三个账本。账本文件不进 plan——backend 只管记账，不算资源。
2. **破坏 1：抢锁**：A 终端 apply 占锁，B 终端报 412 `conditionNotMet` + Lock Info。乐观锁教学完成。
3. **破坏 2：换账本（失忆实验）**：
   - 注释 backend → `init -reconfigure` → `plan` 显示 **`2 to add`**——云上机器活得好好的，空账本六亲不认；
   - 恢复 backend → `init -reconfigure` → `plan` 回到 **`No changes`**。
   - 结论：**state 才是 Terraform 的记忆，代码本身不记资源是否存在。**

### 踩坑实录（下次直接绕开）

- **Terraform 1.13 后端变更必须显式选路**：`init` 单独跑报 `Backend configuration changed`，必须加 `-reconfigure`（不搬旧账本，重新对准）或 `-migrate-state`（把账本搬过去）。换账本实验一律用 `-reconfigure`。
- **「取消后端」的死循环 bug**：注释 backend 后 `init -reconfigure` 显示成功，但 `.terraform/terraform.tfstate` 缓存里仍记着 GCS 后端，导致 plan / workspace select 永远报 `Backend initialization required` 互相踢皮球。**解法：`rm .terraform/terraform.tfstate` 再 `init -reconfigure`**（该文件只是缓存，删除无风险）。
- **412 锁报错 ≠ 锁还活着**：`force-unlock` 报 `storage: object doesn't exist` 说明锁已被进程退出时放掉，直接继续干活即可。
- **workspace select 在后端变更中会死循环**：它自己也要过 backend 校验，后端缓存没清干净时就转不起来——先修缓存再操作 workspace。
- **GCS API 走代理**：本机默认代理对 `oauth2.googleapis.com` 报 Bad Gateway，四个代理环境变量（HTTP_PROXY/HTTPS_PROXY/http_proxy/https_proxy）全部指向 squid `127.0.0.1:3128` 后正常。

### 收官

dev 2 destroyed + prod 2 destroyed，计费归零。GCS 桶和三个空 state 保留，练习 6 继续用。
