// 云端音频纠错(慢通道)。
//
// 为什么是「音频+文本」一起发,而不是只发文本:
// 2026-09-09 在真实录音上把三条路都测了 ——
//   本地 qwen2.5:7b 纯文本   1.6s/句,166 句只改对 4 处,且会把对的改错(GPT→GGT、删掉口语里的粗话)
//   云端 gemini-3.8-flash 纯文本 12.1s/块,质量好但输出 1200 token 全是推理,约 $0.56/小时
//   云端 gemini-2.5-flash-lite 带音频  2.5s/块,输出 20 token,约 $0.012/小时,质量最好
// 差距的根源是纯文本模型「听不见」,只能靠语境猜;带音频的模型能直接核对读音。
// 实测它修出了 Apple 和 whisper 都失败的词:日语的同音专业词、中文「陪本专腰喝→赔本赚吆喝」、
// 英语被拆开的复合词。
//
// 模型选型也是实测定的:gemini-3.1-flash-lite 更快但**过度纠正** ——
// 它被上下文里的专业术语带偏,把本来正确的商业用语改成了另一个领域的词。
// 2.5-flash-lite 保守得多,只动真错的地方,所以选它。
//
// 触发时机按**句子**走,不按固定秒数:快通道每次定稿本身就是音频里的一次停顿,
// 那才是天然切点。切在句中会让模型听到半个词,也会和未被替换的实时行重复
// (whisper 那层为此踩过两次)。实测 12s 块和 42s 块都能修出那个同音词,
// 所以宁可切短、早点出结果,不必攒长。
import Foundation

struct CloudFix { let wrong: String; let right: String }

/// 云端那层怎么用模型。
/// 2026-09-09 实测:同一段日语,纠错模式看着 Apple 的「自自制」只能往旁边猜(出「自家製」「自生」),
/// 重转写模式没被错误锚住,直接听出了那个所有引擎都认错的同音专业词。
/// 所以默认重转写;纠错模式保守(只准逐字替换)但天花板低,留作可选。
enum CloudMode: String { case fix, rewrite }

final class CloudCorrector {
    /// 纠错模式:按 fixes 改写 ids 这几行(不再按时间窗"相交"取行)。
    var onFixes: ((_ ids: [Int], _ fixes: [CloudFix]) -> Void)?
    /// 重转写模式:用整段新文本替换 ids 这几行。
    /// **必须按 ID 而不是时间窗** —— 评审指出:请求音频会向后多取 0.3s,
    /// 而那期间到达的下一句 entry 会与时间窗相交、被整行替换掉,
    /// 但云端只听到它前 0.3 秒,内容就此丢失。
    var onRewrite: ((_ ids: [Int], _ text: String) -> Void)?
    var mode: CloudMode = .rewrite
    var onStatus: ((String) -> Void)?

    /// 攒够这么久就算没遇到停顿也发(有人长篇大论时不能无限等)
    let maxSec: Double
    /// 不足这么久且没遇到停顿就继续攒(避免为一句「嗯」单独调一次 API)
    let minSec: Double
    /// 句间停顿超过这个值 = 一段话说完/换人说,把攒着的立刻发出去
    let gapSec: Double

    private struct Pending { let id: Int; let text: String; let from: Double; let until: Double
                             let locale: String; let conf: Double }
    private var pending: [Pending] = []
    private var busy = false
    private var stopped = true
    /// busy/pending/prevText 会被主线程(enqueue/tick/start/stop)和 URLSession 回调同时改,
    /// 没锁就是竞态(评审指出)。UI 回调跳主线程并不保护这些内部状态。
    private let lock = Lock()
    /// 停止时若还有请求在飞,等它回来再把尾巴强制发掉
    private var flushOnIdle = false
    private weak var tape: TapeRecorder?
    private var apiKey = ""
    private var model = "google/gemini-2.5-flash-lite"
    /// 当前识别语种(从快通道来)。只用来在提示词里定住语言,**不传任何文本** ——
    /// 传文本会被模型原样复述;完全不给语言提示,它又会把日语用汉字音译
    /// (2026-09-11 实测出现「啊啦那那卡 搜诺 尅可哦」)。给语种是唯一安全的中间点。
    var localeHint = ""
    /// 上一块的文本,作为上文一起发出去(只发文本,不发上一块的音频)
    private var prevText = ""
    private(set) var calls = 0
    private(set) var tokensIn = 0
    private(set) var tokensOut = 0
    private(set) var lastError = ""

