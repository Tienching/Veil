# res-retry-pointer · design

**允许改动的文件：`Sources/main.swift`（只此一个）**

## A. 分辨率按屏重试

**1. 状态**
`Resolution` 第 344 行 `var attempted = false` 替换为：
`var attemptedDisplays = Set<CGDirectDisplayID>()`，注释为“本会话已尝试过的屏，每屏只试一次，失败也不重试”。
旧属性删除，不保留兼容 getter，这样编译器能帮忙找出所有遗留用法（grep 结果只有 572/573/589/813/822 五处）。

**2. 纯函数**（放在 `Resolution` 内，便于自检）
```swift
/// active 中尚未尝试的屏;保持 active 顺序并去重
static func pending(active: [CGDirectDisplayID], attempted: Set<CGDirectDisplayID>) -> [CGDirectDisplayID]
```

**3. 调用点**：`Controller.apply(_:)` 中 `if s.remote {` 分支的第 571-575 行替换为下面的代码，放在 `machine.step` / `raise` **之前**，以保证“先缩分辨率再首次蒙黑”的顺序：
```swift
if Settings.shrinkResolution && !headless {
    let fresh = Resolution.pending(active: Curtain.displays(), attempted: resolution.attemptedDisplays)
    if !fresh.isEmpty {
        vlog("resolution: new display(s) online \(fresh), attempting once each")
        var changed = false
        for d in fresh { resolution.attemptedDisplays.insert(d); if resolution.apply(only: [d]) { changed = true } }
        if changed && curtain.engaged { curtain.reassertIfNeeded() }   // 切模式会重置 gamma
    }
}
```
- **逐屏事务**：每块屏各调用一次 `apply(only: [d])`，不放在同一个事务里批量切换。原因是 `apply` 的事务里任何一屏失败都会 `CGCancelDisplayConfiguration` 整批回滚，临时屏（例如 29）可能连累 3、4 号屏。
- **首个 tick 有屏时**：curtain 还没有升起，先切分辨率，后面的 `raise` 再蒙黑，行为与现状一致。
- **晚上线的屏**：curtain 已经升起（0.65s 时已由 reconfig 回调补黑），在下一个 tick（不超过约 1s）切分辨率，然后立即 `reassertIfNeeded()`。另外 `displayReconfigCallback`（第 437 行）和 tick 开头的 reassert（第 543 行）也会兜底。
  **未验证**：gamma 重置是否在 `CGCompleteDisplayConfiguration` 返回前同步完成。如果是异步的，第一道 reassert 可能落空，由后两道补上，期间可能亮屏不到 1s。
- **临时显示器**：不加稳定期门槛。加门槛会让首个 tick 推迟切换，破坏顺序约束。临时屏照常尝试一次：如果它已经消失，`plan` 不包含它，只打一条 `nothing to change`；如果切成功，`saved` 会记录它，断开时 `restore()` 只配置仍处于活动状态的屏（第 403 行），并清空记录（第 408 行），不会出错。尝试过的 id 在本会话内保留，再出现也不重试。

**4. 其他调用点**
- 第 589 行断开分支：`resolution.attempted = false` → `resolution.attemptedDisplays.removeAll()`。只改这一行，第 588 行 `restore()` 不动。
- 第 813 行 `setResChoice` 守卫：`resolution.attempted` → `resolution.attemptedDisplays.contains(displayID)`。该屏已尝试过时，按新选择实时切换；还没尝试的屏由下一个 tick 按新选择处理，结果等价。
- 第 822 行 `toggleShrink`：关闭时仍调用 `restore()`；打开时 `attempted = false` → `attemptedDisplays.removeAll()`。
- 第 835 行 `quitApp`、第 1124 行信号处理器、`cmdResTest`：**不改**。

## B. 移动鼠标/滚轮即揭幕

**1. 纯逻辑**（新增，放在 `RevealMachine` 之后）
```swift
struct MotionGate {
    static let window = 1.0, threshold = 40.0
    var start = -Double.infinity, accum = 0.0
    static func distance(dx: Double, dy: Double) -> Double { (dx * dx + dy * dy).squareRoot() }
    static func scrollIntent(_ deltas: [Double]) -> Bool { deltas.contains { $0 != 0 } }
    /// 固定窗口:距窗口起点超过 window 则重开窗口;累计 ≥ threshold 返回 true 并清零
    mutating func feed(_ d: Double, now: Double) -> Bool
    mutating func reset() { start = -.infinity; accum = 0 }
}
```
- 用固定窗口（tumbling window），不用滑动窗口，实现更简单。代价是一段跨两个窗口的移动最多需要约 2 倍位移才会触发，可以接受。
- 判定用 `>`：`now - start > window` 时重开窗口；`accum >= threshold` 时触发。

