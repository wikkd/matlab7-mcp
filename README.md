# matlab7-mcp — 让 MCP 客户端操控 MATLAB 7.0 (R14)

> An MCP server that lets any MCP client (ZCode / Claude Desktop / Cursor / …)
> drive **MATLAB 7.0 (R14)** on Windows — 22 tools, zero npm dependencies,
> including Simulink **orthogonal auto-routing** and **block auto-arrangement**.

让 ZCode（或任何 MCP 客户端）直接操控本机 **MATLAB 7.0 (R14)** 的 MCP server：
执行代码、读写 workspace/文件、导出图窗、给 Simulink 模型做正交自动布线与
块自动重排。全部代码零 npm 依赖，Node ≥ 16 即可运行。

**为什么会有这个项目**：MATLAB 7.0 是 2004 年的软件，官方 `mathworks/matlab-mcp-server`
要求 R2021a+；COM 自动化接口（`actxserver`）在 Win11 + 现代 CPU 上确定性崩溃
（`m_interpreter.dll` 段错误）。R14 唯一可靠的程序化通道是
`MATLAB.exe -r` 命令行启动常驻 worker + 文件协议。本项目就是这个通道的完整实现，
并在一个 8 次实验的大学课程实战（建模 + 仿真 + 报告）中迭代到 v3。

## 架构

```
MCP客户端 ──MCP stdio──> mcp-server.js (Node, 零依赖)
                          │  读写 req.json / res.json（UTF-8 JSON）
                          ▼
                 MATLAB.exe -r "mcp_worker(...)"   ← 常驻进程，启动一次 ~2s
                          │  轮询请求 → evalin('base',...) → diary 捕获输出
                          ▼
                       base workspace / figure / Simulink
```

- `mcp-server.js` — MCP stdio 服务器：工具定义、参数校验、请求写入 `req.json`、
  监视 `res.json`（fs.watch + 100ms 兜底轮询）、心跳 `busy.json`。
- `mcp_worker.m` — R14 内常驻 worker：轮询请求 → `evalin('base',…)` →
  diary 捕获输出 → 序列化写响应。所有分支都有 catch，**必定**写响应。
- `json_decode.m` / `mcp2json.m` — R14 兼容的双向 JSON（处理 NaN/Inf、
  `\uXXXX` 与 raw UTF-8 双来源、行列主序、N-D 嵌套）。
- `cap_window.ps1` — PowerShell 窗口截图（R14 的 `print('-sModel')` 在本机必失败）。
- 辅助函数：`mcp_check`（语法预检）、`mcp_sim_*`（Simulink 审计/布线/重排）、`mcp_progress`（长任务打点）。

单次工具调用时延约 0.3–0.5 秒。

## 快速开始

1. 安装 MATLAB 7.0（默认在 `D:\MATLAB7`，或用环境变量 `MATLAB7_DIR` 指定根目录，
   要求 `bin\win32\MATLAB.exe` 存在）。
2. 在 MCP 客户端配置里加：

```json
"matlab7": {
  "command": "node",
  "args": ["<仓库路径>\\mcp-server.js"],
  "env": {
    "MATLAB7_DIR": "D:\\MATLAB7",
    "MCP_WORK_DIR": "<仓库路径>"
  }
}
```

可选 env：`MCP_KILL_ALL=1`（清理时全杀 MATLAB，默认只杀自己启动的 worker）、
`MCP_MAX_CHARS`（输出截断阈值，默认 200k）、`MCP_BOOT_WAIT`（启动等待秒数，默认 120）。

3. 首次调用任意工具时自动启动 MATLAB worker（约 2 秒），之后常驻；
   MATLAB 崩溃时下一次调用自动检测并重启（base workspace 会丢失）。

注意：worker 侧 .m 文件必须以 **ASCII 或 GBK** 编码保存（R14 不认 UTF-8 源码），
`matlab_write_file` 已自动处理；仓库里现成的 .m 都是可直接运行的编码。

## 工具清单（22 个）

