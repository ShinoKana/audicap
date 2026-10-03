// 文字系统判定的单元测试(多文件编译时顶层代码只能在 main.swift):
//   awk '/^\/\/ MARK: script-family/,0' Recognizer.swift > /tmp/fn.swift; cp tests/test_script.swift /tmp/main.swift; swiftc -o /tmp/t /tmp/main.swift /tmp/fn.swift && /tmp/t
// 背景:旧的 scriptOf 把所有拉丁字母都当成 en-US,开法语/德语路后这些路的结果会被当成「文字不符」扣 0.25(2026-09-25)。
import Foundation
var failures = 0
func check(_ got: Bool?, _ want: Bool?, _ name: String) {
    print(got == want ? "PASS" : "FAIL", name, "got=\(String(describing: got)) want=\(String(describing: want))")
    if got != want { failures += 1 }
}
// 新增语种:不能被误扣
check(scriptMatches("Le train part à huit heures demain matin", "fr-FR"), true, "法语在法语路")
check(scriptMatches("Der Zug fährt morgen um acht Uhr ab", "de-CH"), true, "德语在德语路(地区码不同)")
check(scriptMatches("내일 아침 여덟 시에 기차가 출발합니다", "ko-KR"), true, "韩语在韩语路")
check(scriptMatches("聽日朝早八點鐘班車開出", "yue-CN"), true, "粤语在粤语路")
check(scriptMatches("明天早上八點火車會準時出發", "zh-TW"), true, "繁中在繁中路")
// 该扣的照样扣
check(scriptMatches("내일 아침 여덟 시에 기차가 출발합니다", "ja-JP"), false, "韩文出在日语路")
check(scriptMatches("おこの人人中国でと人気るじ", "zh-CN"), false, "假名出在中文路(09-13 实测乱码)")
// 日中英原有行为不变
check(scriptMatches("明日の朝八時に電車が出発します", "ja-JP"), true, "日语")
check(scriptMatches("变更日始温度很高", "ja-JP"), false, "无假名长句在日语路(09-13 实测误判)")
check(scriptMatches("明天早上八点火车会准时出发", "zh-CN"), true, "中文")
check(scriptMatches("The train leaves at eight tomorrow morning", "en-US"), true, "英语")
check(scriptMatches("The train leaves at eight tomorrow morning", "zh-CN"), false, "英文出在中文路")
check(scriptMatches("OK", "en-US"), nil, "太短判断不了")
if failures > 0 { print("\(failures) failed"); exit(1) }
print("all passed")
