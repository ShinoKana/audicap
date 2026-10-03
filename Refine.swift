// 两遍解码的「慢通道」。
//
// 实时字幕(Apple SpeechAnalyzer)胜在低延迟、断句和标点,但它和任何流式识别一样,
// 只能看到当前这一小段音频。2026-09-08 实测:同一段真实录音,whisper 拿到**整段上下文**
// 离线跑时能出对专业术语和同音词,而两边在流式条件下都会错。
// 所以这里把会议音频原样留档,散会后用 whisper 整段重跑一遍,产出一份"精修稿"。
//
// 分工:快通道负责当场看,慢通道负责事后引用。互不干扰 —— whisper 只在你按下精修时才加载,
// 开会全程不占那 1.5GB。
import Foundation
import AVFoundation

/// 把识别用的音频同时留一份 16k 单声道 WAV。32KB/s,两小时会议约 230MB。
final class TapeRecorder {
    private var fh: FileHandle?
    private(set) var path = ""
    private var bytes = 0
    private var converter: AVAudioConverter?
    private var srcFormat: AVAudioFormat?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                          channels: 1, interleaved: true)!
    private let lock = Lock()

    func start(path p: String) {
        stop()
        path = p
        FileManager.default.createFile(atPath: p, contents: nil)
        fh = FileHandle(forWritingAtPath: p)
        fh?.write(Self.riffHeader(dataBytes: 0))   // 一开始就是合法头,之后边写边回填长度
        bytes = 0; headerAt = 0
    }

    func write(_ buf: AVAudioPCMBuffer) {
        guard fh != nil else { return }
        var out = buf
        if buf.format != outFormat {
            if converter == nil || srcFormat != buf.format {
                converter = AVAudioConverter(from: buf.format, to: outFormat)
                srcFormat = buf.format
            }
            guard let conv = converter else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * outFormat.sampleRate / buf.format.sampleRate) + 256
            guard let ob = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return }
            var done = false; var err: NSError?
            conv.convert(to: ob, error: &err) { _, st in
                if done { st.pointee = .noDataNow; return nil }
                done = true; st.pointee = .haveData; return buf
            }
            if err != nil || ob.frameLength == 0 { return }
            out = ob
        }
        guard let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength) * 2
        let d = Data(bytes: ch[0], count: n)
        let needHeader: Bool = lock.withLock {
            fh?.write(d); bytes += n
            // 每约 5 秒回填一次头。只在 stop() 回填的话,app 崩溃/强退 → 头是 44 字节全零,
            // 整段录音直接作废(2026-09-08 实测踩到)。
            if bytes - headerAt >= 160_000 { headerAt = bytes; return true }
            return false
        }
        if needHeader { patchHeader() }
    }

    private var headerAt = 0
    /// 就地回填 RIFF 头(不关文件),让文件在任何时刻都是可解码的。
    private func patchHeader() {
        lock.withLock {
            guard let h = fh else { return }
            let cur = h.offsetInFile
            try? h.seek(toOffset: 0)
            h.write(Self.riffHeader(dataBytes: bytes))
            try? h.seek(toOffset: cur)
        }
    }
    static func riffHeader(dataBytes: Int) -> Data {
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); le32(UInt32(36 + dataBytes))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); le32(16); le16(1); le16(1)
        le32(16000); le32(32000); le16(2); le16(16)
        d.append("data".data(using: .ascii)!); le32(UInt32(dataBytes))
        return d
    }

    /// 回填 RIFF 头。不回填的话文件是坏的,whisper/ffmpeg 都读不了。
    /// 一段录音写完(不管是停止转写、中途重开还是关掉留档)都会回调:(路径, 秒数)。主线程。
    var onFinished: ((String, Double) -> Void)?

    func stop() {
        guard let h = fh else { return }
        try? h.seek(toOffset: 0); h.write(Self.riffHeader(dataBytes: bytes)); try? h.close()
        fh = nil
        alog("tape 写完: \(path) (\(bytes / 32000)s)")
        let p = path, sec = seconds
        DispatchQueue.main.async { [weak self] in self?.onFinished?(p, sec) }
    }

    var seconds: Double { Double(bytes) / 32000.0 }
    var isRunning: Bool { fh != nil }

    /// 取 [from, to] 秒的音频,拼成一个独立可解码的 WAV。给滚动精修按块取料用。
    /// 直接读文件(不是内存缓冲),所以任意历史区间都能回取。
    func slice(from: Double, to: Double) -> Data? {
        let a = max(0, Int(from * 32000)) & ~1        // 对齐到 int16 边界
        let b = min(bytes, Int(to * 32000)) & ~1
        guard b > a else { return nil }
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(44 + a))
        guard let pcm = try? h.read(upToCount: b - a), !pcm.isEmpty else { return nil }
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); le32(UInt32(36 + pcm.count))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); le32(16); le16(1); le16(1)
        le32(16000); le32(32000); le16(2); le16(16)
        d.append("data".data(using: .ascii)!); le32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}

