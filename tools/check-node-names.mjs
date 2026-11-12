#!/usr/bin/env node
/**
 * check-node-names.mjs — 校验节点命名是否符合排序契约
 *
 * 背景：
 *   模板所有组都用 include-all-proxies: true，节点顺序由 mihomo 的
 *   slices.Sort(AllProxies) 按**节点名字节序**决定（config/config.go:892），
 *   与 proxies: 段的声明顺序无关。详见 docs/NODE-ORDERING.md。
 *
 *   也就是说：**排序完全由节点名决定**。命名一旦跑偏，顺序立刻错，
 *   而且不会报错 —— 只会在客户端代理页里静默乱序。这是本脚本要挡的事。
 *
 *   三条命名铁律：
 *     1. 无国旗 emoji —— 国旗首字节 0xF0 > 字母 0x41，会让 🇦🇺 排到最前
 *     2. 机型在前 —— A100/B200/… 是主排序键，放后面就按地区分组了
 *     3. 格式统一 —— 机型-地区-机房-城市-序号，缺字段就无法解析
 *
 * 用法：
 *   node tools/check-node-names.mjs <订阅URL>          # 拉真实订阅校验
 *   node tools/check-node-names.mjs --file sub.yaml    # 校验本地 yaml
 *   node tools/check-node-names.mjs --file sub.yaml --expect 31
 *
 * 环境变量：
 *   MISUB_URL / MISUB_PASSWORD  提供时可用 --profile <customId> 自动拉取
 *
 * 退出码：
 *   0  全部合规
 *   1  发现违规（emoji / 格式 / 重复 / 排序不一致）
 *   2  参数错误或拉取失败
 */

import { readFileSync } from 'node:fs';
import { argv, exit } from 'node:process';

/**
 * 节点名契约：机型-地区-机房-城市-序号
 *
 *   机型  [A-Z]\d{3}       A100 / B200 / C300 / …
 *   地区  [A-Z]{2}         US / DE / AU / HK
 *   机房  [A-Z]{3}         DMC / OCI / NCG / AWS / ZTN / CLO
 *   城市  [A-Z]{3}         LAX / SJC / NUE / SYD / HKG / IAD
 *   序号  \d+              01 / 02 / …
 */
export const NODE_NAME_PATTERN = /^([A-Z]\d{3})-([A-Z]{2})-([A-Z]{3})-([A-Z]{3})-(\d+)$/;

/** 国旗 emoji = 两个 Regional Indicator 符号，码位 U+1F1E6–U+1F1FF */
export const FLAG_PATTERN = /[\u{1F1E6}-\u{1F1FF}]{2}/u;

