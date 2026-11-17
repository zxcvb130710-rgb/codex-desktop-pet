import AppKit
import ApplicationServices

struct CodexSelection: Equatable {
    static let efforts = ["low", "medium", "high", "xhigh", "ultra"]
    let effort: String
    var label: String { ["low": "Light", "medium": "Medium", "high": "High", "xhigh": "Extra High", "ultra": "Ultra"][effort] ?? effort }

    static func named(_ text: String) -> CodexSelection? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mapping = ["light": "low", "low": "low", "低": "low", "轻度": "low", "輕度": "low", "medium": "medium", "中": "medium", "high": "high", "高": "high", "extra high": "xhigh", "extra-high": "xhigh", "xhigh": "xhigh", "超高": "xhigh", "极高": "xhigh", "極高": "xhigh", "ultra": "ultra"]
        return mapping[value].map { CodexSelection(effort: $0) }
    }

    static func slider(value: Double, minimum: Double, maximum: Double) -> CodexSelection? {
        guard minimum.isFinite, maximum.isFinite, value.isFinite,
              abs(minimum) < 0.001, value >= 0, value <= maximum else { return nil }
        let count: Int
        if abs(maximum - 3) < 0.001 { count = 4 }
        else if abs(maximum - 4) < 0.001 { count = 5 }
        else { return nil }
        let index = Int(value.rounded())
        guard index >= 0, index < count else { return nil }
        return CodexSelection(effort: efforts[index])
    }

    // Only call for a known model/power control, never arbitrary chat text.
    static func powerLabel(_ text: String) -> CodexSelection? {
        guard !text.lowercased().contains("locked"), !text.contains("锁定"), !text.contains("鎖定") else { return nil }
        // aria-describedby joins the live value and keyboard instructions. Parse
        // only the first clause, including when Chromium inserts a line break.
        let clause = (text.components(separatedBy: CharacterSet(charactersIn: ",，\n\r")).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".。"))
        if let exact = named(clause) { return exact }
        let pattern = #"(?i)(?:^|\s)(extra[ -]high|xhigh|ultra|medium|light|low|high|超高|极高|極高|轻度|輕度|高|中|低)$"#
        guard let range = clause.range(of: pattern, options: .regularExpression) else { return nil }
        return named(String(clause[range]).trimmingCharacters(in: .whitespaces))
    }

    static func powerControl(role: String, name: String, help: String, classes: [String], description: String = "") -> CodexSelection? {
        // Names and effort translations verified against the bundled picker.
        let powerNames = ["Power", "强度", "強度", "效能"]
        let isPower = powerNames.contains(name) || powerNames.contains(description)
        let isPicker = classes.contains { $0.hasPrefix("SliderKeyboardControl-") || $0.hasPrefix("ModelPickerTrigger") }
        guard ["AXMenuItem", "AXButton", "AXPopUpButton"].contains(role), isPower || isPicker else { return nil }
        return powerLabel(help) ?? powerLabel(description) ?? (isPicker ? powerLabel(name) : nil)
    }

    static func resolveEffort(selection: CodexSelection?, eventEffort: String?, current: String) -> String {
        if let selection { return selection.effort }
        return eventEffort.flatMap { efforts.contains($0) ? $0 : nil } ?? current
    }
}

// A large chat must not make each poll restart before reaching the composer.
// Keep traversal progress across polling budgets; never read text node values.
struct CodexSelectionScan<Element: Hashable> {
    private var pending: [Element] = []
    private var offset = 0
    private var visited = Set<Element>()
    var isExhausted: Bool { offset >= pending.count }

    mutating func reset(_ roots: [Element]) {
        pending = roots
        offset = 0
        visited.removeAll(keepingCapacity: true)
    }

    mutating func append(_ children: [Element]) { pending.append(contentsOf: children) }

    mutating func next() -> Element? {
        while offset < pending.count {
            let element = pending[offset]
            offset += 1
            if visited.insert(element).inserted { return element }
        }
        return nil
    }
}

