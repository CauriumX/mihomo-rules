#!/usr/bin/env bash
# ============================================================================
# build-rules.sh — 规则镜像 / 筛选 / 构建流水线
#
# 设计目标：
#   1. 从上游拉取原始规则集
#   2. 按白名单/黑名单做筛选（剔除不属于该分类的条目）
#   3. 输出到 ruleset/ 目录，供模板引用
#   4. 全程可重复执行，结果确定（幂等）
#
# 用法：
#   bash build-rules.sh              # 全量构建
#   bash build-rules.sh crypto       # 只构建 Crypto
#   bash build-rules.sh --verify     # 只校验，不下载
#
# 目录结构（构建产物）：
#   ruleset/
#   ├── Crypto.mrs / Crypto.txt      ← 筛选后的纯加密规则
#   ├── geoip/
#   │   ├── China-IP.mrs
#   │   ├── Local-IP.mrs
#   │   └── Telegram-IP.mrs
#   └── upstream/                    ← 上游原始快照（用于 diff 审计）
#       ├── Crypto.raw.txt
#       └── PayPal.raw.txt
# ============================================================================
set -euo pipefail

# 规则集上游源（域名类 + IP 类）
#
# 默认值已内置（上游 A，MIT 许可）。
# 需要换源时用环境变量覆盖：
#
#   export SRC_RULES="https://your-upstream.example.com"
#   bash build-rules.sh all
#
# 地址结构要求（与 上游 A 一致）：
#   $SRC_RULES/<Category>/<Name>.yaml
#   例：$SRC_RULES/Google/Google.yaml
#
# 来源确认依据（2026-11-07 实测）：
#   Google-Site  ← Google    交集 93.0%
#   Meta-Site    ← Facebook  交集 97.1%
#   AD-Site      ← Advertising 交集 85.9%（本地为旧快照）
#   其余 16 个   ← 同名目录，HTTP 200 可达
# 快照模式：设置 SNAPSHOT_DIR 时从本地快照读取，不访问网络。
#
# 快照由 mihomo-upstream 私有仓的 CI 产出，解包后是：
#   $SNAPSHOT_DIR/a/   主上游（25 个文件）
#   $SNAPSHOT_DIR/b/   第二上游（2 个文件）
#   $SNAPSHOT_DIR/c/   Crypto / PayPal（2 个文件）
#
# 设置后 SRC_* 变量不再必需 —— 这是 CI 复现构建的路径。
SNAPSHOT_DIR="${SNAPSHOT_DIR:-}"

if [ -n "$SNAPSHOT_DIR" ]; then
    SRC_RULES=""
    SRC_SAKURA=""
    SRC_UPSTREAM_C=""
else
    SRC_RULES="${SRC_RULES:?未设置 SRC_RULES，见 .env.example 或本地 .env.local}"
fi

# 第二上游：上游 B（服务商自建规则集）
#
# 与 上游 A 的关系（2026-11-12 实测，19 个域名类规则集两两比对）：
#   Apple/Meta/Discord/Disney/Adobe/Google  重合 90%+  → 同源，无需切换
#   AD-Site                                 服务商更新更快（含 25,711 条仿冒域）
#   AI-Site                                 服务商自编（217 条 vs 我们 51 条）
#
# 路径结构：$SRC_SAKURA/<Category>/<Category>-Site.mrs
# 注意：服务商只提供 .mrs（已编码），不提供 上游 A 那种带类型前缀的 .yaml。
# 解码后是裸域名（suffix 带 +. 前缀），与 convert_to_mrs 的输入约定不同，
# 因此走独立的 fetch_sakura_mrs() 路径。
[ -n "$SNAPSHOT_DIR" ] || SRC_SAKURA="${SRC_SAKURA:?未设置 SRC_SAKURA，见 .env.example 或本地 .env.local}"

require_src_rules() {
    # 快照模式不需要网络地址
    [ -n "$SNAPSHOT_DIR" ] && return 0
    if [ -z "$SRC_RULES" ]; then
        printf '\033[31m错误\033[0m SRC_RULES 为空\n\n' >&2
        printf '本脚本需要规则集上游地址才能拉取。用法：\n\n' >&2
        printf '  bash build-rules.sh all\n\n' >&2
        printf '或显式覆盖：\n\n' >&2
        printf '  export SRC_RULES="https://your-upstream.example.com"\n' >&2
        exit 1
    fi
}
[ -n "$SNAPSHOT_DIR" ] || SRC_UPSTREAM_C="${SRC_UPSTREAM_C:?未设置 SRC_UPSTREAM_C，见 .env.example 或本地 .env.local}"

# 产物目录。check 模式下指向临时目录，不污染工作区。
DEST="${DEST_OVERRIDE:-ruleset}"
UPSTREAM="$DEST/upstream"
TARGET="${1:-}"

# check 模式：先构建到临时目录，再与现有产物 diff，不写入。
# apply 模式：直接构建到 ruleset/。
MODE="${MODE:-apply}"

mkdir -p "$DEST" "$DEST/geoip" "$UPSTREAM"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# riskgrade —— 变更分级
#
# 输出格式（tab 分隔，6 字段）：
#   risk  <ignored>  <ignored>  delta  pct  note
#
# 分级阈值（唯一实现，不要再在别处重算）：
#   两边都为空        → none
#   旧为 0 且新 > 0   → info，note=new
#   变化幅度 > 30%    → BLOCK
#   变化幅度 > 5%     → warn
#   其余              → info
#
# 历史：曾依赖仓库外的 Go 项目（../ruleset-diff 的 cmd/riskgrade）。
# 那是未入库的外部依赖，CI 里必然失败。逻辑本身只有阈值判断，
# 内联成 shell 更可靠。
riskgrade() {
    # 兼容旧调用签名：riskgrade -v <old> <new>
    # -v 原本控制是否输出详细信息，内联实现始终输出完整行，忽略该参数。
    [ "${1:-}" = "-v" ] && shift

    local old_n="${1:-0}" new_n="${2:-0}"

    if [ "$old_n" -eq 0 ] && [ "$new_n" -eq 0 ]; then
        printf 'none\t0\t0\t0\t0\tboth-empty\n'
        return 0
    fi

    local delta=$(( new_n - old_n ))
    local pct note=""

    if [ "$old_n" -eq 0 ]; then
        pct=100
        note="new"
    else
        pct=$(( delta * 100 / old_n ))
        [ "$pct" -lt 0 ] && pct=$(( -pct ))
    fi

    local risk
    if [ "$note" = "new" ]; then
        risk="info"
    elif [ "$pct" -gt 30 ]; then
        risk="BLOCK"
    elif [ "$pct" -gt 5 ]; then
        risk="warn"
    else
        risk="info"
    fi

    printf '%s\t0\t0\t%s\t%s\t%s\n' "$risk" "$delta" "$pct" "$note"
}

