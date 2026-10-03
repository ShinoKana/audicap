// Audicap 识别层 — Apple SpeechAnalyzer/SpeechTranscriber(macOS 26)。
//
// 取代原来的 whisper.cpp + python 子进程链路。2026-09-08 同素材实测(90s 真实录音,流式):
//   whisper 流式: 3x 实时、模型常驻 1.5GB、句子被 5s 硬切成碎片、无标点、出「状況の状況の状況」死循环幻觉
//   本方案    : 60~97x 实时、RSS +8MB、原生句子级断句+标点、静音/纯器乐零幻觉、歌词照出
//   短应答("はい"/"Yes")whisper 漏 40~62%,本方案基本不漏。
//
// 关键设计:
//  · volatile(草稿)/final(定稿)是框架原生语义,直接对应"说到一半"与"这句说完了"。
//  · 多 locale 并行:实测三路并行 wall 1.18s vs 单路 1.07s、RSS 都是 +8MB(走系统级共享服务,
//    不是每路各加载一份模型),所以"自动选语种"几乎免费。按 transcriptionConfidence 选优,
//    实测分离度很大(日英夹杂素材 ja=0.995 / en=0.152)。
//  · 输入用有界 AsyncStream:采集回调只入队不阻塞,识别再慢也不会把 SCK 回调堵死
//    (旧实现在回调里直接阻塞 write() 喂管道,是卡顿的根源)。
import Foundation
import Speech
import AVFoundation
import CoreMedia

/// 一句识别结果。conf<0 表示该 locale 没开置信度或没有可用值。
struct RecogResult {
    let text: String
    let isFinal: Bool
    let confidence: Double
    let locale: String
    let range: CMTimeRange
}

/// 一条 locale 通道。多条并行跑同一份音频,按置信度选优。
private final class Lane: @unchecked Sendable {
    let id: String
    let transcriber: SpeechTranscriber
    let analyzer: SpeechAnalyzer
    let cont: AsyncStream<AnalyzerInput>.Continuation
    let stream: AsyncStream<AnalyzerInput>
    var task: Task<Void, Never>?
    /// 最近若干句定稿置信度的指数滑动平均,用来在多语种模式下选优。
    var score: Double = 0
    var scored = false
    var nFinal = 0, nDraft = 0        // 诊断用:每路到底收到过什么

    init(locale: Locale, fast: Bool) {
        id = locale.identifier(.bcp47)
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if fast { reporting.insert(.fastResults) }
        transcriber = SpeechTranscriber(locale: locale,
                                        transcriptionOptions: [],
                                        reportingOptions: reporting,
                                        attributeOptions: [.transcriptionConfidence])
        analyzer = SpeechAnalyzer(modules: [transcriber])
        // 有界缓冲:采集端永不阻塞;真堵住时丢最旧的,而不是把延迟无限拖长。
        // ★上限按**块数**算,不是秒。SCK 的块可能只有十几毫秒,240 块可能才两三秒 ——
        //   慢的那一路会因此丢音频(评审指出)。放大到 4000,按 SCK 常见块长够几十秒。
        let (s, c) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(4000))
        stream = s; cont = c
    }

    func note(confidence c: Double) {
        guard c >= 0 else { return }
        score = scored ? score * 0.7 + c * 0.3 : c
        scored = true
    }
}

/// AttributedString 各 run 的平均置信度;没有置信度属性时返回 -1。
private func meanConfidence(_ a: AttributedString) -> Double {
    var sum = 0.0, n = 0
    for run in a.runs {
        if let c = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] { sum += c; n += 1 }
    }
    return n == 0 ? -1 : sum / Double(n)
}

enum RecogState: Equatable {
    case idle
    case preparing              // 正在下载/加载语言包
    case listening              // 已就绪,等声音
    case unsupported(String)    // 选的语种系统不支持
    case failed(String)
}

