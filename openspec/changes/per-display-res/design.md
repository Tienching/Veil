# per-display-res · 设计

## 允许改动的文件(硬边界)
- `veil/Sources/main.swift`(唯一)。openspec 下四件套由 architect 维护。

## 1. 数据模型与持久化
```swift
enum ResChoice: Equatable {
    case default1080p                       // 现状行为;未配置的屏一律是它
    case off                                // 不改变
    case fixed(w: Int, h: Int, pw: Int, ph: Int, hz: Int)   // 点尺寸 + 像素尺寸 + 刷新率(取整)
    var encoded: String                     // "default" | "off" | "fixed:w,h,pw,ph,hz"
    static func decode(_ s: String?) -> ResChoice   // nil/乱码 → .default1080p(安全降级)
}
```
- HiDPI 判定:`pw != w`(点≠像素)。同一 `w×h` 的 HiDPI(pw=2w)与非 HiDPI(pw=w)靠 `pw/ph` 区分,
  这正是 4K 屏上 "1920×1080" 的歧义所在。
- 持久化:UserDefaults 单个字典 key **`displayRes`**:`[String: String]`,key=稳定显示器标识,value=`ResChoice.encoded`。
  `.default1080p` 写入时**删除该 key**(字典保持精简;缺省即默认)。
- 全局 key `shrinkResolution` **保留为总开关**(默认 true,语义不变);总开关关 → 完全不调用 `Resolution.apply`(L450 条件不变)。
  菜单文案改为"远程连接时调整分辨率"。
- 稳定标识 `DisplayKey.key(for: CGDirectDisplayID) -> String`:
  首选 `CGDisplayCreateUUIDFromDisplayID(id)` → `CFUUIDCreateString`;取不到时退化为
  `"v\(CGDisplayVendorNumber)-m\(CGDisplayModelNumber)-s\(CGDisplaySerialNumber)"`。
  【未验证】UUID 在重启/换口后是否不变、两台同型号无序列号显示器是否冲突;冲突时它们共享配置(可接受,写入风险)。
- 屏幕名称:`NSScreen.screens` 中 `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == id` 的
  `localizedName`(macOS 10.15+,用 `#available` 守卫);找不到则 `"显示器 \(id)"`。名称仅用于展示,不参与持久化。

## 2. 菜单栏 UI
- `itemShrink` 保留为总开关;其后新增 `itemResParent`("各显示器目标分辨率 ▸"),子菜单由 `menuNeedsUpdate`(L622)每次打开时重建:
  每块 `Curtain.displays()` 一项,标题 `名称 · 当前选择摘要`,其子菜单为:
  `默认(1080p)` · `不改变` · 分隔线 · 该屏模式列表。当前配置项打勾(`.state = .on`;无记录 = 默认)。
- 模式列表由纯函数 `ResolutionPick.menuModes(_ modes:[ModeInfo]) -> [ModeInfo]` 产出:
  只留 `usable`;按 `(w,h,pw,ph,Int(hz.rounded()))` 去重;排序 `pw*ph` 降序 → 非 HiDPI 在前 → `hz` 降序。
  枚举模式必须带 `kCGDisplayShowDuplicateLowResolutionModes: true`(同 L251),否则看不到非 HiDPI 重复项。
- 标题纯函数 `ModeInfo.menuTitle`:`"1920×1080 非HiDPI 60Hz"` / `"1920×1080 HiDPI(3840×2160 px) 60Hz"`;`hz==0` 省略刷新率。
- 点击动作:`representedObject = "\(key)\u{1F}\(choice.encoded)"`(String),统一 `@objc pickRes(_:)` 解析后调 `Controller.setResChoice`。

## 3. 选取逻辑(保持纯函数)
```swift
ResolutionPick.pick(_ modes:[ModeInfo], current: ModeInfo, choice: ResChoice) -> ModeInfo?
```
- `.off` → nil。
- `.default1080p` → 调用**原样保留**的 `pick(modes, current:)`(L228-236,不改一行,既有 7 条自检不动)。
- `.fixed(w,h,pw,ph,hz)` → 候选 = `usable && w,h,pw,ph 全等`;按 `|Δhz|` 升序、`hz` 降序取首个;
  无候选 → nil(**降级策略:不切换**,调用方写日志 `resolution: target mode not available on dN`);
  首选项 `== current` → nil(已在目标)。
