# res-retry-pointer · test-plan

## 自动（每个 task 都要跑，必须附上命令、退出码和输出摘要）
```bash
cd <repo> && swiftc -O -swift-version 5 Sources/main.swift -o /tmp/veil_rr -framework Cocoa -framework Carbon -framework ApplicationServices -framework IOKit; echo "exit=$?"
/tmp/veil_rr --selftest --no-display; echo "exit=$?"
/tmp/veil_rr --selftest --no-display | grep -c '^PASS'   # T1 后 65,T2 后 73
```
基线（主理人已确认）：60 PASS。注意 DisplayKey 用例的条数取决于本机显示器数量，如果显示器数量变化，要以同一环境下的基线为准再做比较。

## 新增 selftest 用例

**A：`Resolution.pending`，共 5 条**

| # | 输入 | 期望 |
|---|---|---|
| A1 | active=[] attempted=∅ | [] |
| A2 | active=[3,4,29] attempted={3,4} | [29] |
| A3 | active=[3,4] attempted={3,4,29} | []（临时屏消失后不重试，已试过的不再试） |
| A4 | active=[4,3,4] attempted=∅ | [4,3]（去重并保持顺序） |
| A5 | 复现 23:53 日志的序列：tick1 active=[] → [] ；tick2 active=[3,4] → [3,4]，并插入 attempted；tick3 active=[3,4] → []；复位（removeAll）后 tick4 active=[3,4] → [3,4] | 四步全部符合 |

**B：`MotionGate`，共 8 条**

| # | 输入 | 期望 |
|---|---|---|
| B1 | 单次 feed(10, t=0) | false |
| B2 | 在 t=0, 0.2, 0.4, 0.6 各 feed(10) | 前三次 false，第 4 次 true |
| B3 | 紧接 B2 之后 feed(10, t=0.7) | false（触发后清零） |
| B4 | 新 gate：feed(30, t=0)，然后 feed(30, t=1.5) | 两次都 false（窗口过期重开） |
| B5 | 新 gate：feed(39) 为 false；另一个新 gate：feed(40) | 前者 false，后者 true（边界） |
| B6 | 抖动：每 0.5s feed(3)，持续 10s | 全程 false |
| B7 | `distance(dx:3, dy:4)` | 5；`scrollIntent([0,0,0,0])` 为 false，`scrollIntent([0,-1,0,0])` 为 true |
| B8 | feed(30) 后 reset()，再 feed(30) | false |

## 手动真机验证（本方案未执行，由用户执行）
- **M1**：显示器睡眠时发起远程连接。期望日志依次出现 `new display(s) online [3, 4]`、`resolution: applied …`、`re-asserted`，现场全程黑屏（允许亮屏不到 1s）。
- **M2**：断开远程。期望出现 `resolution: restored …`；再连一次，应再次对每块屏各尝试一次。
- **M3（关键，先在辅助功能已授权的环境下做）**：帘幕期间，**远程端**移动鼠标并滚动。期望不揭幕，日志 `first passed event` 中 pid≠0。如果出现 `first swallowed event` 或 `desk trigger` 由远程操作引起，说明 R1 成立：立刻关闭 `revealOnPointer`，并回报 stateID。
- **M4**：帘幕期间，**现场**轻碰鼠标（位移小于 40）不揭幕；明显移动或滚一下滚轮时揭幕并锁屏。日志出现 `desk trigger type=… stateID=… accum=…`。