/// 识别引擎。喂 AVAudioPCMBuffer,回调出草稿/定稿。
/// 线程模型:内部全部在 Task 里跑,回调统一 hop 到主线程,调用方不用自己加锁。
final class Recognizer: @unchecked Sendable {
    /// 定稿一句。已按多 locale 选优。
    var onFinal: ((RecogResult) -> Void)?
    /// 草稿更新(同一句会连续更新多次,直到被 final 取代)。
    var onDraft: ((RecogResult) -> Void)?
    var onState: ((RecogState) -> Void)?
    /// 语种判定完成/改判时回调(给云端 localeHint 和菜单显示用)
    var onLocale: ((String) -> Void)?
    /// 上层(云端判语种)给的**先验**。现在只是偏好、不是锁 ——
    /// 2026-09-13 实测:锁定 en-US 之后换成日语,输出直接归零。逃生通道要求
    /// "锁定那路从头到尾一个字没出过",而英语阶段早出过字了,永远触发不了。
    /// 用户的真实场景是「一段话内语言一致,停顿几十秒后可能换一种」。
    func lockLocale(_ id: String) {
        let ok: Bool = lock.withLock {
            guard lanes.contains(where: { $0.id == id }) else { return false }
            preferred = id; preferredAt = Date(); localeConfident = true
            return true
        }
        guard ok else { return }
        alog("[\(tag)] 云端语种先验: \(id)(只是偏好,之后每句现场比)")
        DispatchQueue.main.async { self.onLocale?(id) }
    }
    /// 已经有语种偏好了吗(上层据此决定要不要再去云端判一次)
    var isLocaleLocked: Bool { lock.withLock { preferred != nil } }
    /// 检测到语音的音频位置(秒);还没听到就是 nil
    var speechStartedAt: Double? { lock.withLock { firstSpeechAt } }

    private var lanes: [Lane] = []
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterSrcFormat: AVAudioFormat?
    private var running = false
    private var startTime = CMTime.zero
    private let tag: String            // "sys" / "mic",只用于日志
    private let lock = Lock()          // feed() 在 SCK 采集队列上跑,start/stop 在 Task 里
    // 多语种仲裁。
    //
    // 早期做法是"攒 0.35s 再按置信度挑一条",**行不通** —— 2026-09-13 实测:
    // 各路的断句边界完全不同(en-US 把 15.00–19.44 / 19.44–23.58 切成两句,
    // zh-CN 把 14.34–24.66 合成一句),到达时间也差好几秒,根本没法按时间窗配对。
    // 结果三路各自都发了出去,记录里同一段话出现两三遍、语言还不统一
    // (「I can do a thousand now.」+「I can do athound now」)。
    //
    // 改成:**只放行当前领先的那一路**,其余直接丢弃。置信度分离度足够
    // (同一段英语:en 0.870 / zh 0.584 / ja 0.528)。
    // ── 按句现场比语种 ────────────────────────────────────────────────
    // 三路(ja/en/zh)始终并行跑同一份音频。每条 final 先按音频区间归组,
    // 等其他路补齐(或 arbWaitSec 到点)后**只发置信度最高的那一条**。
    //
    // 为什么按句比是可行的 —— 2026-09-13 实测,中日混合素材 90s:
    //   中文讲解段 zh=0.97 / ja=0.78;日语台词段 ja=0.81 / zh=0.61;
    //   再中文 zh=0.89 / ja=0.62;再日语 ja=0.92,0.93,0.98 / zh=0.73~0.76;
    //   en 全程 0.01~0.03。六次比较全部选对,正确那路领先幅度最小 0.16。
    //   三路常驻只多占 7MB(峰值 23MB)、44 倍实时,成本可以忽略。
    private struct ArbGroup {
        let gid: Int
        var range: CMTimeRange
        var results: [RecogResult]
        /// もう一度だけ待ち直したか。文字体系の合わない候補しか無い時に一回だけ延長する。
        var extended = false
    }
    private var groups: [ArbGroup] = []
    private var gidSeq = 0
    /// 等其他路补齐的时间。实测各路对同一句的定稿时间差在零点几秒内。
    private let arbWaitSec = 1.0
    /// 最好的候选也没把握、且还有路没交结果时,多等这么久再决定(各路一到齐就立刻决定,不会白等)。
    /// 2026-09-25 实测:en-US 路判「一句结束」比其他路早 ~1.8s。法语音频上 en 先交了 0.50 的乱码,
    /// 1s 后就被发出去,晚到的 fr-FR 0.97 被当成迟到者丢掉。代价:只有可疑句子(<0.80)字幕会晚一点。
    private let lowConfWaitSec = 2.0
    private let lowConfLine = 0.80
    /// 低于这个置信度直接丢:实测错误那路会吐出 " , , , ," 这种 conf=0.01 的东西。
    private let junkConf = 0.25
    /// 上一句选中的语种 = 下一句的偏好。加分必须**小于**正确路的领先幅度(实测最小 0.16),
    /// 否则会压住真正的语言切换;又要够挡住同一段话里的抖动。
    static let biasBonus = 0.08
    /// 文字体系が自分のレーンの言語と食い違う候補への減点。
    /// 2026-09-13 実測:ja 路が中国語音声に「変更日始」(仮名ゼロ)を信頼度 0.78 で出した。
    /// 本物の日本語なら助詞で必ず仮名が混ざるので、仮名ゼロの長文＝聞き間違い。
    /// zh 路が「おこの人人中国でと人気るじ」のように仮名を吐く逆パターンも同じ。
    static let scriptMismatchPenalty = 0.25
    /// 1~3 文字は日中どちらとも取れるので見ない(scriptOf 自体も漢字3つ以上を要求する)。
    /// 減点は**同じ区間に対抗馬がいる時しか効かない**(候補が1つならそれが最大のまま)ので、
    /// 短い日本語が誤って中国語扱いされて消える心配はない。
    static let scriptCheckMinChars = 4

