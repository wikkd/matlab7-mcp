# v5 router design — A\* mid-section search, quality first

Design note, 2026-10-31. Goal: **routing quality first** (效果为优) — the
router should produce layouts a human would accept as "well routed", not
merely legal. Runtime is secondary (batch tool, ≤60 s/model acceptable).

## 1. What "better" means (measurable)

The official criteria (shortest × fewest bends × no overlap with blocks,
text, other lines) plus tidiness. Operationalized as a metric suite computed
from stored geometry AFTER routing, independently of the router's own state:

| metric | v4.1 state | v5 target |
|---|---|---|
| failed lines | 0 | 0 |
| non-orthogonal segments | 0 | 0 |
| cross-family colinear overlaps (incl. forced-forced pairs) | 0* | 0 |
| block-body hits / label hits | 0 / 0 | 0 / 0 |
| total wire length | baseline | ≤ baseline |
| total 90° bends | baseline | ≤ baseline |
| perpendicular crossings between nets | not counted | counted, ≤ baseline |
| detour ratio per line (len/manhattan) | ≤ 2.6 observed | ≤ 1.6 typical |
| sim anchors | identical | bit-identical |

*v4.1's `super` counter is blind to forced-forced cross-family pairs (the
13-overlap class fixed at route time by ex_pick). v5 counts them — metric
and action must not share blind spots.

## 2. Why the pattern router plateaued

v3/v4/v4.1 enumerates shape patterns (SAFE-Z, anchor-lane, go-around) with
greedy lane/channel choice + ex_pick for entry lanes + nudge. Each pattern
was forced into existence by an R14 storage law, which is the right way to
EMIT shapes — but as a SEARCH it is greedy and myopic:

- it cannot weigh "detour here vs crossing there" (no global cost);
- extreme-lane degeneracies (the y=-79 class) appear whenever the greedy
  checks reject all near lanes;
- every new collision class needed a new hand-written rule (v3 labels, v4
  wire map, v4.1 entry lanes).

The mature fix (libavoid, and every EDA maze router): separate CHOOSING the
path from EMITTING the shape, and make choosing an optimal shortest-path
search under a cost that encodes the official criteria.

## 3. Architecture: choose → emit → verify (unchanged philosophy)

```
A* (Hanan-style sparse grid, direction-state, congestion-aware)   ← chooses
   ↓  corners only
emitter: R14 serialization laws (probe-calibrated tails, stubs,
         anti-compression pairs, elbow rule)                      ← emits
   ↓  set_param
verifier: readback orthogonal + anchor + wire-map audit
   ↓ on failure
pattern strategies (v4.1 SAFE-Z/anchor-lane/go-around)            ← fallback
   ↓ on failure
restore pre-attempt geometry (minimum disturbance, mini rip-up)
```

The pattern router is kept verbatim as the fallback, so v5 can never be
worse than v4.1 on any line where A\* fails or is disabled
(`opts.method = 'pattern'`).

## 4. Search: A\* on a Hanan-style sparse grid

### Grid lines (built once per model, coordinates stay meaningful)

- x-lines: every block left/right ±12, every port x ± (10..40 in 10 px
  steps) (entry lanes), plus multiples of 20 between block edges.
- y-lines: every block top/bottom ±12, every port y, plus multiples of 20.
- Sparse lattice: for EV_Energy_Range ≈ 90 x-lines × 90 y-lines ≈ 8 k cells
  (dense-grid alternative would be 24 k with meaningless coordinates). Every
  grid line is a coordinate a human would have picked — this is where the
  "tidy" look comes from, the same reason official routing snaps to edges.

### Cell cost layers (per sweep)

1. **hard block**: blocks + labels inflated by margin — impassable.
2. **hard overlap**: cells carrying another family's same-direction segment —
   impassable (colinear overlap is the defect class).
