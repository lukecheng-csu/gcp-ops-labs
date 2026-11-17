# 练习 10：CI/CD —— push 即部署，红了不许上

> 目标：把练习 9 那套「手敲 build + deploy + smoke」变成一条流水线。
> 代码 push 到 `main` → GitHub Actions 自动构建镜像 → 部署 Cloud Run → 跑 6 条冒烟断言；
> 断言不过，流水线红。**认证全程无 JSON 密钥**（Workload Identity Federation）。

## 实验目的（先读这段，再动手）

**一句话**：证明你能把「部署」从**人的动作**变成**流水线的动作**——不再是人记得敲哪几条命令，
而是一次 push 触发、失败自动红、凭证不落地。这是 DevOps 岗和运维岗的分水岭。

**这个实验要回答的 4 个问题**

1. **CI 怎么在没有密钥的情况下拿到 GCP 权限？** GitHub 的 OIDC token 怎么换成短期凭证？
   为什么 WIF 比「下载 SA 的 JSON key 塞进 Secret」安全一个量级（key 会泄漏、不会过期、不好轮换）？
2. **流水线失败时，线上会怎样？** 构建挂了（镜像没产出）和冒烟挂了（镜像已部署但断言不过）
   是两种完全不同的故障面——分别影响不影响正在服务的版本？
3. **权限给多了会怎样？** 部署 SA 少了 `run.admin` 会卡在哪一步、报什么错？
   给多了（比如 `owner`）又为什么是隐患？
4. **怎么回滚？** Cloud Run 的 revision 是天然的回滚点，`--to-revisions` 怎么把流量切回上一版？

**验收标准（做到才算过）**

- [ ] push 一次 → Actions 自动跑完 build + push 镜像 + deploy + 6 条冒烟，全绿
- [ ] GitHub 仓库里**没有任何 GCP 长期密钥**（Secrets 里只有 provider 名和 SA 邮箱，不是 JSON）
- [ ] 三轮破坏：撤权限（403）、改坏依赖（build 红但线上不受影响）、部署坏版本（冒烟红 → 回滚）
- [ ] 能说清「构建失败」和「冒烟失败」对线上的不同影响

**刻意不做（划边界，防跑偏）**

- 不做多环境（staging/prod）与审批流：本次只跑单环境 `main`
- 不做测试套件（pytest 单测）：本次门禁是**部署后的冒烟**，不是代码级单测
- 不做 Terraform 管流水线基础设施：`setup-wif.sh` 手写命令，练的是「知道每一步在建什么」
- 不做蓝绿/灰度：`--no-traffic` + 打 tag 再切流量属于进阶，只在本 README 末尾提一句

## 架构

```
你的 Mac ──git push──► GitHub 仓库 (lukecheng-csu/gcp-ops-labs)
                            │
                            │ ① OIDC token（无需密钥）
                            ▼
                    GitHub Actions runner
                            │ ② 换取短期凭证（WIF）
                            ▼
                    GCP: lab10-deployer SA
                            │ ③ docker build / push
                            ▼
                    Artifact Registry: lab10/api:<sha>
                            │ ④ gcloud run deploy
                            ▼
                    Cloud Run: lab10-api  ◄── ⑤ 冒烟 6 条（门禁）
```

**和练习 9 的差别只有一处**：练习 9 是你在终端里敲这 5 步；练习 10 是 runner 替你敲，
而且第 ⑤ 步失败会让整条流水线红。

## 免费红线

- GitHub Actions：公开仓库免费不限；私有仓库每月 2000 分钟（本练习一次约 1–2 分钟）
- Cloud Build **不用了**（这次在 runner 里 `docker build`），省下构建分钟
- Artifact Registry / Cloud Run：同练习 9，量极小；**练完删服务 + 仓库**

## S0 开工三件事（每个新窗口都要重粘）

```bash
cd ~/gcp-ops-labs/10-cicd-cloudrun
export PROJECT=lukechengtest REGION=us-central1 REPO_SLUG=lukecheng-csu/gcp-ops-labs
export CLOUDSDK_CORE_DISABLE_PROMPTS=1
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 \
       HTTP_PROXY=http://127.0.0.1:7897 HTTPS_PROXY=http://127.0.0.1:7897
G() { gcloud "$@"; }
```

## S1 前置复核

```bash
G run services list --region=$REGION          # 应为空（练习 9 已归零）
G artifacts repositories list --location=$REGION   # 应为空
git remote -v                                  # 确认是 lukecheng-csu/gcp-ops-labs
```

## S2 一次性基础设施（SA + WIF + AR 仓库）

```bash
bash scripts/setup-wif.sh
```

它会做 7 件事，**每一步都值得你知道在建什么**：

