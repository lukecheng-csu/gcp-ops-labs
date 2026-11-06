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

# 2. 建 dev 环境并部署（重做时 workspace 已存在，new 会报 already exists，直接用 select）
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

1. **双终端抢锁**：如上，观察 `Error acquiring the state lock` 和锁文件 `<workspace>.tflock`（锁文件名跟随当前 workspace，不是写死的 default）；A 终端 Ctrl+C 释放后 B 恢复。这解决的是「两人同时改生产」的经典事故。
2. **换账本（失忆实验）**：把 `backend "gcs"` **显式改成 `backend "local" {}`** → `terraform init -reconfigure` → `plan` 看「全要新建」的恐怖场面（云上明明有机器）→ **千万别 apply** → 改回 gcs → `init -reconfigure` → `plan` 回到 `No changes`。体会：backend 配置决定 Terraform「在哪本账本上记账」，换账本 = 失忆。
   > 别用「直接注释掉 backend」的老写法：会踩 `.terraform/terraform.tfstate` 未 unset 的已知误导行为（见踩坑实录）。
   > 另外先清掉本地后端实验残留 `terraform.tfstate.d/`（本次已清理），否则本地 prod 账本里若有旧内容就不「失忆」了。
3. **state 版本化验证**：`gcloud storage ls --versions gs://lukechengtest-tfstate/labs/terraform-advanced/` 看每次 apply 留下的 state 历史版本。

## 收尾

```bash
terraform workspace select dev   && terraform destroy
terraform workspace select prod  && terraform destroy
# 两个 workspace 都清了，state 文件保留（下一练习还能用），桶不删
# 若两个终端并行拆，改用 TF_WORKSPACE=<env> terraform destroy，见下方「并行 destroy 的边界」
```

## 实战记录（2026-11-06，全流程已跑完）

1. **remote state + module + workspaces 跑通**：dev/prod 各 apply 成功，GCS 上落 `default.tfstate / dev.tfstate / prod.tfstate` 三个账本。账本文件不进 plan——backend 只管记账，不算资源；账本是在各环境 apply 尾部**上传 state** 时写回 GCS 的，`Releasing state lock` 只是删锁日志，跟写账本是两件事。
2. **破坏 1：抢锁**：A 终端 apply 占锁，B 终端报 412 `conditionNotMet` + Lock Info（本次是 `prod.tflock`）。乐观锁教学完成。
3. **破坏 2：换账本（失忆实验）**：
   - 换到本地空账本 → `init -reconfigure` → `plan` 显示 **`2 to add`**——云上机器活得好好的，空账本六亲不认（第一轮实操用的是「注释 backend」老写法，踩了缓存死循环；标准姿势见踩坑实录）；
   - 恢复 backend → `init -reconfigure` → `plan` 回到 **`No changes`**。
   - 结论：**state 才是 Terraform 的记忆，代码本身不记资源是否存在。**

### 踩坑实录（下次直接绕开）

- **backend 变更一贯要求显式选路**（不是 1.13 新行为，本机 1.13.4 实测一致）：`init` 检测到配置变化时报 `Backend configuration changed`；交互模式会询问，脚本/非交互必须显式给 `-reconfigure`（重新对准，不搬账本）或 `-migrate-state`（搬账本；注意方向：往远端搬会覆盖远端账本，往本地搬会把远端账本复制下来）。
- **「取消后端」的已知误导行为**：删掉 backend 块后 `init -reconfigure` 报成功，但 `.terraform/terraform.tfstate`（只存后端初始化指针的本地缓存文件，**不含任何资源账本**）里旧后端记录没有 unset，后续 plan / workspace 命令全部报 `Backend initialization required: Unsetting the previously set backend "gcs"`。这不是随机 bug，是社区大量记录的已知行为（S3 / Local 换后端同样），提示信息误导。
  - **规范解法（做失忆实验优先用 ①）**：① 别「删」backend 块，**显式改成 `backend "local" {}`** 再 `terraform init -reconfigure`，一次到位、无死循环；② `terraform init -migrate-state` 也能正确改写后端记录，但会询问是否把远端账本搬到本地——做失忆实验要答 **no**，否则账本复制下来就不失忆了。
  - 本项目实际用的 `rm .terraform/terraform.tfstate`（或 `rm -rf .terraform`）后重新 init，同样安全有效，与社区通行 workaround 一致，保留作兜底。
