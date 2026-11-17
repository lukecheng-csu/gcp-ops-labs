# 练习 9：无服务器 API（Cloud Run）

> 目标：把一个自己写的 FastAPI 应用做成镜像 → 推 Artifact Registry → 部署 Cloud Run，
> 外网一条 URL 直达、无服务器、按请求付费。**统一错误结构**是本练习的代码侧交付物，
> 三轮破坏-修复是运维侧交付物。

## 实验目的（先读这段，再动手）

**一句话**：证明你能把「自己写的应用」变成一个 URL、按请求付费、不用管服务器的服务，
并且它坏了你能定位——不是只会敲一条 `gcloud run deploy`。

**这个实验要回答的 5 个问题**

1. **代码怎么变成线上服务**：Dockerfile 为什么要监听 `$PORT`？镜像仓（Artifact Registry）
   在链路里扮演什么角色？为什么部署完就自动有 HTTPS 和域名？
2. **云端构建 vs 本地构建**：本机 Docker 代理坏着（指向死掉的 7890），为什么
   `gcloud builds submit` 照样能出镜像？这两种构建什么时候该用哪个？
3. **错误格式为什么必须统一**：FastAPI 原生是 `{"detail":...}`，我为什么要强行改成
   `{"error":{"code","message"}}`？谁在消费这个格式（前端、Blackbox 探针、CI、告警）？
4. **三种「坏」怎么区分**：500（应用自己炸）、504（平台网关掐断）、403（IAM 拒绝）——
   分别是谁造成的、日志长什么样、修法在哪一层？
5. **部署完怎么证明它是好的**：6 条冒烟断言各自防什么事故？为什么 2xx 看内容、
   4xx 看结构？这脚本进 CI 之后是什么角色？

**验收标准（做到才算过）**

- [ ] 一条 `gcloud builds submit` 在云端出镜像，本机不需要装 Docker
- [ ] 部署后外网 URL 可达，`/health` 返回 200 且 `"mode"` 反映注入的环境变量
- [ ] 所有非 2xx 都是 `{"error":{"code","message"}}`（六条断言全绿，含 201 反向证据）
- [ ] 三轮破坏（env 改错 / 超时 / 撤权限）都看到现象、都能从日志定位、都修回来
- [ ] 能说出 504 为什么**不会**进 FastAPI 的异常处理器
- [ ] 练完全删：Cloud Run 服务 + AR 仓库，无计费残留

**刻意不做（划边界，防跑偏）**

- **不加数据库**：任务表故意放内存字典，就是为了让你亲眼看到「扩容/重启数据就没了」——
  这个缺陷留给练习 6 用 Cloud SQL 补
- **不做压测/并发**：本次验的是「对不对」，不是「扛不扛得住」；稳定性归监控（练习 7/8）和压测
- **不做鉴权细节**：`--allow-unauthenticated` 是刻意的，IAM 最小权限在练习 11
- **不追求生产级**：单区域、`max-instances=2`、无自定义域名，够验证概念就行

**学完能对外这么讲**

> 「部署不是一条 `deploy` 命令，而是构建 → 部署 → 冒烟三段。我给 API 定了统一错误契约，
> 用 6 条断言把它固化成门禁，代码改坏了流水线立刻红。」
>
> 「504 是 Cloud Run 网关在平台层掐的，应用的异常处理器根本管不到——这类错误只能从
> 超时配置和平台日志入手，跟 500 完全不是一个层面。」

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
# 原始流水：平台请求日志 + 容器 stdout 混排
G run services logs read lab09-api --region=$REGION --limit 20

# 只看错误及以上。注意参数名是 --log-filter，不是 --filter（后者会报 unrecognized arguments）
G run services logs read lab09-api --region=$REGION --log-filter='severity>=ERROR' --limit 10
```

**更好用的一条：带状态码和耗时的结构化视图**（排 5xx / 超时首选，一眼看 latency）

```bash
G logging read 'resource.type="cloud_run_revision"
  AND resource.labels.service_name="lab09-api"
  AND httpRequest.status>=400' \
  --limit=10 --format='table(timestamp,httpRequest.status,httpRequest.latency,httpRequest.requestUrl)'
```

输出长这样（真实记录）：

```
TIMESTAMP                    STATUS  LATENCY        REQUEST_URL
2026-11-17T07:46:51Z         504     60.000597879s  .../api/slow?seconds=70
2026-11-17T07:40:27Z         400     0.004092879s   .../api/tasks
```

**读日志的三个要点**

1. 一条请求两行：`GET 200 https://...` 是**平台**记的（带 URL 和状态码），
   `INFO: 169.254.x.x - "GET / HTTP/1.1" 200` 是**容器里 uvicorn** 记的。只有平台行没有容器行
   = 请求没进容器（对照排错表 9）。
2. `169.254.169.126` 是 Cloud Run 内部代理，**不是你**；真实客户端 IP 在 `X-Forwarded-For`。
3. 时间戳是 **UTC**，北京时间要 +8。

**504 的判据（本练习的关键区分）**：平台日志有 504、`latency` 恰好等于 `--timeout` 的秒数
（60.000597879s 就是 60s 上限），而容器侧**没有该请求的完成日志**——因为响应还没生成，
连接已经被网关切了。应用里的 `exception_handler` 根本没机会执行。

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
G run services logs read lab09-api --region=$REGION --log-filter='severity>=ERROR' --limit 10

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

### S8 实测记录（2026-11-17，手敲）