3. **crossing cost λ_x** (default 20 px): cells carrying another family's
   perpendicular segment — legal (lines may cross) but priced, so A\*
   avoids gratuitous crossings.
4. **congestion cost λ_c** (default 8 px): cells within ±10 px of any
   other-family segment — spreads parallel runs into evenly spaced lanes;
   subsumes v4's soft lane/channel priority AND v4.1's ex_pick (entry-lane
   stepping becomes emergent: crowded canonical lanes price out).
5. **entry-lane deviation** (default 2 px per 10 px step away from the
   canonical `dx-10` column): prefers canonical entries unless crowded.

### Search state

Classic direction-augmented A\*: state = (x-cell, y-cell, arrival direction);
bend penalty λ_b (default 60 px) charged on direction change. This models
"shortest with fewest bends" exactly. Start = source port + R14 exit stub
(`sx+8, sy`, first move horizontal); goal = the dst entry segment cells
`(X, dy)` for X in the dst's entry lanes (descent column X free ≥ dx-10,
emitter appends the canonical rung). Ports whose bare probe discovers no
elbow (vertical-entry Sum inputs) get goal = cells on column dx above/below
the port, unshifted.

R14 implementation notes: no priority queue — open list as arrays with
linear min-extract is fine at ≤ 40 k states (≈ 0.1–0.5 s/net interpreted);
expansion budget per net (default 30 k pops) → budget exceeded = fall back
to patterns. Grid lines from geometry only, so the grid is built once and
only cell costs change between sweeps.

### Cost function (per net)

```
cost = length + λ_b·bends + λ_x·crossings + λ_c·congestion + λ_e·entry-dev
```

λ defaults: bend 60, crossing 20, congestion 8, entry 2 (all in px
equivalents, `opts`-overridable). Bend penalty dominates: 60 px means the
router will detour up to ~30 px on two runs to save one bend — matching the
official "as short as possible, minimal 90° turns" trade.

## 5. Global strategy over nets

- **Ordering**: most-constrained-first — multi-dst nets, then longest
  manhattan span. Hard nets get the clean corridors; short local lines fill
  in around them.
- **Hyperedge (multi-dst)**: keep the junction-stub decomposition (trunk
  source→J, segments J→dstᵢ, J anchored at source per minimum-disturbance).
  A\* routes each piece; v1 keeps the current J heuristic (source row, or
  dropped below the source label band when a same-row dst is blocked).
- **Sweeps**: sweep 1 routes everything. The existing nudge pass becomes
  sweep 2 — re-route the movable side of any cross-family pair, now with
  A\* instead of pattern retry, colliding coordinate hard-banned.
- **Rollback**: each line's Points are snapshotted before routing; if every
  strategy fails, the snapshot is restored (fixes the "left unchanged"
  lie — failed attempts used to leave mutated shapes behind).
- **Minimum disturbance** (interactive use): `opts.onlyBroken` pre-audits
  each line (orthogonal + no hits + no overlaps) and skips clean ones.

## 6. Emitter — the R14 law book, unchanged

A\* emits corners only; the emitter applies the probe-verified serialization
(exactly the v3/v3.1/v4.1 machinery, nothing new to discover):

- prepend the port stub; append the canonical elbow `(dx-10, dy)` explicitly
  when the descent column X ≠ dx-10 (README law 11 — otherwise R14 rewrites
  the last point and shears);
- same-row blocked dsts → junction dropped below the source label band
  (existing pass-1 logic, untouched);
- per-dst calibration probe (v3.1) still runs first — the A\* goal uses the
  probe-learned (dx, dy, ex), never assumed semantics;
- dedup + readback + `all_orthogonal` + wire-map audit before accepting.

## 7. Metrics tool

`mcp_sim_metrics(model)` — the independent auditor from the v4.1 session,
productized: diag segments, out-of-bbox, cross-family colinear overlaps
(separating forced-forced pairs), block/label hits, crossings, total
length/bends, per-line detour table. Runs standalone via `matlab_eval`
(no server tool registration), so the router's claims are always graded by
code that shares nothing with it.

