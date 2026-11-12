#!/usr/bin/env node
/**
 * check-agents-md.mjs — 防止 AGENTS.md 漂移
 *
 * 背景：
 *   AGENTS.md 由 Readme Harness 生成（tools/generate.mjs:184-233），
 *   里面写着 Version 和 CI 两个会随仓库演进的字段。生成后没人重跑，
 *   它们就会静默过时 —— 2026-11-11 实测：Version 停在 0.1.0，
 *   CI 写着 none，而实际已有 14 步流水线。
 *
 *   危险在于 AGENTS.md 是 AI agent 开工时**自动读取**的文件。
 *   它读到「没有 CI」，就不会去跑 CI；读到旧版本号，版本判断就错。
 *   这类漂移不会报错，只会让后续每次协作都建立在错误前提上。
 *
 * 校验策略：
 *   不重跑生成器（那会覆盖人工补充的内容），只校验**会漂移的字段**：
 *     · Version  === package.json.version
 *     · CI       === 检测到的 workflow 文件（存在则为路径，否则 none）
 *     · Name     === package.json.name
 *
 * 用法：
 *   node tools/check-agents-md.mjs [项目目录]
 *   node tools/check-agents-md.mjs --fix      # 就地修正漂移字段
 *
 * 退出码：
 *   0  一致（或已修正）
 *   1  发现漂移且未 --fix
 *   2  文件缺失 / 无法解析
 */

import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { argv, exit } from 'node:process';

/** 从 AGENTS.md 里取出 Project 段的三个字段 */
export function parseAgentsFields(text) {
    const field = (label) => {
        // - **Version**: `0.2.6`   /  - **CI**: `.github/workflows/ci.yml` (…)
        const re = new RegExp(`^- \\*\\*${label}\\*\\*:\\s*(.+)$`, 'm');
        const m = text.match(re);
        if (!m) return null;
        return m[1].trim();
    };

    const strip = (v) => {
        if (v === null) return null;
        const tick = v.match(/`([^`]*)`/);
        return tick ? tick[1] : v;
    };

    return {
        name: strip(field('Name')),
        kind: strip(field('Kind')),
        version: strip(field('Version')),
        ci: strip(field('CI')),
    };
}

/**
 * 检测仓库实际的 CI 状态。
 *
 * 返回 `none` 或第一个 workflow 的路径 —— 与生成器一致：
 * 生成器读的是「有没有 CI」，不是「有几个」。
 */
export function detectCi(dir) {
    const wfDir = join(dir, '.github', 'workflows');
    if (!existsSync(wfDir)) return 'none';
    const files = readdirSync(wfDir).filter((f) => /\.ya?ml$/.test(f)).sort();
    if (files.length === 0) return 'none';
    return `.github/workflows/${files[0]}`;
}

/**
 * 计算期望值并与实际比对。
 *
 * @returns {{ok: boolean, drift: Array<{field: string, actual: string|null, expected: string}>}}
 */
export function checkAgentsMd(dir) {
    const agentsPath = join(dir, 'AGENTS.md');
    if (!existsSync(agentsPath)) {
        throw new Error(`AGENTS.md 不存在: ${agentsPath}`);
    }
    const text = readFileSync(agentsPath, 'utf8');
    const actual = parseAgentsFields(text);

    const pkgPath = join(dir, 'package.json');
    if (!existsSync(pkgPath)) {
        throw new Error(`package.json 不存在: ${pkgPath}`);
    }
    const pkg = JSON.parse(readFileSync(pkgPath, 'utf8'));

    const expected = {
        // name 不校验：生成器用的是目录名，
        // package.json.name 是小写（dsotm-mihomo），两者本来就不同。
        version: pkg.version ?? null,
        ci: detectCi(dir),
    };

    const drift = [];
    for (const field of ['version', 'ci']) {
        if (expected[field] === null) continue; // package.json 没这个字段就跳过
        if (actual[field] !== expected[field]) {
            drift.push({ field, actual: actual[field], expected: expected[field] });
        }
    }

    return { ok: drift.length === 0, drift, actual, expected };
}

/**
 * 就地修正漂移字段。
 *
 * 只替换 `- **Version**: \`x\`` 这一行的值，保留行内其余内容
 * （CI 行后面可能跟着步骤说明）。没有该字段则追加到 Project 段末尾。
 */
export function fixAgentsMd(dir, drift) {
    const agentsPath = join(dir, 'AGENTS.md');
    let text = readFileSync(agentsPath, 'utf8');

    for (const { field, expected } of drift) {
        // 字段名大小写必须与生成器一致：Name / Kind / Version / CI
        // 不能简单 charAt(0).toUpperCase()，ci 会变成 Ci 而模板里是 CI。
        const label = { name: 'Name', kind: 'Kind', version: 'Version', ci: 'CI' }[field];
        if (!label) continue;

        const re = new RegExp(`^(- \\*\\*${label}\\*\\*:\\s*)\`[^\`]*\``, 'm');
        if (re.test(text)) {
            text = text.replace(re, `$1\`${expected}\``);
        } else {
            // 字段缺失：插到 Project 段最后一个 bullet 之后
            const anchor = /^(- \*\*CI\*\*:.*)$/m;
            if (anchor.test(text)) {
                text = text.replace(anchor, `$1\n- **${label}**: \`${expected}\``);
            }
        }
    }

    writeFileSync(agentsPath, text, 'utf8');
    return text;
}

// ---- CLI ----------------------------------------------------------------

function main() {
    const args = argv.slice(2);
    const fix = args.includes('--fix');
    const dir = args.find((a) => !a.startsWith('--')) || '.';

    let result;
    try {
        result = checkAgentsMd(dir);
    } catch (e) {
        console.error(`✖ ${e.message}`);
        exit(2);
    }

    if (result.ok) {
        console.log(
            `✓ AGENTS.md 与仓库一致（version=${result.actual.version} ` +
                `ci=${result.actual.ci}）`
        );
        exit(0);
    }

    console.log('✖ AGENTS.md 已漂移：\n');
    for (const { field, actual, expected } of result.drift) {
        console.log(`  ${field}`);
        console.log(`    当前: ${actual === null ? '(缺失)' : actual}`);
        console.log(`    应为: ${expected}`);
    }

    if (fix) {
        fixAgentsMd(dir, result.drift);
        console.log('\n✓ 已就地修正');
        exit(0);
    }

    // 提示放最后，避免 console.error 插到 stdout 报告中间
    console.log(
        '\nAGENTS.md 由 Readme Harness 生成，是 AI agent 开工时自动读取的文件。' +
            '\n版本号或 CI 状态过时会让后续协作建立在错误前提上。' +
            '\n\n修正：node tools/check-agents-md.mjs --fix'
    );
    exit(1);
}

if (import.meta.url === `file://${argv[1]}`) {
    main();
}
