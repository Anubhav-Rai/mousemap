// mousemap: remap mouse side buttons (back / forward / middle) from a JSON config.
//
// Runs as a launchd agent. An event tap catches the button clicks and replaces
// them with the action configured in ~/.config/mousemap/config.json.

import AppKit
import ApplicationServices

let label = "local.mousemap"
let home = FileManager.default.homeDirectoryForCurrentUser
let configURL = ProcessInfo.processInfo.environment["MOUSEMAP_CONFIG"].map { URL(fileURLWithPath: $0) }
    ?? home.appendingPathComponent(".config/mousemap/config.json")
let plistURL = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
let logURL = home.appendingPathComponent("Library/Logs/mousemap.log")
let service = "gui/\(getuid())/\(label)"

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Actions

enum Action {
    case passthrough             // "default": let the click through untouched
    case ignore                  // "none": swallow the click
    case key(CGKeyCode, [Modifier])
    case media(Int32)
    case shell(String)
}

struct Modifier {
    let flag: CGEventFlags
    let keyCode: CGKeyCode?      // nil for fn: pressing it alone can open the emoji picker
}

let modifiers: [String: Modifier] = [
    "cmd": Modifier(flag: .maskCommand, keyCode: 0x37),
    "command": Modifier(flag: .maskCommand, keyCode: 0x37),
    "shift": Modifier(flag: .maskShift, keyCode: 0x38),
    "alt": Modifier(flag: .maskAlternate, keyCode: 0x3A),
    "opt": Modifier(flag: .maskAlternate, keyCode: 0x3A),
    "option": Modifier(flag: .maskAlternate, keyCode: 0x3A),
    "ctrl": Modifier(flag: .maskControl, keyCode: 0x3B),
    "control": Modifier(flag: .maskControl, keyCode: 0x3B),
    "fn": Modifier(flag: .maskSecondaryFn, keyCode: nil),
]

// Virtual key codes (US layout positions).
let keyCodes: [String: CGKeyCode] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
    "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
    "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
    "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
    "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
    "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
    "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
    "escape": 0x35, "esc": 0x35, "forwarddelete": 0x75,
    "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
    "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
    "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
    "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
]

let fKeyCodes: Set<CGKeyCode> = [
    0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D,
    0x67, 0x6F, 0x69, 0x6B, 0x71, 0x6A, 0x40, 0x4F, 0x50, 0x5A,
]

// NX_KEYTYPE_* values from IOKit's ev_keymap.h.
let mediaKeys: [String: Int32] = [
    "volume_up": 0, "volume_down": 1, "brightness_up": 2, "brightness_down": 3,
    "mute": 7, "play_pause": 16, "next": 17, "previous": 18,
]

func parseAction(_ text: String) throws -> Action {
    let s = text.trimmingCharacters(in: .whitespaces)
    if s == "default" { return .passthrough }
    if s == "none" { return .ignore }
    if s.hasPrefix("shell:") {
        let command = s.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { throw Failure("\"\(text)\": empty shell command") }
        return .shell(command)
    }
    if s.hasPrefix("media:") {
        let name = String(s.dropFirst(6))
        guard let key = mediaKeys[name] else {
            throw Failure("unknown media key \"\(name)\" (use \(mediaKeys.keys.sorted().joined(separator: ", ")))")
        }
        return .media(key)
    }
    let parts = s.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
    guard let keyName = parts.last, !keyName.isEmpty else { throw Failure("\"\(text)\": missing key after +") }
    guard let code = keyCodes[keyName] else { throw Failure("unknown key \"\(keyName)\" in \"\(text)\"") }
    let mods = try parts.dropLast().map { name -> Modifier in
        guard let mod = modifiers[name] else { throw Failure("unknown modifier \"\(name)\" in \"\(text)\"") }
        return mod
    }
    return .key(code, mods)
}

// MARK: - Config

let buttons: [String: Int64] = ["middle": 2, "back": 3, "forward": 4]