    /// 候補の採点。テストから直接叩けるよう静的に切り出してある。
    static func arbScore(_ r: RecogResult, preferred: String?, biasOn: Bool) -> Double {
        let mismatch = r.text.count >= scriptCheckMinChars
            && scriptMatches(r.text, r.locale) == false
        // ★文字体系が合わない時は加点もしない。
        //   「前の文と同じ言語だから」という偏りの前提そのものが崩れているため。
        //   これを入れないと ja 0.93+0.08-0.25=0.76 が正しい中国語 0.72 を押し切ってしまう(実測)。
        if mismatch { return r.confidence - scriptMismatchPenalty }
        return r.confidence + (biasOn && r.locale == preferred ? biasBonus : 0)
    }
    /// 停顿超过这么久就不再偏向上一句的语种(实际使用中,停顿几十秒后常常换了播放内容)。
    private let biasHoldSec = 12.0
    private var preferred: String?
    private var preferredAt = Date.distantPast
    /// 直通阈值:当前语种 + 置信度高到这个程度就**不等其他路**,立刻发出去(省掉 1s 等待)。
    /// 实测错误那路最高只到 0.81,正确那路常在 0.92~0.98,所以 0.90 不会误放。
    private let fastPassConf = 0.90
    /// 已经发出去的音频区间。直通发过之后,别的路对同一段的迟到结果必须丢掉,否则就是重复。
    private var emitted: [(CMTimeRange, Date)] = []

    /// 开始有语音的音频位置。**必须用音频能量判,不能用"某一路吐字了"** ——
    /// 2026-09-13 实测:ja-JP 在静音第 0 秒就幻觉出内容,于是那个信号把锚点又拉回了静音区。
    /// 用来躲幻觉的判据本身被幻觉污染,是这一路排查里最隐蔽的一个坑。
    private var firstSpeechAt: Double?
    private var loudRun = 0.0          // 连续高于阈值的时长
    /// 噪声本底(最近见过的最小 RMS)。**不能用固定绝对阈值** ——
    /// 2026-09-13 踩到:我按"正常音量"拍脑袋定了 0.01,而实际素材全程只有 0.0013~0.0028,
    /// 语音检测从头到尾没触发过。系统音的真静音是数字 0,所以用"比本底高一截"判最稳。
    private var noiseFloor: Float = 1.0
    private var rmsLogged = 0
    /// 判定是否可信(≥2 路参与比较)。不可信时不给云端语种提示 ——
    /// 给错的提示比不给更糟。
    private(set) var localeConfident = false
    /// 启动代次。准备语言包要 await,期间若用户已停止,旧 Task 不能再把 lanes 装上去。
    private var generation = 0
    /// 兜底去重:只挡"完全相同且 3 秒内"的,不做包含判断 ——
    /// 评审指出原来 `a == b` 写在长度守卫之前,「はい」「OK」照样被误杀;
    /// 且「Please continue」→「Please continue with slide three」后者会被整条删掉。
    private var recent: [(String, Date)] = []

