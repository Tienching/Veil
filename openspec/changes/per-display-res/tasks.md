# per-display-res · tasks

三个 task 的写入文件**都是同一个 `Sources/main.swift`**,无法并行,必须严格串行 T1 → T2 → T3;每个 task 完成后都要编译 + 自检通过再进入下一个。
语言规范索引中没有 Swift 规范 → Coder 报告里标注"规范文件缺失",沿用文件现有风格。

编译:`cd <repo> && swiftc -O -swift-version 5 Sources/main.swift -o build/Veil -framework Cocoa -framework Carbon -framework ApplicationServices -framework IOKit`
自检:`./build/Veil --selftest --no-display`

## T1 纯逻辑与单测(零行为变化)
- 目标:新增 `ResChoice`(编解码)、`ResolutionPick.pick(_:current:choice:)`、`ResolutionPick.menuModes`、`ModeInfo.menuTitle`;
  原 `pick(_:current:)` 一字不改。在 `cmdSelftest` 的 "2c. 分辨率选择"(L813-825)之后追加用例(见 test-plan)。
- 允许文件:`Sources/main.swift`(仅 L216-237 区域与 cmdSelftest)。
- 验收:编译通过;自检全 PASS,既有用例数不减少,新增用例全 PASS;运行时行为无变化(新代码未被调用)。

## T2 存储、稳定标识、Resolution 改造
- 目标:`Settings.displayRes` 字典读写 + `Settings.resChoice(forKey:)` / `setResChoice`;`DisplayKey.key(for:)` 与 `DisplayKey.name(for:)`;
  `Resolution.plan(only:choice:)` 按屏取 choice;`apply` 的 saved 首次写入保护与 Configure 失败整体 Cancel;
  `restore(only:)`;`--doctor` 增加每屏 key/名称/当前配置;日志区分 "target mode not available"。
- 允许文件:`Sources/main.swift`(Settings L39-52、Resolution L239-288、cmdDoctor L683-701)。
- 验收:编译通过;自检全 PASS(含 DisplayKey 稳定性用例);`./build/Veil --doctor` 打印每屏 key;
  `./build/Veil --res-test 4`(会真实切分辨率,需有显示器)在**无配置**时结果与改动前一致(1080p → 还原)。

## T3 菜单 UI 与实时生效
- 目标:`itemShrink` 改为总开关文案;新增 `itemResParent` 及动态子菜单;`@objc pickRes(_:)`;`Controller.setResChoice`(在线实时重定向,见 design §4);
  help 文案更新 `--res-test` 说明。
- 允许文件:`Sources/main.swift`(Controller 声明 L406、setupUI L584-605、menuNeedsUpdate L622-632、新增 @objc 方法、printHelp)。
- 验收:编译通过;自检全 PASS;手动(真机)验证项见 test-plan §3;断开/退出/信号路径代码 diff 为零(`git diff` 检查 L466、L650、L893 未被修改)。