    /// minSec 从 4 降到 2.5:用户要更快。代价是调用次数多一点,
    /// 但一小时也就一美分量级,不值得为省这个牺牲反应速度。
    init(minSec: Double = 2.5, maxSec: Double = 20, gapSec: Double = 0.8) {
        self.minSec = minSec; self.maxSec = maxSec; self.gapSec = gapSec
    }

    var configured: Bool { !apiKey.isEmpty }

    func start(tape t: TapeRecorder, key: String, model m: String) {
        lock.withLock {
            stopped = false; apiKey = key; busy = false; flushOnIdle = false
            pending = []; prevText = ""; calls = 0; tokensIn = 0; tokensOut = 0; lastError = ""
        }
        tape = t
        if !m.isEmpty { model = m }
        alog("cloud correct: 启用 \(model) 句驱动 min=\(Int(minSec))s max=\(Int(maxSec))s gap=\(gapSec)s")
    }
    func stop() {
        let busyNow: Bool = lock.withLock { stopped = true; flushOnIdle = busy; return busy }
        if !busyNow { flush(force: true) }   // 不忙就直接把尾巴发掉
        // 忙的话由回调里的 flushOnIdle 接手 —— 原来只调普通 flush(),
        // 不足 minSec 的尾巴会永远留下(评审指出)
    }

    /// 快通道每定稿一句就喂进来。什么时候发由这里决定。
    /// 快通道每定稿一句就喂进来。什么时候真的发由这里决定。
    /// 全程持锁,决定完再在锁外调 flush —— 锁内调 flush 会重入同一把锁。
    /// locale/conf = 这句在快通道里胜出的语种和它的置信度(只跑一路语种时由调用方传 1.0)
    func enqueue(id: Int, text: String, from: Double, until: Double, locale: String, conf: Double) {
        enum Act { case none, flushThenAdd, addThenFlush }
        let act: Act = lock.withLock {
            guard !apiKey.isEmpty, !stopped else { return .none }
            // 和上一句之间的停顿 —— 这是「一段话说完了」最可靠的信号
            if let last = pending.last, from - last.until >= gapSec, span() >= minSec {
                return .flushThenAdd
            }
            pending.append(Pending(id: id, text: text, from: from, until: until, locale: locale, conf: conf))
            return span() >= maxSec ? .addThenFlush : .none    // 有人一直说,不能无限等
        }
        switch act {
        case .none: return
        case .addThenFlush: flush()
        case .flushThenAdd:
            flush()
            lock.withLock { pending.append(Pending(id: id, text: text, from: from, until: until, locale: locale, conf: conf)) }
        }
    }

    private func span() -> Double {
        guard let a = pending.first, let b = pending.last else { return 0 }
        return max(0, b.until - a.from)
    }

    /// 把攒着的这批连音频一起发出去。
    func flush(force: Bool = false) {
        guard let tape else { return }
        let batch: [Pending] = lock.withLock {
            guard !busy, !pending.isEmpty, !apiKey.isEmpty else { return [] }
            if !force && span() < minSec { return [] }
            let b = pending; pending = []; busy = true
            return b
        }
        guard !batch.isEmpty else { return }
        let from = batch.first!.from
        let to = min(tape.seconds, batch.last!.until + 0.3)   // 尾巴多带一点,别把最后一个字切掉
        guard to > from, let wav = tape.slice(from: from, to: to) else {
            lock.withLock { busy = false }; return
        }
        let asr = batch.map { $0.text }.joined(separator: "\n")
        let ctx = lock.withLock { prevText }
        let ids = batch.map { $0.id }
        let reqMode = mode          // 请求时固定住:期间用户切模式,回来时不能按新 mode 解析
        let hint = cloudLangHint(batch.map { ($0.locale, $0.conf) })
        if hint.isEmpty { alog("cloud: 语种没把握 \(batch.map { "\($0.locale)=\(String(format: "%.2f", $0.conf))" }),不给提示") }
        send(wav: wav, asr: asr, ctx: ctx, mode: reqMode, hint: hint) { [weak self] content, err in
            guard let self else { return }
            let wantTailFlush: Bool = self.lock.withLock {
                self.busy = false
                let f = self.flushOnIdle; self.flushOnIdle = false; return f
            }
            if let err { self.lastError = err; alog("cloud correct 失败: \(err)") }
            if let content, !content.isEmpty {
                switch reqMode {
                case .fix:
                    self.lock.withLock { self.prevText = asr }
                    let fixes = CloudCorrector.parse(content)
                    if !fixes.isEmpty { self.onFixes?(ids, fixes) }
                case .rewrite:
                    let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
                    // 重转写太短(明显没听出东西)就不覆盖,免得把实时结果冲没了
                    if t.count >= max(2, asr.count / 4) {
                        self.prevText = t
                        self.onRewrite?(ids, t)
                    } else { self.prevText = asr }
                }
            } else { self.prevText = asr }
            self.flush(force: wantTailFlush)       // 期间又攒了新的就接着发;停止时强制发尾巴
        }
    }