    /// 主语种(单语种模式)或候选集(自动模式)。
    private(set) var localeIDs: [String] = []

    init(tag: String) { self.tag = tag }

    /// 设置里能选的语种(SpeechTranscriber 支持的 30 个 locale 里挑的主流语言,每种一个代表)。
    static let selectable: [(id: String, zh: String, en: String)] = [
        ("ja-JP", "日语", "Japanese"), ("en-US", "英语", "English"),
        ("zh-CN", "普通话（简体）", "Mandarin (Simplified)"), ("zh-TW", "國語（繁體）", "Mandarin (Traditional)"),
        ("yue-CN", "粤语", "Cantonese"), ("ko-KR", "韩语", "Korean"),
        ("fr-FR", "法语", "French"), ("de-DE", "德语", "German"), ("es-ES", "西班牙语", "Spanish"),
        ("it-IT", "意大利语", "Italian"), ("pt-BR", "葡萄牙语", "Portuguese"),
    ]
    /// 一个 app 同时最多占 5 个语言包名额(AssetInventory.maximumReservedLocales),
    /// 而且跨次运行一直记着(2026-09-25 实测:超了报 "Too many allocated locales, 5 maximum")。
    static let maxLanes = 5
    /// 自动模式并行跑的语种,由 App 从设置同步进来。多开一路几乎不占资源,
    /// 但每多一路就多一个能抢结果的对手 —— 只勾会上实际会说的语言。
    static var autoLocales = ["ja-JP", "en-US", "zh-CN"]

    static func localeIDs(for setting: String) -> [String] {
        switch setting {
        case "ja": return ["ja-JP"]          // 旧版设置值
        case "en": return ["en-US"]
        case "zh": return ["zh-CN"]
        case "auto", "": return Array(autoLocales.prefix(maxLanes))   // 并行跑,按句按置信度选优
        default:   return [setting]          // 单一语种:存的就是 locale id
        }
    }

