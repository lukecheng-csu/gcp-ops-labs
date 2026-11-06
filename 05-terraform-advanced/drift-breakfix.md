# 练习 5 · 破坏 3：drift 检测 —— 控制台手改后 Terraform 知道吗？

> 追踪器对应项：「prod workspace 手改资源 → plan 看 drift」。
> 2026-11-06 实测完成，两种漂移（属性级 / 资源级）都跑到了。

## 一句话结论

**drift = 云上真实状态与 Terraform 账本记录的偏差。** 普通 `plan` 以**代码**为基线，发现漂移就提议"抹回代码的样子"；`plan -refresh-only` 以**账本**为基线，只体检、提议"把现实记进账本"。同一现实，两次输出箭头方向相反——因为比较基线不同。

---

## 做法（在 prod workspace 上）

```bash
terraform workspace select prod
terraform apply     # 先把 prod 的 VM + firewall 建出来

# 模拟"有人背着 Terraform 动了控制台"：手加一条 metadata
gcloud compute instances add-metadata prod-practice-web \
  --metadata=drift_test=1 --zone=us-central1-a
```

---

## 观察 1：属性级漂移 —— 普通 plan 提议"抹掉"

`terraform plan` 输出（节选）：

```
  # module.web.google_compute_instance.web will be updated in-place
  ~ resource "google_compute_instance" "web" {
      ~ metadata = {
          - "drift_test" = "1" -> null
            # (1 unchanged element hidden)
        }
        # (23 unchanged attributes hidden)
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

箭头是 **`-`**：代码里没有 `drift_test`，Terraform 的立场是**代码权威**——下一步把它从云上删掉。

确认执行路径：`terraform apply` 后 `gcloud compute instances describe` 里 `drift_test` 已消失。
**这就是 drift 的第一后果：谁手改谁被下一次 apply 无声抹掉。**

## 观察 2：只读体检 —— refresh-only 提议"记账"

`terraform plan -refresh-only` 输出（节选）：

```
Note: Objects have changed outside of Terraform

Terraform detected the following changes made outside of Terraform since
the last "terraform apply" which may have affected this plan:

  # module.web.google_compute_instance.web has changed
  ~ resource "google_compute_instance" "web" {
      ~ metadata = {
          + "drift_test" = "1"
            # (1 unchanged element hidden)
        }
      ~ metadata_fingerprint = "hbHVmySv1NY=" -> "GSjc_w97EAI="
        # (22 unchanged attributes hidden)
    }

This is a refresh-only plan, so Terraform will not take any actions to
undo these. If you were expecting these changes then you can apply this
plan to record the updated values in the Terraform state without
changing any remote objects.
```

箭头变成了 **`+`**：同一现实，这次的意思是"**云上比账本多了这条，我提议把它记进账本**"——不碰云上任何东西。

### 灵魂：为什么两次箭头相反？

| 命令 | 比较基线 | 箭头含义 |
|------|----------|----------|
| `plan` | 现实(refresh 后) vs **代码** | `-` = 我要把云上这条删掉（以代码为准） |
| `plan -refresh-only` | 现实 vs **账本** | `+` = 云上比账本多了这条，我要记录（只动账本） |

普通 plan 回答"我接下来要对云做什么"；refresh-only 回答"现实和我的记忆差在哪"。分不清这两个，就会对同一份现实看到两套相反的结论而懵掉。

## 观察 3：手改手回 —— 不用 apply 就自愈

```bash
gcloud compute instances remove-metadata prod-practice-web \
  --keys=drift_test --zone=us-central1-a
terraform plan
```

输出直接是 `No changes. Your infrastructure matches the configuration.`

原因：现代 Terraform（0.15+）plan 的 refresh 阶段发现现实已和账本一致，直接对齐——**人工回滚合法，两条收尾路径都通**：
① `apply` 让 Terraform 权威地抹掉手改（代码说了算）；
② 人手把改动撤回，plan 自然回到 No changes（应急时不必跑 Terraform）。

## 观察 4：资源级漂移 —— 整个资源被删

在控制台（Network Security → VPC firewall rules）删掉 `prod-practice-web-allow-http`，再 plan：

```
  # module.web.google_compute_firewall.web will be created
  + resource "google_compute_firewall" "web" { ... }

Plan: 1 to add, 0 to change, 0 to destroy.
```

账本里有、云上没了 → Terraform 判定"缺失"，`apply` 23 秒重建该规则。
**这个行为两面性要记住**：误删规则时它是救命（下次 apply 自动补回）；不想要的东西被重建时它是惊魂。资源级漂移不能靠 refresh-only"记账"消化——缺失的资源只能按代码重建。

## 彩蛋：`goog-terraform-provisioned` 标签

`gcloud compute instances describe` 输出里有一行：

```
labels:
  goog-terraform-provisioned: 'true'
```

Terraform 的 GCP provider **自动**给它创建的资源戳这个标签。于是可以一键盘点"哪些资源归 IaC 管"：

```bash
gcloud compute instances list --filter="labels.goog-terraform-provisioned=true"
```

做"接管客户现有环境"类单子时，第一步就是用这条命令画出哪些资产已入账、哪些是游离的。

## 收尾

`terraform destroy`：2 destroyed（firewall + VM）。云端只剩练习 1 手搓的 `practice-web` + `allow-http` / `allow-ssh-2222` 规则——Terraform 全程没碰过它们，反向印证：**账本之外的资源，plan 不认识、destroy 也不会动**（这正是"接管存量环境必须 import"的原因）。

## 踩坑小记

- `gcloud compute instances add-metadata` 偶发报 `No change requested`（刚 remove 过仍如此）——gcloud 本地比较逻辑抽风，**以 `describe` / `plan` 为准**。
- `gcloud compute instances list NAME` 位置参数已弃用，用 `--filter="name=..."`。
- `metadata_fingerprint` 变化说明 metadata 被外部修改过，是 GCP 自己的乐观并发版本号，可用作"有没有人动过"的快速信号。

## 一句话带走

- drift 分类：**属性漂移**（plan 抹回代码 / refresh-only 记进账本）vs **资源漂移**（缺失=重建 / 多余=destroy 不会动）。
- `plan` 以代码为基线，`plan -refresh-only` 以账本为基线——箭头相反不是矛盾，是基线不同。
- 治理规范：所有变更走 Terraform，控制台救火后必须回写代码，否则下次 apply 无声抹掉。
