# Test Materials / 测试素材

Real course-lab artifacts produced end-to-end **on MATLAB 7.0 (R14) through this MCP bridge**.
They double as regression material: if you modify `mcp-server.js`, `mcp_worker.m` or the
Simulink helpers, you can re-run these models against the stored `.mat` baselines to verify
nothing broke.

通过本 MCP 桥在 **MATLAB 7.0 (R14) 真机**上完成的真实课程实验产物。
同时可作为回归素材：改动 `mcp-server.js`、`mcp_worker.m` 或 Simulink 辅助脚本后，
重跑这些模型并与 `.mat` 基线对比，即可确认没有改坏。

> All files are desensitized: no usernames, school or course information is included
> (`LastModifiedBy` fields rewritten, no absolute paths embedded).
> 所有文件均已脱敏：不含用户名、学校与课程信息（模型 `LastModifiedBy` 已改写，无绝对路径残留）。

## Layout / 目录结构

| Dir | Model / topic | Highlights for testing |
|-----|--------------|------------------------|
| `exp1/` | BPSK 通信链路 (`Comm_Link.mdl`) + 正弦/余弦绘图脚本 | plain Simulink model, script-only experiment |
| `exp2/` | 8 个信号处理脚本 (`exp2_1.m` … `exp2_8.m`) | R14 syntax pitfalls: bare `catch`, no `[~,x]=sort`, GBK comments |
| `exp3/` | 悬挂系统仿真 (`exp3_suspension_m1/m2.mdl`) | two similar models, Symbolic Math Toolbox usage |
| `exp4/` | CLTC 工况数据清洗 (`CLTC.csv` → clean data) | 1800-point CSV I/O, statistical scripts |
| `exp5/` | 行驶阻力/功率计算 (`exp5_drag_power*.m`) | physics formulas, CSV result export |
| `exp6/` | 整车动力学模型 (`EV_Drag_Power.mdl`) + 输入数据 | 40+ block model, subsystem, FromWorkspace input |
| `exp7/` | Rint 电池 SOC/续航 (`Exp7_Rint_Battery.mdl`) | 80+ line dense model, the **routing/layout stress test**; 3 working conditions with `.mat` baselines (`exp7_base/load/cold.mat`) |
| `exp8/` | 能耗相关性/误差分析脚本 | cross-checking multiple `.mat` datasets |

## Suggested regression flow / 建议回归流程

1. Start the MCP bridge, point `MATLAB7_DIR` at your R14 install.
2. `matlab_run_file` on `exp2/exp2_1.m` … `exp2_8.m` — verifies eval/file/figure pipeline.
3. `load_system('Exp7_Rint_Battery')` (bare name! full path fails on R14) and run
   `exp7/exp7_run_base.m` after loading `exp4/CLTC_clean_data.csv`-derived `simin`
   (pre-built in `exp6/exp6_input.mat`).
4. Compare `E_base`, `soc_result(end)`, `mileage(end)` against `exp7/exp7_base.mat`.
5. Run `matlab_sim_info` on `exp6` / `exp7` models — expect zero orphan lines and
   the known benign "duplicate-dst" branch rows only.

## Known-good baselines (R14, verified) / 已验证基线

| Case | E_batt (kWh) | SOC_end | mileage_end |
|------|-------------|---------|-------------|
| base (m=1500kg, R0=0.02Ω·96) | 1.0956 | 0.8849 | 9.7306 km |
| load (m=1800kg)              | 1.2575 | 0.8737 | 9.7306 km |
| cold (R0=0.06Ω·96)           | 1.0955 | 0.8696 | 9.7306 km |