**核心执行**
- `matlab_eval` — base workspace 执行代码（可跑 Simulink `sim('model')`），语法/运行时错误都可靠上报；`check_first` 选项先查语法再执行
- `matlab_check` — 语法检查（不运行）：文本级块关键字配平 + pcode 全量解析
- `matlab_run_file` — 运行 .m（自动 clear 该函数缓存 + cd 恢复）
- `matlab_status` / `matlab_restart` — worker 状态（含 busy 命令）/ 重启
- `matlab_progress` — 读取长 eval 里 `mcp_progress(frac,msg)` 的打点

**数据与文件**
- `matlab_get_var` / `matlab_set_var` — workspace 变量 JSON 读写
- `matlab_summary` — 大变量带预算读取（meta/stats/端点保留降采样）
- `matlab_workspace` — 列出变量
- `matlab_write_file` / `matlab_append_file` — 写/追加文本（.m 自动 GBK，其他 UTF-8；拒绝二进制类型）
- `matlab_read_file` — 读文本文件（.m 自动 GBK 解码，≤2MB）
- `matlab_dir` — 列目录

**图形**
- `matlab_figure_png` — 导出 figure（默认最新图；dpi/close 可选），返回 MCP image
- `matlab_window_png` — 按标题子串截取真实窗口（Simulink 编辑器/Scope），配 cap_window.ps1
- `matlab_figures` — 列出打开的图窗（newest-first）
- `matlab_cleanup` — 一键关闭全部 figure / 已加载模型

**Simulink**
- `matlab_sim_info` — 模型审计：幽灵线（重复目标线）、孤儿线段、未连接端口（可 fix 自动删）
- `matlab_sim_clean` — 温和清理孤儿线段并保存
- `matlab_sim_route` — 全模型正交自动布线（横平竖直、器件避让、含分支线），见下文
- `matlab_sim_arrange` — 块自动重排（Sugiyama 分层信号流布局），配 sim_route 形成管线

## Simulink 自动布局管线

```
matlab_sim_arrange(model)   ← 分层重排块（信号流左→右）
matlab_sim_route(model)     ← 全部连线正交化（可跑两轮促收敛）
```

### matlab_sim_arrange：块自动重排

- **Sugiyama 式分层布局**：① 从 dst 侧枚举连接图（分支边必须从 Inport 侧扫——
  Outport 侧只含第一目标，漏扫会让汇块层错乱）；② Kahn 最长路径分层
  （回路成员取最浅已定前驱层，防止反馈链爬到 L100+）；③ 重心排序两轮消线交叉
  （**重心并列时必须加位置 ε 平局破除**，否则 find 返回同一索引、行内块被静默丢弃）；
  ④ 行内堆叠 + 以前层平均中轴为行中心；⑤ **x 用累计槽位**
  （下一层 x = 本层最右块右缘 + gap），宽块不再入侵相邻层。
- 只动块（`set_param Position` 保尺寸）；**线不会自动跟随**——随后必须跑 `matlab_sim_route`。
- **已验证**：exp6（15 块/10 层，零重叠，布线后 0 斜线，仿真 E=1.0975 kWh 与布局前一致）；
  exp7（36 块含 SOC/里程双反馈环，层正确归位，零重叠，0 斜线，SOC/里程与基线一致）。

### matlab_sim_route：正交自动布线

- 对模型里**每条线**（主干+分支）重算折线：同 y 直线 → SAFE-Z（出口横段+通道竖段+
  进场横段，三段都做器件避障测试）→ 锚点垂降通道 → 绕行走线（上下绕过障碍带），
  兜底保留 R14 规范形。
- **零斜线机制**：每次 set_param 后读回 Points 做正交校验，R14 改写成对角线则如实
  报告；内置收敛轮（最多 2 次）重路由被锚点迁移带歪的线。
- **不动块、不删线**；报告 ghost 重复线行数（红虚线渲染产物，不影响仿真）。
- **已验证**：exp6（41 条线）100% 正交、仿真数据与布线前一致；exp7 布局+布线后 0 斜线。

### R14 线语义铁律（程序化改布线前必读，全部逐条实测）

1. `Points` 为绝对坐标；首点强制 = 线锚（主干=源端口，分支=主干分支点，且**共源
   线的锚点会随主干路由迁移**）。