    /// 定时兜底:说话人停下来之后 pending 里还剩东西,不能一直挂着。
    func tickIdle(now: Double) {
        let due: Bool = lock.withLock {
            guard !busy, let last = pending.last else { return false }
            return now - last.until >= gapSec * 2
        }
        if due { flush(force: true) }
    }

    private func prompt(asr: String, ctx: String, mode: CloudMode, hint: String) -> String {
        if mode == .rewrite {
            let langLine: String
            // hint 是「这一批句子」自己的语种,且只有全部高置信才非空(见 cloudLangHint)。
            // 早先用全局 localeHint:它跟着每次语种切换跳,发送时拿到的常是别的句子的判断。
            switch hint {
            // ★提示只是参考,绝不能凌驾于"听到什么写什么" ——
            // 2026-09-13 实测:语种判错成中文后,这句把模型指使去**把英语翻译成了中文**,
            // 整份记录变成了译文。必须写明冲突时以录音为准。
            case let l where l.hasPrefix("ja"): langLine = "（参考：可能是日语。）"
            case let l where l.hasPrefix("zh"): langLine = "（参考：可能是中文。）"
            case let l where l.hasPrefix("en"): langLine = "（参考：可能是英语。）"
            case "": langLine = ""
            default:   // 其他语种(韩/粤/法/德…):用系统本地化的语言名
                let code = String(hint.prefix { $0 != "-" })
                let name = Locale(identifier: "zh-Hans").localizedString(forLanguageCode: code) ?? code
                langLine = "（参考：可能是\(name)。）"
            }
            let p = """
            请把这段录音逐字转写成文字。
            **用录音里实际说的那种语言书写。绝对不要翻译成别的语言，也不要音译成别的文字系统。**
            如果下面的参考与你实际听到的语言不符，一律以你听到的为准。
            \(langLine)
            - 保留口语原样:语气词(えっと/あの/嗯/那个)、重复、口吃、脏话**都要保留**,不要润色成书面语。
            - 不要翻译,说什么语言就写什么语言。
            - 不要加说话人标签、时间戳或任何解释,只输出转写文本本身。
            """
            // ★不要附上 ASR 文本或前文。
            // 2026-09-11 实测:附了之后模型会把参考文本**原样复述一遍**再接自己的转写,
            // 结果每句都出现两次。离线验证成功的那版就是只给音频+指令,保持一致。
            // 代价是它看不到上文里的专有名词,但正确性优先。
            return p
        }
        var p = """
        这是一段对话录音，以及自动语音识别(ASR)的结果。ASR 有同音字/近音词错误。
        请**听录音**，把 ASR 结果里听错的字改对。
        规则：
        - 只改用字。不改语序、不改口语风格、**不要删语气词和脏话**、不要补充没说过的内容、不要润色。
        - 只改你在录音里确实听出来不一样的地方。原文没错就不要动 —— 宁可漏改，不可错改。
        - "wrong" 必须是 ASR 结果里逐字存在的子串，且尽量短。
        - 只输出 JSON：{"fixes":[{"wrong":"...","right":"..."}]}，没有要改的就 {"fixes":[]}
        """
        if !ctx.isEmpty { p += "\n\n【上文（仅供理解，不要改）】\n" + String(ctx.suffix(300)) }
        p += "\n\n【ASR 结果】\n" + asr
        return p
    }