/** 任意 emoji（含国旗、装饰符号）—— 字节序排序时都会干扰 */
export const ANY_EMOJI_PATTERN = /[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/u;

/**
 * 从 Clash YAML 文本提取 proxies: 段的节点名，保持原顺序。
 *
 * 用逐行扫描而不是 YAML 库：模板和订阅里 proxies 段可能很大，
 * 而且这里只关心 name 字段，不需要完整解析。
 *
 * @param {string} yamlText
 * @returns {string[]}
 */
export function extractProxyNames(yamlText) {
    const names = [];
    let inProxies = false;
    let proxiesIndent = -1;

    for (const line of yamlText.split('\n')) {
        if (!inProxies) {
            const m = line.match(/^(\s*)proxies:\s*$/);
            if (m) {
                inProxies = true;
                proxiesIndent = m[1].length;
            }
            continue;
        }
        if (line.trim() === '') continue;

        const indent = line.match(/^(\s*)/)[1].length;
        if (indent <= proxiesIndent) break;

        const nm = line.match(/^\s*-\s*name:\s*(.+?)\s*$/);
        if (nm) {
            let n = nm[1];
            if ((n.startsWith('"') && n.endsWith('"')) || (n.startsWith("'") && n.endsWith("'"))) {
                n = n.slice(1, -1);
            }
            names.push(n);
        }
    }
    return names;
}

/**
 * 已知的 MiSub 前缀来源。
 *
 * MiSub 在**算子链之前**注入这些前缀（subscription-service.js:722），
 * 所以 rename 正则匹配不到，名字原样进入 sort。命中时直接指向开关，
 * 而不是笼统报「机型不在开头」。
 *
 * 每项：pattern 匹配前缀，hint 告诉人该关哪个开关。
 */
export const KNOWN_PREFIXES = [
    {
        pattern: /^手动节点\s*[-—–]\s*/u,
        hint: 'prefixSettings.enableManualNodes 为 true（manualNodePrefix 为空时回退到「手动节点」）—— 在该订阅组设置里关闭',
    },
    {
        pattern: /^\d+\.\s+/, // MiSub 的 prependGroupName 序号前缀
        hint: 'prefixSettings.prependGroupName 为 true —— 在该订阅组设置里关闭',
    },
    {
        pattern: /^手动节点/u,
        hint: 'prefixSettings.enableManualNodes 为 true —— 在该订阅组设置里关闭',
    },
];

/**
 * 识别节点名开头的已知前缀。
 *
 * @param {string} name
 * @returns {{prefix: string, hint: string}|null}
 */
export function detectKnownPrefix(name) {
    for (const { pattern, hint } of KNOWN_PREFIXES) {
        const m = name.match(pattern);
        if (m) return { prefix: m[0], hint };
    }
    return null;
}

/**
 * 单个节点名的诊断。
 *
 * @param {string} name
 * @returns {{name: string, ok: boolean, problems: string[], parts: object|null, prefix: object|null}}
 */
export function checkNodeName(name) {
    const problems = [];
    const parts = {};

    if (FLAG_PATTERN.test(name)) {
        problems.push('含国旗 emoji（字节序 0xF0 > 0x41，会被排到最前）');
    } else if (ANY_EMOJI_PATTERN.test(name)) {
        problems.push('含 emoji（会干扰字节序排序）');
    }

    const m = name.match(NODE_NAME_PATTERN);
    if (!m) {
        // 先查已知前缀：能直接指向开关，比笼统报位置问题有用得多。
        const known = detectKnownPrefix(name);
        if (known) {
            problems.push(`带前缀「${known.prefix.trim()}」—— ${known.hint}`);
        } else {
            // 给出可操作的诊断，而不是只报"格式错误"。
            // 已含 emoji 时不再叠报位置问题 —— 去掉 emoji 后可能就合规了，
            // 两条一起报会误导人以为要改两处。
            const stripped = name.replace(ANY_EMOJI_PATTERN, '').trim();
            if (problems.length === 0) {
                if (/^[A-Z]{2}-[A-Z]\d{3}-/.test(stripped)) {
                    problems.push('地区代码在前（机型必须在前，否则按地区分组而非按机型）');
                } else if (!/^[A-Z]\d{3}/.test(stripped)) {
                    problems.push('机型不在开头（应为 A100/B200/C300… 这类 [A-Z]\\d{3}）');
                } else {
                    problems.push('不符合 机型-地区-机房-城市-序号 格式');
                }
            }
        }
    } else {
        parts.model = m[1];
        parts.region = m[2];
        parts.facility = m[3];
        parts.city = m[4];
        parts.index = m[5];
    }

    return {
        name,
        ok: problems.length === 0,
        problems,
        parts,
        prefix: detectKnownPrefix(name),
    };
}

/**
 * 校验整组节点名。
 *
 * 除了逐条格式，还检查两件只有看全量才能发现的事：
 *   · 重名 —— mihomo 会拒绝重复节点名，且 store-selected 的 key 会失效
 *   · 排序收敛 —— MiSub 的 localeCompare 与 mihomo 的字节序必须给出同一顺序
 *
 * @param {string[]} names  MiSub 输出的顺序
 * @returns {{ok: boolean, entries: object[], duplicates: string[], orderMismatch: boolean, sorted: string[]}}
 */
export function checkNodeNames(names) {
    const entries = names.map(checkNodeName);

    const seen = new Map();
    const duplicates = [];
    for (const n of names) {
        seen.set(n, (seen.get(n) || 0) + 1);
    }
    for (const [n, c] of seen) {
        if (c > 1) duplicates.push(`${n} ×${c}`);
    }

    // mihomo slices.Sort 对 []string 按 UTF-8 字节序比较
    const sorted = [...names].sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)));
    const orderMismatch = sorted.some((n, i) => n !== names[i]);

    const ok = entries.every((e) => e.ok) && duplicates.length === 0 && !orderMismatch;
    return { ok, entries, duplicates, orderMismatch, sorted };
}

/** 机型序号提取，用于按机型分组展示 */
function modelOf(name) {
    const m = name.match(NODE_NAME_PATTERN);
    return m ? m[1] : '(未匹配)';
}