2. **主干线尾段被强制规范化**为 `[...]→(dst_x-10, dst_y)→dst`；与规范肘点冲突的
   中间点会被删除。
3. **共线压缩**：同一横/竖行上连续的中间点只保留最后一个——竖直出发的中间点
   （与锚点同 x）会被吞掉，产生对角线。SAFE-Z 模式（出口行放 `(c-8,sy)` 和 `(c,sy)`
   两个点保证幸存者）是对抗压缩的关键。
4. y 轴向下；端口 Position = 精确连接点；端口外伸量随块类型不同（Sum -5、Gain -15 …），
   必须读 `PortHandles` 实时取坐标，不能记常数。
5. `get_param(block,'LineHandles')` 的线句柄挂在**目标块**的 Inport 上，源块 Outport
   常为 -1；遍历线必须两侧都收集。
6. **绝不要**脚本化按"同目标端口多行=ghost"删线——会误删合法分支线（实战中删掉
   45 条导致模型崩溃，靠公式逐条重建恢复）。本工具只**报告** ghost 数量，删除走
   `matlab_sim_info` 的交互确认。

## 开发经验总结

这套桥在一门 8 次实验的课程里边用边改，从 v1 到 v3。回头看，最有价值的几条经验：

### 1. 先选对通道，再写代码

老版本 MATLAB 的集成方案里，COM/ActiveX 看起来最"正规"，但在新系统上是确定性崩溃，
怎么调都白搭。最后能落地的反而是最土的方案：`-r` 起常驻进程 + 文件交换。
**集成老软件时，先花半天把所有通道各写一个 hello-world 探针，确认哪条路真的通，
再决定架构**——这个半天比任何框架设计都值钱。

### 2. 协议设计的第一原则：worker 永远要回话

v1 最大的坑是"worker 内部出错就不写响应文件"，服务器端只能干等超时，而且**不知道
是挂了还是慢**。v2 把 worker 改成所有分支都有 catch、必定写响应；再加 `busy.json`
心跳（谁在跑、何时开始），超时报错才能区分"worker 忙，加大 timeout"和"请求丢了，
重试"。**给不可靠的老系统做封装，每个错误路径都要落到协议里，不能靠异常穿透。**

### 3. 编码链是中文 Windows 上最大的暗坑

整个项目最耗时的单点不是算法，是编码：req.json 是 UTF-8 字节，JSON 解析器要先
`native2unicode`；MATLAB diary 输出按 GBK 读回；响应必须直接 `fwrite(uint8(s))`
（再过一次 unicode2native 就二次编码）；R14 无论怎么设置都不按 UTF-8 读 .m 源文件，
中文注释必须 GBK。而且 JSON 有两种非 ASCII 来源（Node 的 raw UTF-8 与
Python `ensure_ascii` 的 `\uXXXX`），解析器必须都吃。**在动手之前先定一张
"数据从哪来、到哪去、每跳什么编码"的表，能省掉大量猜谜。**

### 4. 控制老 MATLAB：先实测语义，再写算法

Simulink 自动布线 v1 惨败的根因是想当然：以为 Points 就是给定的折线。实际上 R14
会强制改写你的数据（首点=锚、尾段规范化、共线压缩吞点）。后来先写了十几个探针
脚本逐条实测线语义（见上文"铁律"），算法是照着实测规律设计的。**对没有文档的
老 API，"探针→规律→算法"的顺序不能颠倒**；同理，块自动重排前也是先摸清
`set_param Position` 对端口锚点的连带影响。

### 5. 工具要"只报告、不擅自动手"

实战中最大的事故：脚本按"同目标端口多条线=ghost"规则 delete_line，一口气删掉 45
条**合法**分支线，模型直接跑崩。教训固化成了两条工具纪律：自动布线器**绝不删线**，
只报告 ghost 数量；破坏性清理单独做工具（`sim_info` 的 fix），默认只读。
**凡是批量删除，先备份 .mdl，且永远让"判断"和"执行"分成两步。**

### 6. 可信度来自"读回验证"，不是"调用成功"

