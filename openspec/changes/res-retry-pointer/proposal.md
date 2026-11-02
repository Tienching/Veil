# res-retry-pointer · proposal

## 目标
- **A 分辨率按屏重试**：远程会话里，每块显示器**在本会话第一次处于活动状态时**各尝试调整分辨率一次。这样可以覆盖“连接瞬间显示器还在睡眠、活动列表为空”的情况。
- **B 移动鼠标即揭幕**：帘幕期间，现场移动鼠标、拖拽或滚动滚轮，也按“现场操作”处理（揭幕，并在 `lockOnDeskInput` 打开时锁屏），和 Windows 远程桌面的行为一致。

## 缺陷证据（主理人提供，Veil 日志 2026-10-30 23:53）
远程连上瞬间的日志依次是：`resolution: nothing to change`，然后 `blackout: engaged on 0 display(s) []`；0.65s 后出现 `blackout: re-asserted on [3, 4]`，期间还有临时显示器 29 短暂出现。
原因是 `resolution.attempted` 是会话级布尔（main.swift:344），在 572-575 行被置为 true 后，本会话就不会再尝试，所以 3、4 号屏的分辨率一直没有改。

## 范围
- 只改 `Sources/main.swift`。
- A：把 `Resolution.attempted: Bool` 换成每屏集合，新增纯函数 `Resolution.pending`，调整 `apply(_:)`、`setResChoice`、`toggleShrink` 以及断开时的复位。
- B：新增纯逻辑 `MotionGate`（抗抖阈值）、设置项 `revealOnPointer`（默认开）和对应菜单项，扩展 `handleTap` 的触发类型，补充诊断日志。
- 新增 `--selftest` 用例：A 5 条，B 8 条。

## 非目标
- 断开、退出（`quitApp`）、信号处理三条还原路径一行都不改（`resolution.restore()` 的语义保持不变）。
- 不改 `Resolution.apply/restore/plan`、`ResolutionPick`、`RevealMachine`、`Curtain` 的已有实现。
- 不改“只拦截 sourcePID==0”的判定，也不新增基于 `hidIdle` 的交叉校验（该 API 的语义未验证）。
- 阈值不做成可配置项（YAGNI）。

## 验收标准
1. 编译命令退出码为 0；`--selftest --no-display` 输出 `ALL PASS`，PASS 数等于基线 60 加新增 13，即 73。
2. 代码审查：572-575 行的会话级布尔不再存在；断开分支、`quitApp`、信号处理器里的 `restore()` 调用没有变化。
3. 日志可观测：A 对每块新上线的屏有 `resolution: new display(s) online …` 日志；B 触发时日志里带 `type/pid/stateID/accum`，每次帘幕期间首个放行事件和首个吞掉事件各记一条。
4. 真机验证（远程会话 + 辅助功能已授权）**由用户执行，本方案未执行**：见 test-plan.md 的 M1-M4。
