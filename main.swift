// space-arrange: move macOS Spaces between displays by dragging their
// Mission Control thumbnails, driven by app → display rules.
import Cocoa
import ApplicationServices

// MARK: - SkyLight (private)
let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)!
typealias MainConnFn = @convention(c) () -> Int32
typealias CopyMDSFn = @convention(c) (Int32) -> Unmanaged<CFArray>
typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>
let conn = unsafeBitCast(dlsym(sky, "SLSMainConnectionID"), to: MainConnFn.self)()
let copyManagedDisplaySpaces = unsafeBitCast(dlsym(sky, "SLSCopyManagedDisplaySpaces"), to: CopyMDSFn.self)
let copySpacesForWindows = unsafeBitCast(dlsym(sky, "SLSCopySpacesForWindows"), to: CopySpacesForWindowsFn.self)
typealias WindowIsOrderedInFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Bool>) -> Int32
let windowIsOrderedIn = unsafeBitCast(dlsym(sky, "SLSWindowIsOrderedIn"), to: WindowIsOrderedInFn.self)
func isOrderedIn(_ wid: Int) -> Bool { var b = false; return windowIsOrderedIn(conn, UInt32(wid), &b) == 0 && b }

struct Space { let id: Int; let type: Int }
struct ManagedDisplay { let uuid: String; let spaces: [Space] }
func managedDisplays() -> [ManagedDisplay] {
    let arr = copyManagedDisplaySpaces(conn).takeRetainedValue() as! [[String: Any]]
    return arr.map { d in
        ManagedDisplay(uuid: d["Display Identifier"] as! String,
                       spaces: (d["Spaces"] as! [[String: Any]]).map { Space(id: $0["ManagedSpaceID"] as! Int, type: $0["type"] as! Int) })
    }
}

// MARK: - Screens
struct Screen { let uuid: String; let name: String; let frame: CGRect; let work: CGRect; let pixels: Double; let builtin: Bool; var role: String } // frames in top-left global coords (AX/CGEvent)
/// Roles: "builtin" for the internal display, "external:1" for the largest external (by pixel count), "external:2" the next, ...
func screens() -> [Screen] {
    let primaryH = NSScreen.screens[0].frame.height
    var list = NSScreen.screens.map { s -> Screen in
        let did = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! CGDirectDisplayID
        let uuid = CFUUIDCreateString(nil, CGDisplayCreateUUIDFromDisplayID(did)!.takeRetainedValue())! as String
        let f = s.frame, v = s.visibleFrame
        return Screen(uuid: uuid, name: s.localizedName, frame: CGRect(x: f.minX, y: primaryH - f.maxY, width: f.width, height: f.height),
                      work: CGRect(x: v.minX, y: primaryH - v.maxY, width: v.width, height: v.height),
                      pixels: Double(CGDisplayPixelsWide(did) * CGDisplayPixelsHigh(did)), builtin: CGDisplayIsBuiltin(did) != 0, role: "")
    }
    var rank = 0
    for i in list.indices.sorted(by: { list[$0].pixels > list[$1].pixels }) {
        if list[i].builtin { list[i].role = "builtin" } else { rank += 1; list[i].role = "external:\(rank)" }
    }
    return list
}
/// A rule target is a role ("builtin", "external:N") or a literal display name.
func resolve(_ target: String, in screens: [Screen]) -> Screen? { screens.first { $0.role == target } ?? screens.first { $0.name == target } }

// MARK: - Windows per space
struct Win { let id: Int; let pid: pid_t; let owner: String; let area: Int }
func windowsPerSpace() -> [Int: [Win]] {
    let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
    var out: [Int: [Win]] = [:]
    for w in list {
        guard (w["kCGWindowLayer"] as? Int) == 0, let b = w["kCGWindowBounds"] as? [String: Any],
              let width = b["Width"] as? Double, let height = b["Height"] as? Double, width >= 200, height >= 100,
              let owner = w["kCGWindowOwnerName"] as? String, let wid = w["kCGWindowNumber"] as? Int, let pid = w["kCGWindowOwnerPID"] as? pid_t else { continue }
        guard isOrderedIn(wid) else { continue }
        let spaces = copySpacesForWindows(conn, 7, [wid] as CFArray).takeRetainedValue() as! [Int]
        for s in spaces { out[s, default: []].append(Win(id: wid, pid: pid, owner: owner, area: Int(width * height / 1000))) }
    }
    return out
}
func appsPerSpace() -> [Int: [String: Int]] {
    var out: [Int: [String: Int]] = [:]
    for (space, wins) in windowsPerSpace() { for w in wins { out[space, default: [:]][w.owner, default: 0] += w.area } }
    return out
}

