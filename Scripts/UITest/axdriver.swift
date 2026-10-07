import AppKit
import ApplicationServices
import Carbon.HIToolbox
setvbuf(stdout, nil, _IONBF, 0)

// Accessibility driver for Roger. Commands:
//   dump | texts | buttons | find <needle> | exists <needle> | wait <needle> <s> | waitgone <needle> <s>
//   type <text> (composer + return) | typeinto <field> <text> | setvalue <field> <text> | press <needle>
//   key <combo> | menu model|<popup> <item> | select <row text> | scrollup [ticks] | scrollhid [ticks]
//   scrollfirst | chattexts | keycodes | value <needle>
func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ name: String) -> String {
    guard let v = attr(el, name) else { return "" }
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return ""
}
func children(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func point(_ el: AXUIElement, _ name: String) -> CGPoint? {
    guard let v = attr(el, name) else { return nil }
    var p = CGPoint.zero
    return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
}
func size(_ el: AXUIElement) -> CGSize? {
    guard let v = attr(el, kAXSizeAttribute) else { return nil }
    var s = CGSize.zero
    return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
}
struct Node { var el: AXUIElement; var role: String; var title: String; var desc: String; var value: String; var depth: Int; var placeholder: String }
func walk(_ el: AXUIElement, _ depth: Int, _ out: inout [Node], max: Int = 40) {
    let role = str(el, kAXRoleAttribute)
    var value = str(el, kAXValueAttribute)
    if value.count > 160 { value = String(value.prefix(160)) + "…" }
    out.append(Node(el: el, role: role, title: str(el, kAXTitleAttribute), desc: str(el, kAXDescriptionAttribute), value: value, depth: depth, placeholder: str(el, kAXPlaceholderValueAttribute)))
    if depth < max { for c in children(el) { walk(c, depth + 1, &out) } }
}
// Wait up to 30 s for the app and its window (it may still be launching).
var foundApp: NSRunningApplication?
var foundWindow: AXUIElement?
for _ in 0..<60 {
    if let a = NSRunningApplication.runningApplications(withBundleIdentifier: "com.mathieu.Roger").first {
        foundApp = a
        if let w = (attr(AXUIElementCreateApplication(a.processIdentifier), kAXWindowsAttribute) as? [AXUIElement])?.first { foundWindow = w; break }
    }
    usleep(500_000)
}
guard let app = foundApp else { print("Roger not running"); exit(2) }
let axApp = AXUIElementCreateApplication(app.processIdentifier)
guard let window = foundWindow else { print("no window"); exit(2) }
var nodes: [Node] = []
walk(window, 0, &nodes)
let args = CommandLine.arguments.dropFirst()
let cmd = args.first ?? "dump"

func matches(_ n: Node, _ needle: String) -> Bool {
    let q = needle.lowercased()
    return n.title.lowercased().contains(q) || n.desc.lowercased().contains(q) || n.value.lowercased().contains(q) || n.placeholder.lowercased().contains(q)
}
func activate() { app.activate(options: [.activateIgnoringOtherApps]); usleep(300_000) }
func rewalk() -> [Node] { var n: [Node] = []; walk(window, 0, &n); return n }
/// The chat's own scroll view: shallowest scroll area without the sidebar outline (code blocks nest their own).
func chatArea() -> Node? {
    let candidates = nodes.filter { $0.role == "AXScrollArea" && !children($0.el).contains { str($0, kAXRoleAttribute) == "AXOutline" } }
    guard let minDepth = candidates.map(\.depth).min() else { return nil }
    return candidates.first { $0.depth == minDepth }
}
func chatTexts() -> [String] {
    guard let chat = chatArea() else { return [] }
    var inside: [Node] = []
    walk(chat.el, 0, &inside)
    return inside.filter { $0.role == "AXStaticText" && $0.value.count > 3 }.map { String($0.value.prefix(50)) }
}
/// Key (and whether Shift is needed) producing a character in the current keyboard layout.
func keyCode(for char: Character) -> (code: CGKeyCode, shift: Bool)? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    let target = String(char).lowercased()
    return data.withUnsafeBytes { raw -> (CGKeyCode, Bool)? in
        guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
        for (modifiers, shift) in [(UInt32(0), false), (UInt32((shiftKey >> 8) & 0xFF), true)] {
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let err = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
                if err == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == target { return (CGKeyCode(code), shift) }
            }
        }
        return nil
    }
}
func typeText(_ text: String) {
    let src = CGEventSource(stateID: .combinedSessionState)
    let utf16 = Array(text.utf16)
    for start in stride(from: 0, to: utf16.count, by: 16) {
        var units = Array(utf16[start..<min(start + 16, utf16.count)])
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)!
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.postToPid(app.processIdentifier)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)!
        up.postToPid(app.processIdentifier)
        usleep(15_000)
    }
}
/// Layout-aware shortcut: "cmd+n", "cmd+shift+n", "return", "escape", "delete", "down"…
func key(_ combo: String) {
    activate()
    let parts = combo.lowercased().split(separator: "+").map(String.init)
    var flags: CGEventFlags = []
    let keyName = parts.last ?? ""
    for p in parts.dropLast() { switch p { case "cmd": flags.insert(.maskCommand); case "shift": flags.insert(.maskShift); case "alt", "opt": flags.insert(.maskAlternate); case "ctrl": flags.insert(.maskControl); default: break } }
    let special: [String: CGKeyCode] = ["return": 36, "enter": 36, "escape": 53, "esc": 53, "tab": 48, "space": 49, "up": 126, "down": 125, "delete": 51]
    var code: CGKeyCode
    if let s = special[keyName] { code = s } else {
        guard keyName.count == 1, let found = keyCode(for: keyName.first!) else { print("unknown key \(keyName)"); exit(1) }
        code = found.code
        if found.shift { flags.insert(.maskShift) }
    }
    let src = CGEventSource(stateID: .combinedSessionState)
    let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!; down.flags = flags
    let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!; up.flags = flags
    down.postToPid(app.processIdentifier); usleep(30_000); up.postToPid(app.processIdentifier)
}
func field(_ needle: String) -> Node? {
    nodes.first { ($0.role == "AXTextArea" || $0.role == "AXTextField") && matches($0, needle) }
}
func clearAndType(_ f: Node, _ text: String) {
    activate()
    AXUIElementSetAttributeValue(f.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    key("down"); key("down")
    let existing = str(f.el, kAXValueAttribute).count
    for _ in 0..<min(existing + 2, 300) { key("delete"); usleep(8_000) }
    if !text.isEmpty { typeText(text) }
    usleep(300_000)
}
func scrollCenter() -> CGPoint? {
    guard let chat = chatArea(), let pos = point(chat.el, kAXPositionAttribute), let sz = size(chat.el) else { return nil }
    return CGPoint(x: pos.x + sz.width / 2, y: pos.y + sz.height / 2)
}

switch cmd {
case "dump":
    print("WINDOW: \(str(window, kAXTitleAttribute))")
    for n in nodes where !(n.role == "AXGroup" && n.title.isEmpty && n.desc.isEmpty && n.value.isEmpty) {
        print(String(repeating: " ", count: n.depth) + "\(n.role) | \(n.title) | \(n.desc) | \(n.value)\(n.placeholder.isEmpty ? "" : " | ph=\(n.placeholder)")")
    }
case "texts":
    for n in nodes where n.role == "AXStaticText" || n.role == "AXTextArea" || n.role == "AXTextField" { if !n.value.isEmpty { print(n.value) } }
case "buttons":
    for n in nodes where n.role == "AXButton" || n.role == "AXPopUpButton" || n.role == "AXMenuButton" { print("\(n.role) | \(n.title) | \(n.desc)") }
case "find":
    let needle = args.dropFirst().joined(separator: " ")
    for n in nodes where matches(n, needle) { print("\(n.role) | \(n.title) | \(n.desc) | \(n.value)") }
case "value":
    let needle = args.dropFirst().joined(separator: " ")
    for n in nodes where matches(n, needle) { print(n.value) }
case "exists":
    exit(nodes.contains { matches($0, args.dropFirst().joined(separator: " ")) } ? 0 : 1)
case "wait":
    let needle = String(args.dropFirst().first ?? ""); let timeout = Int(args.dropFirst(2).first ?? "60") ?? 60
    for _ in 0..<timeout { if rewalk().contains(where: { matches($0, needle) }) { print("found \(needle)"); exit(0) }; sleep(1) }
    print("timeout waiting for \(needle)"); exit(1)
case "waitgone":
    let needle = String(args.dropFirst().first ?? ""); let timeout = Int(args.dropFirst(2).first ?? "60") ?? 60
    for _ in 0..<timeout { if !rewalk().contains(where: { matches($0, needle) }) { print("gone \(needle)"); exit(0) }; sleep(1) }
    print("timeout waiting for \(needle) to go away"); exit(1)
case "type":
    let text = args.dropFirst().joined(separator: " ")
    guard let f = nodes.first(where: { ($0.role == "AXTextArea" || $0.role == "AXTextField") && $0.placeholder.contains("Message Roger") }) else { print("composer not found"); exit(1) }
    activate()
    AXUIElementSetAttributeValue(f.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    usleep(150_000)
    typeText(text)
    usleep(300_000)
    print("typed \(str(f.el, kAXValueAttribute).count)/\(text.count) chars")
    key("return")
case "typeinto":
    let needle = String(args.dropFirst().first ?? ""); let text = args.dropFirst(2).joined(separator: " ")
    guard let f = field(needle) else { print("field not found"); exit(1) }
    clearAndType(f, text)
    print("field now: \(str(f.el, kAXValueAttribute))")
case "setvalue":
    let needle = String(args.dropFirst().first ?? ""); let text = args.dropFirst(2).joined(separator: " ")
    guard let f = field(needle) else { print("field not found"); exit(1) }
    AXUIElementSetAttributeValue(f.el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    print("set: \(AXUIElementSetAttributeValue(f.el, kAXValueAttribute as CFString, text as CFString) == .success)")
case "press":
    let needle = args.dropFirst().joined(separator: " ")
    guard let b = nodes.first(where: { ($0.role == "AXButton" || $0.role == "AXMenuButton" || $0.role == "AXRow" || $0.role == "AXMenuItem") && matches($0, needle) }) else { print("button not found: \(needle)"); exit(1) }
    activate()
    print("press \(b.role) '\(b.title.isEmpty ? b.desc : b.title)': \(AXUIElementPerformAction(b.el, kAXPressAction as CFString) == .success)")
case "key":
    key(args.dropFirst().joined()); print("sent \(args.dropFirst().joined())")
case "menu":
    let popupNeedle = String(args.dropFirst().first ?? ""); let itemNeedle = args.dropFirst(2).joined(separator: " ")
    guard let popup = nodes.first(where: { $0.role == "AXPopUpButton" && (popupNeedle == "model" ? ($0.value.contains(":") || $0.value.contains("/")) : matches($0, popupNeedle)) }) else { print("popup not found"); exit(1) }
    activate()
    AXUIElementPerformAction(popup.el, kAXPressAction as CFString)
    usleep(600_000)
    var items: [Node] = []
    walk(popup.el, 0, &items)
    if items.count < 3 { items = []; walk(axApp, 0, &items) }
    guard let item = items.first(where: { $0.role == "AXMenuItem" && matches($0, itemNeedle) }) else {
        print("menu item not found: \(itemNeedle); items: \(items.filter { $0.role == "AXMenuItem" }.map(\.title))"); key("escape"); exit(1)
    }
    print("choose '\(item.title)': \(AXUIElementPerformAction(item.el, kAXPressAction as CFString) == .success)")
case "select":
    let needle = args.dropFirst().joined(separator: " ")
    guard let row = nodes.filter({ $0.role == "AXRow" }).first(where: { r in var inside: [Node] = []; walk(r.el, 0, &inside); return inside.contains { $0.role == "AXStaticText" && matches($0, needle) } }) else { print("row not found: \(needle)"); exit(1) }
    activate()
    var r = AXUIElementSetAttributeValue(row.el, kAXSelectedAttribute as CFString, kCFBooleanTrue)
    if r != .success { r = AXUIElementPerformAction(row.el, kAXPressAction as CFString) }
    print("select '\(needle)': \(r == .success ? "ok" : "error \(r.rawValue)")")
case "scrollup", "scrollhid":
    let ticks = Int(args.dropFirst().first ?? "20") ?? 20
    guard let center = scrollCenter() else { print("chat scroll area not found"); exit(1) }
    activate()
    let saved = NSEvent.mouseLocation
    if cmd == "scrollhid" { CGWarpMouseCursorPosition(center); usleep(100_000) }
    for _ in 0..<ticks {
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 5, wheel2: 0, wheel3: 0)!
        e.location = center
        if cmd == "scrollhid" { e.post(tap: .cghidEventTap) } else { e.postToPid(app.processIdentifier) }
        usleep(25_000)
    }
    if cmd == "scrollhid", let screen = NSScreen.screens.first { CGWarpMouseCursorPosition(CGPoint(x: saved.x, y: screen.frame.height - saved.y)) }
    print("\(cmd) \(ticks) ticks at \(Int(center.x)),\(Int(center.y))")
case "scrollfirst":
    guard let chat = chatArea() else { print("chat scroll area not found"); exit(1) }
    var inside: [Node] = []
    walk(chat.el, 0, &inside)
    guard let first = inside.first(where: { $0.role == "AXStaticText" && $0.value.count > 3 }) else { print("no text in chat"); exit(1) }
    print("scroll to '\(first.value.prefix(40))': \(AXUIElementPerformAction(first.el, "AXScrollToVisible" as CFString) == .success)")
case "chattexts":
    let t = chatTexts()
    print("\(t.count) texts; first: \(t.first ?? "-") | last: \(t.last ?? "-")")
case "keycodes":
    for c in ["a", "n", "f", "q", ".", "m", "w"] { print(c, keyCode(for: Character(c)).map { "code \($0.code) shift \($0.shift)" } ?? "none") }
default:
    print("unknown command \(cmd)")
}
