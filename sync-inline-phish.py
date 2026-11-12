#!/usr/bin/env python3
"""
sync-inline-phish.py — 把 PayPal-Phish.txt 自动同步进模板的 rules: 段

问题：
  钓鱼规则已内联到模板（省一次 provider 请求），
  但上游更新后需要手动补进模板，容易遗漏。

方案：
  用标记注释包裹内联段，脚本按标记替换，幂等可重复执行。

标记：
  # >>> PAYPAL-PHISH-INLINE (auto-generated, do not edit by hand)
  ...15 条规则...
  # <<< PAYPAL-PHISH-INLINE

用法：
  python3 sync-inline-phish.py <模板.yaml> <PayPal-Phish.txt>

  只检查不写入：
  python3 sync-inline-phish.py <模板.yaml> <PayPal-Phish.txt> --dry-run

退出码：
  0 = 已同步或无需改动
  1 = 参数错误 / 文件缺失
  2 = 模板缺少标记（需先手动加一次标记）
"""

import re
import sys

BEGIN = '  # >>> PAYPAL-PHISH-INLINE (auto-generated, do not edit by hand)'
END = '  # <<< PAYPAL-PHISH-INLINE'

# 匹配整个标记块（含标记行本身），非贪婪
BLOCK_RE = re.compile(
    r'^' + re.escape(BEGIN) + r'\n.*?^' + re.escape(END) + r'$',
    re.MULTILINE | re.DOTALL,
)


def load_rules(path):
    """从 PayPal-Phish.txt 提取 DOMAIN 规则行"""
    rules = []
    with open(path, encoding='utf-8', errors='ignore') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if not line.startswith('DOMAIN'):
                continue
            parts = line.split(',')
            if len(parts) < 2:
                continue
            rules.append((parts[0].strip(), parts[1].strip()))
    return rules


def build_block(rules):
    """生成标记块文本"""
    lines = [
        BEGIN,
        '  # PayPal 钓鱼/仿冒域名（内联，省一次 provider 请求）',
        '  # 判定依据：DNS MX 证据 —— 官方 MX=mx1.paypalcorp.com，',
        '  #          钓鱼站无 MX 或 MX=bh.markmonitor.com（品牌保护商已收购停用）',
        '  # 已校验：不含 paypal.com / paypalobjects.com / paypalinc.com 等官方域名',
        '  # 由 filter-paypal-phish.py 生成，sync-inline-phish.py 注入',
    ]
    for rtype, value in rules:
        lines.append(f'  - "{rtype},{value},REJECT"')
    lines.append(END)
    return '\n'.join(lines)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    dry_run = '--dry-run' in sys.argv

    if len(args) != 2:
        print(__doc__)
        sys.exit(1)

    tpl_path, phish_path = args

    try:
        with open(tpl_path, encoding='utf-8') as f:
            tpl = f.read()
    except FileNotFoundError:
        print(f'错误: 模板不存在 {tpl_path}', file=sys.stderr)
        sys.exit(1)

    try:
        rules = load_rules(phish_path)
    except FileNotFoundError:
        print(f'错误: 钓鱼清单不存在 {phish_path}', file=sys.stderr)
        print('提示: 先运行 bash build-rules.sh paypal', file=sys.stderr)
        sys.exit(1)

    if not rules:
        print(f'错误: {phish_path} 中没有 DOMAIN 规则', file=sys.stderr)
        sys.exit(1)

    new_block = build_block(rules)

    # 安全检查：钓鱼清单绝不能包含官方域名
    OFFICIAL = {
        'paypal.com', 'paypal.me', 'paypalobjects.com', 'paypalinc.com',
        'paypal-biz.com', 'paypalcorp.com', 'paypal-prepaid.com',
        'braintreegateway.com', 'venmo-touch.com', 'xoomcom.com',
        'paypal-community.com', 'paypal-business.com', 'paypal-status.com',
        'paypal-support.com', 'paypal-team.com',
    }
    leaked = {v for _, v in rules} & OFFICIAL
    if leaked:
        print(f'错误: 钓鱼清单含官方域名，拒绝写入: {sorted(leaked)}', file=sys.stderr)
        sys.exit(1)

    if not BLOCK_RE.search(tpl):
        print('错误: 模板中未找到标记块', file=sys.stderr)
        print(f'  需要包含: {BEGIN.strip()}', file=sys.stderr)
        print(f'          : {END.strip()}', file=sys.stderr)
        print('  首次使用请手动把内联段首尾换成这两个标记行。', file=sys.stderr)
        sys.exit(2)

    old_block = BLOCK_RE.search(tpl).group(0)

    if old_block == new_block:
        print(f'  无需改动（{len(rules)} 条已是最新）')
        sys.exit(0)

    # 统计差异
    old_rules = set(re.findall(r'^  - "([^"]+)"$', old_block, re.MULTILINE))
    new_rules = set(re.findall(r'^  - "([^"]+)"$', new_block, re.MULTILINE))
    added = sorted(new_rules - old_rules)
    removed = sorted(old_rules - new_rules)

    print(f'  钓鱼规则: {len(old_rules)} → {len(new_rules)}')
    if added:
        print(f'  新增 {len(added)} 条:')
        for r in added:
            print(f'    + {r}')
    if removed:
        print(f'  移除 {len(removed)} 条:')
        for r in removed:
            print(f'    - {r}')

    if dry_run:
        print('  [dry-run] 未写入')
        sys.exit(0)

    updated = tpl.replace(old_block, new_block, 1)
    with open(tpl_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(updated)

    print(f'  已写入 {tpl_path}')
    sys.exit(0)


if __name__ == '__main__':
    main()
