// Audicap — 原生 Mac 实时字幕(AppKit)。
//
// 采集:ScreenCaptureKit 抓系统音(与输出设备无关 —— 蓝牙耳机、切设备都不断)。
// 识别:Apple SpeechAnalyzer/SpeechTranscriber(macOS 26,本地、原生草稿/定稿两级)。
//      2026-09-08 用同一批真实录音与 whisper.cpp large-v3-turbo 流式对打后换的:
//      快 20~30 倍、内存从 1.5GB 降到 ~24MB、短应答不漏、静音与纯器乐零幻觉、原生断句带标点。
// 翻译:原生 Translation 框架。
// 全程单进程、无子进程、无 HTTP、无模型文件。
import Cocoa
import CoreAudio
import AVFoundation
import CoreGraphics
import Carbon.HIToolbox
import Darwin
import SwiftUI
import Translation
import ScreenCaptureKit
import CoreMedia
import Speech

let HOME = NSHomeDirectory()

/// os_unfair_lock 的薄封装。用它而不是 NSLock:NSLock.lock() 在 async 上下文里
/// 被标记为 unavailable(Swift 6 语言模式下直接是 error)。这里只在同步的短临界区里用,
/// 不跨 await 持锁。
final class Lock: @unchecked Sendable {
    private var l = os_unfair_lock_s()
    func withLock<R>(_ body: () -> R) -> R {
        os_unfair_lock_lock(&l); defer { os_unfair_lock_unlock(&l) }
        return body()
    }
}

// 界面语言(en | zh)。UI 文案统一走 L(英文, 中文);UILANG 在启动时从设置同步、切换时更新。
var UILANG = "zh"
func L(_ en: String, _ zh: String) -> String { UILANG == "zh" ? zh : en }

/// 日志位置:开发机(有 ~/whisper-live 源码目录)照旧写在那里;别人的机器写 ~/Library/Logs/Audicap/。
/// 早先写死 ~/whisper-live,别人机器上没这个目录,createFile 静默失败 → 一条日志都没有,出了问题没法排查。
let LOGPATH: String = {
    let dev = "\(HOME)/whisper-live"
    if FileManager.default.fileExists(atPath: dev) { return dev + "/audicap.log" }
    let dir = "\(HOME)/Library/Logs/Audicap"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir + "/audicap.log"
}()

func alog(_ s: String) {
    let p = LOGPATH; let line = s + "\n"
    if !FileManager.default.fileExists(atPath: p) { FileManager.default.createFile(atPath: p, contents: nil) }
    if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces); if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v>>16)&0xff)/255, green: CGFloat((v>>8)&0xff)/255, blue: CGFloat(v&0xff)/255, alpha: 1)
    }
    var hex: String { guard let c = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent*255), Int(c.greenComponent*255), Int(c.blueComponent*255)) }
}

final class Settings {
    let d = UserDefaults(suiteName: "com.kana.audicap") ?? .standard
    var fontSize: CGFloat { get { let v = d.double(forKey: "fontSize"); return v > 0 ? v : 26 } set { d.set(newValue, forKey: "fontSize") } }
    var fontName: String { get { d.string(forKey: "fontName") ?? "PingFang SC" } set { d.set(newValue, forKey: "fontName") } }
    var bold: Bool { get { d.object(forKey: "bold") == nil ? true : d.bool(forKey: "bold") } set { d.set(newValue, forKey: "bold") } }
    var colorHex: String { get { d.string(forKey: "colorHex") ?? "#FFFFFF" } set { d.set(newValue, forKey: "colorHex") } }
    var effect: String { get { d.string(forKey: "effect") ?? "outline" } set { d.set(newValue, forKey: "effect") } }
    var effectColorHex: String { get { d.string(forKey: "effectColorHex") ?? "#000000" } set { d.set(newValue, forKey: "effectColorHex") } }
    /// 屏幕上最多显示几**行**(折行、译文都算一行),不是几句。
    /// 早先按句数限:一句 15 秒的长话折成七八行,浮窗能撑到 1/4 屏。
    var lines: Int { get { let v = d.integer(forKey: "maxLines"); return v > 0 ? v : 4 } set { d.set(newValue, forKey: "maxLines") } }
    var lineSpacing: CGFloat { get { d.object(forKey: "lineSpacing") == nil ? 3 : CGFloat(d.double(forKey: "lineSpacing")) } set { d.set(Double(newValue), forKey: "lineSpacing") } }
    var bgColorHex: String { get { d.string(forKey: "bgColorHex") ?? "#000000" } set { d.set(newValue, forKey: "bgColorHex") } }
    var bgOpacity: CGFloat { get { d.object(forKey: "bgOpacity") == nil ? 0.4 : CGFloat(d.double(forKey: "bgOpacity")) } set { d.set(Double(newValue), forKey: "bgOpacity") } }
    var translate: String { get { d.string(forKey: "translate") ?? "off" } set { d.set(newValue, forKey: "translate") } }  // off | en | zh
    var recogLang: String { get { d.string(forKey: "recogLang") ?? "auto" } set { d.set(newValue, forKey: "recogLang") } }  // auto | locale id(旧值 ja/en/zh 也认)
    /// 自动模式并行跑的语种(最多 Recognizer.maxLanes 个)
    var autoLocales: [String] { get { d.stringArray(forKey: "autoLocales") ?? ["ja-JP", "en-US", "zh-CN"] } set { d.set(newValue, forKey: "autoLocales") } }
    var micOn: Bool { get { d.bool(forKey: "micOn") } set { d.set(newValue, forKey: "micOn") } }  // 双向会议:转写自己的麦克风(默认关)
    var uiLang: String { get { d.string(forKey: "uiLang") ?? "zh" } set { d.set(newValue, forKey: "uiLang") } }  // 界面语言 en | zh
    var transColorHex: String { get { d.string(forKey: "transColorHex") ?? "#FFB8CC" } set { d.set(newValue, forKey: "transColorHex") } }
    var transSize: CGFloat { get { let v = d.double(forKey: "transSize"); return v > 0 ? v : 20 } set { d.set(newValue, forKey: "transSize") } }
    // 讲完多少秒后字幕自动淡出(0=常驻)。旧版没有任何计时器,最后一句会一直挂在屏幕上。
    var autoHideSec: Int { get { d.object(forKey: "autoHideSec") == nil ? 6 : d.integer(forKey: "autoHideSec") } set { d.set(newValue, forKey: "autoHideSec") } }
    var showDraft: Bool { get { d.object(forKey: "showDraft") == nil ? true : d.bool(forKey: "showDraft") } set { d.set(newValue, forKey: "showDraft") } }
    var draftColorHex: String { get { d.string(forKey: "draftColorHex") ?? "#B9B9B9" } set { d.set(newValue, forKey: "draftColorHex") } }
    // 终端式「选中即复制」:鼠标松开时把选中文本(去时间戳)直接送剪贴板。
    var selectToCopy: Bool { get { d.object(forKey: "selectToCopy") == nil ? true : d.bool(forKey: "selectToCopy") } set { d.set(newValue, forKey: "selectToCopy") } }
    var fastMode: Bool { get { d.object(forKey: "fastMode") == nil ? true : d.bool(forKey: "fastMode") } set { d.set(newValue, forKey: "fastMode") } }
    var autoStart: Bool { get { d.bool(forKey: "autoStart") } set { d.set(newValue, forKey: "autoStart") } }
    /// 首次启动的录音免责声明弹过一次就不再弹。
    var consentShown: Bool { get { d.bool(forKey: "consentShown") } set { d.set(newValue, forKey: "consentShown") } }
    // 留一份原始音频,供事后 whisper 整段精修(两遍解码的慢通道)。32KB/s。
    var keepTape: Bool { get { d.object(forKey: "keepTape") == nil ? true : d.bool(forKey: "keepTape") } set { d.set(newValue, forKey: "keepTape") } }
    // 滚动自动精修:开着就常驻 whisper-server(~1.5GB 内存),换来实时文本被整段上下文持续覆盖。
    var autoRefine: Bool { get { d.bool(forKey: "autoRefine") } set { d.set(newValue, forKey: "autoRefine") } }
    /// 录音写完后弹窗问是否跑 ~/whisper-job/_pipeline/audicap_post.sh(Gemini 完整稿 + 分说话人 + 比对)
    var autoPost: Bool { get { d.object(forKey: "autoPost") == nil ? true : d.bool(forKey: "autoPost") } set { d.set(newValue, forKey: "autoPost") } }
    /// 整理完全成功后删掉 wav(失败/有段落丢弃时保留,方便重跑)
    var autoPostDelete: Bool { get { d.object(forKey: "autoPostDelete") == nil ? true : d.bool(forKey: "autoPostDelete") } set { d.set(newValue, forKey: "autoPostDelete") } }
    // 云端纠错:把每段音频+ASR文本发给多模态模型听一遍再改。**会把会议音频发到云端**,默认关。
    var cloudCorrect: Bool { get { d.bool(forKey: "cloudCorrect") } set { d.set(newValue, forKey: "cloudCorrect") } }
    var cloudKey: String { get { d.string(forKey: "cloudKey") ?? "" } set { d.set(newValue, forKey: "cloudKey") } }
    var cloudModel: String { get { d.string(forKey: "cloudModel") ?? "google/gemini-2.5-flash-lite" } set { d.set(newValue, forKey: "cloudModel") } }
    // rewrite=让模型独立重转写(质量更好) / fix=只准逐字替换(保守)。实测 rewrite 能修出纠错模式修不了的同音词。
    var cloudMode: String { get { d.string(forKey: "cloudMode") ?? "rewrite" } set { d.set(newValue, forKey: "cloudMode") } }
    /// 记录(转写 txt + wav)存放目录。存的是原始值,取的时候统一做 ~ 展开 ——
    /// 唯一一处做这件事,别的地方直接读 st.archiveDir 就是展开好的绝对路径。
    /// 默认:老用户已经在用 ~/whisper-job/live-transcripts 就沿用(升级不搬家);
    /// 新用户给一个不挂在开发目录下的位置,方便把 app 分发给别人用。
    var archiveDir: String {
        get {
            let raw = d.string(forKey: "archiveDir") ?? {
                let legacy = "\(HOME)/whisper-job/live-transcripts"
                return FileManager.default.fileExists(atPath: legacy) ? legacy : "\(HOME)/Documents/Audicap"
            }()
            return (raw as NSString).expandingTildeInPath
        }
        set { d.set(newValue, forKey: "archiveDir") }
    }
    /// 会后整理脚本路径;脚本不存在/不可执行就静默跳过这个功能(见 launchPost 的 guard)。
    var postScript: String { get { d.string(forKey: "postScript") ?? "\(HOME)/whisper-job/_pipeline/audicap_post.sh" } set { d.set(newValue, forKey: "postScript") } }
}

func captionAttr(_ s: String, _ st: Settings, size: CGFloat? = nil, colorHex: String? = nil) -> NSAttributedString {
    let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = st.lineSpacing
    let fs = size ?? st.fontSize
    var font = NSFont(name: st.fontName, size: fs) ?? NSFont.systemFont(ofSize: fs, weight: .semibold)
    if st.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
    let color = NSColor(hex: colorHex ?? st.colorHex) ?? .white, ec = NSColor(hex: st.effectColorHex) ?? .black
    var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: p]
    switch st.effect {
    case "glow": let sh = NSShadow(); sh.shadowColor = ec; sh.shadowBlurRadius = 14; sh.shadowOffset = .zero; a[.shadow] = sh
    case "none": let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.45); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1); a[.shadow] = sh
    default: a[.strokeColor] = ec; a[.strokeWidth] = -2.5
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.55); sh.shadowBlurRadius = 3; sh.shadowOffset = NSSize(width: 0, height: -1); a[.shadow] = sh
    }
    return NSAttributedString(string: s, attributes: a)
}

