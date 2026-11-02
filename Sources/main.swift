// Veil — 现场挡屏帘幕(重新实现)
// 被远程查看屏幕时,把"现场物理屏幕"蒙黑(gamma 置零),远程端画面不受影响;
// 同时拦截现场键鼠、断开后可选锁屏。菜单栏常驻 + 命令行诊断。
import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import IOKit.pwr_mgt

let appVersion = "2.0.0"
let logPath = NSString(string: "~/Library/Logs/Veil2.log").expandingTildeInPath

// MARK: - 日志 / 设置

final class Logger {
    static let shared = Logger()
    var echo = false
    private let q = DispatchQueue(label: "veil2.log")
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()
    func log(_ s: String) {
        q.sync {
            let line = "\(fmt.string(from: Date()))  \(s)\n"
            if echo { FileHandle.standardOutput.write(Data(("• " + s + "\n").utf8)) }
            if let attr = try? FileManager.default.attributesOfItem(atPath: logPath),
               let size = attr[.size] as? Int, size > 2_000_000 {
                try? FileManager.default.removeItem(atPath: logPath)
            }
            if let h = FileHandle(forWritingAtPath: logPath) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
            }
        }
    }
}
func vlog(_ s: String) { Logger.shared.log(s) }

enum Settings {
    // 注意:suiteName 与自身 bundle id 相同会返回 nil;打包成 .app 后用 standard 即为 com.local.veil.curtain 域
    static let d: UserDefaults = Bundle.main.bundleIdentifier != nil ? .standard : (UserDefaults(suiteName: "com.local.veil.curtain") ?? .standard)
    private static func get(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    static var auto: Bool { get { get("auto", true) } set { d.set(newValue, forKey: "auto") } }
    static var blockInput: Bool { get { get("blockInput", true) } set { d.set(newValue, forKey: "blockInput") } }
    static var lockOnDisconnect: Bool { get { get("lockOnDisconnect", true) } set { d.set(newValue, forKey: "lockOnDisconnect") } }
    static var lockOnDeskInput: Bool { get { get("lockOnDeskInput", true) } set { d.set(newValue, forKey: "lockOnDeskInput") } }
    static var rearmOnIdle: Bool { get { get("rearmOnIdle", true) } set { d.set(newValue, forKey: "rearmOnIdle") } }
    static var shrinkResolution: Bool { get { get("shrinkResolution", true) } set { d.set(newValue, forKey: "shrinkResolution") } }
    static var revealOnPointer: Bool { get { get("revealOnPointer", true) } set { d.set(newValue, forKey: "revealOnPointer") } }
    static var rearmIdleSeconds: Double {
        let v = d.double(forKey: "rearmIdleSeconds"); return v > 0 ? v : 30
    }
    /// 每块显示器的目标分辨率:稳定标识 -> ResChoice.encoded;缺省(无该 key)= .default1080p
    static var displayRes: [String: String] { d.dictionary(forKey: "displayRes") as? [String: String] ?? [:] }
    static func choice(for key: String) -> ResChoice { ResChoice.decode(displayRes[key]) }
    static func setChoice(_ c: ResChoice, for key: String) {
        var m = displayRes
        if c == .default1080p { m.removeValue(forKey: key) } else { m[key] = c.encoded }
        d.set(m, forKey: "displayRes")
    }
}

// MARK: - netstat 解析(纯函数,可单测)

enum NetstatParse {
    struct Row { let proto: String; let local: String; let foreign: String; let state: String }

    static func parse(_ text: String) -> [Row] {
        var rows = [Row]()
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let t = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let p = t.first else { continue }
            if p.hasPrefix("tcp"), t.count >= 6 {
                rows.append(Row(proto: p, local: t[3], foreign: t[4], state: t[5]))
            } else if p.hasPrefix("udp"), t.count >= 5 {
                rows.append(Row(proto: p, local: t[3], foreign: t[4], state: ""))
            }
        }
        return rows
    }

    /// 地址形如 "192.0.2.10.5900" / "*.5900" / "fe80::1%en0.5900":端口是最后一个 '.' 之后
    static func port(_ addr: String) -> Int? {
        guard let i = addr.lastIndex(of: ".") else { return nil }
        return Int(addr[addr.index(after: i)...])
    }
    static func isWildcard(_ a: String) -> Bool { a.hasPrefix("*") }
    static let vncPorts = 5900...5909

    /// 本机作为服务端、已建立的 VNC/屏幕共享 TCP 连接("本地 <- 对端")。出站连接(本地端口不是 590x)不算。
    static func establishedVNC(_ rows: [Row]) -> [String] {
        rows.compactMap { r in
            guard r.proto.hasPrefix("tcp"), r.state == "ESTABLISHED",
                  let lp = port(r.local), vncPorts.contains(lp), !isWildcard(r.foreign) else { return nil }
            return "\(r.local)<-\(r.foreign)"
        }
    }
    /// 高性能屏幕共享:本地 590x 的 UDP 且已绑定对端
    static func peeredUDP(_ rows: [Row]) -> [String] {
        rows.compactMap { r in
            guard r.proto.hasPrefix("udp"), let lp = port(r.local), vncPorts.contains(lp),
                  !isWildcard(r.foreign) else { return nil }
            return "\(r.local)<-\(r.foreign)"
        }
    }
}

// MARK: - 传感器

struct Signals {
    var captured = false
    var locked = false
    var tcp: [String] = []
    var udp: [String] = []
    var assertions: [String] = []   // screensharingd 持有的 "Remote user is connected" 电源断言(主信号)
    var daemon = false
    var netstatOK = true            // netstat 返回了 TCP 表;为 false 表示该信号失效(而非"无连接")
    var remote: Bool { captured || !assertions.isEmpty || !tcp.isEmpty || !udp.isEmpty }
    var summary: String {
        "captured=\(captured) assertion=\(assertions.isEmpty ? "none" : assertions.joined(separator: ",")) "
        + "tcp5900=\(tcp.isEmpty ? "none" : tcp.joined(separator: ",")) "
        + "udp590x=\(udp.isEmpty ? "none" : udp.joined(separator: ",")) daemon=\(daemon) netstat=\(netstatOK ? "ok" : "BLIND")"
    }
}

enum Sensors {
    static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// 主信号:屏幕共享守护进程为"有远程用户连接"持有的电源断言。走 IOKit API,不依赖 netstat/权限。
    static func remoteAssertions() -> [String] {
        var out: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&out) == 0,
              let d = out?.takeRetainedValue() as? [Int: [[String: Any]]] else { return [] }
        var hits = [String]()
        for (pid, list) in d {
            for a in list {
                let proc = (a["Process Name"] as? String ?? "").lowercased()
                let name = (a["AssertName"] as? String ?? "").lowercased()
                if proc.hasPrefix("screensharing") && name.contains("remote user is connected") {
                    hits.append("\(proc)#\(pid)")
                }
            }
        }
        return hits.sorted()
    }

    static func sample() -> Signals {
        var s = Signals()
        s.assertions = remoteAssertions()
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
            s.captured = (d["CGSSessionScreenIsCaptured"] as? Bool) ?? ((d["CGSSessionScreenIsCaptured"] as? NSNumber)?.boolValue ?? false)
            s.locked = (d["CGSSessionScreenIsLocked"] as? Bool) ?? ((d["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false)
        }
        if let txt = run("/usr/sbin/netstat", ["-an"]) {
            let rows = NetstatParse.parse(txt)
            // 一台联网的 Mac 不可能没有任何 TCP 行:没有就说明 netstat 在当前环境被"致盲",不能当作"无连接"
            s.netstatOK = rows.contains { $0.proto.hasPrefix("tcp") }
            s.tcp = NetstatParse.establishedVNC(rows)
            s.udp = NetstatParse.peeredUDP(rows)
        } else {
            s.netstatOK = false
        }
        s.daemon = (run("/usr/bin/pgrep", ["-x", "screensharingd"]) ?? "").isEmpty == false
        return s
    }
}

// MARK: - 帘幕(gamma 置零)

final class Curtain {
    private(set) var engaged = false
    private let zeros = [CGGammaValue](repeating: 0, count: 256)

    static func displays() -> [CGDirectDisplayID] {
        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &ids, &n)
        return Array(ids.prefix(Int(n)))
    }
    static func gammaEnd(_ d: CGDirectDisplayID) -> Float {
        var r = [CGGammaValue](repeating: -1, count: 256)
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(d, 256, &r, &g, &b, &count) == .success, count > 0 else { return -1 }
        return r[Int(count) - 1]
    }
    private func applyBlack() {
        for d in Curtain.displays() { _ = CGSetDisplayTransferByTable(d, 256, zeros, zeros, zeros) }
    }
    func engage() {
        engaged = true
        applyBlack()
        vlog("blackout: engaged on \(Curtain.displays().count) display(s) \(Curtain.displays())")
    }
    func release() {
        guard engaged else { return }
        engaged = false
        CGDisplayRestoreColorSyncSettings()
        vlog("blackout: released")
    }
    /// 显示器重配置/唤醒后 gamma 可能被系统重置,发现不是全黑就补一次
    func reassertIfNeeded() {
        guard engaged else { return }
        let lit = Curtain.displays().filter { Curtain.gammaEnd($0) > 0.001 }
        if !lit.isEmpty {
            applyBlack()
            vlog("blackout: re-asserted on \(lit)")
        }
    }
}