R14 的 `set_param` 很少报错，但它可能默默改写你给的数据。所以 v2 布线器每次写入
Points 后都读回来自检正交性， arrange 后跑仿真对比数值。项目里多个"改好了"其实
没改好的 bug，都是靠读回校验抓出来的。**对不信任的底层，每个写操作后面跟一个读
操作做断言。**

### 7. 长任务必须有进度通道

几万点仿真跑几十秒，客户端黑盒等待体验极差。方案是在 worker 里放 `mcp_progress`
打点函数，用户代码循环里调用，客户端轮询。顺带解决了一个隐蔽 bug：用户代码里的
裸 `clear` 会清掉打点变量和 marker 变量，让"失败"伪装成"成功"——eval 现在会检测
裸 clear 并警告。

### 8. 回归测试保住每一次重构

v3 大改 22 个工具后没翻车，靠的是 `v3_regress.js`：起真 stdio server + 真 MATLAB
worker，34 组断言覆盖全部工具（含 GBK 往返、NaN 序列化、幽灵线审计）。每加一个
功能先加断言，每次改完 helper 必跑全量。**老系统折腾成本高，测试是最好的保险。**

## 版本演进

### v2 相对 v1 的改进

| 问题（v1 实际踩到） | v2 修复 |
|---|---|
| `get`/`set` 一个不存在的变量 → worker 不写响应 → 服务器挂 60s 超时 | worker 所有分支都有 catch，必定写响应 |
| `mcp2json` 输出裸 `NaN`/`Inf` → V8 JSON.parse 抛异常 → 挂死 | NaN/Inf 序列化为字符串 `"NaN"`/`"Inf"`（合法 JSON） |
| JSON 里 `, ` 后带空格（python json.dumps 默认）→ `setfield('')` 崩 | `json_decode` pobj/parr 逗号后跳空白 |
| `\uXXXX` 转义中文（python ensure_ascii）被当 UTF-8 字节再解码 → 全变 U+FFFD | pstring 区分 raw UTF-8 字节与 `\u` 转义，混合解析 |
| `jstr('')` / `mcp2json('')`：R14 `unicode2native('')` 抛 "One dimension must be unary" → figs 等命令挂死 | 空串先行返回 |
| eval 行尾注释吞掉 `,catch` → 语法错误 | inner 多行 try/catch（每行一个语句），不再靠逗号拼接 |
| eval 成败靠 `strfind(txt,'ERROR:')` → 用户打印 "ERROR:" 文本即假阳性 | marker 变量判定 + 语法错误外层 catch 上报 |
| 语法错误被静默吞掉 | 整段先 eval，语法错误进入 catch 并返回 |
| 改 .m 后 worker 用旧缓存代码，需手动 clear functions | `run_file` 自动 clear 该函数 + rehash；`write_file` 后自动 rehash |
| `run_file` 用 cd 永久改变 worker 工作目录 | 保存 oldcd，运行后必定恢复 |
| 中文 .m 必须手动 Bash+iconv 转 GBK | `write_file`/`read_file` 自动编码转换（.m→GBK，其他→UTF-8） |
| `taskkill /IM MATLAB.exe /F` 会杀掉用户自己的 MATLAB GUI | 默认只杀 pidfile 里的 PID；`MCP_KILL_ALL=1` 才全杀 |
| `status` 看不到 worker 在忙什么；超时不知道任务还在跑 | busy.json 心跳 + 超时报错附带 busy 信息 |
| `matlab_figure_png` 的 fig=1 是第一个图不是当前图 | fig=0（默认）= 最新创建的图；支持 dpi / close 参数 |
| 输出无截断，长日志撑爆 MCP | `MCP_MAX_CHARS`（默认 200k）截断 |
| 轮询每 120ms spawn tasklist | fs.watch + 100ms 兜底轮询 |
| R14 `get(fig,'Number')` 返回 'on' 字符串（NumberTitle 属性）不是数字 | figs 不再输出 number 字段，handle 排序 newest-first |
| 数组序列化列主序（与 JSON 惯例相悖） | 全类型行主序；列向量平铺；N-D 嵌套数组；logical 数组布尔化 |

