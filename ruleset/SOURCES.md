# 规则集来源登记

本文件记录每个规则集的实际来源、体量与已知风险。
`build-rules.sh` 用它做来源校验；README 用它生成说明。

> **地址脱敏**：上游的具体 URL 通过环境变量注入，不在仓库中公开。
> 本地完整记录见 `UPSTREAM-LOCAL.md`（gitignore）。

**为什么需要这个文件**：审计发现 19 个 `.mrs` 的上游地址无法追溯 ——
`SRC_RULES` 没有默认值，README 用占位符。任何人 clone 后都无法验证
现有产物是否来自同一上游，也无法判断上游更新后产物是否合理。

---

## 上游总览

| 上游 | 许可 | 用途 | 状态 |
|---|---|---|---|
| 上游 A（GitHub） | MIT | 17 个域名规则集 + 2 个 IP 规则集 | ✅ 已确认 |
| 上游 B（HTTP） | 未声明 | AD-Site 补仿冒域 + AI-Site 主体 | ✅ 已确认 |
| 上游 C（GitHub） | MIT | Crypto / PayPal | ✅ 已确认 |
| 本地生成 | — | Local-IP（IANA 私有网段） | ✅ 无需上游 |

**来源确认方法**：内容比对。下载上游同名规则集，与本地解码结果求交集。

| 本地 | 上游 | 交集率 | 说明 |
|---|---|---|---|
| Google-Site | Google | 93.0% | 本地含上游未收录的广告子域 |
| Meta-Site | Facebook | 97.1% | 目录名是 Facebook，非 Meta |
| AD-Site | Advertising | 85.9% | 本地为旧快照，上游已删 25,699 条 |
| 其余 16 个 | 同名目录 | — | HTTP 200 可达 |

---

## 体量分布

```
AD-Site        316,103  ████████████████████████████████████████ 97.5%
China-Site       3,691  ▏1.1%
Apple-Site       1,559  ▏0.5%
Google-Site        690  ▏0.2%
Microsoft-Site     667  ▏0.2%
Meta-Site          546  ▏0.2%
AI-Site            222  ▏0.1%
其余 12 个           630  ▏0.2%
```

**AD-Site 占 97.5%** —— 31.6 万条 domain trie 常驻内存。
这是当前最大的性能开销，也是最大的误伤风险面。

> 2026-11-12 合并 上游 B 后数据。合并前为 290,392 条。
> 内存实测：合并前 43,204 kB → 合并后 43,732 kB（+528 kB），
> 因为新增的 25,711 条大量是 `*.mlcrosoft.vip` 同后缀仿冒域，trie 节点复用。

---

## 逐项登记

### AD-Site

| 项 | 值 |
|---|---|
| 上游 | 上游 A → `Advertising/Advertising_Domain_For_Clash.txt`<br>+ 上游 B → `AD/AD-Site.mrs`（合并） |
| 上游 A 体量 | 291,159 条（含 DOMAIN / SUFFIX / KEYWORD / IP-CIDR） |
| 上游 B 体量 | 181,665 条 |
| 本地体量 | **316,103 条**（合并去重后，仅 domain 类） |
| 交集 | 155,954 条 |
| 上游更新时间 | 上游 A: 2026-10-28 05:39 / 上游 B: 2026-11-12 02:14 |

**为何用 `_Domain_For_Clash.txt` 而非 `Advertising.yaml`**：
`Advertising.yaml` 只有 778 行（声明 TOTAL=291159），完整域名列表在
`Advertising_Domain_For_Clash.txt`。用 `.yaml` 会静默丢掉 99.9% 的规则。

#### 为何合并而非换源（2026-11-12）

上游 B 那份含 25,711 条 上游 A 没有的仿冒域（`*.mlcrosoft.vip` 等），
但比 上游 A 少 108,727 条。两者只交集 155,954 条，**不是同源**。

实测内存（mihomo v1.19.2，仅加载 AD-Site）：

| 方案 | 条数 | `.mrs` | VmRSS |
|---|---:|---:|---:|
| 基线（无规则集） | 0 | — | 25,932 kB |
| 上游 A | 290,392 | 2,176,858 B | 43,204 kB |
| 上游 B | 181,665 | 1,498,713 B | 36,304 kB |
| **合并** | **316,103** | **2,368,584 B** | **43,732 kB** |

**合并只多 528 kB（+1.2%）** —— domain trie 共享后缀，25,711 条新增里
大量是 `*.mlcrosoft.vip` 这类同后缀仿冒域，节点复用。
换源能省 6.9 MB 但少拦 108,727 个广告域，不划算。

**已知风险**：

1. **体量**：占全部规则量 97.4%（316,103 / 324,515）。每次 DNS 解析都要查这棵 trie。
2. **误伤面**：31 万条中大量是「两段短域名且不含广告关键词」，
   无法仅凭域名判断是否为广告域。抽样未发现主流业务域被误收，
   但样本有限。