| 步骤 | 建什么 | 为什么 |
| --- | --- | --- |
| 1 | 开 4 个 API | `sts` / `iamcredentials` 是 WIF 换凭证必需，不开会报 403 |
| 2 | SA `lab10-deployer` | 专用身份，别用默认计算 SA（后者权限太大） |
| 3 | 三个角色：`run.admin` / `iam.serviceAccountUser` / `artifactregistry.writer` | 部署、以运行 SA 身份部署、推镜像——**只给这三条** |
| 4 | WIF 池 `github-pool` | 存放「外部身份提供方」的容器 |
| 5 | OIDC provider，带 `--attribute-condition` | **关键安全闸**：只有 `assertion.repository == 你的仓库` 才允许换取凭证 |
| 6 | `workloadIdentityUser` 绑定到 repo | 把「哪个仓库的 workflow」和「哪个 SA」绑死 |
| 7 | AR 仓库 `lab10` | 放镜像，按 sha 打 tag |

脚本最后会打印两个值，长这样：

```
WIF_PROVIDER      projects/184964235395/locations/global/workloadIdentityPools/github-pool/providers/github-provider
WIF_SERVICE_ACCOUNT  lab10-deployer@lukechengtest.iam.gserviceaccount.com
```

## S3 把两个值填进 GitHub

仓库页面 → **Settings → Secrets and variables → Actions → New repository secret**：

| Name | Value |
| --- | --- |
| `WIF_PROVIDER` | 上面打印的第一行 |
| `WIF_SERVICE_ACCOUNT` | 上面打印的第二行 |

注意：这两个**不是密钥**（provider 名和邮箱都是公开信息），放 Secret 只是图省事；
真正的安全来自「只有你的仓库能换到凭证」这条 attribute condition。

## S4 触发第一次流水线

workflow 文件已在 `.github/workflows/deploy-lab10.yml`，push 即触发：

```bash
cd ~/gcp-ops-labs
git pull
git commit --allow-empty -m "ci: 触发 lab10 首次流水线"
git push
```

页面看：仓库 → **Actions** → `deploy-lab10` → 点最新那次 run。

**逐段看日志，按这顺序**：

1. `Auth to GCP (WIF)` —— 换凭证成功会打印 `Authenticated as lab10-deployer@...`
2. `Show identity` —— 确认 active account 是那个 SA，不是你的个人账号
3. `Build image` / `Push image` —— 镜像 tag 是 commit sha
4. `Deploy to Cloud Run` —— 输出新的 revision 名
5. `Smoke test (部署门禁)` —— 6 条全 PASS 才算绿

## S5 门禁的意义（这次它真会红）

冒烟那一步用的是练习 9 同一个脚本，只是它现在**跑在流水线里**：

- 部署成功但 `/api/tasks` 返回 500 → 冒烟 6 条里 5 条 FAIL → 脚本退出码 1 → **整条流水线红**
- 红了的 run 在 Actions 列表里是 ❌，GitHub 会给你发邮件

这一点要记住：**流水线红不等于线上挂了**，它只是「不允许这次发布被认作成功」。真正的止损动作是
下一步的回滚。

## S6 破坏-修复三轮（不许跳）

### ① 撤权限 → deploy 步 403 → 定位在 IAM 不在代码

```bash
# 破坏：拿掉 run.admin
G projects remove-iam-policy-binding $PROJECT \
  --member="serviceAccount:lab10-deployer@$PROJECT.iam.gserviceaccount.com" \
  --role=roles/run.admin --condition=None

git commit --allow-empty -m "ci: 权限破坏演练" && git push
```

**预期**：build + push 都绿（`artifactregistry.writer` 还在），到 `Deploy to Cloud Run` 报
`PERMISSION_DENIED: Permission 'run.services.update' denied`。

**看点**：错误出现在第 4 步而不是第 1 步——说明**权限是逐步用到的**，不是一开始就全查一遍。
定位方法是看「哪一步开始红」，而不是从头怀疑代码。

```bash
# 修复
G projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:lab10-deployer@$PROJECT.iam.gserviceaccount.com" \
  --role=roles/run.admin --condition=None
```

### ② 改坏依赖 → build 红，但**线上完全不受影响**

```bash
# 破坏：往 requirements 里加一个不存在的包
echo "fastapi-nonexistent-package==9.9.9" >> 10-cicd-cloudrun/app/requirements.txt
git add -A && git commit -m "ci: 依赖破坏演练" && git push
```

**预期**：`Build image` 步 `pip install` 报 `No matching distribution found`，流水线红。

**看点（这次最重要）**：`gcloud run services describe` 看 revision **没变**、线上 URL 照样 200。
因为镜像压根没产出，部署步骤根本没执行——**构建失败是「发布失败」，不是「线上故障」**。