    private func send(wav: Data, asr: String, ctx: String, mode: CloudMode, hint: String,
                      done: @escaping (String?, String?) -> Void) {
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": prompt(asr: asr, ctx: ctx, mode: mode, hint: hint)],
                    ["type": "input_audio",
                     "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]],
                ],
            ]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            done(nil, "请求构造失败"); return
        }
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 90
        URLSession.shared.dataTask(with: req) { [weak self] d, _, err in
            guard let self else { return }
            if let err { done(nil, err.localizedDescription); return }
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                done(nil, "响应不是 JSON"); return
            }
            if let e = j["error"] as? [String: Any] {
                done(nil, (e["message"] as? String) ?? "未知错误"); return
            }
            self.lock.withLock {
                if let u = j["usage"] as? [String: Any] {
                    self.tokensIn += (u["prompt_tokens"] as? Int) ?? 0
                    self.tokensOut += (u["completion_tokens"] as? Int) ?? 0
                }
                self.calls += 1
            }
            guard let ch = (j["choices"] as? [[String: Any]])?.first,
                  let msg = ch["message"] as? [String: Any],
                  let content = msg["content"] as? String else { done(nil, "没有内容"); return }
            done(content, nil)
        }.resume()
    }

    /// 拿一小段音频问云端「这是什么语言」。
    ///
    /// 为什么不靠三路识别器互相比:2026-09-13 实测,在很轻的音频上(rms≈0.002)
    /// en/zh 要在**语音开始后 17 秒**才吐第一个字,而 ja 在静音区就幻觉出内容。
    /// 想等齐三路就得等 20+ 秒 —— 开头 20 秒没字幕不可接受。
    /// 云端听一遍 2~3 秒就有答案,还准得多。
    func detectLanguage(wav: Data, done: @escaping (String?) -> Void) {
        let key = lock.withLock { apiKey }
        guard !key.isEmpty else { done(nil); return }
        // 只问语言容易判错(实测把英语判成了 zh)。让它同时抄一句原话,
        // 上层就能用"这句原话是什么文字"来交叉验证语种。
        let p = """
        这段录音主要是什么语言?并抄写你听到的第一句话(用录音里实际说的语言原样写)。
        只输出 JSON: {"lang":"ja|en|zh|other","sample":"..."}
        """
        let body: [String: Any] = [
            "model": model, "temperature": 0, "max_tokens": 8,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": p],
                ["type": "input_audio", "input_audio": ["data": wav.base64EncodedString(), "format": "wav"]],
            ]]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { done(nil); return }
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = data
        req.timeoutInterval = 45
        URLSession.shared.dataTask(with: req) { d, _, _ in
            guard let d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ch = (j["choices"] as? [[String: Any]])?.first,
                  let m = ch["message"] as? [String: Any],
                  let t = m["content"] as? String else { done(nil); return }
            // 解析 JSON;拿 sample 的文字系统交叉验证 lang,不一致就以 sample 为准
            var lang = ""
            var sample = ""
            if let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b,
               let d2 = String(t[a...b]).data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d2) as? [String: Any] {
                lang = ((o["lang"] as? String) ?? "").lowercased()
                sample = (o["sample"] as? String) ?? ""
            } else { lang = t.lowercased() }
            let byScript = CloudCorrector.scriptOf(sample)
            var pick: String? = lang.contains("ja") ? "ja-JP" : lang.contains("zh") ? "zh-CN"
                              : lang.contains("en") ? "en-US" : nil
            if let s2 = byScript, s2 != pick {
                alog("判语种冲突:模型说 \(lang) 但样句像 \(s2),以样句为准 — \(sample.prefix(40))")
                pick = s2
            }
            done(pick)
        }.resume()
    }

    /// 按文字系统粗判语种:有假名=日语,纯汉字=中文,拉丁字母占多数=英语。
    static func scriptOf(_ s: String) -> String? {
        guard !s.isEmpty else { return nil }
        var kana = 0, han = 0, latin = 0
        for u in s.unicodeScalars {
            switch u.value {
            case 0x3040...0x30FF: kana += 1
            case 0x4E00...0x9FFF: han += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if kana >= 2 { return "ja-JP" }
        if latin > (han + kana) * 2 && latin >= 6 { return "en-US" }
        if han >= 3 && latin < han { return "zh-CN" }
        return nil
    }

    /// 从回复里抠出 fixes。模型有时会用 ```json 包起来,所以取第一个 { 到最后一个 }。
    static func parse(_ s: String) -> [CloudFix] {
        guard let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b else { return [] }
        let json = String(s[a...b])
        guard let d = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let arr = o["fixes"] as? [[String: Any]] else { return [] }
        return arr.compactMap {
            guard let w = $0["wrong"] as? String, let r = $0["right"] as? String,
                  !w.isEmpty, !r.isEmpty, w != r else { return nil }
            return CloudFix(wrong: w, right: r)
        }
    }
}

/// 一批句子该不该给云端语种提示。口音英语时三路置信度只有 0.5~0.7、语种逐句乱跳
/// (2026-09-24 实测),这时给「可能是日语」会把英语改写成「えっと、あの、ええ」。
/// 规则:同一语种 + 每句置信度 ≥ 0.85 才给;否则空串 = 不给提示,让模型按听到的写。
/// 0.85 的依据:正确路常 0.92~0.98,错误路最高 0.81(2026-09-13 实测)。conf<0 = 没有置信度,当没把握。
func cloudLangHint(_ items: [(String, Double)]) -> String {
    guard let first = items.first?.0, !first.isEmpty else { return "" }
    for (loc, conf) in items where loc != first || conf < 0.85 { return "" }
    return first
}
