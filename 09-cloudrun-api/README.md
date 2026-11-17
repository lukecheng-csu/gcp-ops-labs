# 练习 9：无服务器 API（Cloud Run）

> 目标：把一个自己写的 FastAPI 应用做成镜像 → 推 Artifact Registry → 部署 Cloud Run，
> 外网一条 URL 直达、无服务器、按请求付费。**统一错误结构**是本练习的代码侧交付物，
> 三轮破坏-修复是运维侧交付物。

## 架构（就一条链，没有 VM）

```
你的 Mac ──gcloud builds submit──► Cloud Build（云端构建，不占本机）
                                        │
                                        ▼ 打镜像
                                 Artifact Registry（私有镜像仓）
                                        │
                                        ▼ 部署
                                   Cloud Run（lab09-api）
                                        ▲
外部 curl ◄──── https://lab09-api-xxx-uc.a.run.app ────┘（自动 TLS + 域名）
```

对比练习 1–8：**第一次全程不需要一台属于你的 VM**。Cloud Run 帮你管容器调度、
TLS 证书、域名、扩缩容，你只交付「一个监听 $PORT 的容器」。

## 免费红线

- Cloud Run 免费层：每月 200 万请求 + 36 万 GB-秒（本练习用不到零头）；`--max-instances=2` 防失控
- Cloud Build：每天 120 build 分钟免费（本练习一次 build 约 2 分钟）
- Artifact Registry：0.5GB 免费存储（一个 python:slim 镜像约 150MB）
- **归零只删 Cloud Run 服务 + AR 仓库，不产生 VM/磁盘挂账**；但 AR 镜像按存续天数计费，练完就删

## S0 开工三件事（每个新窗口都要重粘）

```bash
cd ~/gcp-ops-labs/09-cloudrun-api
export PROJECT=lukechengtest REGION=us-central1 CLOUDSDK_CORE_DISABLE_PROMPTS=1
export http_proxy=http://127.0.0.1:7897 https_proxy=http://127.0.0.1:7897 \
       HTTP_PROXY=http://127.0.0.1:7897 HTTPS_PROXY=http://127.0.0.1:7897
G() { gcloud "$@"; }
```

## S1 前置复核（2026-11-16 已实测，直接开敲）

- 练习 8 已全量归零：`lab08-mon` 已删、防火墙无残留、两台靶机采集器已拆、GCS 无 lab08 对象
- 当前 GCP 实例只剩 `practice-web`（10.128.0.3 / 35.194.5.128）
- 仓库 HEAD 含本目录；代码三件套 = `app/main.py` + `app/requirements.txt` + `Dockerfile`

```bash
G compute instances list --format='table(name,status)'
```

## S2 开 API（三个，一次到位）

```bash
G services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com
G services list --enabled --filter='config.name:(run OR artifactregistry OR cloudbuild)' \
  --format='value(config.name)'
```

期望三个都返回（enable 是幂等的，已开会直接成功）。

## S3 建 Artifact Registry 仓库

```bash
G artifacts repositories create lab09 \
  --repository-format=docker --location=$REGION
G artifacts repositories list --location=$REGION
```

## S4 云端构建镜像（本机不装 Docker）

```bash
G builds submit . \
  --tag "us-central1-docker.pkg.dev/$PROJECT/lab09/api:v1"
```

- 构建在 Google 云端跑（拉基础镜像、pip install 都不走你的代理），**日志实时刷在终端**
- 结尾看到 `STATUS: DONE` + `IMAGE` 一行即成功；失败 90% 是 Dockerfile 路径（build 上下文是 `.`）

## S5 部署 Cloud Run

```bash
G run deploy lab09-api \
  --image "us-central1-docker.pkg.dev/$PROJECT/lab09/api:v1" \
  --region=$REGION --allow-unauthenticated \
  --set-env-vars=LAB09_MODE=dev \
  --memory=256Mi --cpu=1 --timeout=60s --max-instances=2 --min-instances=0
```