// MARK: - Config
struct Rule: Decodable { let apps: [String]; let displays: [String] }
struct Config: Decodable { let rules: [Rule]; let fallback: String? }
let configPath = NSString(string: "~/.config/space-arrange/config.json").expandingTildeInPath
func loadConfig() -> Config {
    guard let data = FileManager.default.contents(atPath: configPath) else { fail("config not found: \(configPath)") }
    do { return try JSONDecoder().decode(Config.self, from: data) } catch { fail("bad config: \(error)") }
}
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(1) }

// MARK: - AX helpers
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, n as CFString, &v); return v }
func axFrame(_ e: AXUIElement) -> CGRect { guard let v = attr(e, "AXFrame") else { return .zero }; var r = CGRect.zero; AXValueGetValue(v as! AXValue, .cgRect, &r); return r }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, "AXChildren") as? [AXUIElement]) ?? [] }
func childWithID(_ e: AXUIElement, _ id: String) -> AXUIElement? { children(e).first { (attr($0, "AXIdentifier") as? String) == id } }
struct MCDisplay { let frame: CGRect; let buttons: [CGRect]; let add: CGRect }
func readMissionControl() -> [MCDisplay] {
    var out: [MCDisplay] = []
    for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock") {
        var found: [AXUIElement] = []
        func visit(_ e: AXUIElement, _ d: Int) {
            if (attr(e, "AXIdentifier") as? String) == "mc.display" { found.append(e); return }
            if d == 0 { return }; for c in children(e) { visit(c, d - 1) }
        }
        visit(AXUIElementCreateApplication(app.processIdentifier), 4)
        for g in found {
            guard let sp = childWithID(g, "mc.spaces"), let list = childWithID(sp, "mc.spaces.list") else { continue }
            out.append(MCDisplay(frame: axFrame(g), buttons: children(list).map { axFrame($0) }, add: childWithID(sp, "mc.spaces.add").map { axFrame($0) } ?? .zero))
        }
    }
    return out
}
func near(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2 }

// MARK: - Input
let src = CGEventSource(stateID: .hidSystemState)
func mouse(_ p: CGPoint, _ type: CGEventType = .mouseMoved) { CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap) }
func key(_ k: CGKeyCode) { CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: true)!.post(tap: .cghidEventTap); CGEvent(keyboardEventSource: src, virtualKey: k, keyDown: false)!.post(tap: .cghidEventTap) }
func pause(_ s: Double) { Thread.sleep(forTimeInterval: s) }

/// Mission Control is on screen when the Dock has full-screen overlay windows up (layers 18/20); this does
/// not depend on the Dock's Accessibility tree, which can lag several seconds behind the picture.
func missionControlVisible() -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
    return list.contains { ($0["kCGWindowOwnerName"] as? String) == "Dock" && (($0["kCGWindowLayer"] as? Int) ?? -1) > 0 }
}
/// Opening Mission Control.app toggles it, so only open it when it is not already up (e.g. left over from
/// an aborted run); then wait for the Accessibility tree, and if that never shows up, close and try again.
func openMissionControl() -> Bool {
    for _ in 0..<3 {
        if !missionControlVisible() {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            for _ in 0..<30 { pause(0.1); if missionControlVisible() { break } }
        }
        guard missionControlVisible() else { continue }
        for _ in 0..<40 { pause(0.25); if readMissionControl().contains(where: { !$0.buttons.isEmpty }) { pause(0.5); return true } }
        key(53); pause(1.0)
    }
    return false
}
func closeMissionControl() { key(53); for _ in 0..<40 { pause(0.1); if !missionControlVisible() { return } } }