final class CaptionView: NSView {
    var attributed = NSAttributedString() { didSet { needsDisplay = true } }
    let st: Settings
    var onClose: (() -> Void)?; var onToggle: (() -> Void)?; var onSettings: (() -> Void)?
    var onMoved: (() -> Void)?          // 用户拖动过 → 之后不要再自动居中
    private let bar = NSView(); private var lastMouse = NSPoint.zero
    private var btnClose: NSButton?, btnTrans: NSButton?, btnSet: NSButton?
    init(frame: NSRect, st: Settings) {
        self.st = st; super.init(frame: frame); wantsLayer = true
        bar.wantsLayer = true; bar.layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor; bar.layer?.cornerRadius = 7; bar.isHidden = true; addSubview(bar)
        func mk(_ t: String, _ x: CGFloat, _ w: CGFloat, _ sel: Selector) -> NSButton { let b = NSButton(title: t, target: self, action: sel); b.bezelStyle = .inline; b.isBordered = false; b.contentTintColor = .white; b.frame = NSRect(x: x, y: 3, width: w, height: 22); bar.addSubview(b); return b }
        btnClose = mk(L("✕ Close", "✕ 关闭"), 8, 62, #selector(c)); btnTrans = mk(L("▤ Transcript", "▤ 记录"), 74, 104, #selector(t)); btnSet = mk(L("⚙ Settings", "⚙ 设置"), 182, 86, #selector(sg))
    }
    func relocalizeBar() { btnClose?.title = L("✕ Close", "✕ 关闭"); btnTrans?.title = L("▤ Transcript", "▤ 记录"); btnSet?.title = L("⚙ Settings", "⚙ 设置") }
    required init?(coder: NSCoder) { fatalError() }
    @objc func c() { onClose?() }; @objc func t() { onToggle?() }; @objc func sg() { onSettings?() }
    override func layout() { super.layout(); bar.frame = NSRect(x: bounds.width/2 - 140, y: bounds.height - 30, width: 280, height: 28) }
    override func draw(_ r: NSRect) {
        guard attributed.length > 0 else { return }
        let maxW = bounds.width - 36
        let box = attributed.boundingRect(with: NSSize(width: maxW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        if st.bgOpacity > 0.01 {
            let bw = min(box.width, maxW) + 40, bh = box.height + 22
            let rect = NSRect(x: (bounds.width - bw)/2, y: (bounds.height - bh)/2 - 6, width: bw, height: bh)
            (NSColor(hex: st.bgColorHex) ?? .black).withAlphaComponent(st.bgOpacity).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
        }
        attributed.draw(with: NSRect(x: (bounds.width - maxW)/2, y: (bounds.height - box.height)/2 - 6, width: maxW, height: box.height + 6), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
    override func updateTrackingAreas() { super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea); addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) }
    override func mouseEntered(with e: NSEvent) { bar.isHidden = false }
    override func mouseExited(with e: NSEvent) { bar.isHidden = true }
    override func mouseDown(with e: NSEvent) { if e.clickCount == 2 { onToggle?(); return }; lastMouse = NSEvent.mouseLocation }
    override func mouseDragged(with e: NSEvent) {
        let cur = NSEvent.mouseLocation
        if let w = window { let o = w.frame.origin; w.setFrameOrigin(NSPoint(x: o.x + cur.x - lastMouse.x, y: o.y + cur.y - lastMouse.y)) }
        lastMouse = cur
        onMoved?()
    }
    override func rightMouseDown(with e: NSEvent) { onClose?() }
}

/// 标了这个属性的文字**永不进剪贴板**。译文只是参考,
/// 用户要的是原文 —— 选中整段时译文照样显示,复制出去却只有原文。
let kNoCopy = NSAttributedString.Key("audicapNoCopy")

/// 记录面板的文本视图。三件事:
///  · 复制时去掉行首 [HH:MM:SS] —— 记录要带时间,粘出去不要。
///  · 「选中即复制」:像终端那样,鼠标一松开就进剪贴板,不用再按 ⌘C。
///  · 剔掉 kNoCopy 的段落(译文),复制出去的永远只有原文。
/// (注意:⌘C 能生效的前提是 App 设置了 mainMenu,见 buildMainMenu 的注释。)
final class CopyCleanTextView: NSTextView {
    var selectToCopy: (() -> Bool)?

    private func cleanSelection() -> String? {
        guard let r = selectedRanges.first?.rangeValue, r.length > 0,
              let att = textStorage?.attributedSubstring(from: r) else { return nil }
        let m = NSMutableAttributedString(attributedString: att)
        var drop: [NSRange] = []
        m.enumerateAttribute(kNoCopy, in: NSRange(location: 0, length: m.length)) { v, rr, _ in
            if v != nil { drop.append(rr) }
        }
        for rr in drop.reversed() { m.deleteCharacters(in: rr) }   // 倒着删,前面的偏移才不会失效
        let out = stripTimestamps(m.string)
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : out
    }
    @objc override func copy(_ sender: Any?) {
        guard let cleaned = cleanSelection() else { return }   // 只选到译文:什么都不做,别清空剪贴板
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cleaned, forType: .string)
    }
    override func mouseUp(with e: NSEvent) {
        super.mouseUp(with: e)
        guard selectToCopy?() == true, let cleaned = cleanSelection(), !cleaned.isEmpty else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cleaned, forType: .string)
    }
}
// ── 权限 ──────────────────────────────────────────────────────────────────────
// 系统音靠「屏幕录制」权限(ScreenCaptureKit 目前唯一入口,没有绕开的纯音频 API);
// 麦克风走标准 TCC。旧行为是权限没给就悄悄不出字幕,用户以为程序坏了 —— 参照
// thxjune/MeetingMind 的 PermissionsModel,给出可读状态 + 一键跳转设置面板。

/// 屏幕录制是否已授权。**注意**:CGPreflightScreenCaptureAccess 在用户去系统设置里
/// 打开开关后不会立刻反映出来 —— macOS 要等这个 app 重新启动才真正生效(TCC 在
/// relaunch 时才刷新),所以调用点的文案都要带上「授权后请退出并重开」,不能指望
/// 这里下一次调用就变 true。
func screenRecordingGranted() -> Bool { CGPreflightScreenCaptureAccess() }

/// 麦克风授权状态,只在「双向会议」(st.micOn)转写自己麦克风时用得到。
func micGranted() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

func openScreenRecordingSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
}
func openMicrophoneSettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
}
// ── 采集层 ────────────────────────────────────────────────────────────────────
// 两处都改成「回调交出 AVAudioPCMBuffer」,不再往管道里写 int16:
// 旧实现在实时回调里直接阻塞 write() 喂 python,推理一忙就把采集回调堵死(播放卡顿的根源)。
// 现在交给 Recognizer 的有界 AsyncStream,回调只入队。

/// 找一个内置麦克风。**不要跟随默认输入**:蓝牙耳机常是默认输入,一旦打开它的麦克风,
/// macOS 会把耳机从 A2DP 拽进 HFP 通话模式,播放音质当场变差(Apple 官方文档明确说明)。
/// 用户只是想转写会议,不该为此牺牲听感。
func builtInInputDeviceID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    let sys = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return nil }
    var devs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &devs) == noErr else { return nil }
    for d in devs {
        // 必须有输入通道
        var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                            mScope: kAudioDevicePropertyScopeInput,
                                            mElement: kAudioObjectPropertyElementMain)
        var ssz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(d, &sa, 0, nil, &ssz) == noErr, ssz > 0 else { continue }
        let abl = UnsafeMutableRawPointer.allocate(byteCount: Int(ssz), alignment: 16)
        defer { abl.deallocate() }
        guard AudioObjectGetPropertyData(d, &sa, 0, nil, &ssz, abl) == noErr else { continue }
        let list = abl.assumingMemoryBound(to: AudioBufferList.self)
        var chans: UInt32 = 0
        withUnsafePointer(to: &list.pointee.mBuffers) { p in
            for i in 0..<Int(list.pointee.mNumberBuffers) { chans += p[i].mNumberChannels }
        }
        guard chans > 0 else { continue }
        // 传输类型 = 内置
        var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                            mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain)
        var tt: UInt32 = 0; var tsz = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(d, &ta, 0, nil, &tsz, &tt) == noErr, tt == kAudioDeviceTransportTypeBuiltIn {
            return d
        }
    }
    return nil
}

func deviceName(_ id: AudioDeviceID) -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString,
                                       mScope: kAudioObjectPropertyScopeGlobal,
                                       mElement: kAudioObjectPropertyElementMain)
    // 用 Unmanaged 收 CFStringRef:直接对 `var x: CFString` 取地址会让编译器
    // 形成指向对象引用的 raw pointer(不安全,且 ARC 语义未定义)。
    var ref: Unmanaged<CFString>?
    var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &ref) == noErr,
          let r = ref else { return "?" }
    return r.takeRetainedValue() as String
}

/// 系统音采集(ScreenCaptureKit)。抓的是各 app 播放的数字流,**与输出设备无关** ——
/// 2026-09-08 实测:蓝牙耳机 / 内置扬声器 / 说话说到一半切换输出设备,整句一字不丢。
/// 代价是权限走「屏幕录制」且菜单栏强制显示紫色指示器(macOS 26 SDK 里没有能绕开的纯音频入口)。
final class SCKCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onHealth: ((String) -> Void)?
    private var stream: SCStream?
    private let q = DispatchQueue(label: "com.kana.audicap.sck")
    private var stopping = false            // 用户主动停止 → 不自动重连
    private var retry = 0
    private(set) var callbacks = 0
    private(set) var peak: Float = 0
    private(set) var lastFormat = ""
    private var deviceObserverInstalled = false

    func start() {
        stopping = false
        Task { await self.begin() }
        installDeviceObserver()
    }

    private func begin() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { fail("找不到显示器"); return }
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = 16000
            cfg.channelCount = 1
            cfg.excludesCurrentProcessAudio = true      // 不抓自己(否则字幕朗读会自激)
            cfg.width = 64; cfg.height = 64             // 只注册 .audio 输出,视频轨不接收
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                             configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
            try await s.startCapture()
            stream = s
            retry = 0
            alog("SCK capture running")
            onHealth?("ok")
        } catch {
            // 没授权就别重连:每次重试 SCK 都会再弹一次系统授权框(2026-10-01 实测会一直弹),
            // 而 TCC 改动要重开 app 才生效,本进程里重试多少次都不会成功。
            let ns = error as NSError
            if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue {
                alog("SCK: 屏幕录制未授权(userDeclined),不重连;授权后需重开 app")
                onHealth?(L("Screen Recording not granted — grant it, then quit and reopen Audicap",
                            "未授权屏幕录制:授权后请退出并重开 Audicap"))
                return
            }
            fail("SCK 启动失败: \(error.localizedDescription)")
        }
    }

    private func fail(_ msg: String) {
        alog("SCK: \(msg)")
        onHealth?(msg)
        scheduleRetry()
    }

    /// 可恢复错误退避重连;用户主动停止则不重连。
    private func scheduleRetry() {
        guard !stopping, retry < 6 else { return }
        retry += 1
        let delay = min(30.0, pow(2.0, Double(retry)))
        alog("SCK: \(Int(delay))s 后第 \(retry) 次重连")
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopping else { return }
            Task { await self.begin() }
        }
    }

    /// 输出设备变化时不盲目重建 —— 实测切设备 SCK 不断流。只有真的断了(didStopWithError)才重连。
    /// 这里只记一笔,便于诊断"换耳机后没字幕"到底是采集断了还是别的环节。
    private func installDeviceObserver() {
        guard !deviceObserverInstalled else { return }
        deviceObserverInstalled = true
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            guard let self else { return }
            let cb0 = self.callbacks
            alog("输出设备变了(SCK 应不受影响,4s 后核对)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.callbacks == cb0 && !self.stopping {
                    alog("换设备后 4s 没有音频回调 → 重建 SCK")
                    self.restart()
                }
            }
        }
    }

    func restart() {
        let s = stream; stream = nil
        Task {
            try? await s?.stopCapture()
            await self.begin()
        }
    }

    func stop() {
        stopping = true
        let s = stream; stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ s: SCStream, didStopWithError e: Error) {
        alog("SCK stopped: \(e)")
        onHealth?("采集中断: \(e.localizedDescription)")
        stream = nil
        scheduleRetry()
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sb) else { return }
        // 用真实 ASBD 建 buffer,不假设格式(旧实现写死 f32 mono,格式一变就整块丢弃)
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let fmt = AVAudioFormat(streamDescription: asbd) else { return }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n),
                                                          into: buf.mutableAudioBufferList) == noErr else { return }
        callbacks += 1
        if lastFormat.isEmpty {
            lastFormat = "\(Int(fmt.sampleRate))Hz ch\(fmt.channelCount) \(fmt.commonFormat.rawValue)"
            alog("SCK 实际格式: \(lastFormat)")
        }
        if let ch = buf.floatChannelData {
            var p: Float = 0
            for i in 0..<Int(buf.frameLength) { let a = abs(ch[0][i]); if a > p { p = a } }
            if p > peak { peak = p }
        }
        onBuffer?(buf)
    }
}

/// 麦克风采集(双向会议:把自己说的话也转写)。
/// 显式绑内置麦克风,并监听引擎配置变化(插拔耳机会改输入格式,旧实现缓存了格式就此哑掉)。
final class MicCapture {
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onHealth: ((String) -> Void)?
    private var engine = AVAudioEngine()
    private var running = false
    private var observer: NSObjectProtocol?

    func start() {
        guard !running else { return }
        engine = AVAudioEngine()
        // 绑内置麦克风:绝不因为开转写而把蓝牙耳机拽进 HFP
        if let dev = builtInInputDeviceID() {
            var d = dev
            let unit = engine.inputNode.audioUnit
            let st = AudioUnitSetProperty(unit!, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
            alog("mic: 绑定内置麦克风 \(deviceName(dev)) (st=\(st))")
        } else {
            alog("mic: 找不到内置麦克风,退回默认输入")
            onHealth?("找不到内置麦克风")
        }
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            alog("mic: 输入格式无效 \(fmt)"); onHealth?("麦克风输入格式无效"); return
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] buf, _ in
            self?.onBuffer?(buf)
        }
        do { try engine.start(); running = true; alog("mic capture running @\(Int(fmt.sampleRate))Hz ch\(fmt.channelCount)") }
        catch { alog("mic engine err: \(error)"); onHealth?("麦克风启动失败: \(error.localizedDescription)"); return }

        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            guard let self, self.running else { return }
            alog("mic: 音频配置变化 → 重建")
            self.stop(); self.start()
        }
    }

    func stop() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}
// ── 翻译层 ────────────────────────────────────────────────────────────────────
// 原生 macOS Translation 框架。2026-09-08 实测旧实现的竞态:
// enqueue 里一改 config,SwiftUI 的 translationTask 会取消旧 session、run() 重建 AsyncStream
// 并覆盖 cont —— 而那一句刚好 yield 进了已被取消的旧 stream,直接丢失。
// 日志里表现为成串的 `translate err: CancellationError()`,实测 6 句里丢 4 句。
// 修法:待翻任务放在 session 之外的 pending 队列,新 session 起来时接手,不再依赖 cont 的时序。
func transDetect(_ t: String) -> String {
    if t.range(of: "\\p{Hiragana}|\\p{Katakana}", options: .regularExpression) != nil { return "ja" }
    if t.range(of: "\\p{Hangul}", options: .regularExpression) != nil { return "ko" }
    if t.range(of: "\\p{Han}", options: .regularExpression) != nil { return "zh" }
    return "en"
}

