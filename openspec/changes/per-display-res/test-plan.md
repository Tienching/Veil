# per-display-res · 测试计划

## 1. 新增 --selftest 用例(T1/T2,纯逻辑,可在 --no-display 下运行)
夹具复用 `mi(...)` 与 `landscape` / `portrait`(L814-822);另加 4K HiDPI 夹具 `hi`:
`mi(55,1920,1080,3840,2160,60)`、`mi(54,1920,1080,1920,1080,60)`、`mi(56,1920,1080,1920,1080,50)`、`mi(60,2560,1440,5120,2880,60)`、`mi(61,2560,1440,2560,1440,60)`、`mi(62,1280,720,2560,1440,60,false)`。

编解码
1. `decode("off") == .off`;`decode("default") == .default1080p`;`decode(nil) == .default1080p`
2. `decode("garbage") == .default1080p`;`decode("fixed:1,2,3")`(字段不足)== `.default1080p`
3. round-trip:`decode(c.encoded) == c` 对 `.fixed(1920,1080,3840,2160,60)` 成立

选取
4. `.default1080p` 与旧 `pick(modes,current:)` 对 landscape/portrait 夹具结果相同
5. `.off` → nil
6. `.fixed(1920,1080,3840,2160,60)` 在 `hi` 中选 id 55(HiDPI),不选 54(非 HiDPI)
7. `.fixed(1920,1080,1920,1080,60)` 选 54,不选 55
8. 当前已是目标模式 → nil
9. 目标不存在(`.fixed(1600,900,1600,900,60)`)→ nil
10. 目标仅有 `usable=false` 的模式(id 62)→ nil
11. hz 就近:`.fixed(1920,1080,1920,1080,50)` 选 56
12. 竖屏:`.fixed(1080,1920,1080,1920,60)` 在 portrait 夹具选 41;横屏 fixed 在竖屏夹具 → nil(朝向保持)

菜单
13. `menuModes` 过滤 `usable=false`
14. `menuModes` 去重(重复 id/同 w,h,pw,ph,hz 只留一个)
15. `menuModes` 排序:大分辨率在前、同分辨率非 HiDPI 在 HiDPI 前、同模式 hz 降序
16. `menuTitle`:HiDPI 标题含 "HiDPI" 与像素尺寸;非 HiDPI 含 "非HiDPI";`hz==0` 无 "Hz"

标识(T2,读取真实显示器列表,无显示器时作为 INFO 跳过)
17. 对每个 `Curtain.displays()`:`DisplayKey.key(for:)` 非空,且连续两次调用相同

## 2. 命令(必须真实执行并记录退出码)
- 编译(见 tasks.md),期望退出码 0、无 error。
- `./build/Veil --selftest --no-display`,期望尾行 `ALL PASS`、退出码 0。
- `./build/Veil --doctor`:每块屏打印 key/名称/配置(T2 后)。
- `./build/Veil --res-test 4`:无配置 = 旧行为(有显示器的机器上执行;改变分辨率约 4 秒后自动还原,运行前提醒用户)。
- 范围自检:`git diff --name-only` 仅出现 `Sources/main.swift`(若目录非 git 仓库则对比 `backup/`)。

## 3. 真机手动验证(T3,需要真实远程会话;自动化不可得,执行前标注"未执行"直到做过)
1. 双屏:A 选"不改变",B 选某 HiDPI 模式;发起 VNC 连接 → 只有 B 切换,日志出现 `resolution: applied` 仅含 B;断开后 B 回到原模式。
2. 远程在线时把 B 改成"默认(1080p)":B 切到 1080p 非 HiDPI;断开后 B 回到**最初**模式(验证 saved 首次写入保护)。
3. 远程在线时把 B 改成"不改变":B 回到原模式。
4. 帘幕升起状态下实时切换:观察现场屏是否闪亮(记录结果,作为风险验证)。
5. 连接中退出 Veil(菜单退出、`kill -TERM`):分辨率恢复。
6. 删除 `displayRes` 后行为 = 现状(两块屏都降 1080p)。
