# per-display-res · 提案

## 目标
远程连接期间,按**每块显示器独立配置**的目标分辨率切换;远程断开/退出后恢复到连接前的模式。

## 现状(已读 Sources/main.swift)
- `Settings.shrinkResolution` 单一布尔(L48);`ResolutionPick`(L223-237)写死 1920x1080 / 1080x1920 非 HiDPI;
  `Resolution.plan/apply/restore`(L239-288);`Controller.apply`(L448-453 缩分辨率、L465-467 还原);菜单项 `itemShrink`(L596、L630、L635-638)。

## 范围
1. 每块屏三态配置:**默认(1080p,即现状)** / **不改变** / **指定模式**(含 HiDPI 区分)。
2. 菜单栏:每块显示器一个子菜单,列出该屏可用模式。
3. 配置键使用稳定显示器标识(非 `CGDirectDisplayID`)。
4. 远程在线时改配置即时生效(仅该屏)。
5. 新增 `--selftest` 用例;`--doctor` 输出各屏标识与配置。

## 非目标
- 不做显示器热插拔后的"会话内重新缩放"(现状同样不处理,L450 每会话只试一次)。
- 不改 gamma/蒙黑、状态机、传感器逻辑;不改 `forAppOnly` 语义。
- 不做配置导入导出、不清理已离线显示器的历史配置。
- 不新增文件;只改 `Sources/main.swift`。

## 验收标准
- 无任何新配置时行为与现状逐字节等价(每块屏仍降 1080p;总开关 `shrinkResolution=false` 仍整体关闭)。
- 对 A 屏选"不改变"、B 屏选某 HiDPI 模式后,远程连接时只有 B 屏被切换到该模式;断开后 B 屏回到连接前的模式。
- 菜单中同一 `w×h` 的 HiDPI 与非 HiDPI 模式可区分。
- 目标模式在该屏不存在 → 不切换并写日志,不报错、不切到别的模式。
- 编译通过,`./build/Veil --selftest --no-display` 全部 PASS(含新增用例)。
