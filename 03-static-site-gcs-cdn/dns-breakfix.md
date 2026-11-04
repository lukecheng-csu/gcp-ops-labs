# 练习 3 · 破坏 3：DNS 指错 IP（A 记录 → 黑洞）

## 先回答：改哪里？

| 位置 | 存的是什么 | 这次要动吗 |
|------|-----------|-----------|
| **Cloudflare** | `cloudworkflowdone.com` 主域 + 一条把 `static` 子域委派给 Google 的 **NS 记录**（灰云） | ❌ 不动 |
| **Google Cloud DNS**（zone: `static-site-zone`） | 真正的 **A 记录**：`static.cloudworkflowdone.com. → 136.82.37.171`（TTL 300） | ✅ 改这里 |

原因：练习 3 里子域是**走 NS 委派**交给 Cloud DNS 托管的。Cloudflare 只负责"把人指到 Google 的域名服务器"，具体 IP 归 Google 管。所以改 IP 只在 Cloud DNS 改，Cloudflare 面板上改任何 A 记录都不影响这个子域。

---

## 破坏目标

把 A 记录从 LB 的 IP（`136.82.37.171`）改成 `192.0.2.1`。

`192.0.2.1` 是 RFC 5737 的文档保留段（TEST-NET-1），**不可路由**——指过去等于把域名扔进黑洞：域名解析正常、包发不出去。

---

## 第 0 步 · 基线（先留证据）

```bash
# 1. 权威 NS 答案（真相，无缓存）
NS=$(gcloud dns managed-zones describe static-site-zone \
  --format='value(nameServers.firstof())' --project=lukechengtest)
echo "authoritative NS: $NS"
dig @$NS static.cloudworkflowdone.com +short

# 2. 本地 resolver 答案 + TTL
dig static.cloudworkflowdone.com +noall +answer

# 3. 服务本身正常（不带 --resolve，走真实 DNS）
curl --noproxy '*' -s -o /dev/null -w "baseline HTTP %{http_code}\n" \
  https://static.cloudworkflowdone.com/
```

预期：dig 返回 `136.82.37.171`，curl 200。

---

## 第 1 步 · 破坏（事务改记录）

Cloud DNS 改记录值必须走**事务**（先删旧再加新，一次提交）：

```bash
gcloud dns record-sets transaction start --zone=static-site-zone

gcloud dns record-sets transaction remove static.cloudworkflowdone.com. \
  --zone=static-site-zone --type=A --ttl=300

gcloud dns record-sets transaction add 192.0.2.1 \
  --zone=static-site-zone --name=static.cloudworkflowdone.com. \
  --type=A --ttl=300

gcloud dns record-sets transaction execute --zone=static-site-zone
```

立即用权威 NS 验证改动已生效（这个不经过任何缓存，几秒内就是新答案）：

```bash
dig @$NS static.cloudworkflowdone.com +short
# 预期: 192.0.2.1
```

---

## 第 2 步 · 观察（三层证据）

| # | 手段 | 命令 | 预期现象 | 说明 |
|---|------|------|----------|------|
| 1 | 权威 NS | `dig @$NS static.cloudworkflowdone.com +short` | `192.0.2.1` | 真相，秒级生效 |
| 2 | 本地 resolver | `dig static.cloudworkflowdone.com +short` | 可能还是旧 IP | **TTL=300 缓存**，最长 5 分钟才换 |
| 3 | curl 走真实 DNS | `curl --noproxy '*' -v --max-time 15 https://static.cloudworkflowdone.com/ -o /dev/null` | 连接超时 | 包发往 192.0.2.1 黑洞 |
| 4 | 浏览器（电脑/手机） | 直接开 `https://static.cloudworkflowdone.com/` | `ERR_CONNECTION_TIMED_OUT` 类超时页 | **不是 5xx**——请求根本没到任何服务器 |

### 三个关键观察点（这次破坏的灵魂）

1. **报错形态是"超时"，不是 5xx。** DNS 是导航：导航指错了，车根本到不了店。对比破坏 1（403）是"到了店被拒"，这次是"压根没到店"。
2. **Cloudflare 面板一片安静。** 这个子域委派走了，流量不经过 Cloudflare，所以 Cloudflare 不会给它出任何错误页。别去 Cloudflare 里找原因。
3. **`curl --resolve` 测不出这次破坏！** `--resolve ...:443:136.82.37.171` 是手动指定目的地，会**绕过 DNS**。用它 curl 依然是 200（证书也正常）。这正好反向证明：**服务本身没坏，是导航指错了路**——可以拿这个当对照实验。

