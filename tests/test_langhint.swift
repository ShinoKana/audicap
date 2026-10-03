// cloudLangHint 的单元测试(多文件编译时顶层代码只能在 main.swift):
//   awk "/^func cloudLangHint/,/^}/" CloudCorrect.swift > /tmp/fn.swift; cp tests/test_langhint.swift /tmp/main.swift; swiftc -o /tmp/t /tmp/main.swift /tmp/fn.swift && /tmp/t
import Foundation
// 用例取自 2026-09-24 的实测日志(带口音英语,三路置信度 0.5~0.7 来回跳)
func check(_ got: String, _ want: String, _ name: String) {
    print(got == want ? "PASS" : "FAIL", name, "got=\(got.debugDescription) want=\(want.debugDescription)")
    if got != want { failures += 1 }
}
var failures = 0
// 今天的真实情况:口音英语被判成 ja/zh,置信度 0.56~0.66 → 不给提示
check(cloudLangHint([("ja-JP", 0.56)]), "", "口音英语被低置信判成 ja")
check(cloudLangHint([("zh-CN", 0.66), ("ja-JP", 0.62)]), "", "一段里语种不一致")
// 错误路最高 0.81(09-13 实测)→ 仍不给
check(cloudLangHint([("ja-JP", 0.81)]), "", "错误路上限 0.81")
// 正确路常 0.92~0.98 → 给
check(cloudLangHint([("ja-JP", 0.95), ("ja-JP", 0.92)]), "ja-JP", "整段高置信同语种")
check(cloudLangHint([("en-US", 0.97), ("en-US", 0.60)]), "", "一句不够把握就整段不给")
check(cloudLangHint([("zh-CN", 0.93), ("en-US", 0.95)]), "", "高置信但混语种")
check(cloudLangHint([]), "", "空")
// conf<0 = 该 locale 没有置信度 → 当作没把握
check(cloudLangHint([("en-US", -1)]), "", "无置信度")
if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