/// Drag the space at `index` on `fromScreen` to the end of `toScreen`'s bar. Mission Control must be open.
func dragSpace(index: Int, from fromScreen: Screen, to toScreen: Screen) -> Bool {
    mouse(CGPoint(x: fromScreen.frame.midX, y: fromScreen.frame.minY + 5)); pause(0.8) // expand the bar
    let mc = readMissionControl()
    guard let s = mc.first(where: { near($0.frame, fromScreen.frame) }), let d = mc.first(where: { near($0.frame, toScreen.frame) }),
          index < s.buttons.count, let last = d.buttons.last else { return false }
    let start = CGPoint(x: s.buttons[index].midX, y: s.buttons[index].midY)
    let target = CGPoint(x: last.maxX + 30, y: last.midY)
    mouse(start); pause(0.3)
    mouse(start, .leftMouseDown); pause(0.4)
    mouse(CGPoint(x: start.x + 4, y: start.y + 2), .leftMouseDragged); pause(0.1)
    for i in 1...60 {
        let t = CGFloat(i) / 60
        mouse(CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t), .leftMouseDragged); pause(0.02)
    }
    pause(0.6)
    // Once the drag reaches the bar, the bar re-lays out around a placeholder for the incoming space and grows
    // to the left, so the point we aimed at now sits before the real last thumbnail. Re-read the live layout
    // and move past its rightmost thumbnail before letting go, so the space lands at the very end.
    var drop = target
    if let live = mcDisplay(toScreen), let rightmost = live.buttons.map({ $0.maxX }).max() {
        drop = CGPoint(x: rightmost + 30, y: target.y)
        for i in 1...20 { let t = CGFloat(i) / 20; mouse(CGPoint(x: target.x + (drop.x - target.x) * t, y: target.y), .leftMouseDragged); pause(0.02) }
        pause(0.6)
    }
    mouse(drop, .leftMouseUp); pause(1.0)
    return true
}

// MARK: - Plan
struct Move { let space: Int; let from: Screen; let to: Screen; let apps: String }
func plan(config: Config, screens: [Screen], displays: [ManagedDisplay], apps: [Int: [String: Int]]) -> [Move] {
    // The space belongs to the app occupying the most window area in it; that app's rule decides the display.
    // Apps named in a rule win near-ties (≥ 80% of the largest window): after --fit every window has the same
    // size, and a stray Finder window must not pull a Chrome space to the fallback display.
    func target(for area: [String: Int]) -> Screen? {
        guard let top = area.values.max(), top > 0 else { return nil }
        let ruled = Set(config.rules.flatMap { $0.apps })
        let byArea = area.sorted { ($0.value, $0.key) > ($1.value, $1.key) }
        let dominant = byArea.first { ruled.contains($0.key) && $0.value * 5 >= top * 4 }?.key ?? byArea[0].key
        let rule = config.rules.first { $0.apps.contains(dominant) }
        let targets = rule?.displays ?? [config.fallback].compactMap { $0 }
        return targets.lazy.compactMap { resolve($0, in: screens) }.first
    }
    var moves: [Move] = []
    for d in displays {
        guard let from = screens.first(where: { $0.uuid == d.uuid }) else { continue }
        var remaining = d.spaces.filter { $0.type == 0 }.count
        for s in d.spaces where s.type == 0 {
            let counts = apps[s.id] ?? [:]
            guard !counts.isEmpty, let to = target(for: counts), to.uuid != from.uuid else { continue }
            if remaining <= 1 { print("skip space \(s.id): last space on \(from.name)"); continue }
            remaining -= 1
            moves.append(Move(space: s.id, from: from, to: to, apps: counts.sorted { $0.value > $1.value }.map { $0.key }.joined(separator: " ")))
        }
    }
    return moves
}

// MARK: - Space switching & window fitting
func mcDisplay(_ screen: Screen) -> MCDisplay? { readMissionControl().first { near($0.frame, screen.frame) } }

/// Make `space` the visible space on its display by clicking its Mission Control thumbnail.
func switchTo(space: Int, on screen: Screen) -> Bool {
    guard let d = managedDisplays().first(where: { $0.uuid == screen.uuid }), let idx = d.spaces.firstIndex(where: { $0.id == space }) else { return false }
    if d.spaces[idx].id == currentSpace(on: screen) { return true }
    guard openMissionControl() else { return false }
    mouse(CGPoint(x: screen.frame.midX, y: screen.frame.minY + 5)); pause(0.8)
    guard let mc = mcDisplay(screen), idx < mc.buttons.count else { closeMissionControl(); return false }
    let c = CGPoint(x: mc.buttons[idx].midX, y: mc.buttons[idx].midY)
    mouse(c); pause(0.2); mouse(c, .leftMouseDown); pause(0.08); mouse(c, .leftMouseUp)
    for _ in 0..<40 { pause(0.1); if readMissionControl().isEmpty { break } }
    for _ in 0..<30 { pause(0.1); if currentSpace(on: screen) == space { pause(0.8); return true } }
    return false
}
typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
let managedDisplayCurrentSpace = unsafeBitCast(dlsym(sky, "SLSManagedDisplayGetCurrentSpace"), to: CurrentSpaceFn.self)
func currentSpace(on screen: Screen) -> Int { Int(managedDisplayCurrentSpace(conn, screen.uuid as CFString)) }

