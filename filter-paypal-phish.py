#!/usr/bin/env python3
"""
filter-paypal-phish.py — 从 PayPal 规则集中分离钓鱼域名

判定依据不写在代码里，写在 filters/paypal.yaml —— 这样每次变更都能被
git diff 看见，而不是藏在正则里。

三档语义（优先级从高到低）：
  keep     显式保留，即使命中 pattern_reject 也放行
  reject   显式拦截，进 PayPal-Phish.txt
  review   待人工确认，默认保留但每次构建打印提醒

判定顺序：
  1. keep 命中          → clean
  2. reject 命中        → phish
  3. pattern_reject 命中 → phish
  4. review 命中        → clean（并打印提醒）
  5. 其余               → clean（保守：宁可漏拦，不可误伤）

关键约束：
  keep 与 pattern_reject 冲突时直接报错退出，不静默取其一。
  这是 0.2.4 之前 ppaypal.com 走代理的根因 —— 白名单有它，
  钓鱼正则也匹配它，代码里白名单优先，没人发现。

关于 MX 判据（重要）：
  MX 只能证真，不能证伪。
    MX = mx1.paypalcorp.com  → 官方（可证真）
    MX = bh.markmonitor.com  → 官方已收购保护（可证真）
    MX = 无                  → 不能证伪

  实测 PayPal.txt 中 191 条官方域名，其中 92 条无 MX ——
  官方子品牌域名通常不做邮件服务，无 MX 是正常的。
  因此「无 MX」不是钓鱼信号，只是「需要人工复核」的信号。

用法：
  python3 filter-paypal-phish.py <PayPal.txt> <phish输出> <clean输出>
  python3 filter-paypal-phish.py <PayPal.txt> <phish输出> <clean输出> --check

  --check  只校验规则文件自身一致性，不处理输入

退出码：
  0 = 成功
  1 = 参数错误 / 文件缺失
  2 = 规则文件存在冲突（keep 与 pattern_reject 同时命中）
"""

import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print('错误: 需要 PyYAML（pip install pyyaml）', file=sys.stderr)
    sys.exit(1)

DEFAULT_FILTERS = Path(__file__).parent / 'filters' / 'paypal.yaml'


class Filters:
    """filters/paypal.yaml 的运行时表示"""

    def __init__(self, path):
        with open(path, encoding='utf-8') as f:
            data = yaml.safe_load(f)

        self.keep = {e['domain'].lower() for e in data.get('keep') or []}
        self.reject = {e['domain'].lower() for e in data.get('reject') or []}
        self.review = {e['domain'].lower() for e in data.get('review') or []}
        self.patterns = [
            (re.compile(e['pattern'], re.I), e['pattern'])
            for e in data.get('pattern_reject') or []
        ]

    def match_pattern(self, value):
        """返回命中的模式字符串，未命中返回 None"""
        for rx, src in self.patterns:
            if rx.match(value):
                return src
        return None

    def conflicts(self):
        """keep 与 pattern_reject 同时命中的条目"""
        out = []
        for d in self.keep:
            pat = self.match_pattern(d)
            if pat:
                out.append((d, pat))
        return out

    def review_hits(self):
        """review 段中实际会被保留的条目"""
        return sorted(self.review)


def classify(line, filters):
    """返回 ('phish' | 'clean' | 'skip', 原因)"""
    line = line.strip()
    if not line or line.startswith('#'):
        return 'skip', None

    parts = line.split(',')
    if len(parts) < 2:
        return 'skip', None

    value = parts[1].strip().lower()

    # 1. keep 最高优先级
    if value in filters.keep:
        return 'clean', 'keep'

    # 2. reject 显式拦截
    if value in filters.reject:
        return 'phish', 'reject'

    # 3. pattern_reject 正则兜底
    pat = filters.match_pattern(value)
    if pat:
        return 'phish', f'pattern:{pat}'

    # 4. review 保留但提醒
    if value in filters.review:
        return 'clean', 'review'

    # 5. 其余保守放行
    return 'clean', 'default'