/// 滚动慢通道(自动精修)。
///
/// 实时字幕的通行结构就是两条通道:快通道低延迟先出、边说边改;慢通道滞后一截,
/// 用更大的窗口和完整上下文重跑,再覆盖掉前面的结果。这里的慢通道 = whisper。
///
/// 为什么按块而不是逐句:whisper 的优势恰恰来自长上下文,逐句喂等于把它降级成流式,
/// 之前实测过那样它会退化成「自社時勢」「エンターン」。所以攒够 chunkSec 再送,
/// 并向前多取 overlapSec 作为上文,避免块边界处又出现切断词。
///
/// 代价说清楚:开着它就要常驻 whisper-server(约 1.5GB 内存)。CPU 占用不高——
/// whisper 对 30s 块约 2s 算完,占空比 ~7%。
final class AutoRefiner {
    /// 一块精修完成:用 text 覆盖 [from, to] 这段时间窗的实时文本。
    var onRefined: ((_ from: Double, _ to: Double, _ text: String) -> Void)?
    var onStatus: ((String) -> Void)?

    let chunkSec: Double
    let overlapSec: Double
    private let port = 8917                 // 跟手动精修/别人用的 8910 岔开,避免抢端口
    private var server: Process?
    private(set) var nextStart = 0.0
    private var busy = false
    private var pendingStop = false          // 停止时若还在解最后一块,等它完再关 server
    private var lang = "auto"
    private weak var tape: TapeRecorder?
    private var stopped = true

    init(chunkSec: Double = 30, overlapSec: Double = 4) {
        self.chunkSec = chunkSec; self.overlapSec = overlapSec
    }

    var isReady: Bool { server != nil }

