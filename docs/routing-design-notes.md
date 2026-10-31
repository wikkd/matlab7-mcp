# Simulink official line routing — design logic vs mcp_sim_route

Research notes, 2026-10-31. Sources at the bottom. Motivation: v3/v3.1 router
was built empirically against R14's storage quirks; this note records what the
official (R20xx+) router is documented to do, the published algorithm family
behind that behavior, and what is worth adopting.

## Official timeline

| version | what changed |
|---|---|
| R14 (2004) | no auto-routing of existing lines at all (the gap this tool fills) |
| R2012b | **Smart Signal Routing** ships with the new Simulink Editor |
| R2015b/R2016a | editor polish; Auto Arrange button (Format tab) |
| R2019b | programmatic API: `Simulink.BlockDiagram.routeLine(h)`, `arrangeSystem(h)`; batch mode via `set_param(0,'LineUpdate','deferred')` + `routeLine('DeferredLines')` |
| current (R2026b docs) | same API surface; doc states the routing goal verbatim |

## The official design criteria (verbatim quotes)

Guy on Simulink, "Smart Signal Routing" (Oct 2012), on what "optimal path"
means when the editor draws a line:

> "as short as possible, has minimal 90 degree turns, and doesn't overlap
> other blocks and text"

And on incrementality:

> "Part of the smartness of the smart signal routing algorithm is to know
> when to leave a signal alone. It's what we call **minimum disturbance**."
> (existing lines are disturbed as little as possible while blocks move)

Current programmatic-API doc (Configure Model Layout Programmatically):

> "The functions route signal lines to **avoid overlap with blocks,
> annotations, and other signal lines**."

So the official objective is: shortest × fewest bends × no overlap with
blocks/annotations/**other lines**, computed incrementally.

## Published algorithm family behind this behavior

MathWorks does not publish internals, but the behavior matches the orthogonal
connector-routing literature:

- Wybrow, Marriott, Stuckey — *Incremental Connector Routing* (Graph Drawing
  2005), the basis of **libavoid** (Adaptagrams): A* shortest-path search over
  a dynamically maintained orthogonal visibility graph (scanline structure);
  path cost = length + bend penalty (+ crossing penalties); incremental
  recomputation fast enough to reroute during interactive dragging;
  **hyperedge routing** for connectors sharing an endpoint (our branch
  fan-out case) and a **nudge** post-pass that separates segments sharing a
  corridor. Related: Rüegg et al., *Stress-Minimizing Orthogonal Layout of
  Data Flow Diagrams with Ports* (arXiv:1408.4626) for the layout side.

## Mapping: official criterion → mcp_sim_route v3.1 status

| official criterion | v3.1 status |
|---|---|
| shortest path | SAFE-Z channel candidates are length-equivalent; detour lanes scanned nearest the signal rows first |
| minimal 90° bends | strategy order prefers fewer bends (straight 0 → SAFE-Z 2 → anchor-lane 2 → go-around 4) |
| no overlap with blocks & text | block bodies + name-label rects (Java font metrics) as obstacles |
| no overlap with **other lines** | **not implemented** — the main true gap |
| minimum disturbance | junction stubs anchored at the source; per-line routing never moves unrelated lines; re-routes only invalid shapes |
| branch fan-out (hyperedge) | junction stub + segments fork at one T (same idea as libavoid hyperedges) |
| batch/deferred routing | one call routes every line of a layer in a fixed order (trunks → segments → convergence) |

## v4 roadmap (adopting the official logic)

1. **Line-line avoidance / nudge** (highest value, matches official objective):
   post-pass that detects two routed lines sharing a corridor segment and
   nudges one lane over (libavoid-style); or treat existing line segments as
   soft obstacles with a crossing penalty during the lane scan.
   **DONE (2026-10-31, mcp_sim_route v4):** wire map with family ids, soft
   last-priority lane/channel avoidance, nudge pass with hard-banned
   colliding coordinates; R14-forced segments (anchor-collinear exit runs,
   approach rungs, canonical elbow columns, port stubs) are exempt as nudge
   targets. Verified on Comm_Link / EV_Drag_Power / Exp7_Rint_Battery:
   super_before = super_after = 0 on all three (soft avoidance alone), 0
   failed, 0 non-orthogonal, sim anchors identical.
   **v4.1 (2026-10-31) — entry-lane de-confliction**, the blind spot the
   wire map could not see: R14 pins the stored tail to the canonical elbow
   `(dst_x-10, dst_y)` (README law 11), so every line entering a block-edge
   column descended the SAME vertical — 13 cross-signal superpositions on
   EV_Energy_Range alone, invisible to `wire_count_super` because both
   sides are R14-forced segments. `ex_pick` now steps the descent column
   left in 10 px while another family occupies the descent span (or the
   dst-row rung would overlap, or blocks/labels sit on it), and the stored
   tail ends at the canonical elbow explicitly — R14 rewrites the last
   stored point to the elbow otherwise and shears a diagonal (this broke
   53 lines at first attempt; probes caught it). Vertical-entry ports whose
   bare probe discovers no elbow keep the unshifted descent. Independent
   audit: 13 → 0 cross-family overlaps, 3 → 0 diagonals, sim anchors
   (E/SOC/mileage) bit-identical; Comm_Link / exp6 / exp7 regression all 0
   failed, cross-family 0.
2. **A\* middle-section search**: keep the R14-compatible serializers
   (SAFE-Z / anchor-lane / go-around with the calibrated elbow tail — they
   exist because of the storage laws, see README "R14 line-semantics laws"),
   but let a small A\* over an obstacle-corner grid choose the mid-section
   with cost = length + λ·bends. Replaces strategy enumeration with true
   optimality in dense diagrams.
3. **Minimum-disturbance prefilter**: route only lines whose stored shape is
   non-orthogonal or hits an obstacle (v3 already re-routes everything on
   call; a flag could skip already-clean lines for interactive use).
4. **Shared-corridor bundling for >2 branches** (libavoid hyperedge nuance):
   currently all segments fork at one T; bundling would merge their exit runs
   until their lanes diverge.

## Sources

- Guy on Simulink — Smart Signal Routing (2012-10-11):
  https://blogs.mathworks.com/simulink/2012/10/11/smart-signal-routing/
- Configure Model Layout Programmatically (routeLine / arrangeSystem,
  R2019b+): https://www.mathworks.com/help/simulink/ug/configure-model-layout-programmatically.html
- Wybrow, Marriott, Stuckey — Incremental Connector Routing (GD 2005);
  Adaptagrams / libavoid: https://www.adaptagrams.org/documentation/libavoid/
- Rüegg et al. — Stress-Minimizing Orthogonal Layout of Data Flow Diagrams
  with Ports: https://arxiv.org/abs/1408.4626