// MARK: - 分辨率(远程在线时降到 1920x1080 / 1080x1920 像素)

struct ModeInfo: Equatable {
    var id: Int32, w: Int, h: Int, pw: Int, ph: Int, hz: Double, usable: Bool
    var text: String { "\(w)x\(h)pt \(pw)x\(ph)px \(Int(hz))Hz(io=\(id))" }
    /// 菜单标题:"1920×1080 非HiDPI 60Hz" / "1920×1080 HiDPI(3840×2160 px) 60Hz";hz==0 省略刷新率
    var menuTitle: String {
        var s = "\(w)×\(h) " + (pw != w ? "HiDPI(\(pw)×\(ph) px)" : "非HiDPI")
        let r = Int(hz.rounded())
        if r > 0 { s += " \(r)Hz" }
        return s
    }
}

/// 每块显示器的目标分辨率选择(持久化编码:"default" | "off" | "fixed:w,h,pw,ph,hz")
enum ResChoice: Equatable {
    case default1080p
    case off
    case fixed(w: Int, h: Int, pw: Int, ph: Int, hz: Int)

    var encoded: String {
        switch self {
        case .default1080p: return "default"
        case .off: return "off"
        case let .fixed(w, h, pw, ph, hz): return "fixed:\(w),\(h),\(pw),\(ph),\(hz)"
        }
    }
    /// nil / 乱码 / 字段不足 -> .default1080p(安全降级)
    static func decode(_ s: String?) -> ResChoice {
        guard let s = s else { return .default1080p }
        if s == "off" { return .off }
        if s.hasPrefix("fixed:") {
            let parts = s.dropFirst("fixed:".count).split(separator: ",", omittingEmptySubsequences: false).map { Int($0) }
            if parts.count == 5, parts.allSatisfy({ $0 != nil }) {
                let v = parts.map { $0! }
                return .fixed(w: v[0], h: v[1], pw: v[2], ph: v[3], hz: v[4])
            }
        }
        return .default1080p
    }
}

enum ResolutionPick {
    /// 目标像素尺寸:跟随当前朝向(横屏 1920x1080,竖屏 1080x1920)
    static func targetSize(pw: Int, ph: Int) -> (Int, Int) { pw >= ph ? (1920, 1080) : (1080, 1920) }

    /// 选出"真正的 1080p 像素、非 HiDPI(点==像素)、可用于桌面、刷新率最接近当前"的模式;已经是则返回 nil
    static func pick(_ modes: [ModeInfo], current: ModeInfo) -> ModeInfo? {
        let (tw, th) = targetSize(pw: current.pw, ph: current.ph)
        if current.pw == tw && current.ph == th && current.w == tw && current.h == th { return nil }
        let c = modes.filter { $0.pw == tw && $0.ph == th && $0.w == tw && $0.h == th && $0.usable }
        return c.sorted {
            let a = abs($0.hz - current.hz), b = abs($1.hz - current.hz)
            return a != b ? a < b : $0.hz > $1.hz
        }.first
    }

    /// 按每屏选择取目标模式:.off -> nil;.default1080p -> 原 pick;.fixed -> 四元组精确匹配,无候选或已在目标 -> nil(不切换)
    static func pick(_ modes: [ModeInfo], current: ModeInfo, choice: ResChoice) -> ModeInfo? {
        switch choice {
        case .off:
            return nil
        case .default1080p:
            return pick(modes, current: current)
        case let .fixed(w, h, pw, ph, hz):
            // 已在目标:四元组相同且刷新率取整相同(不比较 id)
            if current.w == w && current.h == h && current.pw == pw && current.ph == ph
                && Int(current.hz.rounded()) == hz { return nil }
            let c = modes.filter { $0.usable && $0.w == w && $0.h == h && $0.pw == pw && $0.ph == ph }
            let best = c.sorted {
                let a = abs(Int($0.hz.rounded()) - hz), b = abs(Int($1.hz.rounded()) - hz)
                return a != b ? a < b : $0.hz > $1.hz
            }.first
            guard let want = best else { return nil }
            if want == current { return nil }
            return want
        }
    }

    /// 菜单可选模式:仅 usable;按 (w,h,pw,ph,hz取整) 去重;pw*ph 降序 -> 非 HiDPI 在前 -> hz 降序
    static func menuModes(_ modes: [ModeInfo]) -> [ModeInfo] {
        var seen = Set<[Int]>()
        var out = [ModeInfo]()
        for m in modes where m.usable {
            let k = [m.w, m.h, m.pw, m.ph, Int(m.hz.rounded())]
            if seen.insert(k).inserted { out.append(m) }
        }
        return out.sorted {
            let a = $0.pw * $0.ph, b = $1.pw * $1.ph
            if a != b { return a > b }
            let ha = $0.pw != $0.w, hb = $1.pw != $1.w
            if ha != hb { return !ha }
            if $0.hz != $1.hz { return $0.hz > $1.hz }
            return $0.id < $1.id
        }
    }
}

/// 显示器稳定标识与展示名(名称只用于展示,不参与持久化)
enum DisplayKey {
    static func key(for id: CGDirectDisplayID) -> String {
        if let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let s = CFUUIDCreateString(nil, u) as String?, !s.isEmpty { return s }
        return "v\(CGDisplayVendorNumber(id))-m\(CGDisplayModelNumber(id))-s\(CGDisplaySerialNumber(id))"
    }
    static func name(for id: CGDirectDisplayID) -> String {
        if #available(macOS 10.15, *) {
            for s in NSScreen.screens {
                if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                   n.uint32Value == id { return s.localizedName }
            }
        }
        return "显示器 \(id)"
    }
}

final class Resolution {
    struct Step { let display: CGDirectDisplayID; let from: CGDisplayMode; let to: CGDisplayMode }
    private var saved: [CGDirectDisplayID: CGDisplayMode] = [:]
    var applied: Bool { !saved.isEmpty }
    var attemptedDisplays = Set<CGDirectDisplayID>()   // 本会话已尝试过的屏,每屏只试一次,失败也不重试

    /// active 中尚未尝试的屏;保持 active 顺序并去重
    static func pending(active: [CGDirectDisplayID], attempted: Set<CGDirectDisplayID>) -> [CGDirectDisplayID] {
        var seen = attempted
        return active.filter { seen.insert($0).inserted }
    }

    static func info(_ m: CGDisplayMode) -> ModeInfo {
        ModeInfo(id: m.ioDisplayModeID, w: m.width, h: m.height, pw: m.pixelWidth, ph: m.pixelHeight,
                 hz: m.refreshRate, usable: m.isUsableForDesktopGUI())
    }
    static func plan(only: Set<CGDirectDisplayID>? = nil,
                     choice: (CGDirectDisplayID) -> ResChoice = { Settings.choice(for: DisplayKey.key(for: $0)) }) -> [Step] {
        var out = [Step]()
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for d in Curtain.displays() {
            if let o = only, !o.contains(d) { continue }
            let ch = choice(d)
            if ch == .off { continue }
            guard let cur = CGDisplayCopyDisplayMode(d),
                  let all = CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode] else { continue }
            let infos = all.map(info)
            guard let want = ResolutionPick.pick(infos, current: info(cur), choice: ch) else {
                if case let .fixed(w, h, pw, ph, hz) = ch,
                   !infos.contains(where: { $0.usable && $0.w == w && $0.h == h && $0.pw == pw && $0.ph == ph }) {
                    vlog("resolution: target mode not available on d\(d) (\(ch.encoded), w=\(w) h=\(h) px=\(pw)x\(ph) \(hz)Hz)")
                }
                continue
            }
            guard let target = all.first(where: { $0.ioDisplayModeID == want.id && info($0) == want }) else { continue }
            out.append(Step(display: d, from: cur, to: target))
        }
        return out
    }
    @discardableResult
    func apply(only: Set<CGDirectDisplayID>? = nil) -> Bool {
        let steps = Resolution.plan(only: only)
        guard !steps.isEmpty else { vlog("resolution: nothing to change (already 1080p or no matching mode)"); return false }
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { vlog("resolution: begin failed"); return false }
        for s in steps {
            let cr = CGConfigureDisplayWithDisplayMode(c, s.display, s.to, nil)
            if cr != .success {
                CGCancelDisplayConfiguration(c)
                vlog("resolution: configure failed on d\(s.display) rc=\(cr.rawValue), configuration cancelled")
                return false
            }
        }
        // forAppOnly:进程退出/崩溃时系统自动还原,不会把用户留在低分辨率
        let r = CGCompleteDisplayConfiguration(c, .forAppOnly)
        guard r == .success else { CGCancelDisplayConfiguration(c); vlog("resolution: complete failed rc=\(r.rawValue)"); return false }
        // 仅首次写入:二次应用时 s.from 可能已是缩小后的模式,不能覆盖最初的原始模式
        for s in steps where saved[s.display] == nil { saved[s.display] = s.from }
        vlog("resolution: applied " + steps.map { "d\($0.display) \(Resolution.info($0.from).text) -> \(Resolution.info($0.to).text)" }.joined(separator: "; "))
        return true
    }
    /// only == nil:还原全部(与旧行为一致);非 nil:只还原并移除这些屏的记录
    func restore(only: Set<CGDirectDisplayID>? = nil) {
        guard !saved.isEmpty else { return }
        let targets = saved.filter { only == nil || only!.contains($0.key) }
        guard !targets.isEmpty else { return }
        let active = Set(Curtain.displays())
        var cfg: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg {
            for (d, m) in targets where active.contains(d) { _ = CGConfigureDisplayWithDisplayMode(c, d, m, nil) }
            let r = CGCompleteDisplayConfiguration(c, .forAppOnly)
            if r != .success { CGCancelDisplayConfiguration(c); vlog("resolution: restore failed rc=\(r.rawValue)") }
            else { vlog("resolution: restored " + targets.filter { active.contains($0.key) }.map { "d\($0.key) -> \(Resolution.info($0.value).text)" }.joined(separator: "; ")) }
        }
        if only == nil { saved.removeAll() } else { for k in targets.keys { saved.removeValue(forKey: k) } }
    }
}

