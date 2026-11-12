#!/usr/bin/env node
/**
 * check-doc-refs.mjs — 校验文档里的源码引用（文件/行号/内容）是否仍然成立
 *
 * 背景：
 *   文档里最容易静默漂移的不是业务数字，是**行号引用**。
 *   业务数字改了会有人发现；行号错了没人会去查 ——
 *   2026-11-11 实测：两份文档里有 5 处 mihomo 行号偏差，
 *   最大的一处少算了 85 行（ParseProxyGroup 实际到 L185，文档写 L48-100）。
 *
 *   行号引用一旦失效，读者按图索骥会看到完全无关的代码，
 *   比没有引用更糟：它让人以为已经核实过。
 *
 * 校验方式：
 *   不解析文档里的行号（那是脆弱的正则匹配），而是维护一份**登记表**
 *   tools/doc-refs.json，把每条引用写成可执行断言：
 *
 *     { "file": "...", "line": 892, "expect": "slices.Sort(AllProxies)" }
 *     { "file": "...", "range": [74, 94], "expectStart": "...", "expectEnd": "..." }
 *
 *   登记表与文档分离的好处：文档可以自由改写措辞，校验只关心
 *   「这个文件第 N 行是不是这句话」。
 *
 * 外部源码：
 *   mihomo / MiSub 不在本仓库。CI 里按 pin 的 tag 浅克隆到 .cache/src/，
 *   本地有副本则校验，没有则跳过（不算失败）。
 *
 * 用法：
 *   node tools/check-doc-refs.mjs                  # 校验（缺源码则跳过外部）
 *   node tools/check-doc-refs.mjs --fetch          # 先拉取外部源码再校验
 *   node tools/check-doc-refs.mjs --local-only     # 只校验本仓库内的引用
 *
 * 退出码：
 *   0  全部通过（或外部源码缺失而跳过）
 *   1  发现失效引用
 *   2  登记表缺失/损坏，或 --fetch 失败
 */

import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { argv, exit } from 'node:process';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');
const REGISTRY = join(HERE, 'doc-refs.json');

/** 读登记表 */
export function loadRegistry(path = REGISTRY) {
    if (!existsSync(path)) throw new Error(`登记表不存在: ${path}`);
    let data;
    try {
        data = JSON.parse(readFileSync(path, 'utf8'));
    } catch (e) {
        throw new Error(`登记表不是合法 JSON: ${e.message}`);
    }
    if (!data.local || !data.external) {
        throw new Error('登记表缺少 local / external 段');
    }
    return data;
}

/**
 * 校验单条引用。
 *
 * 两种形态：
 *   · line  —— 单行，expect 必须是该行的子串
 *   · range —— 区间，expectStart 是首行子串，expectEnd 是末行子串
 *
 * 用「子串」而不是「全等」：源码有缩进和尾随空格，
 * 全等比对会被无关的格式差异打回。
 *
 * @returns {{ok: boolean, reason?: string, actual?: string}}
 */
export function checkRef(ref, readFile) {
    const text = readFile(ref.file);
    if (text === null) {
        return { ok: false, reason: `文件不存在: ${ref.file}` };
    }
    const lines = text.split('\n');

    if (Array.isArray(ref.range)) {
        const [start, end] = ref.range;
        if (start < 1 || end > lines.length || start > end) {
            return {
                ok: false,
                reason: `区间 [${start}, ${end}] 超出文件范围（共 ${lines.length} 行）`,
            };
        }
        const first = lines[start - 1] ?? '';
        const last = lines[end - 1] ?? '';
        if (!first.includes(ref.expectStart)) {
            return {
                ok: false,
                reason: `L${start} 不含 "${ref.expectStart}"`,
                actual: `L${start}: ${first.trim()}`,
            };
        }
        if (!last.includes(ref.expectEnd)) {
            return {
                ok: false,
                reason: `L${end} 不含 "${ref.expectEnd}"`,
                actual: `L${end}: ${last.trim()}`,
            };
        }
        return { ok: true };
    }

    const n = ref.line;
    if (!Number.isInteger(n) || n < 1 || n > lines.length) {
        return { ok: false, reason: `行号 ${n} 超出文件范围（共 ${lines.length} 行）` };
    }
    const actual = lines[n - 1] ?? '';
    if (!actual.includes(ref.expect)) {
        return {
            ok: false,
            reason: `L${n} 不含 "${ref.expect}"`,
            actual: `L${n}: ${actual.trim()}`,
        };
    }
    return { ok: true };
}

