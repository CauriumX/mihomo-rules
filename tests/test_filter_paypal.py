"""filter-paypal-phish.py 的单元测试

重点覆盖审计发现的缺陷：
  - ppaypal.com 白名单与钓鱼正则冲突（曾静默走代理）
  - keep / pattern_reject 冲突必须报错而非静默取其一
  - MX 无记录不能当作钓鱼信号
"""

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))
import importlib.util

spec = importlib.util.spec_from_file_location(
    'filter_paypal', Path(__file__).parent.parent / 'filter-paypal-phish.py'
)
fp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fp)

FILTERS = fp.Filters(Path(__file__).parent.parent / 'filters' / 'paypal.yaml')


def classify(domain, rtype='DOMAIN-SUFFIX'):
    kind, reason = fp.classify(f'{rtype},{domain}', FILTERS)
    return kind, reason


class TestKeepPriority:
    def test_ppaypal_is_kept_despite_matching_pattern(self):
        """ppaypal.com 曾被 ^ppaypal\\. 正则误判 —— keep 必须优先"""
        kind, reason = classify('ppaypal.com')
        assert kind == 'clean'
        assert reason == 'keep'

    def test_official_domains_kept(self):
        for d in ('paypal.com', 'paypal.me', 'paypalobjects.com', 'paypalcorp.com'):
            kind, _ = classify(d)
            assert kind == 'clean', f'{d} 应放行'

    def test_keep_overrides_pattern_explicitly(self):
        """keep 列表里任何命中 pattern_reject 的条目都应被放行"""
        for d in FILTERS.keep:
            kind, reason = classify(d)
            assert kind == 'clean', f'{d} 在 keep 中却被判 {kind}'
            assert reason == 'keep'


class TestReject:
    def test_explicit_rejects(self):
        for d in ('pa9pal.com', 'paypa1.com', 'payppal.com', 'paypal-secure.net'):
            kind, _ = classify(d)
            assert kind == 'phish', f'{d} 应拦截'

    def test_pattern_rejects(self):
        """不在 reject 列表但命中 pattern 的也应拦截"""
        kind, reason = classify('paypa1.example')
        assert kind == 'phish'
        assert reason.startswith('pattern:')

    def test_briantree_typo(self):
        kind, _ = classify('briantreepayments.net')
        assert kind == 'phish'


class TestReview:
    def test_review_entries_are_kept(self):
        """review 段默认保留，不拦截"""
        for d in FILTERS.review:
            kind, reason = classify(d)
            assert kind == 'clean', f'{d} 在 review 中却被判 {kind}'
            assert reason == 'review'

    def test_no_mx_is_not_a_phishing_signal(self):
        """无 MX 的 typo 变体走 review 而非 reject —— MX 只能证真不能证伪"""
        for d in ('paypall.com', 'paypaly.com', 'paypali.net'):
            kind, reason = classify(d)
            assert kind == 'clean'
            assert reason == 'review'


class TestConsistency:
    def test_no_keep_pattern_conflict(self):
        """规则文件本身不能有 keep / pattern_reject 冲突"""
        assert FILTERS.conflicts() == []

    def test_check_rules_passes(self):
        assert fp.check_rules(FILTERS) == []

    def test_keep_reject_disjoint(self):
        assert FILTERS.keep & FILTERS.reject == set()

    def test_review_disjoint_from_keep_and_reject(self):
        assert FILTERS.review & FILTERS.keep == set()
        assert FILTERS.review & FILTERS.reject == set()


class TestConflictDetection:
    def test_detects_keep_pattern_conflict(self, tmp_path):
        """构造一个冲突的规则文件，check_rules 必须报错"""
        bad = tmp_path / 'bad.yaml'
        bad.write_text(
            'keep:\n'
            '  - domain: ppaypal.com\n'
            '    why: test\n'
            'pattern_reject:\n'
            "  - pattern: '^ppaypal\\.'\n"
            '    why: test\n',
            encoding='utf-8',
        )
        f = fp.Filters(bad)
        errors = fp.check_rules(f)
        assert len(errors) == 1
        assert 'ppaypal.com' in errors[0]

    def test_detects_keep_reject_overlap(self, tmp_path):
        bad = tmp_path / 'bad.yaml'
        bad.write_text(
            'keep:\n  - domain: a.com\n    why: t\n'
            'reject:\n  - domain: a.com\n    why: t\n',
            encoding='utf-8',
        )
        errors = fp.check_rules(fp.Filters(bad))
        assert any('keep 与 reject' in e for e in errors)


class TestEdgeCases:
    def test_comments_skipped(self):
        assert fp.classify('# comment', FILTERS)[0] == 'skip'

    def test_empty_skipped(self):
        assert fp.classify('', FILTERS)[0] == 'skip'

    def test_malformed_skipped(self):
        assert fp.classify('no-comma-here', FILTERS)[0] == 'skip'

    def test_unknown_domain_defaults_to_clean(self):
        """保守策略：宁可漏拦，不可误伤"""
        kind, reason = classify('some-random-site.com')
        assert kind == 'clean'
        assert reason == 'default'