3. **含仿冒域名**：形如 `*.mlcrosoft.vip` 的品牌仿冒域，
   属于钓鱼而非广告，放在 AD 组里 REJECT 结果正确，但分类不准确。

**建议**：拆分核心 / 长尾（见审计报告 D3）。

---

### China-Site

| 项 | 值 |
|---|---|
| 上游 | 上游 A → `China/China.yaml` |
| 本地体量 | 3,691 条 |
| 与 Bilibili-Site 交集 | 36 条（有意：B 站单独分流） |
| 与 AD-Site 交集 | 143 条（有意：广告优先拦截） |

---

### AI-Site

| 项 | 值 |
|---|---|
| 上游 | 上游 B → `AI/AI-Site.mrs`（主体 217 条）<br>+ `上游 A` 补漏（6 条） |
| 本地体量 | **222 条** |
| 剔除 | 1 条（`browser-intake-datadoghq.com`，见下） |
| 上游更新时间 | 上游 B: 2026-11-12 02:14 / 上游 A: 2025-06-06 09:20 |

#### 为何从 51 条扩到 222 条（2026-11-12）

上游 A 的 AI 目录停在 2025-06-06，只有 51 条，且**不含**主流 AI 服务。
上游 B 那份是自编的 217 条，覆盖面完全不同：

| 类别 | 上游 B 有 | 上游 A |
|---|---|---|
| Perplexity | `perplexity.ai` `pplx.ai` `perplexity.com` | ❌ |
| Grok / xAI | `grok.com` `grok.x.com` `x.ai` `grokipedia.com` | ❌ |
| Cursor | `cursor.com` `cursor.sh` `cursorapi.com` `cursorvm.com` | ❌ |
| Windsurf / Codeium | `windsurf.com` `windsurf.build` `codeium.com` | ❌ |
| Midjourney | `midjourney.com` | ❌ |
| Kimi / Moonshot | `kimi.ai` `moonshot.ai` | ❌ |
| Manus | `manus.im` `manuscdn.com` | ❌ |
| Cerebras / Groq / Mistral / Cohere | 全有 | ❌ |
| Devin / Jules / Trae / Qoder / Kiro | 全有 | ❌ |
| ElevenLabs / HuggingFace / Ollama | 全有 | ❌ |
| Google AI 全家桶 | `ai.studio` `notebooklm.*` `jules.google` `antigravity.*` … | 仅 4 条 |
| Claude 全家桶 | `claude.com` `claude.app` `claude.dev` `claude.site` … | 仅 `claude.ai` |
| Copilot 系 | `copilot.com` `copilot.microsoft.com` `githubcopilot.com` | ❌ |

两份交集仅 26 条，**不是同源**。

#### 合并策略

```
上游 B 217 条  +  上游 A 补漏 6 条  =  223 条
223 条  −  剔除 1 条  =  222 条
```

补漏清单见 `filters/ai-keep.txt`（6 条，与 上游 B 零重合）：

```
ai.com  civitai.com  apis.google.com
openai-api.arkoselabs.com  client-api.arkoselabs.com
chat.openai.com.cdn.cloudflare.net
```

#### 剔除的通用 SaaS 依赖

上游 A 的 51 条里混入了 15 条全互联网共用的依赖：

```
stripe.com  sentry.io  segment.io  auth0.com  intercom.io
launchdarkly.com  algolia.net  identrust.com  api.statsig.com
cdn.usefathom.com  events.statsigapi.net  featuregates.org
intercomcdn.com  observeit.net  static.cloudflareinsights.com
```

这些塞进 🤖AI 组会把无关流量拽进 AI 节点（例：访问任意 Stripe 支付页
都走 AI 节点）。清单见 `filters/ai-drop-saas.yaml`。

**实测**：上游 B 那份本来就不含这 15 条，所以剔除只命中 1 条
（`browser-intake-datadoghq.com`，上游 B 也有）。清单保留作为防护，
防止将来上游把 SaaS 依赖加回来。

#### KEYWORD 规则在 mrs 中的退化（已删除）

上游 A 原文有 4 条 `DOMAIN-KEYWORD`：

```yaml
- DOMAIN-KEYWORD,colab
- DOMAIN-KEYWORD,developerprofiles
- DOMAIN-KEYWORD,generativelanguage
- DOMAIN-KEYWORD,openai
```

但 **mihomo 的 mrs `domain` 格式只支持 exact 和 suffix，不支持 keyword**。
`convert_to_mrs` 剥掉类型前缀后，它们退化为 exact 匹配：

```
DOMAIN-KEYWORD,colab  →  colab  →  mrs 里只匹配域名恰好等于 "colab"
```