**2. handleTap**（第 684-688 行）：只改硬件源分支（sourcePID==0）里的 switch，第 679 行的判定不动。
- `.keyDown` 和各类 `MouseDown`：保持不变，直接调用 `deskTouched`。
- `.mouseMoved`、`.leftMouseDragged`、`.rightMouseDragged`、`.otherMouseDragged`：在 `Settings.revealOnPointer` 打开时，计算 `motion.feed(distance(mouseEventDeltaX, mouseEventDeltaY), now)`，结果为 true 才触发。
- `.scrollWheel`：在 `revealOnPointer` 打开且 `scrollIntent([Axis1, Axis2, PointDeltaAxis1, PointDeltaAxis2])` 为 true 时触发。这样可以排除触控板只发 phase、delta 全为 0 的情况。
- 触发路径与现有一致：`DispatchQueue.main.async { self.deskTouched(...) }`，保留 5s 节流和 `curtain.engaged` 守卫。MotionGate 位于节流**上游**，两者是串联关系。
- **未验证**：`mouseEventDeltaX/Y` 是否等于屏幕像素（可能是加速后的设备单位）。这里用 delta 而不用 location，因为吞掉事件后光标位置的行为也未验证。
- tap 回调本身跑在主 runloop（第 657 行），所以 `motion` 是 Controller 的普通属性，不需要加锁。`raise()` 里执行 `motion.reset()`。

**3. 设置与菜单**
- `Settings.revealOnPointer`，key 为 `"revealOnPointer"`，默认 true。
- 菜单项 `itemPointer`，文案为“现场移动鼠标/滚轮也算现场操作”，放在 `itemLockDesk` 之后；`toggleRevealPointer()`；在 `menuNeedsUpdate` 里同步勾选状态。
- 启动日志（第 1128 行）和 `cmdDoctor` 的 settings 行追加 `revealOnPointer=`。
- 依赖：tap 只在 `blockInput` 打开且已获得辅助功能授权时安装，所以 B 也只在这个条件下生效。

**4. 日志（用于事后验证 pid 假设）**
- `deskTouched` 增加参数 `why: String`。触发时记录：`input: desk trigger type=<rawValue> pid=<…> stateID=<eventSourceStateID> accum=<Int>`。由于前面已按 pid 过滤，这里 pid 恒为 0，关键看 stateID。
- 每个帘幕周期首个**放行**事件和首个**吞掉**事件各记一条：`input: first passed|swallowed event type= pid= stateID=`。用两个 Bool 标记，在 `raise()` 中复位。这样不用开 debug 也能拿到“远程注入事件是否 pid≠0”的证据。

## 风险
- **R1（B 的首要风险）**：如果远程注入的鼠标移动 pid==0，远程用户一动鼠标，现场就会被揭幕并锁屏。防护措施：(a) 40px/1s 的阈值；(b) `revealOnPointer` 可以一键关闭；(c) 上述日志能当场取证。补充说明：现有的 keyDown/MouseDown 也依赖同一假设，B 没有引入新的判定，只是让触发更频繁。由于辅助功能此前一直未授权，这条假设至今没有被检验过，必须先完成 M3 真机验证再默认依赖它。
- **R2**：晚上线的屏切换模式时，可能亮屏不到 1s（见上文“未验证”）。
- **R3**：显示器睡眠或唤醒后 display id 是否变化**未验证**。如果变了，新 id 会被当作新屏再试一次；`saved` 只在首次写入，不会覆盖原始模式。

## 回滚
- 整体回滚：用 `backup/main.swift.pre-res-retry`（已确认存在，61556 字节）覆盖 `Sources/main.swift` 并重新编译即可。这次改动不涉及持久化格式迁移。新增的 `revealOnPointer` 是一个 key，旧版本会忽略它。
- 运行时降级：在菜单里关闭“现场移动鼠标/滚轮也算现场操作”，或者关闭 `shrinkResolution`。