struct ScrollSettings {
    var smooth = false
    var speed = 1.0
    var smoothness = 1.0
    var momentum = 1.0
    var acceleration = 1.0
    var reverse = false
}

struct Config {
    var global: [Int64: Action] = [:]
    var apps: [String: [Int64: Action]] = [:]
    var scroll = ScrollSettings()
    var appScroll: [String: ScrollSettings] = [:]

    var summary: String {
        let count = global.count + apps.values.reduce(0) { $0 + $1.count }
        return "\(count) button mapping(s), smooth scrolling \(scroll.smooth ? "on" : "off")"
            + (scroll.reverse ? ", mouse scroll reversed" : "")
            + (appScroll.isEmpty ? "" : ", scroll settings for \(appScroll.count) app(s)")
    }

    func action(button: Int64, app: String?) -> Action? {
        if let app, let action = apps[app]?[button] { return action }
        return global[button]
    }

    func scroll(app: String?) -> ScrollSettings {
        app.flatMap { appScroll[$0] } ?? scroll
    }
}

// JSON numbers 0 and 1 also cast to Bool in Swift, so check the real type.
func isBool(_ value: Any) -> Bool { CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() }

// Takes the scroll_* settings out of `dict`, on top of `base`. Nil if there are none.
func parseScroll(_ dict: inout [String: Any], base: ScrollSettings, context: String) throws -> ScrollSettings? {
    var settings = base
    var found = false
    for (key, path) in [("smooth_scroll", \ScrollSettings.smooth), ("scroll_reverse", \ScrollSettings.reverse)] {
        guard let value = dict.removeValue(forKey: key) else { continue }
        guard isBool(value), let on = value as? Bool else { throw Failure("\(context)\"\(key)\" must be true or false") }
        settings[keyPath: path] = on
        found = true
    }
    let numbers = [
        ("scroll_speed", \ScrollSettings.speed, false),
        ("scroll_smoothness", \ScrollSettings.smoothness, false),
        ("scroll_momentum", \ScrollSettings.momentum, true),
        ("scroll_acceleration", \ScrollSettings.acceleration, true),
    ]
    for (key, path, zeroAllowed) in numbers {
        guard let value = dict.removeValue(forKey: key) else { continue }
        guard !isBool(value), let number = value as? Double, number > 0 || (zeroAllowed && number == 0) else {
            throw Failure("\(context)\"\(key)\" must be a number \(zeroAllowed ? "0 or more" : "above 0")")
        }
        settings[keyPath: path] = number
        found = true
    }
    return found ? settings : nil
}

func parseButtons(_ dict: [String: Any], context: String) throws -> [Int64: Action] {
    var out: [Int64: Action] = [:]
    for (name, value) in dict {
        guard let button = buttons[name] else {
            throw Failure("\(context): unknown setting \"\(name)\" (buttons are back, forward, middle)")
        }
        guard let text = value as? String else { throw Failure("\(context): \"\(name)\" must be a string") }
        out[button] = try parseAction(text)
    }
    return out
}

func readConfigJSON() throws -> [String: Any] {
    var text = try String(contentsOf: configURL, encoding: .utf8)
    // TextEdit likes to turn " into smart quotes.
    text = text.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
    let json: Any
    do {
        json = try JSONSerialization.jsonObject(with: Data(text.utf8), options: .json5Allowed)
    } catch {
        let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "\(error)"
        throw Failure("not valid JSON: \(detail)")
    }
    guard let root = json as? [String: Any] else { throw Failure("config must be a JSON object { ... }") }
    return root
}

func loadConfig() throws -> Config { try parseConfig(readConfigJSON()) }

func parseConfig(_ json: [String: Any]) throws -> Config {
    var root = json
    var config = Config()
    config.scroll = try parseScroll(&root, base: ScrollSettings(), context: "") ?? ScrollSettings()
    if let apps = root.removeValue(forKey: "apps") {
        guard let apps = apps as? [String: Any] else { throw Failure("\"apps\" must be an object") }
        for (bundleID, value) in apps {
            guard var dict = value as? [String: Any] else { throw Failure("apps.\(bundleID) must be an object") }
            // An app's scroll settings start from the global ones.
            config.appScroll[bundleID] = try parseScroll(&dict, base: config.scroll, context: "apps.\(bundleID): ")
            config.apps[bundleID] = try parseButtons(dict, context: "apps.\(bundleID)")
        }
    }
    config.global = try parseButtons(root, context: "config")
    return config
}