    /// 语言包是否齐备;缺就下载(首次每个语种几十 MB)。
    static func ensureAssets(_ ids: [String]) async -> String? {
        var mods: [any SpeechModule] = []
        for id in ids {
            guard let sel = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { continue }
            mods.append(SpeechTranscriber(locale: sel, preset: .progressiveTranscription))
        }
        guard !mods.isEmpty else { return "没有可用语种" }
        // 先把现在用不到的语种的名额还回去,否则换语种时新的装不上(上限 5,跨次运行一直记着)
        var want = Set<String>()
        for id in ids {
            if let sel = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) { want.insert(sel.identifier(.bcp47)) }
        }
        for l in await AssetInventory.reservedLocales where !want.contains(l.identifier(.bcp47)) {
            let ok = await AssetInventory.release(reservedLocale: l)
            alog("语言包名额释放 \(l.identifier(.bcp47)): \(ok)")
        }
        if await AssetInventory.status(forModules: mods) == .installed { return nil }
        do {
            if let req = try await AssetInventory.assetInstallationRequest(supporting: mods) {
                try await req.downloadAndInstall()
            }
            return nil
        } catch { return "语言包安装失败: \(error.localizedDescription)" }
    }

    /// startOffset:音频时间轴的起点。会议中途改语种/低延迟会重启 Recognizer,
    /// 必须把当前录音位置传进来续上 —— 否则 startTime 归零而 Tape 继续累计,
    /// 之后 range 会比真实位置早几百秒,云端按它切音频就切错了(2026-09-13 评审指出)。
    func start(setting: String, fast: Bool, startOffset: Double = 0) {
        guard !running else { return }
        running = true
        lock.withLock { startTime = CMTime(seconds: max(0, startOffset), preferredTimescale: 48000) }
        // 每次开始采集都要重来一遍语种判定,去重缓存也清掉 ——
        // 否则第二次采集会沿用上次的领先者和上次的已发内容
        let gen: Int = lock.withLock {
            generation += 1
            preferred = nil; preferredAt = .distantPast
            groups = []; gidSeq = 0; recent = []; emitted = []
            localeConfident = false
            firstSpeechAt = nil; loudRun = 0; noiseFloor = 1.0; rmsLogged = 0
            return generation
        }
        localeIDs = Recognizer.localeIDs(for: setting)
        emit(.preparing)
        Task { [weak self] in
            guard let self else { return }
            var built: [Lane] = []
            for id in self.localeIDs {
                guard let sel = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: id)) else { continue }
                built.append(Lane(locale: sel, fast: fast))
            }
            guard !built.isEmpty else {
                self.running = false
                self.emit(.unsupported(self.localeIDs.joined(separator: ",")))
                return
            }
            if let err = await Recognizer.ensureAssets(self.localeIDs) {
                self.running = false; self.emit(.failed(err)); return
            }
            guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [built[0].transcriber]) else {
                self.running = false; self.emit(.failed("拿不到可用音频格式")); return
            }
            // 代次核对:await 期间用户可能已经停止或又启动了一次
            let stale = self.lock.withLock { gen != self.generation }
            if stale { alog("[\(self.tag)] 启动已过期(gen \(gen)),丢弃"); return }
            self.lock.withLock { self.analyzerFormat = fmt; self.lanes = built }
            for lane in built { self.collect(lane) }
            for lane in built {
                do { try await lane.analyzer.start(inputSequence: lane.stream) }
                catch {
                    self.running = false
                    self.emit(.failed("[\(lane.id)] 启动失败: \(error.localizedDescription)"))
                    return
                }
            }
            alog("[\(self.tag)] recognizer started: \(self.localeIDs.joined(separator: ",")) fmt=\(fmt.sampleRate)Hz ch\(fmt.channelCount)")
            self.emit(.listening)
        }
    }

    private func collect(_ lane: Lane) {
        lane.task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await r in lane.transcriber.results {
                    let txt = String(r.text.characters)
                    if txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                    let conf = meanConfidence(r.text)
                    let res = RecogResult(text: txt, isFinal: r.isFinal, confidence: conf,
                                          locale: lane.id, range: r.range)

                    if r.isFinal {
                        self.lock.withLock { lane.nFinal += 1 }
                        // score/scored 被别的 lane 的 leadingLane() 和主线程的 laneScores() 读,
                        // 写的时候必须持同一把锁(评审指出原来只有读端加锁,消不掉竞态)
                        self.lock.withLock { lane.note(confidence: conf) }
                        self.submitFinal(res)
                    } else {
                        self.lock.withLock { lane.nDraft += 1 }
                        guard self.draftAllowed(lane.id) else { continue }
                        await MainActor.run { self.onDraft?(res) }
                    }

                }
            } catch {
                alog("[\(self.tag)][\(lane.id)] results err: \(error)")
            }
        }
    }

    /// 草稿跟着当前偏好那一路(让用户尽快看到字);偏好过期(停顿久了)就跟领先那路。
    /// 草稿选错不要紧 —— 一两秒后的 final 会按置信度纠正它。
    private func draftAllowed(_ id: String) -> Bool {
        let (p, fresh): (String?, Bool) = lock.withLock {
            (preferred, Date().timeIntervalSince(preferredAt) <= biasHoldSec)
        }
        if let p, fresh { return id == p }
        return leadingLane()?.id == id
    }

    /// 当前领先的通道(按定稿置信度的滑动平均)。还没有任何评分时用第一路。
    private func leadingLane() -> Lane? {
        lock.withLock {
            guard lanes.count > 1 else { return lanes.first }
            return lanes.filter { $0.scored }.max(by: { $0.score < $1.score }) ?? lanes.first
        }
    }

    /// 单语种直接出;多语种按句归组,比完只发一条(不锁语种)。
    private func submitFinal(_ r: RecogResult) {
        if lanes.count <= 1 { deliver(r); return }
        if r.confidence >= 0 && r.confidence < junkConf {
            alog("[\(tag)][\(r.locale)] 丢弃低置信度 \(String(format: "%.2f", r.confidence)): \(r.text.prefix(20))")
            return
        }
        // 已经发过这一段了 → 这是输掉的那路迟到的结果,丢掉(否则同一句会出两遍)
        enum Act { case drop, fast, group }
        let act: Act = lock.withLock {
            let now = Date()
            emitted.removeAll { now.timeIntervalSince($0.1) > 30 }
            if emitted.contains(where: { Recognizer.sameUtterance($0.0, r.range) }) { return .drop }
            let fresh = now.timeIntervalSince(preferredAt) <= biasHoldSec
            if fresh, r.locale == preferred, r.confidence >= fastPassConf,
               scriptMatches(r.text, r.locale) == true,   // 文字体系が合わない限り直通させない
               !groups.contains(where: { Recognizer.sameUtterance($0.range, r.range) }) {
                emitted.append((r.range, now)); preferredAt = now
                return .fast
            }
            return .group
        }
        if act == .drop { return }
        if act == .fast { deliver(r); return }

        var ready: ArbGroup?
        var newGid: Int?
        lock.withLock {
            if let i = groups.firstIndex(where: { Recognizer.sameUtterance($0.range, r.range) }) {
                groups[i].results.append(r)
                groups[i].range = groups[i].range.union(r.range)
                // 各路都到齐了就不用再等
                if Set(groups[i].results.map { $0.locale }).count >= lanes.count {
                    ready = groups.remove(at: i)
                }
            } else {
                gidSeq += 1
                groups.append(ArbGroup(gid: gidSeq, range: r.range, results: [r]))
                newGid = gidSeq
            }
        }
        if let g = ready { decideGroup(g) }
        if let gid = newGid {
            DispatchQueue.main.asyncAfter(deadline: .now() + arbWaitSec) { [weak self] in
                guard let self else { return }
                let g: ArbGroup? = self.lock.withLock {
                    guard let i = self.groups.firstIndex(where: { $0.gid == gid }) else { return nil }
                    return self.groups.remove(at: i)
                }
                if let g { self.decideGroup(g) }
            }
        }
    }

    /// 两条结果算不算同一句:重叠时长要占**双方各自**一半以上。
    /// 只要"有重叠"就并,会把跨好几句的那条(错误路很常见,比如 en 吐了个 36–62s 的 " , , ,")
    /// 跟正确路的多句连锁并成一大坨,一句话只剩一条,内容就丢了。
    private static func sameUtterance(_ a: CMTimeRange, _ b: CMTimeRange) -> Bool {
        let ov = min(a.end.seconds, b.end.seconds) - max(a.start.seconds, b.start.seconds)
        let da = a.duration.seconds, db = b.duration.seconds
        guard ov > 0, da > 0, db > 0 else { return false }
        return ov >= da * 0.5 && ov >= db * 0.5
    }

    /// 一组候选里挑一条发出去,并把胜出语种记成下一句的偏好。
    private func decideGroup(_ g: ArbGroup) {
        guard !g.results.isEmpty else { return }
        // 候補が1つだけで、しかも文字体系が自分のレーンと合わない = そのレーンは聞き間違えている。
        // 正しいレーンの結果が少し遅れているだけの可能性が高いので、一回だけ待ち直す。
        // (2026-09-13 実測:末尾で zh 路の仮名混じり乱码が先に確定し、
        //  正しい ja 路の結果が「遅れて来た対抗馬」として捨てられていた)
        let scriptWrong = g.results.count == 1
            && g.results[0].text.count >= Recognizer.scriptCheckMinChars
            && scriptMatches(g.results[0].text, g.results[0].locale) == false
        let incomplete = lock.withLock { Set(g.results.map { $0.locale }).count < lanes.count }
        let unsure = incomplete && (g.results.map { $0.confidence }.max() ?? 0) < lowConfLine
        if !g.extended, scriptWrong || unsure {
            var again = g; again.extended = true
            lock.withLock { groups.append(again) }
            let wait = unsure ? lowConfWaitSec : arbWaitSec
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self else { return }
                let g2: ArbGroup? = self.lock.withLock {
                    guard let i = self.groups.firstIndex(where: { $0.gid == again.gid }) else { return nil }
                    return self.groups.remove(at: i)
                }
                if let g2 { self.decideGroup(g2) }
            }
            return
        }
        let (winner, changed, multi): (RecogResult, Bool, Bool) = lock.withLock {
            let now = Date()
            let biasOn = now.timeIntervalSince(preferredAt) <= biasHoldSec
            let best = g.results.max {
                Recognizer.arbScore($0, preferred: preferred, biasOn: biasOn)
                    < Recognizer.arbScore($1, preferred: preferred, biasOn: biasOn)
            } ?? g.results[0]
            let ch = preferred != nil && preferred != best.locale
            preferred = best.locale; preferredAt = now
            emitted.append((g.range, now))
            if g.results.count >= 2 { localeConfident = true }
            return (best, ch, g.results.count >= 2)
        }
        if multi {
            alog("[\(tag)] 按句选语种 [\(String(format: "%.1f", g.range.start.seconds))–\(String(format: "%.1f", g.range.end.seconds))s] " +
                 g.results.map { "\($0.locale)=\(String(format: "%.2f", $0.confidence))" }.joined(separator: " ") +
                 " → \(winner.locale)")
        }
        if changed {
            alog("[\(tag)] 语种切换 → \(winner.locale)")
            DispatchQueue.main.async { self.onLocale?(winner.locale) }
        }
        deliver(winner)
    }

    /// 送出。兜底去重只挡「完全相同且 3 秒内」,不做包含判断。
    /// 锁定语种之后跨路重复已经不存在了,这里只防同一路瞬间重发,所以可以很保守——
    /// 宁可漏挡,也不能把真实的重复发言和短应答删掉。
    private func deliver(_ r: RecogResult) {
        let dup: Bool = lock.withLock {
            let n = Recognizer.norm(r.text)
            if n.isEmpty { return true }
            let now = Date()
            recent.removeAll { now.timeIntervalSince($0.1) > 3 }
            if recent.contains(where: { $0.0 == n }) { return true }
            recent.append((n, now))
            return false
        }
        if dup { alog("[\(tag)] 丢弃 3s 内完全相同的一句: \(r.text.prefix(24))"); return }
        DispatchQueue.main.async { self.onFinal?(r) }
    }

    /// 这一块音频的 RMS。Float32 和 Int16 两种格式都要能算 ——
    /// SCK 给的是 Float32,转换后可能是别的。
    static func rms(_ b: AVAudioPCMBuffer) -> Float {
        let n = Int(b.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let ch = b.floatChannelData {
            for i in 0..<n { let v = ch[0][i]; sum += v * v }
        } else if let ch = b.int16ChannelData {
            for i in 0..<n { let v = Float(ch[0][i]) / 32768.0; sum += v * v }
        } else { return 0 }
        return (sum / Float(n)).squareRoot()
    }

    static func norm(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// 当前各路得分,给状态面板看。
    func laneScores() -> [(String, Double)] {
        lock.withLock { lanes.map { ($0.id, $0.scored ? $0.score : -1) } }
    }

    /// 喂一块音频。可从任意线程调用;不阻塞。
    func feed(_ buf: AVAudioPCMBuffer) {
        let (ok, fmtOpt, ls) = lock.withLock { (running, analyzerFormat, lanes) }
        guard ok, let fmt = fmtOpt, !ls.isEmpty else { return }
        var out = buf
        if buf.format != fmt {
            if converter == nil || converterSrcFormat != buf.format {
                converter = AVAudioConverter(from: buf.format, to: fmt)
                converterSrcFormat = buf.format
                alog("[\(tag)] converter \(buf.format.sampleRate)Hz ch\(buf.format.channelCount) → \(fmt.sampleRate)Hz ch\(fmt.channelCount)")
            }
            guard let conv = converter else { return }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * fmt.sampleRate / buf.format.sampleRate) + 256
            guard let ob = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else { return }
            var done = false; var err: NSError?
            conv.convert(to: ob, error: &err) { _, st in
                if done { st.pointee = .noDataNow; return nil }
                done = true; st.pointee = .haveData; return buf
            }
            if err != nil || ob.frameLength == 0 { return }
            out = ob
        }
        let rms = Recognizer.rms(out)
        let secs = Double(out.frameLength) / fmt.sampleRate
        let dur = CMTime(seconds: secs, preferredTimescale: 48000)
        let at: CMTime = lock.withLock {
            // 能量判语音:阈值 = max(极小绝对值, 本底×6),连续 0.5s 才算,防一声杂音触发
            if firstSpeechAt == nil {
                if rms > 0 { noiseFloor = min(noiseFloor, rms) }
                let thr = max(Float(0.0004), noiseFloor * 6)
                if rms > thr {
                    loudRun += secs
                    if loudRun >= 0.5 {
                        firstSpeechAt = max(0, startTime.seconds - loudRun)
                        alog("[\(tag)] 检测到语音 @\(String(format: "%.1f", firstSpeechAt!))s rms=\(String(format: "%.5f", rms)) 阈值=\(String(format: "%.5f", thr))")
                    }
                } else { loudRun = 0 }
                // 前几次记一下实际电平,下次再出问题不用猜
                if rmsLogged < 3 && startTime.seconds > 1 {
                    rmsLogged += 1
                    alog("[\(tag)] 电平采样 @\(String(format: "%.1f", startTime.seconds))s rms=\(String(format: "%.5f", rms)) 本底=\(String(format: "%.5f", noiseFloor))")
                }
            }
            let t = startTime
            startTime = CMTimeAdd(startTime, dur)
            return t
        }
        for lane in ls { lane.cont.yield(AnalyzerInput(buffer: out, bufferStartTime: at)) }
    }

    func stop() {
        let ls: [Lane] = lock.withLock {
            guard running else { return [] }
            running = false
            let l = lanes
            lanes = []; groups = []
            return l
        }
        guard !ls.isEmpty else { return }
        for lane in ls { lane.cont.finish() }
        Task {
            for lane in ls {
                try? await lane.analyzer.finalizeAndFinishThroughEndOfInput()
                lane.task?.cancel()
            }
        }
        emit(.idle)
    }

    private func emit(_ s: RecogState) {
        DispatchQueue.main.async { self.onState?(s) }
    }
}