## 8. Acceptance

On EV_Energy_Range + Comm_Link + exp6 + exp7 copies:
1. every v4.1 green metric stays green;
2. total length and total bends strictly ≤ v4.1 baseline (expect clear wins
   on EV_Energy_Range, whose v4.1 output still contains greedy detours);
3. crossings counted and ≤ baseline;
4. sim anchors bit-identical;
5. runtime ≤ 60 s/model (else budget tuning, not algorithm change);
6. offscreen render, eyeball pass.

## 9. Work breakdown

1. `mcp_sim_astar.m` — grid build, cost layers, direction-state A\*, emitter
   glue (one file; R14-safe: arrays only, no containers.Map).
2. `mcp_sim_route.m` — route_one tries A\* → patterns → restore; opts
   (`method`, `bend`, `cross`, `congest`, `entry`, `onlyBroken`, budget);
   snapshot/restore around every attempt.
3. `mcp_sim_metrics.m` — the independent grader.
4. README (rule 10), docs notes, pitfalls if new R14 laws surface.
5. Baseline capture with v4.1 before switching (metrics on all four models),
   then A/B.

Known limits carried over: top/bottom-fed Sum ports keep their ~10 px stub
across their own label (R14 port geometry, not routable); layout quality
(arrange's tall single-column layers) bounds routing quality and stays out
of scope here.

## 10. Implementation results (2026-10-31, same day)

All four acceptance criteria met on the first full run after debugging:

| model | v4.1 -> v5 total length | v4.1 -> v5 total bends | worst detour | defects |
|---|---|---|---|---|
| Comm_Link   | 1375 -> 1375   | 21 -> **11** | 1.0 -> 1.0   | 0 -> 0 |
| EV_Drag_Power | 2439 -> **2127** | 24 -> **18** | 1.8 -> 1.7 | 0 -> 0 |
| Exp7_Rint_Battery | 9528 -> **9432** | 64 -> **56** | 2.5 -> 2.3 | 0 -> 0 |
| EV_Energy_Range | 10978 -> **10512** | 62 -> **56** | 2.7 -> **1.3** | 4 -> **0** |

(EV_Energy_Range's v4.1 baseline carried 1 cross-family overlap + 1 block
hit + 2 label hits from routing over its own output — v5 is idempotent, a
second run reproduces the metrics bit-for-bit.)

A* engaged on 140/147 route attempts (EV_Energy_Range; the rest are
same-row delegations), 0.1-10 s per model, sim anchors (E=1.0957 kWh /
SOC=0.9277 / mileage=9.731 km) bit-identical.

Bugs found during bring-up, all instructive:
1. `Vc = repmat(diff(ys), 1, nx)` tiles the 1x(ny-1) row ACROSS — needs
   `repmat(diff(ys)', 1, nx)` for the (ny-1) x nx cost matrix. Hc survived
   by argument luck; Vc became a 1x((ny-1)nx) row and every wire-layer
   index silently mis-addressed (caught only via bounds errors on nets
   with >= 2 vertical lanes).
2. R14 rejects vector operands to `&&` (and this codebase's static gate
   does not catch it): `if ii <= nx && Vc(ja:jb, ii) < Inf` with a range
   `ja:jb` throws "Operands to the || and && operators..." — scalarize.
   (Plain vector `if` conditions ARE legal in R14 — red herring during
   debugging.)
3. The emit obstacle audit must skip the FIRST and LAST segments: both are
   R14-mandated port stubs that necessarily cross the margin zone.
4. The lattice boundary epsilon must match `seg_blocked_*` (touching an
   inflated rect = blocked) or A* proposes edges the verifier rejects.
5. The catch handler must capture `lasterr` BEFORE any other failing call
   — inner errors overwrite it and mask the real cause.