    func start(tape t: TapeRecorder, lang l: String) {
        guard Refiner.available else { onStatus?("whisper 不可用,自动精修跳过"); return }
        stopped = false; tape = t; lang = l; nextStart = 0; busy = false
        guard server == nil else { return }
        reapStrays()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Refiner.server)
        p.arguments = ["-m", Refiner.model, "--host", "127.0.0.1", "--port", "\(port)", "-t", "4", "-sns"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); server = p; alog("autorefine: whisper-server 起了 (port \(port))") }
        catch { onStatus?("whisper-server 起不来: \(error.localizedDescription)"); return }
        onStatus?("自动精修:加载模型中…")
    }

    func stop() {
        stopped = true
        if busy { pendingStop = true; alog("autorefine: 等最后一块解完再关"); return }
        killServer()
    }
    /// 收掉上次留下的 whisper-server。
    ///
    /// stop() 会 terminate,但 app 被强退或崩溃时它根本没机会跑 —— 子进程被托孤给
    /// launchd,带着约 1.6GB 的模型常驻下去。更阴的是 whisper-server 开了 SO_REUSEPORT,
    /// 同一端口能被多个进程同时 LISTEN,所以重复启动不会报「端口已占用」,只会静默叠加:
    /// 崩一次多一个。实测在一台机器上堆到 5 个、合计 8.4GB、挂了 25 天,
    /// 每个累计 CPU 仅约 1 分钟(纯加载模型),一次转写都没做过,把 16GB 的机器压进了 swap。
    ///
    /// 所以每次 start() 之前先收一遍尸,启动即自愈 —— 不指望上一次能干净退出。
    private func reapStrays() {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // 按「可执行名 + 本实例的端口」匹配,不会碰到别人跑在 8910 等其他端口上的 server。
        pgrep.arguments = ["-f", "whisper-server .*--port \(port)( |$)"]
        let out = Pipe()
        pgrep.standardOutput = out
        pgrep.standardError = FileHandle.nullDevice
        guard (try? pgrep.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        pgrep.waitUntilExit()
        let me = ProcessInfo.processInfo.processIdentifier
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid != me else { continue }
            kill(pid, SIGTERM)
            alog("autorefine: 收掉上次残留的 whisper-server (pid \(pid))")
        }
    }

    private func killServer() {
        pendingStop = false
        server?.terminate(); server = nil
        alog("autorefine: server 已停")
    }

    /// 主循环定期调用。够一块就送去精修;结束时 flush 尾巴。
    ///
    /// alignTo:快通道最近一句的**开始**时间。块尾切在这里,边界就落在句子之间,
    /// 而不是拦腰切在句中 —— 否则两版对照时比的根本不是同一段内容,
    /// 相似度会被边界错位人为拉低(实测把本来只差几个词的段算成 31% 相似)。
    func tick(final: Bool = false, alignTo: Double? = nil) {
        guard !stopped || final, !busy, let tape, server != nil else { return }
        let avail = tape.seconds
        let need = final ? 1.0 : chunkSec
        guard avail - nextStart >= need else { return }
        let from = nextStart
        var to = final ? avail : nextStart + chunkSec
        // alignTo 由上层挑好:离目标切点最近的一个句子边界。
        // 早期条件写成 a > from + chunkSec*0.5,但快通道的分段有 10~16 秒长,
        // 这个条件经常不成立 → 退回固定 30s 切,切在句子中间,
        // 于是 whisper 块的内容跨过了边界,那条实时行又没被替换,同一段话出现两遍。
        if !final, let a = alignTo, a > from + 1, a <= avail { to = a }
        let ctxFrom = max(0, from - overlapSec)
        guard let wav = tape.slice(from: ctxFrom, to: to) else { return }
        let dropBefore = from - ctxFrom          // 前面这段是喂给 whisper 的上文,不能进结果
        busy = true
        decode(wav) { [weak self] segs in
            guard let self else { return }
            self.busy = false
            self.nextStart = to
            // 裁掉喂进去当上文的那 overlapSec 秒。
            // ★必须按**词**裁,不能按段:whisper 的段是句子级的,一个段常从上文区跨到正文区
            //   (实测块1结尾和块2开头出现同一句话),按段过滤等于没裁。
            let text = AutoRefiner.stripJunk(AutoRefiner.trim(segs, dropBefore: dropBefore))
            if !text.isEmpty { self.onRefined?(from, to, text) }
            if self.pendingStop { self.killServer() }
        }
    }

    /// whisper 在静音/音乐段的经典套话(训练数据里大量 YouTube 字幕的片尾语)。
    /// 慢通道尤其容易在块尾的静音上吐这些,而快通道(Apple)根本不会产出 ——
    /// 不滤掉就会用垃圾覆盖掉本来正确的实时文本。
    /// 2026-09-09 实测:Apple 出「哦。」(正确),whisper 覆盖成
    /// 「嗯 请不吝点赞 订阅 转发 打赏支持明镜与点点栏目」。当时中文一条都没有,补上。
    static let junk: Set<String> = [
        "ご視聴ありがとうございました", "ありがとうございました", "最後までご視聴いただきありがとうございます",
        "チャンネル登録お願いします", "次回もお楽しみに", "おわり", "終わり", "音楽", "字幕", "by H.",
        "thankyou", "thankyouverymuch", "thankyouforwatching", "thanksforwatching",
        "pleasesubscribe", "youbye", "bye", "byebye", "music", "applause", "blankaudio",
        "谢谢观看", "感谢观看", "谢谢大家观看", "我们下期再见", "下期再见", "请订阅", "字幕志愿者",
    ]

    /// 会混在真实内容里出现的长套话,必须按**子串**剔除而不是整段判断 ——
    /// 实测形态是「嗯 请不吝点赞 订阅 转发 打赏支持明镜与点点栏目」,
    /// 开头那个「嗯」是真的,整段丢会把真内容一起丢掉。
    /// 只收多词长短语:「订阅」单独出现在 SaaS 讨论里是正常词,不能当幻觉。
    static let junkPhrases: [String] = [
        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
        "请不吝点赞订阅转发打赏支持明镜与点点栏目",
        "点赞 订阅 转发 打赏支持明镜与点点栏目",
        "打赏支持明镜与点点栏目", "明镜与点点栏目", "请不吝点赞",
        "点赞 订阅 转发 打赏", "点赞订阅转发打赏", "打赏支持明镜",
        "字幕由Amara.org社区提供", "由Amara.org社区提供的字幕", "中文字幕由", "本字幕由",
        "优优独播剧场——YoYo Television Series Exclusive", "优优独播剧场", "YoYo Television Series Exclusive",
        "MING PEI 明佩", "字幕提供", "转录由", "本视频由",
        "最後までご視聴いただきありがとうございます", "ご視聴ありがとうございました",
        "チャンネル登録よろしくお願いします",
        "Thanks for watching", "Thank you for watching", "Please subscribe to my channel",
    ]

    /// 从文本里剔除套话片段,返回清理后的文本。
    static func stripJunk(_ t: String) -> String {
        var out = t
        for p in junkPhrases { out = out.replacingOccurrences(of: p, with: " ") }
        out = out.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 按词级时间戳裁掉 dropBefore 之前的内容,并滤掉套话幻觉。
    /// 没有词级时间戳时退回段级(整段落在上文区才丢)。
    static func trim(_ segs: [Seg], dropBefore: Double) -> String {
        var parts: [String] = []
        for s in segs {
            if isJunk(s.text) { continue }
            if s.start >= dropBefore { parts.append(s.text); continue }
            if s.end <= dropBefore { continue }               // 整段都在上文区
            if s.words.isEmpty {
                if s.start >= dropBefore - 0.3 { parts.append(s.text) }   // 无词时间戳,退回段级
                continue
            }
            let kept = s.words.filter { $0.0 >= dropBefore }.map { $0.1 }.joined()
            let t = kept.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty && !isJunk(t) { parts.append(t) }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isJunk(_ t: String) -> Bool {
        let n = t.replacingOccurrences(of: "[^\\w]", with: "", options: .regularExpression).lowercased()
        return n.isEmpty || junk.contains(n)
    }

    struct Seg { let start: Double; let end: Double; let text: String; let words: [(Double, String)] }

    private func decode(_ wav: Data, done: @escaping ([Seg]) -> Void) {
        let boundary = "audicap-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ n: String, _ v: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(n)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        field("response_format", "verbose_json")
        field("language", lang)
        field("temperature", "0.0")
        // ★必须关:VAD 把音频全滤掉时 server.cpp 的 lang_probs[-2] 会越界,whisper-server 直接崩。
        //   顺带这块被官方注释为 expensive operation,关掉还更快。
        field("no_language_probabilities", "true")
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        req.timeoutInterval = 180
        URLSession.shared.dataTask(with: req) { data, resp, err in
            guard let data, err == nil,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = j["segments"] as? [[String: Any]] else { done([]); return }
            let segs: [Seg] = arr.compactMap { s in
                guard let t = s["text"] as? String else { return nil }
                let ws: [(Double, String)] = ((s["words"] as? [[String: Any]]) ?? []).compactMap {
                    guard let w = $0["word"] as? String else { return nil }
                    return (($0["start"] as? Double) ?? 0, w)
                }
                return Seg(start: (s["start"] as? Double) ?? 0,
                           end: (s["end"] as? Double) ?? 0,
                           text: t.trimmingCharacters(in: .whitespacesAndNewlines),
                           words: ws)
            }
            done(segs)
        }.resume()
    }
}

/// 精修结果。用专用枚举而不是 Result<String,String> —— String 不是 Error。
enum RefineOutcome {
    case ok(String)         // 精修稿路径
    case fail(String)       // 人话错误信息
}

enum Refiner {
    static let cli = "\(HOME)/whisper.cpp/build/bin/whisper-cli"
    static let server = "\(HOME)/whisper.cpp/build/bin/whisper-server"
    static let model = "\(HOME)/whisper.cpp/models/ggml-large-v3-turbo.bin"

    static var available: Bool {
        FileManager.default.fileExists(atPath: cli) && FileManager.default.fileExists(atPath: model)
    }

    /// 对整段录音跑一遍 whisper。lang 传 "auto" 时让它自己判。
    /// 完成后把精修稿写到 wav 同目录,回调给出路径或错误。
    static func refine(wav: String, lang: String, progress: @escaping (String) -> Void,
                       done: @escaping (RefineOutcome) -> Void) {
        guard available else {
            done(.fail("找不到 whisper-cli 或模型 —— 精修需要 ~/whisper.cpp 那套还在")); return
        }
        guard FileManager.default.fileExists(atPath: wav) else {
            done(.fail("找不到录音 \(wav)")); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            var args = ["-m", model, "-f", wav, "-np",
                        // 整段跑就要用上整段上下文:关掉逐段重置,并压住非语音 token
                        "-sns", "-mc", "128"]
            if lang != "auto" { args += ["-l", lang] } else { args += ["-l", "auto"] }
            p.arguments = args
            let op = Pipe(); p.standardOutput = op; p.standardError = FileHandle.nullDevice
            progress("whisper 精修中…（约为音频时长的 1/15）")
            do { try p.run() } catch {
                DispatchQueue.main.async { done(.fail("whisper 启动失败: \(error.localizedDescription)")) }
                return
            }
            let data = op.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                DispatchQueue.main.async { done(.fail("whisper 退出码 \(p.terminationStatus)")) }
                return
            }
            let out = (wav as NSString).deletingPathExtension + ".refined.md"
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
            let body = """
            # Audicap 精修稿 \(f.string(from: Date()))

            > 实时字幕由 Apple SpeechAnalyzer 生成（低延迟、逐句出）；
            > 本文件由 whisper large-v3-turbo 对整段录音重跑，拿得到完整上下文，
            > 专业名词和跨句边界通常更准。两份都保留，按需取用。
            >
            > 录音：`\(wav)`

            \(text.trimmingCharacters(in: .whitespacesAndNewlines))
            """
            do {
                try body.write(toFile: out, atomically: true, encoding: .utf8)
                DispatchQueue.main.async { done(.ok(out)) }
            } catch {
                DispatchQueue.main.async { done(.fail("写不出精修稿: \(error.localizedDescription)")) }
            }
        }
    }
}