let configHelp = #"""
// mousemap config. Change it from the terminal with `mousemap set` (see
// `mousemap help`), or edit this file. Saved changes apply right away.
//
// Buttons: "back", "forward", "middle" (wheel click).
// Leave a button out to keep its normal behaviour.
//
// Actions:
//   "cmd+c", "ctrl+left", "cmd+shift+]", "f11"   keyboard shortcut
//       modifiers: cmd, shift, alt (or opt), ctrl, fn
//       keys: a-z, 0-9, f1-f20, left, right, up, down, space, return, tab,
//             escape, delete, forwarddelete, home, end, pageup, pagedown,
//             and punctuation: [ ] - = ; ' , . / \ `
//   "media:volume_up"   also volume_down, mute, play_pause, next, previous,
//                       brightness_up, brightness_down
//   "shell:open -a Safari"   run a shell command
//   "none"                   do nothing
//   "default"                normal behaviour (useful inside "apps")
//
// Smooth scrolling, trackpad-style (mouse wheel only; trackpads are left alone):
//   "smooth_scroll": true / false
//   "scroll_speed": 1.0        how far each notch pushes; 2.0 = twice as far
//   "scroll_smoothness": 1.0   glide of slow scrolling; 0.5 = snappier, 2.0 = floatier
//   "scroll_momentum": 1.0     coasting after fast scrolling; 0 = none, 2.0 = longer
//   "scroll_acceleration": 1.0 how much faster scrolling goes further; 0 = none
//   "scroll_reverse": false    flip the mouse wheel only. macOS has one "natural
//                              scrolling" switch for mouse and trackpad; leave it
//                              on for the trackpad and set this to true.
//
// "apps" holds per-app buttons and scroll_* settings by bundle ID (see
// `mousemap apps`); they apply while that app is in front.

"""#

let defaultConfig = configHelp + #"""
// Remove the // at the start of a line to turn it on.
{
  "smooth_scroll": true,
  "scroll_speed": 1.0,
  "scroll_smoothness": 1.0,
  "scroll_momentum": 1.0,
  "scroll_acceleration": 1.0,
  "scroll_reverse": false,

  // "back": "ctrl+left",      // previous desktop
  // "forward": "ctrl+right",  // next desktop

  "apps": {
    // "com.google.Chrome": { "back": "default", "forward": "default" },
    // "com.apple.Terminal": { "scroll_speed": 0.5 },
  },
}