### v3 相对 v2 的改进（基于全课程实战的战损清单）

| 实战中踩到的问题 | v3 方案 |
|---|---|
| Simulink 反复 add_line/delete_block 后出现"幽灵线"：add_line 报"已连接"但查不到、LineHandles=-1、孤儿线段，手工排查耗掉大半天 | `matlab_sim_info`（审计：重复目标线/孤儿线/未连接端口，可 fix=true 自动删）+ `matlab_sim_clean`（温和清理并保存） |
| `print('-sModel')` 在本机必失败（"Error using ==> graphics"），截图只能手写 PowerShell 抓窗口脚本 | 内置 `cap_window.ps1` + `matlab_window_png` 工具：按标题子串找窗口 → 置顶/还原/可缩放 → 截图返回 MCP image |
| 写长 .m 时 fprintf/sprintf `%%` 转义极易写坏，跑起来才发现 | `matlab_check`（运行前语法检查）+ `matlab_append_file`（追加模式建日志，无 fprintf 转义） |
| eval 的 marker 变量会被用户代码里的裸 `clear` 清掉 → 报错被吞成成功 | eval 后检测裸 clear/clear all 并附加 NOTE 警告 |
| 50000 点仿真数组 get_var 直接吐几 MB JSON | `matlab_summary`：行预算 + 端点保留降采样 + min/max/mean/std 统计 |
| 长仿真期间黑盒（busy.json 只有命令名） | `mcp_progress(frac,msg)` 用户代码内打点 + `matlab_progress` 工具轮询 |
| 每个实验结束都要手写收尾脚本关图窗/关模型 | `matlab_cleanup`：一键关闭全部 figure / 已加载模型 |
| 大段 GUI 截图脚本每次手写 | `matlab_window_png`（同上） |
| 布线/重排需要（见上文两个专节） | `matlab_sim_route` + `matlab_sim_arrange` 管线 |

## 踩坑全录（R14 vs 现代 MATLAB，维护必读）

R14 与现代 MATLAB 的差异，全部在本仓库代码里规避：