/// 识别 locale → 翻译源语种。优先用识别结果,比按字形猜可靠
/// (旧的 transDetect 把韩语归成英语,韩语因此永远翻不出来)。
func srcFromLocale(_ l: String) -> String? {
    if l.hasPrefix("ja") { return "ja" }
    if l.hasPrefix("zh") || l.hasPrefix("yue") { return "zh" }
    if l.hasPrefix("ko") { return "ko" }
    if l.hasPrefix("en") { return "en" }
    if l.hasPrefix("de") { return "de" }
    if l.hasPrefix("fr") { return "fr" }
    if l.hasPrefix("es") { return "es" }
    if l.hasPrefix("it") { return "it" }
    if l.hasPrefix("pt") { return "pt" }
    return nil
}

final class Translator: ObservableObject {
    struct Job { let id: Int; let ts: String; let text: String; let src: String }
    @Published var config: TranslationSession.Configuration?
    var onResult: ((Int, String, String, String) -> Void)?   // (id, ts, 原文, 译文)
    private(set) var target = "off"
    private var srcCode = ""
    private var cont: AsyncStream<Job>.Continuation?
    private var pending: [Job] = []
    private let lock = Lock()

    private func lang(_ c: String) -> Locale.Language? {
        switch c {
        case "ja": return Locale.Language(identifier: "ja")
        case "en": return Locale.Language(identifier: "en")
        case "zh": return Locale.Language(identifier: "zh-Hans")
        case "ko": return Locale.Language(identifier: "ko")
        case "de": return Locale.Language(identifier: "de")
        case "fr": return Locale.Language(identifier: "fr")
        case "es": return Locale.Language(identifier: "es")
        case "it": return Locale.Language(identifier: "it")
        case "pt": return Locale.Language(identifier: "pt")
        default:   return nil
        }
    }

    func setTarget(_ code: String) {
        lock.withLock { target = code; srcCode = ""; pending.removeAll() }
        DispatchQueue.main.async { self.config = nil }
        alog("translator target=\(code)")
    }

    /// srcHint 来自识别 locale;没有就退回字形推断。
    func enqueue(_ id: Int, _ ts: String, _ text: String, srcHint: String?) {
        guard target != "off" else { return }
        let src = srcHint ?? transDetect(text)
        if src == target { return }                       // 已是目标语,不翻
        guard let s = lang(src), let t = lang(target) else { return }
        let job = Job(id: id, ts: ts, text: text, src: src)
        let needNewSession: Bool = lock.withLock {
            if src != srcCode {
                srcCode = src
                pending.append(job)                       // 先攒着,等新 session 起来接手
                return true
            }
            if let c = cont { c.yield(job) } else { pending.append(job) }
            return false
        }
        if needNewSession {
            DispatchQueue.main.async { self.config = TranslationSession.Configuration(source: s, target: t) }
        }
    }

    func run(_ session: TranslationSession) async {
        let stream = AsyncStream<Job> { c in
            self.lock.withLock {
                self.cont = c
                for j in self.pending { c.yield(j) }      // ★接手上一个 session 没消费掉的任务
                self.pending.removeAll()
            }
        }
        do { try await session.prepareTranslation() } catch { alog("prepareTranslation: \(error)") }
        for await job in stream {
            do {
                let r = try await session.translate(job.text)
                let out = r.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty {
                    let id = job.id, ts = job.ts, src = job.text
                    await MainActor.run { self.onResult?(id, ts, src, out) }
                }
            } catch is CancellationError {
                // session 被换掉了:把这句放回 pending,由下一个 session 接手,不再静默丢失
                lock.withLock { pending.append(job) }
            } catch {
                alog("translate err: \(error)")
            }
        }
    }
}

struct TranslatorHost: View {
    @ObservedObject var translator: Translator
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .translationTask(translator.config) { session in
                await translator.run(session)
            }
    }
}

struct Cap { var id: Int; var ts: String; var orig: String; var trans: String; var draft: Bool = false }

/// 转录里的一行。
///
/// 设计参照工业界实时转录(Otter/Teams/Meet)的做法:**单一份转录不断演化**,
/// 而不是给用户看两个版本。慢通道回来后就地改写同一行,原文留在 `original` 里可回看,
/// 不销毁也不并列。
/// at 用**音频时间轴**(SpeechAnalyzer 的 Result.range),不是墙钟——墙钟会和精修块错位。
struct Entry {
    var at: Double
    var until: Double = 0          // 这条覆盖到音频的第几秒(精修按区间相交替换时要用)
    var ts: String
    var text: String               // 当前显示的文本(可能已被精修改写)
    var original: String = ""      // 被改写前的实时文本;没被改写过就是空
    var trans: String = ""
    var transOf: String = ""       // 这条译文对应的原文。文本一变就作废,避免重复翻译/译错行
    var mic: Bool = false          // 自己说的话(不在系统音录音里,不参与精修)
    var refined: Bool = false
    var id: Int = 0
    var lang: String = ""          // 按句仲裁选出的语种(ja-JP/en-US/zh-CN),同语言不翻译要用
}
// ── 主程序 ────────────────────────────────────────────────────────────────────
final class App: NSObject, NSApplicationDelegate {
    let st = Settings()
    var win: NSWindow!, view: CaptionView!, panel: NSWindow!, tv: CopyCleanTextView!, settingsWin: NSWindow?
    var searchField: NSSearchField?
    let sck = SCKCapture()
    let mic = MicCapture()
    let sysRecog = Recognizer(tag: "sys")
    let micRecog = Recognizer(tag: "mic")
    var statusItem: NSStatusItem?
    var capturing = false
    var recogState: RecogState = .idle
    var health = "—"

    var transcriptFH: FileHandle?; var transcriptPath = ""
    let tape = TapeRecorder()                 // 两遍解码的慢通道:音频留档
    let autoRefiner = AutoRefiner()           // 滚动精修:每 30s 用整段上下文重跑并覆盖(whisper,本地)
    let cloud = CloudCorrector()              // 云端音频纠错:句驱动,把音频+文本一起给多模态模型
    var refineTimer: Timer?
    var captureStart = Date()
    /// 采集会话代次。停止后迟到的识别结果会带着旧代次回来,
    /// 不挡的话会写进已关闭的 transcript(还会自己新建一个文件),甚至混进下一场会议。
    var session = 0
    var langProbeSent = false        // 云端判语种只做一次
    var entries: [Entry] = []                 // 实时稿(Apple)。**永不被精修改写**
    var showOriginal = false                  // 是否把被精修改写前的原文也显示出来
    var rendered: [(id: Int, range: NSRange)] = []   // 面板里每条 entry 占的字符范围(增量更新用)
    var lastSrcHint: String? = nil            // 最近一次识别的源语种,给翻译用
    var lastWav = ""
    var refining = false
    var refineNote = ""
    var refinedSec = 0.0
    let translator = Translator(); var transHostView: NSView?
    var caps: [Cap] = []
    var draft: Cap?
    var idc = 0
    var hideTimer: Timer?
    /// 用户把字幕条拖到哪就记在这。relayout 会围绕它伸缩,而不是每次都拉回屏幕中心。
    var captionAnchorX: CGFloat?
    var sigSources: [DispatchSourceSignal] = []
    var hotKeyRef: EventHotKeyRef?
    weak var autoLangPD: NSPopUpButton?     // 设置里「自动模式的语言」下拉
    weak var sizeL: NSTextField?; weak var linesL: NSTextField?; weak var spL: NSTextField?
    weak var bgOpL: NSTextField?; weak var transSizeL: NSTextField?; weak var hideL: NSTextField?
    weak var archiveDirL: NSTextField?      // 设置里「记录存放位置」路径展示,选完目录要刷新它

    // MARK: 启动