- 首次部署要等 IAM 收敛，1~3 分钟；成功后打印 Service URL（形如 `https://lab09-api-xxxxx-uc.a.run.app`）
- `--allow-unauthenticated` = 公网可访问（练习用；生产会换 IAM 限定调用者）
- 记下 URL，后面全用它：

```bash
export URL=https://<你的服务URL>
echo $URL
```

## S6 冒烟测试（6 个断言，含统一错误结构）

一键版（脚本就是把这 6 条串起来跑）：

```bash
bash scripts/smoke.sh        # 先 export URL=... 见 S5
```

### S6 手敲版：一条一条来，看清每条在验什么

`-w '\n[HTTP %{http_code}]\n'` 的作用：body 打完再单独打一行状态码，一眼看清「内容对不对 + 码对不对」。
`--noproxy '*'` 是绕开本地代理直连（你的 7897 对 `*.run.app` 常半通，走代理会莫名失败）。

**① 健康检查 —— 容器活着、环境变量生效**
验：进程起来了，且 `LAB09_MODE=dev` 真的注进容器了（不是代码里写死的默认值）。
```bash
curl -sS -m 15 --noproxy '*' -w '\n[HTTP %{http_code}]\n' "$URL/health"
# {"status":"ok","mode":"dev","version":"1.0.0"}   [HTTP 200]
```

**② 根信息 —— 服务身份**
验：请求真的打到了你自己的镜像，不是 Google 的兜底页（兜底页会是 HTML + 带 Google logo）。
```bash
curl -sS -m 15 --noproxy '*' -w '\n[HTTP %{http_code}]\n' "$URL/"
# {"service":"lab09-api","version":"1.0.0","mode":"dev"}   [HTTP 200]
```

**③ 列表 —— 正常业务路径**
验：业务路由通，返回结构是 `{"count":N,"tasks":[...]}`。
```bash
curl -sS -m 15 --noproxy '*' -w '\n[HTTP %{http_code}]\n' "$URL/api/tasks"
# {"count":2,"tasks":[{"id":1,...},{"id":2,...}]}   [HTTP 200]
```

**④ 404 —— 错误结构是否统一（本练习的核心）**
验：不存在的资源**不是** FastAPI 默认的 `{"detail":"Not Found"}`，而是自己的 `{"error":{"code","message"}}`。
```bash
curl -sS -m 15 --noproxy '*' -w '\n[HTTP %{http_code}]\n' "$URL/api/tasks/999"
# {"error":{"code":404,"message":"任务 999 不存在"}}   [HTTP 404]
```

**⑤ 参数校验 400 —— 非法输入也走同一套结构**
验：`seconds=abc` 转数字失败，返回 400，且错误体同样是 `{"error":...}`（不是 `detail` 数组）。
```bash
curl -sS -m 15 --noproxy '*' -w '\n[HTTP %{http_code}]\n' "$URL/api/slow?seconds=abc"
# {"error":{"code":400,"message":"参数校验失败: Input should be a valid number...(field: ('query','seconds'))"}}   [HTTP 400]
```

**⑥ POST 空 title —— 写接口的输入校验**
验：`title` 有 `min_length=1`，空字符串必须 400 且统一结构（不能静默创建空任务）。
```bash
curl -sS -m 15 --noproxy '*' -w '\n[HTTP %{http_code}]\n' \
  -X POST -H 'Content-Type: application/json' -d '{"title":""}' "$URL/api/tasks"
# {"error":{"code":400,"message":"参数校验失败: String should have at least 1 character...(field: ('body','title'))"}}   [HTTP 400]
```

**⑥ 的反向证据 —— 合法输入应该建成（可选，跑完记得心里有数）**
```bash
curl -sS -m 15 --noproxy '*' -w '\n[HTTP %{http_code}]\n' \
  -X POST -H 'Content-Type: application/json' -d '{"title":"手敲验证"}' "$URL/api/tasks"
# {"created":{"id":3,"title":"手敲验证","done":false}}   [HTTP 201]
```

