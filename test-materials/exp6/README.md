
## Fresh-session pitfall (2026-10-25)

Opening `EV_Drag_Power.mdl` / `Exp7_Rint_Battery.mdl` in a fresh MATLAB session
raises "Error evaluating parameter ... Undefined function or variable 'simin' /
'CN'": the .mdl stores parameter *expressions* (`simin`, `CN`, `R0pkg`), not
values. The models only run after the base workspace is populated:

- exp6: `load exp6_input.mat` (provides `simin`)
- exp7: `simin` + `CN=50` + `R0pkg=0.02*96`

One-shot scripts added: `exp6/exp6_setup.m`, `exp7/exp7_setup.m` (both verified
on real R14 from an empty workspace).

Two extra R14 traps found while writing them:

1. **Ambiguous `end`**: in a script, `v(end)` fails to *parse* when `v` is only
   created at runtime by `load`/`sim` ("The construct v(...end...) is
   ambiguous... To make it a variable, assign to it"). Fix: index with
   `size(v,1)` / `length(v)` instead of `end`.
2. `run('C:/full/path/script.m')` fails on R14 with a truncated error; use
   `cd` + script name. (Also: editing a script between runs needs
   `matlab_restart` / fresh session - the resident worker keeps the old parse.)
