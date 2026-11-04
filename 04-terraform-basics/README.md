# 练习 4：Terraform 基础 —— 一键重建练习 1 的 VM

> 目标：`terraform apply` 重建练习 1 的加固 VM（e2-micro + firewall），`destroy` 干净销毁。
> 详细路线见仓库根目录 `ROADMAP.md` 第三节。

## 第一轮：跑通

```bash
cd 04-terraform-basics

# 1. Terraform 需要 GCP 凭证（gcloud login 不自动给 Terraform 用，要单独授权一次）
gcloud auth application-default login

# 2. 初始化（下载 google provider）
terraform init

# 3. 先看计划，不动任何资源 —— 核对每一行是不是你想要的
terraform plan

# 4. 确认无误再真正创建
terraform apply
```

## 第二轮：小改动看行为

改 `variables.tf`（或用 `-var` 覆盖）里的 `machine_type`，再 `plan`：
- 观察输出里是 **in-place update**（`~` 前缀，原地改）还是 **replace**（`-/+`，销毁重建）。
- 大多数 VM 属性改动都是 replace —— 这就是 IaC 的「声明式」含义。

## 破坏-修复（骨架，自己敲）

1. 去控制台手动删掉 firewall 规则 → `terraform plan` 看 **drift 检测**（它会告诉你少了什么、要补回来）。
2. 备份后删 `terraform.tfstate` → `plan` 看到「全要重建」→ `terraform import` 一个个把资源接回 state。
3. 把某个属性改成非法值让 `apply` 中途失败 → 观察部分应用，`terraform taint` / plan 里的 replace 提示修复。

## 命名冲突说明

练习 1 手搓的 `practice-web` 还在跑。本目录默认新建 **`practice-web-tf`**（不碰旧机），
练完 `terraform destroy` 只销毁 TF 管理的这台。旧机的接管（`terraform import`）留在破坏环节练。

## 免费红线

- e2-micro 仅 us-west1 / us-central1 / us-east1 免费；
- 盘 20GB pd-standard（免费额度 30GB 内）；
- 练完 `terraform destroy`，state 和 lock 文件别提交进 git（本目录 .gitignore 已挡）。
