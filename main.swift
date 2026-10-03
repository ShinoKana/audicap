// 入口。Swift 只允许 main.swift 里有顶层语句,所以拆出来
// (识别层 Recognizer.swift 独立成文件后,AudicapApp.swift 就不能再放顶层代码了)。
import Cocoa

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 无 Dock 图标;菜单栏 NSStatusItem 是唯一常驻入口
app.run()