typealias AXGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
let axGetWindow = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow"), to: AXGetWindowFn.self)

/// Move/resize the windows to the screen's work area through Accessibility (only windows on a visible
/// space are reachable). Returns how many accepted the new frame.
func place(_ wins: [Win], on screen: Screen) -> Int {
    var done = 0
    var axByPid: [pid_t: [AXUIElement]] = [:]
    for w in wins {
        if axByPid[w.pid] == nil { axByPid[w.pid] = (attr(AXUIElementCreateApplication(w.pid), "AXWindows") as? [AXUIElement]) ?? [] }
        guard let el = axByPid[w.pid]!.first(where: { var id: UInt32 = 0; return axGetWindow($0, &id) == .success && Int(id) == w.id }) else { print("    \(w.owner) \(w.id): not reachable via Accessibility"); continue }
        var pos = screen.work.origin, size = screen.work.size
        let okP = AXUIElementSetAttributeValue(el, "AXPosition" as CFString, AXValueCreate(.cgPoint, &pos)!) == .success
        let okS = AXUIElementSetAttributeValue(el, "AXSize" as CFString, AXValueCreate(.cgSize, &size)!) == .success
        _ = AXUIElementSetAttributeValue(el, "AXPosition" as CFString, AXValueCreate(.cgPoint, &pos)!) // some apps clamp size first, then position
        if okP && okS { done += 1 } else { print("    \(w.owner) \(w.id): resize refused") }
    }
    return done
}
/// Resize every real window of the (visible) space to the screen's work area. Returns (done, total).
func fitWindows(in space: Int, on screen: Screen) -> (Int, Int) {
    let wins = windowsPerSpace()[space] ?? []
    return (place(wins, on: screen), wins.count)
}

/// A window belongs to the display its frame is on: when a space moves to another display, macOS keeps every
/// window whose frame does not reach that display behind, on the source display's current space. Moving such a
/// window's frame onto the target display makes it join the space the target display is showing, so show the
/// moved space there and move the strays onto it. Returns (rehomed, strays).
func rehomeStrays(of space: Int, were: [Win], on screen: Screen) -> (Int, Int) {
    let now = windowsPerSpace()
    let there = Set((now[space] ?? []).map { $0.id })
    let strays = were.filter { w in !there.contains(w.id) && now.values.contains { $0.contains { $0.id == w.id } } }
    if strays.isEmpty { return (0, 0) }
    guard switchTo(space: space, on: screen) else { return (0, strays.count) }
    _ = place(strays, on: screen); pause(0.5)
    let after = Set((windowsPerSpace()[space] ?? []).map { $0.id })
    return (strays.filter { after.contains($0.id) }.count, strays.count)
}

// MARK: - Reserve an empty first space
func spaceIsEmpty(_ id: Int, _ wins: [Int: [Win]]) -> Bool { (wins[id] ?? []).isEmpty }

/// Add a space on `screen` through Mission Control's "+" button. Returns the new space id.
func addSpace(on screen: Screen) -> Int? {
    let before = Set(managedDisplays().first { $0.uuid == screen.uuid }?.spaces.map { $0.id } ?? [])
    guard openMissionControl() else { return nil }
    mouse(CGPoint(x: screen.frame.midX, y: screen.frame.minY + 5)); pause(0.8)
    guard let mc = mcDisplay(screen), mc.add != .zero else { closeMissionControl(); return nil }
    // The "+" tile hangs off the screen's top-right corner; click a point of it that is actually on screen.
    let c = CGPoint(x: min(mc.add.midX, screen.frame.maxX - 12), y: max(mc.add.midY, screen.frame.minY + 12))
    print("  add button \(mc.add) → clicking \(c)")
    mouse(c); pause(0.6); mouse(c, .leftMouseDown); pause(0.08); mouse(c, .leftMouseUp); pause(1.2)
    closeMissionControl()
    let after = managedDisplays().first { $0.uuid == screen.uuid }?.spaces.map { $0.id } ?? []
    return after.first { !before.contains($0) }
}

