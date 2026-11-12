import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
    NODE_NAME_PATTERN,
    FLAG_PATTERN,
    extractProxyNames,
    checkNodeName,
    checkNodeNames,
    detectKnownPrefix,
} from '../tools/check-node-names.mjs';

const SAMPLE = `port: 7890
proxies:
  - name: A100-US-DMC-LAX-01
    type: vless
    server: 1.2.3.4
  - name: B200-US-OCI-SJC-01
    type: vless
    server: 1.2.3.5
proxy-groups:
  - name: Main
    type: select
`;

test('extractProxyNames 只取 proxies 段，遇到下一个顶层键停止', () => {
    const names = extractProxyNames(SAMPLE);
    assert.deepEqual(names, ['A100-US-DMC-LAX-01', 'B200-US-OCI-SJC-01']);
});

test('extractProxyNames 去掉 YAML 引号', () => {
    const yaml = `proxies:
  - name: "A100-US-DMC-LAX-01"
  - name: 'B200-US-OCI-SJC-01'
`;
    assert.deepEqual(extractProxyNames(yaml), ['A100-US-DMC-LAX-01', 'B200-US-OCI-SJC-01']);
});

test('extractProxyNames 空 proxies 返回空数组', () => {
    assert.deepEqual(extractProxyNames('proxies: []\nproxy-groups: []\n'), []);
});

test('合规命名通过', () => {
    for (const n of [
        'A100-US-DMC-LAX-01',
        'B200-US-OCI-SJC-05',
        'C300-DE-NCG-NUE-01',
        'E500-AU-AWS-SYD-03',
        'F600-HK-ZTN-HKG-02',
        'G700-US-CLO-IAD-01',
    ]) {
        const r = checkNodeName(n);
        assert.ok(r.ok, `${n} 应通过，实际: ${r.problems.join('; ')}`);
        assert.ok(NODE_NAME_PATTERN.test(n));
    }
});

test('带国旗的命名被拒绝', () => {
    const r = checkNodeName('🇺🇸A100-US-DMC-LAX-01');
    assert.equal(r.ok, false);
    assert.match(r.problems.join(), /国旗/);
    assert.ok(FLAG_PATTERN.test('🇺🇸A100-US-DMC-LAX-01'));
});

test('地区前置的命名被拒绝，且诊断指向机型位置', () => {
    const r = checkNodeName('US-A100-DMC-LAX-01');
    assert.equal(r.ok, false);
    assert.match(r.problems.join(), /地区代码在前/);
});

test('机型不在开头被拒绝', () => {
    const r = checkNodeName('LAX-A100-US-DMC-01');
    assert.equal(r.ok, false);
    assert.match(r.problems.join(), /机型不在开头/);
});

test('替换串未展开的 $6 残留被拒绝', () => {
    // 真实事故：正则只有 5 个捕获组却写 $6，JS 原样输出字面量
    const r = checkNodeName('US-DMC-LAX-01-$6');
    assert.equal(r.ok, false);
});

test('checkNodeName 解析出各字段', () => {
    const r = checkNodeName('A100-US-DMC-LAX-01');
    assert.deepEqual(r.parts, {
        model: 'A100',
        region: 'US',
        facility: 'DMC',
        city: 'LAX',
        index: '01',
    });
});

test('重名被检出', () => {
    const r = checkNodeNames(['A100-US-DMC-LAX-01', 'A100-US-DMC-LAX-01']);
    assert.equal(r.ok, false);
    assert.equal(r.duplicates.length, 1);
    assert.match(r.duplicates[0], /×2/);
});

test('排序收敛时 orderMismatch 为 false', () => {
    const names = [
        'A100-US-DMC-LAX-01',
        'B200-US-OCI-SJC-01',
        'C300-DE-NCG-NUE-01',
        'G700-US-CLO-IAD-01',
    ];
    const r = checkNodeNames(names);
    assert.equal(r.orderMismatch, false);
    assert.equal(r.ok, true);
});

test('排序不收敛时 orderMismatch 为 true', () => {
    const names = ['B200-US-OCI-SJC-01', 'A100-US-DMC-LAX-01'];
    const r = checkNodeNames(names);
    assert.equal(r.orderMismatch, true);
    assert.equal(r.ok, false);
    assert.deepEqual(r.sorted, ['A100-US-DMC-LAX-01', 'B200-US-OCI-SJC-01']);
});

test('带国旗的节点会同时触发格式与排序两条告警', () => {
    const names = ['🇦🇺E500-AU-AWS-SYD-01', 'A100-US-DMC-LAX-01'];
    const r = checkNodeNames(names);
    assert.equal(r.ok, false);
    assert.equal(r.orderMismatch, true); // 国旗字节序把 E500 排到最前
    assert.equal(r.entries[0].ok, false);
});

// ---- 已知前缀诊断 ----------------------------------------------------------

test('detectKnownPrefix 识别「手动节点 - 」前缀', () => {
    const r = detectKnownPrefix('手动节点 - D400-US-OCI-SJC-01');
    assert.ok(r);
    assert.match(r.prefix, /手动节点/);
    assert.match(r.hint, /enableManualNodes/);
});

test('detectKnownPrefix 兼容不同破折号与空格', () => {
    for (const n of [
        '手动节点 - D400-US-OCI-SJC-01',
        '手动节点-D400-US-OCI-SJC-01',
        '手动节点 — D400-US-OCI-SJC-01',
        '手动节点  –  D400-US-OCI-SJC-01',
    ]) {
        assert.ok(detectKnownPrefix(n), `应识别: ${n}`);
    }
});

test('detectKnownPrefix 识别 prependGroupName 序号前缀', () => {
    const r = detectKnownPrefix('1. D400-US-OCI-SJC-01');
    assert.ok(r);
    assert.match(r.hint, /prependGroupName/);
});

test('detectKnownPrefix 对合规名返回 null', () => {
    assert.equal(detectKnownPrefix('A100-US-DMC-LAX-01'), null);
    assert.equal(detectKnownPrefix('🇺🇸A100-US-DMC-LAX-01'), null);
});

test('带前缀时诊断指向开关，而非笼统的「机型不在开头」', () => {
    const r = checkNodeName('手动节点 - D400-US-OCI-SJC-01');
    assert.equal(r.ok, false);
    const msg = r.problems.join();
    assert.match(msg, /enableManualNodes/);
    assert.doesNotMatch(msg, /机型不在开头/);
    assert.ok(r.prefix);
});

test('无前缀的格式错误仍报位置问题', () => {
    const r = checkNodeName('US-A100-DMC-LAX-01');
    assert.equal(r.ok, false);
    assert.match(r.problems.join(), /地区代码在前/);
    assert.equal(r.prefix, null);
});

test('真实事故：Canton 全组带前缀被整体判定', () => {
    const names = [1, 2, 3, 4].map((i) => `手动节点 - D400-US-OCI-SJC-0${i}`);
    const r = checkNodeNames(names);
    assert.equal(r.ok, false);
    assert.ok(r.entries.every((e) => e.prefix), '每条都应识别出前缀');
    assert.ok(r.entries.every((e) => /enableManualNodes/.test(e.problems.join())));
});