> 判读口诀：**2xx 看内容对不对，4xx 看结构统不统一**。① 挂 = 部署/环境变量问题；
> ② 挂且返回 HTML = 打到了 Google 前端而不是你的容器（对照排错表 9）；③④⑤⑥ 挂 = 代码逻辑问题。

## S7 看日志（排障的标配入口）

```bash
G run services logs read lab09-api --region=$REGION --limit 20
G run services logs read lab09-api --region=$REGION --filter='severity>=ERROR' --limit 10
```

## S8 破坏-修复三轮（不许跳）

### ① 环境变量改错 → 500 → 日志定位 → 修复

```bash
# 破坏：部署一个"坏模式"新版本（用同一镜像，只改环境变量）
G run deploy lab09-api --image "us-central1-docker.pkg.dev/$PROJECT/lab09/api:v1" \
  --region=$REGION --allow-unauthenticated --set-env-vars=LAB09_MODE=broken \
  --memory=256Mi --cpu=1 --timeout=60s --max-instances=2

curl -sS -o /dev/null -w '%{http_code}\n' $URL/api/tasks     # 500
curl -sS $URL/api/tasks; echo                                 # 统一错误结构

# 定位：日志里能看到 500 + 我们的中文报错文案
G run services logs read lab09-api --region=$REGION --filter='severity>=ERROR' --limit 10

# 修复：改回 dev（重新部署即可，容器/镜像都不用动）
G run deploy lab09-api --image "us-central1-docker.pkg.dev/$PROJECT/lab09/api:v1" \
  --region=$REGION --allow-unauthenticated --set-env-vars=LAB09_MODE=dev \
  --memory=256Mi --cpu=1 --timeout=60s --max-instances=2
curl -sS $URL/api/tasks; echo                                  # 200
```

**看点**：改环境变量发新版是 Cloud Run 最常用的「配置热修」——不动镜像，秒级生效；
旧的 healthy revision 还在，`G run revisions list` 能看到版本序列。

### ② 超时 → 504 → 看清超时是平台判的

```bash
# 破坏：把超时压到 20s，然后请求一个睡 60s 的端点
G run services update lab09-api --region=$REGION --timeout=20s
time curl -sS -o /dev/null -w '%{http_code}\n' "$URL/api/slow?seconds=60"   # 504，约 20s 处断
curl -sS "$URL/api/slow?seconds=60"; echo

# 修复：超时调回 60s（或修代码别让请求睡 60 秒——生产里正确答案是后者）
G run services update lab09-api --region=$REGION --timeout=60s
curl -sS "$URL/api/slow?seconds=3"; echo    # 200
```

**看点**：504 是 Cloud Run 在平台层掐断的（应用里没写一行超时逻辑）；
`--timeout` 上限 3600s。顺带观察 `--min-instances=0` 时第一次请求的冷启动延迟。

### ③ 撤公网权限 → 403 → 加回

```bash
# 破坏：拿掉匿名调用权
G run services remove-iam-policy-binding lab09-api --region=$REGION \
  --member=allUsers --role=roles/run.invoker
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' $URL/health    # 403

# 修复：加回
G run services add-iam-policy-binding lab09-api --region=$REGION \
  --member=allUsers --role=roles/run.invoker
sleep 20
curl -sS -o /dev/null -w '%{http_code}\n' $URL/health    # 200
```

**看点**：IAM 收敛要等十几秒（刚加完就 curl 可能还 403，等一下再判）；
这条就是练习 11（IAM 纵深）的前菜。

## S9 归零（练完不过夜）

```bash
G run services delete lab09-api --region=$REGION
G artifacts repositories delete lab09 --location=$REGION
# 复核（期望都是空/404）
G run services list --region=$REGION
G artifacts repositories list --location=$REGION
```

本地无需清理（没有渲染产物）。

## 翻车清单（踩过的坑先看这）