// MARK: - 锁屏

func lockScreen() {
    if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
       let sym = dlsym(h, "SACLockScreenImmediate") {
        typealias F = @convention(c) () -> Int32
        _ = unsafeBitCast(sym, to: F.self)()
        vlog("lock: SACLockScreenImmediate")
    } else {
        _ = Sensors.run("/usr/bin/pmset", ["displaysleepnow"])
        vlog("lock: fallback displaysleepnow")
    }
}

// MARK: - 全局回调(C 函数指针不能捕获上下文)

var gController: Controller?
var signalSources: [DispatchSourceSignal] = []

let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let c = Unmanaged<Controller>.fromOpaque(refcon).takeUnretainedValue()
    return c.handleTap(type: type, event: event)
}

func displayReconfigCallback(_ d: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    DispatchQueue.main.async { gController?.curtain.reassertIfNeeded() }
}

// MARK: - 揭幕/重新黑屏 状态机(纯逻辑,可单测)
//
// 行为参照微软远程桌面:
//   远程连接            → 现场黑屏
//   现场操作/快捷键      → 揭幕并锁屏(现场必须解锁),远程会话保持
//   现场解锁成功         → 保持揭幕(现场在用)
//   之后任一发生         → 重新黑屏:① 屏幕再次被锁 ② 现场空闲超过 N 秒 ③ 手动(快捷键/菜单)
//   远程断开            → 全部复位

struct RevealMachine {
    enum Action: Equatable { case none, raise(String) }

    var revealed = false            // 现场已揭幕(远程仍在):不能再被"自动升幕"重新黑掉,除非满足重新黑屏条件
    var awaitingUnlock = false      // 我们刚为揭幕而锁屏,正在等现场解锁
    var awaitingSince = 0.0
    var prevLocked = false
    var unlockTimeout = 20.0        // 锁屏动作没生效时的兜底:超时视为已揭幕,避免卡死

    /// 现场操作/快捷键触发揭幕。lock=true 时随后会锁屏,等待现场解锁。
    mutating func reveal(lock: Bool, now: Double) {
        revealed = true
        awaitingUnlock = lock
        awaitingSince = now
    }
    /// 手动重新黑屏(快捷键/菜单):清除揭幕态
    mutating func rearmNow() { revealed = false; awaitingUnlock = false }
    mutating func remoteEnded() { revealed = false; awaitingUnlock = false }

    mutating func step(remote: Bool, auto: Bool, engaged: Bool, locked: Bool,
                       hidIdle: Double, rearmIdle: Double?, now: Double) -> Action {
        defer { prevLocked = locked }
        guard remote else { remoteEnded(); return .none }

        // 现场解锁成功(由我们的揭幕锁屏引起)
        if awaitingUnlock {
            if prevLocked && !locked { awaitingUnlock = false; revealed = true; return .none }
            if !locked && now - awaitingSince > unlockTimeout { awaitingUnlock = false; revealed = true }
            if awaitingUnlock { return .none }
        }
        guard auto, !engaged else { return .none }

        // 重新黑屏条件 ①:屏幕被(别人/系统/用户)重新锁上
        if revealed && !prevLocked && locked {
            revealed = false
            return .raise("re-arm: screen locked while remote active")
        }
        // 条件 ②:现场空闲
        if revealed, let idle = rearmIdle, hidIdle >= idle {
            revealed = false
            return .raise("re-arm: desk idle \(Int(hidIdle))s >= \(Int(idle))s")
        }
        // 默认:远程在线且未揭幕 → 黑屏
        if !revealed { return .raise("remote session active") }
        return .none
    }
}

// MARK: - 现场移动鼠标/滚轮判定(纯逻辑,可单测)
//
// 固定窗口(tumbling):距窗口起点超过 window 秒则从本次重新累计;累计位移 >= threshold 返回 true 并清零。
// 跨两个窗口的一段移动最多需要约 2 倍位移才触发,可接受。

struct MotionGate {
    static let window = 1.0, threshold = 40.0
    var start = -Double.infinity, accum = 0.0
    static func distance(dx: Double, dy: Double) -> Double { (dx * dx + dy * dy).squareRoot() }
    /// 滚轮:任一轴 delta 非 0 才算(排除触控板只发 phase、delta 全 0 的事件)
    static func scrollIntent(_ deltas: [Double]) -> Bool { deltas.contains { $0 != 0 } }
    mutating func feed(distance d: Double, now: Double) -> Bool {
        if now - start > MotionGate.window { start = now; accum = 0 }
        accum += d
        if accum >= MotionGate.threshold { reset(); return true }
        return false
    }
    mutating func reset() { start = -.infinity; accum = 0 }
}

func hidIdleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
}
func combinedIdleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

// MARK: - 控制器

final class Controller: NSObject, NSMenuDelegate {
    enum Origin { case auto, manual }
    let curtain = Curtain()
    let resolution = Resolution()
    var origin: Origin?
    var machine = RevealMachine()
    var negative = 0
    var wasRemote = false
    var curtainedForRemote = false
    var last: Signals?
    var inFlight = false
    var tap: CFMachPort?
    var swallowed = 0, passed = 0
    var lastDeskAction = Date.distantPast
    var headless = false
    var warnedNetstat = false
    var warnedAX = false
    var motion = MotionGate()                                // 现场移动鼠标累计(tap 回调在主 runloop,无需加锁)
    var loggedFirstPassed = false, loggedFirstSwallowed = false   // 每轮帘幕首个放行/吞掉事件各记一条(取证 pid 假设)

    var statusItem: NSStatusItem?
    var timer: Timer?
    var hotKeyRef: EventHotKeyRef?
    var itemStatus, itemToggle, itemAuto, itemBlock, itemLockDisc, itemLockDesk, itemRearm, itemRearmIdle, itemShrink, itemResParent: NSMenuItem!
    var itemPointer: NSMenuItem!

    // 生命周期
    func start() {
        gController = self
        registerHotKey()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.1
        tick()
    }