require_src_rules() {
    # 快照模式不需要网络地址
    [ -n "$SNAPSHOT_DIR" ] && return 0
    if [ -z "$SRC_RULES" ]; then
        printf '\033[31m错误\033[0m SRC_RULES 为空\n\n' >&2
        printf '本脚本需要规则集上游地址才能拉取。用法：\n\n' >&2
        printf '  bash build-rules.sh all\n\n' >&2
        printf '或显式覆盖：\n\n' >&2
        printf '  export SRC_RULES="https://your-upstream.example.com"\n' >&2
        exit 1
    fi
}
[ -n "$SNAPSHOT_DIR" ] || SRC_UPSTREAM_C="${SRC_UPSTREAM_C:?未设置 SRC_UPSTREAM_C，见 .env.example 或本地 .env.local}"

# 产物目录。check 模式下指向临时目录，不污染工作区。
DEST="${DEST_OVERRIDE:-ruleset}"
UPSTREAM="$DEST/upstream"
TARGET="${1:-}"

# check 模式：先构建到临时目录，再与现有产物 diff，不写入。
# apply 模式：直接构建到 ruleset/。
MODE="${MODE:-apply}"

mkdir -p "$DEST" "$DEST/geoip" "$UPSTREAM"

log() { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------------------
# riskgrade —— 分级逻辑的唯一实现
#
# 阈值定义在仓库外的 internal/risk（Go 包），build-rules.sh
# 通过 cmd/riskgrade 调用它。这样 shell 和桌面 app 不可能对「30% 算不算
# BLOCK」有两种答案。
#
# 查找顺序：
#   1. $RISKGRADE 环境变量显式指定
#   2. PATH 里的 riskgrade
#   3. 同级目录 ../ruleset-diff 存在时用 go run（开发环境）
#
# 找不到时 fail fast：宁可让 check 报错，也不要退回一份会漂移的实现。
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# 上游完整性校验
#
# 上游 A 的部分 .yaml 被截断：头部声明 TOTAL=291159，
# 实际只有 778 行。直接转换会静默丢掉 99.9% 的规则。
#
# 校验方式：对比「头部声明的域名类条数」与「实际可提取的域名类条数」。
#
# 注意：必须按类型分开比，不能用 TOTAL。
#   TOTAL 包含 IP-CIDR / PROCESS-NAME / IP-ASN 等，
#   而域名规则集只提取 DOMAIN* 三类。
#   例：Netflix 声明 TOTAL=1157，其中 1115 条是 IP-CIDR，
#   域名只有 38 条 —— 用 TOTAL 比会误判为截断。
#
# 无类型声明的文件（如 *_Domain_For_Clash.txt）跳过校验。
# ---------------------------------------------------------------------------
check_upstream_complete() {
    local f="$1" name="$2" behavior="${3:-domain}"

    python3 - "$f" "$name" "$behavior" <<'PY'
import re, sys

path, name, behavior = sys.argv[1:4]
text = open(path, encoding='utf-8', errors='ignore').read()

if behavior == 'domain':
    declared_types = ('DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD')
    keep = set(declared_types)
else:
    declared_types = ('IP-CIDR', 'IP-CIDR6')
    keep = set(declared_types)

# 头部声明：按类型求和（不是 TOTAL）
declared = 0
found_any = False
for t in declared_types:
    m = re.search(rf'^# {re.escape(t)}:\s*(\d+)\s*$', text, re.M)
    if m:
        declared += int(m.group(1))
        found_any = True

if not found_any:
    sys.exit(0)          # 无类型声明，跳过

# 实际可提取
actual = 0
for line in text.splitlines():
    line = line.strip()
    if line.startswith('- '):
        p = [x.strip() for x in line[2:].split(',')]
        if len(p) >= 2 and p[0] in keep:
            actual += 1
    elif line and not line.startswith('#') and not line.startswith('payload:'):
        actual += 1      # 纯文本格式

if declared == 0:
    sys.exit(0)

pct = actual / declared * 100
if pct < 90:
    print(f'  \033[31mFAIL\033[0m {name} 上游不完整：'
          f'声明 {declared} 条{behavior}类，实际 {actual} 条（{pct:.0f}%）',
          file=sys.stderr)
    print('         上游文件可能被截断，检查是否应改用 *_Domain_For_Clash.txt',
          file=sys.stderr)
    sys.exit(1)
PY
}

# ---------------------------------------------------------------------------
# 把上游 YAML / 纯文本规则集转换为 mihomo mrs
#
# 用法：convert_to_mrs <domain|ipcidr> <输入文件> <输出.mrs>
#
# mihomo 的 convert-ruleset 只接受纯规则文本（每行一条），
# 因此需要先把 上游 A 的 YAML（payload: 列表）拆成纯文本。
#
# 输入支持两种格式：
#   1. 上游 A YAML：payload: 下的 "  - DOMAIN-SUFFIX,example.com"
#   2. 纯文本：每行一条规则（已去注释）
# ---------------------------------------------------------------------------
convert_to_mrs() {
    local behavior="$1" src="$2" out="$3"
    local plain
    plain="$(mktemp)"

    if grep -q '^payload:' "$src" 2>/dev/null; then
        # 上游 A YAML → 纯规则文本
        # 只取 DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD（domain）
        # 或 IP-CIDR / IP-CIDR6（ipcidr），丢弃 PROCESS-NAME / IP-ASN 等
        python3 - "$src" "$plain" "$behavior" <<'PY'
import sys

src, dst, behavior = sys.argv[1:4]
keep = {
    'domain': {'DOMAIN', 'DOMAIN-SUFFIX', 'DOMAIN-KEYWORD'},
    'ipcidr': {'IP-CIDR', 'IP-CIDR6'},
}[behavior]

out = []
for line in open(src, encoding='utf-8', errors='ignore'):
    line = line.strip()
    if not line.startswith('- '):
        continue
    parts = [p.strip() for p in line[2:].split(',')]
    if len(parts) < 2:
        continue
    rtype, value = parts[0], parts[1]
    if rtype not in keep:
        continue
    # mihomo convert-ruleset 只需值，不要类型前缀
    out.append(value)

with open(dst, 'w', encoding='utf-8', newline='\n') as f:
    for v in out:
        f.write(v + '\n')
PY
    else
        # 纯文本：去掉注释与空行
        grep -v '^#' "$src" | grep -v '^[[:space:]]*$' > "$plain" || true
    fi

    if [ ! -s "$plain" ]; then
        bad "convert_to_mrs: 输入为空（$src）"
        rm -f "$plain"
        return 1
    fi

    if ! command -v mihomo >/dev/null 2>&1; then
        bad "convert_to_mrs: 未找到 mihomo 命令"
        printf '         安装：https://github.com/MetaCubeX/mihomo/releases\n' >&2
        rm -f "$plain"
        return 1
    fi

    mihomo convert-ruleset "$behavior" text "$plain" "$out" 2>/dev/null
    local rc=$?
    rm -f "$plain"

    if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
        bad "convert_to_mrs: mihomo 转换失败（$src）"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 从 上游 B 拉取并解码 .mrs 为纯域名文本
#
# 用法：fetch_sakura_mrs <Category> <输出文本>
#   例：fetch_sakura_mrs AI /tmp/ai.txt
#
# 与 上游 A 路径的三点差异：
#   1. 只有 .mrs（无 .yaml），必须用 mihomo 解码
#   2. 解码后是裸域名，suffix 带 "+." 前缀（mihomo 的 suffix 标记）
#   3. 无 # NAME / # UPDATED / # TOTAL 头，check_upstream_complete 不适用
#      替代校验：解码后条数 ≥ 1，且不含 "+." 以外的异常字符
#
# 输出统一为裸域名（去掉 "+." 前缀），与 convert_to_mrs 的产物格式一致。
# ---------------------------------------------------------------------------
fetch_sakura_mrs() {
    local category="$1" out="$2"
    local url="$SRC_SAKURA/$category/$category-Site.mrs"
    local raw code
    raw="$(mktemp)"

    # 快照模式：直接从本地读
    if [ -n "$SNAPSHOT_DIR" ]; then
        local snap="$SNAPSHOT_DIR/b/$category/$category-Site.mrs"
        if [ ! -s "$snap" ]; then
            bad "Sakura $category-Site 不在快照中（$snap）"
            rm -f "$raw"
            return 1
        fi
        cp "$snap" "$raw"
    else
        code=$(curl -sSL --retry 3 --retry-delay 2 -m 120 \
                    -o "$raw" -w "%{http_code}" "$url" 2>/dev/null || echo 000)
        if [ "$code" != "200" ] || [ ! -s "$raw" ]; then
            bad "Sakura $category-Site http=$code（$url）"
            rm -f "$raw"
            return 1
        fi
    fi

    if ! command -v mihomo >/dev/null 2>&1; then
        bad "fetch_sakura_mrs: 未找到 mihomo 命令（解码 .mrs 需要）"
        rm -f "$raw"
        return 1
    fi

    # .mrs → 裸域名文本，并去掉 suffix 前缀 "+."
    if ! mihomo convert-ruleset domain mrs "$raw" "$out" 2>/dev/null; then
        bad "Sakura $category-Site 解码失败"
        rm -f "$raw"
        return 1
    fi
    rm -f "$raw"

    if [ ! -s "$out" ]; then
        bad "Sakura $category-Site 解码后为空"
        return 1
    fi

    sed -i 's/^+\.//; s/^+//' "$out"
    return 0
}

# ---------------------------------------------------------------------------
# 按剔除清单过滤域名文本
#
# 用法：filter_out <输入文本> <剔除清单> <输出文本>
#
# 剔除清单：每行一个域名，空行与 # 注释忽略。
# 用于 AI-Site 剔除通用 SaaS 依赖（stripe / sentry / segment 等）——
# 这些是全互联网共用的，放进 🤖AI 组会把无关流量拽进 AI 节点。
# ---------------------------------------------------------------------------
filter_out() {
    local src="$1" drop="$2" out="$3"
    if [ ! -f "$drop" ]; then
        cp "$src" "$out"
        return 0
    fi
    python3 - "$src" "$drop" "$out" <<'PY'
import sys

src, drop, out = sys.argv[1:4]

blocked = set()
for line in open(drop, encoding='utf-8', errors='ignore'):
    line = line.strip()
    if not line or line.startswith('#'):
        continue
    blocked.add(line.lower())

kept = []
removed = 0
for line in open(src, encoding='utf-8', errors='ignore'):
    v = line.strip()
    if not v:
        continue
    if v.lower() in blocked:
        removed += 1
        continue
    kept.append(v)

with open(out, 'w', encoding='utf-8', newline='\n') as f:
    for v in kept:
        f.write(v + '\n')

print(f'  剔除 {removed} 条 → 保留 {len(kept)} 条')
PY
}

# ---------------------------------------------------------------------------
# Crypto 筛选规则
#
# 上游 上游 C 的 Crypto.txt 混入了完整 PayPal 规则集（205/417 条，占 49%）。
# 实测：Crypto ∩ PayPal = 205 条，Crypto 独有 = 212 条。
#
# 本脚本用「集合差」精确剔除：下载 PayPal.txt，从 Crypto 中减去。
# 不用关键词匹配，避免误杀（如 crypto.com 含 "crypto" 但需保留，
# 而 paypal.com 不含 crypto 却必须剔除）。
# ---------------------------------------------------------------------------
build_crypto() {
    log "构建 Crypto（剔除 PayPal 污染）"

    local raw="$UPSTREAM/Crypto.raw.txt"
    local paypal="$UPSTREAM/PayPal.raw.txt"
    local out="$DEST/Crypto.txt"

    if [ -n "$SNAPSHOT_DIR" ]; then
        cp "$SNAPSHOT_DIR/c/Crypto.txt" "$raw"
        cp "$SNAPSHOT_DIR/c/PayPal.txt" "$paypal"
    else
        curl -sSL --retry 3 --retry-delay 2 -m 60 -o "$raw"    "$SRC_UPSTREAM_C/Crypto.txt"
        curl -sSL --retry 3 --retry-delay 2 -m 60 -o "$paypal" "$SRC_UPSTREAM_C/PayPal.txt"
    fi

    if ! grep -q "^DOMAIN" "$raw"; then bad "Crypto 下载异常"; return 1; fi
    if ! grep -q "^DOMAIN" "$paypal"; then bad "PayPal 下载异常"; return 1; fi

    python3 - "$raw" "$paypal" "$out" <<'PY'
import sys

raw_path, paypal_path, out_path = sys.argv[1:4]

def load(path):
    """读取规则集，返回 (有序条目列表, 去重集合)"""
    seen, ordered = set(), []
    for line in open(path, encoding='utf-8', errors='ignore'):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if ',' not in line:
            continue
        if line not in seen:
            seen.add(line)
            ordered.append(line)
    return ordered, seen

crypto_ordered, crypto_set = load(raw_path)
_, paypal_set = load(paypal_path)

# 集合差：Crypto 中不属于 PayPal 的条目
kept = [r for r in crypto_ordered if r not in paypal_set]
removed = len(crypto_ordered) - len(kept)

with open(out_path, 'w', encoding='utf-8', newline='\n') as f:
    f.write('# NAME: Crypto\n')
    f.write('# FILTERED: 从上游 Crypto 规则集筛选\n')
    f.write(f'# FILTER: removed {removed} PayPal/payment entries\n')
    f.write(f'# TOTAL: {len(kept)}\n')
    for r in kept:
        f.write(r + '\n')

print(f'  原始 {len(crypto_ordered)} 条 → 保留 {len(kept)} 条，剔除 {removed} 条')
PY

    # 编译为 mrs。
    #
    # 必须剔除 DOMAIN-KEYWORD 行：mihomo 的 domainStrategy.Insert() 把整行
    # 当域名插进 trie，不解析 "domain-keyword," 前缀 —— 转成 mrs 后这些行
    # 会变成永远匹配不到的字面量。
    #
    # 对应的 5 条 keyword 内联在模板 rules: 段（RULE-SET,Crypto 之前）。
    if command -v mihomo >/dev/null 2>&1; then
        local plain
        plain="$(mktemp)"
        grep -v '^DOMAIN-KEYWORD,' "$out" \
            | sed 's/^DOMAIN-SUFFIX,//; s/^DOMAIN,//' > "$plain"

        local kw_count
        kw_count=$(grep -c '^DOMAIN-KEYWORD,' "$out" || true)

        if mihomo convert-ruleset domain text "$plain" "$DEST/Crypto.mrs" 2>/dev/null; then
            ok "Crypto.mrs 已生成（剔除 $kw_count 条 keyword，见模板内联）"
        else
            bad "mrs 编译失败（Mihomo 版本不支持 convert-ruleset）"
        fi
        rm -f "$plain"
    else
        printf '  \033[33mSKIP\033[0m 未找到 mihomo 命令，仅输出 .txt\n'
        printf '         安装：https://github.com/MetaCubeX/mihomo/releases\n'
    fi

    ok "Crypto.txt → $out"
}

# ---------------------------------------------------------------------------
# PayPal 规则集
#
# 上游 Crypto.txt 已混入完整 PayPal（205/417 条），被 build_crypto 剔除。
# 这里单独镜像 PayPal.txt，供 💳PayPal 组使用，避免与 Crypto 组冲突。
#
# 注意：只有根目录 PayPal.txt 有效。
#   /mihomo/PayPal.txt        → 206 条 ✅
#   /mihomo/domain/PayPal.txt → 404 HTML ❌（不要用）
# ---------------------------------------------------------------------------
build_paypal() {
    log "镜像 PayPal 规则集并分离钓鱼域名"

    local out="$DEST/PayPal.txt"
    local phish="$DEST/PayPal-Phish.txt"
    local raw="$UPSTREAM/PayPal.raw.txt"

    if [ -n "$SNAPSHOT_DIR" ]; then
        cp "$SNAPSHOT_DIR/c/PayPal.txt" "$raw"
    else
        curl -sSL --retry 3 --retry-delay 2 -m 60 -o "$raw" "$SRC_UPSTREAM_C/PayPal.txt"
    fi

    # 内容校验：必须是 DOMAIN 开头的规则行，不能是 HTML
    if ! grep -q "^DOMAIN" "$raw"; then
        bad "PayPal 下载异常（可能是 404 HTML）"
        head -3 "$raw"
        return 1
    fi

    # 分离钓鱼域名：官方放行 → PayPal.txt，仿冒拦截 → PayPal-Phish.txt
    # 判定依据见 filter-paypal-phish.py 头部注释（基于 DNS MX 证据）
    if ! python3 "$(dirname "$0")/filter-paypal-phish.py" "$raw" "$phish" "$out"; then
        bad "钓鱼域名分离失败"
        return 1
    fi

    local n_clean n_phish
    n_clean=$(grep -c '^DOMAIN' "$out" || true); n_clean=${n_clean:-0}
    n_phish=$(grep -c '^DOMAIN' "$phish" || true); n_phish=${n_phish:-0}
    ok "PayPal.txt ($n_clean 条官方)"
    ok "PayPal-Phish.txt ($n_phish 条钓鱼)"

    # 编译 PayPal.mrs，剔除 DOMAIN-KEYWORD（原因同 Crypto：mrs 不支持）。
    # 对应的 9 条 keyword 内联在模板 rules: 段（RULE-SET,PayPal 之前）。
    if command -v mihomo >/dev/null 2>&1; then
        local plain kw_count
        plain="$(mktemp)"
        grep -v '^DOMAIN-KEYWORD,' "$out" \
            | sed 's/^DOMAIN-SUFFIX,//; s/^DOMAIN,//' > "$plain"
        kw_count=$(grep -c '^DOMAIN-KEYWORD,' "$out" || true)

        if mihomo convert-ruleset domain text "$plain" "$DEST/PayPal.mrs" 2>/dev/null; then
            ok "PayPal.mrs 已生成（剔除 $kw_count 条 keyword，见模板内联）"
        else
            bad "PayPal.mrs 编译失败"
        fi
        rm -f "$plain"
    else
        printf '  \033[33mSKIP\033[0m 未找到 mihomo，跳过 PayPal.mrs\n'
    fi

    # 自动同步内联段到模板
    #
    # 查找策略（按优先级）：
    #   1. 环境变量 MISUB_TEMPLATE 显式指定（最高优先级）
    #   2. 全仓库递归搜索含 PAYPAL-PHISH-INLINE 标记的文件
    #   3. templates/ 下的 .mjaa / .yaml / .yml
    #
    # 递归搜索依据标记而非扩展名：只要文件含标记就该同步，
    # 避免模板改名/移动后漏同步。
    local tpl=""
    local repo_root
    repo_root="$(cd "$(dirname "$0")" && pwd)"

    if [ -n "${MISUB_TEMPLATE:-}" ] && [ -f "${MISUB_TEMPLATE}" ]; then
        tpl="$MISUB_TEMPLATE"
    else
        # 排除 .git / node_modules / ruleset 产物目录，避免误匹配
        tpl=$(grep -rl --include='*.mjaa' --include='*.yaml' --include='*.yml' \
                  --exclude-dir=.git --exclude-dir=node_modules \
                  --exclude-dir=ruleset --exclude-dir=upstream \
                  'PAYPAL-PHISH-INLINE' "$repo_root" 2>/dev/null \
              | head -1 || true)

        # 兜底：无标记时退回 templates/ 目录扫描
        if [ -z "$tpl" ]; then
            tpl=$(find "$repo_root/templates" -maxdepth 1 -type f \
                      \( -name '*.mjaa' -o -name '*.yaml' -o -name '*.yml' \) \
                      2>/dev/null | head -1 || true)
        fi
    fi

    if [ -n "$tpl" ] && [ -f "$tpl" ]; then
        log "同步内联段 → ${tpl#"$repo_root"/}"
        if python3 "$(dirname "$0")/sync-inline-phish.py" "$tpl" "$phish"; then
            ok "内联段已同步"
        else
            printf '  \033[33mWARN\033[0m 内联段同步失败（模板可能缺少标记）\n'
        fi
    else
        printf '  \033[33mSKIP\033[0m 未找到含标记的模板，跳过内联同步\n'
        printf '         可用 MISUB_TEMPLATE=/path/to/tpl 显式指定\n'
    fi
}

# ---------------------------------------------------------------------------
# 域名类规则集镜像（19 个）
#
# 全部镜像到本仓库 ruleset/site/，模板不引用任何第三方域名。
# 上游更新后重跑本函数即可同步。
# ---------------------------------------------------------------------------
build_site() {
    require_src_rules
    log "镜像域名类规则集 → $DEST/site/"

    mkdir -p "$DEST/site"

    local repo_root
    repo_root="$(cd "$(dirname "$0")" && pwd)"

    # 本地名 : 上游路径
    #
    # 多数是 <Name>/<Name>.yaml，但有三个例外：
    #   Advertising / China / Apple 的 .yaml 被截断（只含 KEYWORD 与部分条目），
    #   完整域名列表在 <Name>_Domain_For_Clash.txt。
    #   例：Advertising.yaml 声明 TOTAL=291159，实际只有 778 行。
    #
    # AI-Site 是多个 AI 目录的合并（单个目录只有几十条）。
    # 用逗号分隔多个上游路径。
    #
    # Meta ← Facebook 是名称映射。
    local -a items=(
        "AD-Site:Advertising/Advertising_Domain_For_Clash.txt"
        "Adobe-Site:Adobe/Adobe.yaml"
        "AI-Site:OpenAI/OpenAI.yaml,Anthropic/Anthropic.yaml,Claude/Claude.yaml,Gemini/Gemini.yaml,BardAI/BardAI.yaml,Civitai/Civitai.yaml"
        "Apple-Site:Apple/Apple_Domain_For_Clash.txt"
        "Bahamut-Site:Bahamut/Bahamut.yaml"
        "Bilibili-Site:BiliBili/BiliBili.yaml"
        "China-Site:China/China_Domain_For_Clash.txt"
        "Discord-Site:Discord/Discord.yaml"
        "Disney-Site:Disney/Disney.yaml"
        "Google-Site:Google/Google.yaml"
        "Meta-Site:Facebook/Facebook.yaml"
        "Microsoft-Site:Microsoft/Microsoft.yaml"
        "Netflix-Site:Netflix/Netflix.yaml"
        "Pixiv-Site:Pixiv/Pixiv.yaml"
        "Reddit-Site:Reddit/Reddit.yaml"
        "Steam-Site:Steam/Steam.yaml"
        "Telegram-Site:Telegram/Telegram.yaml"
        "Twitch-Site:Twitch/Twitch.yaml"
        "Twitter-Site:Twitter/Twitter.yaml"
    )

    # 从 Sakura 取源的规则集：本地名 : 上游 B 分类
    #
    # 2026-11-12 决策依据（19 个规则集两两比对，见 ruleset/SOURCES.md）：
    #   AD-Site  服务商 181,665 条含 25,711 条我们缺的仿冒域（mlcrosoft.vip 等），
    #            但比 上游 A 少 108,727 条 → 合并而非替换
    #   AI-Site  服务商自编 217 条，覆盖 Perplexity/Grok/Cursor/Midjourney/Kimi/Manus
    #            等我们完全没有的服务 → 与 上游 A 合并
    #   其余 17 个重合率 90%+，同源，保持 上游 A
    #
    # 目前没有「纯换源」的规则集 —— 两个例外都走合并。
    # 保留这个数组是为了将来有规则集确实只该用 上游 B 时直接加。
    local -a sakura_items=()

    # AD-Site 合并：上游 A 全量 + 上游 B 补仿冒域
    #
    # 实测（2026-11-12，mihomo v1.19.2）：
    #   上游 A  290,392 条  43,204 kB
    #   上游 B        181,665 条  36,304 kB
    #   合并          316,103 条  43,732 kB
    #
    # 合并只多 528 kB（+1.2%）—— domain trie 共享后缀，
    # 25,711 条新增里大量是 *.mlcrosoft.vip 这类同后缀仿冒域。
    # 换源能省 6.9 MB 但少拦 108,727 个广告域，不划算。
    local ad_merge=1

    # AI-Site 合并：上游 B 为主 + 上游 A 补漏
    # 补漏清单是 上游 A 有、上游 B 没有的 AI 业务域（10 条）。
    # 通用 SaaS 依赖（stripe/sentry/segment 等 15 条）由
    # filters/ai-drop-saas.yaml 剔除 —— 见该文件头部的决策说明。
    local ai_keep="$repo_root/filters/ai-keep.txt"
    local ai_drop="$repo_root/filters/ai-drop-saas.yaml"

    local okc=0 failc=0
    for item in "${items[@]}"; do
        local name rels tmp code
        name="${item%%:*}"
        rels="${item##*:}"
        tmp="$UPSTREAM/$name.raw"
        out="$DEST/site/$name.mrs"

        # 多上游：逐个下载并拼接
        : > "$tmp"
        local dl_fail=0
        local IFS=','
        for rel in $rels; do
            local one
            one="$(mktemp)"
            if [ -n "$SNAPSHOT_DIR" ]; then
                if [ ! -s "$SNAPSHOT_DIR/a/$rel" ]; then
                    bad "$name 不在快照中（a/$rel）"
                    dl_fail=1
                    rm -f "$one"
                    break
                fi
                cp "$SNAPSHOT_DIR/a/$rel" "$one"
            else
                code=$(curl -sSL --retry 3 --retry-delay 2 -m 120 \
                            -o "$one" -w "%{http_code}" \
                            "$SRC_RULES/$rel" 2>/dev/null || echo 000)
                if [ "$code" != "200" ] || [ ! -s "$one" ]; then
                    bad "$name http=$code（上游 $rel）"
                    dl_fail=1
                    rm -f "$one"
                    break
                fi
            fi
            if ! check_upstream_complete "$one" "$name ($rel)"; then
                dl_fail=1
                rm -f "$one"
                break
            fi
            cat "$one" >> "$tmp"
            rm -f "$one"
        done
        unset IFS

        if [ "$dl_fail" -eq 1 ]; then
            failc=$((failc+1))
            continue
        fi

        # 上游 YAML / 纯文本 → mihomo mrs
        if ! convert_to_mrs domain "$tmp" "$out"; then
            bad "$name 转换失败"
            failc=$((failc+1))
            continue
        fi

        printf '  \033[32mOK\033[0m   %-18s %9s bytes\n' "$name" "$(stat -c%s "$out")"
        okc=$((okc+1))
    done

    # ---- 上游 B 换源的规则集 ----
    for item in "${sakura_items[@]}"; do
        local name cat plain
        name="${item%%:*}"
        cat="${item##*:}"
        plain="$(mktemp)"

        if ! fetch_sakura_mrs "$cat" "$plain"; then
            failc=$((failc+1))
            rm -f "$plain"
            continue
        fi

        if ! convert_to_mrs domain "$plain" "$DEST/site/$name.mrs"; then
            bad "$name 转换失败（Sakura 源）"
            failc=$((failc+1))
            rm -f "$plain"
            continue
        fi
        rm -f "$plain"

        printf '  \033[32mOK\033[0m   %-18s %9s bytes  \033[2m(Sakura)\033[0m\n' \
               "$name" "$(stat -c%s "$DEST/site/$name.mrs")"
        okc=$((okc+1))
    done

    # ---- AD-Site 合并：上游 A 全量 + 上游 B 补仿冒域 ----
    if [ "$ad_merge" -eq 1 ]; then
        local ad_sakura ad_cur ad_union
        ad_sakura="$(mktemp)"
        ad_cur="$(mktemp)"
        ad_union="$(mktemp)"

        if ! fetch_sakura_mrs "AD" "$ad_sakura"; then
            failc=$((failc+1))
            rm -f "$ad_sakura" "$ad_cur" "$ad_union"
        else
            # 上游 A 侧已在上面循环里构建好，解码回来归一化
            if ! mihomo convert-ruleset domain mrs "$DEST/site/AD-Site.mrs" "$ad_cur" 2>/dev/null; then
                bad "AD-Site 解码 上游 A 侧失败"
                failc=$((failc+1))
                rm -f "$ad_sakura" "$ad_cur" "$ad_union"
            else
                sed -i 's/^+\.//; s/^+//' "$ad_cur"
                sort -u "$ad_cur" "$ad_sakura" > "$ad_union"

                local n_cur n_sak n_union
                n_cur=$(wc -l < "$ad_cur")
                n_sak=$(wc -l < "$ad_sakura")
                n_union=$(wc -l < "$ad_union")

                if ! convert_to_mrs domain "$ad_union" "$DEST/site/AD-Site.mrs"; then
                    bad "AD-Site 转换失败（合并源）"
                    failc=$((failc+1))
                else
                    printf '  \033[32mOK\033[0m   %-18s %9s bytes  \033[2m(bm7 %s + Sakura %s → %s)\033[0m\n' \
                           "AD-Site" "$(stat -c%s "$DEST/site/AD-Site.mrs")" \
                           "$n_cur" "$n_sak" "$n_union"
                fi
                rm -f "$ad_sakura" "$ad_cur" "$ad_union"
            fi
        fi
    fi

    # ---- AI-Site 合并：上游 B + 上游 A 补漏，剔除通用 SaaS ----
    local ai_sakura ai_bm ai_merged
    ai_sakura="$(mktemp)"
    ai_bm="$(mktemp)"
    ai_merged="$(mktemp)"

    if ! fetch_sakura_mrs "AI" "$ai_sakura"; then
        failc=$((failc+1))
        rm -f "$ai_sakura" "$ai_bm" "$ai_merged"
    else
        # 上游 A 侧只取补漏清单里的 10 条（其余 41 条由 上游 B 覆盖或属通用 SaaS）
        if [ -f "$ai_keep" ]; then
            : > "$ai_bm"
            while IFS= read -r d; do
                [ -z "$d" ] && continue
                case "$d" in \#*) continue ;; esac
                printf '%s\n' "$d" >> "$ai_bm"
            done < "$ai_keep"
        else
            : > "$ai_bm"
        fi

        # 合并 + 去重
        cat "$ai_sakura" "$ai_bm" | sort -u > "$ai_merged"

        # 剔除通用 SaaS 依赖
        local ai_filtered
        ai_filtered="$(mktemp)"
        filter_out "$ai_merged" "$ai_drop" "$ai_filtered"

        if ! convert_to_mrs domain "$ai_filtered" "$DEST/site/AI-Site.mrs"; then
            bad "AI-Site 转换失败（合并源）"
            failc=$((failc+1))
        else
            printf '  \033[32mOK\033[0m   %-18s %9s bytes  \033[2m(Sakura + bm7 补漏)\033[0m\n' \
                   "AI-Site" "$(stat -c%s "$DEST/site/AI-Site.mrs")"
            okc=$((okc+1))
        fi
        rm -f "$ai_filtered"
        rm -f "$ai_sakura" "$ai_bm" "$ai_merged"
    fi

    if [ "$failc" -gt 0 ]; then
        bad "域名类规则集: $okc 成功 / $failc 失败"
        return 1
    fi
    ok "域名类规则集: $okc 个全部成功"
}

# ---------------------------------------------------------------------------
# IP 类规则集镜像（方案 C）
#
# 这三个极少变更，镜像后不依赖服务商存活。
# 必须放 geoip/ 子目录：MiSub 的 getRuleProviderBehavior() 靠
# 路径里的 /geoip/ 判定 ipcidr，否则误判 domain 导致 ErrInvalidFormat。
# ---------------------------------------------------------------------------
build_geoip() {
    require_src_rules
    log "镜像 IP 类规则集 → $DEST/geoip/"

    # Local-IP：标准私有网段，本地生成，不依赖上游
    # （上游合集经常变动，但私有网段是 IANA 固定分配）
    local local_plain
    local_plain="$(mktemp)"
    cat > "$local_plain" <<'EOF'
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.0.0.0/24
192.0.2.0/24
192.168.0.0/16
198.18.0.0/15
198.51.100.0/24
203.0.113.0/24
224.0.0.0/3
::/127
fc00::/7
fe80::/10
ff00::/8
EOF
    if mihomo convert-ruleset ipcidr text "$local_plain" "$DEST/geoip/Local-IP.mrs" 2>/dev/null; then
        ok "Local-IP.mrs（本地生成，$(stat -c%s "$DEST/geoip/Local-IP.mrs") bytes）"
    else
        bad "Local-IP.mrs 生成失败"
        rm -f "$local_plain"
        return 1
    fi
    rm -f "$local_plain"

    # China-IP / Telegram-IP：从上游 IP 列表提取
    #   China-IP    ← ChinaIPs/ChinaIPs_IP.txt
    #   Telegram-IP ← Telegram/Telegram.yaml 中的 IP-CIDR 段
    local -a items=(
        "China-IP:ChinaIPs/ChinaIPs_IP.txt"
        "Telegram-IP:Telegram/Telegram.yaml"
    )

    for item in "${items[@]}"; do
        local name rel tmp
        name="${item%%:*}"
        rel="${item##*:}"
        tmp="$UPSTREAM/$name.raw"

        if [ -n "$SNAPSHOT_DIR" ]; then
            if [ ! -s "$SNAPSHOT_DIR/a/$rel" ]; then
                bad "$name 不在快照中（a/$rel）"
                return 1
            fi
            cp "$SNAPSHOT_DIR/a/$rel" "$tmp"
        else
            local code
            code=$(curl -sSL --retry 3 --retry-delay 2 -m 90 \
                        -o "$tmp" -w "%{http_code}" "$SRC_RULES/$rel" 2>/dev/null || echo 000)
            if [ "$code" != "200" ]; then
                bad "$name http=$code（上游 $rel）"
                return 1
            fi
        fi

        if ! convert_to_mrs ipcidr "$tmp" "$DEST/geoip/$name.mrs"; then
            bad "$name 转换失败"
            return 1
        fi
        ok "$name.mrs ($(stat -c%s "$DEST/geoip/$name.mrs") bytes)"
    done
}

# ---------------------------------------------------------------------------
# 校验：确认 Crypto 已无 PayPal 污染
# ---------------------------------------------------------------------------
verify() {
    log "校验 Crypto 筛选结果"

    local out="$DEST/Crypto.txt"
    [ -f "$out" ] || { bad "缺少 $out，先运行构建"; return 1; }

    local total paypal_left
    total=$(grep -c '^DOMAIN' "$out" || echo 0)
    # 只统计规则行（DOMAIN 开头），跳过 # 注释头
    paypal_left=$(grep '^DOMAIN' "$out" \
        | grep -ic 'paypal\|paypa1\|pa9pal\|paaypal\|paipal\|pavpal\|payppal\|payypal\|ppaypal\|pypl\|braintree\|briantree\|xoom\|venmo\|billmelater\|bill-safe\|loanbuilder' \
        || true)
    paypal_left=${paypal_left:-0}

    echo "  条目总数    : $total"
    echo "  残留支付条目: $paypal_left"

    if [ "$paypal_left" -eq 0 ]; then
        ok "无 PayPal/支付类残留"
    else
        bad "仍有 $paypal_left 条支付类残留"
        grep -i 'paypal\|braintree\|xoom\|venmo' "$out" | head -10
        return 1
    fi

    # 关键交易所必须保留
    local -a must=(
        "binance" "okx" "bybit" "coinbase" "kraken"
        "metamask" "trustwallet" "uniswap" "opensea"
        "coingecko" "coinmarketcap" "etherscan" "trezor"
    )
    local missing=()
    for m in "${must[@]}"; do
        grep -qi "$m" "$out" || missing+=("$m")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        ok "关键平台全部保留（${#must[@]} 项）"
    else
        bad "缺失关键平台: ${missing[*]}"
        return 1
    fi

    # --- PayPal 规则集校验 ---
    local pp="$DEST/PayPal.txt"
    if [ -f "$pp" ]; then
        local pp_total
        pp_total=$(grep -c '^DOMAIN' "$pp" || true)
        pp_total=${pp_total:-0}
        if [ "$pp_total" -gt 0 ] && ! grep -qi 'doctype html' "$pp"; then
            ok "PayPal.txt 有效（$pp_total 条）"
        else
            bad "PayPal.txt 内容异常"
            return 1
        fi

        # 交叉校验：Crypto 与 PayPal 不应有交集（已做集合差）
        local overlap
        overlap=$(comm -12 <(grep '^DOMAIN' "$out" | sort) <(grep '^DOMAIN' "$pp" | sort) | wc -l)
        if [ "$overlap" -eq 0 ]; then
            ok "Crypto ∩ PayPal = 0（无冲突）"
        else
            bad "Crypto 与 PayPal 仍有 $overlap 条交集"
            return 1
        fi

        # 安全校验：官方域名绝不可出现在钓鱼清单中
        local phish="$DEST/PayPal-Phish.txt"
        if [ -f "$phish" ]; then
            local leaked=0
            for d in paypal.com paypal.me paypalobjects.com paypalinc.com \
                     paypal-biz.com braintreegateway.com venmo-touch.com xoomcom.com \
                     paypalcorp.com paypal-prepaid.com; do
                if grep -qE "^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD),${d}\$" "$phish"; then
                    bad "官方域名被误拦: $d"
                    leaked=$((leaked+1))
                fi
            done
            if [ "$leaked" -eq 0 ]; then
                ok "官方域名无误拦（10 项抽检）"
            else
                return 1
            fi

            # 交叉校验：钓鱼清单与官方清单必须无交集
            local ph_overlap
            ph_overlap=$(comm -12 <(grep '^DOMAIN' "$pp" | sort) <(grep '^DOMAIN' "$phish" | sort) | wc -l)
            if [ "$ph_overlap" -eq 0 ]; then
                ok "PayPal ∩ PayPal-Phish = 0"
            else
                bad "官方与钓鱼清单有 $ph_overlap 条交集"
                return 1
            fi
        fi
    else
        printf '  \033[33mSKIP\033[0m PayPal.txt 未构建\n'
    fi
}

# ---------------------------------------------------------------------------
# 差异报告：对比临时构建产物与现有产物
#
# 输出三类信息：
#   1. 文件级：新增 / 删除 / 变更
#   2. 条目级：每个规则集的增减条数
#   3. 风险级：按变更幅度分级（info / warn / block）
#
# 风险分级依据：
#   block  变更幅度 > 30%（可能是上游误操作）
#   warn   变更幅度 > 5%（需人工确认）
#   info   小幅变更（可自动通过）
# ---------------------------------------------------------------------------
diff_report() {
    local new_dir="$1"
    local old_dir="ruleset"
    local report
    report="$(mktemp)"

    local has_block=0 has_warn=0 has_error=0

    echo ""
    log "变更报告"
    printf '  %-24s %10s %10s %10s  %s\n' "规则集" "旧" "新" "增减" "风险"
    printf '  %s\n' "$(printf '%.0s-' {1..72})"

    # 收集全部规则集名（旧+新，去重）
    local -a names=()
    local -A seen=()
    while IFS= read -r f; do
        local bn
        bn="$(basename "$f")"
        [ -n "${seen[$bn]:-}" ] && continue
        seen["$bn"]=1
        names+=("$bn")
    done < <(find "$new_dir" "$old_dir" -maxdepth 2 -type f \( -name '*.mrs' -o -name 'Crypto.txt' -o -name 'PayPal.txt' -o -name 'PayPal-Phish.txt' \) 2>/dev/null | sort)

    # 审核日志目录（gitignore，本地保留）
    local review_dir="${REVIEW_DIR:-review}"
    local review_log="$review_dir/decisions.jsonl"
    mkdir -p "$review_dir" 2>/dev/null || true
    local review_ts
    review_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    for n in "${names[@]}"; do
        # 定位新旧文件（可能在根目录或子目录）
        local old_f new_f
        old_f=$(find "$old_dir" -name "$n" -type f 2>/dev/null | head -1)
        new_f=$(find "$new_dir" -name "$n" -type f 2>/dev/null | head -1)

        local old_n=0 new_n=0
        [ -n "$old_f" ] && [ -s "$old_f" ] && old_n=$(count_entries "$old_f")
        [ -n "$new_f" ] && [ -s "$new_f" ] && new_n=$(count_entries "$new_f")

        # 字节级相同则跳过
        if [ -n "$old_f" ] && [ -n "$new_f" ] && cmp -s "$old_f" "$new_f"; then
            continue
        fi

        # 分级由 cmd/riskgrade 决定，不在这里重算。
        #
        # 曾经这里有一段 awk 实现同样的阈值，和 Go 侧各写一份，已经漂移：
        # shell 把新规则集叫 "new"，Go 叫 "info"；shell 也没有「两边都空」
        # 这个判断。现在阈值只在 internal/risk 定义一次。
        local delta pct risk note
        local graded
        # 分级工具不可用是环境故障，不是「变更很大」。此前这里 return 2，
        # 被调用方解释成 BLOCK，于是「没装 riskgrade」和「上游删了一半规则」
        # 得到同一句提示——真正需要人看的那种情况被淹没了。
        if ! graded=$(riskgrade -v "$old_n" "$new_n" 2>/dev/null); then
            bad "riskgrade 调用失败（old=$old_n new=$new_n）"
            has_error=1
            continue
        fi
        IFS=$'\t' read -r risk _ _ delta pct note <<< "$graded"

        local color="\033[32m"
        case "$risk" in
            none)  color="\033[90m" ;;
            info)  color="\033[32m" ;;
            warn)  color="\033[33m"; has_warn=1 ;;
            BLOCK) color="\033[31m"; has_block=1 ;;
        esac

        # 新规则集单独标注：它是变更的属性，不是一个更高的风险级。
        local label="$risk"
        [ "$note" = "new" ] && { label="new"; color="\033[36m"; }

        printf '  %-24s %10s %10s %+10s  %b%s\033[0m\n' \
            "$n" "$old_n" "$new_n" "$delta" "$color" "$label"

        # 记录到报告文件
        echo "$n|$old_n|$new_n|$delta|$risk" >> "$report"

        # 写入审核日志（JSONL，一行一条变更）
        if [ -n "${review_log:-}" ]; then
            python3 - "$review_log" "$review_ts" "$n" "$old_n" "$new_n" "$delta" "$risk" <<'PY' 2>/dev/null || true
