# 练习 3 · 破坏 2：关掉 Cloud CDN，`age:` 还在吗？

## 一句话结论

**`age:` 不是 Cloud CDN 的身份证。它来自 GCS（Cloud Storage）自己的全球边缘缓存，跟 Cloud CDN 开没开无关。**

那 Cloud CDN 命中怎么判？关键前提：**Cloud CDN 默认不吐任何缓存状态头**。

- `X-Cache` 是 squid / CloudFront 的惯例，Cloud CDN 不发；
- `Via: 1.1 google` 只表示请求经过了 Google 前端(GFE)，命中、未命中、没开缓存都会带，不能当命中证据。

权威判据只有三条：

1. **自定义响应头** `{cdn_cache_status}`（= hit / miss），需在 backend 上显式配置。
2. **Cloud CDN logging**：`httpRequest.cacheHit` + `jsonPayload.cacheId`。
3. **Cloud Monitoring** 指标 `loadbalancing.googleapis.com/https/request_count` 的 `cache_result` 标签。

本实验能下「CDN 没干活」的结论，依据是 `enableCdn=False` 这个**配置事实**，不是 X-Cache 有没有出现。

---

## 要验证的问题

练习 3 全程看到响应带 `age:` 头。一开始以为是 Cloud CDN 在缓存。但关掉 CDN 之后 `age:` 仍然出现，引发疑问：`age:` 到底是不是 Cloud CDN 的身份证？

---

## 实验 B（CDN 关掉后测）

```bash
gcloud compute backend-buckets update static-site-backend \
  --no-enable-cdn --project=lukechengtest
# => Updated [...]

gcloud compute backend-buckets describe static-site-backend \
  --format='value(enableCdn)' --project=lukechengtest
# => False   ← 确认 CDN 真的关了

sleep 300   # 等 5 分钟让开关真正生效（别没生效就下结论）
```

上传新对象 `cdnB.txt`，连续 6 次 `curl --noproxy '*' --resolve ...` 抓**完整**响应头（这次不打 grep，免得漏掉关键头）。

### 关键证据

| 请求 | age | x-guploader-uploadid | server |
|------|-----|----------------------|--------|
| B1 | — | 新 (AFy3sg02…) | UploadServer |
| B2 | — | 新 (AFy3sg0R6…) | UploadServer |
| B3 | 4 | 同 B2 (AFy3sg0R6…) | UploadServer |
| B4 | 7 | 同 B2 (AFy3sg0R6…) | UploadServer |
| B5 | — | 新 (AFy3sg09t…) | UploadServer |
| B6 | 19 | 同 B1 (AFy3sg02…) | UploadServer |

**铁证三条：**

1. `enableCdn=False` 确认了，CDN 关着，但 `age: 4 / 7 / 19` 照样出现 → `age` 与 Cloud CDN 开关无关。
2. 每条响应都是 `server: UploadServer` + 带 `x-guploader-uploadid`。这两个是 **GCS 源站直吐**的标志。Cloud CDN 命中是从自己的缓存回，不会再去 GCS 源站，也就不会有 uploadid。
3. 「Cloud CDN 没干活」的依据是 `enableCdn=False` 这个配置事实；请求里没有 `X-Cache` 是 Cloud CDN 的默认行为（它本就不发 X-Cache），不能反过来拿 X-Cache 缺失当 CDN 状态证据。

### 为什么 B3/B4/B6 有 age、B1/B2/B5 没有？

看 uploadid：

- 第一次落到某个边缘 POP，POP 没有缓存 → 回 GCS 取（新 uploadid，无 age）；
- 同一 POP 后续请求 → 直接吐本地缓存副本（uploadid 不变，age 从 4 涨到 7、涨到 19）。

这就是 GCS 自己的边缘缓存在按 POP 各自生效，跟 Cloud CDN 没关系。

---

## 实验 A 复盘（为什么一度以为 CDN 是开的）

实验 A 跑 `--enable-cdn` 时返回 `No change requested`，说明当时配置位 `enableCdn` 已经是 True。但即使那样，响应里依然**没有 `X-Cache` / `Via`**，只有 `age`。

结合实验 B 的证明（`age` 是 GCS 边缘缓存给的），"配置位 True"并不等于"CDN 真在缓存这条路径"。真正判断 CDN 是否命中，用 `{cdn_cache_status}` 自定义头 / CDN logging / `cache_result` 指标这三条权威判据，别拿 `age` 或 `X-Cache` 的缺失下结论。

---

## 纠错记录

- 之前我说过"CDN 关着还出现 `age` 不可能 / 说明 CDN 其实没关"。**这句话是错的，收回。** 实验 B 证明：CDN 关着，`age` 照样有，因为它来自 GCS 边缘缓存。
- 用户一开始的直觉"我一直没开 CDN"是对的；之前看到的 `age` 从头到尾都是 GCS 边缘缓存，不是 Cloud CDN。

---

## 一句话带走

- 想确认 Cloud CDN 有没有命中 → 配 `{cdn_cache_status}` 自定义头 / 开 CDN logging / 看 `cache_result` 指标（三选一）。
- Cloud CDN 默认不发 `X-Cache`；`Via: 1.1 google` 只表示经过 GFE，都不是命中证据。
- 看到 `age:` 别激动，GCS 自己也会加，不能拿它证明 CDN 开关状态。
- 验证前一定等开关真正生效（本次等了 5 分钟），没生效就下结论会自己绕进去。
