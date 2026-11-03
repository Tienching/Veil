# Veil

Veil 是一个 macOS 菜单栏小工具。当你的 Mac 被远程查看或远程控制（例如 macOS 屏幕共享）时，它会把**本机屏幕蒙黑**，避免现场的人看到远程端的操作；远程端的画面不受影响。远程断开后，屏幕自动恢复。

> 状态：早期实验项目，仅在作者本机验证过。使用前请先阅读"已知限制"。

## 功能

- **远程检测**：通过 IOKit 电源断言检测 `screensharingd` 持有的 "Remote user is connected" 断言；辅以 `CGSession` 与 `netstat` 作为后备信号。
- **现场蒙黑**：通过 `CGSetDisplayTransferByTable` 把现场屏幕 gamma 置零。gamma 是进程级设置，Veil 退出或被强杀后系统会自动还原。
- **分辨率调整**：远程在线时可按显示器独立配置目标分辨率（菜单栏 "各显示器目标分辨率"），断开后还原。默认把每块屏降到 1920×1080（横屏）或 1080×1920（竖屏）的非 HiDPI 模式。
- **现场输入揭幕**（需要辅助功能授权）：蒙黑期间，现场的按键或鼠标点击会揭幕并锁屏，之后可用解锁密码恢复，行为类似 Windows 远程桌面。移动鼠标或滚轮也可触发，需在 1 秒内累计移动不少于 40 像素，或有实际滚动；可在菜单里关闭。
- **紧急解除**：快捷键 `⌃⌥⌘U` 随时解除帘幕。

## 系统要求

- macOS 12.0 或更高版本，Apple Silicon（arm64）。
- 现场键鼠拦截需要在 系统设置 → 隐私与安全性 → 辅助功能 中授权 Veil。未授权时蒙黑仍然生效，但现场输入不会被检测或拦截。

## 构建

直接用 `swiftc` 编译单文件源码，不依赖 Xcode 工程：

```bash
swiftc -O -swift-version 5 Sources/main.swift -o Veil \
  -framework Cocoa -framework Carbon -framework ApplicationServices -framework IOKit
```

打包成 `.app` 时，`Info.plist` 需要至少包含：`CFBundleIdentifier`、`CFBundleExecutable=Veil`、`LSUIElement=true`（菜单栏常驻，无 Dock 图标）、`LSMinimumSystemVersion`。

产物签名示例（ad-hoc）：

```bash
codesign --force --sign - Veil.app
```

## 命令行

```text
Veil                          菜单栏常驻（正常使用方式）
Veil --status                 只读快照：信号、判定、显示器
Veil --doctor                 诊断：权限、设置、信号、显示器
Veil --demo [秒数]            立即升起帘幕并每秒打印状态，到时自动解除（默认 8s）
Veil --demo 8 --no-input      同上，但不安装键鼠拦截
Veil --selftest [--no-display]  自检：解析器与选取逻辑单测；加 --no-display 时跳过实际黑屏
Veil --res-test [秒]          试切分辨率，等待后自动还原（默认 4s）。会真实切换显示器
Veil --panic                  强制还原 gamma（最后手段）
```

`--res-test` 与 `--demo` 会真实改变显示器状态，请先确认没有正在进行的远程会话。

## 日志与设置

- 日志：`~/Library/Logs/Veil2.log`（每次启动会写入 `veil: started ...`，其中 `trusted=` 表示辅助功能是否已授权）。
- 设置保存在 `UserDefaults`，域为 `com.local.veil.curtain`。分辨率配置键 `displayRes` 以显示器的系统 UUID 为 key。
- 删除所有设置：`defaults delete com.local.veil.curtain`。

## 安全与隐私说明

- 所有逻辑都在本机运行，不联网，不收集数据。
- 远程输入的识别依赖事件来源进程号（`eventSourceUnixProcessID`）：硬件输入为 0，远程注入事件应为非 0。这一假设**尚未在真机远程场景中充分验证**，因此启用了移动阈值和菜单开关作为防护。启用前请先在测试环境确认远程端移动鼠标不会触发揭幕。
- 辅助功能授权是一项敏感权限。Veil 只在蒙黑期间拦截硬件事件，远程注入的事件会被放行。

## 已知限制

- 应用使用 ad-hoc 签名。每次重新编译或替换 `.app`，辅助功能授权都需要在系统设置中重新添加。
- 显示器休眠唤醒后，系统显示器列表可能短暂为空。Veil 会在远程会话期间每秒检查一次，对新上线的屏幕尝试一次分辨率切换；失败的屏不会重试。
- 切换显示模式会重置 gamma，因此切换后会立即重新蒙黑；切换瞬间现场屏可能短暂亮起。
- 分辨率切换使用 `.forAppOnly` 配置，进程退出后系统自动还原；但"断开后还原到连接前的模式"在多显示器、模式被外部修改等情况下的行为尚未全面验证。
- 显示器 UUID 在重启或更换接口后是否保持不变，尚未验证。
- 仅支持 Apple Silicon，未在 Intel Mac 上测试。

## 目录结构

```text
Sources/main.swift            全部源码（单文件）
openspec/changes/             功能变更的方案文档（proposal / design / tasks / test-plan）
```

## 许可

未指定许可证。使用或分发前请先联系作者。
