import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { loadRegistry, checkRef, locate } from '../tools/check-doc-refs.mjs';

/** 造一个只读文件映射，模拟 readFile */
function reader(files) {
    return (rel) => (rel in files ? files[rel] : null);
}

const SAMPLE = `line one
line two
	slices.Sort(AllProxies)
line four
line five
`;

test('checkRef 单行命中', () => {
    const r = checkRef({ file: 'a.go', line: 3, expect: 'slices.Sort(AllProxies)' }, reader({ 'a.go': SAMPLE }));
    assert.equal(r.ok, true);
});

test('checkRef 单行未命中时给出实际内容', () => {
    const r = checkRef({ file: 'a.go', line: 2, expect: 'slices.Sort' }, reader({ 'a.go': SAMPLE }));
    assert.equal(r.ok, false);
    assert.match(r.reason, /L2 不含/);
    assert.match(r.actual, /L2: line two/);
});

test('checkRef 用子串匹配，忽略缩进与尾随空格', () => {
    // 源码有 tab 缩进，expect 不带缩进也应命中
    const r = checkRef({ file: 'a.go', line: 3, expect: 'slices.Sort(AllProxies)' }, reader({ 'a.go': SAMPLE }));
    assert.equal(r.ok, true);
});

test('checkRef 行号超出范围', () => {
    const r = checkRef({ file: 'a.go', line: 99, expect: 'x' }, reader({ 'a.go': SAMPLE }));
    assert.equal(r.ok, false);
    assert.match(r.reason, /超出文件范围/);
});

test('checkRef 文件不存在', () => {
    const r = checkRef({ file: 'missing.go', line: 1, expect: 'x' }, reader({}));
    assert.equal(r.ok, false);
    assert.match(r.reason, /文件不存在/);
});

test('checkRef 区间两端都命中', () => {
    const src = `func Foo() {
	body
}
`;
    const r = checkRef(
        { file: 'a.go', range: [1, 3], expectStart: 'func Foo(', expectEnd: '}' },
        reader({ 'a.go': src })
    );
    assert.equal(r.ok, true);
});

test('checkRef 区间起点不匹配', () => {
    const src = `func Foo() {
	body
}
`;
    const r = checkRef(
        { file: 'a.go', range: [1, 3], expectStart: 'func Bar(', expectEnd: '}' },
        reader({ 'a.go': src })
    );
    assert.equal(r.ok, false);
    assert.match(r.reason, /L1 不含 "func Bar\("/);
});

test('checkRef 区间终点不匹配', () => {
    const src = `func Foo() {
	body
	more
}
`;
    const r = checkRef(
        { file: 'a.go', range: [1, 3], expectStart: 'func Foo(', expectEnd: '}' },
        reader({ 'a.go': src })
    );
    assert.equal(r.ok, false);
    assert.match(r.reason, /L3 不含 "}"/);
});

test('checkRef 区间超出文件范围', () => {
    const r = checkRef(
        { file: 'a.go', range: [1, 99], expectStart: 'x', expectEnd: 'y' },
        reader({ 'a.go': SAMPLE })
    );
    assert.equal(r.ok, false);
    assert.match(r.reason, /超出文件范围/);
});

test('locate 给出内容实际所在行号', () => {
    // 真实场景：文档写 L893，实际在 L892
    const hits = locate({ file: 'a.go', expect: 'slices.Sort(AllProxies)' }, reader({ 'a.go': SAMPLE }));
    assert.deepEqual(hits, [3]);
});

test('locate 多处命中时全部返回', () => {
    const src = `foo
foo
bar
`;
    const hits = locate({ file: 'a.go', expect: 'foo' }, reader({ 'a.go': src }));
    assert.deepEqual(hits, [1, 2]);
});

test('locate 内容不存在返回 null', () => {
    const hits = locate({ file: 'a.go', expect: 'nonexistent' }, reader({ 'a.go': SAMPLE }));
    assert.equal(hits, null);
});

test('loadRegistry 读真实登记表', () => {
    const reg = loadRegistry();
    // refs 可以为空：节点排序与模板格式的实证引用随文档迁到了
    // mihomo-template 仓库，本仓库只保留规则集构建相关的引用。
    assert.ok(Array.isArray(reg.local.refs), 'local.refs 应为数组');
    assert.ok(Array.isArray(reg.external.refs), 'external.refs 应为数组');
});

test('loadRegistry 每条引用都有必要字段', () => {
    const reg = loadRegistry();
    for (const ref of [...reg.local.refs, ...reg.external.refs]) {
        assert.ok(ref.file, `缺 file: ${JSON.stringify(ref)}`);
        assert.ok(
            Number.isInteger(ref.line) || Array.isArray(ref.range),
            `缺 line 或 range: ${JSON.stringify(ref)}`
        );
        if (Array.isArray(ref.range)) {
            assert.ok(ref.expectStart, `range 引用缺 expectStart: ${JSON.stringify(ref)}`);
            assert.ok(ref.expectEnd, `range 引用缺 expectEnd: ${JSON.stringify(ref)}`);
        } else {
            assert.ok(ref.expect, `line 引用缺 expect: ${JSON.stringify(ref)}`);
        }
    }
});

test('loadRegistry 外部引用都指向已登记的 source', () => {
    const reg = loadRegistry();
    const known = new Set(Object.keys(reg.external.sources).filter((k) => !k.startsWith('_')));
    for (const ref of reg.external.refs) {
        assert.ok(known.has(ref.source), `未登记的 source: ${ref.source}`);
    }
});

test('loadRegistry 登记表损坏时抛错', () => {
    const dir = mkdtempSync(join(tmpdir(), 'refs-'));
    const p = join(dir, 'bad.json');
    writeFileSync(p, '{ not json');
    assert.throws(() => loadRegistry(p), /不是合法 JSON/);
});

test('loadRegistry 缺段时抛错', () => {
    const dir = mkdtempSync(join(tmpdir(), 'refs-'));
    const p = join(dir, 'partial.json');
    writeFileSync(p, JSON.stringify({ local: { refs: [] } }));
    assert.throws(() => loadRegistry(p), /缺少 local \/ external/);
});
