#!/usr/bin/env bash
# ============================================================================
# snapshot.sh — 上游快照存档
#
# 职责：拉取所有上游原始内容，计算 sha256，打包成 Release 资产。
#
# 设计原则：
#   1. 原始内容原样保存，不改动（保留审计价值）
#   2. 内容未变化时不产生新快照（sha256 比对）
#   3. 单个 provider 失败不阻断其余（保留上次成功的）
#   4. 快照可被 mihomo-rules 下载复现构建
#
# 用法：
#   bash snapshot.sh fetch          # 只拉取到 work/，不算 sha
#   bash snapshot.sh diff           # 拉取并比对，输出 CHANGED=true/false
#   bash snapshot.sh pack           # 打包成 snapshots.tar.gz + MANIFEST.json
#   bash snapshot.sh publish        # 创建 GitHub Release
#   bash snapshot.sh prune          # 按保留策略清理过期快照
#   bash snapshot.sh all            # fetch + diff + pack + publish + prune
#
# 环境变量（必需）：
#   SRC_RULES         主上游（域名 + IP 规则集）
#   SRC_SAKURA        第二上游（AD/AI 补强）
#   SRC_UPSTREAM_C    Crypto / PayPal 上游
#
# 环境变量（publish 时需要）：
#   GH_TOKEN          有 repo 权限的 token
#   GITHUB_REPOSITORY 默认 CauriumX/mihomo-upstream
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HERE/work}"
OUT="${OUT:-$HERE/dist}"
REPO="${GITHUB_REPOSITORY:-CauriumX/mihomo-upstream}"

log()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; }

require_env() {
    local missing=0
    for v in SRC_RULES SRC_SAKURA SRC_UPSTREAM_C; do
        if [ -z "${!v:-}" ]; then
            bad "未设置 $v"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || { echo "见 .env.example"; exit 1; }
}

# ---------------------------------------------------------------------------
# 上游 A：域名类 + IP 类规则集
#
# 路径结构：$SRC_RULES/<Category>/<Name>.yaml
# 三个例外用 *_Domain_For_Clash.txt（完整域名列表）
# ---------------------------------------------------------------------------
A_ITEMS=(
    "Advertising/Advertising_Domain_For_Clash.txt"
    "Adobe/Adobe.yaml"
    "OpenAI/OpenAI.yaml"
    "Anthropic/Anthropic.yaml"
    "Claude/Claude.yaml"
    "Gemini/Gemini.yaml"
    "BardAI/BardAI.yaml"
    "Civitai/Civitai.yaml"
    "Apple/Apple_Domain_For_Clash.txt"
    "Bahamut/Bahamut.yaml"
    "BiliBili/BiliBili.yaml"
    "China/China_Domain_For_Clash.txt"
    "Discord/Discord.yaml"
    "Disney/Disney.yaml"
    "Google/Google.yaml"
    "Facebook/Facebook.yaml"
    "Microsoft/Microsoft.yaml"
    "Netflix/Netflix.yaml"
    "Pixiv/Pixiv.yaml"
    "Reddit/Reddit.yaml"
    "Steam/Steam.yaml"
    "Telegram/Telegram.yaml"
    "Twitch/Twitch.yaml"
    "Twitter/Twitter.yaml"
    "ChinaIPs/ChinaIPs_IP.txt"
)

# 上游 B：AD / AI
B_ITEMS=(
    "AD/AD-Site.mrs"
    "AI/AI-Site.mrs"
)

# 上游 C：Crypto / PayPal
C_ITEMS=(
    "Crypto.txt"
    "PayPal.txt"
)

fetch_one() {
    local base="$1" rel="$2" dest="$3"
    local url="$base/$rel"
    local tmp code

    mkdir -p "$(dirname "$dest")"
    tmp="$(mktemp)"

    code=$(curl -sSL --retry 3 --retry-delay 2 -m 120 \
                -o "$tmp" -w "%{http_code}" "$url" 2>/dev/null || echo 000)

    if [ "$code" != "200" ] || [ ! -s "$tmp" ]; then
        bad "$(basename "$rel") http=$code"
        rm -f "$tmp"
        return 1
    fi

    mv "$tmp" "$dest"
    return 0
}