| 轮次 | 破坏动作 | 现象 | 硬证据 |
| --- | --- | --- | --- |
| ① 环境变量 | `LAB09_MODE=broken` 重新部署（revision `00003-ffj`） | `/api/tasks` 500 且是统一结构；`/health` 仍 200 但 `"mode":"broken"` | `gcloud run revisions describe` 能看到该 revision 的 env 就是 broken；改回 dev 生成 `00004` |
| ② 超时 | `--timeout=20s`，请求 `seconds=60` | 504，`time` 显示 20.695s 总耗时 | 平台日志 `latency = 20.001043161s`（精确等于超时值）；容器侧**无完成日志** |
| ③ IAM | 移除 `allUsers → run.invoker` | `/health` 立刻 403 | 该秒只有平台 403 + `The request was not authenticated...`，**没有 uvicorn 行**；加回后立刻出现 `INFO: ... 200 OK` |

> 另有一次 `seconds=70`（默认 60s 超时）的 504，平台记 `latency = 60.000597879s`。
> 两个数字放在一起就能证明：**耗时几乎精确等于 `--timeout`，误差只在毫秒级连接开销**——
> 是平台按配置掐的，不是应用代码算出来的。

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
| 4 | 500 但日志看不出啥 | 用 `--log-filter='severity>=ERROR'`；FastAPI 的 traceback 在 textPayload 里，搜 `Traceback` |
| 5 | 请求 504 但应用没崩 | 平台超时（`--timeout`），不是 bug；对照 S8 ② |
| 6 | 免费/计费焦虑 | Cloud Run 按请求计费且免费层大；唯一会悄悄计费的是 **AR 仓库存镜像**，归零第 2 步别漏 |
| 7 | 命令贴过去报 `command not found: G` | 新窗口没粘 S0 开工三件事 |
| 8 | `smoke.sh` 报 `line 21: want?: unbound variable` | 旧版失败提示里 `$want` 紧贴中文书名号，Mac 自带 bash 3.2 解析出错。已重写为纯 ASCII 提示 + `${var}` 全加花括号，并修复 URL 末尾 `//` 只去一个斜杠的问题（2026-11-17 手敲实测踩到） |
| 9 | **`/healthz` 返回 Google 的 404 HTML 页（带 logo），容器日志里没这条请求** | **Cloud Run 前端保留路径**：`*.run.app` 会拦 `/healthz` 和所有以 `z` 结尾的路径（`/readyz`、`/livez` 等），请求到不了容器，加不加 `--noproxy` 都一样；加尾斜杠 `/healthz/` 反而能到。**本练习已改用 `/health`**（2026-11-17 手敲实测：Google 官方限制 + Stack Overflow/GitHub 多人踩坑）。判据：`/healthz` 响应是 `text/html`、1568 字节、无 `x-cloud-trace-context`；真容器响应带 `server: Google Frontend` + JSON 体 |
| 10 | **`smoke.sh` 输出 `got HTTP 000000`，但 body 里是正确 JSON** | 两个叠加原因：① 旧版一条断言发两次 curl（一次取 body、一次取 code），本地代理（7897 之类）对 `*.run.app` 半通，第二次被掐断，code 就成了 000；② curl 失败时 `-w '%{http_code}'` 已经输出 `000`，`\|\| printf '000'` 又追加一个，拼成 `000000`。**已重写**：一条断言只发一次请求（body+code 同源）、失败自动 `--noproxy '*'` 直连重试一次、再原样重试一次，curl 原始报错一并打印。另外 bash 3.2 在 `set -u` 下展开**空数组**会报 `extra[@]: unbound variable`，所以脚本里不要用数组拼 curl 参数（2026-11-17 手敲实测踩到） |
| 11 | `gcloud run services logs read ... --filter=...` 报 `unrecognized arguments: --filter=severity>=ERROR (did you mean '--log-filter'?)` | gcloud 591.0.0 起该子命令的过滤参数改名 **`--log-filter`**（`--filter` 只在 `compute list` 这类资源列表命令上用）。已全文改正。想看「状态码 + 耗时」的结构化视图，用 `gcloud logging read` 配 `--format='table(timestamp,httpRequest.status,httpRequest.latency,httpRequest.requestUrl)'`，比纯文本流水好读（2026-11-17 手敲实测） |

## 与前后练习的衔接

- 承接练习 3/8：同一个 `health`+内容校验套路——练习 8 的 Blackbox 以后可以直接拨这个 API 的 `/health`
- 铺垫练习 10（CI/CD）：本练习的手敲 `builds submit + run deploy` 就是 CI/CD 要自动化的两步；
  练习 10 用 GitHub Actions + Workload Identity 无密钥把这两步串起来
- 铺垫练习 11（IAM）：S8 ③ 的 `run.invoker` 就是服务级最小权限的入口

## 交付物自检（做完在 README 勾掉）

- [x] `gcloud builds submit` 一条命令出镜像（S4）— 2026-11-17 实测 30s SUCCESS
- [x] Cloud Run URL 外网可达，`/health` 200（S5/S6）— revision `00006-znf`
- [x] 所有非 2xx 都是 `{"error":{"code","message"}}`（S6 六断言全绿）— 含手敲 6 条 + 201 反向
- [x] 三轮破坏都看到现象、都能定位、都修回来了（S8 ①②③）— 见上方实测记录
- [x] `gcloud run services logs read` 会用 severity 过滤（S7）— 参数是 `--log-filter`
- [ ] 服务 + AR 仓库全删（S9 复核为空）