def check_rules(filters):
    """校验规则文件自身一致性，返回错误列表"""
    errors = []

    for domain, pat in filters.conflicts():
        errors.append(
            f'keep 与 pattern_reject 冲突: {domain} 命中 {pat}'
            f'  → 请从 keep 删除，或调整 pattern_reject'
        )

    # keep / reject 不应有交集
    overlap = filters.keep & filters.reject
    if overlap:
        errors.append(f'keep 与 reject 同时包含: {sorted(overlap)}')

    # review 不应与 keep / reject 重复
    dup_keep = filters.review & filters.keep
    if dup_keep:
        errors.append(f'review 与 keep 重复（应只留一处）: {sorted(dup_keep)}')
    dup_reject = filters.review & filters.reject
    if dup_reject:
        errors.append(f'review 与 reject 重复（应只留一处）: {sorted(dup_reject)}')

    return errors


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    check_only = '--check' in sys.argv

    filters_path = DEFAULT_FILTERS
    if check_only:
        if len(args) > 1:
            print(__doc__)
            sys.exit(1)
        if args:
            filters_path = args[0]
    elif len(args) != 3:
        print(__doc__)
        sys.exit(1)

    try:
        filters = Filters(filters_path)
    except FileNotFoundError:
        print(f'错误: 规则文件不存在 {filters_path}', file=sys.stderr)
        sys.exit(1)

    # 规则自身一致性检查 —— 任何情况下都先做
    errors = check_rules(filters)
    if errors:
        print('规则文件存在冲突:', file=sys.stderr)
        for e in errors:
            print(f'  ✗ {e}', file=sys.stderr)
        sys.exit(2)

    if check_only:
        print(f'  OK  规则文件一致（keep {len(filters.keep)} / '
              f'reject {len(filters.reject)} / '
              f'review {len(filters.review)} / '
              f'pattern {len(filters.patterns)}）')
        if filters.review:
            print(f'  ⚠  {len(filters.review)} 条待人工确认:')
            for d in filters.review_hits():
                print(f'       {d}')
        sys.exit(0)

    src, phish_out, clean_out = args

    phish, clean, skipped = [], [], 0
    reasons = {'keep': 0, 'reject': 0, 'review': 0, 'default': 0}
    pattern_hits = 0

    with open(src, encoding='utf-8', errors='ignore') as f:
        for raw in f:
            kind, reason = classify(raw, filters)
            if kind == 'skip':
                skipped += 1
            elif kind == 'phish':
                phish.append(raw.strip())
                if reason == 'reject':
                    reasons['reject'] += 1
                else:
                    pattern_hits += 1
            else:
                clean.append(raw.strip())
                reasons[reason] = reasons.get(reason, 0) + 1

    with open(phish_out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# NAME: PayPal-Phish\n')
        f.write('# DESC: PayPal 钓鱼/仿冒域名，建议 REJECT\n')
        f.write('# FILTERED: 从上游 PayPal 规则集筛选\n')
        f.write('# WARNING: 不含 paypal.com 等官方域名，可安全拦截\n')
        f.write(f'# TOTAL: {len(phish)}\n')
        for r in phish:
            f.write(r + '\n')

    with open(clean_out, 'w', encoding='utf-8', newline='\n') as f:
        f.write('# NAME: PayPal\n')
        f.write('# DESC: PayPal 官方域名（已剔除钓鱼站）\n')
        f.write('# FILTERED: 从上游 PayPal 规则集筛选\n')
        f.write(f'# TOTAL: {len(clean)}\n')
        for r in clean:
            f.write(r + '\n')

    print(f'  源文件   : {len(phish) + len(clean)} 条（跳过 {skipped} 行注释）')
    print(f'  钓鱼拦截 : {len(phish)} 条 '
          f'(显式 {reasons["reject"]} + 正则 {pattern_hits})')
    print(f'  官方放行 : {len(clean)} 条 '
          f'(keep {reasons["keep"]} + review {reasons["review"]} + 默认 {reasons["default"]})')

    if reasons['review']:
        print(f'  ⚠  {reasons["review"]} 条来自 review 段，待人工确认')


if __name__ == '__main__':
    main()