/**
 * 在文件里搜索期望内容实际所在的行号，用于给出修复建议。
 *
 * 只搜「唯一命中」的情况：多处命中时给出候选，让人自己判断。
 */
export function locate(ref, readFile) {
    const text = readFile(ref.file);
    if (text === null) return null;
    const lines = text.split('\n');
    const needle = ref.expect ?? ref.expectStart;
    if (!needle) return null;
    const hits = [];
    lines.forEach((l, i) => {
        if (l.includes(needle)) hits.push(i + 1);
    });
    return hits.length ? hits : null;
}

/** 确保外部源码在本地有副本 */
export function ensureSource(name, spec, { fetch = false } = {}) {
    const dir = join(ROOT, spec.cacheDir);
    if (existsSync(join(dir, '.git'))) return dir;
    if (!fetch) return null;

    const args = ['clone', '--depth', '1'];
    if (spec.tag) args.push('--branch', spec.tag);
    args.push(spec.repo, dir);

    try {
        execFileSync('git', args, { stdio: 'pipe', encoding: 'utf8' });
        return dir;
    } catch (e) {
        throw new Error(`拉取 ${name} 失败: ${e.message}`);
    }
}

// ---- CLI ----------------------------------------------------------------

function main() {
    const args = argv.slice(2);
    const doFetch = args.includes('--fetch');
    const localOnly = args.includes('--local-only');

    let registry;
    try {
        registry = loadRegistry();
    } catch (e) {
        console.error(`✖ ${e.message}`);
        exit(2);
    }

    const failures = [];
    const skipped = [];
    let checked = 0;

    // ---- 本仓库内的引用 ----
    const localRead = (rel) => {
        const p = join(ROOT, rel);
        return existsSync(p) ? readFileSync(p, 'utf8') : null;
    };

    for (const ref of registry.local.refs) {
        checked += 1;
        const r = checkRef(ref, localRead);
        if (!r.ok) {
            failures.push({ scope: 'local', ref, ...r, hits: locate(ref, localRead) });
        }
    }

    // ---- 外部源码的引用 ----
    if (!localOnly) {
        const dirs = {};
        for (const [name, spec] of Object.entries(registry.external.sources)) {
            if (name.startsWith('_')) continue;
            try {
                dirs[name] = ensureSource(name, spec, { fetch: doFetch });
            } catch (e) {
                console.error(`✖ ${e.message}`);
                exit(2);
            }
        }

        for (const ref of registry.external.refs) {
            const dir = dirs[ref.source];
            if (!dir) {
                skipped.push(ref);
                continue;
            }
            checked += 1;
            const read = (rel) => {
                const p = join(dir, rel);
                return existsSync(p) ? readFileSync(p, 'utf8') : null;
            };
            const r = checkRef(ref, read);
            if (!r.ok) {
                failures.push({ scope: ref.source, ref, ...r, hits: locate(ref, read) });
            }
        }
    }

    // ---- 报告 ----
    console.log(`校验 ${checked} 条源码引用`);

    if (skipped.length) {
        const names = [...new Set(skipped.map((r) => r.source))];
        console.log(
            `· 跳过 ${skipped.length} 条（本地无 ${names.join('/')} 源码副本；` +
                `用 --fetch 拉取，或依赖 CI）`
        );
    }

    if (failures.length === 0) {
        console.log('✓ 全部引用有效');
        exit(0);
    }

    console.log(`\n✖ ${failures.length} 条引用已失效：\n`);
    for (const f of failures) {
        const where = Array.isArray(f.ref.range)
            ? `L${f.ref.range[0]}-${f.ref.range[1]}`
            : `L${f.ref.line}`;
        console.log(`  [${f.scope}] ${f.ref.file}:${where}`);
        console.log(`    ${f.reason}`);
        if (f.actual) console.log(`    实际: ${f.actual}`);
        if (f.hits) {
            console.log(`    该内容现在位于: L${f.hits.join(', L')}`);
        } else {
            console.log(`    该内容在文件中已不存在 —— 上游可能已改写，需重新确认`);
        }
        if (f.ref.docs?.length) {
            console.log(`    引用它的文档: ${f.ref.docs.join(', ')}`);
        }
        console.log('');
    }

    console.log('修正：改 tools/doc-refs.json 里的行号，并同步更新文档。');
    exit(1);
}

if (import.meta.url === `file://${argv[1]}`) {
    main();
}