cmd_fetch() {
    require_env
    log "拉取上游 → $WORK"

    rm -rf "$WORK"
    mkdir -p "$WORK"/{a,b,c}

    local okc=0 failc=0

    for rel in "${A_ITEMS[@]}"; do
        if fetch_one "$SRC_RULES" "$rel" "$WORK/a/$rel"; then
            okc=$((okc+1))
        else
            failc=$((failc+1))
        fi
    done
    ok "上游 A: $okc 成功 / $failc 失败"

    okc=0; failc=0
    for rel in "${B_ITEMS[@]}"; do
        if fetch_one "$SRC_SAKURA" "$rel" "$WORK/b/$rel"; then
            okc=$((okc+1))
        else
            failc=$((failc+1))
        fi
    done
    ok "上游 B: $okc 成功 / $failc 失败"

    okc=0; failc=0
    for rel in "${C_ITEMS[@]}"; do
        if fetch_one "$SRC_UPSTREAM_C" "$rel" "$WORK/c/$rel"; then
            okc=$((okc+1))
        else
            failc=$((failc+1))
        fi
    done
    ok "上游 C: $okc 成功 / $failc 失败"
}

# ---------------------------------------------------------------------------
# 计算当前快照的 MANIFEST
# ---------------------------------------------------------------------------
build_manifest() {
    local out="$1"
    python3 - "$WORK" "$out" "${SRC_RULES:-}" "${SRC_SAKURA:-}" "${SRC_UPSTREAM_C:-}" <<'PY'
import hashlib, json, os, sys
from datetime import datetime, timezone
from pathlib import Path

work, out, base_a, base_b, base_c = sys.argv[1:6]

def sha256(p):
    h = hashlib.sha256()
    with open(p, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()

def count_entries(p):
    """粗估条数：yaml 数 '- '，txt 数非注释行，mrs 无法估"""
    if p.endswith('.mrs'):
        return None
    n = 0
    with open(p, encoding='utf-8', errors='ignore') as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith('#'):
                continue
            if s.startswith('- ') or (',' in s or s.startswith('+')):
                n += 1
    return n

providers = {}
for key, base, sub in (('upstream-a', base_a, 'a'),
                       ('upstream-b', base_b, 'b'),
                       ('upstream-c', base_c, 'c')):
    d = Path(work) / sub
    if not d.exists():
        continue
    files = {}
    for p in sorted(d.rglob('*')):
        if not p.is_file():
            continue
        rel = str(p.relative_to(d))
        files[rel] = {
            'sha256': sha256(p),
            'bytes': p.stat().st_size,
            'entries': count_entries(str(p)),
        }
    providers[key] = {'base': base, 'files': files}

manifest = {
    'snapshotId': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H-%M'),
    'createdAt': datetime.now(timezone.utc).isoformat(),
    'providers': providers,
}

Path(out).parent.mkdir(parents=True, exist_ok=True)
Path(out).write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n',
                     encoding='utf-8')
print(f"  MANIFEST: {sum(len(v['files']) for v in providers.values())} 个文件")
PY
}

# ---------------------------------------------------------------------------
# 比对：与上一次快照的 MANIFEST 比较
# ---------------------------------------------------------------------------
cmd_diff() {
    log "比对快照变化"

    local new_manifest="$OUT/MANIFEST.new.json"
    build_manifest "$new_manifest"

    # 取上一次的 MANIFEST（从 Release 下载，或本地缓存）
    local old_manifest="$OUT/MANIFEST.prev.json"
    if [ ! -f "$old_manifest" ]; then
        warn "无上一次 MANIFEST，视为首次快照"
        echo "CHANGED=true" > "$OUT/changed.env"
        return 0
    fi

    python3 - "$old_manifest" "$new_manifest" "$OUT/changed.env" <<'PY'
import json, sys
from pathlib import Path

old_p, new_p, out_p = sys.argv[1:4]
old = json.loads(Path(old_p).read_text(encoding='utf-8'))
new = json.loads(Path(new_p).read_text(encoding='utf-8'))

changed = []
for prov, data in new.get('providers', {}).items():
    old_files = old.get('providers', {}).get(prov, {}).get('files', {})
    for rel, meta in data.get('files', {}).items():
        old_sha = old_files.get(rel, {}).get('sha256')
        if old_sha != meta['sha256']:
            changed.append(f"{prov}/{rel}")

if changed:
    print(f"  变化: {len(changed)} 个文件")
    for c in changed[:10]:
        print(f"    - {c}")
    if len(changed) > 10:
        print(f"    … 另有 {len(changed)-10} 个")
    Path(out_p).write_text("CHANGED=true\n", encoding='utf-8')
else:
    print("  无变化")
    Path(out_p).write_text("CHANGED=false\n", encoding='utf-8')
PY
}