import json, sys
log, ts, name, old_n, new_n, delta, risk = sys.argv[1:8]
rec = {
    'ts': ts,
    'ruleset': name,
    'old': int(old_n),
    'new': int(new_n),
    'delta': int(delta),
    'risk': risk,
}
with open(log, 'a', encoding='utf-8') as f:
    f.write(json.dumps(rec, ensure_ascii=False) + '\n')
PY
        fi

        # BLOCK 级：列出具体条目
        if [ "$risk" = "BLOCK" ] && [ -n "$old_f" ] && [ -n "$new_f" ]; then
            echo "      删除的条目（前 5 条）:"
            diff_entries "$old_f" "$new_f" removed | head -5 | sed 's/^/        - /'
            echo "      新增的条目（前 5 条）:"
            diff_entries "$old_f" "$new_f" added | head -5 | sed 's/^/        + /'
        fi
    done

    if [ "$has_error" -eq 1 ]; then
        echo ""
        bad "无法完成分级：riskgrade 不可用，本次 check 结果不可信"
        rm -f "$report"
        return 3
    fi

    if [ ! -s "$report" ]; then
        echo "  （无变更）"
        rm -f "$report"
        return 0
    fi

    echo ""
    if [ "$has_block" -eq 1 ]; then
        bad "存在 BLOCK 级变更（幅度 > 30%），需人工确认后才能 apply"
        rm -f "$report"
        return 2
    elif [ "$has_warn" -eq 1 ]; then
        printf '  \033[33mWARN\033[0m 存在 warn 级变更（幅度 > 5%），建议人工确认\n'
        rm -f "$report"
        return 1
    fi

    ok "全部为 info 级变更，可安全 apply"
    rm -f "$report"
    return 0
}