function printReport(result, expectCount) {
    const { entries, duplicates, orderMismatch, sorted } = result;

    // 按机型分组展示，便于一眼看出分布
    const byModel = new Map();
    for (const e of entries) {
        const k = modelOf(e.name);
        if (!byModel.has(k)) byModel.set(k, []);
        byModel.get(k).push(e);
    }

    console.log(`共 ${entries.length} 个节点\n`);

    // 未匹配的归为一组，不逐条展开（否则 31 个全错时会刷屏）
    const unmatched = byModel.get('(未匹配)');
    if (unmatched) byModel.delete('(未匹配)');

    for (const [model, list] of byModel) {
        const bad = list.filter((e) => !e.ok).length;
        const mark = bad === 0 ? '✓' : '✖';
        console.log(`${mark} ${model}  ${list.length} 个${bad ? `（${bad} 个不合规）` : ''}`);
        for (const e of list) {
            if (!e.ok) {
                console.log(`    ${e.name}`);
                for (const p of e.problems) console.log(`      · ${p}`);
            }
        }
    }

    if (unmatched) {
        // 已知前缀（如「手动节点 - 」）单独成块：直接指向要关的开关，
        // 比笼统的「机型不在开头」有用得多。
        const prefixed = unmatched.filter((e) => e.prefix);
        const others = unmatched.filter((e) => !e.prefix);

        if (prefixed.length) {
            // 按前缀文案分组，同一前缀只报一次
            const byPrefix = new Map();
            for (const e of prefixed) {
                const k = e.prefix.prefix.trim();
                if (!byPrefix.has(k)) byPrefix.set(k, { hint: e.prefix.hint, items: [] });
                byPrefix.get(k).items.push(e);
            }
            for (const [prefix, { hint, items }] of byPrefix) {
                console.log(`✖ 带前缀「${prefix}」  ${items.length} 个`);
                console.log(`    → ${hint}`);
                for (const e of items.slice(0, 2)) console.log(`      ${e.name}`);
                if (items.length > 2) console.log(`      … 还有 ${items.length - 2} 个`);
            }
        }

        if (others.length) {
            // 同类问题只展示前 3 个样本 + 汇总，避免刷屏
            const problems = [...new Set(others.flatMap((e) => e.problems))];
            console.log(`✖ (格式不匹配)  ${others.length} 个`);
            for (const p of problems) console.log(`    · ${p}`);
            console.log('    样本：');
            for (const e of others.slice(0, 3)) console.log(`      ${e.name}`);
            if (others.length > 3) console.log(`      … 还有 ${others.length - 3} 个`);
        }
    }

    if (duplicates.length) {
        console.log('\n✖ 重复节点名：');
        for (const d of duplicates) console.log(`    ${d}`);
    }

    if (orderMismatch) {
        console.log('\n✖ 排序不收敛：MiSub 输出顺序与 mihomo 字节序排序不一致');
        console.log('    mihomo 会排成：');
        for (const n of sorted.slice(0, 8)) console.log(`      ${n}`);
        if (sorted.length > 8) console.log(`      … 共 ${sorted.length} 个`);
    }

    if (expectCount !== null && entries.length !== expectCount) {
        console.log(`\n✖ 节点数量不符：期望 ${expectCount}，实际 ${entries.length}`);
        return false;
    }

    return result.ok;
}

// ---- CLI ----------------------------------------------------------------

async function fetchSubscription(url) {
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 45_000);
    try {
        const res = await fetch(url, {
            signal: ctrl.signal,
            redirect: 'follow',
            headers: { 'Cache-Control': 'no-cache' },
        });
        if (!res.ok) return { ok: false, reason: `HTTP ${res.status}` };
        return { ok: true, text: await res.text() };
    } catch (e) {
        return { ok: false, reason: e.message };
    } finally {
        clearTimeout(timer);
    }
}

async function main() {
    const args = argv.slice(2);
    const valueOf = (flag, dflt = null) => {
        const i = args.indexOf(flag);
        return i !== -1 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : dflt;
    };

    const file = valueOf('--file');
    const url = args.find((a) => /^https?:\/\//.test(a));
    const expectRaw = valueOf('--expect');
    const expectCount = expectRaw === null ? null : Number.parseInt(expectRaw, 10);

    if (expectRaw !== null && (!Number.isInteger(expectCount) || expectCount < 0)) {
        console.error(`✖ --expect 需要非负整数，收到: ${expectRaw}`);
        exit(2);
    }

    let text;
    if (file) {
        try {
            text = readFileSync(file, 'utf8');
        } catch (e) {
            console.error(`✖ 读取失败: ${file} — ${e.message}`);
            exit(2);
        }
    } else if (url) {
        const r = await fetchSubscription(url);
        if (!r.ok) {
            console.error(`✖ 拉取订阅失败: ${r.reason}`);
            exit(2);
        }
        text = r.text;
    } else {
        console.error(
            '用法：\n' +
                '  node tools/check-node-names.mjs <订阅URL>\n' +
                '  node tools/check-node-names.mjs --file <本地yaml> [--expect N]'
        );
        exit(2);
    }

    const names = extractProxyNames(text);
    if (names.length === 0) {
        console.error('✖ 没有在 proxies: 段找到任何节点');
        exit(2);
    }

    const result = checkNodeNames(names);
    const passed = printReport(result, expectCount);

    if (passed) {
        console.log('\n✓ 命名合规，排序收敛');
        exit(0);
    }
    // 提示放最后，避免 console.error 插到 stdout 报告中间
    console.log('\n✖ 命名校验未通过 —— 见 docs/NODE-ORDERING.md 第五节');
    exit(1);
}

// 仅在直接执行时跑 CLI，被 import 时不触发
if (import.meta.url === `file://${argv[1]}`) {
    main();
}