cmd_pack() {
    log "打包快照"

    rm -rf "$OUT"
    mkdir -p "$OUT"

    build_manifest "$OUT/MANIFEST.json"

    # 打包（保留目录结构）
    tar czf "$OUT/snapshots.tar.gz" -C "$WORK" a b c 2>/dev/null

    local size
    size=$(stat -c%s "$OUT/snapshots.tar.gz")
    ok "snapshots.tar.gz: $((size / 1024 / 1024)) MB"

    # 更新 prev 用于下次比对
    cp "$OUT/MANIFEST.json" "$OUT/MANIFEST.prev.json" 2>/dev/null || true
}

cmd_publish() {
    log "发布 Release"

    if [ ! -f "$OUT/changed.env" ]; then
        warn "未运行 diff，跳过"
        return 0
    fi

    # shellcheck disable=SC1090
    . "$OUT/changed.env"

    if [ "${CHANGED:-false}" != "true" ]; then
        ok "内容无变化，不创建 Release"
        return 0
    fi

    local sid tag
    sid=$(python3 -c "import json;print(json.load(open('$OUT/MANIFEST.json'))['snapshotId'])")
    tag="snap-$sid"

    if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
        warn "Release $tag 已存在，跳过"
        return 0
    fi

    gh release create "$tag" \
        --repo "$REPO" \
        --title "Snapshot $sid" \
        --notes "自动快照 $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$OUT/snapshots.tar.gz" \
        "$OUT/MANIFEST.json"
    ok "已发布 $tag"
}

# ---------------------------------------------------------------------------
# 保留策略：7 天内全留 / 7-30 天每天 1 份 / 30 天以上每周 1 份
# ---------------------------------------------------------------------------
cmd_prune() {
    log "清理过期快照"

    local tags
    tags=$(gh release list --repo "$REPO" --limit 500 \
               --json tagName,createdAt \
               --jq '.[] | "\(.tagName) \(.createdAt)"' 2>/dev/null || true)

    if [ -z "$tags" ]; then
        warn "无快照可清理"
        return 0
    fi

    python3 - "$REPO" <<'PY' <<<"$tags"
import subprocess, sys
from datetime import datetime, timezone, timedelta

repo = sys.argv[1]
now = datetime.now(timezone.utc)

rows = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    tag, created = line.split(' ', 1)
    ts = datetime.fromisoformat(created.replace('Z', '+00:00'))
    rows.append((tag, ts))

rows.sort(key=lambda x: x[1], reverse=True)

keep = set()
daily_seen = set()
weekly_seen = set()

for tag, ts in rows:
    age_days = (now - ts).days
    if age_days <= 7:
        keep.add(tag)                       # 7 天内全留
    elif age_days <= 30:
        day = ts.strftime('%Y-%m-%d')
        if day not in daily_seen:           # 每天 1 份
            daily_seen.add(day)
            keep.add(tag)
    else:
        week = ts.strftime('%Y-W%W')
        if week not in weekly_seen:         # 每周 1 份
            weekly_seen.add(week)
            keep.add(tag)

deleted = 0
for tag, _ in rows:
    if tag in keep:
        continue
    r = subprocess.run(
        ['gh', 'release', 'delete', tag, '--repo', repo, '--yes'],
        capture_output=True, text=True)
    if r.returncode == 0:
        deleted += 1
    else:
        print(f"  删除失败 {tag}: {r.stderr.strip()[:80]}")

print(f"  保留 {len(keep)} 份，删除 {deleted} 份")
PY
}

cmd_all() {
    cmd_fetch
    cmd_diff
    cmd_pack
    cmd_publish
    cmd_prune
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    fetch)   cmd_fetch ;;
    diff)    cmd_diff ;;
    pack)    cmd_pack ;;
    publish) cmd_publish ;;
    prune)   cmd_prune ;;
    all)     cmd_all ;;
    *)
        cat <<EOF
用法: bash snapshot.sh <command>

  fetch     拉取所有上游到 work/
  diff      比对与上次快照的差异
  pack      打包成 snapshots.tar.gz + MANIFEST.json
  publish   创建 GitHub Release
  prune     按保留策略清理
  all       全部执行

环境变量: SRC_RULES / SRC_SAKURA / SRC_UPSTREAM_C
EOF
        exit 1
        ;;
esac
