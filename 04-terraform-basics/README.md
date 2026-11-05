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

---

## 实战记录（2026-11-04，全部跑通）

### 第一轮：跑通

`plan` 精确 2 to add（1 VM + 1 firewall）→ `apply` 31s 完成。`instance_ip = 35.226.75.108`。
GCP 自动给 TF 管的资源打 `goog-terraform-provisioned = "true"` 标签——控制台里一眼分清「代码管的」和「手搓的」。

### 第二轮：in-place vs replace

- 改 `machine_type`（e2-micro→e2-small→回）：`~ update in-place`，耗时 1m29s = 停机→改→重启。
- **撞坑**：第一次直接报错拒绝——GCE provider 改机型必须停机，要求显式写 `allow_stopping_for_update = true`。绝不悄悄停你的机器，危险动作要签字。
- **意外发现**：in-place 期间 IP 从 35.226.75.108 变成 34.136.158.158——临时公网 IP 在停机时被回收，重启后重新分配。生产环境必须用静态 IP（`google_compute_address`）。plan 在 refresh 阶段就抓到了这个 IP 变化。
- `terraform plan -var zone=us-central1-b`（只 plan 不 apply）：换 zone = `-/+` replace，新机器新 IP 旧的销毁——有些属性压根不能原地改。

### 破坏 1：drift 检测

控制台手动删 firewall → `plan` 显示 `+ create`（「state 里我记着它，现实没了 → 我来补建」）→ `apply` 复活。
**反向 drift 是盲区**：现实中手加的资源（如手搓的 allow-ssh-2222），plan 只字不提——Terraform 只核对 state 里登记过的资源。「我以为 Terraform 全管着」是真实事故经典来源。

### 破坏 2：state 失忆 + 双救援

- 删 `terraform.tfstate` → `plan` 显示「2 to add, 0 to destroy」（失忆：它不知道云上有东西可销毁）。
- **apply 大概率不会双倍建**：资源名全局唯一，API 回 `alreadyExists`——但这是运气不是安全网，名字可重复的资源会悄悄建出第二份。
- 救援 A（备份回滚）：恢复 state → `No changes`。
- 救援 B（import）：`terraform import google_compute_instance.web <self_link>` 逐个接回 → plan 出两个**元数据级小 diff**：
  - `+ allow_stopping_for_update = true`——纯配置侧开关，服务端不存，import 读不到；
  - `+ terraform_labels = goog-terraform-provisioned`——服务端只存 effective_labels，「Terraform 认领清单」要 apply 一次收归名下。
  - 两条 in-place 元数据修改，apply 后 `No changes` 闭环。
- **白捡教训**：对已有主的地址重复 import 报 `Resource already managed by Terraform`——state 记所有权，要重接先 `terraform state rm`。
- **git 雷**：手工备份起名 `terraform.tfstatebak` 漏过 `*.tfstate` / `*.tfstate.*` 规则（中间没点），state 差点进公开仓库。gitignore 改 `*tfstate*` 收口。

### 破坏 3：apply 中途失败（自愈路径）

- firewall ports 加 `99999`：**plan 绿灯**（对 Terraform 只是字符串），apply 中途 API 400（`Port range must be between 0 and 65535`）——plan 抓结构性错误，**业务规则校验在 API 那边，plan 不是 truth**。
- 改回合法值直接 `No changes`：API 拒绝是原子性的，服务端零变更、state 未动，代码=state=现实自动对齐。**更新类失败不留残局，自愈**。
- taint 没用上：它的战场是「创建成功但后续步骤失败」（如 provisioner 半路挂，自动盖 tainted 章强制重建）或资源被外部搞坏 state 对不齐时手动盖章。

### 附加演示：taint（盖「下次必须重建」的章）

- `terraform taint google_compute_instance.web` → plan 显示 `is tainted, so must be replaced`、`-/+ destroy and then create replacement`、`1 to add, 1 to destroy`，instance_ip 变 `(known after apply)`（新机器新 IP）。
- **taint 只改 state 不碰云**——盖章后不 apply，云上机器毫发无损；`terraform untaint` 揭章即复原。
- 使用场景：机器内部被改乱/疑似污染/修不干净 → 不治了重造（「牲口不是宠物」）；或创建成功但后续步骤失败时 Terraform 自动盖章强制重建。
- 新版等价写法：`terraform apply -replace="google_compute_instance.web"` 一步到位。
- 与剧本 3 的区分：API 拒绝变更（服务端零变更）→ 自愈无需 taint；state 里的东西不可信（造坏/污染）→ 才需要 taint。

---

## 手搓（练习 1）vs IaC（练习 4）心得

| 维度 | 练习 1 手搓 | 练习 4 IaC |
|------|-----------|-----------|
| 建一套环境 | 控制台点几十分钟，步骤散在脑子里 | `terraform apply`，31 秒，步骤全在 main.tf 里 |
| 重建一套 | 凭记忆再来一遍，漏一步就翻车 | 换个目录再 apply 一遍，零遗漏 |
| 改配置 | 找到入口改，改了什么没人记得 | git diff 就是变更记录，plan 就是预告片 |
| 环境坏了 | 靠记忆+猜 | plan 一眼看出「现实和代码差在哪」 |
| 交接/审计 | 口口相传 | 代码即文档，state 即台账 |
| 隐性成本 | 手滑改错没法回滚 | destroy/apply 可重来，state 可恢复 |

最核心的一条：**手搓时代「环境是什么样」只存在于服务员的脑子里和 GCP 控制台里；IaC 时代它是一份可以 diff、可以 review、可以回滚的代码。** 练习 1 手搓半小时，练习 4 apply 31 秒——效率差距只是表象，真正的差距是「环境从不可描述变成了可描述」。

IaC 也有代价：state 是新的命根子（丢了就失忆）、新工具链心智负担（plan/apply/import/state）、以及新盲区（反向 drift 看不见）。这些坑练习 4 里全踩了一遍——比在文档里读十遍印象深刻。

## 命名冲突说明

练习 1 手搓的 `practice-web` 还在跑。本目录默认新建 **`practice-web-tf`**（不碰旧机），
练完 `terraform destroy` 只销毁 TF 管理的这台。旧机的接管（`terraform import`）留在破坏环节练。

## 免费红线

- e2-micro 仅 us-west1 / us-central1 / us-east1 免费；
- 盘 20GB pd-standard（免费额度 30GB 内）；
- 练完 `terraform destroy`，state 和 lock 文件别提交进 git（本目录 .gitignore 已挡）。