/// Drag the space at `index` on `screen` to the front of that screen's bar. Mission Control must be open.
func dragToFront(index: Int, on screen: Screen) -> Bool {
    mouse(CGPoint(x: screen.frame.midX, y: screen.frame.minY + 5)); pause(0.8)
    guard let mc = mcDisplay(screen), index < mc.buttons.count, let first = mc.buttons.first else { return false }
    let start = CGPoint(x: mc.buttons[index].midX, y: mc.buttons[index].midY)
    let target = CGPoint(x: first.minX - 40, y: first.midY)
    mouse(start); pause(0.3)
    mouse(start, .leftMouseDown); pause(0.4)
    mouse(CGPoint(x: start.x + 4, y: start.y + 2), .leftMouseDragged); pause(0.1)
    for i in 1...60 {
        let t = CGFloat(i) / 60
        mouse(CGPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t), .leftMouseDragged); pause(0.02)
    }
    pause(0.6); mouse(target, .leftMouseUp); pause(1.0)
    return true
}

/// Keep the first space of every external display empty, so unplugging the display never merges
/// windows into another space (macOS collapses a display's first space; the others move intact).
func reserveFirstSpace(on screen: Screen) -> Bool {
    guard let d = managedDisplays().first(where: { $0.uuid == screen.uuid }), let first = d.spaces.first else { return true }
    let wins = windowsPerSpace()
    if first.type == 0 && spaceIsEmpty(first.id, wins) { print("reserve \(screen.name): first space \(first.id) already empty"); return true }
    var candidate = d.spaces.dropFirst().first { $0.type == 0 && spaceIsEmpty($0.id, wins) }?.id
    if candidate == nil {
        guard let created = addSpace(on: screen) else { print("reserve \(screen.name): could not add a space"); return false }
        print("reserve \(screen.name): added space \(created)")
        candidate = created
    }
    guard let moving = candidate else { return false }
    if currentSpace(on: screen) == moving { _ = switchTo(space: first.id, on: screen) }
    guard let idx = managedDisplays().first(where: { $0.uuid == screen.uuid })?.spaces.firstIndex(where: { $0.id == moving }), openMissionControl() else { return false }
    let ok = dragToFront(index: idx, on: screen)
    closeMissionControl()
    let nowFirst = managedDisplays().first { $0.uuid == screen.uuid }?.spaces.first?.id
    print("reserve \(screen.name): empty space \(moving) moved to front: \(ok && nowFirst == moving ? "ok" : "FAILED")")
    return ok && nowFirst == moving
}

// MARK: - Main
let args = CommandLine.arguments.dropFirst()
let scr = screens()
func usage() -> Never { print("usage: space-arrange [--list | --dry-run | --fit | --fit-all | --reserve]"); exit(2) }
for a in args where !["--list", "--dry-run", "--fit", "--fit-all", "--reserve"].contains(a) { usage() }
if args.contains("--list") {
    let apps = appsPerSpace()
    for d in managedDisplays() {
        let sc = scr.first { $0.uuid == d.uuid }
        print("## \(sc?.name ?? d.uuid)  [\(sc?.role ?? "?")]")
        for s in d.spaces { print("  \(s.id)\(s.type == 0 ? "" : " (fullscreen)")  \((apps[s.id] ?? [:]).sorted { $0.value > $1.value }.map { $0.key }.joined(separator: ", "))") }
    }
    exit(0)
}
guard AXIsProcessTrusted() else { fail("Accessibility permission required for this process") }
let config = loadConfig()
let fitAll = args.contains("--fit-all")
let fit = fitAll || args.contains("--fit")
let reserve = args.contains("--reserve")
let moves = plan(config: config, screens: scr, displays: managedDisplays(), apps: appsPerSpace())
for m in moves { print("move space \(m.space) [\(m.apps)]  \(m.from.name) → \(m.to.name)") }
if moves.isEmpty { print("nothing to move") }
if args.contains("--dry-run") {
    if reserve { for sc in scr where !sc.builtin { let d = managedDisplays().first { $0.uuid == sc.uuid }; let w = windowsPerSpace(); if let f = d?.spaces.first { print("reserve \(sc.name): first space \(f.id) is \(spaceIsEmpty(f.id, w) ? "empty" : "NOT empty → would fix")") } } }
    exit(0)
}

