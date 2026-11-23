import AppKit
import ApplicationServices

struct CodexSelection: Equatable {
    static let efforts = ["low", "medium", "high", "xhigh", "ultra"]
    let effort: String
    var label: String { ["low": "轻度", "medium": "中", "high": "高", "xhigh": "极高", "ultra": "Ultra"][effort] ?? effort }

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

    static func isPowerControl(name: String, description: String, classes: [String]) -> Bool {
        let names = ["Power", "Select power", "Select reasoning effort", "强度", "強度", "效能",
                     "思考强度", "思考程度", "推理强度", "选择推理强度", "選擇推理強度"]
        return names.contains(name) || names.contains(description)
            || classes.contains { $0.hasPrefix("SliderKeyboardControl-") }
    }

    static func powerControl(role: String, name: String, help: String, classes: [String],
                             description: String = "", value: String = "", selected: Bool = false) -> CodexSelection? {
        if classes.contains(where: { $0.hasPrefix("ExplicitOption-") }) {
            // Chromium exposes aria-pressed buttons as toggle buttons (AXCheckBox).
            guard selected, ["AXCheckBox", "AXRadioButton", "AXButton"].contains(role) else { return nil }
            return powerLabel(name) ?? powerLabel(description)
        }
        let isPicker = classes.contains { $0.hasPrefix("ModelPickerTrigger") }
        let isPower = isPowerControl(name: name, description: description, classes: classes)
        guard ["AXMenuItem", "AXButton", "AXPopUpButton", "AXSlider"].contains(role), isPower || isPicker else { return nil }
        return powerLabel(value) ?? powerLabel(help) ?? powerLabel(description) ?? powerLabel(name)
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

    private static func controlSelection(_ element: AXUIElement, role: String) -> CodexSelection? {
        if role == kAXSliderRole, let selected = sliderSelection(element) { return selected }
        guard ["AXMenuItem", "AXButton", "AXPopUpButton", "AXSlider", "AXCheckBox", "AXRadioButton"].contains(role) else { return nil }
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        let description = attribute(element, kAXDescriptionAttribute) as? String ?? ""
        let classes = attribute(element, "AXDOMClassList") as? [String] ?? []
        if classes.contains(where: { $0.hasPrefix("ExplicitOption-") }) {
            let pressed = (attribute(element, kAXValueAttribute) as? NSNumber)?.intValue == 1
            let selected = pressed || (attribute(element, kAXSelectedAttribute) as? NSNumber)?.boolValue == true
            return CodexSelection.powerControl(role: role, name: title, help: "", classes: classes,
                                               description: description, selected: selected)
        }
        let isPower = CodexSelection.isPowerControl(name: title, description: description, classes: classes)
        guard isPower || classes.contains(where: { $0.hasPrefix("ModelPickerTrigger") }) else { return nil }
        let help = attribute(element, kAXHelpAttribute) as? String ?? ""
        let value = attribute(element, kAXValueAttribute) as? String ?? ""
        if let selected = CodexSelection.powerControl(role: role, name: title, help: help, classes: classes,
                                                     description: description, value: value) { return selected }
        guard isPower, let parent = elementAttribute(element, kAXParentAttribute),
              let siblings = attribute(parent, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        // The picker also publishes the current value as a sibling live announcement.
        for sibling in siblings.prefix(8) {
            guard let classes = attribute(sibling, "AXDOMClassList") as? [String],
                  classes.contains(where: { $0.hasPrefix("KeyboardAnnouncement-") }) else { continue }
            let children = attribute(sibling, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for announcement in [sibling] + children.prefix(3) {
                for name in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    if let text = attribute(announcement, name) as? String,
                       let selected = CodexSelection.powerLabel(text) { return selected }
                }
            }
        }
        return nil
    }

    private static func selection(in scan: inout CodexSelectionScan<AXUIElement>, limit: Int, deadline: CFAbsoluteTime) -> CodexSelection? {
        var count = 0
        while count < limit, CFAbsoluteTimeGetCurrent() < deadline, let element = scan.next() {
            count += 1
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if let selected = controlSelection(element, role: role) {
                return selected
            }
            // Text values and conversation contents are never read or recorded.
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
            if let role = attribute(focused, kAXRoleAttribute) as? String,
               let selected = controlSelection(focused, role: role) { return selected }
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
