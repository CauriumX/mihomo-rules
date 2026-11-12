#!/usr/bin/env node
// check-version-contract.mjs — 模板与规则集的版本一致性契约
//
// 问题：
//   misub-lock.mjs 把模板 URL 锁到具体 commit，但模板内部 27 个
//   rule-providers 仍写死 @main。回滚模板到旧 commit 时，规则集
//   还在漂移，两者可能不兼容。
//
// 本脚本检查三件事：
//   1. 模板内所有 rule-provider URL 使用同一个 ref
//   2. 该 ref 与 misub-lock 锁定的 commit 一致（若存在）
//   3. 不允许出现 @main（除非显式允许）
//
// 用法：
//   node tools/check-version-contract.mjs [--allow-main]
//
// 退出码：
//   0 = 通过
//   1 = 版本不一致
//   2 = 环境问题（缺文件）
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, '..');

const TEMPLATE = process.env.MISUB_TEMPLATE || join(ROOT, 'templates', 'mihomo.yaml');
const LOCK_STATE = process.env.MISUB_LOCK_STATE || join(ROOT, '.cache', 'misub-lock.json');

const allowMain = process.argv.includes('--allow-main');

function fail(msg) {
  console.error(`\x1b[31m✖\x1b[0m ${msg}`);
  process.exitCode = 1;
}

function ok(msg) {
  console.log(`\x1b[32m✓\x1b[0m ${msg}`);
}

if (!existsSync(TEMPLATE)) {
  console.error(`\x1b[31m错误\x1b[0m 找不到模板：${TEMPLATE}`);
  process.exit(2);
}

const src = readFileSync(TEMPLATE, 'utf8');

// 只检查 rule-providers 段的 url（ruleset 产物），不检查模板自身 url
const urls = [...src.matchAll(/url:\s*"([^"]+)"/g)]
  .map((m) => m[1])
  .filter((u) => u.includes('/ruleset/'));

if (urls.length === 0) {
  console.error('\x1b[31m错误\x1b[0m 模板内没有 ruleset URL');
  process.exit(2);
}

// 提取 ref
const refs = new Map();
for (const u of urls) {
  const m = u.match(/@([^/]+)\//);
  const ref = m ? m[1] : 'NONE';
  refs.set(ref, (refs.get(ref) || 0) + 1);
}

console.log(`校验 ${urls.length} 个 ruleset URL`);
console.log('');

// 1. 内部一致性
if (refs.size > 1) {
  fail(`模板内 ref 不一致：${[...refs.entries()].map(([r, n]) => `@${r}×${n}`).join(', ')}`);
} else {
  ok(`模板内 ref 统一：@${[...refs.keys()][0]}`);
}

// 2. 与 misub-lock 比对
//    占位符形态（{{RULES_VERSION}}）不参与比对 —— 它在发布时才被替换，
//    此时模板源里本来就没有具体版本。
const onlyRef = refs.size === 1 ? [...refs.keys()][0] : null;
const isPlaceholder = onlyRef === '{{RULES_VERSION}}';

if (isPlaceholder) {
  console.log(`\x1b[90m·\x1b[0m 占位符形态，跳过 misub-lock 比对`);
} else if (existsSync(LOCK_STATE)) {
  let locked = null;
  try {
    locked = JSON.parse(readFileSync(LOCK_STATE, 'utf8')).commit || null;
  } catch {
    fail(`无法解析 ${LOCK_STATE}`);
  }

  if (locked && onlyRef) {
    const short = locked.slice(0, 7);
    if (onlyRef !== locked && onlyRef !== short) {
      fail(
        `版本错配：misub-lock 锁 ${short}，模板 ruleset 用 @${onlyRef}\n` +
        `    后果：回滚模板时规则集仍漂移，两者可能不兼容`
      );
    } else {
      ok(`与 misub-lock 一致：@${onlyRef}`);
    }
  }
} else {
  console.log(`\x1b[90m·\x1b[0m 无 misub-lock 状态，跳过比对`);
}

// 3. @main 检查
if (onlyRef === 'main' && !allowMain) {
  fail(
    `模板 ruleset URL 使用 @main（漂移引用）\n` +
    `    应改为 @{{RULES_VERSION}} 占位符，发布时替换为具体 tag\n` +
    `    或加 --allow-main 显式允许`
  );
} else if (onlyRef === 'main') {
  console.log(`\x1b[33m·\x1b[0m @main 已被 --allow-main 允许`);
}

// 4. 占位符检查（推荐形态）
const hasPlaceholder = urls.some((u) => u.includes('{{RULES_VERSION}}'));
if (hasPlaceholder) {
  ok('使用 {{RULES_VERSION}} 占位符（推荐）');
}

process.exit(process.exitCode || 0);