// remember what each display is showing so we can put it back afterwards
let originalCurrent = scr.map { ($0, currentSpace(on: $0)) }
var failures = 0
var moved: [(Int, Screen)] = []
if !moves.isEmpty {
    // Mission Control will not move the space a display is currently showing (the drag only reorders it),
    // so first show some space that is staying put on each affected display.
    for from in Set(moves.map { $0.from.uuid }).compactMap({ u in scr.first { $0.uuid == u } }) {
        let cur = currentSpace(on: from)
        guard moves.contains(where: { $0.space == cur }) else { continue }
        let staying = managedDisplays().first { $0.uuid == from.uuid }?.spaces.filter { sp in sp.type == 0 && !moves.contains { m in m.space == sp.id } } ?? []
        guard let alt = staying.first, switchTo(space: alt.id, on: from) else { fail("could not switch \(from.name) away from space \(cur)") }
        print("  \(from.name): showing space \(alt.id) while its space \(cur) moves")
    }
    let before = windowsPerSpace()
    guard openMissionControl() else { fail("Mission Control did not open") }
    for m in moves {
        guard let d = managedDisplays().first(where: { $0.uuid == m.from.uuid }), let idx = d.spaces.firstIndex(where: { $0.id == m.space }) else { print("space \(m.space) vanished"); failures += 1; continue }
        let ok = dragSpace(index: idx, from: m.from, to: m.to)
        let now = managedDisplays().first { $0.uuid == m.to.uuid }?.spaces.contains { $0.id == m.space } ?? false
        print("  space \(m.space): \(ok && now ? "ok" : "FAILED")")
        if ok && now { moved.append((m.space, m.to)) } else { failures += 1 }
    }
    closeMissionControl()
    for (space, to) in moved {
        let (done, strays) = rehomeStrays(of: space, were: before[space] ?? [], on: to)
        if strays > 0 { print("  space \(space): \(done)/\(strays) windows were left behind, brought over"); if done < strays { failures += 1 } }
    }
}

if fit {
    var targets = moved
    if fitAll {
        let wins = windowsPerSpace()
        targets = managedDisplays().flatMap { d in d.spaces.filter { $0.type == 0 && !(wins[$0.id] ?? []).isEmpty }.compactMap { s in scr.first { $0.uuid == d.uuid }.map { (s.id, $0) } } }
    }
    for (space, screen) in targets {
        guard switchTo(space: space, on: screen) else { print("fit space \(space): could not switch to it"); failures += 1; continue }
        let (done, total) = fitWindows(in: space, on: screen)
        print("fit space \(space) on \(screen.name): \(done)/\(total) windows")   // a refused resize (fixed-size window) is not a failure
    }
}
if reserve {
    for sc in scr where !sc.builtin { if !reserveFirstSpace(on: sc) { failures += 1 } }
}
if fit || reserve {
    // restore what was showing before (if that space is still on the same display)
    for (screen, space) in originalCurrent where managedDisplays().first(where: { $0.uuid == screen.uuid })?.spaces.contains(where: { $0.id == space }) == true {
        _ = switchTo(space: space, on: screen)
    }
}
// Never leave a display parked on an empty space (a freshly connected display shows its empty first
// space; the built-in one may have just lost the space it was showing): show the first space that
// arrived there, or else the first space that has windows. A display showing a non-empty space is left alone.
let finalWins = windowsPerSpace()
for screen in scr {
    guard let d = managedDisplays().first(where: { $0.uuid == screen.uuid }), spaceIsEmpty(currentSpace(on: screen), finalWins) else { continue }
    let arrived = moved.first { $0.1.uuid == screen.uuid && !spaceIsEmpty($0.0, finalWins) }?.0
    guard let pick = arrived ?? d.spaces.first(where: { $0.type == 0 && !spaceIsEmpty($0.id, finalWins) })?.id else { continue }
    print("\(screen.name): showing space \(pick) instead of an empty one")
    _ = switchTo(space: pick, on: screen)
}
exit(failures == 0 ? 0 : 1)
