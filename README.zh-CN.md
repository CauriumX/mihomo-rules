# mihomo-rules

> 规则集构建流水线：拉取上游、合并多源、按声明的策略筛选，发布前校验每一处改动。
> 由 [Readme Harness](https://github.com/Guislabert/readme-harness) 生成。

<div align="center">

[![CI](https://img.shields.io/badge/CI-passing-34A853.svg)][ci]
[![版本](https://img.shields.io/badge/版本-0.1.0-4285F4.svg)][vlg]
[![License: MIT](https://img.shields.io/badge/License%3A%20MIT-FBBC05.svg)][osi]

</div>

## 为什么

分流配置如果直接指向第三方规则集托管方，就等于继承了它们的可用性、它们的审查决定，以及它们不声不响的改动。其中任何一个下线或重排列表，所有客户端一起失效 —— 而配置本身不会告诉你发生了什么。

本流水线把它用到的每份规则集镜像下来，按声明的策略合并多源规则集，剔除不属于该分类的条目，并在应用前报告每一处改动。

## 是什么

- **19 个域名规则集** 与 **3 个 IP 规则集**，由 29 个上游文件构建
- **多源合并** —— AD-Site 合并两个上游（316,103 条），AI-Site 合并后剔除 15 条通用 SaaS 依赖（222 条）
- **构建脚本** —— 拉取、转换、筛选，并与已提交的产物比对
- **校验工具** —— 单元测试、规则集重叠契约、文档源码引用断言、模板与规则集版本契约

上游地址通过环境变量注入，从不提交。本地记录保存在 `.env.local` 与 `UPSTREAM-LOCAL.md`，两者均已 git-ignore。上游原始快照存在独立的私有仓库。

## 快速开始

```sh
# 1. 配置上游地址（不会提交）
cp .env.example .env.local
# 编辑 .env.local，填入真实上游地址

# 2. 检查上游是否有变更，不修改工作区
set -a && . ./.env.local && set +a
bash build-rules.sh check

# 3. 变更报告确认无误后应用
bash build-rules.sh apply
```

只构建某一类：

```sh
bash build-rules.sh site     # 域名规则集
bash build-rules.sh geoip    # IP 规则集
bash build-rules.sh crypto   # Crypto
bash build-rules.sh paypal   # PayPal
```

### 从快照构建

设置 `SNAPSHOT_DIR` 时，流水线从本地快照目录读取，不访问网络 —— 这是 CI 复现构建的路径。

```sh
SNAPSHOT_DIR=/path/to/snapshot bash build-rules.sh check
```

快照布局为 `a/`（主上游）、`b/`（第二上游）、`c/`（Crypto / PayPal），由私有快照仓库产出。

### 上游快照

```sh
bash tools/snapshot.sh fetch     # 拉取全部上游到 tools/work/
bash tools/snapshot.sh diff      # 与上一次快照比对
bash tools/snapshot.sh pack      # 生成 snapshots.tar.gz + MANIFEST.json
bash tools/snapshot.sh publish   # 创建 GitHub Release
bash tools/snapshot.sh prune     # 按保留策略清理
```

保留策略：7 天内全留，7–30 天每天 1 份，30 天以上每周 1 份。

## 目录

```
build-rules.sh            构建流水线（拉取、转换、筛选、比对）
ruleset/
  site/*.mrs              19 个域名规则集
  geoip/*.mrs             3 个 IP 规则集
  Crypto.mrs              加密 / 交易所
  PayPal.txt              官方域名
  PayPal-Phish.txt        钓鱼域名
  SOURCES.md              来源登记
  precedence.yaml         优先级与重叠声明
filters/                  保留 / 剔除清单
tools/                    校验与构建工具
docs/                     架构文档
```

## 校验

```sh
npm test                          # 单元测试
npm run check:version             # 模板 ↔ 规则集版本契约
npm run check:refs                # 文档源码引用断言
npm run check:agents              # AGENTS.md 漂移
python3 tools/check-overlap.py    # 规则集重叠声明
```

版本契约存在的原因：模板与它引用的规则集必须同版本发布。模板锁在一个 commit 而规则集在 `@main` 上漂移，是一种静默的不兼容；校验会让构建失败，而不是让它悄悄上线。

## 架构

- [架构总览](docs/ARCH-00-overview.md)

四个仓库，每个单一职责：

| 仓库 | 可见性 | 职责 |
|---|---|---|
| `mihomo-upstream` | 私有 | 拉取并归档上游快照 |
| `mihomo-rules` | 公开 | 合并、筛选、校验 —— 本仓库 |
| `mihomo-template` | 公开 | 订阅模板源 |
| `mihomo-apply` | 公开 | 版本化发布，模板与规则集同版本 |
| `mihomo-distribute` | 私有 | 消费端版本管理（持有凭证） |

## 采纳 / 贡献

上游地址是环境变量，不是常量。不要提交它们，也不要加一个内嵌真实地址的默认值。

新增规则集必须在 `ruleset/SOURCES.md` 登记来源与交集率之后才能合并。体量变化超过 30% 的改动需要人工确认 —— 构建会报告 `BLOCK`，未经确认拒绝应用。

规则集产物必须入库，因为发布仓通过 URL 引用它们。忽略它们会让订阅里的每个 provider 全部 404。

## License

MIT © Guislabert

[ci]: https://github.com/CauriumX/mihomo-rules/actions
[vlg]: CHANGELOG.md
[osi]: https://opensource.org/licenses/MIT
