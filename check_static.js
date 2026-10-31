#!/usr/bin/env node
// Static consistency checks that need NO MATLAB and NO worker:
//   1. every .m helper file is pure ASCII (R14 reads .m as GBK; non-ASCII
//      comments/strings mojibake at runtime - the em-dash bug)
//   2. mcp-server.js TOOLS array has exactly 22 tools
//   3. README badges/tables mention the same tool count as the code
//   4. README regression count matches v3_regress.js T-assertions + subchecks
//   5. no leftover username/private info in tracked bridge files
// Exits 0 on all-pass, 1 on any failure. Used by CI and pre-push.
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname);
let fail = 0;
const check = (label, ok, detail) => {
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${label}${detail ? ' :: ' + detail : ''}`);
  if (!ok) fail++;
};

// ---- 1. pure ASCII in R14-read files ------------------------------------
for (const f of fs.readdirSync(ROOT).filter((x) => x.endsWith('.m'))) {
  const buf = fs.readFileSync(path.join(ROOT, f));
  const bad = [...buf].filter((b) => b > 127).length;
  check(`ascii:${f}`, bad === 0, bad ? `${bad} non-ascii byte(s)` : '');
}

// ---- 2. tool count in server ---------------------------------------------
const server = fs.readFileSync(path.join(ROOT, 'mcp-server.js'), 'utf8');
const toolDefs = [...server.matchAll(/^\s*name: '(matlab_[a-z_]+)',$/gm)].map((m) => m[1]);
check('server:24-tools', toolDefs.length === 24, `${toolDefs.length} defs`);
check('server:version-3.2', server.includes("version: '3.2.0'"), '');
check('server:dynamic-bootcount', server.includes('${TOOLS.length} tools'), '');
const unique = new Set(toolDefs);
check('server:unique-names', unique.size === toolDefs.length, '');

// ---- 3. README tool-count agreement ---------------------------------------
// counts must agree with the actual tool definition count in the server
for (const readme of ['README.md', 'README.zh-CN.md']) {
  const md = fs.readFileSync(path.join(ROOT, readme), 'utf8');
  const counts = [...md.matchAll(/(\d+)\s*tools|\(\s*(\d+)\s*\)\s*$|(\d+)\s*个工具|工具清单（(\d+)\s*个/gm)]
    .map((m) => parseInt(m[1] || m[2] || m[3] || m[4], 10))
    .filter((n) => Number.isFinite(n));
  const ok = counts.length > 0 && counts.every((n) => n === toolDefs.length);
  check(`readme:${readme}:toolcount`, ok, counts.length ? counts.join(',') : 'no count found');
}

// ---- 4. regression count agreement ----------------------------------------
const regress = fs.readFileSync(path.join(ROOT, 'v3_regress.js'), 'utf8');
const tCount = [...regress.matchAll(/await T\('([^']+)'/g)].length;
const subPass = [...regress.matchAll(/console\.log\('PASS/g)].length;
const total = tCount + subPass;
for (const readme of ['README.md', 'README.zh-CN.md']) {
  const md = fs.readFileSync(path.join(ROOT, readme), 'utf8');
  const counts = [...md.matchAll(/(\d+)\/(\d+)/g)].map((m) => parseInt(m[1], 10));
  check(`readme:${readme}:regress-count`, counts.includes(total), `expect ${total}`);
}

// ---- 5. privacy: no personal usernames in bridge files ---------------------
// The real username is read from the OS at runtime and never hardcoded, so
// this check stays personal-data-free even though it scans for one.
const os = require('os');
const USERNAME = path.basename(os.homedir());
const PRIV = [USERNAME, 'C:\\Users\\' + USERNAME];
for (const f of fs.readdirSync(ROOT).filter((x) => /\.(js|m|md)$/.test(x) && x !== 'check_static.js')) {
  const txt = fs.readFileSync(path.join(ROOT, f), 'utf8');
  const hit = PRIV.find((p) => txt.includes(p));
  check(`privacy:${f}`, !hit, hit ? `contains "${hit}"` : '');
}

console.log(`\n==== STATIC: ${fail === 0 ? 'ALL PASS' : fail + ' FAIL'} ====`);
process.exit(fail > 0 ? 1 : 0);
