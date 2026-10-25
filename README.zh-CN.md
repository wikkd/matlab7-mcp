<div align="center">

# matlab7-mcp

**让 AI 助手操控 MATLAB 7.0 (R14, 2004) 的 MCP 服务器——22 个工具、零 npm 依赖、Simulink 正交自动布线与块自动重排**

[English](README.md) | [简体中文](README.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-Windows%20XP--11-blue)
![Node](https://img.shields.io/badge/node-%E2%89%A516-green)
![MATLAB](https://img.shields.io/badge/MATLAB-7.0%20(R14)%20%7C%202004-lightgrey)
![License](https://img.shields.io/badge/license-MIT-yellow)
![Tests](https://img.shields.io/badge/regression-47%2F47%20pass-brightgreen)

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

- `mcp-server.js` — MCP stdio 服务器：22 个工具定义、参数校验、请求文件、
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
   预期 47/47 断言通过。如果截图相关断言失败，说明窗口抓取需要交互式桌面
   会话，报告其余哪些断言通过即可。
5. 汇报：仓库路径、MATLAB 根目录、改了哪个配置文件、回归结果，以及还需要
   我手动做什么（重启客户端）。

约束：不要改动仓库里的任何文件——配置修改只发生在客户端自己的配置文件里。
如果 MATLAB7_DIR 无法确定，直接问我，不要猜。
```

AI 部署完成后，重启 MCP 客户端，说一句"列出我的 MATLAB workspace"即可确认。

## 工具清单（22 个）

**执行与诊断**

| 工具 | 功能 |
|---|---|
| `matlab_eval` | base workspace 执行代码（含 `sim('model')`）；语法/运行时错误可靠上报；可选 `check_first` 先查后跑 |
| `matlab_check` | 语法检查不运行：块关键字配平 + pcode 全量解析 |
| `matlab_run_file` | 运行 `.m` 文件（自动 clear 该函数缓存、恢复工作目录） |
| `matlab_status` / `matlab_restart` | worker 状态（含当前 busy 命令）/ 重启 |
| `matlab_progress` | 读回最近一次 eval 里 `mcp_progress(frac, msg)` 的打点（server 在 eval 期间阻塞，适合超时后查看跑到哪了） |

**数据与文件**

| 工具 | 功能 |
|---|---|
| `matlab_get_var` / `matlab_set_var` | workspace 变量 JSON 读写 |
| `matlab_summary` | 大数组带预算读取：meta + min/max/mean/std + 端点保留降采样 |
| `matlab_workspace` | 列出 workspace 变量（名称/类型/尺寸） |
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
| `matlab_sim_info` | 模型审计：幽灵线（重复目标）、孤儿线段、未连接端口（可选自动修复） |
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
8. **回归测试是每次重构的安全网。**47 组断言跑在真 stdio server + 真 MATLAB
   上（GBK 往返、NaN 序列化、幽灵线审计、clear 警告与 progress 生命周期），
   让 22 个工具的 v3 大修零伤亡落地。

## 版本演进

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
    `matlab_progress` 读回（事后查看——server 在 eval 运行期间是阻塞的）。
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
先查 `matlab_status`：如果 worker 是 `busy`，说明还在跑——加大超时继续等，
或 `matlab_restart` 中止。跑完（或重启）之后，`matlab_progress` 可以看到
带 `mcp_progress` 打点的 eval 跑到了哪。只有 idle 且请求确认丢了才重试。

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
node v3_regress.js <仓库目录>   # 全量回归：真 server + 真 R14 worker，47 组断言
```

回归测试起真 stdio server + 真 MATLAB worker，跑 47 组断言覆盖全部 22 个工具
（当前全过）。需要交互桌面会话（窗口截图）。`v3_smoke_window.js` 单测截图
链路；`v3_smoke_arrange.js <模型路径>` 在任意 Simulink 模型上单测
arrange+route 管线。CI（GitHub Actions）在每次 push 时跑静态层；MATLAB 层
依赖真机 R14，留在本地跑。

## 生命周期

- MCP 客户端启动时加载 server（暂不启动 MATLAB）。
- 首次工具调用启动 MATLAB worker（约 2 秒），之后常驻。
- worker 崩溃时下一次调用自动检测并重启（base workspace 丢失；若存在
  `worker_init.m` 会在启动时执行——适合做持久 addpath）。
- MCP 客户端退出时杀掉 worker（shutdown 信号处理）。

## 许可证

[MIT](LICENSE)
