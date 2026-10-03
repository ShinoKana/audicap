// Apple SpeechAnalyzer/SpeechTranscriber 评测探针(macOS 26)。
//
// 为什么要这个:在把 Audicap 的识别层从 whisper.cpp 换成系统自带这套之前,
// 得先量清楚四件事——准确率、延迟、内存、以及多语种/中英夹杂怎么处理。
// 光看"能出字"不够,要能跟 whisper 在同一批素材上对比。
//
// 用法:
//   speechprobe locales
//   speechprobe run <locale[,locale...]> <file.wav> [--realtime] [--fast] [--conf] [--quiet]
//     --realtime  按音频真实时长节流喂入(测真实流式延迟,不加就是尽可能快喂)
//     --fast      开 .fastResults
//     --conf      输出每条结果的平均置信度(多 locale 并行时用来选优)
//     --quiet     只打印 FINAL 和汇总
import Foundation
import Speech
import AVFoundation
import CoreMedia
import Darwin

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

/// 当前进程常驻内存(MB)。用 mach task info,比 shell 里 ps 采样准。
func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1024 / 1024 : -1
}

func listLocales() async {
    let sup = await SpeechTranscriber.supportedLocales
    let ins = await SpeechTranscriber.installedLocales
    print("supportedLocales (\(sup.count)): " + sup.map { $0.identifier(.bcp47) }.sorted().joined(separator: " "))
    print("installedLocales (\(ins.count)): " + ins.map { $0.identifier(.bcp47) }.sorted().joined(separator: " "))
}

func ensureAssets(_ mods: [any SpeechModule], _ tag: String) async {
    let st = await AssetInventory.status(forModules: mods)
    if st != .installed {
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: mods) {
                FileHandle.standardError.write("[\(tag)] 下载语言包…\n".data(using: .utf8)!)
                try await req.downloadAndInstall()
            }
        } catch { print("[\(tag)] asset 安装失败: \(error)") }
    }
}

/// 一条 locale 的识别通道。多条并行跑同一份音频,最后按置信度比。
final class Lane: @unchecked Sendable {
    let id: String
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let cont: AsyncStream<AnalyzerInput>.Continuation
    let stream: AsyncStream<AnalyzerInput>
    var finals: [(t: Double, text: String, conf: Double)] = []
    var firstDraftAt: Double?
    var draftPrints = 0
    var firstFinalAt: Double?
    let lock = NSLock()

    let usedInitContext: Bool
    init(locale: Locale, fast: Bool, conf: Bool, context: AnalysisContext? = nil) {
        id = locale.identifier(.bcp47)
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fast { reporting.insert(.fastResults) }
        var attrs: Set<SpeechTranscriber.ResultAttributeOption> = []
        if conf { attrs.insert(.transcriptionConfidence) }
        transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                        reportingOptions: reporting, attributeOptions: attrs)
        let (s, c) = AsyncStream<AnalyzerInput>.makeStream()
        stream = s; cont = c
        // ★ context 必须在 init 时传:setContext 在 start 之后调没有任何效果(实测)
        if let ctx = context {
            analyzer = SpeechAnalyzer(inputSequence: s, modules: [transcriber], analysisContext: ctx)
            usedInitContext = true
        } else {
            analyzer = SpeechAnalyzer(modules: [transcriber])
            usedInitContext = false
        }
    }

    /// AttributedString 各 run 的置信度平均值;没开 --conf 时返回 -1。
    static func meanConfidence(_ a: AttributedString) -> Double {
        var sum = 0.0, n = 0
        for run in a.runs {
            if let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] {
                sum += c; n += 1
            }
        }
        return n == 0 ? -1 : sum / Double(n)
    }
}