    func applicationDidFinishLaunching(_ n: Notification) {
        Recognizer.autoLocales = st.autoLocales
        tape.onFinished = { [weak self] p, sec in self?.postProcess(wav: p, seconds: sec) }
        signal(SIGPIPE, SIG_IGN)
        UILANG = st.uiLang
        buildMainMenu()                 // ★必须有主菜单,否则 Cmd+C 根本进不了 responder chain
        buildCaptionWindow()
        buildPanel()
        buildStatusItem()
        translator.onResult = { [weak self] id, ts, src, text in self?.applyTrans(id, ts, src, text) }
        let host = NSHostingView(rootView: TranslatorHost(translator: translator))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1); view.addSubview(host); transHostView = host
        if st.translate != "off" { translator.setTarget(st.translate) }
        wireRecognizers()
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.quit() }; s.resume(); sigSources.append(s)
        }
        registerHotKey()
        alog("=== boot ===")
        showConsentNoticeIfNeeded()     // ★必须排在 autoStart 之前:不能等字幕已经在转写了才提醒
        if st.autoStart { startCapture() } else { showPill() }
    }

    /// 首次启动的录音免责声明,一次装机弹一次。**必须在自动开始转写之前弹完**——
    /// 不然 autoStart 已经在录系统音了,提示才姗姗来迟。LSUIElement 的 app 默认不在前台,
    /// 不先 activate 的话 alert 可能弹出来却拿不到键盘焦点甚至被挡在别的窗口后面。
    func showConsentNoticeIfNeeded() {
        guard !st.consentShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("A quick heads-up on recording", "关于录音的一点提醒")
        a.informativeText = L(
            "Audicap transcribes whatever your Mac plays, including other people's voices in a call. In many places you need everyone's consent to record or transcribe a conversation — you're responsible for getting it where required.",
            "Audicap 会转写 Mac 正在播放的所有声音,包括通话里其他人的声音。很多地方录音或转写对话需要征得所有人同意,是否需要由你按当地规定确认并取得同意。")
        a.addButton(withTitle: L("OK", "知道了"))
        a.runModal()
        st.consentShown = true
    }

    func buildCaptionWindow() {
        let scr = NSScreen.main!.frame
        win = NSWindow(contentRect: NSRect(x: scr.midX - 300, y: scr.minY + 80, width: 600, height: 110),
                       styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false; win.backgroundColor = .clear; win.hasShadow = false; win.level = .statusBar
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        view = CaptionView(frame: NSRect(origin: .zero, size: win.frame.size), st: st)
        view.onMoved = { [weak self] in self?.captionAnchorX = self?.win.frame.midX }
        // 转写中:停止转写(浮窗缩成小条)。已停止:收起浮窗,菜单栏 ◎ →「显示字幕」可找回。
        // 旧版只调 stopCapture,而它 guard capturing —— 停止后再点「关闭」毫无反应(2026-09-24 实测)。
        view.onClose = { [weak self] in
            guard let self else { return }
            if self.capturing { self.stopCapture() } else { self.win.orderOut(nil) }
        }
        view.onToggle = { self.togglePanel() }
        view.onSettings = { self.openSettings() }
        win.contentView = view; win.orderFrontRegardless(); relayout()
    }

    /// LSUIElement 的 app 不显示菜单栏菜单,但 **设置 mainMenu 才能让 Cmd+C / Cmd+A 等
    /// 标准编辑快捷键进入 responder chain** —— 旧版没有主菜单,所以记录面板里
    /// 「复制去掉时间戳」那段代码从来没被调用过一次。
    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Settings…", "设置…"), action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit Audicap", "退出 Audicap"), action: #selector(quit), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: L("Edit", "编辑"))
        edit.addItem(withTitle: L("Copy", "复制"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findItem = edit.addItem(withTitle: L("Find in transcript", "在记录中查找"),
                                    action: #selector(focusSearch), keyEquivalent: "f")
        findItem.target = self
        edit.addItem(withTitle: L("Copy whole transcript", "复制整份记录"),
                     action: #selector(copyAll), keyEquivalent: "C").target = self
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◎"
        item.button?.toolTip = "Audicap"
        item.menu = buildStatusMenu()
        statusItem = item
    }

    func buildStatusMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self
        return m
    }

    func refreshStatusMenu(_ m: NSMenu) {
        m.removeAllItems()
        let stateText: String
        switch recogState {
        case .idle:            stateText = L("Idle", "待命")
        case .preparing:       stateText = L("Loading language model…", "正在准备语言包…")
        case .listening:       stateText = capturing ? L("Listening", "正在听") : L("Ready", "就绪")
        case .unsupported(let s): stateText = L("Unsupported locale: \(s)", "不支持的语种: \(s)")
        case .failed(let e):   stateText = L("Error: \(e)", "出错: \(e)")
        }
        let head = NSMenuItem(title: "● " + stateText, action: nil, keyEquivalent: "")
        head.isEnabled = false; m.addItem(head)
        if capturing {
            let d = NSMenuItem(title: "   " + L("audio: ", "音频: ")
                               + (sck.callbacks > 0 ? L("ok · \(sck.callbacks) blocks · peak \(String(format: "%.3f", sck.peak))",
                                                        "正常 · \(sck.callbacks) 块 · 峰值 \(String(format: "%.3f", sck.peak))")
                                                    : L("no data yet", "还没收到数据")),
                               action: nil, keyEquivalent: "")
            d.isEnabled = false; m.addItem(d)
            if !cloud.localeHint.isEmpty && sysRecog.localeIDs.count > 1 {
                let li = NSMenuItem(title: "   " + L("language: \(cloud.localeHint)", "语种: \(cloud.localeHint)"),
                                    action: nil, keyEquivalent: "")
                li.isEnabled = false; m.addItem(li)
            }
            if sysRecog.localeIDs.count > 1 {
                let s = sysRecog.laneScores().map { "\($0.0)=\($0.1 < 0 ? "-" : String(format: "%.2f", $0.1))" }.joined(separator: " ")
                let li = NSMenuItem(title: "   " + L("lang score: ", "语种得分: ") + s, action: nil, keyEquivalent: "")
                li.isEnabled = false; m.addItem(li)
            }
        }
        m.addItem(.separator())
        m.addItem(withTitle: capturing ? L("Stop transcribing", "停止转写") : L("Start transcribing", "开始转写"),
                  action: #selector(toggleCapture), keyEquivalent: "").target = self
        m.addItem(withTitle: win.isVisible ? L("Hide captions", "隐藏字幕") : L("Show captions", "显示字幕"),
                  action: #selector(toggleCaptionWindow), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Transcript…", "记录面板…"), action: #selector(togglePanel), keyEquivalent: "").target = self
        if entries.contains(where: { $0.refined }) {
            let ti = m.addItem(withTitle: showOriginal ? L("Hide pre-refine originals", "隐藏改写前原文")
                                                       : L("Show pre-refine originals", "显示改写前原文"),
                               action: #selector(toggleRefinedView), keyEquivalent: "")
            ti.target = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: L("Copy whole transcript", "复制整份记录"), action: #selector(copyAll), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Export transcript…", "导出记录…"), action: #selector(exportTranscript), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Reveal transcript folder", "打开记录文件夹"), action: #selector(revealFolder), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Show log file", "显示日志文件"), action: #selector(revealLog), keyEquivalent: "").target = self
        // whisper 模型删掉之后这项就是死的,不可用时整条不显示
        if Refiner.available {
            m.addItem(.separator())
            let rTitle: String
            if refining { rTitle = refineNote.isEmpty ? L("Refining…", "精修中…") : refineNote }
            else if tapeReady() { rTitle = L("Refine with whisper (full context)", "用 whisper 精修（整段上下文）") }
            else { rTitle = L("Refine with whisper — no recording yet", "用 whisper 精修 — 还没有录音") }
            let ri = m.addItem(withTitle: rTitle, action: #selector(refineNow), keyEquivalent: "")
            ri.target = self; ri.isEnabled = !refining && tapeReady()
        }
        if st.cloudCorrect && capturing {
            let cost = Double(cloud.tokensIn) / 1e6 * 0.10 + Double(cloud.tokensOut) / 1e6 * 0.40
            let ci = NSMenuItem(title: "   " + L("cloud: \(cloud.calls) calls, ~$\(String(format: "%.3f", cost))",
                                                 "云端纠错:\(cloud.calls) 次,约 $\(String(format: "%.3f", cost))")
                                + (cloud.lastError.isEmpty ? "" : " ⚠︎"),
                                action: nil, keyEquivalent: "")
            ci.isEnabled = false; m.addItem(ci)
        }
        if st.autoRefine && capturing {
            let lag = max(0, tape.seconds - refinedSec)
            let ai = NSMenuItem(title: "   " + L("auto-refine: behind by \(Int(lag))s", "滚动精修:落后 \(Int(lag)) 秒"),
                                action: nil, keyEquivalent: "")
            ai.isEnabled = false; m.addItem(ai)
        }
        m.addItem(.separator())
        // 权限状态一直显示,不等采集失败才提示 —— 之前是权限没给就悄悄没字幕,用户根本不知道原因。
        let screenLine = NSMenuItem(title: "   " + L("Screen Recording \(screenRecordingGranted() ? "✓" : "✗")",
                                                      "屏幕录制 \(screenRecordingGranted() ? "✓" : "✗")"),
                                    action: nil, keyEquivalent: "")
        screenLine.isEnabled = false; m.addItem(screenLine)
        if st.micOn {
            let micLine = NSMenuItem(title: "   " + L("Microphone \(micGranted() ? "✓" : "✗")",
                                                       "麦克风 \(micGranted() ? "✓" : "✗")"),
                                     action: nil, keyEquivalent: "")
            micLine.isEnabled = false; m.addItem(micLine)
        }
        m.addItem(withTitle: L("Check permissions…", "检查权限…"), action: #selector(checkPermissions), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: L("Settings…", "设置…"), action: #selector(openSettings), keyEquivalent: "").target = self
        m.addItem(withTitle: L("Quit Audicap", "退出 Audicap"), action: #selector(quit), keyEquivalent: "").target = self
    }

    /// 缺哪个权限就跳去对应的设置面板;都齐了就打开屏幕录制页(不算错误,只是没什么可跳转的)。
    /// 出问题时让用户把日志发过来:在 Finder 里选中日志文件
    @objc func revealLog() { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: LOGPATH)]) }
    @objc func checkPermissions() {
        if !screenRecordingGranted() { openScreenRecordingSettings() }
        else if st.micOn && !micGranted() { openMicrophoneSettings() }
        else { openScreenRecordingSettings() }
    }

    // MARK: 采集 / 识别

    func wireRecognizers() {
        sck.onBuffer = { [weak self] buf in
            guard let self else { return }
            self.sysRecog.feed(buf)
            self.tape.write(buf)              // 同一份音频顺手留档,供事后 whisper 精修
        }
        sck.onHealth = { [weak self] h in DispatchQueue.main.async { self?.health = h } }
        mic.onBuffer = { [weak self] buf in self?.micRecog.feed(buf) }
        mic.onHealth = { [weak self] h in DispatchQueue.main.async { self?.health = h } }

        sysRecog.onState = { [weak self] s in
            guard let self else { return }
            self.recogState = s
            switch s {
            case .preparing: self.setCaption(L("● preparing language model…", "● 正在准备语言包…"))
            case .listening: if self.caps.isEmpty { self.setCaption(L("● listening…", "● 正在听…")) }
            case .failed(let e), .unsupported(let e): self.setCaption("⚠︎ " + e)
            case .idle: break
            }
            self.statusItem?.button?.title = self.capturing ? "◉" : "◎"
        }
        cloud.onFixes = { [weak self] ids, fixes in
            DispatchQueue.main.async { self?.applyCloudFixes(ids: ids, fixes: fixes) }
        }
        // 重转写:复用 applyRefined —— 它已经做了"就地替换整段 + 原文存进 original + 旧译文作废"
        cloud.onRewrite = { [weak self] ids, text in
            DispatchQueue.main.async { self?.applyRefined(ids: ids, text: text, allowExpansion: true) }
        }
        // whisper 慢通道(已弃用,模型已删)。保留接口可编译:把时间窗换算成 entry ID 再走新路径。
        autoRefiner.onRefined = { [weak self] from, to, text in
            DispatchQueue.main.async {
                guard let self else { return }
                let ids = self.entries.filter { !$0.mic && $0.until > from && $0.at < to }.map { $0.id }
                self.applyRefined(ids: ids, text: text)
            }
        }
        autoRefiner.onStatus = { [weak self] s in DispatchQueue.main.async { self?.refineNote = s } }
        // 语种一锁定就固定下来。早先是每条结果都改 localeHint,
        // 结果"日语那批还在 pending、英语新句先到"时会把日语音频标成英语发出去(评审指出)。
        sysRecog.onLocale = { [weak self] loc in
            self?.cloud.localeHint = loc
            alog("cloud localeHint = \(loc)")
        }
        sysRecog.onFinal = { [weak self] r in self?.onFinal(r, mic: false) }
        sysRecog.onDraft = { [weak self] r in self?.onDraft(r) }
        micRecog.onFinal = { [weak self] r in self?.onFinal(r, mic: true) }
    }

    @objc func toggleCapture() { capturing ? stopCapture() : startCapture() }

    func startCapture() {
        guard !capturing else { return }
        // 看起来没权限:请求 + 打开设置页 + 提示,但**不拦截**,照样尝试开始。
        // 旧行为是 SCK 静默失败、字幕永远空着,用户以为程序坏了。
        // 不拦截是因为 CGPreflightScreenCaptureAccess 在 macOS 26 上是否准确反映 SCK 的
        // 「屏幕与系统录音」权限没验证过,且授权后要重开 app 才更新 —— 误报会把能用的 app 整个锁死。
        // CGRequestScreenCaptureAccess 首次会弹系统对话框,拒绝过一次之后只会跳设置页,所以设置页一起打开。
        // 每次启动 app 最多提醒一次:万一这个判断在 macOS 26 上误报,也不至于每次开始都弹设置页
        if !screenRecordingGranted() && !permHintShown {
            permHintShown = true
            alog("权限:CGPreflightScreenCaptureAccess=false,照样尝试开始")
            _ = CGRequestScreenCaptureAccess()
            openScreenRecordingSettings()
            // 开始后会先显示「启动中」,所以提示延后;已经出字幕就说明其实有权限,不打扰
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.capturing, self.caps.isEmpty else { return }
                self.showPill(L("If captions stay empty: grant Screen Recording, then quit and reopen Audicap",
                                "如果一直没字幕:请授予「屏幕录制」权限,然后退出并重开 Audicap"))
            }
        }
        capturing = true
        session += 1
        statusItem?.button?.title = "◉"
        newTranscript()
        captureStart = Date(); entries.removeAll(); rendered.removeAll(); refinedSec = 0; showOriginal = false
        langProbeSent = false
        caps.removeAll(); draft = nil                    // 上一场的字幕不能留到这一场
        tv?.textStorage?.setAttributedString(NSAttributedString())
        lastWav = (transcriptPath as NSString).deletingPathExtension + ".wav"
        if st.keepTape || st.autoRefine { tape.start(path: lastWav) }
        if st.cloudCorrect && !st.cloudKey.isEmpty {
            if !tape.isRunning { tape.start(path: lastWav) }
            cloud.mode = CloudMode(rawValue: st.cloudMode) ?? .rewrite
            cloud.localeHint = Recognizer.localeIDs(for: st.recogLang).first ?? ""
            cloud.start(tape: tape, key: st.cloudKey, model: st.cloudModel)
            refineTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.cloud.tickIdle(now: self.tape.seconds)
                self.probeLanguageIfNeeded()
            }
        }
        if st.autoRefine {
            autoRefiner.start(tape: tape, lang: whisperLang)
            refineTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.autoRefiner.tick(alignTo: self?.refineBoundary())
            }
        }
        sysRecog.start(setting: st.recogLang, fast: st.fastMode)
        sck.start()
        if st.micOn { mic.start(); micRecog.start(setting: st.recogLang, fast: st.fastMode) }
        showCaptionWindow()
        showPill(L("● starting…", "● 启动中…"))
    }

    func stopCapture() {
        guard capturing else { return }
        capturing = false
        statusItem?.button?.title = "◎"
        sck.stop(); sysRecog.stop()
        mic.stop(); micRecog.stop()
        refineTimer?.invalidate(); refineTimer = nil
        cloud.stop()
        tape.stop()
        if st.autoRefine {
            autoRefiner.tick(final: true)          // 把尾巴那段也精修掉
            autoRefiner.stop()                     // 内部会等最后一块解完再真正关 server
        }
        draft = nil
        closeTranscript()
        showPill()
    }

    // MARK: 字幕

    func onDraft(_ r: RecogResult) {
        guard st.showDraft else { return }
        draft = Cap(id: -1, ts: nowTS(), orig: r.text, trans: "", draft: true)
        render(); relayout(); cancelHide()
    }

    func onFinal(_ r: RecogResult, mic isMic: Bool) {
        guard capturing else { return }        // 停止后迟到的结果一律丢弃
        let text = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 单字符定稿基本是噪声起音被误判(实测出现过只有「あ」的一行),不值得占一行字幕
        guard text.count > 1 else { return }
        idc += 1
        let ts = nowTS()
        // ★对齐必须用**音频时间轴**,不能用墙钟。
        //   定稿到达的时刻总是滞后于实际说话(识别延迟 + 多语种仲裁的 0.35s),
        //   而精修块是按音频秒数切的。两个时间轴错位会让并列对照筛出空集
        //   (实测出现过整段 Apple 侧为空、相似度 0% 的假分歧)。
        //   r.range 是 SpeechAnalyzer 给的音频时间范围,与 tape 的秒数同源。
        let at = r.range.start.seconds.isFinite ? max(0, r.range.start.seconds)
                                                : Date().timeIntervalSince(captureStart)
        if isMic {
            // 自己说的话只进记录,不上浮动字幕(开会时自己说的不需要看字幕)
            entries.append(Entry(at: at, until: at, ts: ts, text: text, mic: true, id: idc))
            fileAppend("[\(ts)] 🎤 \(text)\n"); panelAppend(entries[entries.count - 1])
            return
        }
        let until = r.range.end.seconds.isFinite ? max(at, r.range.end.seconds) : at
        entries.append(Entry(at: at, until: until, ts: ts, text: text, id: idc, lang: r.locale))
        draft = nil
        caps.append(Cap(id: idc, ts: ts, orig: text, trans: ""))
        if caps.count > st.lines { caps.removeFirst(caps.count - st.lines) }
        render(); relayout()
        fileAppend("[\(ts)] \(text)\n")      // .txt 是逐字流水,只追加
        panelAppend(entries[entries.count - 1])
        lastSrcHint = srcFromLocale(r.locale)
        requestTranslation(idc, ts, text)
        // 喂给云端纠错。什么时候真的发由它按句间停顿决定,这里只管投递。
        if st.cloudCorrect {
            // 只跑一路语种(用户手动指定)时语种是确定的;自动模式下用这句胜出那路的置信度
            let conf = sysRecog.localeIDs.count == 1 ? 1.0 : r.confidence
            cloud.enqueue(id: idc, text: text, from: at, until: until, locale: r.locale, conf: conf)
        }
        scheduleHide()
    }

    /// src = 这条译文实际翻的那段原文。必须核对 ——
    /// 评审指出:原文 A 发起翻译、云端把同一 ID 改写成 B、A 的译文回来后被无条件写入,
    /// 还会把 transOf 标成 B,于是旧译文被"认证"成 B 的译文,而且不会再重译。
    func applyTrans(_ id: Int, _ ts: String, _ src: String, _ text: String) {
        if let ei = entries.lastIndex(where: { $0.id == id }) {
            guard entries[ei].text == src else {
                alog("丢弃过期译文 id=\(id)(原文已被改写)"); return
            }
            entries[ei].trans = text
            entries[ei].transOf = src
            panelUpdate(entries[ei])
        }
        if let idx = caps.firstIndex(where: { $0.id == id }), caps[idx].orig == src {
            caps[idx].trans = text; render(); relayout()
        }
        scheduleHide()
        writeFinalTranscript()
    }

    func nowTS() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: Date())
    }

    func setCaption(_ s: String) { showPill(s) }

    func render() {
        var shown = caps
        if let d = draft { shown.append(d) }
        guard !shown.isEmpty else { return }
        if shown.count > st.lines { shown.removeFirst(shown.count - st.lines) }
        let m = NSMutableAttributedString()
        for (i, c) in shown.enumerated() {
            if i > 0 { m.append(NSAttributedString(string: "\n")) }
            // 草稿用淡一档的颜色,一眼能看出"这句还没说完、可能还会改"
            m.append(captionAttr(c.orig, st, colorHex: c.draft ? st.draftColorHex : nil))
            if !c.trans.isEmpty {
                m.append(NSAttributedString(string: "\n"))
                m.append(captionAttr(c.trans, st, size: st.transSize, colorHex: st.transColorHex))
            }
        }
        view.attributed = tailLines(m, width: captionTextWidth - 24, maxLines: st.lines)
    }

    /// 字幕文字区宽度,和 relayout / CaptionView.draw 用同一个口径。
    var captionTextWidth: CGFloat { (win.screen ?? NSScreen.main!).frame.width * 0.7 - 36 }

    /// 只保留折行后的最后 maxLines 行,前面截掉的换成「…」。宽度留了 24pt 余量,
    /// 免得补上「…」后又多折出一行。
    func tailLines(_ s: NSAttributedString, width: CGFloat, maxLines: Int) -> NSAttributedString {
        guard s.length > 0 else { return s }
        let ts = NSTextStorage(attributedString: s), lm = NSLayoutManager()
        let tc = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0; lm.addTextContainer(tc); ts.addLayoutManager(lm); lm.ensureLayout(for: tc)
        var starts: [Int] = []; var gi = 0
        while gi < lm.numberOfGlyphs {
            var r = NSRange(); _ = lm.lineFragmentRect(forGlyphAt: gi, effectiveRange: &r)
            starts.append(lm.characterIndexForGlyph(at: r.location)); gi = max(NSMaxRange(r), gi + 1)
        }
        guard starts.count > maxLines else { return s }
        let cut = starts[starts.count - maxLines]
        let t = NSMutableAttributedString(attributedString: s.attributedSubstring(from: NSRange(location: cut, length: s.length - cut)))
        while t.length > 0, t.string.hasPrefix("\n") { t.deleteCharacters(in: NSRange(location: 0, length: 1)) }
        if t.length > 0 { t.insert(NSAttributedString(string: "…", attributes: t.attributes(at: 0, effectiveRange: nil)), at: 0) }
        return t
    }

    /// 讲完 N 秒后把字幕收起来。0 = 常驻。
    /// 收起 ≠ 丢文本:记录面板和 transcript 文件里始终是全的,这里只管屏幕上那几行。
    /// 收起后不是整个消失,而是缩成一个小条,既不挡视线、又能一眼看到 app 还活着、还能点。
    func scheduleHide() {
        cancelHide()
        let sec = st.autoHideSec
        guard sec > 0 else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(sec), repeats: false) { [weak self] _ in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.4
                self.win.animator().alphaValue = 0.0
            } completionHandler: {
                self.caps.removeAll(); self.draft = nil     // 只清屏幕;文本在记录面板/文件里
                self.showPill()
            }
        }
    }
    func cancelHide() {
        hideTimer?.invalidate(); hideTimer = nil
        if win.alphaValue < 1 { win.alphaValue = 1 }
    }
    func showCaptionWindow() { win.alphaValue = 1; win.orderFrontRegardless() }

    /// 空闲小条。字号压到 13、无背景,只占一点点位置。
    func showPill(_ text: String? = nil) {
        let t = text ?? (capturing ? L("● listening", "● 正在听") : L("◎ Audicap", "◎ Audicap"))
        view.attributed = captionAttr(t, st, size: 13,
                                      colorHex: capturing ? nil : st.draftColorHex)
        win.alphaValue = 1; relayout(); win.orderFrontRegardless()
    }
    @objc func toggleCaptionWindow() {
        if win.isVisible { win.orderOut(nil) } else { showCaptionWindow() }
    }

    func relayout() {
        // 用浮窗自己所在的屏:NSScreen.main 跟着键盘焦点走,多屏时点一下别的屏上的窗口,
        // 浮窗就会被夹到那块屏的坐标里,看起来是突然跳走。
        let scr = (win.screen ?? NSScreen.main!).frame; let maxW = scr.width * 0.7
        let attr = view.attributed.length > 0 ? view.attributed : captionAttr(" ", st)
        let box = attr.boundingRect(with: NSSize(width: maxW - 36, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = min(maxW, max(260, box.width + 56))
        let h = min(max(70, box.height + 44), scr.height * 0.3)      // 硬上限,行数裁剪之外再兜一层
        // 围绕用户摆放的位置伸缩;没拖过才用屏幕中心。
        // 早先每次 relayout 都写死 scr.midX,结果拖到哪都会被下一句字幕拉回中间。
        let cx = captionAnchorX ?? scr.midX
        let x = min(max(scr.minX, cx - w/2), scr.maxX - w)
        let y = min(max(scr.minY, win.frame.minY), scr.maxY - h)       // 往上长时别顶出屏幕
        win.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        view.frame = NSRect(origin: .zero, size: NSSize(width: w, height: h)); view.needsDisplay = true
    }

    // MARK: 记录面板 / 文本导出

    func buildPanel() {
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L("Audicap — Transcript", "Audicap — 记录")
        panel.isReleasedWhenClosed = false; panel.center()
        let cv = panel.contentView!

        let sf = NSSearchField(frame: NSRect(x: 10, y: cv.bounds.height - 34, width: cv.bounds.width - 20, height: 24))
        sf.autoresizingMask = [.width, .minYMargin]
        sf.placeholderString = L("Find in transcript (⌘F) — Enter for next", "在记录中查找（⌘F）— 回车跳下一处")
        sf.target = self; sf.action = #selector(doSearch(_:))
        cv.addSubview(sf); searchField = sf

        let sc = NSScrollView(frame: NSRect(x: 0, y: 0, width: cv.bounds.width, height: cv.bounds.height - 40))
        sc.autoresizingMask = [.width, .height]; sc.hasVerticalScroller = true
        tv = CopyCleanTextView(frame: sc.bounds)
        tv.isEditable = false; tv.isSelectable = true
        tv.font = NSFont.systemFont(ofSize: 15)
        tv.backgroundColor = NSColor(white: 0.08, alpha: 1)
        tv.textColor = NSColor(white: 0.92, alpha: 1)
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.autoresizingMask = [.width]
        tv.selectToCopy = { [weak self] in self?.st.selectToCopy ?? false }
        sc.documentView = tv; cv.addSubview(sc)
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) }
        else { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    @objc func focusSearch() {
        if !panel.isVisible { togglePanel() }
        panel.makeFirstResponder(searchField)
    }
    @objc func doSearch(_ f: NSSearchField) {
        let q = f.stringValue
        guard !q.isEmpty, let s = tv.textStorage?.string else { return }
        let from = tv.selectedRange().location + max(1, tv.selectedRange().length)
        let ns = s as NSString
        var r = ns.range(of: q, options: [.caseInsensitive], range: NSRange(location: min(from, ns.length), length: ns.length - min(from, ns.length)))
        if r.location == NSNotFound { r = ns.range(of: q, options: [.caseInsensitive]) }   // 回绕
        guard r.location != NSNotFound else { NSSound.beep(); return }
        tv.setSelectedRange(r); tv.scrollRangeToVisible(r); tv.showFindIndicator(for: r)
    }
    /// 整份记录去掉时间戳后进剪贴板 —— 用户经常要把转写文本喂给别的工具。
    @objc func copyAll() {
        guard let s = tv.textStorage?.string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(stripTimestamps(s), forType: .string)
    }
    @objc func exportTranscript() {
        guard let s = tv.textStorage?.string, !s.isEmpty else { NSSound.beep(); return }
        let p = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmm"
        p.nameFieldStringValue = "audicap-\(f.string(from: Date())).md"
        p.allowedContentTypes = [.plainText]
        p.begin { r in
            guard r == .OK, let url = p.url else { return }
            let body = "# Audicap 记录 \(f.string(from: Date()))\n\n" + stripTimestamps(s)
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    @objc func revealFolder() {
        let d = st.archiveDir
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(transcriptPath.isEmpty ? nil : transcriptPath,
                                      inFileViewerRootedAtPath: d)
    }

    /// 慢通道结果到了。
    ///
    /// **不覆盖实时稿。** 早先的设计是直接替换掉那段时间窗的实时文本,但实测发现
    /// whisper 会在块尾的静音上吐「ご視聴ありがとうございました」这类幻觉 —— 而 Apple
    /// 根本没产出这句。那样等于用垃圾冲掉本来正确的结果。现在两版并列保存,
    /// 面板可切换、文件里都写,由人来取舍。
    /// allowExpansion:重转写模式下"文本变长"是**正常且期望**的 ——
    /// Apple 只出碎片时,云端转出完整句子必然更长。那道防幻觉膨胀的闸是为 whisper
    /// 纠错模式设计的(它会把「哦。」膨胀成套话),套在重转写上会把好结果全拦掉
    /// (2026-09-10 实测:3字→26字、11字→51字、4字→48字 全被误拦)。
    /// 慢通道结果到了 —— 按 **entry ID** 精确替换那几行。
    ///
    /// 早先按"时间区间相交"取行,评审指出会吞内容:请求音频向后多取 0.3s,
    /// 那期间到达的下一句 entry 与时间窗相交、被整行替换,但云端只听到它前 0.3 秒。
    /// 改成只动请求里明确带上的那几个 ID。
    ///
    /// allowExpansion:重转写模式下"文本变长"是**正常且期望**的 ——
    /// Apple 只出碎片时云端转出完整句子必然更长。防幻觉膨胀那道闸是为 whisper
    /// 纠错模式设计的(它会把「哦。」膨胀成套话),套在重转写上会把好结果全拦掉。
    func applyRefined(ids: [Int], text: String, allowExpansion: Bool = false) {
        guard !text.isEmpty, !ids.isEmpty else { return }
        let idSet = Set(ids)
        let covered = entries.enumerated().filter {
            !$0.element.mic && !$0.element.refined && idSet.contains($0.element.id)
        }
        guard !covered.isEmpty else { return }
        let liveText = covered.map { $0.element.text }.joined()
        // 完全一致才跳过。早先用「相似度 ≥0.92 就跳过」,评审指出 100 字改 1 个字
        // 相似度约 0.99 会被拒 —— 那恰恰是这层最该做的修正。
        guard normEqual(liveText, text) == false else { return }
        let liveLen = liveText.count, refLen = text.count
        if !allowExpansion && liveLen > 0 && refLen > liveLen * 3 && liveLen < 24 {
            alog("refine 跳过:实时 \(liveLen) 字 → 精修 \(refLen) 字,疑似幻觉膨胀")
            return
        }
        // 重转写允许变长(Apple 出碎片时云端转出完整句必然更长),但**必须有上限**。
        // 2026-09-13 实测:语种判错后云端按错误语种硬转,4 字实时膨胀成 200 字编造内容。
        //
        // ★判据必须用**音频时长**,不能用实时文本长度 —— 后者正是这层要修的东西:
        //   Apple 被背景音乐干扰时只吐 6 个字,而那 11 秒音频真有 110 字内容,
        //   按 liveLen*8 算会把完全正确的重转写毙掉(2026-09-13 实测,整行因此没被修正)。
        //   按秒数算:说话再快也就 ~25 字符/秒,4 秒吐 200 字那种幻觉一抓一个准。
        let audioSec = max(0.5, covered.last!.element.until - covered[0].element.at)
        if allowExpansion && refLen > Int(audioSec * 25) + 40 {
            alog("refine 跳过:\(String(format: "%.1f", audioSec))s 音频 → 重转写 \(refLen) 字,超出语速上限,判为幻觉")
            return
        }

        let idxs = Set(covered.map { $0.offset })
        var merged = covered[0].element
        merged.text = text
        merged.until = covered.last!.element.until
        merged.original = liveText
        merged.refined = true
        merged.trans = ""; merged.transOf = ""
        refinedSec = max(refinedSec, merged.until)

        // 被替换的行是否连续(中间可能夹着 🎤 麦克风行)
        let contiguous = (idxs.max()! - idxs.min()! + 1) == idxs.count
        var next: [Entry] = []
        for (i, e) in entries.enumerated() {
            if i == idxs.min() { next.append(merged) }
            else if idxs.contains(i) { continue }
            else { next.append(e) }
        }
        entries = next
        // ★浮窗字幕同步:被这次改写覆盖的那几行,合并成改写后的一行。
        //   不同步的话屏幕上会一直挂着 Apple 那版(常常正是错得离谱的那版),
        //   而记录面板已经换成改写后的 —— 同一句话两个版本并存,以谁为准看不出来。
        //   已经滚出浮窗(超过 st.lines)或被 autoHide 清掉的行自然找不到,跳过即可。
        if let firstPos = caps.firstIndex(where: { idSet.contains($0.id) }) {
            caps.removeAll { idSet.contains($0.id) }
            caps.insert(Cap(id: merged.id, ts: merged.ts, orig: text, trans: ""), at: firstPos)
            if caps.count > st.lines { caps.removeFirst(caps.count - st.lines) }
            render(); relayout()
        }
        if contiguous {
            panelReplace(ids: covered.map { $0.element.id }, with: merged)
        } else {
            // 不连续时 panelReplace 会把夹在中间的麦克风行一起删掉(评审指出),整块重画更安全
            rerenderPanel()
        }
        if st.translate != "off" { requestTranslation(merged.id, merged.ts, text) }
        writeFinalTranscript()
    }

    /// 归一化后完全相同(只忽略空白和标点)。
    func normEqual(_ a: String, _ b: String) -> Bool {
        func n(_ s: String) -> String {
            String(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init)).lowercased()
        }
        return n(a) == n(b)
    }

    /// 云端纠错回来了:按「逐字匹配」应用到**指定的那几行**上。
    /// 匹配不上就丢弃 —— 模型只被允许提"把 A 换成 B",不能重写整句,
    /// 所以对不上的一律不采纳,这是防止它擅自改写的最后一道闸。
    func applyCloudFixes(ids: [Int], fixes: [CloudFix]) {
        let idSet = Set(ids)
        var touched = 0
        for i in entries.indices {
            let e = entries[i]
            if e.mic || !idSet.contains(e.id) { continue }
            var t = e.text
            var applied: [String] = []
            for f in fixes where t.contains(f.wrong) {
                t = t.replacingOccurrences(of: f.wrong, with: f.right)
                applied.append("\(f.wrong)→\(f.right)")
            }
            guard t != e.text else { continue }
            if entries[i].original.isEmpty { entries[i].original = e.text }
            entries[i].text = t
            entries[i].refined = true
            entries[i].trans = ""; entries[i].transOf = ""     // 文本变了,旧译文作废
            panelUpdate(entries[i])
            if let ci = caps.firstIndex(where: { $0.id == e.id }) {
                caps[ci].orig = t; caps[ci].trans = ""
                render(); relayout(); showCaptionWindow(); scheduleHide()
            }
            if st.translate != "off" { requestTranslation(entries[i].id, entries[i].ts, t) }
            touched += 1
            alog("cloud fix [\(e.ts)] " + applied.joined(separator: ", "))
        }
        if touched > 0 { writeFinalTranscript() }
    }

    /// 翻译入口。同一段文本只翻一次 —— 精修改写会触发重译,不去重就会出现重复译文。
    /// 源文本已经是目标语言就别翻了 —— 中文翻成中文是白跑一趟,
    /// 而且模型会把原句重写一遍,看起来像"原文被改了"。
    /// 判据优先用文字系统(云端改写过之后语种可能变),取不到再退回按句仲裁选出的语种。
    func sameLanguageAsTarget(_ text: String, _ entryLang: String) -> Bool {
        // 文字系统和识别语种对得上 → 用识别语种(精确到 fr/de/…);对不上(云端改写换了语言)→ 退回按文字猜。
        // 旧版只按文字猜,法语会被当成英语,翻译目标是英语时就不翻了(2026-09-25)。
        let src = !entryLang.isEmpty && scriptMatches(text, entryLang) == true
            ? entryLang : (CloudCorrector.scriptOf(text) ?? entryLang)
        guard !src.isEmpty else { return false }
        return src.hasPrefix(st.translate)      // zh-CN→"zh" / en-US→"en"
    }

    func requestTranslation(_ id: Int, _ ts: String, _ text: String) {
        guard st.translate != "off" else { return }
        let lang = entries.first(where: { $0.id == id })?.lang ?? ""
        if sameLanguageAsTarget(text, lang) {
            // 之前若已经翻过(比如刚改了目标语言),把旧译文清掉
            if let i = entries.firstIndex(where: { $0.id == id }), !entries[i].trans.isEmpty {
                entries[i].trans = ""; entries[i].transOf = ""
                panelUpdate(entries[i])
            }
            if let ci = caps.firstIndex(where: { $0.id == id }), !caps[ci].trans.isEmpty {
                caps[ci].trans = ""; render(); relayout()
            }
            return
        }
        if let e = entries.first(where: { $0.id == id }), e.transOf == text { return }
        translator.enqueue(id, ts, text, srcHint: lastSrcHint)
    }

    @objc func toggleRefinedView() {
        showOriginal.toggle()
        rerenderPanel()
    }
    func tsFor(seconds: Double) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: captureStart.addingTimeInterval(seconds))
    }
    // ── 增量渲染 ───────────────────────────────────────────────────────────
    // 转录是活的:新句子追加、精修就地改写、译文回填,都会改动面板内容。
    // 早期实现每次变化都 setAttributedString 整块重画,有两个真问题:
    //   ① 用户正在拖选时被打断,选中即复制直接废掉;
    //   ② 恢复选区用的是旧偏移,上方行长度一变就指到别的字上。
    // 所以改成只替换发生变化的那一段,并按长度差修正选区和后续行的位置 ——
    // 专业转录工具都是这么做的。

    /// 一条 entry 渲染成的文本块(正文 + 可选原文 + 可选译文)。
    func renderEntry(_ e: Entry) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.foregroundColor: tv.textColor!, .font: tv.font!]
        // 译文 = 粉色小字,且带 kNoCopy:看得见、复制不走
        let transAttr: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(hex: st.transColorHex) ?? NSColor(hex: "#FFB8CC")!,
            .font: NSFont.systemFont(ofSize: max(10, (tv.font?.pointSize ?? 15) - 3)),
            kNoCopy: true]
        let faint: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor(white: 0.45, alpha: 1),
                                                    .font: NSFont.systemFont(ofSize: max(9, (tv.font?.pointSize ?? 15) - 2))]
        let m = NSMutableAttributedString()
        let mark = e.mic ? "🎤 " : (e.refined ? "✎ " : "")
        m.append(NSAttributedString(string: "[\(e.ts)] \(mark)\(e.text)\n", attributes: base))
        if showOriginal && !e.original.isEmpty {
            m.append(NSAttributedString(string: "        (实时原文) \(e.original)\n", attributes: faint))
        }
        if !e.trans.isEmpty {
            m.append(NSAttributedString(string: "        → \(e.trans)\n", attributes: transAttr))
        }
        return m
    }

    /// 把 [start,end) 这段范围换成新内容,并修正选区与滚动。
    func splicePanel(_ range: NSRange, _ new: NSAttributedString) {
        guard let ts = tv.textStorage else { return }
        let sv = tv.enclosingScrollView
        let visible = sv?.contentView.bounds ?? .zero
        // 只有本来就贴着底部才跟随新内容滚动;用户往上翻着看时不抢滚动条
        let atBottom = sv == nil ? true : visible.maxY >= tv.bounds.maxY - 40
        // 改动是否发生在可视区**上方** —— 是的话内容会整体位移,得补偿滚动量,
        // 否则用户正在读的那段字会凭空跳走(精修改写上面的行时必然发生)
        let lm = tv.layoutManager, tc = tv.textContainer
        var yBefore: CGFloat? = nil
        if !atBottom, let lm, let tc, NSMaxRange(range) <= ts.length {
            let g = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let r = lm.boundingRect(forGlyphRange: g, in: tc)
            if r.maxY < visible.minY { yBefore = tv.bounds.height }   // 记录改动前文档高度
        }
        let sel = tv.selectedRange()
        let delta = new.length - range.length
        ts.replaceCharacters(in: range, with: new)
        // 选区修正:改动完全在选区之前才平移;与选区相交则不动(宁可不改,也别把选区挪错位置)
        if sel.length > 0 {
            if NSMaxRange(range) <= sel.location {
                let moved = NSRange(location: sel.location + delta, length: sel.length)
                if NSMaxRange(moved) <= ts.length { tv.setSelectedRange(moved) }
            } else if range.location >= NSMaxRange(sel) {
                tv.setSelectedRange(sel)
            }
        }
        if atBottom {
            tv.scrollToEndOfDocument(nil)
        } else if let yBefore, let sv {
            // 文档高度变了多少,就把视口移动多少,让眼前的内容保持不动
            tv.layoutManager?.ensureLayout(for: tv.textContainer!)
            let shift = tv.bounds.height - yBefore
            if abs(shift) > 0.5 {
                var o = sv.contentView.bounds.origin
                o.y += shift
                sv.contentView.scroll(to: o)
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }

    /// 追加一条(新定稿)。
    func panelAppend(_ e: Entry) {
        guard tv != nil, let ts = tv.textStorage else { return }
        let block = renderEntry(e)
        let r = NSRange(location: ts.length, length: 0)
        rendered.append((id: e.id, range: NSRange(location: ts.length, length: block.length)))
        splicePanel(r, block)
    }

    /// 就地改写一条(精修 / 译文回填)。
    func panelUpdate(_ e: Entry) {
        guard tv != nil, let i = rendered.firstIndex(where: { $0.id == e.id }) else { return }
        let block = renderEntry(e)
        let old = rendered[i].range
        let delta = block.length - old.length
        splicePanel(old, block)
        rendered[i].range.length = block.length
        for j in (i + 1)..<rendered.count { rendered[j].range.location += delta }
    }

    /// 精修把若干条合成一条:替换掉它们占据的整段范围。
    func panelReplace(ids: [Int], with e: Entry) {
        guard tv != nil, !ids.isEmpty else { return }
        let idxs = rendered.indices.filter { ids.contains(rendered[$0].id) }
        guard let f = idxs.first, let l = idxs.last else { return }
        let start = rendered[f].range.location
        let end = NSMaxRange(rendered[l].range)
        let block = renderEntry(e)
        let delta = block.length - (end - start)
        splicePanel(NSRange(location: start, length: end - start), block)
        rendered.replaceSubrange(f...l, with: [(id: e.id, range: NSRange(location: start, length: block.length))])
        for j in (f + 1)..<rendered.count { rendered[j].range.location += delta }
    }

    /// 整块重画。只在切换「显示原文」这类全局变化时用。
    func rerenderPanel() {
        guard tv != nil, let ts = tv.textStorage else { return }
        let m = NSMutableAttributedString()
        rendered.removeAll()
        for e in entries {
            let b = renderEntry(e)
            rendered.append((id: e.id, range: NSRange(location: m.length, length: b.length)))
            m.append(b)
        }
        ts.setAttributedString(m)
        tv.scrollToEndOfDocument(nil)
    }

    /// 最终稿(单一版本,精修已就地生效)。被改写的行把实时原文放在引用块里,
    /// 想追溯时看得到,但不打断正文阅读。
    func writeFinalTranscript() {
        guard !transcriptPath.isEmpty else { return }
        let out = (transcriptPath as NSString).deletingPathExtension + ".md"
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        var body = "# Audicap 记录 \(f.string(from: captureStart))\n\n"
        let n = entries.filter { $0.refined }.count
        let by = st.cloudCorrect ? "云端多模态模型听录音后改写" : "whisper 用整段上下文重跑改写"
        body += "> 实时转写 Apple SpeechAnalyzer;标 ✎ 的行已由\(by)"
        body += n > 0 ? "(本次 \(n) 行)。\n" : "。\n"
        body += "> 逐字流水见同名 .txt,音频见同名 .wav。\n\n"
        for e in entries {
            let mark = e.mic ? "🎤 " : (e.refined ? "✎ " : "")
            // 改了就是改了,不在正文里重复原文(原文仍存在内存里,菜单「显示改写前原文」可看)
            body += "**[\(e.ts)]** \(mark)\(e.text)\n\n"
            if !e.trans.isEmpty { body += "> \(e.trans)\n\n" }
        }
        try? body.write(toFile: out, atomically: true, encoding: .utf8)
    }

    /// 给精修挑一个切点:离「上次切点 + 一块时长」最近的**句子边界**。
    /// 必须落在句子之间 —— 切在句中会让 whisper 块的内容跨过边界,
    /// 与未被替换的实时行重复(实测出现过同一段话出现两遍)。
    func refineBoundary() -> Double? {
        let from = autoRefiner.nextStart
        let target = from + autoRefiner.chunkSec
        let starts = entries.filter { !$0.mic && $0.at > from + 1 }.map { $0.at }
        guard !starts.isEmpty else { return nil }
        // 取最接近 target 的边界;偏差太大(>一块时长)就不用,等下次 tick
        let best = starts.min { abs($0 - target) < abs($1 - target) }!
        return abs(best - target) <= autoRefiner.chunkSec ? best : nil
    }

    /// 攒够一点语音就让云端判一次语种,判完直接锁定。
    /// 比让三路识别器互相比可靠得多也快得多 ——
    /// 实测在很轻的音频上 en/zh 要在语音开始后 17 秒才吐第一个字,等不起。
    func probeLanguageIfNeeded() {
        guard capturing, !langProbeSent, st.cloudCorrect, !st.cloudKey.isEmpty else { return }
        guard sysRecog.localeIDs.count > 1, !sysRecog.isLocaleLocked else { return }
        guard let speechAt = sysRecog.speechStartedAt else { return }   // 还没听到语音就不问
        let have = tape.seconds - speechAt
        guard have >= 5 else { return }
        guard let wav = tape.slice(from: speechAt, to: min(tape.seconds, speechAt + 8)) else { return }
        langProbeSent = true
        alog("云端判语种:送 \(String(format: "%.1f", min(have, 8)))s 语音")
        cloud.detectLanguage(wav: wav) { [weak self] id in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let id else { alog("云端判语种失败,退回本地比较"); self.langProbeSent = false; return }
                self.sysRecog.lockLocale(id)
                if self.st.micOn { self.micRecog.lockLocale(id) }
            }
        }
    }

    func tapeReady() -> Bool {
        !lastWav.isEmpty && FileManager.default.fileExists(atPath: lastWav)
            && ((try? FileManager.default.attributesOfItem(atPath: lastWav)[.size] as? Int) ?? 0) > 44 + 32000
    }
    /// 慢通道:拿整段录音让 whisper 重跑一遍。实时字幕不受影响。
    @objc func refineNow() {
        guard !refining, tapeReady() else { NSSound.beep(); return }
        if capturing { tape.stop() }        // 先把 WAV 头回填,否则 whisper 读不了
        refining = true
        refineNote = L("Refining…", "精修中…")
        let lang = whisperLang
        Refiner.refine(wav: lastWav, lang: lang, progress: { [weak self] p in
            DispatchQueue.main.async { self?.refineNote = p }
        }, done: { [weak self] (r: RefineOutcome) in
            guard let self else { return }
            self.refining = false; self.refineNote = ""
            switch r {
            case .ok(let path):
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: (path as NSString).deletingLastPathComponent)
            case .fail(let e):
                // 错误进日志和菜单状态,不写进转录内容 —— 转录文件应该只有转录
                alog("refine failed: \(e)")
                self.refineNote = L("refine failed: ", "精修失败: ") + e
                NSSound.beep()
            }
        })
    }

    func newTranscript() {
        closeTranscript()
        let dir = st.archiveDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        transcriptPath = "\(dir)/meeting-\(f.string(from: Date())).txt"
        FileManager.default.createFile(atPath: transcriptPath, contents: nil)
        transcriptFH = FileHandle(forWritingAtPath: transcriptPath)
    }
    func closeTranscript() { try? transcriptFH?.close(); transcriptFH = nil }
    func fileAppend(_ s: String) {
        if transcriptFH == nil { newTranscript() }
        if let h = transcriptFH, let d = s.data(using: .utf8) { h.write(d) }
    }

    // MARK: 全局热键(⌥⌘A 开始/停止)

    func registerHotKey() {
        let id = EventHotKeyID(signature: OSType(0x41554443), id: 1)   // 'AUDC'
        var ref: EventHotKeyRef?
        let mods = UInt32(optionKey | cmdKey)
        if RegisterEventHotKey(UInt32(kVK_ANSI_A), mods, id, GetEventDispatcherTarget(), 0, &ref) == noErr {
            hotKeyRef = ref
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, _, ctx in
                if let ctx { Unmanaged<App>.fromOpaque(ctx).takeUnretainedValue().toggleCapture() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
            alog("hotkey ⌥⌘A registered")
        } else {
            alog("hotkey 注册失败(可能被别的 app 占了)")
        }
    }

    // MARK: 散会后整理(先问再做)

    /// 录音写完就排队;不在转写中才弹窗问。中途重开转写(分成两个文件)时不打断会议,
    /// 等最后停止时一起问 —— runModal 会占住主线程,转写中弹会卡住识别结果投递。
    /// 必须先问:会上传云端,而录音是不是私人对话只有用户知道,程序判断不了。
    var pendingPost: [(stem: String, sec: Double)] = []
    var permHintShown = false          // 本次启动是否已经提示过屏幕录制权限

    func postProcess(wav: String, seconds: Double) {
        guard st.autoPost, seconds >= 300 else { return }      // 短于 5 分钟多半是测试
        let stem = ((wav as NSString).lastPathComponent as NSString).deletingPathExtension
        pendingPost.append((stem, seconds))
        if !capturing { askPost() }
    }

    func askPost() {
        guard !pendingPost.isEmpty else { return }
        let items = pendingPost; pendingPost = []
        let a = NSAlert()
        a.messageText = L("Process this meeting recording?", "整理这次会议录音？")
        let list = items.map { "· \($0.stem)（\(Int($0.sec / 60)) \(L("min", "分钟"))）" }.joined(separator: "\n")
        a.informativeText = list + "\n\n" + L(
            "Uploads the audio to Gemini (OpenRouter) for a full transcript + speaker labels. Choose Skip for private conversations; the audio is kept and can be processed later.",
            "会把录音上传到 Gemini（OpenRouter）生成完整稿 + 分说话人。私人对话请选「不整理」，录音会保留，之后也能手动跑。")
        a.addButton(withTitle: L("Process", "整理"))
        a.addButton(withTitle: L("Skip", "不整理"))
        let del = NSButton(checkboxWithTitle: L("Delete audio after successful processing", "整理成功后删除录音"), target: nil, action: nil)
        del.state = st.autoPostDelete ? .on : .off
        a.accessoryView = del
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { alog("post: 用户选择不整理 \(items.map(\.stem))"); return }
        st.autoPostDelete = (del.state == .on)
        for it in items { launchPost(stem: it.stem, seconds: it.sec) }
    }

    /// 脚本在后台跑,Audicap 退出也不影响;跑完它自己发系统通知。
    func launchPost(stem: String, seconds: Double) {
        let script = st.postScript
        guard FileManager.default.isExecutableFile(atPath: script) else { alog("post: 找不到 \(script)"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script, stem, st.autoPostDelete ? "1" : "0"]
        // 记录目录可能被用户改到别处,脚本那边不知道 Settings,靠环境变量传过去
        p.environment = ProcessInfo.processInfo.environment.merging(["AUDICAP_DIR": st.archiveDir]) { _, new in new }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); alog("post: 已启动整理 \(stem) (\(Int(seconds))s)") }
        catch { alog("post: 启动失败 \(error)") }
    }

    // MARK: 退出

    @objc func quit() {
        sck.stop(); mic.stop(); sysRecog.stop(); micRecog.stop()
        closeTranscript()
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ n: Notification) {
        sck.stop(); mic.stop(); sysRecog.stop(); micRecog.stop(); closeTranscript()
    }
}

