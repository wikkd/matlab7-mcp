<div align="center">

# matlab7-mcp

**让 AI 助手操控 MATLAB 7.0 (R14, 2004) 的 MCP 服务器——28 个工具、零 npm 依赖、Simulink 正交自动布线与块自动重排**

[English](README.md) | [简体中文](README.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-Windows%20XP--11-blue)
![Node](https://img.shields.io/badge/node-%E2%89%A516-green)
![MATLAB](https://img.shields.io/badge/MATLAB-7.0%20(R14)%20%7C%202004-lightgrey)
![License](https://img.shields.io/badge/license-MIT-yellow)
![Tests](https://img.shields.io/badge/regression-76%2F76%20pass-brightgreen)

</div>

> **关键词**：MATLAB 7.0 · MATLAB R14 · 老版本 MATLAB · 学校机房 · 实验课 ·
> MCP · Model Context Protocol · Simulink 自动布线 · 正交布线 · 自动布局 ·
> Sugiyama 分层 · AI 助手 · Claude Desktop · Cursor · ZCode · Cline · Windows

## 为什么有这个项目

很多学校的实验课至今还在用 **MATLAB 7.0 (R14)**——2004 年发布的版本——因为老
的校园授权、旧讲义和从未移植的工具箱。如果你的处境是这样，你一定撞过这些墙：

- **MathWorks 官方 MCP server 要求 R2021a+**，R14 上没戏。
- MATLAB 的 **COM/ActiveX 自动化接口在 Win11 + 现代 CPU 上确定性崩溃**
  （`m_interpreter.dll` 段错误），我们认真试过，救不回来。
- R14 剩下的**唯一可靠程序化通道**是 `MATLAB.exe -r` + 常驻 worker 进程 +
  文件协议。

本项目就是这个通道的完整实现，封装成标准 MCP stdio server，并已在
**一门 8 次实验的大学课程**（建模 + 仿真 + 报告生成）里全程实战——整个课程的
实际工作由 AI 助手完成。

## 这适合你吗？

| ✅ 适合，如果…… | ❌ 不适合，如果…… |
|---|---|
| 学校/实验室**强制使用 MATLAB 7.0 / R14**（或其他 2010 前版本）做实验和报告 | 你有 **R2021a 或更新版本** → 直接用[官方 server](https://github.com/mathworks/MATLAB-MCP-server) |
| 你想让 Claude / Cursor / ZCode / 任何 MCP 客户端跑 MATLAB 代码、读变量、导图 | 你用 Linux/macOS（本桥仅限 Windows——反正 R14 也只能在 Windows 上跑） |
| 你想让 **Simulink 框图自动布线**（横平竖直、不压器件）、**模块自动重排** | 你只需要无界面批处理（图窗/窗口截图需要桌面会话） |
| 你维护老 Simulink 模型，害怕每次重画所有连线 | |

## 工作原理

```
MCP客户端 ──MCP stdio──> mcp-server.js (Node, 零依赖)
                          │  写 req.json / 读 res.json（UTF-8 JSON）
                          ▼
                 MATLAB.exe -r "mcp_worker(...)"   ← 常驻进程，启动 ~2s
                          │  轮询请求 → evalin('base',...) → diary 捕获输出
                          ▼
                       base workspace / figure / Simulink
```

- `mcp-server.js` — MCP stdio 服务器：28 个工具定义、参数校验、请求文件、
  `fs.watch` 响应监视（100ms 兜底轮询）、`busy.json` 心跳。
- `mcp_worker.m` — R14 内常驻 worker：轮询请求 → base workspace 求值 →
  diary 捕获输出 → 序列化写响应。**所有分支都有 catch，worker 必定回话。**
- `json_decode.m` / `mcp2json.m` — R14 兼容双向 JSON（NaN/Inf、`\uXXXX` 与
  raw UTF-8 双来源、N-D 嵌套、行主序）。
- `cap_window.ps1` — PowerShell 窗口截图（R14 的 `print('-sModel')` 已损坏不可用）。
- `mcp_check`、`mcp_sim_route`、`mcp_sim_arrange`、`mcp_sim_audit`、
  `mcp_sim_clean`、`mcp_progress` — 各工具背后的辅助函数。

单次工具调用时延：**0.3–0.5 秒**。

## 环境要求

- Windows（开发与验证环境：Windows 11 跑 32 位 MATLAB 7.0）
- 已安装 MATLAB 7.0 (R14)——必须存在 `bin\win32\MATLAB.exe`。
  其他 7.x 时代版本大概率可用（未逐一测试）；R2021a+ 请用官方 server。
- Node.js ≥ 16。**无需 npm install——零依赖。**

## 快速开始（5 分钟）

1. 没有Node.js 的话先装一个（任意现行 LTS 版本）。
2. **找到你的 MATLAB 根目录**——即包含 `bin\win32\MATLAB.exe` 的文件夹。
   常见位置：`D:\MATLAB7`、`C:\MATLAB7`。装在别处的话，在下面的配置里设
   `MATLAB7_DIR`。
3. **克隆本仓库**（或下载 ZIP 解压到任意位置）：
   ```
   git clone https://github.com/wikkd/matlab7-mcp.git
   ```
4. **在 MCP 客户端里注册服务器。**下面这段 JSON 对 Claude Desktop
   （`claude_desktop_config.json`）、Cursor（`mcp.json`）、ZCode
   （`config.json` → `mcp.servers`）以及大多数 stdio MCP 客户端通用：
   ```json
   "matlab7": {
     "command": "node",
     "args": ["C:\\你的路径\\matlab7-mcp\\mcp-server.js"],
     "env": {
       "MATLAB7_DIR": "D:\\MATLAB7"
     }
   }
   ```
   注意 JSON 里的路径要**双反斜杠**。MATLAB 装在自动探测位置的话可省略
   `MATLAB7_DIR`。
5. **重启客户端**，然后让 AI 做点小事，比如"列出我的 MATLAB workspace"——
   首次调用会启动 worker（约 2 秒），之后常驻。

可选环境变量：`MCP_KILL_ALL=1`（清理时全杀 MATLAB.exe；默认只杀本 server
启动的 worker）、`MCP_MAX_CHARS`（输出截断阈值，默认 200 000）、
`MCP_BOOT_WAIT`（worker 启动等待秒数，默认 120）。

> **编码说明**：R14 永远不会按 UTF-8 读 `.m` 文件。手写含中文注释的 `.m`
> 必须存成 **GBK** 编码——更好的做法是让 AI 通过 `matlab_write_file` 写，
> 会自动转码。本仓库自带的 `.m` 在 R14 上可直接运行（仅注释里有少量 em-dash，
> 已验证无害）。

## 让 AI 自己部署（复制粘贴提示词）

上面的步骤不用手动做。把下面这段提示词直接发给你手头的 MCP 客户端 AI
（ZCode、Claude Code、Cursor agent 等），它会自己完成克隆仓库、找 MATLAB、
写客户端配置、跑回归验证的全流程：

```text
帮我部署 matlab7-mcp 桥接器，参照 https://github.com/wikkd/matlab7-mcp 的
README，全部由你自己完成：

1. 克隆 https://github.com/wikkd/matlab7-mcp 到你选择的目录（记下绝对路径）。
2. 找到我的 MATLAB 7.0 (R14) 安装目录——即包含 bin\win32\MATLAB.exe 的文件夹。
   先检查 D:\MATLAB7、C:\MATLAB7、C:\MATLAB_R14，都不在就搜索磁盘。如果 R14
   根本没装，停下来告诉我先装好，不要继续。
3. 在我的 MCP 客户端配置里注册名为 "matlab7" 的 server：command 为 "node"，
   args 指向 <仓库目录>\mcp-server.js，env 里 MATLAB7_DIR 设为第 2 步找到的
   MATLAB 根目录。JSON 路径用双反斜杠。自己判断我这台机器上正确的配置文件
   位置（Claude Desktop：claude_desktop_config.json；Cursor：mcp.json；
   ZCode：config.json 的 mcp.servers）。如果多个 MCP 客户端共用这个仓库
   目录，给每个客户端单独克隆一份——文件协议是单通道。
4. 验证桥接：用 Node 运行仓库自带的回归测试（node v3_regress.js <仓库目录>），
   预期 76/76 断言通过。如果截图相关断言失败，说明窗口抓取需要交互式桌面
   会话，报告其余哪些断言通过即可。
5. 汇报：仓库路径、MATLAB 根目录、改了哪个配置文件、回归结果，以及还需要
   我手动做什么（重启客户端）。

约束：不要改动仓库里的任何文件——配置修改只发生在客户端自己的配置文件里。
如果 MATLAB7_DIR 无法确定，直接问我，不要猜。
```

AI 部署完成后，重启 MCP 客户端，说一句"列出我的 MATLAB workspace"即可确认。

## 工具清单（28 个）

**执行与诊断**

| 工具 | 功能 |
|---|---|
| `matlab_eval` | base workspace 执行代码（含 `sim('model')`）；语法/运行时错误可靠上报；可选 `check_first` 先查后跑 |
| `matlab_check` | 语法检查不运行：块关键字配平 + pcode 全量解析 |
| `matlab_run_file` | 运行 `.m` 文件（自动 clear 该函数缓存、恢复工作目录） |
| `matlab_status` / `matlab_restart` | worker 状态（含 busy 命令与已耗时）/ 重启（`keep_workspace:true` 先把 base 工作区快照到 .mat 再杀进程，新 worker 起来后自动回载） |
| `matlab_abort` | 协作式中止（v3.4）：写旗标给 `mcp_abort_requested()` 轮询——检查旗标的长循环干净退出；从不轮询的代码仍需 `matlab_restart` 硬杀 |
| `matlab_assert` / `matlab_assert_report` | 批量判分：把布尔表达式的 PASS/FAIL 记入 worker 持久日志（抛错=FAIL）/ 汇总并可清零 |
| `matlab_last` | 最近一次已完成任务的输出——抢救被客户端超时切断的 eval 的控制台文本；`job_id` 从 20 条历史中取回更早任务，`list` 列出最近任务表 |
| `matlab_progress` | 读回最近一次 eval 里 `mcp_progress(frac, msg)` 的打点（v3.1 起可边跑边轮询——server 不再阻塞） |

**数据与文件**

| 工具 | 功能 |
|---|---|
| `matlab_get_var` / `matlab_set_var` | workspace 变量 JSON 读写 |
| `matlab_summary` | 大数组带预算读取：meta + min/max/mean/std + 端点保留降采样 |
| `matlab_workspace` | 列出 workspace 变量（名称/类型/尺寸） |
| `matlab_snapshot` | base 工作区快照到 `.mat` / 回载（自动剔除 worker 内部协议变量）；`matlab_restart {keep_workspace:true}` 的底层能力 |
| `matlab_write_file` / `matlab_append_file` | 写/追加文本（`.m` 自动转 GBK，其他 UTF-8；拒绝二进制类型） |
| `matlab_read_file` | 读文本（`.m` 自动 GBK 解码，其他 UTF-8，≤2MB） |
| `matlab_dir` | 列目录 |

**图形**

| 工具 | 功能 |
|---|---|
| `matlab_figure_png` | 导出 figure（默认最新图；`dpi`/`close` 可选），返回 MCP image |
| `matlab_window_png` | 按标题子串截取真实窗口（Simulink 编辑器、Scope） |
| `matlab_figures` | 列出打开的图窗（最新在前） |
| `matlab_cleanup` | 一键关闭全部 figure / 已加载模型 |

**Simulink**

| 工具 | 功能 |
|---|---|
| `matlab_sim_scan` | 在磁盘上对已保存的 .mdl 做正则搜索，不加载模型（R14 .mdl 是纯文本；模型坏到打不开也能搜）；传目录则递归该目录下所有 .mdl |
| `matlab_sim_info` | 模型审计：幽灵线（重复目标）、孤儿线段、未连接输入与输出端口、悬空线尾（可选自动修复） |
| `matlab_sim_clean` | 温和清理孤儿线段并保存 |
| `matlab_sim_route` | 全模型正交自动布线（见下文） |
| `matlab_sim_arrange` | Sugiyama 式块自动重排（见下文） |

## Simulink 自动布局管线

```
matlab_sim_arrange(model)   ← 按信号流分层重排模块（左→右）
matlab_sim_route(model)     ← 全部连线正交化（建议跑两轮促收敛）
```

### `matlab_sim_arrange` — 块自动重排

Sugiyama 式分层布局：① 从**目标侧**枚举边（分支边只有从 Inport 侧的线才能
看到——只扫 Outport 侧会让汇块层错乱）；② Kahn 最长路径分层，回路成员钉在
最浅已定前驱层，防止反馈链爬到 L100+；③ 两轮重心排序——**并列重心必须加位置
ε 平局破除**，否则 `find` 两次返回同一索引、行内块被静默丢掉；④ 行内堆叠、
以前层平均中轴为行中心；⑤ **x 用累计槽位**（下一层起点越过本层最宽块的右缘），
宽块不再入侵相邻层。

只动块（`set_param Position`，尺寸保留）。**线不会跟随**——之后必须跑
`matlab_sim_route`。

### `matlab_sim_route` — 正交自动布线

对每条折线（主干+分支）重新规划：同 y 直线 → SAFE-Z（出口横段+竖直通道+进场
横段，三段都做避障检测）→ 锚点垂降通道 → 绕行走线，兜底保留 R14 规范形。
每次写入后布线器都会**读回坐标并校验正交性**，最多两轮收敛扫（处理被 R14
拖走的锚点）。它**绝不删线、绝不动块**；只报告 ghost 重复目标行数（红虚线
渲染产物，不影响仿真）。

v3 布线质量规则（2026-10-30，目标：不压文字、结点干净）：

1. **名字标签=障碍。**每个可见块名标签都是布线矩形（宽 = Simulink 画布字体的
   Java 字体度量，兜底 6 px/字符；R14 默认标签在块下方）。任何车道不得穿过
   标签文字——旧的无标签布线器曾把长分支车道直接压过 "BPSK Modulator
   Baseband"。
2. **直行必须畅通。**同 y 直线只在源目标之间无遮挡时保留，否则绕行。
3. **竖直段同样检查**（锚点车道与绕行策略验证两段竖直腿，不只查横段）。
4. **绕行车道靠扫描**，不靠遮挡物极值外推——极值法在 x 跨度大时会绕到荒谬
   深度，错过行间的干净走廊。
5. **多目标端口给结点 stub。**主干折线缩成止于 J=`[port_x+12, port_y]` 的
   短线；R14 把每条分支段的锚钉在主干末点，所有分支从一个干净的 T 分叉。
   （v1 曾把主干布向最后一个目标，把结点拖到那家门上。）若某目标与端口同行
   且后方有遮挡，J 落到源块自身标签下方——同行分支段永远做不了绕行
   （见铁律 8）。
6. **软兜底**：车道过不了标签+块体时，用仅块体重试——v3 永不劣于无标签的
   v2。
7. **尾段用规范化探针校准（v3.1）。**端口 stub 语义随块类型（铁律 4）：
   `get_param Position` 可能是目标点、也可能已是 R14 的肘点（真目标 =
   Position ± (10,0)）。布线器先写裸 `[P0;dp]`，读回 R14 追加的尾段，逐线
   校准 ex/dx/dy；仍被剪（Sum 上/下进线看不到尾段）就从追加的点学出真
   (dst, elbow) 换下一策略带校准重试。exp6 的确定性肘点剪断（Gain1/Gain_m/
   Constant_Ff）正是这么消掉的。已知外观限制：上/下进线的 ~10px 进场 stub
   会穿过该块自己的名字标签——不可修，R14 本来就画在那。
8. **线-线避让（v4）**，对齐官方目标"避免与其他信号线重叠"：每条布好的线
   记入 wire map 并打家族 id（主干+其分支段同族，合法 T 叠放豁免）。被别族
   占用且跨度重叠的候选通道/车道**排最后试**（软避让）；残余的中段叠放走
   nudge 一轮——把可动一侧重布并硬禁碰撞坐标（失败回滚旧几何）。与锚共线、
   进场横段、规范肘点列属于 R14 强制段，永不当 nudge 目标——两强制段相叠是
   官方认可的合并渲染。report.super_before/super_after/nudged 量化该轮。
9. **进场车道去冲突（v4.1）**：R14 把每条存储尾段钉在规范肘点
   `(dst_x-10, dst_y)`，所有进入同一块边列的线曾共用同一条竖直车道、叠成一
   摞（EV_Energy_Range 光左列就有 13 处跨信号叠放）。`ex_pick` 优先规范列，
   但被别族竖直占用（或目标行横段将重叠、或块/标签挡道）时按 10 px 左移。
   探针实证形状：在 `X < dx-10` 垂降、沿目标行走横段、**显式存规范肘点**——
   否则 R14 改写末点剪出斜线。裸探针发现无肘点的端口（`ex == dx`，竖直进线
   的 Sum 输入）保持不移位。独立审计：跨族叠放 13 → **0**、斜线 3 → 0、
   sim 锚点逐位一致。
10. **A\* 中段搜索（v5）**——模式策略降级为已验证兜底，选路改为最优搜索。
    每网络建 Hanan 式稀疏格（块/标签边缘 ±12、端口坐标、出口 stub、进场
    车道），方向态 A\* 最小化 `长度 + 60·拐弯 + 20·跨线 + 8·拥塞`（跨线=
    垂直穿过别族线段，拥塞=距别族 10 px 内）。硬障碍：膨胀矩形（块+标签）与
    别族同向段。发射器逐字复用 v3/v4 序列化规则（探针学到的规范肘点尾、
    stub、去重、读回）；任何失败（剪断/障碍/叠放/3 万弹出预算）回退模式
    策略，且**每条失败路径都回滚尝试前几何**（修掉"原地未动却变异"的泄漏，
    重布幂等——v4.1 会被自己的输出带漂，v5 逐位稳定）。同行受阻对与竖直
    进线端口仍走模式逻辑。`opts.method='pattern'` 回到纯 v4.1；
    `opts.bend/cross/congest` 调成本。独立评分器 `mcp_sim_metrics(model)`
    （worker 侧，经 matlab_eval 调用）：斜线、越界、跨族叠放、跨线、压块/
    压标签、总长/拐弯、最坏绕行——与布线器零共享状态。四模型 A/B
    （v4.1 → v5，全部零缺陷保持）：Comm_Link 拐弯 21→**11**；EV_Drag_Power
    长度 2439→**2127**、拐弯 24→**18**；Exp7 长度 9528→**9432**、拐弯
    64→**56**；EV_Energy_Range 长度 10978→**10512**、拐弯 62→**56**、最坏
    绕行 2.7→**1.3**、基线残留 4 处缺陷→0。单模型 ≤ 10 s；sim 锚点逐位
    一致。
11. **块自动排版（v6，`mcp_sim_arrange`）**——竖单列缺陷：回路成员过去被
    压平到最浅前驱层，整条反馈链（EV_Energy_Range 的 SOC+里程双环 = 16 块）
    堆进一列。v6 用 Kosaraju 找 SCC，每个 SCC 恰剪一条边——在全部剪边组合
    里选总边跨度最小者（被剪的边仍是线，跨度参与计分）——然后普通 Kahn
    最长路径分层；重心扫改为 down-down-up-down。回路链横向铺开，回绕线落点
    与人工绘制一致（EV_Energy_Range 三列回绕）。随版修复的布线器漏洞：绕行
    模式曾让竖直进线从错误一侧穿进目标块（两条这种线还互相锁死在对方的过期
    段上——再跑一轮也救不回）；修法：末段垂降加 pullback-12px 块检查、目标
    点限制在端口外侧、law-12 尾段在 A\* 发射前预置（根除竖直进线的"发射时
    剪断"类——EV_Drag_Power 长度 2127→**2043**、Exp7 9432→**8858**）。
    标签：竖直进线块的名字尽量预移到侧边（NameLocation 可用时），布线擦过
    不可动名字由评分器报告（自身标签进场走廊 = R14 无解，豁免）；
    EV_Energy_Range 按 xgap 110 / ygap 55 重排：**全部指标为零，sim 锚点
    逐位一致**。
12. **平行贴线控制（v6.1）**——异族线相距 2..10 px 平行超过 24 px 在屏上
    读成一条合并线。四层控制：(a) 评分器统计此类对（阈值与修复器一致——
    评分器数得到的必须修得掉）；(b) A\* 拥塞层改双环（10 px 内全费率、
    10..22 px 半费率，`congest` 默认 8→12）让搜索散开车道；(c) 模式软避让
    禁用别族同向段 12 px 内的通道；(d) `ex_pick` 把 12 px 内的平行垂降
    （跨度重叠 > 24 px）视为已占用，首轮布线进场列就散开——单此一条即清掉
    Exp7 左侧 6 线并行轨道（干净重排上长度 8858→7924）——幸存对再走
    `wire_par_fixes` nudge 轮（整条拥挤带双坐标 ±8 px 禁用）。四模型从干净
    副本重验：parallel 全零，其余指标保持零，sim 锚点逐位一致。

**最小扰动模式（v6.2，`only_dirty`）**：给 `matlab_sim_route` 传
`only_dirty: true`，存储形状已正交且无遮挡的线一律不动——对齐官方
"知道什么时候别动信号"。它们的 wire map 条目照常参与避让；脏线走正常
管线。障碍检查前先剪掉端口 stub（26 px，按设计就在 margin 区里）。report
新增 `clean` = 跳过的干净线数。真实课程模型验证：
`node v62_test_onlydirty.js <仓库> <模型.mdl> ...`（干净模型 → 0 重布/
0 改动；剪断一条线 → 恰好重布该条；修复后再跑 → 严格空操作）。

### 实测结果

真实课程模型，布线/重排前后仿真输出对比：

- **exp6**（电动车拖曳功率，15 块/10 层，41 条线）：0 重叠、100% 正交，
  能耗 **1.0975 kWh 前后完全一致**。
- **exp7**（Rint 电池，36 块含 SOC+里程双反馈环）：双环都正确归位闭合，
  0 重叠、**0 斜线**，SOC 0.95 → 0.8849、里程 9.7306 km 与基线一致。

### R14 线语义铁律（逐条探针实测，改线前必读）

1. `Points` 是绝对坐标；首点强制 = 线锚（主干=源端口，分支=主干分支点），且
   **重布主干时同源分支线的锚点会跟着迁移**。
2. 主干线尾段被强制规范化为 `[...]→(dst_x-10, dst_y)→dst`；与该肘点冲突的
   中间点会被删除。
3. **共线压缩只保留每段同行中间点的最后一个**——与锚点同 x 的竖直出发中间点
   被吞掉，产生斜线。SAFE-Z 模式（出口横段同时放 `(c-8,sy)` 和 `(c,sy)` 两个点，
   保证有一个幸存）是对抗手段。
4. y 轴向下；端口 `Position` 即精确连接点；端口外伸量随块类型不同（Sum −5、
   Gain −15……）——必须从 `PortHandles` 实时读坐标，不要记常数。
5. `get_param(block,'LineHandles')` 把线挂在**目标块**的 Inport 上；源块
   Outport 常为 −1。两侧都要收集。
6. **绝不要按"同目标端口多行=ghost"的规则脚本删线**——会误删合法分支行
   （我们删过 45 条然后靠公式逐条重建模型）。本布线器只报告；删除走
   `matlab_sim_info` 的显式修复选项。
7. **分支段锚点 = 主干折线的末点**，不是内部顶点——重布主干时 R14 会把每条
   同源分支段的 `Points(1,:)` 重新钉到那里。结点放置 = 选择主干折线的终点。
8. **同行分支段（锚行 = 目标行）必剪成斜线**：R14 用规范尾段
   `[...]→(dst,dy)→(dst+10,dy)` 替换任何绕行中间点，中间点列表全灭。这类
   连接要从离开共享行的结点起布。
9. **段中间点必须止于规范肘点 `(dst-10, dy)`**，且 SAFE-Z 的
   `(c-8,sy)/(c,sy)` 成对技巧**不能用在段上**（成对会让 R14 丢掉通道）。
   主干正相反：必须成对，任意尾段会被强制规范化。探针实证形状：
   主干 `[P0;(c-8,sy);(c,sy);(c,dy);(dx-10,dy)]`，
   段   `[P0;(c,sy);(c,dy);(dx-10,dy)]`。
10. **块名标签不是暴露的几何。**封装块拒绝 `NameLocation`；文字宽度用
    `java.awt.Toolkit.getDefaultToolkit.getFontMetrics(Font('Helvetica',0,10))`
    度量（R14 拒绝链式静态调用——分两步写），位置按块下方放置。
11. **R14 会把任何 set 形状的最后一个存储点改写到规范肘点
    `(dst_x-10, dst_y)`**（不止裸主干——铁律 2 的推广）：垂降离开规范列的
    形状也必须显式以 `...;(X,dy);(dx-10,dy)` 结尾，否则改写剪出斜线。肘点
    由裸 `[P0;dp]` 探针发现；set 失败后学到的值已被污染（`Pr(end,1)` =
    dst），要重新探针而非累积。
12. **竖直进线尾段被改写为 `(dst_x, dst_y -/+ 5)`**——块边外侧靠近侧 5 px
    带。更远的尾段（dy±10/20）会被拉进来；若倒数第二点是横段端点，5 px
    平移剪出斜线（"sheared on emit"）。预置 `(dx, dy∓5)` 显式竖直尾可让
    改写变空操作。另外：**Sum 与 Constant 块拒绝 `NameLocation`**（名字
    位置不可动——R14 把它们印在下方的固定条带里，而下进线端口的进场走廊
    恰是这条条带），布线器只对接受该参数的块移标签。

## 开发经验总结（两代版本实战战损，蒸馏成 8 条）

1. **先选对通道，再写代码。**COM 看起来最"正规"但确定性崩溃；最土的 `-r` +
   文件协议反而是唯一通路。动手设计前，先花半天给每条集成通道各写一个
   hello-world 探针。
2. **worker 永远要回话。**每条错误路径都要落到协议里（必定写响应 + busy
   心跳）——否则服务器分不清"忙"和"死"，用户只能干瞪着超时。
3. **编码链先画表。**中文 Windows 上最大的时间黑洞不是算法，是"这一跳是什么
   编码"：UTF-8 请求字节 → GBK diary 读回 → 裸 `fwrite(uint8(s))` 响应。
4. **先探语义，再写算法。**R14 会静默改写你 set 的数据（锚点规范化、尾段
   规范化、共线压缩）。十个探针脚本换来上面的铁律；布线器是**照着**规律设计的，
   不是怀着希望硬写。
5. **只报告，不擅自动手。**本项目最严重的事故——按"重复目标=ghost"规则删掉
   45 条合法分支线——固化成工具纪律：布线器绝不删线，破坏性操作单独做成
   显式工具，批量删除前必须备份 `.mdl`。
6. **可信度来自读回验证，不是调用成功。**`set_param` 极少报错但可能悄悄改写
   数据；每次写后面跟一个读回断言。多个"改好了其实没改好"的 bug 都是这样抓出来的。
7. **长任务要有进度通道**——并且当心用户代码里的裸 `clear`：它会同时清掉进度
   打点和循环变量，把失败伪装成成功（eval 工具现在会检测并警告）。
8. **回归测试是每次重构的安全网。**76 组断言跑在真 stdio server + 真 MATLAB
   上（GBK 往返、NaN 序列化、幽灵线审计、clear 警告与 progress 生命周期），
   让 v3 大修零伤亡落地。

## 版本演进

### v3.4.0 — 协作式中止、工作区快照、最小扰动布线

三个从课程项目实战模式（fire → poll → collect）长出来的长任务/生命周期
功能，外加官方路由差距清单（`docs/routing-design-notes.md`）的最后一项：

- **`matlab_abort` + `mcp_abort_requested()`** — R14 无法中断运行中的代码，
  这是协作式中止通道。工具在 server 侧写旗标（瞬时，绝不排在忙 worker 的
  请求队列后面）；轮询旗标的长循环干净退出、还能带回部分结果。旗标随请求
  结束被消费、下一请求开始前被清掉，绝不泄漏到后续任务。从不轮询的代码仍需
  `matlab_restart`（硬杀不变）。路径钉法照搬 `mcp_progress`（worker 帧全局
  + 根 appdata，都能扛 `clear all`）。
- **`matlab_snapshot`** — base 工作区存/取 `workspace_snap.mat`（保存侧自动
  剔除 worker 内部 `MCP_*` 协议变量与 eval 标记，回载永不复活过期协议状态；
  变量计数走 R14 稳妥的 struct 绕行——不信任 `whos('-file')`）。
- **`matlab_restart {keep_workspace:true}`** — 快照 → 杀 → boot → 回载
  一条龙。改 worker `.m` 不再赔上工作区（旧痛点：每次改 worker 代码 base
  工作区全灭）。旧 worker 已死或忙时跳过并注明（忙 worker 收不了快照请求）。
- **`mcp_sim_route` `only_dirty`** — 最小扰动预过滤，对齐官方"知道什么时候
  别动信号"：存储形状已正交且无遮挡的线一律不动（wire map 照常记录，重布的
  邻线仍会避让它）；脏线走正常 v6.1 管线。障碍检查前先剪掉端口 stub
  （26 px）——它们按设计就在 margin 区里。真实课程模型验证见
  `v62_test_onlydirty.js`（exp7：47 线/65 recs 双反馈环；Comm_Link）：
  干净模型 → routed 0/changed 0；剪断一条线 → 恰好重布该条；修复后再跑
  → 严格空操作。回归现为 71 例 / 76 断言 / 28 工具。

### v6.1 — 平行贴线控制

异族线以 2..10 px 间距并行 > 24 px 时，屏上读成一条合并线。四层控制：
评分器按同一阈值统计（数得到的必须修得掉）→ A\* 拥塞层改双环费率（10 px 内
全费、10..22 px 半费，`congest` 默认 8→12）→ 模式软避让禁用别族同向段
12 px 内通道 → `ex_pick` 把 12 px 内平行垂降（跨度重叠 > 24 px）视为占用，
首轮布线进场列即散开（Exp7 左侧 6 线并行轨道就此消失，干净重排上长度
8858→7924）；幸存对再走 `wire_par_fixes` nudge 轮（整条拥挤带 ±8 px 禁用）。
四模型从干净副本重验：parallel 全零、其余指标保持零、sim 锚点逐位一致。

### v6 — SCC 排版：回路横向铺开

旧 arrange 的回路兜底把回路成员压平到最浅前驱层——EV_Energy_Range 的
SOC+里程双环（16 块）堆成一列。v6 用 Kosaraju 找 SCC、每个 SCC 恰剪一条边
（全组合枚举取总跨度最小，被剪边仍按线计分），再普通 Kahn 分层；重心扫改
down-down-up-down。随版修布线器三处：绕行模式可从错误一侧穿进竖直进线的
目标块（两线互锁在对方过期段上，重跑不愈）——末段垂降加 pullback-12px 块
检查、目标限制端口外侧、law-12 尾段在 A\* 发射前预置（EV_Drag_Power
2127→2043、Exp7 9432→8858）；标签预处理 + 布线后标签修复轮（Sum/Constant
拒绝 `NameLocation`）。EV_Energy_Range 按 xgap 110 / ygap 55 重排：全部
指标零，sim 锚点逐位一致。

### v5 — A\* 中段搜索：选路从枚举变最优

模式策略降级为已验证兜底；每个 net 建 Hanan 式稀疏格（块/标签缘 ±12、端口、
stub、进场车道），方向态 A\* 最小化 长度+60·拐弯+20·跨线+8·拥塞；发射器
逐字复用 v3/v4 序列化规则；任何失败回退模式策略且回滚尝试前几何（重布幂等
——v4.1 曾被自己的输出带漂）。`opts.method='pattern'` 回 v4.1；
`opts.bend/cross/congest` 调成本。新增独立评分器 `mcp_sim_metrics`（与布线
器零共享状态）。四模型 A/B：拐弯 Comm_Link 21→11、EV_Drag_Power 24→18、
Exp7 64→56、EV_Energy_Range 62→56；长度 EV_Drag_Power 2439→2127、
Exp7 9528→9432、EV_Energy_Range 10978→10512；最坏绕行 2.7→1.3、残留缺陷
4→0。单模型 ≤10 s，sim 锚点逐位一致。

### v4.1 — 进场车道去冲突

R14 把存储尾段钉在规范肘点 `(dst_x-10, dst_y)`，所有进入同一块边列的线共用
一条竖直车道叠成一摞——EV_Energy_Range 光左列 13 处跨信号叠放，且两侧都是
R14 强制段、wire 计数看不见。`ex_pick` 被占时按 10 px 左移垂降列，存储尾段
显式含规范肘点（否则 R14 改写末点剪斜线——首试剪断 53 条线，探针抓回）。
独立审计：跨族叠放 13→0、斜线 3→0，sim 锚点逐位一致；Comm_Link / exp6 /
exp7 回归全部 0 failed。

### v4 — 线-线避让（对齐官方目标）

官方目标"避免与其他信号线重叠"补齐：每条布好的线记入 wire map（主干+分支
同族，合法 T 叠放豁免）；被别族占用且跨度重叠的候选通道/车道排最后试（软
避让）；残余中段叠放走 nudge 轮，可动侧重布、碰撞坐标硬禁、失败回滚。锚共线
段/进场横段/规范肘点列识别为 R14 强制段，永不当 nudge 目标。
Comm_Link / EV_Drag_Power / Exp7 实证：super_before=super_after=0（软避让
已够）、0 failed、0 非正交、sim 锚点一致。

### v3.3.0 — 全量内部重构（审查驱动，协议零变更）

对全部代码逐行审查后做结构性重构，全程由测试网把关（重构后 56 例回归 +
17 查隔离驱动 + 专项重启验证，真 R14 上全绿）：

- **server 拆模块**：1111 行单体拆成 lib/config.js（常量/env）、
  lib/worker.js（生命周期 + 实例请求通道）、lib/tools.js（26 个 schema）、
  lib/handlers.js（26 个实现）；mcp-server.js 只留 MCP stdio 管线。schema
  与 v3.2.2 机器比对**逐字节一致**；文件协议不变。
- **worker 去样板**：五个响应构造器（resp_ok / resp_val / resp_err /
  resp_out / resp_err_out）替换约 20 处手拼括号串；eval 拆成 do_eval；
  write_file/append 共享 enc_text_bytes（路径 + 编码 + 编码为字节）。
- **三个审查修复**（契约对齐）：
  - `matlab_restart` 现在**真的**杀进程重启——旧代码在 worker 活着时直接
    早退，"重启"从不重载 worker 代码，而工具描述一直承诺 kill+restart
    （探针实证：PID 换人、重启后 eval 正常）。
  - 所有文本输出统一走 `MCP_MAX_CHARS` 截断（截断移进 textOut；此前只有
    eval/run_file/read_file/last 截断——超大的 matlab_dir 清单或
    matlab_sim_scan 输出是不设防的）。
  - 超时请求不再泄漏 pendingCmd 条目；删除死代码（sleepSync——v3.0
    Atomics 时代的阻塞遗留、figCounter）。
- CI/静态检查跟随拆分：`node --check` 覆盖 lib/*.js，协议字段守卫与隐私
  扫描读拼接后的模块源码。重启/boot 内的清扫改为先扫完再 spawn 新
  worker（await，清扫不再可能与 boot 竞态）。

### v3.2.2 — 测试网补全（56 例 + 隔离/负路径驱动）

v3.2/v3.2.1 的功能此前只临时验证过——重构把它们改坏时，旧套件照样全绿。
现在每个工具和协议失败路径都有回归覆盖：

- `v3_regress.js` 从 44 例扩到 **56 例工具用例**（59 组断言）：批量判分
  （`matlab_assert` / `matlab_assert_report`，含"抛错=FAIL"规则）、
  `matlab_sim_scan`、`matlab_last` 的 `list` / `job_id` / 越界 id 形态，
  以及 D11 回归用例——外来 cwd 里 `clear all` 不得把 `progress.json` 带偏。
- 新增 `v32_test_isolation.js`（独立隔离 `MCP_WORK_DIR`，双 server）：
  boot 清扫删光植入的死实例垃圾、运行中绝不触碰活实例文件；两个 server
  实例共享一个 worker 且各自历史文件互不串线（reply 标签）；协议负路径
  （错配 id 的陈旧 res、畸形请求 JSON、残留 busy.json）都不得卡死 worker。
- 写测试过程顺手揪出一个真缺陷：v3.2.1 的 `which()` 回退只在"server 目录
  =工作目录"布局下正确。现在 worker 在 boot 时和每个请求末把 progress
  路径同时钉在**根图形对象 appdata** 上（`setappdata(0, …)`）——R14 探针
  实证根 appdata 能扛住 `clear all`，global 不能。`mcp_progress` 在
  `which()` 之前先读它。

### v3.2.1 — 运行时卫生 + progress 路径加固

连续一周课程项目实战（2026-10-31 → 11-05）踩出来的三个缺陷：

| 症状 | 根因 | 修复 |
|---|---|---|
| `progress.json` 出现在**用户的项目目录**里，同时 `matlab_progress` 对一次 8 分钟多圈仿真全程报 "(no progress reported)" | worker boot 用 `evalin('base', …)` **在 try 块里**发布 `MCP_PROGRESS_FILE`——R14 这种方式建的 global 绑定跨请求不可靠（与 `matlab_assert` 改用 base 变量同一原因），`mcp_progress` 静默回退到 `pwd` | `mcp_progress` 回退改为 `which('mcp_progress')` 所在目录（即 server addpath 的工作目录），实在不行才用 `pwd`；worker 改为在自己函数帧直接赋值 global，并且**每个请求结束后重 assert**（用户代码 `clear all` 也能扛住） |
| 14 个死 server 实例的 `res_history_i<pid>.jsonl` / `res_last_i<pid>.json` 在工作目录永久堆积 | boot 清扫只匹配通道文件，不匹配实例历史/末次文件 | boot 清扫（只在重启死 worker 时运行，活实例文件绝不触碰）扩展到 `res_history_i*.jsonl`、`res_last_i*.json` 与 legacy `res_history.jsonl` / `res_last.json` |
| 默认名 `figure_<ts>.png` 截图无限堆积（实测 4 张） | 从来没人删 | 同一清扫顺带删 `figure_<13位时间戳>.png`；自定义 `file` 导出不受影响。`.gitignore` 顺手去重 |

### v3.2 — 对齐官方 MathWorks MCP 服务器

| 官方能力 | v3.2 对应实现 |
|---|---|
| `model_scan` — 不加载模型、在磁盘上正则搜索已保存模型 | `matlab_sim_scan`：R14 .mdl 是纯文本，磁盘搜索连模型加载都不需要——坏到打不开的模型也能搜；传目录则搜该目录全部 .mdl |
| `model_check` 的未连端口 / 悬空线检测 | `matlab_sim_info` 现在同时审计未连接的**输出**端口（此前只有输入）与悬空线尾（源正常、目标悬空）；报告新增 `nUnconnSrc` / `nDanglingTails` |


v3.2 同批 robustness 改进（来自长任务实战）：

- **任务历史环形缓冲**——每个完成的 worker 响应追加进 `res_history.jsonl`（保留最近 20 条）。`matlab_last` 新增 `job_id` 取回更早任务（此前一次后续调用会永久覆盖超时任务的输出）、`list` 列出最近任务表。
- **eval 出错带控制台上下文**——失败 eval 的 `error` 自动附 diary 尾巴（末 30 行），一次调用同时看到"错在哪 + 之前发生了什么"。
- **`mcp_check` 索引 `end` 修复**——块平衡扫描器在闭括号减深度**之后**才结算词元，导致 `f(x(end))` / `c{end}` / `a(k:end)` 被误判为块 `end` 而拒掉合法代码。现在词元先结算、深度后更新。

- **实例独立协议通道**——每个 server 进程走自己的 `req_i<pid>.json` / `res_i<pid>.json`（请求带 `reply` 标签；worker 轮询全部 `req_i*.json` + 兼容旧 `req.json`，按请求方通道回写）。两个 ZCode 会话共用 matlab7 不再互踩；MATLAB worker 与 pidfile 共享，boot.lock 防双 MATLAB 冷启动。
- **`matlab_assert` / `matlab_assert_report`**——R14 批量判分原语（无单元测试框架）：每次记录一个布尔表达式的 PASS/FAIL 到 base workspace 日志（抛错=FAIL），最后汇总分组 PASS/FAIL 表并可清零。典型流程：`matlab_run_file` 跑学生脚本 → 每个预期锚点值一条 assert → 一条 report 收尾。- `check_static.js` 的版本断言改为从 server 源码派生（格式+最低版本），升版本不再需要改测试。

其余官方接口在 R14 上不适用（`run_matlab_test_file` 依赖单元测试框架、共享会话需 R2023a+），不补。

### v3 — Simulink 布局管线 + 课程实战战损

| 实战中踩到的问题 | v3 方案 |
|---|---|
| 反复 `add_line`/`delete_block` 后出现"幽灵线"：add_line 报已连接但查不到、LineHandles=−1、孤儿线段——手工排查耗掉大半天 | `matlab_sim_info`（审计+显式修复）和 `matlab_sim_clean` |
| `print('-sModel')` 必失败（"Error using ==> graphics"） | `cap_window.ps1` + `matlab_window_png`：按标题找窗口 → 置顶/还原/缩放 → 截图 → 返回 MCP image |
| 长 `.m` 文件总被 fprintf `%%` 转义写坏 | `matlab_check`（运行前语法预检）+ `matlab_append_file`（追加建日志，无需转义） |
| 用户代码里的裸 `clear` 清掉 eval marker → 报错被吞成成功 | eval 检测裸 `clear`/`clear all` 并附加 NOTE 警告 |
| 50 000 点仿真数组吐成几 MB JSON | `matlab_summary`：行预算 + 端点保留降采样 + 统计 |
| 长仿真期间黑盒 | 用户代码内 `mcp_progress(frac,msg)` + 超时后 `matlab_progress` 查看进度 |
| 每次收尾都要手写清理脚本 | `matlab_cleanup` |
| 需要自动布局（详见上文） | `matlab_sim_route` + `matlab_sim_arrange` 管线 |

### v2 — 协议加固

| 实战中踩到的问题 | v2 方案 |
|---|---|
| `get`/`set` 不存在的变量 → worker 不写响应 → 60s 超时 | 所有分支都有 catch，必定写响应 |
| JSON 裸 `NaN`/`Inf` → `JSON.parse` 抛异常 → 服务器挂死 | NaN/Inf 序列化为字符串 `"NaN"`/`"Inf"` |
| 逗号后带空格（python json.dumps 默认）→ `setfield('')` 崩 | `json_decode` 逗号后跳空白 |
| `\uXXXX` 转义中文被当 UTF-8 字节再解码 → 全变 U+FFFD | pstring 区分 raw UTF-8 字节与 `\uXXXX` 转义，混合解析 |
| `unicode2native('')` 抛 "One dimension must be unary" → 多个工具挂死 | 空串先行守卫 |
| 行尾注释吞掉 `,catch` → 语法错误 | inner 多行 try/catch（每行一语句） |
| 成败靠 `strfind(txt,'ERROR:')` → 用户打印 "ERROR:" 即假阳性 | marker 变量判定 + 外层 catch 上报语法错误 |
| 改 `.m` 后函数缓存过期 | `run_file` 自动 clear 该函数 + rehash；`write_file` 后 rehash |
| `run_file` 的 cd 永久改变 worker 工作目录 | 保存 oldcd，必定恢复 |
| 中文 `.m` 要手动 iconv | 写/读自动转码（`.m` → GBK，其他 UTF-8） |
| `taskkill /IM MATLAB.exe /F` 会杀掉用户自己的 GUI 会话 | 默认只杀 pidfile 里的 PID；`MCP_KILL_ALL=1` 才全杀 |
| `status` 干活时瞎；超时与挂死无法区分 | busy.json 心跳；超时报错附带 busy 信息 |
| `fig=1` 是第一个图不是当前图 | `fig=0`（默认）= 最新；`dpi`/`close` 可选 |
| 输出无上限撑爆 MCP 管道 | `MCP_MAX_CHARS` 截断（默认 200k） |
| 120ms 轮询每次 spawn tasklist | fs.watch + 100ms 兜底轮询 |
| `get(fig,'Number')` 返回字符串 'on' | 去掉 number 字段；最新在前排序 |
| 数组按列主序序列化（与 JSON 惯例相悖） | 全部行主序；列向量平铺；N-D 嵌套；logical → 布尔 |

## 踩坑全录（R14 vs 现代 MATLAB，31 条，全部在本仓库代码中规避）

1. **不支持 `catch err` 语法**（R2009b+ 才有）——用裸 `catch` + `lasterr`。
2. **标识符不能以下划线开头**——`clear __x` 报 "Missing variable or function"。
3. **`dir()` 结构体没有 `datenum` 字段**。
4. **`sprintf('%s',…)` 会把 >127 的 char 破坏成 0x1A(SUB)**——含多字节文本用
   `[]` 拼接 + `num2str` 拼数字。
5. **`fwrite`/`fread` 返回列向量**——与行向量 char 拼接需转置。
6. **`error('id:x')` 单参数**——R14 把它当 identifier，要求第二参数。
7. **`unicode2native('')` 直接抛异常**（"One dimension must be unary"）——先守卫空串。
8. **`get(fig,'Number')` 返回字符串 'on'**（NumberTitle 属性值），不是数字。
9. **编码链**：req.json 是 UTF-8 字节；`json_decode` 用 `native2unicode(…,'UTF-8')`
   解码；diary 输出按 GBK 读回；响应必须裸 `fwrite(uint8(s))` 写
   （再过一次 unicode2native 会二次编码）。
10. **`evalc` 在 caller workspace 求值，不在 base**——不能替代 diary + evalin。
11. **`print(handle,…)` 对不存在的 figure 会挂起**——先 `ishandle()`/`findobj` 检查。
12. **`strmatch` 是前缀匹配**——`strmatch('.m',{'.mat',…})` 会误中！用 `any(strcmp(…))`。
13. **JSON 非 ASCII 有两种来源**：Node 的 raw UTF-8 字节与 python
    `json.dumps` 的 `\uXXXX`（ensure_ascii 默认）。解析器必须都吃。
14. **R14 永远不按 UTF-8 读 `.m`**（设 `feature('DefaultCharacterSet','UTF-8')`
    也没用）——中文 `.m` 必须 GBK。
15. **改 worker 的 `.m` 后必须重启进程**；evalin(base) 里的 `clear functions`
    清不掉常驻循环栈上已解析的代码。
16. **MATLAB reshape 列主序填充**——`reshape(1:24,[2,3,4])` 第一页是
    `[1 3 5; 2 4 6]`，与 numpy 不同；序列化按 MATLAB 实际内存布局。
17. **僵尸 worker 会用旧代码抢请求**——server 启动时清理协议文件；
    `MCP_KILL_ALL=1` 兜底。
18. **复杂 `-r` 语句**：启动逻辑放进包装函数，别在 shell 里拼引号。
19. **`find_system(model,'Type','Block')` 在本机返回 0 行**——用
    `find_system(model)` 全列出再 `get_param(…,'BlockType')` 过滤
    （FindAll 线搜索倒是可用）。
20. **`LineHandles` 挂在目标块的 Inport 上**；源块 Outport 常为 −1——两侧都收集。
21. **端口句柄不能当 struct 字段名**（num2str 产生 '9.001' 带点）——用平行数组。
22. **精简版 R14 没有 checkcode/mlint**——语法检查走 pcode；但 pcode 容忍缺
    `end`，所以先做文本级块关键字配平预检（注意括号：`Points(end,:)` 的 end
    不是块关键字）。
23. **`print('-sModelName')` 必失败**（"Error using ==> graphics"）——用
    `cap_window.ps1` 抓窗口。
24. **worker `.m` 必须纯 ASCII/GBK**；UTF-8 中文注释会乱码并可能损坏字符串内容。
25. **长任务要汇报进度**：eval 代码里调 `mcp_progress(k/n,'msg')`；
    `matlab_progress` 读回（v3.1 起可边跑边轮询）。
26. **不支持 `[~,x]=sort(…)`**（波浪号忽略输出是 R2009b+）——手写排序 + find 循环。
27. **struct 字段名不能含点**——用句柄字符串拼动态字段名时当心。
28. **全路径 `load_system` 失败**（"There is no system named 'C:/…'"）——cd 到
    模型目录用裸名；子系统根层名要跟着换。
29. **`set_param(block,'Position',…)` 会自动搬动端口锚点**，且端口外伸量随块
    类型不同——布局后从 `PortHandles` 重读全部坐标；线不跟随块移动。
30. **分支线锚在主干的分支点上**：独立分支线对象的 `Points` 首点被强制到那里，
    重布主干会迁移分支锚点——布线器需要收敛轮（否则红虚线/断线）。
31. **脚本中歧义的 `end`**：当 `v` 只由 `load`/`sim` 在运行时创建时，`v(end)` 连解析都不过（"The construct v(...end...) is ambiguous... To make it a variable, assign to it"）——改用 `size(v,1)`/`length(v)` 取末元素。另外 `run('C:/全路径.m')` 会报截断错误，用 `cd` + 裸文件名。写 exp6/exp7 模型 setup 脚本时双双踩中。

## 常见问题

**支持哪些 MATLAB 版本？**
在 MATLAB 7.0 (R14) 32 位上开发并全程实战。其他 7.x 时代版本（7.1–7.9）
大概率可用、偶有小差异——踩坑全录适用于整个 7.x 时代，欢迎提 issue。
R2021a+ 请用 MathWorks 官方 server。

**64 位 Windows 能用吗？**
能——这正是我们的开发环境（Windows 11 64 位跑 32 位 R14）。`MATLAB7_DIR`
要指向包含 `bin\win32\MATLAB.exe` 的 32 位安装目录。

**需要 MATLAB 在屏幕上可见吗？**
MATLAB 通过 `-r` 以 GUI 进程启动。代码执行和仿真没问题，但图窗/窗口截图
工具需要交互桌面会话（SSH/服务上下文里不可用）。

**清理时会不会杀掉我自己开着的 MATLAB？**
不会。默认只杀本 server 启动的 worker PID。`MCP_KILL_ALL=1` 才会全杀。

**req.json / res.json / worker.pid 在哪？**
在 `MCP_WORK_DIR`（默认 server 所在文件夹）。都是运行时产物，已 gitignore，
worker 空闲时可安全删除。

**工具调用超时了——是死了吗？**
先查 `matlab_status`：如果 worker 是 `busy`，说明还在跑——加大超时继续等。
真要中止，先试 `matlab_abort`（v3.4 协作式：跑着的循环轮询
`mcp_abort_requested()` 就会干净退出），不行再 `matlab_restart` 硬杀（base
工作区丢——要留就用 `matlab_restart {keep_workspace:true}`）。跑完（或重启）
之后，`matlab_progress` 可以看到带 `mcp_progress` 打点的 eval 跑到了哪。
只有 idle 且请求确认丢了才重试。

**两个 MCP 客户端能共用一个 server 目录吗？**
不能——文件协议（req.json/res.json）是单通道。每个客户端实例用自己的克隆
或自己的 `MCP_WORK_DIR`；每个目录一个 worker 进程。

**有 npm 包吗？**
还没有。仓库刻意零依赖——clone 后把客户端指过去即可。欢迎打包 PR。

## 故障排查

| 症状 | 处理 |
|---|---|
| 首次调用报 "MATLAB.exe not found" | 把 `MATLAB7_DIR` 设到包含 `bin\win32\MATLAB.exe` 的目录 |
| 首次调用挂 ~120s 后报错 | MATLAB 启动慢；调大 `MCP_BOOT_WAIT` |
| 改过辅助 `.m` 文件后所有调用超时 | 僵尸 worker 在跑旧代码——重启客户端（server 会重启 worker），或 `MCP_KILL_ALL=1` 清一次 |
| `Reference to a cleared variable` | 代码里有裸 `clear`（R14 经典坑）——改用 `clear <name>` |
| Simulink 显示红虚线 | 通常是 ghost 重复目标产物——用 `matlab_sim_info` 审计；绝不要按重复规则脚本删线 |
| `matlab_figure_png` 返回空白/损坏 | 改用 `matlab_window_png` + 图窗标题（R14 print 的局限） |
| 中文注释在 R14 编辑器里乱码 | 把 `.m` 存成 GBK（或经 `matlab_write_file` 写入） |

## 测试

两层测试，clone 后即可运行：

```
node check_static.js          # 无需 MATLAB：ASCII/工具数/README/隐私一致性
node v3_regress.js <仓库目录>   # 全量回归：真 server + 真 R14 worker，76 组断言
node v32_test_isolation.js    # 隔离工作目录：boot 清扫、双实例共享、协议负路径
```

回归测试起真 stdio server + 真 MATLAB worker，跑 76 组断言覆盖全部 28 个工具
（当前全过）。需要交互桌面会话（窗口截图）。`v3_smoke_window.js` 单测截图
链路；`v3_smoke_arrange.js <模型路径>` 在任意 Simulink 模型上单测
arrange+route 管线。隔离驱动在独立 `MCP_WORK_DIR` 里运行，额外验证 boot
卫生、实例共享与协议失败路径。CI（GitHub Actions）在每次 push 时跑静态层；
MATLAB 层依赖真机 R14，留在本地跑。

## 生命周期

- MCP 客户端启动时加载 server（暂不启动 MATLAB）。
- 首次工具调用启动 MATLAB worker（约 2 秒），之后常驻。
- worker 崩溃时下一次调用自动检测并重启（base workspace 丢失——计划内重启用
  `matlab_restart {keep_workspace:true}` 快照并回载；若存在 `worker_init.m`
  会在启动时执行——适合做持久 addpath）。
- MCP 客户端退出时杀掉 worker（shutdown 信号处理）。

## 许可证

[MIT](LICENSE)