// MARK: script-family —— 文字系统判定(文件末尾,单测直接 awk 抽这一段)
// 旧的 CloudCorrector.scriptOf 只认 ja/zh/en,把所有拉丁字母都当 en-US:
// 开了法语/德语等路之后,这些路的结果会被当成「文字不符」扣 0.25,几乎永远赢不了(2026-09-25)。
// 改成比较「文字系统」:假名 / 汉字 / 谚文 / 拉丁字母,再和该路语言应有的文字比。日中英的判定与旧版一致。

enum ScriptFamily { case kana, han, hangul, latin }

func scriptFamily(_ s: String) -> ScriptFamily? {
    var kana = 0, han = 0, hangul = 0, latin = 0
    for u in s.unicodeScalars {
        switch u.value {
        case 0x3040...0x30FF: kana += 1
        case 0x4E00...0x9FFF: han += 1
        case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: latin += 1      // 含 é/ü/ñ 等带符号字母
        default: break
        }
    }
    if kana >= 2 { return .kana }            // 真日语几乎必带助词假名
    if hangul >= 2 { return .hangul }
    if latin > (han + kana + hangul) * 2 && latin >= 6 { return .latin }
    if han >= 3 && latin < han { return .han }
    return nil
}

func expectedScript(_ locale: String) -> ScriptFamily {
    if locale.hasPrefix("ja") { return .kana }
    if locale.hasPrefix("zh") || locale.hasPrefix("yue") { return .han }
    if locale.hasPrefix("ko") { return .hangul }
    return .latin
}

/// 这段文字的文字系统和这一路的语言对不对得上。nil = 太短或混杂,判断不了(不扣分也不直通)。
func scriptMatches(_ text: String, _ locale: String) -> Bool? {
    scriptFamily(text).map { $0 == expectedScript(locale) }
}
