# res-retry-pointer · tasks

两个 task 写同一个文件 `Sources/main.swift`，**必须严格串行**：T1 验收通过后才开始 T2。两者改动的代码段互不相交。

## T1 · 分辨率按屏重试（A）
- 允许改动：`Sources/main.swift`，仅限以下位置：
  - `Resolution` 类：第 344 行属性，新增 `pending`。
  - `Controller.apply(_:)`：第 571-575 行、第 589 行。
  - `setResChoice`：第 813 行。
  - `toggleShrink`：第 822 行。
  - `cmdSelftest`：在 2c' 之后追加 A 的 5 条用例。
- 禁止改动：断开分支的 `restore()`（第 588 行）、`quitApp`（第 835 行）、信号处理器（第 1124 行），以及 `apply/restore/plan` 的实现。
- 实现：按 design.md A 节执行。
- 验收：
  1. 编译命令退出码为 0。
  2. `--selftest --no-display` 输出 ALL PASS，PASS 数为 65（基线 60 加 5）。
  3. `grep -n "\.attempted\b\|var attempted " Sources/main.swift` 无结果。

## T2 · 移动鼠标/滚轮即揭幕（B）
- 允许改动：`Sources/main.swift`，仅限以下位置：
  - `Settings`：新增 `revealOnPointer`。
  - 新增 `struct MotionGate`，放在 `RevealMachine` 之后。
  - `Controller`：新增属性（`motion`、两个首事件标记、`itemPointer`），以及 `raise`、`deskTouched`、`handleTap`、`setupUI`、`menuNeedsUpdate`；新增 `toggleRevealPointer`。
  - `cmdDoctor` 的 settings 行、启动日志行。
  - `cmdSelftest`：追加 B 的 8 条用例。
- 禁止改动：`handleTap` 第 679 行的 pid 判定、逃生键逻辑、5s 节流值、`RevealMachine`。
- 实现：按 design.md B 节执行。
- 验收：
  1. 编译命令退出码为 0。
  2. `--selftest --no-display` 输出 ALL PASS，PASS 数为 73（65 加 8）。
  3. `--doctor` 的 settings 行包含 `revealOnPointer=true`。