- **412 锁报错 ≠ 锁还活着**：`force-unlock` 报 `storage: object doesn't exist` 说明锁对象已不存在，直接继续即可——**前提是持锁进程优雅退出**（Ctrl+C 会触发释放锁）。若进程被 `kill -9` / 终端崩溃，锁对象会**残留**，那时才需要 `terraform force-unlock <LOCK_ID>`（ID 在 412 报错的 Lock Info 里），或直接删对象：
  ```bash
  gcloud storage rm gs://lukechengtest-tfstate/labs/terraform-advanced/<workspace>.tflock
  ```
  判断锁是否残留：`gcloud storage ls gs://lukechengtest-tfstate/labs/terraform-advanced/` 看不到 `<workspace>.tflock` 即已释放。短暂并发抢锁更推荐 `-lock-timeout=5m`，别一上来就 force-unlock。（该报错文本在并发竞争场景也会出现，terraform#30149。）
- **workspace select 在后端变更中会死循环**：它自己也要过 backend 校验，后端缓存没清干净时就转不起来——先修缓存再操作 workspace。
- **GCS API 走代理**：本机默认代理对 `oauth2.googleapis.com` 报 Bad Gateway，四个代理环境变量（HTTP_PROXY/HTTPS_PROXY/http_proxy/https_proxy）全部指向 squid `127.0.0.1:3128` 后正常。

### 并行 destroy 的边界

两个 workspace 并行拆是**能跑通的**（本次 dev/prod 两个终端同时 destroy，实测各 2 destroyed）：

- 锁按 state 对象隔离：`<prefix>/dev.tflock` 与 `<prefix>/prod.tflock` 是两把锁，互不阻塞；
- `.terraform/environment`（本地共享的「当前 workspace 指针」，实测内容为 `prod`）只在**命令启动时**读取，另一终端后来 `select` 不影响已启动进程。

但**这不是官方支持模式**（官方立场：同一工作目录不支持并发 terraform 命令）。本次安全的三个前提：

1. 所有资源名都带 `${terraform.workspace}` 前缀（本模块满足）；
2. 没有共享的全局无前缀资源（如保留 IP、LB、URL map——有的话并行拆会撞 409）；
3. 仅 destroy 期短时并发，没有并发 init。

更规范的写法，给每个进程钉死 workspace、不碰共享文件：

```bash
TF_WORKSPACE=dev  terraform destroy
TF_WORKSPACE=prod terraform destroy
```

或按环境分目录 / 直接串行（一次也就十几秒）。

**module 设计附注**：两个环境的 firewall target tag 都是 `http-server`，dev/prod 两条规则对两台 VM 都生效；本次两条规则完全相同所以无害，真实多环境应换隔离网络或带环境前缀的 tag。

### 概念结论（问答沉淀）

- **Terraform 的记忆 = state 账本**，不是代码、也不是云上现状。
- **plan 只对比「账本里记的现状」vs「代码描述的目标」**；仅对账本里已知的资源做 Refresh，不会主动去云上盘点未知资源。账本没记的，云上真有十个它也看不见 → 只能 import 认领。练习 4 用的是 CLI `terraform import`；**Terraform ≥1.5 还支持代码化的 `import` 块**（声明式导入，适合练习 9 的 CI/CD 场景）。
- **backend 块只是「记忆地址指针」**：`bucket` = 柜子，`prefix` = 文件夹，workspace 名 = 账本文件名（`default/dev/prod.tfstate`）；不写则默认本地 `./terraform.tfstate`。它不建桶、不进 plan、不决定建什么。`bucket` / `prefix` 可用 **`terraform init -backend-config=`** 参数化（别硬编码），练习 9 接 CI/CD 时就知道好处。
- **选 GCS 的真正收益**：state lock（同一账本同时只一人写）+ 版本历史（可回滚）。
- **换成空的本地账本 = 失忆**（`2 to add`），指回 GCS = 记忆恢复（`No changes`）——治好失忆的是「换回记了账的本子」，不是「回到云上」。

### 收官

dev 2 destroyed + prod 2 destroyed，计费归零。GCS 桶和三个空 state 保留，练习 6 继续用。