    // 轮询
    func tick() {
        if curtain.engaged {
            curtain.reassertIfNeeded()
            if Settings.blockInput && tap == nil { installTap() }
        }
        guard !inFlight else { return }
        inFlight = true
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Sensors.sample()
            DispatchQueue.main.async { self.inFlight = false; self.apply(s) }
        }
    }

    var remoteNow: Bool { last?.remote ?? false }

    func apply(_ s: Signals) {
        last = s
        if !s.netstatOK {
            if !warnedNetstat { vlog("sensor: netstat is blind in this environment — relying on power-assertion/CGSession signals"); warnedNetstat = true }
        } else { warnedNetstat = false }

        if s.remote {
            negative = 0
            wasRemote = true
        } else {
            negative += 1
            if wasRemote { vlog("sample: no remote signal (negative=\(negative)) \(s.summary)") }
        }

        if s.remote {
            // 先缩分辨率再蒙黑:切换模式会重置 gamma,顺序反了会让黑屏瞬间失效。
            // 每块屏首次出现在活动列表时各试一次(连上瞬间显示器可能还在睡眠、列表为空)。
            // 逐屏事务:apply 的事务里任一屏失败会整批回滚,临时屏不能连累其他屏。
            if Settings.shrinkResolution && !headless {
                let fresh = Resolution.pending(active: Curtain.displays(), attempted: resolution.attemptedDisplays)
                if !fresh.isEmpty {
                    vlog("resolution: new display(s) online \(fresh), attempting once each")
                    var changed = false
                    for d in fresh { resolution.attemptedDisplays.insert(d); if resolution.apply(only: [d]) { changed = true } }
                    if changed && curtain.engaged { curtain.reassertIfNeeded() }   // 切模式会重置 gamma
                }
            }
            let idleLimit: Double? = Settings.rearmOnIdle ? Settings.rearmIdleSeconds : nil
            let act = machine.step(remote: true, auto: Settings.auto, engaged: curtain.engaged, locked: s.locked,
                                   hidIdle: hidIdleSeconds(), rearmIdle: idleLimit, now: Date().timeIntervalSince1970)
            if case .raise(let why) = act {
                raise(.auto, reason: "\(why): \(s.summary)")
                curtainedForRemote = true
            }
        } else if negative >= 2 {   // 去抖:连续 2 次(约 2s)检测不到才算断开
            _ = machine.step(remote: false, auto: Settings.auto, engaged: curtain.engaged, locked: s.locked,
                             hidIdle: 0, rearmIdle: nil, now: 0)
            if origin == .auto && curtain.engaged { lower("remote session ended") }
            // 断开后先还原分辨率(此时帘幕已降下,不会闪黑),并允许下次会话再次缩小
            resolution.restore()
            resolution.attemptedDisplays.removeAll()
            if wasRemote {
                wasRemote = false
                if curtainedForRemote && Settings.lockOnDisconnect && !headless { lockScreen() }
                curtainedForRemote = false
            }
        }
        if !Settings.auto && origin == .auto && curtain.engaged { lower("auto mode turned off") }
        updateUI()
    }

    func raise(_ o: Origin, reason: String) {
        curtain.engage()
        origin = o
        swallowed = 0; passed = 0
        motion.reset(); loggedFirstPassed = false; loggedFirstSwallowed = false
        vlog("curtain UP (\(o == .auto ? "auto" : "manual")) — \(reason)")
        if Settings.blockInput { installTap() }
        updateUI()
    }
    func lower(_ reason: String) {
        curtain.release()
        removeTap()
        origin = nil
        vlog("curtain DOWN — \(reason) (swallowed \(swallowed) desk events, passed \(passed) injected)")
        updateUI()
    }

    /// 现场揭幕(快捷键/菜单/现场键鼠):降下帘幕,远程在线时锁屏让现场解锁
    func revealLocal(_ why: String) {
        guard curtain.engaged else { return }
        let lock = remoteNow && Settings.lockOnDeskInput && !headless
        machine.reveal(lock: lock, now: Date().timeIntervalSince1970)
        lower(why + (lock ? " → reveal + lock (waiting for local unlock)" : " → reveal"))
        if lock { lockScreen() }
    }
    /// 手动重新黑屏(远程仍在线)
    func rearmManually() {
        guard remoteNow, !curtain.engaged else { return }
        machine.rearmNow()
        raise(.auto, reason: "manual re-arm")
    }
    func hotkeyPressed() {
        if curtain.engaged { revealLocal("hotkey ⌃⌥⌘U") } else { rearmManually() }
    }
    func deskTouched(why: String = "key/click") {
        guard curtain.engaged, Date().timeIntervalSince(lastDeskAction) > 5 else { return }
        lastDeskAction = Date()
        vlog("input: desk trigger \(why)")
        revealLocal("desk input detected")
    }

    // 现场键鼠拦截
    func installTap() {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            if !warnedAX { vlog("input: Accessibility not granted — desk input NOT blocked (⌃⌥⌘U still works)"); warnedAX = true }
            return
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown,
                                    .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved, .leftMouseDragged,
                                    .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        var mask: CGEventMask = 0
        for t in types { mask |= (1 << CGEventMask(t.rawValue)) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            vlog("input: tapCreate failed"); return
        }
        let src = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        vlog("input: event tap installed")
    }
    func removeTap() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false); CFMachPortInvalidate(t); tap = nil; vlog("input: event tap removed") }
    }
    func handleTap(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // 逃生键 ⌃⌥⌘U(在 tap 内直接匹配,不依赖 Carbon 热键)
        if type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_ANSI_U) {
            let f = event.flags
            if f.contains(.maskControl) && f.contains(.maskAlternate) && f.contains(.maskCommand) {
                DispatchQueue.main.async { self.hotkeyPressed() }
                return nil
            }
        }
        // 只拦截"硬件源"事件(sourcePID==0);远程会话注入的事件带注入进程 pid,放行
        if event.getIntegerValueField(.eventSourceUnixProcessID) != 0 {
            passed += 1
            if !loggedFirstPassed {
                loggedFirstPassed = true
                vlog("input: first passed event type=\(type.rawValue) pid=\(event.getIntegerValueField(.eventSourceUnixProcessID)) stateID=\(event.getIntegerValueField(.eventSourceStateID))")
            }
            return Unmanaged.passUnretained(event)
        }
        swallowed += 1
        if !loggedFirstSwallowed {
            loggedFirstSwallowed = true
            vlog("input: first swallowed event type=\(type.rawValue) pid=0 stateID=\(event.getIntegerValueField(.eventSourceStateID))")
        }
        // 只在真正触发时才拼字符串,避免每个 mouseMoved 都做插值
        func tag() -> String { "type=\(type.rawValue) pid=0 stateID=\(event.getIntegerValueField(.eventSourceStateID))" }
        switch type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let why = tag()
            DispatchQueue.main.async { self.deskTouched(why: why) }
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            guard Settings.revealOnPointer else { break }
            let d = MotionGate.distance(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
            if motion.feed(distance: d, now: ProcessInfo.processInfo.systemUptime) {
                let why = "pointer accum>=\(Int(MotionGate.threshold)) " + tag()
                DispatchQueue.main.async { self.deskTouched(why: why) }
            }
        case .scrollWheel:
            guard Settings.revealOnPointer else { break }
            let deltas = [event.getDoubleValueField(.scrollWheelEventDeltaAxis1), event.getDoubleValueField(.scrollWheelEventDeltaAxis2),
                          event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1), event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)]
            if MotionGate.scrollIntent(deltas) {
                let why = "scroll " + tag()
                DispatchQueue.main.async { self.deskTouched(why: why) }
            }
        default: break
        }
        return nil
    }

    // Carbon 热键(tap 未安装时的后备)
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { gController?.hotkeyPressed() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x56454C32), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_U), UInt32(cmdKey | optionKey | controlKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
        vlog("hotkey: registered ⌃⌥⌘U")
    }

    // MARK: 菜单栏 UI
    func setupUI() {
        let si = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = si
        let menu = NSMenu()
        menu.delegate = self
        itemStatus = NSMenuItem(title: "Veil", action: nil, keyEquivalent: ""); itemStatus.isEnabled = false
        itemToggle = NSMenuItem(title: "", action: #selector(toggleCurtain), keyEquivalent: ""); itemToggle.target = self
        itemAuto = NSMenuItem(title: "检测到远程查看时自动升起", action: #selector(toggleAuto), keyEquivalent: ""); itemAuto.target = self
        itemBlock = NSMenuItem(title: "帘幕期间拦截现场键鼠", action: #selector(toggleBlock), keyEquivalent: ""); itemBlock.target = self
        itemLockDesk = NSMenuItem(title: "现场触碰按键/点击时:揭幕并锁屏", action: #selector(toggleLockDesk), keyEquivalent: ""); itemLockDesk.target = self
        itemPointer = NSMenuItem(title: "现场移动鼠标/滚轮也算现场操作", action: #selector(toggleRevealPointer), keyEquivalent: ""); itemPointer.target = self
        itemLockDisc = NSMenuItem(title: "远程断开后自动锁屏", action: #selector(toggleLockDisc), keyEquivalent: ""); itemLockDisc.target = self
        itemRearm = NSMenuItem(title: "重新黑屏(远程仍连接时)", action: #selector(menuRearm), keyEquivalent: ""); itemRearm.target = self
        itemShrink = NSMenuItem(title: "远程连接时按下方设置调整分辨率", action: #selector(toggleShrink), keyEquivalent: ""); itemShrink.target = self
        itemResParent = NSMenuItem(title: "各显示器目标分辨率", action: nil, keyEquivalent: ""); itemResParent.submenu = NSMenu()
        itemRearmIdle = NSMenuItem(title: "揭幕后现场空闲 \(Int(Settings.rearmIdleSeconds)) 秒自动重新黑屏", action: #selector(toggleRearmIdle), keyEquivalent: ""); itemRearmIdle.target = self
        let log = NSMenuItem(title: "打开日志", action: #selector(openLog), keyEquivalent: ""); log.target = self
        let ax = NSMenuItem(title: "辅助功能授权…", action: #selector(openAX), keyEquivalent: ""); ax.target = self
        let quit = NSMenuItem(title: "退出 Veil", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self
        for i in [itemStatus!, NSMenuItem.separator(), itemToggle!, itemRearm!, NSMenuItem.separator(), itemAuto!, itemBlock!,
                  itemLockDesk!, itemPointer!, itemShrink!, itemResParent!, itemRearmIdle!, itemLockDisc!, NSMenuItem.separator(), ax, log, quit] { menu.addItem(i) }
        si.menu = menu
        updateUI()
    }
    func statusText() -> String {
        let remote = last?.remote ?? false
        if curtain.engaged { return "帘幕已升起(\(origin == .manual ? "手动" : "自动"))· ⌃⌥⌘U 揭幕" }
        if remote {
            return machine.awaitingUnlock ? "远程在线 · 等待现场解锁" : "远程在线 · 已揭幕(锁屏/空闲/⌃⌥⌘U 将重新黑屏)"
        }
        return "待命 · 未检测到远程查看"
    }
    func updateUI() {
        guard let si = statusItem, let b = si.button else { return }
        let name = curtain.engaged ? "eye.slash.fill" : "eye"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "Veil") {
            img.isTemplate = true; b.image = img; b.title = ""
        } else { b.title = curtain.engaged ? "V●" : "V" }
        itemStatus?.title = statusText()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        itemStatus.title = statusText()
        itemToggle.title = curtain.engaged ? "揭幕(现场解锁)" : "立即升起帘幕"
        itemRearm.isEnabled = remoteNow && !curtain.engaged
        itemAuto.state = Settings.auto ? .on : .off
        itemBlock.state = Settings.blockInput ? .on : .off
        itemLockDesk.state = Settings.lockOnDeskInput ? .on : .off
        itemPointer.state = Settings.revealOnPointer ? .on : .off
        itemRearmIdle.state = Settings.rearmOnIdle ? .on : .off
        itemShrink.state = Settings.shrinkResolution ? .on : .off
        rebuildResMenu()
        itemLockDisc.state = Settings.lockOnDisconnect ? .on : .off
    }
    /// 每次菜单打开时重建"各显示器目标分辨率"子菜单
    func rebuildResMenu() {
        guard let sub = itemResParent?.submenu else { return }
        sub.removeAllItems()
        let ids = Curtain.displays()
        let names = ids.map { DisplayKey.name(for: $0) }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for (i, d) in ids.enumerated() {
            let key = DisplayKey.key(for: d)
            var name = names[i]
            if names.filter({ $0 == name }).count > 1 { name += " · 屏 \(i + 1)" }
            let cur = Settings.choice(for: key)
            let modes = ResolutionPick.menuModes(((CGDisplayCopyAllDisplayModes(d, opts) as? [CGDisplayMode]) ?? []).map(Resolution.info))
            let curKey: ResChoice? = { if case .fixed = cur { return cur }; return nil }()
            func choiceOf(_ m: ModeInfo) -> ResChoice { .fixed(w: m.w, h: m.h, pw: m.pw, ph: m.ph, hz: Int(m.hz.rounded())) }
            let summary: String
            switch cur {
            case .default1080p: summary = "默认(1080p)"
            case .off: summary = "不改变"
            case .fixed: summary = modes.first(where: { choiceOf($0) == cur })?.menuTitle ?? "已配置(当前不可用)"
            }
            let parent = NSMenuItem(title: "\(name) · \(summary)", action: nil, keyEquivalent: "")
            let m = NSMenu()
            func add(_ title: String, _ c: ResChoice, on: Bool) {
                let it = NSMenuItem(title: title, action: #selector(pickRes(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = "\(key)\u{1F}\(d)\u{1F}\(c.encoded)"
                it.state = on ? .on : .off
                m.addItem(it)
            }
            add("默认(1080p)", .default1080p, on: cur == .default1080p)
            add("不改变", .off, on: cur == .off)
            if curKey != nil, !modes.contains(where: { choiceOf($0) == cur }) {
                let miss = NSMenuItem(title: "已配置:\(cur.encoded)(当前不可用)", action: nil, keyEquivalent: "")
                miss.isEnabled = false; m.addItem(miss)
            }
            m.addItem(NSMenuItem.separator())
            for mode in modes { add(mode.menuTitle, choiceOf(mode), on: choiceOf(mode) == cur) }
            m.autoenablesItems = false
            parent.submenu = m
            sub.addItem(parent)
        }
        if ids.isEmpty { let none = NSMenuItem(title: "未检测到显示器", action: nil, keyEquivalent: ""); none.isEnabled = false; sub.addItem(none) }
        sub.autoenablesItems = false
        itemResParent.title = "各显示器目标分辨率"
    }
    @objc func pickRes(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? String else { return }
        let parts = payload.components(separatedBy: "\u{1F}")
        guard parts.count == 3, let id = UInt32(parts[1]) else { return }
        setResChoice(key: parts[0], displayID: id, choice: ResChoice.decode(parts[2]))
    }
    /// 保存某屏的选择;远程在线且已应用过分辨率时,对该屏实时重定向(先还原再应用,失败也停在原始/新模式)
    func setResChoice(key: String, displayID: CGDirectDisplayID, choice: ResChoice) {
        Settings.setChoice(choice, for: key)
        vlog("res-config: \(DisplayKey.name(for: displayID)) \(key) -> \(choice.encoded)")
        guard wasRemote && resolution.attemptedDisplays.contains(displayID) && Settings.shrinkResolution && !headless else { return }
        resolution.restore(only: [displayID])
        resolution.apply(only: [displayID])
        curtain.reassertIfNeeded()
    }
    @objc func menuRearm() { rearmManually() }
    @objc func toggleRearmIdle() { Settings.rearmOnIdle.toggle() }
    @objc func toggleShrink() {
        Settings.shrinkResolution.toggle()
        if !Settings.shrinkResolution { resolution.restore() } else { resolution.attemptedDisplays.removeAll() }
    }
    @objc func toggleCurtain() {
        if curtain.engaged { revealLocal("menu") } else { raise(.manual, reason: "menu") }
    }
    @objc func toggleAuto() { Settings.auto.toggle() }
    @objc func toggleBlock() { Settings.blockInput.toggle(); if !Settings.blockInput { removeTap() } else if curtain.engaged { installTap() } }
    @objc func toggleLockDesk() { Settings.lockOnDeskInput.toggle() }
    @objc func toggleRevealPointer() { Settings.revealOnPointer.toggle(); motion.reset() }
    @objc func toggleLockDisc() { Settings.lockOnDisconnect.toggle() }
    @objc func openLog() { NSWorkspace.shared.open(URL(fileURLWithPath: logPath)) }
    @objc func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func quitApp() { if curtain.engaged { lower("quit") }; resolution.restore(); NSApp.terminate(nil) }
}

// MARK: - 单实例锁

var lockFD: Int32 = -1
func acquireInstanceLock() -> Bool {
    let dir = NSString(string: "~/Library/Application Support/Veil2").expandingTildeInPath
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    lockFD = open(dir + "/veil2.lock", O_CREAT | O_RDWR, 0o644)
    guard lockFD >= 0 else { return false }
    return flock(lockFD, LOCK_EX | LOCK_NB) == 0
}

// MARK: - 命令行

func fmtDisplays() -> [String] {
    Curtain.displays().map { d in
        "display \(d): main=\(CGDisplayIsMain(d) != 0) builtin=\(CGDisplayIsBuiltin(d) != 0) "
        + "\(CGDisplayPixelsWide(d))x\(CGDisplayPixelsHigh(d)) gamma-end=\(String(format: "%.3f", Curtain.gammaEnd(d)))"
    }
}

func cmdStatus() {
    let s = Sensors.sample()
    vlog("status-cmd ppid=\(getppid()) launchedByLS=\(getppid() == 1): \(s.summary)")
    print("signals:  \(s.summary)")
    print("verdict:  \(s.remote ? "REMOTE SESSION ACTIVE" : "no remote session")")
    print("locked:   \(s.locked)")
    print("idle:     hid=\(String(format: "%.1f", hidIdleSeconds()))s combined=\(String(format: "%.1f", combinedIdleSeconds()))s (hid=仅硬件输入;远程会话期间若 hid 持续增长而 combined 被清零,说明远程输入未污染现场空闲判定)")
    for l in fmtDisplays() { print(l) }
}

func cmdDoctor() {
    print("=== Veil doctor (v\(appVersion)) ===")
    print("macOS:        \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print("binary:       \(Bundle.main.bundlePath)")
    print("log:          \(logPath)")
    print("\n--- permissions ---")
    print("accessibility:    \(AXIsProcessTrusted() ? "granted" : "NOT granted (desk input cannot be blocked)")")
    print("\n--- settings ---")
    print("auto=\(Settings.auto) blockInput=\(Settings.blockInput) lockOnDisconnect=\(Settings.lockOnDisconnect) lockOnDeskInput=\(Settings.lockOnDeskInput) revealOnPointer=\(Settings.revealOnPointer)")
    print("\n--- remote session signals ---")
    let s = Sensors.sample()
    print(s.summary)
    print("verdict: \(s.remote ? "REMOTE SESSION ACTIVE" : "no remote session")")
    print("\n--- displays ---")
    for l in fmtDisplays() { print(l) }
    for d in Curtain.displays() {
        let k = DisplayKey.key(for: d)
        print("res-config  d\(d) key=\(k) name=\(DisplayKey.name(for: d)) choice=\(Settings.choice(for: k).encoded)")
    }
    print("\n--- notes ---")
    print("• 逃生键 ⌃⌥⌘U。gamma 是进程级的:Veil 退出/崩溃时系统会自动还原显示。")
    print("• 只检测\"本机作为服务端\"的 590x 连接;出站 VNC 连接不会触发。")
}

func cmdResTest(_ secs: Int) {
    Logger.shared.echo = true
    print("before: " + fmtDisplays().joined(separator: " | "))
    for s in Resolution.plan() {
        print("plan  d\(s.display): \(Resolution.info(s.from).text) -> \(Resolution.info(s.to).text)")
    }
    let r = Resolution()
    guard r.apply() else { print("res-test: nothing applied"); return }
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    print("during: " + Curtain.displays().map { d -> String in
        let m = CGDisplayCopyDisplayMode(d)!; return "d\(d) \(Resolution.info(m).text)" }.joined(separator: " | "))
    RunLoop.main.run(until: Date().addingTimeInterval(Double(secs)))
    r.restore()
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    print("after:  " + Curtain.displays().map { d -> String in
        let m = CGDisplayCopyDisplayMode(d)!; return "d\(d) \(Resolution.info(m).text)" }.joined(separator: " | "))
}

func cmdPanic() {
    CGDisplayRestoreColorSyncSettings()
    print("gamma restored")
    for l in fmtDisplays() { print(l) }
}

func cmdDemo(_ secs: Int, noInput: Bool) {
    Logger.shared.echo = true
    guard acquireInstanceLock() else {
        print("Veil is already running — quit it before running --demo."); exit(1)
    }
    if noInput { Settings.d.set(false, forKey: "blockInput") }
    let c = Controller(); c.headless = true; gController = c
    c.registerHotKey()
    c.raise(.manual, reason: "demo \(secs)s")
    var t = 0
    while t < secs && c.curtain.engaged {
        RunLoop.main.run(until: Date().addingTimeInterval(1)); t += 1
        let ends = Curtain.displays().map { "d\($0)=\(String(format: "%.3f", Curtain.gammaEnd($0)))" }.joined(separator: " ")
        print("t=\(t)s engaged=\(c.curtain.engaged) \(ends) swallowed=\(c.swallowed) passed=\(c.passed)")
    }
    if c.curtain.engaged { c.lower("demo finished") }
    print("demo: released — " + fmtDisplays().joined(separator: " | "))
    if noInput { Settings.d.removeObject(forKey: "blockInput") }
}

func cmdSelftest(skipDisplay: Bool) -> Int32 {
    var fails = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL")  \(name) \(detail)"); if !ok { fails += 1 }
    }
    print("=== Veil self-test ===")
    // 1. 解析器(含本机真实抓到的那行)
    let real = "tcp4       0   4878  192.0.2.10.5900      198.51.100.20.55414    ESTABLISHED\n"
        + "tcp4       0      0  *.5900                 *.*                    LISTEN\n"
        + "tcp6       0      0  *.5900                 *.*                    LISTEN\n"
        + "udp4       0      0  192.0.2.10.59008     203.0.113.9.443\n"
    let r1 = NetstatParse.parse(real)
    check("parse real session line", NetstatParse.establishedVNC(r1) == ["192.0.2.10.5900<-198.51.100.20.55414"], "\(NetstatParse.establishedVNC(r1))")
    check("LISTEN only is not a session", NetstatParse.establishedVNC(NetstatParse.parse("tcp4 0 0 *.5900 *.* LISTEN\n")).isEmpty)
    check("port 59008 is not 590x", NetstatParse.peeredUDP(r1).isEmpty)
    check("IPv6 established", NetstatParse.establishedVNC(NetstatParse.parse("tcp6 0 0 fe80::1%en0.5900 fe80::2%en0.50000 ESTABLISHED\n")).count == 1)
    check("verbose (-anv) line", NetstatParse.establishedVNC(NetstatParse.parse("tcp4 0 0 10.0.0.1.5900 10.0.0.2.51111 ESTABLISHED 131072 131768 123 0 0x0102 0x00000000\n")).count == 1)
    check("outbound VNC client is ignored", NetstatParse.establishedVNC(NetstatParse.parse("tcp4 0 0 10.0.0.1.50000 10.0.0.9.5900 ESTABLISHED\n")).isEmpty)
    check("peered UDP 5900", NetstatParse.peeredUDP(NetstatParse.parse("udp4 0 0 10.0.0.1.5900 10.0.0.2.52000\n")).count == 1)
    check("wildcard UDP is not peered", NetstatParse.peeredUDP(NetstatParse.parse("udp4 0 0 *.5900 *.*\n")).isEmpty)
    // 2. 判定逻辑:任一信号成立即判定远程在线
    var sg = Signals()
    check("no signal -> not remote", !sg.remote)
    sg.assertions = ["screensharingd#1"]
    check("power assertion alone -> remote", sg.remote)
    sg = Signals(); sg.captured = true
    check("CGSession captured alone -> remote", sg.remote)
    sg = Signals(); sg.tcp = ["x<-y"]
    check("tcp alone -> remote", sg.remote)
    // 2b. 揭幕/重新黑屏状态机(RDP 风格)
    func st(_ m: inout RevealMachine, remote: Bool = true, engaged: Bool, locked: Bool, idle: Double = 0, rearm: Double? = 30, t: Double) -> RevealMachine.Action {
        m.step(remote: remote, auto: true, engaged: engaged, locked: locked, hidIdle: idle, rearmIdle: rearm, now: t)
    }
    var m = RevealMachine()
    if case .raise = st(&m, engaged: false, locked: false, t: 0) { check("远程连接 -> 黑屏", true) } else { check("远程连接 -> 黑屏", false) }
    // 现场操作:揭幕+锁屏
    m.reveal(lock: true, now: 1)
    check("揭幕后(等待解锁)不会被自动重新黑屏", st(&m, engaged: false, locked: false, t: 2) == .none)
    check("屏幕已锁:等待解锁期间不黑屏", st(&m, engaged: false, locked: true, t: 3) == .none)
    check("仍在锁屏:不黑屏", st(&m, engaged: false, locked: true, t: 4) == .none)
    check("现场解锁成功 -> 保持揭幕(不黑屏)", st(&m, engaged: false, locked: false, idle: 1, t: 5) == .none && m.revealed && !m.awaitingUnlock)
    check("解锁后现场在用(idle 5s<30s) -> 不黑屏", st(&m, engaged: false, locked: false, idle: 5, t: 6) == .none)
    check("现场空闲 >=30s -> 重新黑屏", st(&m, engaged: false, locked: false, idle: 31, t: 40) == .raise("re-arm: desk idle 31s >= 30s"))
    // 再次揭幕后,通过"重新锁屏"重新黑屏
    var m2 = RevealMachine(); _ = st(&m2, engaged: false, locked: false, t: 0)
    m2.reveal(lock: true, now: 1); _ = st(&m2, engaged: false, locked: true, t: 2); _ = st(&m2, engaged: false, locked: false, t: 3)
    check("揭幕后重新锁屏 -> 重新黑屏", st(&m2, engaged: false, locked: true, idle: 1, t: 10) == .raise("re-arm: screen locked while remote active"))
    // 手动重新黑屏
    var m3 = RevealMachine(); m3.reveal(lock: false, now: 0)
    check("揭幕(不锁屏)+现场在用 -> 不黑屏", st(&m3, engaged: false, locked: false, idle: 1, t: 1) == .none)
    m3.rearmNow()
    check("手动 rearm 后 -> 黑屏", st(&m3, engaged: false, locked: false, idle: 1, t: 2) == .raise("remote session active"))
    // 兜底:锁屏没生效,超时后视为揭幕,不卡死
    var m4 = RevealMachine(); m4.reveal(lock: true, now: 0)
    check("锁屏未生效,超时前不动作", st(&m4, engaged: false, locked: false, t: 5) == .none && m4.awaitingUnlock)
    _ = st(&m4, engaged: false, locked: false, t: 25)
    check("锁屏未生效,超时后视为已揭幕", !m4.awaitingUnlock && m4.revealed)
    // 远程断开 -> 复位
    _ = st(&m4, remote: false, engaged: false, locked: false, t: 30)
    check("远程断开 -> 状态复位", !m4.revealed && !m4.awaitingUnlock)
    // 关闭空闲重新黑屏时,空闲不触发
    var m5 = RevealMachine(); m5.reveal(lock: false, now: 0)
    check("rearmOnIdle 关闭时空闲不触发", st(&m5, engaged: false, locked: false, idle: 999, rearm: nil, t: 1) == .none)
    // 帘幕已升起时不重复升起
    var m6 = RevealMachine()
    check("帘幕已升起 -> 不重复升", st(&m6, engaged: true, locked: false, t: 0) == .none)
    // 2c. 分辨率选择
    func mi(_ id: Int32, _ w: Int, _ h: Int, _ pw: Int, _ ph: Int, _ hz: Double, _ u: Bool = true) -> ModeInfo { ModeInfo(id: id, w: w, h: h, pw: pw, ph: ph, hz: hz, usable: u) }
    let landscape = [mi(54, 1920, 1080, 1920, 1080, 60), mi(55, 1920, 1080, 3840, 2160, 60), mi(56, 1920, 1080, 1920, 1080, 50),
                     mi(5, 960, 540, 1920, 1080, 60), mi(153, 1920, 1080, 1920, 1080, 60, false), mi(70, 3840, 2160, 3840, 2160, 60)]
    let curHiDPI = mi(55, 1920, 1080, 3840, 2160, 60)
    check("4K HiDPI 屏 -> 选真 1080p 像素模式(非 HiDPI)", ResolutionPick.pick(landscape, current: curHiDPI)?.id == 54, "\(String(describing: ResolutionPick.pick(landscape, current: curHiDPI)?.text))")
    check("不选 HiDPI 的 1920x1080pt(像素是 3840)", ResolutionPick.pick(landscape, current: curHiDPI)?.pw == 1920)
    check("不选 usable=false 的模式", ResolutionPick.pick([mi(153, 1920, 1080, 1920, 1080, 60, false)], current: curHiDPI) == nil)
    check("已是 1080p 像素 -> 无需切换", ResolutionPick.pick(landscape, current: mi(54, 1920, 1080, 1920, 1080, 60)) == nil)
    let portrait = [mi(41, 1080, 1920, 1080, 1920, 60), mi(40, 1080, 1920, 2160, 3840, 60), mi(42, 1080, 1920, 1080, 1920, 50), mi(4, 540, 960, 1080, 1920, 60)]
    check("竖屏 2160x3840 -> 选 1080x1920 像素", ResolutionPick.pick(portrait, current: mi(69, 2160, 3840, 2160, 3840, 60))?.id == 41)
    check("无匹配模式 -> nil(不乱切)", ResolutionPick.pick([mi(70, 3840, 2160, 3840, 2160, 60)], current: curHiDPI) == nil)
    check("刷新率就近(当前 50Hz 选 50Hz)", ResolutionPick.pick(landscape, current: mi(57, 1920, 1080, 3840, 2160, 50))?.id == 56)
    // 2c'. 每屏分辨率选择 ResChoice(纯逻辑)
    let hi = [mi(55, 1920, 1080, 3840, 2160, 60), mi(54, 1920, 1080, 1920, 1080, 60), mi(56, 1920, 1080, 1920, 1080, 50),
              mi(60, 2560, 1440, 5120, 2880, 60), mi(61, 2560, 1440, 2560, 1440, 60), mi(62, 1280, 720, 2560, 1440, 60, false)]
    let cur4k = mi(70, 3840, 2160, 3840, 2160, 60)
    let fxHi = ResChoice.fixed(w: 1920, h: 1080, pw: 3840, ph: 2160, hz: 60)
    check("ResChoice 解码 off/default/nil", ResChoice.decode("off") == .off && ResChoice.decode("default") == .default1080p && ResChoice.decode(nil) == .default1080p)
    check("ResChoice 解码乱码/字段不足 -> default", ResChoice.decode("garbage") == .default1080p && ResChoice.decode("fixed:1,2,3") == .default1080p)
    check("ResChoice fixed round-trip", ResChoice.decode(fxHi.encoded) == fxHi, fxHi.encoded)
    check("ResChoice 解码拒绝非数字/多余字段", ResChoice.decode("fixed:a,b,c,d,e") == .default1080p && ResChoice.decode("fixed:1,2,3,4,5,6") == .default1080p)
    check("choice=default 与旧 pick 一致(landscape/portrait)",
          ResolutionPick.pick(landscape, current: curHiDPI, choice: .default1080p) == ResolutionPick.pick(landscape, current: curHiDPI)
          && ResolutionPick.pick(portrait, current: mi(69, 2160, 3840, 2160, 3840, 60), choice: .default1080p) == ResolutionPick.pick(portrait, current: mi(69, 2160, 3840, 2160, 3840, 60)))
    check("choice=off -> nil", ResolutionPick.pick(hi, current: cur4k, choice: .off) == nil)
    check("fixed HiDPI 1920x1080 -> 选 55 不选 54", ResolutionPick.pick(hi, current: cur4k, choice: fxHi)?.id == 55)
    check("fixed 非HiDPI 1920x1080 -> 选 54 不选 55", ResolutionPick.pick(hi, current: cur4k, choice: .fixed(w: 1920, h: 1080, pw: 1920, ph: 1080, hz: 60))?.id == 54)
    check("fixed 当前已是目标 -> nil", ResolutionPick.pick(hi, current: mi(55, 1920, 1080, 3840, 2160, 60), choice: fxHi) == nil)
    check("fixed 目标不存在 -> nil(不乱切)", ResolutionPick.pick(hi, current: cur4k, choice: .fixed(w: 1600, h: 900, pw: 1600, ph: 900, hz: 60)) == nil)
    check("fixed 目标仅有 usable=false -> nil", ResolutionPick.pick(hi, current: cur4k, choice: .fixed(w: 1280, h: 720, pw: 2560, ph: 1440, hz: 60)) == nil)
    check("fixed 刷新率就近(50Hz 选 56)", ResolutionPick.pick(hi, current: cur4k, choice: .fixed(w: 1920, h: 1080, pw: 1920, ph: 1080, hz: 50))?.id == 56)
    check("fixed 竖屏选 41", ResolutionPick.pick(portrait, current: mi(69, 2160, 3840, 2160, 3840, 60), choice: .fixed(w: 1080, h: 1920, pw: 1080, ph: 1920, hz: 60))?.id == 41)
    check("fixed 横屏目标在竖屏夹具 -> nil(朝向保持)", ResolutionPick.pick(portrait, current: mi(69, 2160, 3840, 2160, 3840, 60), choice: fxHi) == nil)
    let mm = ResolutionPick.menuModes(hi)
    check("menuModes 过滤 usable=false", !mm.contains(where: { $0.id == 62 }) && mm.count == 5, "\(mm.map { $0.id })")
    let dup = ResolutionPick.menuModes([mi(54, 1920, 1080, 1920, 1080, 60), mi(154, 1920, 1080, 1920, 1080, 60.0), mi(155, 1920, 1080, 1920, 1080, 59.97)])
    check("menuModes 去重(同 w,h,pw,ph,hz取整)", dup.count == 1 && dup[0].id == 54, "\(dup.map { $0.id })")
    check("menuModes 排序:pw*ph 降序,同像素 hz 降序", mm.map { $0.id } == [60, 55, 61, 54, 56], "\(mm.map { $0.id })")
    let tie = ResolutionPick.menuModes([mi(55, 1920, 1080, 3840, 2160, 60), mi(70, 3840, 2160, 3840, 2160, 50), mi(71, 3840, 2160, 3840, 2160, 60)])
    check("menuModes 排序:同像素非HiDPI先于HiDPI,再 hz 降序", tie.map { $0.id } == [71, 70, 55], "\(tie.map { $0.id })")
    check("menuTitle HiDPI 含 HiDPI 与像素尺寸", mi(55, 1920, 1080, 3840, 2160, 60).menuTitle == "1920×1080 HiDPI(3840×2160 px) 60Hz", mi(55, 1920, 1080, 3840, 2160, 60).menuTitle)
    check("menuTitle 非HiDPI", mi(54, 1920, 1080, 1920, 1080, 60).menuTitle == "1920×1080 非HiDPI 60Hz", mi(54, 1920, 1080, 1920, 1080, 60).menuTitle)
    check("fixed 已在目标(四元组/hz 相同但 id 不同)-> nil", ResolutionPick.pick(hi, current: mi(999, 1920, 1080, 3840, 2160, 60), choice: fxHi) == nil)
    check("fixed hz 取整相同(59.97 vs 60)也算已在目标", ResolutionPick.pick(hi, current: mi(998, 1920, 1080, 3840, 2160, 59.97), choice: fxHi) == nil)
    // 2d. 分辨率按屏重试 Resolution.pending(纯逻辑)
    check("pending: 活动列表为空 -> 空", Resolution.pending(active: [], attempted: []).isEmpty)
    check("pending: 新出现的临时屏 29 待尝试", Resolution.pending(active: [3, 4, 29], attempted: [3, 4]) == [29])
    check("pending: 已尝试过的不重复(含已消失的 29)", Resolution.pending(active: [3, 4], attempted: [3, 4, 29]).isEmpty)
    check("pending: 去重并保持顺序", Resolution.pending(active: [4, 3, 4], attempted: []) == [4, 3], "\(Resolution.pending(active: [4, 3, 4], attempted: []))")
    var seen = Set<CGDirectDisplayID>()
    let t1 = Resolution.pending(active: [], attempted: seen)                      // 23:53:36 屏在睡眠,列表为空
    let t2 = Resolution.pending(active: [3, 4], attempted: seen); seen.formUnion(t2)  // 0.65s 后 3、4 上线
    let t3a = Resolution.pending(active: [29, 3, 4], attempted: seen); seen.formUnion(t3a)  // 临时屏 29 出现
    let t3b = Resolution.pending(active: [3, 4], attempted: seen)               // 29 消失,不再重试
    seen.removeAll()                                                              // 会话断开复位
    let t4 = Resolution.pending(active: [3, 4], attempted: seen)
    check("pending: 复现 23:53 序列(空 -> [3,4] -> [29] -> [] -> 复位后 [3,4])",
          t1.isEmpty && t2 == [3, 4] && t3a == [29] && t3b.isEmpty && t4 == [3, 4], "\(t1) \(t2) \(t3a) \(t3b) \(t4)")
    // 2e. 移动鼠标/滚轮揭幕 MotionGate(纯逻辑)
    var g1 = MotionGate()
    check("motion: 单次 10px 不触发", !g1.feed(distance: 10, now: 0))
    var g2 = MotionGate()
    let r2 = [0, 0.2, 0.4, 0.6].map { g2.feed(distance: 10, now: $0) }
    check("motion: 1s 内 4×10px 第 4 次触发", r2 == [false, false, false, true], "\(r2)")
    check("motion: 触发后清零(紧接 10px 不触发)", !g2.feed(distance: 10, now: 0.7))
    var g4 = MotionGate()
    let r4 = [g4.feed(distance: 30, now: 0), g4.feed(distance: 30, now: 1.5)]
    check("motion: 窗口过期后重新累计(30@0 + 30@1.5 不触发)", r4 == [false, false], "\(r4)")
    var g5a = MotionGate(), g5b = MotionGate()
    check("motion: 边界 39 不触发 / 40 触发", !g5a.feed(distance: 39, now: 0) && g5b.feed(distance: 40, now: 0))
    var g6 = MotionGate()
    let r6 = stride(from: 0.0, through: 10.0, by: 0.5).map { g6.feed(distance: 3, now: $0) }
    check("motion: 每 0.5s 抖 3px 持续 10s 不触发", !r6.contains(true), "\(r6.count) feeds")
    check("motion: distance(3,4)==5,scrollIntent 全 0 为 false、任一非 0 为 true",
          MotionGate.distance(dx: 3, dy: 4) == 5 && !MotionGate.scrollIntent([0, 0]) && MotionGate.scrollIntent([0, 1])
          && !MotionGate.scrollIntent([0, 0, 0, 0]) && MotionGate.scrollIntent([0, -1, 0, 0]))
    var g8 = MotionGate(); _ = g8.feed(distance: 30, now: 0); g8.reset()
    check("motion: reset 后清零(30 + reset + 30 不触发)", !g8.feed(distance: 30, now: 0.1))
    // 17. 显示器稳定标识(读取真实显示器列表;无显示器时 INFO 跳过)
    let dids = Curtain.displays()
    if dids.isEmpty { print("INFO  no displays: skip DisplayKey stability") }
    else {
        for did in dids {
            let k1 = DisplayKey.key(for: did), k2 = DisplayKey.key(for: did)
            check("DisplayKey d\(did) 非空且两次一致", !k1.isEmpty && k1 == k2, k1)
        }
    }
    check("menuTitle hz==0 无 Hz", !mi(9, 1920, 1080, 1920, 1080, 0).menuTitle.contains("Hz"), mi(9, 1920, 1080, 1920, 1080, 0).menuTitle)
    // 3. 真实环境:netstat 是否致盲;主信号是否与 pmset 一致
    if let txt = Sensors.run("/usr/sbin/netstat", ["-an"]) {
        let rows = NetstatParse.parse(txt)
        let tcpRows = rows.filter { $0.proto.hasPrefix("tcp") }.count
        print("INFO  netstat returned \(tcpRows) tcp rows (0 => blind in this environment; assertion signal covers it)")
    } else { print("INFO  netstat failed to run") }
    let live = Sensors.remoteAssertions()
    var pmsetHas = false
    if let pm = Sensors.run("/usr/bin/pmset", ["-g", "assertions"]) { pmsetHas = pm.contains("Remote user is connected") }
    check("live assertion signal agrees with pmset", live.isEmpty == !pmsetHas, "veil=\(live) pmset=\(pmsetHas)")
    // 3. gamma 引擎
    if skipDisplay { print("SKIP  gamma engage/release (--no-display)") }
    else {
        let cu = Curtain(); cu.engage()
        Thread.sleep(forTimeInterval: 0.5)
        let dark = Curtain.displays().allSatisfy { Curtain.gammaEnd($0) < 0.001 }
        check("gamma goes to 0 on all displays", dark, Curtain.displays().map { String(format: "%.3f", Curtain.gammaEnd($0)) }.joined(separator: ","))
        cu.release()
        Thread.sleep(forTimeInterval: 0.3)
        let lit = Curtain.displays().allSatisfy { Curtain.gammaEnd($0) > 0.99 }
        check("gamma restored on release", lit, Curtain.displays().map { String(format: "%.3f", Curtain.gammaEnd($0)) }.joined(separator: ","))
    }
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILED")
    return fails == 0 ? 0 : 1
}

func printHelp() {
    print("""
    Veil \(appVersion) — 现场挡屏帘幕(远程查看时蒙黑现场屏幕)

      Veil                    菜单栏常驻(正常使用方式)
      Veil --status           只读快照:信号/判定/显示器
      Veil --doctor           诊断:权限、设置、信号、显示器
      Veil --demo [秒数]      立刻升起帘幕并每秒打印状态,到时自动解除(默认 8s)
      Veil --demo 8 --no-input  同上,但不安装键鼠拦截
      Veil --selftest [--no-display]  自检:解析器单测 + gamma 黑屏/还原(会黑屏约 1 秒)
      Veil --res-test [秒]    试切分辨率(遵循菜单里每块显示器的配置;默认 1920x1080/1080x1920),等待后自动还原(默认 4s)
      Veil --panic            强制还原 gamma(最后手段)
      Veil --help

    快捷键 ⌃⌥⌘U 随时解除帘幕。
    """)
}

// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "--status": cmdStatus()
case "--doctor": cmdDoctor()
case "--panic": cmdPanic()
case "--res-test":
    cmdResTest(args.dropFirst().compactMap { Int($0) }.first ?? 4)
case "--help", "-h": printHelp()
case "--selftest": exit(cmdSelftest(skipDisplay: args.contains("--no-display")))
case "--demo":
    let secs = args.dropFirst().compactMap { Int($0) }.first ?? 8
    cmdDemo(secs, noInput: args.contains("--no-input"))
default:
    guard acquireInstanceLock() else { print("Veil is already running."); exit(1) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let c = Controller()
    // 信号:退出前务必还原显示
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { vlog("veil: received signal \(sig), shutting down"); c.resolution.restore(); CGDisplayRestoreColorSyncSettings(); exit(0) }
        src.resume()
        signalSources.append(src)
    }
    vlog("veil: started v\(appVersion) auto=\(Settings.auto) blockInput=\(Settings.blockInput) lockOnDisconnect=\(Settings.lockOnDisconnect) lockOnDeskInput=\(Settings.lockOnDeskInput) revealOnPointer=\(Settings.revealOnPointer) trusted=\(AXIsProcessTrusted())")
    if Settings.blockInput && !AXIsProcessTrusted() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    c.setupUI()
    c.start()
    app.run()
}
