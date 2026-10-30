<div align="center">

# matlab7-mcp

**An MCP server that lets AI agents drive MATLAB 7.0 (R14, 2004) on Windows —
23 tools, zero npm dependencies, Simulink orthogonal auto-routing & block auto-arrangement**

[English](README.md) | [简体中文](README.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-Windows%20XP--11-blue)
![Node](https://img.shields.io/badge/node-%E2%89%A516-green)
![MATLAB](https://img.shields.io/badge/MATLAB-7.0%20(R14)%20%7C%202004-lightgrey)
![License](https://img.shields.io/badge/license-MIT-yellow)
![Tests](https://img.shields.io/badge/regression-47%2F47%20pass-brightgreen)

</div>

> **Keywords**: MATLAB 7.0 · MATLAB R14 · legacy MATLAB · old MATLAB MCP server ·
> Model Context Protocol · MCP · Simulink automation · Simulink auto-route ·
> orthogonal routing · auto-layout · Sugiyama layout · university lab course ·
> AI agent · Claude Desktop · Cursor · ZCode · Cline · Windows

## Why this exists

Many universities still teach on **MATLAB 7.0 (R14)** — released in 2004 — because
of old site licenses, legacy courseware, and toolboxes that never got ported.
If that's your situation, you've hit this wall:

- The **official MathWorks MCP server requires R2021a+**. Not an option on R14.
- MATLAB's **COM/ActiveX automation interface deterministically crashes** on
  Windows 11 with modern CPUs (`m_interpreter.dll` access violation). We tried — hard.
- The **only reliable programmatic channel** left in R14 is
  `MATLAB.exe -r` + a persistent worker process + a file-based protocol.

This project is that channel, wrapped into a standard MCP stdio server, and
**battle-tested through a full 8-experiment university course** (modeling,
simulation, report generation) where an AI agent did the actual work.

## Is this for you?

| ✅ Yes, if… | ❌ Not for you, if… |
|---|---|
| Your school/lab **forces MATLAB 7.0 / R14** (or other pre-2010 versions) for labs and reports | You have **R2021a or newer** → use the [official server](https://github.com/mathworks/MATLAB-MCP-server) instead |
| You want Claude / Cursor / ZCode / any MCP client to run MATLAB code, read variables, export figures | You need Linux/macOS (this bridge is Windows-only, like R14 itself) |
| You want **Simulink diagrams auto-routed** (orthogonal lines, no block overlap) and **blocks auto-arranged** | You only need headless batch execution without a desktop session (figure/window capture needs one) |
| You maintain old Simulink models and dread re-drawing every connection | |

## How it works

```
MCP client ──MCP stdio──> mcp-server.js (Node, zero deps)
                          │  writes req.json / reads res.json (UTF-8 JSON)
                          ▼
                 MATLAB.exe -r "mcp_worker(...)"   ← resident process, ~2s boot
                          │  polls requests → evalin('base',...) → diary capture
                          ▼
                       base workspace / figures / Simulink
```

- `mcp-server.js` — the MCP stdio server: 22 tool definitions, parameter
  validation, request files, `fs.watch` response polling (100 ms fallback),
  `busy.json` heartbeat.
- `mcp_worker.m` — resident R14 worker: polls requests, evaluates in the base
  workspace, captures output via `diary`, serializes results. **Every branch
  has a catch — the worker always writes a response.**
- `json_decode.m` / `mcp2json.m` — R14-compatible JSON both ways (NaN/Inf,
  `\uXXXX` and raw-UTF-8 dual sources, N-D nesting, row-major order).
- `cap_window.ps1` — PowerShell window capture (R14's `print('-sModel')` is broken).
- `mcp_check`, `mcp_sim_route`, `mcp_sim_arrange`, `mcp_sim_audit`,
  `mcp_sim_clean`, `mcp_progress` — helper functions behind the tools.

Single tool-call latency: **0.3–0.5 s**.

## Requirements

- Windows (developed and verified on Windows 11 running 32-bit MATLAB 7.0)
- MATLAB 7.0 (R14) installed — `bin\win32\MATLAB.exe` must exist.
  Other 7.x-era versions will likely work (untested); R2021a+ → official server.
- Node.js ≥ 16. No npm install needed — zero dependencies.

## Quick start (5 minutes)

1. **Install Node.js** if you don't have it (any current LTS).
2. **Find your MATLAB root** — the folder that contains `bin\win32\MATLAB.exe`.
   Common locations: `D:\MATLAB7`, `C:\MATLAB7`. If yours is elsewhere, set
   `MATLAB7_DIR` in the config below.
3. **Clone this repo** (or download ZIP and extract anywhere):
   ```
   git clone https://github.com/wikkd/matlab7-mcp.git
   ```
4. **Register the server in your MCP client.** The JSON below works for
   Claude Desktop (`claude_desktop_config.json`), Cursor (`mcp.json`), ZCode
   (`config.json` → `mcp.servers`), and most other stdio MCP clients:
   ```json
   "matlab7": {
     "command": "node",
     "args": ["C:\\path\\to\\matlab7-mcp\\mcp-server.js"],
     "env": {
       "MATLAB7_DIR": "D:\\MATLAB7"
     }
   }
   ```
   Note the **double backslashes** — JSON needs them. Omit `MATLAB7_DIR` if
   MATLAB lives in one of the auto-detected locations.
5. **Restart your client**, then ask the AI something like
   *"list my MATLAB workspace"* — the first call boots the worker (~2 s),
   after which it stays resident.

Optional env vars: `MCP_KILL_ALL=1` (cleanup kills every MATLAB.exe; default
only kills the worker this server spawned), `MCP_MAX_CHARS` (output truncation,
default 200 000), `MCP_BOOT_WAIT` (worker boot timeout seconds, default 120).

> **Encoding note**: R14 never reads `.m` files as UTF-8. Hand-written `.m`
> files with non-ASCII comments must be saved as **GBK** — or better, let the
> agent write them through `matlab_write_file`, which converts automatically.
> Every `.m` file shipped in this repo is verified pure ASCII (enforced by
> `node check_static.js`), so it runs on R14 as-is — a UTF-8 em-dash in a
> worker string once mojibake'd a runtime warning before this check existed.

## Let the agent install it itself (copy-paste prompt)

You don't have to do any of the above by hand. Paste the prompt below into
your MCP-capable AI assistant (ZCode, Claude Code, Cursor agent, ...) and it
will clone the repo, find MATLAB, write the client config, and verify the
bridge end-to-end on its own:

```text
Install the matlab7-mcp bridge for me, following the README at
https://github.com/wikkd/matlab7-mcp. Do all of this yourself:

1. Clone https://github.com/wikkd/matlab7-mcp to a directory of your choice
   (record the absolute path).
2. Locate my MATLAB 7.0 (R14) installation — the folder containing
   bin\win32\MATLAB.exe. Check D:\MATLAB7, C:\MATLAB7, C:\MATLAB_R14 first,
   then search the disk if none exist. If R14 is not installed at all, stop
   and tell me where to get it installed before continuing.
3. Register the server "matlab7" in my MCP client config: command "node",
   args pointing at <repo>\mcp-server.js, env MATLAB7_DIR set to the MATLAB
   root found in step 2. Use double backslashes in JSON paths. Find the
   correct config file for my client yourself (Claude Desktop:
   claude_desktop_config.json; Cursor: mcp.json; ZCode: config.json
   mcp.servers). If two MCP clients share this repo folder, give each its
   own clone — the file protocol is a single channel.
4. Verify the bridge: run the repo's regression suite with Node
   (node v3_regress.js <repo folder>) — expect 47/47 assertions passing.
   If a capture-related assertion fails, note that window capture needs an
   interactive desktop session and report which assertions still pass.
5. Report back: repo path, MATLAB root, config file edited, regression
   result, and anything I must do manually (restart the client).

Constraints: do not modify any file inside the repo — config edits happen
in the client's own config file only. If MATLAB7_DIR cannot be determined,
ask me instead of guessing.
```

After the agent finishes, restart your MCP client and try
*"list my MATLAB workspace"* to confirm.

## Tools (23)

**Execution & diagnostics**

| Tool | What it does |
|---|---|
| `matlab_eval` | Run code in the base workspace (including `sim('model')`); reliable syntax & runtime error reporting; optional `check_first` |
| `matlab_check` | Syntax-check without running: block-keyword balance + full pcode parse |
| `matlab_run_file` | Run a `.m` file (auto-clears its function cache, restores cwd) |
| `matlab_status` / `matlab_restart` | Worker status (incl. busy command + elapsed seconds) / restart |
| `matlab_last` | Output of the most recent completed job — rescues console text of evals whose tool call was cut by a client timeout |
| `matlab_progress` | Read `mcp_progress(frac, msg)` markers from the last eval (v3.1: pollable WHILE the eval runs — the server no longer blocks) |

**Data & files**

| Tool | What it does |
|---|---|
| `matlab_get_var` / `matlab_set_var` | JSON read/write of workspace variables |
| `matlab_summary` | Read large arrays with a row budget: meta + min/max/mean/std + endpoint-preserving downsample |
| `matlab_workspace` | List workspace variables (name/class/size) |
| `matlab_write_file` / `matlab_append_file` | Write/append text (`.m` → GBK automatically, others UTF-8; binary types rejected) |
| `matlab_read_file` | Read text (`.m` auto GBK-decode, others UTF-8, ≤ 2 MB) |
| `matlab_dir` | List a directory |

**Graphics**

| Tool | What it does |
|---|---|
| `matlab_figure_png` | Export a figure (default: most recent; `dpi`/`close` options) as an MCP image |
| `matlab_window_png` | Capture a real OS window by title substring (Simulink editor, Scope) |
| `matlab_figures` | List open figure windows (newest first) |
| `matlab_cleanup` | Close all figures and/or loaded models in one call |

**Simulink**

| Tool | What it does |
|---|---|
| `matlab_sim_info` | Audit a model: ghost lines (duplicate destinations), orphan segments, unconnected ports (optional auto-fix) |
| `matlab_sim_clean` | Gently remove orphan line segments and save |
| `matlab_sim_route` | Orthogonal auto-routing for every line in a model (see below) |
| `matlab_sim_arrange` | Sugiyama-style block auto-arrangement (see below) |

## Simulink auto-layout pipeline

```
matlab_sim_arrange(model)   ← re-place blocks in signal-flow layers (left → right)
matlab_sim_route(model)     ← orthogonalize every line (run twice for convergence)
```

### `matlab_sim_arrange` — block auto-arrangement

Sugiyama-style layered layout: ① edges enumerated from the **destination side**
(branch edges are only visible from Inport lines — scanning Outport side alone
mis-layers sink blocks); ② Kahn longest-path layering, with cycle members
pinned to their shallowest finalized feeder layer so feedback loops don't
climb to L100+; ③ two barycenter-ordering sweeps — **ties must be broken with
a positional ε**, or `find` returns the same index twice and blocks silently
vanish from a row; ④ in-row stacking centered on the previous layer's mean
mid-Y; ⑤ **cumulative x slots** (next layer starts past the widest block's
right edge) so wide blocks stop bleeding into neighbors.

Moves blocks only (`set_param Position`, size preserved). **Lines do not
follow** — run `matlab_sim_route` afterwards.

### `matlab_sim_route` — orthogonal auto-routing

Re-plans every polyline (trunks and branches): same-Y straight line → SAFE-Z
(exit rung + vertical channel + entry rung, all three obstacle-checked) →
anchor drop channel → go-around lanes, falling back to R14's canonical shape.
After every write the router **reads the points back and verifies
orthogonality**, with up to two convergence sweeps for anchors dragged around
by R14. It **never deletes lines and never moves blocks**; it reports ghost
duplicate-destination rows (red-dashed render artifacts that don't affect sims).

v3 routing-quality rules (2026-10-30, built for "no line through text, tidy
junctions"):

1. **Name labels are obstacles.** Every visible block name label becomes a
   routing rect (width measured via Java font metrics of the Simulink canvas
   font, 6 px/char fallback; R14 default label position is below the block).
   No lane may run through label text — the old label-blind router drew long
   branch lanes straight through "BPSK Modulator Baseband".
2. **Straight runs must be clear.** A same-Y line only stays straight when
   nothing sits between src and dst; otherwise it detours.
3. **Vertical legs are checked too** (anchor-lane and go-around strategies
   verify both vertical legs, not just the horizontal run).
4. **Go-around lanes are scanned**, not extrapolated from blocker extremes —
   extremes reach absurd depths when the x-span covers many rows and miss the
   clean corridors between them.
5. **Multi-dst ports get a junction stub.** The parent polyline is reduced to
   a stub ending at J = `[port_x+12, port_y]`; R14 anchors every branch
   segment at the parent's last point, so all branches fork from a clean T
   right after the source port. (v1 re-routed the parent toward its LAST dst,
   which dragged the junction to that dst's doorstep.) If some dst sits on
   the port row behind blockers, J drops below the source's own name label —
   a same-row branch segment can never hold a detour (law 8 below).
6. **Soft fallback**: when no lane clears labels+bodies, retry with block
   bodies only — v3 is never worse than the label-blind v2.
7. **Calibrate the tail with a canonicalization probe (v3.1).** Port stub
   semantics vary by block type (law 4): `get_param Position` may be the dst
   point OR already R14's elbow (true dst = Position ± (10,0) on the
   approach column). The router writes a bare `[P0;dp]` and reads back the
   tail R14 appends to calibrate ex/dx/dy per line; if a set still gets
   sheared (Sum inports fed from above/below hide their tail from the bare
   probe), it learns the true (dst, elbow) from the appended points and
   retries the next strategy calibrated. Deterministic exp6 elbow shears
   (Gain1/Gain_m/Constant_Ff) came exactly from this. Known cosmetic limit:
   the ~10px entry stub of a top/bottom-fed Sum port crosses that block's
   own name label — unavoidable, R14 draws the stub there anyway.
8. **Line-line avoidance (v4)**, matching the official objective "avoid
   overlap with ... other signal lines": every routed line's segments are
   tracked in a wire map tagged with a family id (parent + its branch
   segments share one family, so legal tee overlaps are exempt). Candidate
   channels/lanes occupied by another family with overlapping span are
   tried LAST (soft), and a nudge pass re-routes the movable side of any
   remaining middle-segment superposition with the colliding coordinate
   hard-banned (previous geometry restored on failure). Segments collinear
   with the anchor, the approach rung and the canonical elbow column are
   recognized as R14-forced and never chosen as nudge targets — pairs
   of two forced segments are official-normal merged renders.
   report.super_before/super_after/nudged quantify the pass.

### Verified results

Real course models, sim outputs compared before/after:

- **exp6** (EV drag-power, 15 blocks / 10 layers, 41 lines): 0 overlaps,
  100 % orthogonal, energy **1.0975 kWh identical** before and after.
- **exp7** (Rint battery, 36 blocks with SOC + mileage dual feedback loops):
  layers correct with both loops closed, 0 overlaps, **0 diagonal lines**,
  SOC 0.95 → 0.8849 and mileage 9.7306 km identical to baseline.

### R14 line-semantics laws (probe-verified, read before touching lines)

1. `Points` are absolute; the first point is forced to the line anchor
   (trunk = source port, branch = trunk branch point), and **anchors of
   sibling branch lines migrate when the trunk is re-routed**.
2. The trunk tail is force-normalized to `[...]→(dst_x-10, dst_y)→dst`;
   intermediate points conflicting with that elbow get deleted.
3. **Collinear compression keeps only the last middle point of each run** — a
   vertical-exit middle sharing the anchor's x is swallowed, producing
   diagonals. The SAFE-Z pattern (put both `(c-8,sy)` and `(c,sy)` on the exit
   rung so one survives) is the countermeasure.
4. Y axis points down; port `Position` is the exact connection point; port
   stub lengths vary by block type (Sum −5, Gain −15…) — always read live
   coordinates from `PortHandles`, never memorize constants.
5. `get_param(block,'LineHandles')` hangs lines on the **destination** block's
   Inports; source Outports are often −1. Collect lines from both sides.
6. **Never script-delete lines by the "same destination port has multiple
   lines = ghost" rule** — it deletes legitimate branch rows (we lost 45 and
   rebuilt the model by formula). This router only reports; deletion goes
   through `matlab_sim_info`'s opt-in fix.
7. **A branch segment's anchor is the parent polyline's LAST point**, not an
   interior vertex — R14 re-pins every sibling segment's `Points(1,:)` to it
   whenever the parent is re-routed. Junction placement = choose where the
   parent polyline ends.
8. **A same-row branch segment (anchor row == dst row) always shears into a
   diagonal**: R14 replaces any detour middles with the canonical
   `[...]→(dst,dy)→(dst+10,dy)` tail. No middle list survives. Route such
   connections from a junction dropped off the shared row instead.
9. **Segment middles must end at the canonical elbow `(dst-10, dy)`**, and
   the SAFE-Z `(c-8,sy)/(c,sy)` pair trick must NOT be used on segments (a
   pair makes R14 drop the channel). Trunks are the opposite: pairs required,
   arbitrary tails get force-normalized. Probe-verified shapes:
   trunk `[P0;(c-8,sy);(c,sy);(c,dy);(dx-10,dy)]`,
   segment `[P0;(c,sy);(c,dy);(dx-10,dy)]`.
10. **Block name labels are NOT exposed geometry.** Masked blocks reject
   `NameLocation`; measure text with
   `java.awt.Toolkit.getDefaultToolkit.getFontMetrics(Font('Helvetica',0,10))`
   (R14 rejects chained static calls — two steps) and assume below-block
   placement.

## Lessons learned (2 versions of battle damage, distilled)

1. **Pick the right channel before writing code.** COM looked "proper" but
   deterministically crashes; the crude `-r` + file protocol was the only road
   that worked. Spend half a day probing every integration channel with
   hello-worlds before designing anything.
2. **The worker must always answer.** Every error path must land in the
   protocol (always write a response + a busy heartbeat) — otherwise the
   server can't tell "busy" from "dead" and users stare at timeouts.
3. **Map the encoding chain first.** On a Chinese-locale Windows, the biggest
   time sink isn't algorithms, it's "which encoding is this jump": UTF-8
   request bytes → GBK diary readback → raw `fwrite(uint8(s))` responses.
4. **Probe semantics before writing algorithms.** R14 silently rewrites the
   data you set (anchor normalization, tail canonicalization, collinear
   compression). Ten probe scripts bought us the laws above; the router was
   designed *from* them, not against hope.
5. **Report, don't act.** The worst incident of the project — 45 legitimate
   branch lines deleted by a "duplicate destination = ghost" script — became a
   tool discipline: routers never delete, destructive ops are separate opt-in
   tools, and every bulk delete gets a `.mdl` backup first.
6. **Trust read-back verification, not call success.** `set_param` rarely
   errors but may quietly rewrite your data; every write is followed by a
   read-back assertion. Multiple "it's fixed" bugs were caught exactly this way.
7. **Long tasks need a progress channel** — and beware user code that calls a
   bare `clear`, which wipes both the progress marker and your loop variables,
   disguising failures as successes (the eval tool now warns about it).
8. **Regression tests are the safety net for every refactor.** 47 assertions
   over a real stdio server + real MATLAB (GBK round-trips, NaN serialization,
   ghost audits, clear-warning and progress lifecycle) made the v3 overhaul of
   23 tools land without casualties.

## Changelog

### v3 — Simulink layout pipeline + course battle damage

| Problem hit in practice | v3 answer |
|---|---|
| "Ghost lines" after repeated `add_line`/`delete_block`: add_line says connected but the line can't be found, LineHandles = −1, orphan segments — half a day of manual triage | `matlab_sim_info` (audit + opt-in fix) and `matlab_sim_clean` |
| `print('-sModel')` always fails ("Error using ==> graphics") | `cap_window.ps1` + `matlab_window_png`: find window by title → foreground/restore/resize → capture → return as MCP image |
| Long `.m` files keep getting mangled by fprintf `%%` escaping | `matlab_check` (syntax pre-flight) + `matlab_append_file` (log building without escaping) |
| A bare `clear` in user code wipes the eval marker → errors silently swallowed as success | eval detects bare `clear`/`clear all` and appends a NOTE warning |
| A 50 000-point sim array dumped as multi-MB JSON | `matlab_summary`: row budget + endpoint-preserving downsample + stats |
| Long sims were a black box | `mcp_progress(frac,msg)` in user code + `matlab_progress` to inspect after a timeout |
| End-of-session cleanup scripted by hand every time | `matlab_cleanup` |
| Layout needed (details above) | `matlab_sim_route` + `matlab_sim_arrange` pipeline |

### v2 — protocol hardening

| Problem hit in practice | v2 answer |
|---|---|
| `get`/`set` of a missing variable → worker writes no response → 60 s timeout | Every worker branch has a catch and always writes a response |
| Bare `NaN`/`Inf` in JSON → `JSON.parse` throws → server hangs | NaN/Inf serialized as strings `"NaN"`/`"Inf"` |
| `, ` after commas (python json.dumps default) → `setfield('')` crash | `json_decode` skips whitespace after commas |
| `\uXXXX`-escaped Chinese decoded again as UTF-8 bytes → all U+FFFD | pstring distinguishes raw UTF-8 bytes from `\uXXXX` escapes, mixed parsing |
| `unicode2native('')` throws "One dimension must be unary" → several tools hang | Empty-string guard first |
| Trailing comments swallowing `,catch` → syntax error | Inner multi-line try/catch (one statement per line) |
| Success detected by `strfind(txt,'ERROR:')` → user printing "ERROR:" is a false positive | Marker-variable decision + outer catch for syntax errors |
| Stale function cache after editing `.m` | `run_file` auto-clears that function + rehash; `write_file` rehashes |
| `run_file`'s `cd` permanently moves the worker cwd | oldcd saved, always restored |
| Chinese `.m` needing manual iconv | write/read auto-convert (`.m` → GBK, others UTF-8) |
| `taskkill /IM MATLAB.exe /F` kills the user's own GUI sessions | Default kills only the pidfile PID; `MCP_KILL_ALL=1` to kill all |
| `status` blind during work; timeouts indistinguishable from hangs | busy.json heartbeat; timeout errors attach busy info |
| `fig=1` was the first figure, not the current one | `fig=0` (default) = newest; `dpi`/`close` options |
| Unbounded output blowing up the MCP pipe | `MCP_MAX_CHARS` truncation (default 200 k) |
| 120 ms polling spawning tasklist | fs.watch + 100 ms fallback poll |
| `get(fig,'Number')` returns the string 'on' | number field dropped; newest-first ordering |
| Arrays serialized column-major (against JSON convention) | Row-major everywhere; column vectors flattened; N-D nesting; logical → boolean |

## Pitfall catalog (R14 vs modern MATLAB — 31 items, all circumvented in this codebase)

1. **`catch err` syntax unsupported** (R2009b+) — use bare `catch` + `lasterr`.
2. **Identifiers can't start with underscore** — `clear __x` fails ("Missing variable or function").
3. **`dir()` structs have no `datenum` field.**
4. **`sprintf('%s',…)` corrupts chars > 127 into 0x1A(SUB)** — build JSON text with `[]` concatenation + `num2str`.
5. **`fwrite`/`fread` return column vectors** — transpose when joining row-wise char.
6. **`error('id:x')` with one argument** — R14 treats it as an identifier and demands a second argument.
7. **`unicode2native('')` throws** ("One dimension must be unary") — guard empty strings first.
8. **`get(fig,'Number')` returns the string 'on'** (NumberTitle property), not a number.
9. **Encoding chain**: req.json is UTF-8 bytes; `json_decode` decodes via `native2unicode(…,'UTF-8')`; diary output is read back as GBK; responses must be written with raw `fwrite(uint8(s))` (another `unicode2native` would double-encode).
10. **`evalc` evaluates in the caller's workspace, not base** — can't replace diary + evalin.
11. **`print(handle,…)` hangs on nonexistent figures** — check `ishandle()`/`findobj` first.
12. **`strmatch` is prefix matching** — `strmatch('.m',{'.mat',…})` matches! Use `any(strcmp(…))`.
13. **JSON non-ASCII has two sources**: Node's raw UTF-8 bytes and python `json.dumps`'s `\uXXXX` (ensure_ascii default). The parser must eat both.
14. **R14 never reads `.m` as UTF-8**, regardless of `feature('DefaultCharacterSet','UTF-8')` — Chinese `.m` must be GBK.
15. **Editing worker `.m` files requires a process restart**; `clear functions` inside evalin(base) can't flush already-parsed resident code.
16. **MATLAB reshape is column-major** — `reshape(1:24,[2,3,4])`'s first page is `[1 3 5; 2 4 6]`, unlike numpy; serialize in MATLAB's actual memory order.
17. **Zombie workers with stale code can steal requests** — the server cleans protocol files at startup; `MCP_KILL_ALL=1` as a fallback.
18. **Complex `-r` statements**: put startup logic in a wrapper function; don't assemble quotes in a shell.
19. **`find_system(model,'Type','Block')` returned 0 rows on our machine** — enumerate `find_system(model)` and filter with `get_param(…,'BlockType')`. (FindAll line searches do work.)
20. **`LineHandles` hang on the destination block's Inports**; source Outports are often −1 — collect from both sides.
21. **Port handles can't be struct field names** (`num2str` yields '9.001' with a dot) — use parallel arrays.
22. **Trimmed R14 has no checkcode/mlint** — syntax-check via pcode; but pcode tolerates a missing `end`, so run a textual block-keyword balance pre-pass first (mind parentheses: the `end` in `Points(end,:)` is not a block keyword).
23. **`print('-sModelName')` always fails** ("Error using ==> graphics") — capture windows with `cap_window.ps1` instead.
24. **Worker `.m` files must be ASCII/GBK**; UTF-8 Chinese comments become mojibake and can corrupt string contents.
25. **Report progress on long tasks**: call `mcp_progress(k/n,'msg')` inside eval code; `matlab_progress` reads it back (v3.1: pollable live during the run).
26. **`[~,x] = sort(…)` unsupported** (tilde output-ignoring is R2009b+) — hand-rolled sort + find loops.
27. **Struct field names can't contain dots** — beware dynamic field names built from handle strings.
28. **Full-path `load_system` fails** ("There is no system named 'C:/…'") — `cd` into the model folder and use the bare name; subsystem root names follow the swap.
29. **`set_param(block,'Position',…)` auto-moves port anchors**, and port stub lengths vary by block type — re-read all coordinates from `PortHandles` after layout; lines don't follow moved blocks.
30. **Branch lines anchor at the trunk's branch point**: independent branch-line objects' `Points` first point is forced there, and re-routing the trunk migrates branch anchors — routers need convergence passes (else red-dashed rendering / broken lines).
31. **Ambiguous `end` in scripts**: `v(end)` fails to *parse* when `v` is only created at runtime by `load`/`sim` ("The construct v(...end...) is ambiguous... To make it a variable, assign to it") — index with `size(v,1)`/`length(v)` instead. Also `run('C:/full/path.m')` fails with a truncated error; use `cd` + bare name. Both hit while writing the exp6/exp7 model setup scripts.

## FAQ

**Which MATLAB versions does this support?**
Built and battle-tested on MATLAB 7.0 (R14), 32-bit. Other 7.x-era versions
(7.1–7.9) will probably work with minor quirks — the pitfall catalog applies
to that whole era; issues welcome. If you have R2021a+, use the official
MathWorks server instead.

**I'm on 64-bit Windows. Will it work?**
Yes — that's our dev environment (Windows 11, 64-bit, running 32-bit R14).
`MATLAB7_DIR` must point at the 32-bit install containing `bin\win32\MATLAB.exe`.

**Does it need MATLAB visible on screen?**
MATLAB is launched as a GUI process via `-r`. Code execution and sims work
fine, but the figure/window capture tools need an interactive desktop session
(they won't work from an SSH/service context).

**Will cleanup kill my own open MATLAB?**
No. By default only the worker PID this server spawned is killed.
`MCP_KILL_ALL=1` opts into killing every MATLAB.exe.

**Where do req.json / res.json / worker.pid live?**
In `MCP_WORK_DIR` (default: the server's own folder). They're runtime
artifacts, gitignored, and safe to delete while the worker is idle.

**A tool call timed out — is it dead?**
**Long-job pattern (v3.1)**: fire the eval/run_file call (the MCP client may cut
it at ~30 s — the job keeps running), poll `matlab_status` (busy? elapsed?) and
`matlab_progress` (scripted markers), then collect the console output with
`matlab_last`. If the worker is `busy` and you truly want to abort, use
`matlab_restart`. After the run finishes (or you restart), `matlab_progress` shows how far a `mcp_progress`-
instrumented eval got. Retry only if the worker is idle and the request was lost.

**Can two MCP clients share one server folder?**
No — the file protocol (req.json/res.json) is a single channel. Give each
client instance its own clone or its own `MCP_WORK_DIR`; each folder gets its
own worker process.

**Is there an npm package?**
Not yet. The repo is deliberately zero-dependency — clone and point your
client at it. Packaging PRs are welcome.

## Troubleshooting

| Symptom | Fix |
|---|---|
| First call errors "MATLAB.exe not found" | Set `MATLAB7_DIR` to the folder containing `bin\win32\MATLAB.exe` |
| First call hangs ~120 s then errors | Slow MATLAB start; raise `MCP_BOOT_WAIT` |
| Everything times out after editing helper `.m` files | Zombie worker running stale code — restart the client (server reboots worker), or one `MCP_KILL_ALL=1` pass |
| `Reference to a cleared variable` | A bare `clear` in your code (classic R14 trap) — use `clear <name>` |
| Simulink shows red-dashed lines | Usually ghost duplicate-dst artifacts — audit with `matlab_sim_info`; never script-delete by the duplicate rule |
| `matlab_figure_png` returns blank/broken | Use `matlab_window_png` with the figure title instead (R14 print limitations) |
| Chinese comments garbled in R14 editor | Save `.m` as GBK (or write through `matlab_write_file`) |

## Testing

Two layers, both runnable from a fresh clone:

```
node check_static.js          # no MATLAB needed: ASCII/tool-count/README/privacy consistency
node v3_regress.js <repo>     # full regression: real server + real R14 worker, 47 assertions
```

The regression boots a real stdio server + real MATLAB worker and runs 46
assertions across all 23 tools (currently all passing). Requires an
interactive desktop session (window capture). `v3_smoke_window.js` tests the
capture chain; `v3_smoke_arrange.js <model path>` tests the arrange+route
pipeline on any Simulink model. CI (GitHub Actions) runs the static layer on
every push; the MATLAB layer stays local because it needs a real R14 install.

## Lifecycle

- The server loads at MCP-client startup (no MATLAB yet).
- The first tool call boots the MATLAB worker (~2 s); it stays resident.
- A crashed worker is auto-detected and restarted on the next call (base
  workspace lost; `worker_init.m` runs at boot if present — handy for addpath).
- Worker is killed when the MCP client exits (shutdown signal handling).

## License

[MIT](LICENSE)