/// --plain:只打印最终文本一行(多 locale 时打印置信度最高那路)。给评测脚本用,免得
/// 从人类可读输出里正则抠字符串——之前那样抠会把汇总行和 160 字预览也当成识别结果,
/// 算出来的 CER 是假的。
func runFile(localeIDs: [String], path: String, realtime: Bool, fast: Bool, conf: Bool, quiet: Bool, plain: Bool = false, ctxFile: String? = nil) async {
    var ctx0: AnalysisContext? = nil
    if let f = ctxFile, let raw = try? String(contentsOfFile: f, encoding: .utf8) {
        let terms = raw.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
                       .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let c = AnalysisContext(); c.contextualStrings = [.general: terms]; ctx0 = c
        FileHandle.standardError.write("ctx: \(terms.count) 词\n".data(using: .utf8)!)
    }
    var lanes: [Lane] = []
    for lid in localeIDs {
        guard let sel = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: lid)) else {
            print("locale \(lid) 不支持,跳过"); continue
        }
        lanes.append(Lane(locale: sel, fast: fast, conf: conf, context: ctx0))
    }
    if lanes.isEmpty { die("没有可用 locale") }
    await ensureAssets(lanes.map { $0.transcriber }, localeIDs.joined(separator: ","))

    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { die("读不了 \(path)") }
    let srcFmt = file.processingFormat
    let audioSec = Double(file.length) / srcFmt.sampleRate
    guard let bestFmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [lanes[0].transcriber]) else {
        die("拿不到 bestAvailableAudioFormat")
    }

    // 回读一次,确认 context 真的进到 analyzer 里了(区分"API 无效"和"我接错了")
    if ctxFile != nil {
        for lane in lanes {
            let c = await lane.analyzer.context
            let n = c.contextualStrings[.general]?.count ?? -1
            let sample = c.contextualStrings[.general]?.prefix(3).joined(separator: ",") ?? "-"
            FileHandle.standardError.write("[\(lane.id)] analyzer.context 回读: \(n) 词  样例=\(sample)\n".data(using: .utf8)!)
        }
    }

    let rss0 = rssMB()
    let t0 = Date()

    var collectors: [Task<Void, Never>] = []
    for lane in lanes {
        collectors.append(Task {
            do {
                for try await r in lane.transcriber.results {
                    let dt = Date().timeIntervalSince(t0)
                    let txt = String(r.text.characters)
                    if txt.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                    lane.lock.lock()
                    if r.isFinal {
                        if lane.firstFinalAt == nil { lane.firstFinalAt = dt }
                        lane.finals.append((dt, txt, Lane.meanConfidence(r.text)))
                        if !plain && (!quiet || lanes.count == 1) {
                            let c = Lane.meanConfidence(r.text)
                            print(String(format: "  [%@ wall=%5.2fs audio=%6.2f–%6.2fs]%@ %@", lane.id, dt,
                                         r.range.start.seconds, r.range.end.seconds,
                                         c >= 0 ? String(format: " conf=%.2f", c) : "", txt))
                        }
                    } else {
                        if lane.firstDraftAt == nil { lane.firstDraftAt = dt }
                        if !plain && lane.draftPrints < 12 {
                            lane.draftPrints += 1
                            print(String(format: "  [%@ wall=%5.2fs audio=%6.2f–%6.2fs] draft  %@",
                                         lane.id, dt, r.range.start.seconds, r.range.end.seconds,
                                         txt.suffix(40).description))
                        }
                    }
                    lane.lock.unlock()
                }
            } catch { print("[\(lane.id)] results err: \(error)") }
        })
    }

    for lane in lanes where !lane.usedInitContext {
        do { try await lane.analyzer.start(inputSequence: lane.stream) }
        catch { die("[\(lane.id)] start 失败: \(error)") }
    }

    // 喂音频。realtime 时按块时长节流,模拟真实说话速度。
    let conv = (srcFmt != bestFmt) ? AVAudioConverter(from: srcFmt, to: bestFmt) : nil
    let chunkSec = 0.2
    let chunk = AVAudioFrameCount(srcFmt.sampleRate * chunkSec)
    var t = CMTime.zero
    var peakRSS = rss0
    let feedStart = Date()
    var fed = 0.0
    while true {
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: chunk) else { break }
        do { try file.read(into: inBuf, frameCount: chunk) } catch { break }
        if inBuf.frameLength == 0 { break }
        var out = inBuf
        if let conv = conv {
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * bestFmt.sampleRate / srcFmt.sampleRate) + 128
            guard let ob = AVAudioPCMBuffer(pcmFormat: bestFmt, frameCapacity: cap) else { break }
            var done = false; var err: NSError?
            conv.convert(to: ob, error: &err) { _, st in
                if done { st.pointee = .noDataNow; return nil }
                done = true; st.pointee = .haveData; return inBuf
            }
            if err != nil { break }
            out = ob
        }
        for lane in lanes { lane.cont.yield(AnalyzerInput(buffer: out, bufferStartTime: t)) }
        let dur = Double(out.frameLength) / bestFmt.sampleRate
        t = CMTimeAdd(t, CMTime(seconds: dur, preferredTimescale: 48000))
        fed += dur
        peakRSS = max(peakRSS, rssMB())
        if realtime {
            let should = fed - Date().timeIntervalSince(feedStart)
            if should > 0 { try? await Task.sleep(nanoseconds: UInt64(should * 1e9)) }
        }
    }
    for lane in lanes { lane.cont.finish() }
    for lane in lanes {
        do { try await lane.analyzer.finalizeAndFinishThroughEndOfInput() }
        catch { print("[\(lane.id)] finalize err: \(error)") }
    }
    for c in collectors { _ = await c.result }
    peakRSS = max(peakRSS, rssMB())

    let wall = Date().timeIntervalSince(t0)
    if plain {
        // 选平均置信度最高的一路,把它的 final 按时间顺序拼出来
        var best: Lane? = nil; var bs = -2.0
        for lane in lanes {
            let cs = lane.finals.map { $0.conf }.filter { $0 >= 0 }
            let m = cs.isEmpty ? -1 : cs.reduce(0,+) / Double(cs.count)
            if m > bs { bs = m; best = lane }
        }
        if let b = best { print(b.finals.map { $0.text }.joined()) }
        return
    }
    print("---")
    for lane in lanes {
        let text = lane.finals.map { $0.text }.joined()
        let confs = lane.finals.map { $0.conf }.filter { $0 >= 0 }
        let mc = confs.isEmpty ? -1 : confs.reduce(0,+) / Double(confs.count)
        print(String(format: "[%@] finals=%d chars=%d%@ firstDraft=%@ firstFinal=%@",
                     lane.id, lane.finals.count, text.count,
                     mc >= 0 ? String(format: " meanConf=%.3f", mc) : "",
                     lane.firstDraftAt.map { String(format: "%.2fs", $0) } ?? "-",
                     lane.firstFinalAt.map { String(format: "%.2fs", $0) } ?? "-"))
        if quiet && lanes.count > 1 { print("     " + text.prefix(160)) }
    }
    print(String(format: "audio=%.1fs wall=%.2fs speed=%.1fx  RSS: start=%.0fMB peak=%.0fMB (+%.0fMB) lanes=%d",
                 audioSec, wall, audioSec / max(wall, 0.001), rss0, peakRSS, peakRSS - rss0, lanes.count))
}

@main
struct Probe {
    static func main() async {
        let a = CommandLine.arguments
        if a.count >= 2 && a[1] == "locales" { await listLocales(); return }
        // 语言包名额:每个程序最多同时占 5 个(AssetInventory.maximumReservedLocales),
        // 而且跨次运行一直记着 —— 测过 5 种之后再测别的会报 "Too many allocated locales"。
        if a.count >= 2 && a[1] == "release" {
            for l in await AssetInventory.reservedLocales {
                let ok = await AssetInventory.release(reservedLocale: l)
                print("release \(l.identifier(.bcp47)): \(ok)")
            }
            return
        }
        guard a.count >= 4, a[1] == "run" else {
            print("用法: speechprobe locales | speechprobe release | speechprobe run <locale[,locale...]> <file.wav> [--realtime] [--fast] [--conf] [--quiet]")
            return
        }
        await runFile(localeIDs: a[2].split(separator: ",").map(String.init),
                      path: a[3],
                      realtime: a.contains("--realtime"),
                      fast: a.contains("--fast"),
                      conf: a.contains("--conf"),
                      quiet: a.contains("--quiet"),
                      plain: a.contains("--plain"),
                      ctxFile: a.firstIndex(of: "--ctx").flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil })
    }
}