---

## 第 3 步 · 回滚

```bash
gcloud dns record-sets transaction start --zone=static-site-zone

gcloud dns record-sets transaction remove static.cloudworkflowdone.com. \
  --zone=static-site-zone --type=A --ttl=300

gcloud dns record-sets transaction add 136.82.37.171 \
  --zone=static-site-zone --name=static.cloudworkflowdone.com. \
  --type=A --ttl=300

gcloud dns record-sets transaction execute --zone=static-site-zone

dig @$NS static.cloudworkflowdone.com +short
# 预期: 136.82.37.171
```

---

## 第 4 步 · 验证恢复

```bash
# 等 resolver 缓存过期（TTL 300，最长 5 分钟），或直接盯权威 NS 已确认回滚
dig static.cloudworkflowdone.com +noall +answer   # TTL 会倒数，归零后换成新答案

curl --noproxy '*' -s -o /dev/null -w "after HTTP %{http_code}\n" \
  https://static.cloudworkflowdone.com/
# 预期: 200
```

---

## 踩坑预警

- **`--resolve` 绕过 DNS**：它能让 curl 在 DNS 全坏的情况下照样 200。测 DNS 问题永远别带它。
- **TTL 缓存**：本地 dig / curl 可能最长 5 分钟还显示旧状态，判断生效与否以**权威 NS** 为准，别拿缓存当真相（和破坏 2 "等真正生效再测"是同一个教训）。
- **事务必须配对**：`transaction remove` 的 name/type/ttl 必须和现有记录完全一致，否则提交报错。
- **证书不受影响**：Google 托管证书还是 ACTIVE。DNS 坏只坏"找到服务器"这一步，TLS 层毫无感知。

## 实战记录（2026-11-04 已跑通）

破坏执行顺利：事务 `change 2` status=done，A 记录成功换成 `192.0.2.1`。三层观察全部命中预期，过程中额外踩中两个新坑：

### 坑 1：dig 权威 NS 查出空答案 —— 字母没对上

```
dig @ns-cloud-a1.googledomains.com ...   ← 空答案
dig @ns-cloud-c1.googledomains.com ...   ← 192.0.2.1 ✓
```

Cloud DNS 给每个 zone 分配的权威服务器带**字母编号**（本 zone 是 c1–c4，见 `managed-zones describe` 的 `nameServers`）。`a1` 是别人 zone 的服务器，不认识你的域名，只会返回空。**查权威答案前先 describe 拿到自己 zone 的那组名字。**

### 坑 2：设了 http_proxy 环境变量时，--resolve 被无视

```
curl --resolve static.cloudworkflowdone.com:443:136.82.37.171 https://...
curl: (56) CONNECT tunnel failed, response 503
```

失败原因**不是**服务挂了：shell 里 `http_proxy=127.0.0.1:3128`（squid），curl 把请求交给代理，**代理自己做 DNS 解析**（拿到 192.0.2.1）然后连黑洞。`--resolve` 只管 curl 自己的解析，管不了代理的。

**正确姿势：`--noproxy '*'` 和 `--resolve` 必须一起上**，才能验证"服务没坏、只是 DNS 指错"：

```bash
curl --noproxy '*' --resolve static.cloudworkflowdone.com:443:136.82.37.171 \
  https://static.cloudworkflowdone.com/ -o /dev/null -w "%{http_code}\n"
# 预期 200 ← 服务和证书都活着，死的只是导航
```

### 命中预期的观察

- 事务提交后 SOA 序列号自动 1→2（Cloud DNS 每次变更都会 bump，供从服务器同步）。
- 传播比预想快：本地 resolver、8.8.8.8、1.1.1.1 几分钟内全部变成 `192.0.2.1`（这些 resolver 没有旧缓存，TTL 300 没挡路）。
- 走 squid 的 curl 返回 503 + `X-Squid-Error: ERR_CONNECT_FAIL 110`——剥开代理的包装，本质就是"连接 192.0.2.1 超时"，DNS 类故障的"超时不是 5xx"指纹成立。

## 一句话带走

- 子域走 NS 委派后，**A 记录归 Cloud DNS 管，Cloudflare 只管指路**。
- DNS 类故障的指纹是**连接超时 / NXDOMAIN**，不是 5xx；且 Cloudflare 无感知。
- 判断 DNS 生效看**权威 NS**，判断服务活着用**不带 --resolve 的 curl**。
- 有代理环境变量时，**--resolve 必须配 --noproxy '*'**，否则解析权在代理手里。
