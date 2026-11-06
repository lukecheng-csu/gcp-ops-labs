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