# 统计规则集条目数（支持 mrs 与纯文本）
count_entries() {
    local f="$1"
    case "$f" in
        *.mrs)
            local tmp
            tmp="$(mktemp)"
            local behavior="domain"
            case "$f" in */geoip/*) behavior="ipcidr" ;; esac
            if mihomo convert-ruleset "$behavior" mrs "$f" "$tmp" 2>/dev/null; then
                grep -vc '^#' "$tmp" 2>/dev/null || echo 0
            else
                echo 0
            fi
            rm -f "$tmp"
            ;;
        *)
            grep -v '^#' "$f" 2>/dev/null | grep -c . || echo 0
            ;;
    esac
}

# 列出两个规则集的条目差异
diff_entries() {
    local old_f="$1" new_f="$2" want="$3"
    local old_t new_t
    old_t="$(mktemp)"; new_t="$(mktemp)"

    decode_to_text "$old_f" "$old_t"
    decode_to_text "$new_f" "$new_t"

    if [ "$want" = "removed" ]; then
        comm -23 <(sort -u "$old_t") <(sort -u "$new_t")
    else
        comm -13 <(sort -u "$old_t") <(sort -u "$new_t")
    fi

    rm -f "$old_t" "$new_t"
}

# 把任意规则集解码为纯文本（每行一个值，已归一化）
#
# 归一化：去掉前导 + 与 .，统一小写。
# mihomo 解码 mrs 时会保留原始前缀（+.reddit.com），
# 而重新构建的产物不带前缀（reddit.com）—— 不归一化会把
# 同一个域名当成增删两条，差异虚高。
decode_to_text() {
    local f="$1" out="$2"
    case "$f" in
        *.mrs)
            local behavior="domain"
            case "$f" in */geoip/*) behavior="ipcidr" ;; esac
            mihomo convert-ruleset "$behavior" mrs "$f" "$out" 2>/dev/null || true
            ;;
        *)
            grep -v '^#' "$f" 2>/dev/null | awk -F, 'NF>=2{print $2}' > "$out" || true
            ;;
    esac

    # 归一化：去前导 + / .，转小写，去空行
    if [ -s "$out" ]; then
        awk '{gsub(/^[+.]*/, ""); print tolower($0)}' "$out" \
            | grep -v '^$' | sort -u > "$out.norm" || true
        mv "$out.norm" "$out"
    fi
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
case "$TARGET" in
    crypto) build_crypto; verify ;;
    paypal) build_paypal; verify ;;
    site)   build_site ;;
    geoip)  build_geoip ;;
    verify) verify ;;

    # -----------------------------------------------------------------------
    # check —— 构建到临时目录，与现有产物 diff，不写入
    #
    # 退出码：
    #   0  无变更，或全部为 info 级
    #   1  存在 warn 级变更（幅度 > 5%）
    #   2  存在 BLOCK 级变更（幅度 > 30%）
    # -----------------------------------------------------------------------
    check)
        require_src_rules
        command -v mihomo >/dev/null 2>&1 || {
            bad "check 模式需要 mihomo（用于解码 mrs 并对比条目）"
            printf '         安装：https://github.com/MetaCubeX/mihomo/releases\n' >&2
            exit 2
        }

        tmp_dest="$(mktemp -d)"
        trap 'rm -rf "$tmp_dest"' EXIT

        log "check 模式：构建到临时目录，不修改工作区"

        DEST="$tmp_dest/ruleset"
        UPSTREAM="$DEST/upstream"
        mkdir -p "$DEST" "$DEST/geoip" "$UPSTREAM"

        build_crypto
        build_paypal
        build_site
        build_geoip

        # 临时产物与现有产物对比
        rc=0
        diff_report "$DEST" || rc=$?

        echo ""
        if [ "$rc" -eq 0 ]; then
            echo "  确认无误后执行：bash build-rules.sh apply"
        elif [ "$rc" -eq 1 ]; then
            echo "  建议先查看具体差异，确认后执行：bash build-rules.sh apply"
        elif [ "$rc" -eq 3 ]; then
            echo "  ⚠ 环境不完整：先装好 riskgrade（go install ./cmd/riskgrade）再重跑 check"
        else
            echo "  ⚠ BLOCK 级变更需人工审查。确认上游无误后执行："
            echo "    bash build-rules.sh apply"
        fi
        exit "$rc"
        ;;

    # -----------------------------------------------------------------------
    # apply —— 构建并写入 ruleset/（原 all 的行为）
    # -----------------------------------------------------------------------
    apply)
        build_crypto
        build_paypal
        build_site
        build_geoip
        verify
        echo
        log "构建完成。产物："
        find "$DEST" -type f \( -name '*.mrs' -o -name 'Crypto.txt' \) | sort | while read -r f; do
            printf '  %-40s %s bytes\n' "$f" "$(stat -c%s "$f")"
        done
        echo
        log "下一步：git add ruleset/ && git commit -m 'update rules' && git push"
        ;;

    # all 已废弃，改为提示先跑 check
    all)
        printf '\033[33m注意\033[0m all 已拆分：\n\n' >&2
        printf '  bash build-rules.sh check   # 先看差异（不写入）\n' >&2
        printf '  bash build-rules.sh apply   # 确认后写入\n\n' >&2
        printf '直接跳转到 check...\n\n' >&2
        exec bash "$0" check
        ;;

    *)
        cat >&2 <<'USAGE'
用法: bash build-rules.sh <command>

构建：
  check    构建到临时目录，与现有产物 diff，不写入（推荐先跑）
  apply    构建并写入 ruleset/

单项：
  crypto   只构建 Crypto
  paypal   只构建 PayPal
  site     只构建域名类规则集
  geoip    只构建 IP 类规则集

校验：
  verify   校验现有产物（不联网）

推荐流程：
  bash build-rules.sh check    # 看差异
  bash build-rules.sh apply    # 确认后写入
  bash build-rules.sh verify   # 校验产物
USAGE
        exit 1
        ;;
esac
