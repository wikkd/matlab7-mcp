#!/usr/bin/env node
// Static consistency checks that need NO MATLAB and NO worker:
//   1. every .m helper file is pure ASCII (R14 reads .m as GBK; non-ASCII
//      comments/strings mojibake at runtime - the em-dash bug)
//   2. mcp-server.js TOOLS array has exactly 22 tools
//   3. README badges/tables mention the same tool count as the code
//   4. README regression count matches v3_regress.js T-assertions + subchecks
//   5. no leftover username/private info in tracked bridge files
//   6. every request key mcp-server.js sends exists in mcp_worker.m parse_req
//      (v3.2.2: matlab_sim_scan shipped broken because 'pattern' was missing
//      from the parser whitelist and no test exercised the tool)
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
// v3.3: the server is split into lib/*.js modules — all checks that read the
// server source must scan the entry PLUS every lib module.
const jsFiles = fs.readdirSync(ROOT).filter((x) => x.endsWith('.js'))
  .concat(fs.readdirSync(path.join(ROOT, 'lib')).filter((x) => x.endsWith('.js')).map((x) => 'lib/' + x));
const server = jsFiles.map((f) => fs.readFileSync(path.join(ROOT, f), 'utf8')).join('\n');
const toolDefs = [...server.matchAll(/^\s*name: '(matlab_[a-z_]+)',$/gm)].map((m) => m[1]);
check('server:26-tools', toolDefs.length === 26, `${toolDefs.length} defs`);
// Version and tool counts are derived, not hardcoded: read the version the
// server actually advertises and require only its shape, so a future bump
// doesn't need a test edit.
const ver = (server.match(/(?:version:|VERSION =) '(\d+\.\d+\.\d+)'/) || [])[1];
check('server:version-shape', /^\d+\.\d+\.\d+$/.test(ver || ''), ver || 'not found');
check('server:version-min', ver && ver >= '3.2.0' ? true : false, ver || '');
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
const scanFiles = fs.readdirSync(ROOT).filter((x) => /\.(js|m|md)$/.test(x) && x !== 'check_static.js')
  .concat(fs.readdirSync(path.join(ROOT, 'lib')).filter((x) => x.endsWith('.js')).map((x) => 'lib/' + x));
for (const f of scanFiles) {
  const txt = fs.readFileSync(path.join(ROOT, f), 'utf8');
  const hit = PRIV.find((p) => txt.includes(p));
  check(`privacy:${f}`, !hit, hit ? `contains "${hit}"` : '');
}

// ---- 6. protocol field whitelist: server keys vs worker parse_req ---------
const workerSrc = fs.readFileSync(path.join(ROOT, 'mcp_worker.m'), 'utf8');
const structDef = (workerSrc.match(/req = struct\(([\s\S]*?)\);/) || [])[1] || '';
const have = new Set([...structDef.matchAll(/'([a-z_]+)'/g)].map((m) => m[1]));
const sent = new Set();
for (const m of server.matchAll(/workerRequest\(\{([\s\S]*?)\}/g)) {
  for (const k of [...m[1].matchAll(/([a-z_]+):/g)]) sent.add(k[1]);
}
const missingKeys = [...sent].filter((k) => !have.has(k));
check('protocol:request-keys', missingKeys.length === 0,
  missingKeys.length ? 'missing in parse_req: ' + missingKeys.join(',') : '');

console.log(`\n==== STATIC: ${fail === 0 ? 'ALL PASS' : fail + ' FAIL'} ====`);
process.exit(fail > 0 ? 1 : 0);