final class CodexSelectionMonitor {
    var onChange: ((CodexSelection) -> Void)?
    private(set) var current: CodexSelection?
    private var timer: DispatchSourceTimer?
    private static var preparedPID: pid_t?
    private static var backgroundScan = CodexSelectionScan<AXUIElement>()
    private let queue = DispatchQueue(label: "local.gptcompanion.slider", qos: .utility)
    static var isTrusted: Bool { AXIsProcessTrusted() }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func sliderSelection(_ element: AXUIElement) -> CodexSelection? {
        guard attribute(element, kAXRoleAttribute) as? String == kAXSliderRole else { return nil }
        for name in [kAXValueDescriptionAttribute, kAXValueAttribute] {
            if let text = attribute(element, name) as? String, let selected = CodexSelection.named(text) { return selected }
        }
        if let value = attribute(element, kAXValueAttribute) as? NSNumber,
           let minimum = attribute(element, kAXMinValueAttribute) as? NSNumber,
           let maximum = attribute(element, kAXMaxValueAttribute) as? NSNumber {
            return CodexSelection.slider(value: value.doubleValue, minimum: minimum.doubleValue, maximum: maximum.doubleValue)
        }
        return nil
    }

    private static func controlSelection(_ element: AXUIElement) -> CodexSelection? {
        if let selected = sliderSelection(element) { return selected }
        let role = attribute(element, kAXRoleAttribute) as? String ?? ""
        guard ["AXMenuItem", "AXButton", "AXPopUpButton"].contains(role) else { return nil }
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
        let classes = attribute(element, "AXDOMClassList") as? [String] ?? []
        let help = attribute(element, kAXHelpAttribute) as? String ?? ""
        return CodexSelection.powerControl(role: role, name: title, help: help, classes: classes, description: description)
    }

    private static func selection(in scan: inout CodexSelectionScan<AXUIElement>, limit: Int, deadline: CFAbsoluteTime) -> CodexSelection? {
        var count = 0
        while count < limit, CFAbsoluteTimeGetCurrent() < deadline, let element = scan.next() {
            count += 1
            if let selected = controlSelection(element) {
                return selected
            }
            // Text values and conversation contents are never read or recorded.
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, kAXImageRole].contains(role) { continue }
            if let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
                scan.append(children)
            }
        }
        return nil
    }

    static func readCurrent() -> CodexSelection? {
        guard isTrusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").first, app.isActive else {
            backgroundScan.reset([])
            return nil
        }
        let deadline = CFAbsoluteTimeGetCurrent() + 0.18
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.1)
        if preparedPID != app.processIdentifier {
            // Chromium may keep its accessibility tree disabled until a client
            // explicitly announces assistive access. This changes no chat settings.
            _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            preparedPID = app.processIdentifier
            backgroundScan.reset([])
        }
        if let focused = elementAttribute(application, kAXFocusedUIElementAttribute) {
            if let selected = controlSelection(focused) { return selected }
            // A mouse-opened picker can focus a different item in its menu.
            // Search that menu before walking the full application window.
            var ancestor: AXUIElement? = focused
            for _ in 0..<8 {
                guard let node = ancestor else { break }
                let role = attribute(node, kAXRoleAttribute) as? String ?? ""
                if role == kAXMenuRole {
                    var menuScan = CodexSelectionScan<AXUIElement>()
                    menuScan.reset([node])
                    if let selected = selection(in: &menuScan, limit: 160, deadline: min(deadline, CFAbsoluteTimeGetCurrent() + 0.08)) { return selected }
                    break
                }
                if [kAXWindowRole, "AXWebArea", kAXApplicationRole].contains(role) { break }
                ancestor = elementAttribute(node, kAXParentAttribute)
            }
        }
        if backgroundScan.isExhausted {
            var roots = (attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []).reversed().map { $0 }
            if let window = elementAttribute(application, kAXFocusedWindowAttribute) { roots.insert(window, at: 0) }
            backgroundScan.reset(roots)
        }
        let selected = selection(in: &backgroundScan, limit: 700, deadline: deadline)
        if selected != nil { backgroundScan.reset([]) }
        return selected
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        if !Self.isTrusted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in
            guard self != nil, let selected = Self.readCurrent() else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, selected != self.current else { return }
                self.current = selected
                self.onChange?(selected)
            }
        }
        self.timer = timer
        timer.resume()
    }

    func refresh() {
        if let current { onChange?(current) }
    }

    deinit { timer?.cancel() }
}