```bash
# 修复：把那一行删掉再 push
```

### ③ 部署坏版本 → 冒烟红 → 用 revision 回滚

```bash
# 先记下当前正常 revision
G run revisions list --service=lab10-api --region=$REGION

# 破坏：把 workflow 里的 LAB10_MODE=dev 改成 broken（模拟"配置改错但镜像能构建"）
# 改完 push，等流水线跑到 Smoke test → 应该红
```

**预期**：部署成功（新 revision 已 100% 流量），但冒烟 5 条 FAIL → 流水线红。
这时候线上**真的坏了**（`/api/tasks` 500，`/health` 仍 200）。

回滚有两种，**都练一遍**：

```bash
# 方式 A：把流量切回上一个正常 revision（秒级，镜像不用重建）
GOOD=$(G run revisions list --service=lab10-api --region=$REGION \
  --format='value(metadata.name)' --limit=2 | tail -1)
G run services update-traffic lab10-api --region=$REGION --to-revisions="${GOOD}=100"
curl -sS -m 15 --noproxy '*' -w '\n[HTTP %{http_code}]\n' "$URL/api/tasks"

# 方式 B：把 workflow 改回 dev，重新走一遍流水线（正解，但慢一分钟）
```

**看点**：方式 A 是**止血**，方式 B 是**修复**。生产事故里这两步是分开做的：
先止血（回滚流量），再修代码（走正常发布）。

## S7 归零（练完不过夜）

```bash
# 1) 服务与镜像仓库
G run services delete lab10-api --region=$REGION --quiet
G artifacts repositories delete lab10 --location=$REGION --quiet

# 2) WIF 与 SA（这才是「无密钥」的收尾：连信任关系一起拆）
G iam service-accounts delete lab10-deployer@$PROJECT.iam.gserviceaccount.com --quiet
G iam workload-identity-pools providers delete github-provider \
  --workload-identity-pool=github-pool --location=global --quiet
G iam workload-identity-pools delete github-pool --location=global --quiet

# 3) 复核：全空
G run services list --region=$REGION
G artifacts repositories list --location=$REGION
G iam service-accounts list --filter='email~lab10'
```

GitHub 侧：Settings → Secrets 里那两条可以留着（下次练习还要用），也可以删。

**注意**：workflow 文件留在仓库里没关系，但如果你删了 SA，之后任何 push 到
`10-cicd-cloudrun/**` 都会让流水线红在 Auth 步——这是预期行为，不是坏了。

## 进阶（可选，面试加分）

想让「冒烟不过就绝不上线」更严谨，可以改成**先不发流量**：

```bash
# 部署到无流量 revision，拿到 tag URL 单独测
G run deploy lab10-api --image "$IMAGE" --region=$REGION --no-traffic \
  --tag=staging --set-env-vars=LAB10_MODE=dev
# smoke 打 https://staging---lab10-api-xxx.a.run.app
# 全绿后再把 100% 流量切过去
G run services update-traffic lab10-api --region=$REGION --to-latest
```

这样冒烟失败时，**线上一条流量都没受影响**——这才是「门禁」最完整的形态。

## 翻车清单

| # | 现象 | 原因 / 解法 |
| --- | --- | --- |
| 1 | `Auth to GCP (WIF)` 报 `invalid_target` 或 `unauthorized_client` | `WIF_PROVIDER` 填错（少了 `projects/<号>/locations/global/...` 前缀），或 provider 的 attribute-condition 里的仓库名和实际不符 |
| 2 | Auth 报 `Permission 'iam.serviceAccounts.getAccessToken' denied` | 少了 `workloadIdentityUser` 绑定；检查 `principalSet` 里的仓库名大小写 |
| 3 | `docker push` 报 `denied: Permission "artifactregistry.repositories.uploadArtifacts" denied` | SA 少了 `artifactregistry.writer` |
| 4 | deploy 报 `Permission 'run.services.update' denied` | 少了 `run.admin`（破坏 ① 就是这个） |
| 5 | deploy 报 `Permission 'iam.serviceaccounts.actAs' denied` | 少了 `iam.serviceAccountUser`——部署时要「以运行 SA 身份」创建 revision |
| 6 | 流水线绿但服务还是旧版本 | 看 deploy 步是否真的执行（`--quiet` 会吞掉确认，但不会吞错误）；确认看的是 `status.latestReadyRevisionName` |
| 7 | Actions 里根本没有这个 workflow | workflow 必须在**仓库根** `.github/workflows/`，子目录里的不生效 |
| 8 | push 了但没触发 | `paths` 过滤只匹配 `10-cicd-cloudrun/**` 和 workflow 自身；改别处不会触发，可用 `workflow_dispatch` 手动点 |