extension App: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { refreshStatusMenu(menu) }
}

/// 归一化后的字符相似度(0~1)。用来判断精修版和实时版是不是"其实一样",
/// 一样就没必要并列 —— 两版并列的价值在于对照差异,不在于把同一句话写两遍。
func textSimilarity(_ a: String, _ b: String) -> Double {
    func norm(_ s: String) -> [Character] {
        Array(s.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map { Character($0) })
    }
    let x = norm(a), y = norm(b)
    if x.isEmpty && y.isEmpty { return 1 }
    if x.isEmpty || y.isEmpty { return 0 }
    // 长文本上 O(n*m) 也够用(一块 30s ≈ 几百字符);超长时直接按长度比粗判,避免卡主线程
    if x.count * y.count > 400_000 {
        return Double(min(x.count, y.count)) / Double(max(x.count, y.count))
    }
    var prev = Array(0...y.count)
    var cur = [Int](repeating: 0, count: y.count + 1)
    for i in 1...x.count {
        cur[0] = i
        for j in 1...y.count {
            cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + (x[i-1] == y[j-1] ? 0 : 1))
        }
        swap(&prev, &cur)
    }
    return 1.0 - Double(prev[y.count]) / Double(max(x.count, y.count))
}

func stripTimestamps(_ s: String) -> String {
    s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        if let r = line.range(of: #"^\[\d{2}:\d{2}:\d{2}\]\s*"#, options: .regularExpression) {
            return String(line[r.upperBound...])
        }
        return String(line)
    }.joined(separator: "\n")
}
// ── 设置面板 ──────────────────────────────────────────────────────────────────
extension App {
    @objc func openSettings() {
        if let w = settingsWin { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let W: CGFloat = 420, H: CGFloat = 1370      // 内容总高。2026-10-01 实测旧值 1122 时日志报「到底剩 -228pt」(底部被截);改值后看 audicap.log 那行应 ≥0
        // 内容高 H 已经超过笔记本屏幕可用高度(1728×1117 屏约 1080pt),窗口直接开 H 会被截掉最上/最下几项。
        // 窗口高度按屏幕封顶,内容放进可滚动的 documentView(MeetingMind 的设置页也是这么解决的)。
        let winH = min(H, (NSScreen.main?.visibleFrame.height ?? H) - 40)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: winH),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = L("Audicap Settings", "Audicap 设置"); w.isReleasedWhenClosed = false; w.center()
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: W, height: winH))
        sv.hasVerticalScroller = true; sv.drawsBackground = false; sv.autoresizingMask = [.width, .height]
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        sv.documentView = v; w.contentView = sv
        var y = H - 40
        func header(_ t: String) {
            let l = NSTextField(labelWithString: t); l.font = .boldSystemFont(ofSize: 13); l.textColor = .secondaryLabelColor
            l.frame = NSRect(x: 20, y: y, width: W - 40, height: 18); v.addSubview(l)
            let line = NSBox(frame: NSRect(x: 20, y: y - 7, width: W - 40, height: 1)); line.boxType = .separator; v.addSubview(line); y -= 32
        }
        func lab(_ t: String) { let l = NSTextField(labelWithString: t); l.frame = NSRect(x: 24, y: y, width: 170, height: 20); v.addSubview(l) }
        func checkbox(_ t: String, _ on: Bool, _ sel: Selector) {
            let b = NSButton(checkboxWithTitle: t, target: self, action: sel)
            b.frame = NSRect(x: 24, y: y, width: W - 48, height: 22); b.state = on ? .on : .off; v.addSubview(b); y -= 30
        }
        func popup(_ t: String, _ items: [String], _ curIdx: Int, _ sel: Selector) {
            lab(t); let p = NSPopUpButton(frame: NSRect(x: 200, y: y - 3, width: 196, height: 26))
            p.addItems(withTitles: items); p.selectItem(at: min(max(0, curIdx), items.count - 1))
            p.target = self; p.action = sel; v.addSubview(p); y -= 36
        }
        func colorRow(_ t: String, _ hex: String, _ def: NSColor, _ sel: Selector) {
            lab(t); let c = NSColorWell(frame: NSRect(x: 200, y: y - 3, width: 56, height: 26))
            c.color = NSColor(hex: hex) ?? def; c.target = self; c.action = sel; v.addSubview(c); y -= 36
        }
        // 路径可能很长(尤其云盘目录),中间截断比截尾更看得出是哪个文件夹
        func pathRow(_ t: String, _ path: String, _ sel: Selector) -> NSTextField {
            lab(t)
            let l = NSTextField(labelWithString: (path as NSString).abbreviatingWithTildeInPath)
            l.lineBreakMode = .byTruncatingMiddle
            l.frame = NSRect(x: 200, y: y, width: 122, height: 20); v.addSubview(l)
            let b = NSButton(title: L("Choose…", "选择…"), target: self, action: sel)
            b.bezelStyle = .rounded; b.frame = NSRect(x: 328, y: y - 4, width: 68, height: 24)
            v.addSubview(b); y -= 36
            return l
        }
        @discardableResult
        func stepperRow(_ t: String, _ mn: Double, _ mx: Double, _ inc: Double, _ val: Int, _ sel: Selector) -> NSTextField {
            lab(t); let valL = NSTextField(labelWithString: "\(val)")
            valL.frame = NSRect(x: 200, y: y, width: 44, height: 20); valL.alignment = .right; v.addSubview(valL)
            let s = NSStepper(frame: NSRect(x: 252, y: y - 2, width: 20, height: 24))
            s.minValue = mn; s.maxValue = mx; s.increment = inc; s.integerValue = val
            s.target = self; s.action = sel; v.addSubview(s); y -= 36; return valL
        }

        header(L("Interface", "界面"))
        popup(L("Language", "界面语言"), ["中文", "English"], st.uiLang == "zh" ? 0 : 1, #selector(cUILang(_:)))
        checkbox(L("Start transcribing on launch", "启动即开始转写"), st.autoStart, #selector(cAutoStart(_:)))

        header(L("Meeting / Transcription", "会议 / 转写"))
        let recogIdx: Int = {
            let cur = ["ja": "ja-JP", "en": "en-US", "zh": "zh-CN"][st.recogLang] ?? st.recogLang
            return (Recognizer.selectable.firstIndex { $0.id == cur }).map { $0 + 1 } ?? 0
        }()
        popup(L("Recognize language", "识别语言"),
              [L("Auto (languages below)", "自动（下面勾选的语言）")] + Recognizer.selectable.map { L($0.en, $0.zh) },
              recogIdx, #selector(cRecog(_:)))
        // 自动模式的语种:下拉菜单里勾(窗口高度已到顶,放不下一排勾选框)
        lab(L("Auto: languages", "自动模式的语言"))
        let pd = NSPopUpButton(frame: NSRect(x: 200, y: y - 3, width: 196, height: 26), pullsDown: true)
        pd.menu?.autoenablesItems = false
        pd.addItem(withTitle: autoLocalesTitle())
        for (i, l) in Recognizer.selectable.enumerated() {
            let it = NSMenuItem(title: L(l.en, l.zh), action: #selector(cAutoLang(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = st.autoLocales.contains(l.id) ? .on : .off
            pd.menu?.addItem(it)
        }
        pd.toolTip = L("Up to \(Recognizer.maxLanes). Pick only what will be spoken — each extra language can steal results.",
                       "最多 \(Recognizer.maxLanes) 种。只勾会上会说的语言：多一种就多一个抢结果的对手。")
        autoLangPD = pd; v.addSubview(pd); y -= 36
        checkbox(L("Transcribe my voice (two-way · built-in mic)", "转写我说的话（双向会议 · 内置麦克风）"), st.micOn, #selector(cMic(_:)))
        checkbox(L("Low-latency mode", "低延迟模式"), st.fastMode, #selector(cFast(_:)))

        header(L("Captions", "字幕"))
        hideL = stepperRow(L("Auto-hide after (s, 0=never)", "讲完几秒后隐藏（0=常驻）"), 0, 60, 1, st.autoHideSec, #selector(cAutoHide(_:)))
        checkbox(L("Show draft while speaking", "说话过程中显示草稿"), st.showDraft, #selector(cShowDraft(_:)))
        colorRow(L("Draft color", "草稿颜色"), st.draftColorHex, .lightGray, #selector(cDraftColor(_:)))

        header(L("Transcript", "记录"))
        archiveDirL = pathRow(L("Save recordings to", "记录存放位置"), st.archiveDir, #selector(cArchiveDir(_:)))
        checkbox(L("Copy on selection (like a terminal)", "选中即复制（像终端一样，无需 ⌘C）"), st.selectToCopy, #selector(cSelCopy(_:)))
        checkbox(L("Keep audio (needed for correction & refinement)", "保留录音（云端纠错和精修都要用）"), st.keepTape, #selector(cKeepTape(_:)))
        checkbox(L("After meeting: ask to make full transcript + speakers (≥5 min)", "散会后询问是否整理：完整稿+分说话人（≥5 分钟）"), st.autoPost, #selector(cAutoPost(_:)))
        checkbox(L("Delete audio after successful processing", "整理成功后删除录音"), st.autoPostDelete, #selector(cAutoPostDelete(_:)))
        // whisper 那条慢通道已被云端音频纠错全面超越(快 5 倍、便宜 45 倍、还修出它修不了的词),
        // 模型也删了。不可用时不显示开关 —— 免得开了却没反应。
        if Refiner.available {
            checkbox(L("Auto-refine with local whisper (~1.5GB RAM)", "本地 whisper 自动精修（约 1.5GB 内存）"), st.autoRefine, #selector(cAutoRefine(_:)))
        }

        header(L("Cloud correction", "云端纠错"))
        checkbox(L("Enable — sends meeting AUDIO to the cloud", "启用 —— 会把会议**音频**发到云端"),
                 st.cloudCorrect, #selector(cCloud(_:)))
        do {
            lab(L("OpenRouter key", "OpenRouter key"))
            let f = NSSecureTextField(frame: NSRect(x: 200, y: y - 3, width: 196, height: 24))
            f.stringValue = st.cloudKey; f.target = self; f.action = #selector(cCloudKey(_:))
            f.placeholderString = "sk-or-v1-…"
            v.addSubview(f); y -= 34
        }
        popup(L("Mode", "方式"),
              [L("Re-transcribe (better)", "让模型重新转写（更准）"), L("Fix only (conservative)", "只做逐字纠错（保守）")],
              st.cloudMode == "rewrite" ? 0 : 1, #selector(cCloudMode(_:)))
        popup(L("Model", "模型"),
              ["google/gemini-2.5-flash-lite", "google/gemini-3.1-flash-lite", "google/gemini-2.5-flash"],
              max(0, ["google/gemini-2.5-flash-lite","google/gemini-3.1-flash-lite","google/gemini-2.5-flash"].firstIndex(of: st.cloudModel) ?? 0),
              #selector(cCloudModel(_:)))

        header(L("Translation", "翻译"))
        popup(L("Translate to", "翻译成"), [L("Off", "关闭"), "English", L("Chinese", "中文")],
              ["off": 0, "en": 1, "zh": 2][st.translate] ?? 0, #selector(cTranslate(_:)))
        transSizeL = stepperRow(L("Translation size", "译文字号"), 12, 70, 1, Int(st.transSize), #selector(cTransSize(_:)))
        colorRow(L("Translation color", "译文颜色"), st.transColorHex, .white, #selector(cTransColor(_:)))

        header(L("Caption style", "字幕样式"))
        sizeL = stepperRow(L("Size", "字号"), 14, 80, 1, Int(st.fontSize), #selector(cSize(_:)))
        let fonts = ["PingFang SC", "Hiragino Sans", "Helvetica Neue", "Avenir Next", "Menlo", "Songti SC"]
        popup(L("Font", "字体"), fonts, max(0, fonts.firstIndex(of: st.fontName) ?? 0), #selector(cFont(_:)))
        checkbox(L("Bold", "加粗"), st.bold, #selector(cBold(_:)))
        colorRow(L("Text color", "文字颜色"), st.colorHex, .white, #selector(cColor(_:)))
        popup(L("Edge effect", "描边效果"), [L("None", "无"), L("Outline", "描边"), L("Glow", "光晕")],
              ["none": 0, "outline": 1, "glow": 2][st.effect] ?? 1, #selector(cEffect(_:)))
        colorRow(L("Edge / Glow color", "描边 / 光晕颜色"), st.effectColorHex, .black, #selector(cEColor(_:)))

        header(L("Background / Layout", "背景 / 布局"))
        colorRow(L("Background color", "背景颜色"), st.bgColorHex, .black, #selector(cBgColor(_:)))
        bgOpL = stepperRow(L("Background opacity %", "背景不透明度 %"), 0, 100, 5, Int(st.bgOpacity * 100), #selector(cBgOpacity(_:)))
        linesL = stepperRow(L("Max lines", "最多显示行数"), 1, 8, 1, st.lines, #selector(cLines(_:)))
        spL = stepperRow(L("Line spacing", "行间距"), 0, 28, 1, Int(st.lineSpacing), #selector(cSpacing(_:)))

        alog("settings 布局到底剩 \(Int(y))pt(<0 = 最下面被截掉)")
        // documentView 不是 flipped,原点在底部 → 滚到 H-winH 才是从最上面开始看
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, H - winH))); sv.reflectScrolledClipView(sv.contentView)
        settingsWin = w; w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc func cSize(_ s: NSStepper) { st.fontSize = CGFloat(s.integerValue); sizeL?.stringValue = "\(s.integerValue)"; refresh() }
    @objc func cFont(_ p: NSPopUpButton) { st.fontName = p.titleOfSelectedItem ?? "PingFang SC"; refresh() }
    @objc func cBold(_ b: NSButton) { st.bold = (b.state == .on); refresh() }
    @objc func cColor(_ c: NSColorWell) { st.colorHex = c.color.hex; refresh() }
    @objc func cEffect(_ p: NSPopUpButton) { st.effect = ["none", "outline", "glow"][max(0, p.indexOfSelectedItem)]; refresh() }
    @objc func cEColor(_ c: NSColorWell) { st.effectColorHex = c.color.hex; refresh() }
    @objc func cLines(_ s: NSStepper) { st.lines = s.integerValue; linesL?.stringValue = "\(s.integerValue)"; render(); relayout() }
    @objc func cSpacing(_ s: NSStepper) { st.lineSpacing = CGFloat(s.integerValue); spL?.stringValue = "\(s.integerValue)"; refresh() }
    @objc func cBgColor(_ c: NSColorWell) { st.bgColorHex = c.color.hex; view.needsDisplay = true }
    @objc func cBgOpacity(_ s: NSStepper) { st.bgOpacity = CGFloat(s.integerValue) / 100.0; bgOpL?.stringValue = "\(s.integerValue)"; view.needsDisplay = true }
    @objc func cTransSize(_ s: NSStepper) { st.transSize = CGFloat(s.integerValue); transSizeL?.stringValue = "\(s.integerValue)"; refresh() }
    @objc func cTransColor(_ c: NSColorWell) { st.transColorHex = c.color.hex; refresh() }
    @objc func cDraftColor(_ c: NSColorWell) { st.draftColorHex = c.color.hex; refresh() }
    @objc func cAutoHide(_ s: NSStepper) { st.autoHideSec = s.integerValue; hideL?.stringValue = "\(s.integerValue)"; scheduleHide() }
    @objc func cShowDraft(_ b: NSButton) { st.showDraft = (b.state == .on); if !st.showDraft { draft = nil; refresh() } }
    @objc func cSelCopy(_ b: NSButton) { st.selectToCopy = (b.state == .on) }
    @objc func cAutoRefine(_ b: NSButton) {
        st.autoRefine = (b.state == .on)
        guard capturing else { return }
        if st.autoRefine {
            if !tape.isRunning { tape.start(path: lastWav) }
            autoRefiner.start(tape: tape, lang: whisperLang)
            refineTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                self?.autoRefiner.tick(alignTo: self?.refineBoundary())
            }
        } else {
            refineTimer?.invalidate(); refineTimer = nil; autoRefiner.stop()
        }
    }
    @objc func cCloud(_ b: NSButton) {
        st.cloudCorrect = (b.state == .on)
        guard capturing else { return }
        if st.cloudCorrect && !st.cloudKey.isEmpty {
            if !tape.isRunning { tape.start(path: lastWav) }
            cloud.mode = CloudMode(rawValue: st.cloudMode) ?? .rewrite
            cloud.localeHint = Recognizer.localeIDs(for: st.recogLang).first ?? ""
            cloud.start(tape: tape, key: st.cloudKey, model: st.cloudModel)
            // 中途启用也要建兜底定时器 —— 原来只在 startCapture 里建,
            // 会议中途打开这个开关的话,停话后的短 pending 永远不会被 flush(评审指出)
            refineTimer?.invalidate()
            refineTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.cloud.tickIdle(now: self.tape.seconds)
            }
        } else {
            cloud.stop()
            refineTimer?.invalidate(); refineTimer = nil
        }
    }
    @objc func cCloudKey(_ f: NSSecureTextField) { st.cloudKey = f.stringValue.trimmingCharacters(in: .whitespaces) }
    @objc func cCloudMode(_ p: NSPopUpButton) {
        st.cloudMode = p.indexOfSelectedItem == 0 ? "rewrite" : "fix"
        cloud.mode = CloudMode(rawValue: st.cloudMode) ?? .rewrite
    }
    @objc func cCloudModel(_ p: NSPopUpButton) { st.cloudModel = p.titleOfSelectedItem ?? "google/gemini-2.5-flash-lite" }
    @objc func cAutoPost(_ b: NSButton) { st.autoPost = (b.state == .on) }
    @objc func cAutoPostDelete(_ b: NSButton) { st.autoPostDelete = (b.state == .on) }
    /// 换记录存放目录:只影响新开的转写(当前正在写的文件不挪),下次开会才生效
    @objc func cArchiveDir(_ sender: NSButton) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.allowsMultipleSelection = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: st.archiveDir, isDirectory: true)
        p.begin { [weak self] r in
            guard let self, r == .OK, let url = p.url else { return }
            self.st.archiveDir = url.path
            self.archiveDirL?.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
    @objc func cKeepTape(_ b: NSButton) {
        st.keepTape = (b.state == .on)
        if capturing { st.keepTape ? tape.start(path: lastWav) : tape.stop() }
    }
    @objc func cFast(_ b: NSButton) { st.fastMode = (b.state == .on); restartRecognizers() }
    @objc func cAutoStart(_ b: NSButton) { st.autoStart = (b.state == .on) }

    @objc func cTranslate(_ p: NSPopUpButton) {
        st.translate = ["off", "en", "zh"][max(0, p.indexOfSelectedItem)]
        translator.setTarget(st.translate)
        if st.translate == "off" { for i in caps.indices { caps[i].trans = "" }; render(); relayout() }
    }
    /// 换识别语种。不再需要重启子进程 —— 直接换 Recognizer 的 locale 通道,采集不中断。
    @objc func cRecog(_ p: NSPopUpButton) {
        let i = p.indexOfSelectedItem
        st.recogLang = i <= 0 ? "auto" : Recognizer.selectable[i - 1].id
        restartRecognizers()
    }
    func autoLocalesTitle() -> String {
        Recognizer.selectable.filter { st.autoLocales.contains($0.id) }.map { L($0.en, $0.zh) }.joined(separator: " + ")
    }
    @objc func cAutoLang(_ it: NSMenuItem) {
        let id = Recognizer.selectable[it.tag].id
        var cur = st.autoLocales
        if let k = cur.firstIndex(of: id) {
            guard cur.count > 1 else { NSSound.beep(); return }          // 至少留一种
            cur.remove(at: k)
        } else {
            guard cur.count < Recognizer.maxLanes else { NSSound.beep(); return }   // 系统上限 5
            cur.append(id)
        }
        // 按列表顺序存,标题和并行顺序稳定
        st.autoLocales = Recognizer.selectable.map(\.id).filter { cur.contains($0) }
        Recognizer.autoLocales = st.autoLocales
        it.state = st.autoLocales.contains(id) ? .on : .off
        autoLangPD?.item(at: 0)?.title = autoLocalesTitle()
        if st.recogLang == "auto" { restartRecognizers() }
    }
    /// 已弃用的 whisper 精修只认 auto / 两字母语言码
    var whisperLang: String {
        st.recogLang == "auto" ? "auto" : String(st.recogLang.prefix { $0 != "-" })
    }
    func restartRecognizers() {
        guard capturing else { return }
        // 续上录音的时间轴,不能从 0 重来 —— 否则新结果的 range 会比真实位置早几百秒,
        // 云端按它切音频就切到会议开头去了(评审指出)
        let off = tape.seconds
        sysRecog.stop(); sysRecog.start(setting: st.recogLang, fast: st.fastMode, startOffset: off)
        if st.micOn { micRecog.stop(); micRecog.start(setting: st.recogLang, fast: st.fastMode, startOffset: off) }
    }
    @objc func cMic(_ b: NSButton) {
        st.micOn = (b.state == .on)
        guard capturing else { return }
        if st.micOn { mic.start(); micRecog.start(setting: st.recogLang, fast: st.fastMode) }
        else { mic.stop(); micRecog.stop() }
    }
    @objc func cUILang(_ p: NSPopUpButton) {
        st.uiLang = p.indexOfSelectedItem == 0 ? "zh" : "en"; UILANG = st.uiLang
        view.relocalizeBar()
        buildMainMenu()
        panel.title = L("Audicap — Transcript", "Audicap — 记录")
        let old = settingsWin; settingsWin = nil; old?.close()
        DispatchQueue.main.async { self.openSettings() }
    }
    func refresh() { render(); relayout() }
}