实测往返验证：输入 `colab`，mrs 编码再解码仍是 `colab`，语义已丢失。

**影响**：`colab.research.google.com` 匹配不上 🤖AI 组。但它已被
`rules:` 段的 `DOMAIN-SUFFIX,googleapis.com,🔍Google`（L835）覆盖，
走 🔍Google 组 —— 这是 2026-11-12 确认的预期行为（方案 A）。

**处理方式（2026-11-12）：删除。**

这 4 条已从 `filters/ai-keep.txt` 移除，AI-Site 从 226 条降至 222 条。

删除依据：

1. **目标域已被其它规则覆盖**
   - `colab.research.google.com` / `generativelanguage.googleapis.com`
     → `DOMAIN-SUFFIX,googleapis.com,🔍Google`
   - `openai.com` → 上游 B 的 `+.openai.com` / `+.openai.org`
   - `developerprofiles` 的目标域也在 `googleapis.com` 下
2. **留着是假的安全感** —— 看起来有规则，实际匹配不到任何真实域名

> 如果将来确实需要 keyword 语义，不能靠 mrs。
> 可选方案：在模板 `rules:` 段写内联 `DOMAIN-KEYWORD,xxx,🤖AI`，
> 或者改用 `behavior: classical` 的 rule-provider（支持完整规则类型）。

#### 已探测但不存在的 上游 A 目录

| 目录 | 状态 |
|---|---|
| `ChatGPT` | 404（内容已并入 `OpenAI`） |
| `Perplexity` | 404（上游 B 有） |
| `Grok` | 404（上游 B 有） |
| `DeepSeek` | 404（`deepwiki.com` 由 上游 B 覆盖） |
| `Midjourney` | 404（上游 B 有） |
| `Sora` | 404（上游 B 有 `sora.com`） |
| `Copilot` | 200，51 条（上游 B 已覆盖，不再需要） |

#### 已知盲区

| 服务 | 当前命中 | 说明 |
|---|---|---|
| DeepSeek 主站 | `China-Site`（国内域） | 国内直连，符合预期 |
| Google AI 服务 | `🔍Google`（`googleapis.com` 的 SUFFIX 在 AI-Site 之前） | 2026-11-12 确认的方案 A |

---

### Meta-Site

| 项 | 值 |
|---|---|
| 上游 | 上游 A → `Facebook/Facebook.yaml` |
| 本地体量 | 546 条 |
| 交集 | 539 条（97.1%，同步前） |

**注意**：上游目录名是 `Facebook`，不是 `Meta`。改名时需同步
`build-rules.sh` 的映射表。

---

### Crypto

| 项 | 值 |
|---|---|
| 上游 | 上游 C → `Crypto.txt` |
| 上游体量 | 417 条（含 205 条 PayPal 污染） |
| 本地体量 | 212 条 |
| 变换 | 集合差：减去 `上游 C/PayPal.txt` 全部条目 |

**污染现状**（2026-11-08 上游）：仍是 417 条，其中 205 条与 PayPal.txt 重复。
上游未修复，本地剔除逻辑仍必要。

---

### PayPal

| 项 | 值 |
|---|---|
| 上游 | 上游 C → `PayPal.txt` |
| 上游体量 | 206 条（官方 + 钓鱼混在一起） |
| 本地体量 | 191 条（官方） |
| 变换 | 按 `filters/paypal.yaml` 分三档 |

**上游缺陷**：官方域名与钓鱼域名同表。`filters/paypal.yaml` 做分离。

---

### PayPal-Phish

| 项 | 值 |
|---|---|
| 来源 | 从 `PayPal.txt` 分离 |
| 本地体量 | 15 条 |
| 去向 | 内联进模板 `rules:` 段（`REJECT`），不走 provider |

---

### Local-IP

| 项 | 值 |
|---|---|
| 来源 | 本地生成（IANA 私有网段） |
| 本地体量 | 17 条 |
| 说明 | 不依赖上游。上游合集常变动，但私有网段是固定分配。 |

---

### China-IP / Telegram-IP

| 项 | 值 |
|---|---|
| 上游 | `ChinaIPs/ChinaIPs_IP.txt` / `Telegram/Telegram.yaml` |
| 本地体量 | 11,775 / 10 条 |
| 说明 | 与上游当前版本部分重合（版本差异），本地为旧快照 |

**注意**：MiSub 靠 URL 路径里的 `/geoip/` 判定 `ipcidr`，
这三个必须放在 `ruleset/geoip/` 下，否则误判 `domain` 导致
运行期 `ErrInvalidFormat`。

---

## 维护约定

1. **新增规则集**必须先在此登记来源与交集率
2. **上游变更**后重跑 `bash build-rules.sh check`，看 diff 再决定是否 `apply`
3. **体量变化超过 5%** 需要在本文件更新体量分布
4. **来源无法确认**的规则集不得入库
