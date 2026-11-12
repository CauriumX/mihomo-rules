#!/usr/bin/env python3
"""
check-overlap.py — 校验规则集重叠是否都已显式声明

问题：
  模板的 rules: 段按顺序匹配，先命中者生效。两个规则集有交集时，
  排在前面的静默遮蔽后面的。任何人重排 rules 都会改变分流结果，
  而 CI 看不出来。

本脚本做两件事：
  1. 解码全部 .mrs，计算两两交集
  2. 与 ruleset/precedence.yaml 的 allowed_overlap 比对
     - 未声明的重叠 → 失败
     - 声明了但实际无重叠 → 警告（要求删除过期声明）

用法：
  python3 tools/check-overlap.py [--ruleset-dir ruleset] [--precedence ruleset/precedence.yaml]

  --decode-cache <dir>   复用已解码的文本（省去重复解码）

依赖：mihomo（用于解码 mrs）

退出码：
  0 = 全部重叠已声明
  1 = 存在未声明的重叠
  2 = 环境问题（缺 mihomo / 缺文件）
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    print('错误: 需要 PyYAML（pip install pyyaml）', file=sys.stderr)
    sys.exit(2)


def decode_mrs(mihomo, mrs_path, behavior, out_path):
    """把 mrs 解码为纯文本，返回条目集合"""
    r = subprocess.run(
        [mihomo, 'convert-ruleset', behavior, 'mrs', str(mrs_path), str(out_path)],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise RuntimeError(f'解码失败 {mrs_path}: {r.stderr.strip()}')

    entries = set()
    for line in out_path.read_text(encoding='utf-8', errors='ignore').splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        # mrs 解码后是裸值（域名或 CIDR），统一小写去前导 +.
        entries.add(line.lstrip('+.').lower())
    return entries


def load_ruleset_sets(mihomo, ruleset_dir, cache_dir):
    """加载全部规则集，返回 {name: set}"""
    sets = {}

    # 域名类
    for f in sorted((ruleset_dir / 'site').glob('*.mrs')):
        name = f.stem
        sets[name] = decode_mrs(mihomo, f, 'domain', cache_dir / f'{name}.txt')

    # Crypto / PayPal 是纯文本
    for name in ('Crypto', 'PayPal'):
        p = ruleset_dir / f'{name}.txt'
        if not p.exists():
            continue
        entries = set()
        for line in p.read_text(encoding='utf-8', errors='ignore').splitlines():
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split(',')
            if len(parts) >= 2:
                entries.add(parts[1].strip().lower())
        sets[name] = entries

    # IP 类不参与域名重叠分析（行为不同）
    return sets


def find_overlaps(sets):
    """两两求交，返回 {(a, b): count}，a < b 字典序"""
    names = sorted(sets)
    out = {}
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            n = len(sets[a] & sets[b])
            if n:
                out[(a, b)] = n
    return out


def normalize_pair(a, b):
    return tuple(sorted((a, b)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ruleset-dir', default='ruleset')
    ap.add_argument('--precedence', default='ruleset/precedence.yaml')
    ap.add_argument('--mihomo', default='mihomo')
    ap.add_argument('--verbose', '-v', action='store_true')
    args = ap.parse_args()

    ruleset_dir = Path(args.ruleset_dir)
    prec_path = Path(args.precedence)

    if not prec_path.exists():
        print(f'错误: 找不到 {prec_path}', file=sys.stderr)
        sys.exit(2)

    prec = yaml.safe_load(prec_path.read_text(encoding='utf-8'))
    declared = {
        normalize_pair(*e['pair'])
        for e in prec.get('allowed_overlap') or []
    }

    with tempfile.TemporaryDirectory() as tmp:
        try:
            sets = load_ruleset_sets(args.mihomo, ruleset_dir, Path(tmp))
        except FileNotFoundError:
            print(f'错误: 找不到 mihomo 命令（{args.mihomo}）', file=sys.stderr)
            print('  安装：https://github.com/MetaCubeX/mihomo/releases', file=sys.stderr)
            sys.exit(2)
        except RuntimeError as e:
            print(f'错误: {e}', file=sys.stderr)
            sys.exit(2)

    actual = find_overlaps(sets)

    print(f'  规则集: {len(sets)} 个，共 {sum(len(s) for s in sets.values())} 条')
    print(f'  实际重叠: {len(actual)} 组')
    print(f'  已声明:   {len(declared)} 组')
    print()

    undeclared = {k: v for k, v in actual.items() if k not in declared}
    stale = declared - set(actual)

    if undeclared:
        print('未声明的重叠（会静默遮蔽，必须补声明）:', file=sys.stderr)
        for (a, b), n in sorted(undeclared.items(), key=lambda x: -x[1]):
            print(f'  ✗ {a} ∩ {b} = {n} 条', file=sys.stderr)
            if args.verbose:
                sample = sorted(sets[a] & sets[b])[:5]
                print(f'      例: {sample}', file=sys.stderr)

    if stale:
        print('已声明但实际无重叠（应删除过期声明）:', file=sys.stderr)
        for a, b in sorted(stale):
            print(f'  ⚠ {a} ∩ {b} = 0', file=sys.stderr)

    if undeclared:
        sys.exit(1)

    if stale:
        print()
        print('  ⚠ 有过期声明，但不阻断构建')

    print('  OK  全部重叠已显式声明')
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
