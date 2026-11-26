# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html).

## [0.1.3] - 2026-11-26

### Changed
- **完整 apply 到快照 `snap-2026-11-26T16-09`**（与 ci.yml 中 mihomo v1.19.33 同版本构建），apply 后 `check` 零差异（幂等）。
  - **AD-Site** `316,103 → 322,872`（+6,769，上游 Sakura 新增仿冒域）；**AI-Site** `222 → 224`（+`elevenlabsusercontent.com`、`+gemma.ai`）；**Crypto** `212 → 208`（顺带剔除 5 条退化的 `domain-keyword`）。
  - **接入三个新规则集**：`IntlAcademic-Site`（465 条，89 精确 + 376 后缀）、**PlayStation-Site**、**Spotify-Site**（均为上游 Sakura 独有，上游 A 无此目录）。
  - **差异判定修复**：`diff_report` 对「旧产物有、本轮未构建」退回 `SKIP`，不再把「还没轮到」误判为 `-100% = BLOCK`。

## [0.1.2] - 2026-11-12

对齐已发布的流水线版本。规则集产物与 `mihomo-apply@v0.1.2` 同版，
README badge 指向 `mihomo-apply/tags`（产品版本由发布仓决定，本仓
只承载构建逻辑与镜像产物）。

本版之前的 `package.json` 与 CHANGELOG 停在 0.1.0，而 badge 已是 0.1.2，
`version-check` 因此在 CI 第 4 步失败，导致其后 8 项检查全部被跳过
（含规则集完整性与快照构建）。此条目补齐版本链。

### Added

- **Crypto / PayPal 生成 `mrs`** — `build-rules.sh` 产出 `Crypto.mrs` /
  `PayPal.mrs`。`mrs` 不支持 `DOMAIN-KEYWORD`，因此把 14 条 keyword
  规则内联进模板的 `rules:` 段。

### Fixed

- **`riskgrade` 内联** — 去掉未入库的 Go 依赖，改用内置实现。
  修复重复定义，并兼容 `-v` 参数。
- **CI 快照构建** — 补齐 mihomo 安装步骤；移除引用已迁走文件的步骤。

### Changed

- 文档引用随 `mihomo-template` 拆分迁出，`loadRegistry` 允许 `refs` 为空。
- README 按 Readme Harness 骨架重写。

## [0.1.0] - 2026-11-12

首次发布。四仓架构的第一环：规则集构建流水线。

### Added

- **构建流水线** — `build-rules.sh`，拉取上游、合并多源规则集、
  按策略筛选、报告变更。

  支持分阶段构建：`site`（域名）/ `geoip`（IP）/ `crypto` / `paypal`。
  `check` 模式构建到临时目录并与现有产物比对，不写工作区。

- **19 个域名规则集 + 3 个 IP 规则集** — 全部镜像在 `ruleset/` 下。
  AD-Site 为多源合并（316,103 条），AI-Site 为多源合并 + 剔除通用 SaaS 依赖（222 条）。

- **上游快照存档** — `tools/snapshot.sh`，自包含，只依赖环境变量。

  ```
  fetch / diff / pack / publish / prune
  ```

  拉取 29 个上游文件，计算 sha256，打包成 Release 资产。
  保留策略：7 天内全留 / 7–30 天每天 1 份 / 30 天以上每周 1 份。
  实测单次 3 MB，按此策略年体积约 188 MB。

- **审核日志** — `build-rules.sh` 的 `diff_report()` 写入
  `review/decisions.jsonl`（JSONL，一行一条变更）。无变更时不写。

- **版本契约校验** — `tools/check-version-contract.mjs`。

  检查模板内所有 rule-provider URL 是否使用同一个 ref，并与
  `misub-lock` 锁定的 commit 比对。占位符形态（`{{RULES_VERSION}}`）
  跳过比对，因为它在发布时才被替换。

- **规则集重叠契约** — `tools/check-overlap.py`。两两求交集，
  与 `ruleset/precedence.yaml` 的 `allowed_overlap` 比对。
  未声明的重叠阻断构建，声明了但无重叠的给出警告。

- **架构文档** — `docs/ARCH-00` 至 `ARCH-06`，记录六池设计。
  后经工程审计修正为三仓方向（见 ARCH-00 的审计结论）。

### Design decisions

- **上游地址通过环境变量注入** — `SRC_RULES` / `SRC_SAKURA` /
  `SRC_UPSTREAM_C` 没有默认值，未设置则构建失败。

  本地记录在 `.env.local` 与 `UPSTREAM-LOCAL.md`（均 gitignore）；
  可提交的模板是 `.env.example`。

- **产物头部不写上游身份** — `Crypto.txt` / `PayPal.txt` /
  `PayPal-Phish.txt` 的头部只写「从上游规则集筛选」，不写来源名与地址。

- **规则集产物必须入库** — 模板通过 URL 引用它们，忽略会导致
  订阅里每个 provider 全部 404。

### Verification

- 78 项单元测试
- 14 条文档源码引用断言
- 25 组规则集重叠全部已声明
- 版本一致性、AGENTS.md 漂移、模板/规则集版本契约

## License

MIT