"""#

func writeDefaultConfigIfMissing() throws {
    guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try defaultConfig.write(to: configURL, atomically: true, encoding: .utf8)
}

// MARK: - Performing actions

// Real keyboards set these flags on arrow / navigation / F keys; some shortcuts
// (e.g. ctrl+arrow to switch desktops) are ignored without them.
func extraFlags(_ code: CGKeyCode) -> CGEventFlags {
    switch code {
    case 0x7B...0x7E: return [.maskSecondaryFn, .maskNumericPad]
    case 0x73, 0x74, 0x75, 0x77, 0x79: return .maskSecondaryFn
    case _ where fKeyCodes.contains(code): return .maskSecondaryFn
    default: return []
    }
}

func postShortcut(_ code: CGKeyCode, _ mods: [Modifier]) {
    let source = CGEventSource(stateID: .hidSystemState)
    func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    // Press modifiers, tap the key, release modifiers, like a real keyboard would.
    var flags: CGEventFlags = []
    for mod in mods {
        flags.insert(mod.flag)
        if let key = mod.keyCode { post(key, down: true, flags: flags) }
    }
    post(code, down: true, flags: flags.union(extraFlags(code)))
    post(code, down: false, flags: flags.union(extraFlags(code)))
    for mod in mods.reversed() {
        flags.remove(mod.flag)
        if let key = mod.keyCode { post(key, down: false, flags: flags) }
    }
}

func postMediaKey(_ key: Int32) {
    for down in [true, false] {
        let state: Int32 = down ? 0xA : 0xB
        let event = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
            timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: Int((key << 16) | (state << 8)), data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}

func perform(_ action: Action) {
    switch action {
    case .passthrough, .ignore:
        break
    case let .key(code, mods):
        postShortcut(code, mods)
    case let .media(key):
        postMediaKey(key)
    case let .shell(command):
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        do { try process.run() } catch { log("shell command failed: \(error)") }
    }
}

// MARK: - Smooth scrolling

// Trackpad-style: every wheel notch adds speed, and a 120 Hz timer lets the
// page coast to a stop under friction. Friction is strong at low speed, so
// single notches stop crisply, and weak at high speed, so fast spins build up
// speed and carry on like a flick.
let notchPixels = 40.0                  // speed kick per notch, as distance (scroll_speed 1.0)
let glideSeconds = 0.07                 // friction time constant when slow (scroll_smoothness 1.0)
let coastSeconds = 0.4                  // ... and when fast (scroll_momentum 1.0)
let fastSpeed = 3000.0                  // px/s at which friction is weakest
let maxSpeed = 15000.0                  // px/s
let accelStart = 3.0                    // notches/s before notches start pushing harder
let accelScale = 12.0                   // ... and how quickly the push grows above that
let accelPower = 1.3
let scrollMarker: Int64 = 0x6D6D_6170   // tags the scroll events we post ourselves

var activeScroll = ScrollSettings()     // settings of the app being scrolled
var lastNotch = (time: 0.0, direction: 0.0)
var scrollVelocity = (y: 0.0, x: 0.0)   // px/s
var scrollCarry = (y: 0.0, x: 0.0)      // sub-pixel remainder
var scrollTimer: DispatchSourceTimer?
var lastScrollTick = 0.0

func frictionSeconds(_ speed: Double) -> Double {
    let slow = glideSeconds * activeScroll.smoothness
    let fast = max(slow, coastSeconds * activeScroll.momentum)
    return slow + (fast - slow) * min(1, speed / fastSpeed)
}

func addScroll(_ event: CGEvent, _ settings: ScrollSettings) {
    activeScroll = settings
    // One notch per event, direction only: the speed build-up above is the
    // acceleration, so macOS's own wheel acceleration is ignored.
    func notch(_ whole: CGEventField, _ fixed: CGEventField) -> Double {
        let delta = Double(event.getIntegerValueField(whole))
        let value = delta != 0 ? delta : event.getDoubleValueField(fixed)
        return value > 0 ? 1 : value < 0 ? -1 : 0
    }
    let y = notch(.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1)
    let x = notch(.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)

    // Notches arriving quickly in the same direction push harder.
    let now = ProcessInfo.processInfo.systemUptime
    let direction = y != 0 ? y : x * 2
    let rate = direction == lastNotch.direction ? 1 / max(now - lastNotch.time, 0.005) : 0
    lastNotch = (now, direction)
    let boost = 1 + settings.acceleration * pow(max(0, rate - accelStart) / accelScale, accelPower)

    let kick = notchPixels * settings.speed / (glideSeconds * settings.smoothness) * boost
        * (settings.reverse ? -1 : 1)
    func push(_ velocity: Double, _ direction: Double) -> Double {
        guard direction != 0 else { return velocity }
        let base = velocity * direction < 0 ? 0 : velocity   // changing direction stops the old movement
        return max(-maxSpeed, min(maxSpeed, base + direction * kick))
    }
    scrollVelocity.y = push(scrollVelocity.y, y)
    scrollVelocity.x = push(scrollVelocity.x, x)

    guard scrollTimer == nil else { return }
    lastScrollTick = ProcessInfo.processInfo.systemUptime - 1.0 / 120
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .milliseconds(1))
    timer.setEventHandler(handler: scrollTick)
    timer.resume()
    scrollTimer = timer
}

func reverseScroll(_ event: CGEvent) {
    // Setting the line delta recalculates the other two, so read everything
    // first and set the line delta before the others.
    let axes: [(CGEventField, CGEventField, CGEventField)] = [
        (.scrollWheelEventDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventPointDeltaAxis1),
        (.scrollWheelEventDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventPointDeltaAxis2),
    ]
    for (lines, fixed, points) in axes {
        let l = event.getIntegerValueField(lines), f = event.getDoubleValueField(fixed), p = event.getIntegerValueField(points)
        event.setIntegerValueField(lines, value: -l)
        event.setDoubleValueField(fixed, value: -f)
        event.setIntegerValueField(points, value: -p)
    }
}

func scrollTick() {
    let now = ProcessInfo.processInfo.systemUptime
    let dt = now - lastScrollTick
    lastScrollTick = now

    // Distance travelled this tick while friction slows the axis down. Whole
    // pixels only; the leftover fraction carries over to the next tick.
    func advance(_ velocity: inout Double, _ carry: inout Double) -> Int32 {
        let friction = frictionSeconds(abs(velocity))
        let decay = exp(-dt / friction)
        let distance = velocity * friction * (1 - decay) + carry
        velocity *= decay
        let pixels = distance.rounded()
        carry = distance - pixels
        return Int32(pixels)
    }
    let dy = advance(&scrollVelocity.y, &scrollCarry.y)
    let dx = advance(&scrollVelocity.x, &scrollCarry.x)
    if dy != 0 || dx != 0 {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0)
        event?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event?.setIntegerValueField(.eventSourceUserData, value: scrollMarker)
        event?.post(tap: .cghidEventTap)
    }
    // Stop once less than a pixel of travel is left on both axes.
    func settled(_ velocity: Double) -> Bool { abs(velocity) * frictionSeconds(abs(velocity)) < 1 }
    if settled(scrollVelocity.y) && settled(scrollVelocity.x) {
        scrollVelocity = (0, 0)
        scrollCarry = (0, 0)
        scrollTimer?.cancel()
        scrollTimer = nil
    }
}

// MARK: - Agent

let logDateFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(logDateFormat.string(from: Date())) \(message)\n".utf8))
}

var config = Config()
var configModified: Date?
var lastConfigCheck = 0.0
var eventTap: CFMachPort?
var swallowedButtons = Set<Int64>()

func reloadConfigIfChanged() {
    // Scrolling sends many events a second; looking at the file twice a second is plenty.
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastConfigCheck >= 0.5 else { return }
    lastConfigCheck = now

    let modified = (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
    guard modified != configModified else { return }
    configModified = modified
    guard modified != nil else {
        config = Config()
        log("no config at \(configURL.path); buttons behave normally")
        return
    }
    do {
        config = try loadConfig()
        log("loaded config (\(config.summary))")
    } catch {
        log("config error, keeping previous config: \(error)")
    }
}

func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }

    if type == .scrollWheel {
        guard event.getIntegerValueField(.eventSourceUserData) != scrollMarker else {
            return Unmanaged.passUnretained(event)
        }
        // Trackpads and Magic Mouse send continuous events: leave them alone.
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else {
            return Unmanaged.passUnretained(event)
        }
        reloadConfigIfChanged()
        let settings = config.scroll(app: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        // With a modifier held (cmd+scroll zoom, shift+scroll sideways) the
        // app gets the raw event, only reversed if asked.
        if settings.smooth && event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskAlternate, .maskShift]) {
            addScroll(event, settings)
            return nil
        }
        if settings.reverse { reverseScroll(event) }
        return Unmanaged.passUnretained(event)
    }

    let button = event.getIntegerValueField(.mouseEventButtonNumber)

    // Swallow the release of any press we swallowed, and nothing else.
    if type == .otherMouseUp {
        return swallowedButtons.remove(button) != nil ? nil : Unmanaged.passUnretained(event)
    }

    reloadConfigIfChanged()
    let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    guard let action = config.action(button: button, app: app) else { return Unmanaged.passUnretained(event) }
    if case .passthrough = action { return Unmanaged.passUnretained(event) }

    swallowedButtons.insert(button)
    DispatchQueue.main.async { perform(action) }
    return nil
}

func installTap() {
    let mask: CGEventMask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        | (1 << CGEventType.scrollWheel.rawValue)
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
        eventsOfInterest: mask, callback: { _, type, event, _ in handle(type, event) }, userInfo: nil)
    else {
        log("could not create event tap")
        exit(1)
    }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    log("running")
}

// Asks a fresh copy of ourselves: this process's own answer can stay stale
// after the user grants permission.
func isTrustedNow() -> Bool {
    let process = Process()
    process.executableURL = Bundle.main.executableURL
    process.arguments = ["trusted"]
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func runAgent() -> Never {
    log("starting (pid \(getpid()))")
    reloadConfigIfChanged()
    let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if AXIsProcessTrustedWithOptions(prompt) {
        installTap()
    } else {
        log("waiting for permission: System Settings > Privacy & Security > Device Control and Data Access (Accessibility on older macOS) > turn on \"mousemap\"")
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { timer in
            guard isTrustedNow() else { return }
            timer.invalidate()
            log("permission granted")
            installTap()
        }
    }

    // An AppKit run loop keeps NSWorkspace's frontmost-app info current.
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApplication.shared.run()
    exit(0)
}

// MARK: - Commands

@discardableResult
func launchctl(_ args: String...) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, "\(error)") }
    let output = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: output, as: UTF8.self))
}

func turnOn() throws {
    try writeDefaultConfigIfMissing()
    let executable = Bundle.main.executableURL!.resolvingSymlinksInPath().path
    let plist: [String: Any] = [
        "Label": label,
        "ProgramArguments": [executable, "run"],
        "RunAtLoad": true,
        "KeepAlive": true,
        "ProcessType": "Interactive",
        "StandardOutPath": logURL.path,
        "StandardErrorPath": logURL.path,
        "EnvironmentVariables": ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
    ]
    try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)

    launchctl("enable", service)
    if launchctl("print", service).status == 0 {
        launchctl("kickstart", "-k", service)
    } else {
        let result = launchctl("bootstrap", "gui/\(getuid())", plistURL.path)
        guard result.status == 0 else { throw Failure("launchctl bootstrap failed: \(result.output)") }
    }
    print("mousemap is on. Config: \(configURL.path)")
}

func turnOff() {
    launchctl("disable", service)
    launchctl("bootout", service)
    print("mousemap is off. Side buttons are back to normal.")
}

func status() {
    let result = launchctl("print", service)
    if result.status != 0 {
        print("mousemap: off")
    } else if let pid = result.output.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) })
        .first(where: { $0.hasPrefix("pid = ") }) {
        print("mousemap: on (\(pid))")
    } else {
        print("mousemap: on, but not running (see log below)")
    }

    if !FileManager.default.fileExists(atPath: configURL.path) {
        print("config: missing (\(configURL.path))")
    } else {
        do { print("config: OK, \(try loadConfig().summary) (\(configURL.path))") }
        catch { print("config: ERROR, \(error)") }
    }

    if let text = try? String(contentsOf: logURL, encoding: .utf8) {
        let lines = text.split(separator: "\n").suffix(5)
        if !lines.isEmpty {
            print("\nrecent log (\(logURL.path)):")
            lines.forEach { print("  \($0)") }
        }
    }
}

func edit() throws {
    try writeDefaultConfigIfMissing()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-t", configURL.path]
    try process.run()
    process.waitUntilExit()
}

func listApps() {
    let apps = NSWorkspace.shared.runningApplications
        .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    let width = apps.map { $0.localizedName?.count ?? 0 }.max() ?? 0
    for app in apps {
        let name = app.localizedName ?? ""
        print(name.padding(toLength: width + 2, withPad: " ", startingAt: 0) + app.bundleIdentifier!)
    }
}

// Accepts an app name ("Terminal") or bundle ID ("com.apple.Terminal").
func bundleID(for app: String) throws -> String {
    let wanted = app.lowercased()
    if let match = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier?.lowercased() == wanted || $0.localizedName?.lowercased() == wanted
    }), let id = match.bundleIdentifier {
        return id
    }
    // Part of a name ("chrome") is fine when it matches only one running app.
    let partial = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.localizedName?.lowercased().contains(wanted) == true
    }
    if partial.count == 1, let id = partial[0].bundleIdentifier { return id }
    if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) != nil { return app }
    for dir in ["/Applications", "/System/Applications", "/System/Applications/Utilities", home.path + "/Applications"] {
        if let id = Bundle(path: "\(dir)/\(app).app")?.bundleIdentifier { return id }
    }
    throw Failure("can't find an app called \"\(app)\" (use its bundle ID from `mousemap apps`)")
}

func writeConfigJSON(_ root: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try (configHelp + String(decoding: data, as: UTF8.self) + "\n").write(to: configURL, atomically: true, encoding: .utf8)
}

// mousemap set [app] <setting> <value>   /   mousemap unset [app] <setting>
func changeSetting(_ args: [String], remove: Bool) throws {
    let valueCount = remove ? 0 : 1
    guard args.count == 1 + valueCount || args.count == 2 + valueCount else {
        throw Failure(remove ? "usage: mousemap unset [app] <setting>" : "usage: mousemap set [app] <setting> <value>")
    }
    let app = args.count == 2 + valueCount ? try bundleID(for: args[0]) : nil
    let key = args[args.count - 1 - valueCount]
    var value: Any?
    if !remove {
        let text = args[args.count - 1]
        value = text == "true" ? true : text == "false" ? false : Double(text).map { $0 as Any } ?? text
    }

    try writeDefaultConfigIfMissing()
    var root = try readConfigJSON()
    if let app {
        var apps = root["apps"] as? [String: Any] ?? [:]
        var entry = apps[app] as? [String: Any] ?? [:]
        entry[key] = value
        apps[app] = entry.isEmpty ? nil : entry
        root["apps"] = apps
    } else {
        root[key] = value
    }
    _ = try parseConfig(root)   // refuse to save anything the agent couldn't load
    try writeConfigJSON(root)

    let target = app.map { " for \($0)" } ?? ""
    print(remove ? "removed \(key)\(target)" : "\(key) = \(args[args.count - 1])\(target)")
}

func showSettings() throws {
    let data = try JSONSerialization.data(withJSONObject: readConfigJSON(), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    print(String(decoding: data, as: UTF8.self))
}

let usage = """
usage: mousemap <command>

  on       start mousemap now and at every login
  off      stop it (side buttons go back to normal)
  status   show whether it's running, check the config, show recent log
  show     print the current settings
  set [app] <setting> <value>
           change a setting, for every app or just one, e.g.
             mousemap set scroll_speed 1.2
             mousemap set Terminal scroll_speed 0.25
             mousemap set forward ctrl+up
  unset [app] <setting>
           remove a setting, so it falls back to the default
             (for an app: back to the everywhere setting)
  edit     open the config file (lists every setting)
  apps     list running apps and their bundle IDs (for per-app settings)
"""

do {
    switch CommandLine.arguments.dropFirst().first {
    case "run": runAgent()
    case "trusted": exit(AXIsProcessTrusted() ? 0 : 1)
    case "on": try turnOn()
    case "off": turnOff()
    case "status": status()
    case "edit": try edit()
    case "apps": listApps()
    case "show": try showSettings()
    case "set": try changeSetting(Array(CommandLine.arguments.dropFirst(2)), remove: false)
    case "unset": try changeSetting(Array(CommandLine.arguments.dropFirst(2)), remove: true)
    case nil, "help", "-h", "--help": print(usage)
    default:
        print(usage)
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("mousemap: \(error)\n".utf8))
    exit(1)
}
