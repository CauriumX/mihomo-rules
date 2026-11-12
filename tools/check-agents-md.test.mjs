import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { parseAgentsFields, detectCi, checkAgentsMd, fixAgentsMd } from '../tools/check-agents-md.mjs';

/** 造一个最小仓库：package.json + AGENTS.md + 可选 workflow */
function makeRepo({ version = '0.1.0', agentsVersion = '0.1.0', ci = 'none', workflows = [] } = {}) {
    const dir = mkdtempSync(join(tmpdir(), 'agents-check-'));
    writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'demo', version }));

    if (workflows.length) {
        mkdirSync(join(dir, '.github', 'workflows'), { recursive: true });
        for (const wf of workflows) {
            writeFileSync(join(dir, '.github', 'workflows', wf), 'name: ci\n');
        }
    }

    writeFileSync(
        join(dir, 'AGENTS.md'),
        `# AGENTS.md — AI working contract

## Project

- **Name**: \`demo\`
- **Kind**: Node (package.json)
- **Version**: \`${agentsVersion}\`
- **CI**: \`${ci}\`
`
    );
    return dir;
}

test('parseAgentsFields 提取四个字段', () => {
    const dir = makeRepo();
    const text = readFileSync(join(dir, 'AGENTS.md'), 'utf8');
    assert.deepEqual(parseAgentsFields(text), {
        name: 'demo',
        kind: 'Node (package.json)',
        version: '0.1.0',
        ci: 'none',
    });
});

test('parseAgentsFields 从 CI 行提取反引号内容，忽略后续说明', () => {
    const text = '- **CI**: `.github/workflows/ci.yml` (version coherence, unit tests)';
    assert.equal(parseAgentsFields(text).ci, '.github/workflows/ci.yml');
});

test('parseAgentsFields 字段缺失返回 null', () => {
    const r = parseAgentsFields('# nothing here');
    assert.equal(r.version, null);
    assert.equal(r.ci, null);
});

test('detectCi 无 workflows 目录返回 none', () => {
    assert.equal(detectCi(makeRepo()), 'none');
});

test('detectCi 返回排序后的第一个 workflow', () => {
    const dir = makeRepo({ workflows: ['z.yml', 'ci.yml'] });
    assert.equal(detectCi(dir), '.github/workflows/ci.yml');
});

test('版本一致时 ok', () => {
    const r = checkAgentsMd(makeRepo({ version: '0.1.0', agentsVersion: '0.1.0' }));
    assert.equal(r.ok, true);
    assert.equal(r.drift.length, 0);
});

test('版本漂移被检出', () => {
    const r = checkAgentsMd(makeRepo({ version: '0.1.0', agentsVersion: '0.0.9' }));
    assert.equal(r.ok, false);
    assert.equal(r.drift.length, 1);
    assert.equal(r.drift[0].field, 'version');
    assert.equal(r.drift[0].actual, '0.0.9');
    assert.equal(r.drift[0].expected, '0.1.0');
});

test('CI 从 none 变为有 workflow 时被检出', () => {
    // 真实事故：AGENTS.md 写着 CI: none，实际已有 14 步流水线
    const dir = makeRepo({ ci: 'none', workflows: ['ci.yml'] });
    const r = checkAgentsMd(dir);
    assert.equal(r.ok, false);
    assert.equal(r.drift[0].field, 'ci');
    assert.equal(r.drift[0].expected, '.github/workflows/ci.yml');
});

test('name 不参与校验（生成器用目录名，与 package.json.name 大小写不同）', () => {
    const dir = makeRepo();
    // 把 name 改成与 package.json 不同的大小写
    let text = readFileSync(join(dir, 'AGENTS.md'), 'utf8');
    text = text.replace('- **Name**: `demo`', '- **Name**: `Demo`');
    writeFileSync(join(dir, 'AGENTS.md'), text);

    const r = checkAgentsMd(dir);
    assert.equal(r.ok, true, 'name 大小写差异不应报漂移');
});

test('fixAgentsMd 只改版本号那一行', () => {
    const dir = makeRepo({ version: '0.1.0', agentsVersion: '0.0.9' });
    const before = readFileSync(join(dir, 'AGENTS.md'), 'utf8');
    const r = checkAgentsMd(dir);

    fixAgentsMd(dir, r.drift);
    const after = readFileSync(join(dir, 'AGENTS.md'), 'utf8');

    assert.match(after, /- \*\*Version\*\*: `0\.1\.0`/);
    assert.doesNotMatch(after, /0\.0\.9/);
    // 其余行不变
    assert.equal(
        after.replace(/`0\.1\.0`/, '`0.0.9`'),
        before,
        '除版本号外不应有其它改动'
    );
});

test('fixAgentsMd 保留 CI 行尾的步骤说明', () => {
    const dir = makeRepo({ ci: 'none', workflows: ['ci.yml'] });
    let text = readFileSync(join(dir, 'AGENTS.md'), 'utf8');
    text = text.replace(
        '- **CI**: `none`',
        '- **CI**: `none` (version coherence, unit tests, template integrity)'
    );
    writeFileSync(join(dir, 'AGENTS.md'), text);

    fixAgentsMd(dir, checkAgentsMd(dir).drift);
    const after = readFileSync(join(dir, 'AGENTS.md'), 'utf8');

    assert.match(after, /- \*\*CI\*\*: `\.github\/workflows\/ci\.yml` \(version coherence, unit tests, template integrity\)/);
});

test('修复后重新校验通过', () => {
    const dir = makeRepo({ version: '0.1.0', agentsVersion: '0.1.0', workflows: ['ci.yml'] });
    assert.equal(checkAgentsMd(dir).ok, false);

    fixAgentsMd(dir, checkAgentsMd(dir).drift);
    const r = checkAgentsMd(dir);
    assert.equal(r.ok, true, `修复后仍漂移: ${JSON.stringify(r.drift)}`);
});

test('AGENTS.md 缺失时抛错', () => {
    const dir = mkdtempSync(join(tmpdir(), 'agents-missing-'));
    writeFileSync(join(dir, 'package.json'), JSON.stringify({ name: 'x', version: '1.0.0' }));
    assert.throws(() => checkAgentsMd(dir), /AGENTS\.md 不存在/);
});

test('package.json 缺失时抛错', () => {
    const dir = mkdtempSync(join(tmpdir(), 'pkg-missing-'));
    writeFileSync(join(dir, 'AGENTS.md'), '- **Version**: `1.0.0`\n');
    assert.throws(() => checkAgentsMd(dir), /package\.json 不存在/);
});