| # | 症状 | 原因/解法 |
| --- | --- | --- |
| 1 | build 卡住或 `docker push` 权限错 | 用 `gcloud builds submit`（云端构建+推送一体），别本机 docker build 后手推；本机走 Clash 时 push 私仓常死 |
| 2 | 部署后 revision 起不来（`Container failed to start`） | 九成是**没监听 $PORT**（Dockerfile 里写死了 8080 之外的端口或用了 exec 形式 CMD 不展开变量）；本模板用 shell 形式 CMD，已避开 |
| 3 | `--allow-unauthenticated` 后仍 403 | IAM 收敛延迟，等 30 秒再试；还不行看 `G run services get-iam-policy` |
| 4 | 500 但日志看不出啥 | 用 `--filter='severity>=ERROR'`；FastAPI 的 traceback 在 textPayload 里，搜 `Traceback` |
| 5 | 请求 504 但应用没崩 | 平台超时（`--timeout`），不是 bug；对照 S8 ② |
| 6 | 免费/计费焦虑 | Cloud Run 按请求计费且免费层大；唯一会悄悄计费的是 **AR 仓库存镜像**，归零第 2 步别漏 |
| 7 | 命令贴过去报 `command not found: G` | 新窗口没粘 S0 开工三件事 |
| 8 | `smoke.sh` 报 `line 21: want?: unbound variable` | 旧版失败提示里 `$want` 紧贴中文书名号，Mac 自带 bash 3.2 解析出错。已重写为纯 ASCII 提示 + `${var}` 全加花括号，并修复 URL 末尾 `//` 只去一个斜杠的问题（2026-11-17 手敲实测踩到） |
| 9 | **`/healthz` 返回 Google 的 404 HTML 页（带 logo），容器日志里没这条请求** | **Cloud Run 前端保留路径**：`*.run.app` 会拦 `/healthz` 和所有以 `z` 结尾的路径（`/readyz`、`/livez` 等），请求到不了容器，加不加 `--noproxy` 都一样；加尾斜杠 `/healthz/` 反而能到。**本练习已改用 `/health`**（2026-11-17 手敲实测：Google 官方限制 + Stack Overflow/GitHub 多人踩坑）。判据：`/healthz` 响应是 `text/html`、1568 字节、无 `x-cloud-trace-context`；真容器响应带 `server: Google Frontend` + JSON 体 |
| 10 | **`smoke.sh` 输出 `got HTTP 000000`，但 body 里是正确 JSON** | 两个叠加原因：① 旧版一条断言发两次 curl（一次取 body、一次取 code），本地代理（7897 之类）对 `*.run.app` 半通，第二次被掐断，code 就成了 000；② curl 失败时 `-w '%{http_code}'` 已经输出 `000`，`\|\| printf '000'` 又追加一个，拼成 `000000`。**已重写**：一条断言只发一次请求（body+code 同源）、失败自动 `--noproxy '*'` 直连重试一次、再原样重试一次，curl 原始报错一并打印。另外 bash 3.2 在 `set -u` 下展开**空数组**会报 `extra[@]: unbound variable`，所以脚本里不要用数组拼 curl 参数（2026-11-17 手敲实测踩到） |

## 与前后练习的衔接

- 承接练习 3/8：同一个 `health`+内容校验套路——练习 8 的 Blackbox 以后可以直接拨这个 API 的 `/health`
- 铺垫练习 10（CI/CD）：本练习的手敲 `builds submit + run deploy` 就是 CI/CD 要自动化的两步；
  练习 10 用 GitHub Actions + Workload Identity 无密钥把这两步串起来
- 铺垫练习 11（IAM）：S8 ③ 的 `run.invoker` 就是服务级最小权限的入口

## 交付物自检（做完在 README 勾掉）

- [ ] `gcloud builds submit` 一条命令出镜像（S4）
- [ ] Cloud Run URL 外网可达，`/health` 200（S5/S6）
- [ ] 所有非 2xx 都是 `{"error":{"code","message"}}`（S6 六断言全绿）
- [ ] 三轮破坏都看到现象、都能定位、都修回来了（S8 ①②③）
- [ ] `gcloud run services logs read` 会用 severity 过滤（S7）
- [ ] 服务 + AR 仓库全删（S9 复核为空）