- 朝向:fixed 以点/像素四元组精确匹配,天然保持物理朝向(竖屏模式本身就是 w<h);用户之后旋转屏幕 → 无候选 → 不切换。
  【未验证】旋转后 `CGDisplayCopyAllDisplayModes` 是否随之交换宽高;默认 1080p 分支沿用现有假设(L225、L822 用例)。
- `Resolution.plan(only:)` 增加参数 `choice: (CGDirectDisplayID) -> ResChoice`,默认实现 = `Settings.resChoice(forKey: DisplayKey.key(for: $0))`;
  `--res-test`(L703)因此也遵循配置(行为在 help 文案注明)。

## 4. 远程在线时改配置 & 恢复路径
- `Controller.setResChoice(key:, choice:)`:先持久化;若 `wasRemote && resolution.attempted && Settings.shrinkResolution && !headless`,
  则对 key 对应的在线屏做 `resolution.restore(only: [d])` → `resolution.apply(only: [d])`,随后 `curtain.reassertIfNeeded()`。
  否则只存配置,下一次会话生效。恢复先于应用 → 任一步失败,该屏都停在"原始模式"或"新模式",不会停在中间态。
- **必须修的既有缺陷**:`apply` 里 `saved[s.display] = s.from`(L272)会在二次应用时把"已缩小的模式"当成原始模式覆盖。
  改为 `if saved[s.display] == nil { saved[s.display] = s.from }`。
- `Resolution.restore(only: Set<CGDirectDisplayID>? = nil)`:`nil` 时行为与现状完全一致(含最后 `saved.removeAll()`);
  非 nil 时只还原并移除这些屏的条目。
- `apply` 加固:任一 `CGConfigureDisplayWithDisplayMode` 返回非 `.success` → `CGCancelDisplayConfiguration` 并返回 false,
  不提交半套配置;`saved` 仅在 `Complete == .success` 后写入(现状已是)。
- **不得改动**:`.forAppOnly`(L270、L282)、断开去抖后的 `restore`(L466)、`quitApp`(L650)、信号处理(L893)。
  Controller.apply 中"先缩分辨率后蒙黑"的顺序(L448-453)不变。
- 实时切换且帘幕已升起时,模式切换会重置 gamma:依赖既有 `displayReconfigCallback`(L315)+ 显式 `reassertIfNeeded()` + 1s `tick`(L421);
  可能出现 ≤1 个 tick 的现场屏闪亮(风险,见下)。

## 5. 兼容性 / 回滚
- 兼容:无 `displayRes` key 时 100% 走原路径;旧 `shrinkResolution` 语义不变;不删除任何既有 key。
- 回滚:`git checkout Sources/main.swift`(或用 `backup/`);用户侧删除 `displayRes` key 即回到现状行为:
  `defaults delete com.local.veil.curtain displayRes`(bundle 运行时域名以实际为准,【未验证】)。
- 切换失败兜底:`forAppOnly` 保证进程崩溃/退出自动还原;失败路径 Cancel 配置;`--panic` 仍可手动还原 gamma。

## 6. 风险
| 风险 | 缓解 |
|---|---|
| 二次应用覆盖原始模式 | `saved` 首次写入保护 + 自检/真机验证 |
| 实时改配置时帘幕下现场屏短暂闪亮 | reassert + 重配置回调;如不接受,降级为"仅下次会话生效"(改 `setResChoice` 一处条件) |
| 显示器 UUID 不稳定/冲突 | 退化 vendor/model/serial;冲突共享配置;doctor 打印标识便于排查 |
| 菜单模式过多 | 仅 usable + 去重;必要时 coder 可过滤 `pw<1024`(不改变验收) |
| 指定模式在远程客户端不友好 | 用户自选;默认值仍为 1080p |