1. **`catch err` 语法不支持**（R2009b+ 才有）— 用裸 `catch` + `lasterr`。
2. **标识符不能以下划线开头** — `clear __x` 报 "Missing variable or function"（v2 曾因此启动失败）。
3. **`dir()` 结构体没有 `datenum` 字段**。
4. **`sprintf('%s', ...)` 会把 >127 的 char 破坏成 0x1A(SUB)** — 含多字节文本的 JSON 必须用 `[]` 拼接 + `num2str` 拼数字。
5. **`fwrite`/`fread` 返回列向量** — 与行向量 char 拼接需 `'` 转置。
6. **`error('id:x')` 单参数** — R14 把它当 identifier 要求第二参数。
7. **`unicode2native('')` 空串直接抛异常** "One dimension must be unary" — jstr/mcp2json 都要先行守卫（v2 修）。
8. **`get(fig,'Number')` 返回 'on' 字符串**（NumberTitle 属性值），不是数字 — 不要当 double 用（v2 修）。
9. **编码链**：req.json 是 UTF-8 字节；`json_decode` 用 `native2unicode(...,'UTF-8')` 解码；diary 输出按 GBK 读回；响应**直接 `fwrite(uint8(s))`**（s 已含 UTF-8 字节值，再过 unicode2native 会二次编码）。
10. **`evalc` 在 caller workspace 而非 base** — 不能用它替代 diary+evalin。
11. **`print(handle,...)` 对不存在的 figure 会挂起** — 先 `ishandle()` / `findobj` 检查。
12. **`strmatch` 是前缀匹配** — `strmatch('.m',{'.mat'...})` 会误中！精确匹配用 `any(strcmp(...))`（v2 修）。
13. **JSON 两种非 ASCII 来源**：Node `JSON.stringify` 写 raw UTF-8 字节；python `json.dumps`（ensure_ascii 默认）写 `\uXXXX`。解析器必须都能处理（v2 mixed_to_char）。
14. **R14 用 `feature('DefaultCharacterSet','UTF-8')` 也不能让它按 UTF-8 读 .m 源文件** — 中文 .m 必须 GBK 编码（write_file 的 auto 规则就是为此）。
15. **改 worker 的 .m 后必须重启 worker 进程**（taskkill 让 server 自动重启）；`clear functions` 在 evalin(base) 里清不掉常驻循环栈上已解析的函数。
16. **MATLAB reshape 列主序填充** — `reshape(1:24,[2,3,4])` 第一页是 `[1 3 5; 2 4 6]`，与 numpy 不同；行主序 JSON 化时以 MATLAB 实际内存布局为准。
17. **僵尸 worker 会用旧代码抢请求** — server 启动时清理协议文件；`MCP_KILL_ALL=1` 兜底。
18. **R14 的 `-r` 语句**：复杂启动逻辑放进包装函数，别在 shell 里拼引号。
19. **`find_system(model,'Type','Block')` 在本机返回 0 个结果**（v3 实测）— 必须 `find_system(model)` 全列出再用 `get_param(p,'BlockType')` 判别；`find_system(model,'FindAll','on','Type','line')` 倒是可用。
20. **`get_param(block,'LineHandles')` 的线句柄挂在目标块的 Inport 上**，源块的 Outport 常为 -1 — 遍历线必须两侧都收集。
21. **端口句柄不能当 struct 字段名**（num2str 后是 '9.001' 含点）— 用平行数组。
22. **本机精简版没有 checkcode/mlint** — 语法检查走 pcode；pcode 又容忍缺 end（单函数文件可省 end），所以先做文本级 for/while/if/switch/try 与 end 的配平（注意括号深度：`Points(end,:)` 的 end 不是块关键字）。
23. **`print('-sModelName')` 必失败**（"Error using ==> graphics"）— Simulink/Scope 截图走 cap_window.ps1 窗口抓取。
24. **worker .m 文件必须纯 ASCII 或 GBK**；UTF-8 中文注释会被 R14 读成乱码，导致字符串内容损坏。
25. **长任务要向用户汇报进度**：在 eval 代码里调 `mcp_progress(k/n, 'msg')`，客户端用 matlab_progress 轮询。
26. **R14 不支持 `[~,x]=sort(...)`**（波浪号忽略输出是 R2009b+）— 手写排序 + find 循环。
27. **struct 字段名不能含点**；同样 `set_param` 动态字段名也要防句柄字符串里的点。
28. **R14 不认全路径 `load_system`**（"There is no system named 'C:/...'"）— 工具内自动 cd 到模型目录后用裸名；子系统根层名要跟着换。
29. **`set_param(block,'Position',...)` 会自动搬动端口锚点**，且端口外伸量随块类型不同（Sum -5、Gain -15…）— 布局后所有坐标必须从 `PortHandles` 实时重读，线不会跟随块移动。
30. **分支线的锚点与分支点关联**：独立分支线对象（isbranch）的 Points 首点强制=主干上的分支点；重布主干会迁移分支锚点，布线器必须处理收敛（否则红虚线/断线）。

## 回归测试

```
node v3_regress.js <mcp-worker 目录>
```

起 stdio server + 真 MATLAB worker，覆盖全部 22 工具 34 组断言（当前全过）。
要求桌面会话（window_png 走屏幕抓取）；`v3_smoke_window.js` 单测截图链路，
`v3_smoke_arrange.js` 单测 arrange+route 管线（模型路径由第一个参数给出）。

## 生命周期

- MCP 客户端会话启动时 server 加载（不启动 MATLAB）。
- 首次调用任何工具时启动 MATLAB worker（约 2 秒），之后常驻。
- MATLAB 崩溃时下一次调用自动检测并重启（base workspace 丢失；`worker_init.m` 若存在会自动执行，用于持久 addpath）。
- 客户端退出时杀掉 worker（shutdown 信号处理）。
- 运行时产物（req.json/res.json/worker.pid/busy.json/progress.json）写在 `MCP_WORK_DIR`，已列入 .gitignore。

## License

MIT — 详见 [LICENSE](LICENSE)。
