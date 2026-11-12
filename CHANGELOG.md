# Changelog

All notable changes to this project are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [SemVer 2.0.0](https://semver.org/spec/v2.0.0.html).

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
