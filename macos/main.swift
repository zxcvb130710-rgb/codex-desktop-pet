import AppKit
import QuartzCore

struct BridgeEvent: Decodable, Equatable {
    let schemaVersion: Int
    let sessionId: String
    let turnId: String
    let event: String
    let effort: String?
    let activity: String
    let timestamp: Double

    // Codex turn IDs are UUIDv7, whose first 48 bits are creation milliseconds.
    // Use turn creation rather than hook arrival to order successive turns: a
    // delayed Stop for an old turn must not hide work in a newer turn.
    var turnStartedAt: TimeInterval {
        guard let uuid = UUID(uuidString: turnId) else { return timestamp }
        let parts = uuid.uuidString.split(separator: "-")
        guard parts.count == 5, parts[2].first == "7",
              let milliseconds = UInt64(parts[0] + parts[1], radix: 16) else { return timestamp }
        let started = TimeInterval(milliseconds) / 1000
        return started > 0 && started <= timestamp + 60 ? started : timestamp
    }
}

final class CodexBridge {
    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["GPT_PET_DATA_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPTCompanion/events", isDirectory: true)
    }

    static func latestPerSession(_ events: [BridgeEvent], now: Double = Date().timeIntervalSince1970) -> [BridgeEvent] {
        let recent = events.filter {
            $0.schemaVersion == 1 && ["idle", "thinking"].contains($0.activity)
                && $0.timestamp > now - 6 * 3600 && $0.timestamp <= now + 60
        }
        var latest: [String: BridgeEvent] = [:]
        for event in recent {
            if let previous = latest[event.sessionId] {
                if event.turnStartedAt < previous.turnStartedAt { continue }
                if event.turnStartedAt == previous.turnStartedAt && event.timestamp < previous.timestamp { continue }
                if event.turnId == previous.turnId && event.timestamp == previous.timestamp && previous.activity == "idle" { continue }
            }
            latest[event.sessionId] = event
        }
        return Array(latest.values)
    }

    static func select(_ events: [BridgeEvent], now: Double = Date().timeIntervalSince1970) -> BridgeEvent? {
        let latest = latestPerSession(events, now: now)
        // Only each chat's newest turn can still be working. An abandoned older
        // start must not keep the pet busy after a later turn has finished.
        let busy = latest.filter { $0.activity == "thinking" }
        return (busy.isEmpty ? latest : busy).max { $0.timestamp < $1.timestamp }
    }

    static func readEvents(from directory: URL = directory) -> [BridgeEvent] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left > right
        }.prefix(512).compactMap { url in
            guard let data = try? Data(contentsOf: url), data.count < 16_384 else { return nil }
            return try? JSONDecoder().decode(BridgeEvent.self, from: data)
        }
    }

    var onChange: ((BridgeEvent?) -> Void)?
    private(set) var current: BridgeEvent?
    private(set) var activeSessionCount = 0
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?

    func start() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(Self.directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.refresh() }
            source.setCancelHandler { Darwin.close(descriptor) }
            self.source = source
            source.resume()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refresh() }
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        let events = Self.readEvents()
        let next = Self.select(events)
        let active = Self.latestPerSession(events).filter { $0.activity == "thinking" }.count
        guard force || next != current || active != activeSessionCount else { return }
        current = next
        activeSessionCount = active
        onChange?(next)
    }

    deinit { source?.cancel(); timer?.invalidate() }
}

struct CharacterManifest: Decodable {
    struct Mode: Decodable {
        let idle: String
        let thinking: String
    }
    let modes: [String: Mode]
}

struct PetState: Equatable {
    var effort: String
    var activity: String
    var key: String { "\(effort)-\(activity)" }
    var label: String { "\(CodexSelection(effort: effort).label) · \(activity == "thinking" ? "思考中" : "待机")" }
}

enum PetError: LocalizedError {
    case missingResource(String)
    var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "无法读取桌宠素材：\(name)"
        }
    }
}

final class CharacterLibrary {
    let images: [String: NSImage]

    init(bundle: Bundle = .main) throws {
        guard let resources = bundle.resourceURL else { throw PetError.missingResource("Resources") }
        let manifestURL = resources.appendingPathComponent("character.json")
        let manifest = try JSONDecoder().decode(CharacterManifest.self, from: Data(contentsOf: manifestURL))
        var loaded: [String: NSImage] = [:]
        for effort in CodexSelection.efforts {
            guard let mode = manifest.modes[effort] else { throw PetError.missingResource(effort) }
            for (activity, path) in [("idle", mode.idle), ("thinking", mode.thinking)] {
                guard let image = NSImage(contentsOf: resources.appendingPathComponent(path)), image.isValid else {
                    throw PetError.missingResource(path)
                }
                loaded["\(effort)-\(activity)"] = image
            }
        }
        images = loaded
    }
}

final class PetView: NSView {
    var image: NSImage? {
        didSet {
            guard oldValue !== image else { return }
            if shouldAnimate && window?.isVisible == true {
                let fade = CATransition()
                fade.type = .fade
                fade.duration = 0.28
                portrait.add(fade, forKey: "poseFade")
            }
            withoutImplicitAnimation {
                portrait.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
            needsLayout = true
        }
    }
    var petState = PetState(effort: "high", activity: "idle") {
        didSet {
            if oldValue != petState {
                refreshAnimations()
                if oldValue.effort != petState.effort { flashOnChange() }
            }
        }
    }
    var animationEnabled = true {
        didSet { if oldValue != animationEnabled { refreshAnimations() } }
    }
    var toggleActivity: (() -> Void)?
    var makeMenu: (() -> NSMenu)?
    private let motion = CALayer()
    private let aura = CALayer()
    private let portrait = CALayer()
    private let magic = CALayer()
    private var animationVisible = true
    private var reduceMotionObserver: NSObjectProtocol?
    private var shouldAnimate: Bool {
        animationEnabled && animationVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        prepareLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        prepareLayers()
    }

    private func prepareLayers() {
        wantsLayer = true
        layer?.addSublayer(motion)
        motion.addSublayer(aura)
        motion.addSublayer(portrait)
        motion.addSublayer(magic)
        portrait.contentsGravity = .resizeAspect
        portrait.minificationFilter = .trilinear
        portrait.magnificationFilter = .linear
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshAnimations() }
    }

    deinit {
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var portraitRect: NSRect {
        guard let image, image.size.height > 0 else { return .zero }
        // Leave room for movement and glow at every menu size.
        let available = bounds.insetBy(dx: 14, dy: 14)
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: available.minY, width: size.width, height: size.height)
    }

    private func withoutImplicitAnimation(_ changes: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        changes()
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        withoutImplicitAnimation {
            motion.frame = bounds
            aura.frame = bounds
            magic.frame = bounds
            portrait.frame = portraitRect
            portrait.contentsScale = window?.backingScaleFactor ?? 2
        }
        refreshAnimations()
    }

    func setAnimationVisibility(_ visible: Bool) {
        guard animationVisible != visible else { return }
        animationVisible = visible
        refreshAnimations()
    }

    private func oscillate(_ key: String, from: Double, to: Double, duration: Double) -> CABasicAnimation {
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        return animation
    }

    private func refreshAnimations() {
        motion.removeAllAnimations()
        portrait.removeAnimation(forKey: "outlinePulse")
        portrait.shadowOpacity = 0
        aura.sublayers?.forEach { $0.removeFromSuperlayer() }
        magic.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard shouldAnimate else { portrait.removeAnimation(forKey: "poseFade"); return }
        let thinking = petState.activity == "thinking"
        let intense = ["xhigh", "ultra"].contains(petState.effort)
        let amplitude = Double(min(4.5, max(2.0, bounds.height * 0.011)))
        motion.add(oscillate("transform.translation.y", from: -amplitude * 0.35, to: amplitude, duration: thinking ? 2.0 : 2.6), forKey: "float")
        motion.add(oscillate("transform.scale.y", from: 1, to: thinking ? 1.009 : 1.006, duration: thinking ? 1.8 : 2.2), forKey: "breathe")
        motion.add(oscillate("transform.rotation.z", from: -0.0025, to: 0.0025, duration: 3.8), forKey: "sway")
        addAmbientLight()
        guard thinking, portraitRect.width > 0 else { return }

        // Coordinates follow the spell objects in the supplied art, from top-left.
        let rect = portraitRect
        let anchors = ["low": NSPoint(x: 0.733, y: 0.206), "medium": NSPoint(x: 0.711, y: 0.184), "high": NSPoint(x: 0.75, y: 0.26), "xhigh": NSPoint(x: 0.69, y: 0.47), "ultra": NSPoint(x: 0.69, y: 0.47)]
        let normalized = anchors[petState.effort] ?? NSPoint(x: 0.75, y: 0.26)
        let center = CGPoint(x: rect.minX + rect.width * normalized.x, y: rect.maxY - rect.height * normalized.y)
        let radius = rect.height * (intense ? 0.073 : 0.063)
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.frame = CGRect(x: center.x - radius * 1.5, y: center.y - radius * 1.5, width: radius * 3, height: radius * 3)
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.colors = [NSColor(srgbRed: 0.77, green: 0.63, blue: 1, alpha: 0.38).cgColor, NSColor.clear.cgColor]
        glow.locations = [0, 1]
        glow.add(oscillate("opacity", from: 0.35, to: intense ? 0.95 : 0.7, duration: 1.5), forKey: "spellPulse")
        aura.addSublayer(glow)

        let orbit = CAShapeLayer()
        orbit.frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        orbit.path = CGPath(ellipseIn: orbit.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        orbit.fillColor = nil
        orbit.strokeColor = NSColor(srgbRed: 0.83, green: 0.73, blue: 1, alpha: 0.6).cgColor
        orbit.lineWidth = 0.7
        orbit.lineDashPattern = [3, 8]
        orbit.add(oscillate("opacity", from: 0.2, to: 0.7, duration: 1.8), forKey: "orbitPulse")
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = Double.pi * 2
        rotation.duration = intense ? 9 : 13
        rotation.repeatCount = .infinity
        orbit.add(rotation, forKey: "orbit")
        magic.addSublayer(orbit)

        let starCount = ["low": 2, "medium": 3, "high": 4, "xhigh": 8, "ultra": 12][petState.effort] ?? 4
        for index in 0..<starCount {
            let angle = Double(index) * 2.39996
            let distance = radius * (1.0 + CGFloat(index % 3) * 0.25)
            let star = CAShapeLayer()
            let size: CGFloat = index.isMultiple(of: 3) ? 5 : 3.5
            star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            star.position = CGPoint(x: center.x + cos(angle) * distance, y: center.y + sin(angle) * distance)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: size / 2, y: 0))
            path.addLine(to: CGPoint(x: size * 0.62, y: size * 0.38))
            path.addLine(to: CGPoint(x: size, y: size / 2))
            path.addLine(to: CGPoint(x: size * 0.62, y: size * 0.62))
            path.addLine(to: CGPoint(x: size / 2, y: size))
            path.addLine(to: CGPoint(x: size * 0.38, y: size * 0.62))
            path.addLine(to: CGPoint(x: 0, y: size / 2))
            path.addLine(to: CGPoint(x: size * 0.38, y: size * 0.38))
            path.closeSubpath()
            star.path = path
            star.fillColor = NSColor(srgbRed: 0.9, green: 0.84, blue: 1, alpha: 0.9).cgColor
            star.opacity = 0
            let twinkle = CAKeyframeAnimation(keyPath: "opacity")
            twinkle.values = [0, 0, 0.85, 0, 0]
            twinkle.keyTimes = [0, 0.15, 0.4, 0.7, 1]
            twinkle.duration = 2.6 + Double(index % 3) * 0.45
            twinkle.timeOffset = Double(index) * 0.49
            twinkle.repeatCount = .infinity
            star.add(twinkle, forKey: "twinkle")
            let drift = oscillate("transform.translation.y", from: -2, to: Double(radius * 0.35), duration: 1.5 + Double(index % 3) * 0.3)
            drift.timeOffset = Double(index) * 0.3
            star.add(drift, forKey: "drift")
            magic.addSublayer(star)
        }
    }

    private func addAmbientLight() {
        let rect = portraitRect
        guard rect.width > 0 else { return }
        let tier = CodexSelection.efforts.firstIndex(of: petState.effort) ?? 2
        let tint = NSColor(srgbRed: 0.66, green: 0.30, blue: 1, alpha: 1)
        let cyan = NSColor(srgbRed: 0.45, green: 0.91, blue: 1, alpha: 1)
        portrait.shadowColor = tint.cgColor
        portrait.shadowOffset = .zero
        portrait.shadowRadius = 8 + CGFloat(tier) * 3
        portrait.shadowOpacity = 0.9
        portrait.add(oscillate("shadowOpacity", from: 0.6, to: 1, duration: 1.4), forKey: "outlinePulse")
        // Spread the halo beyond the wings so the silhouette cannot hide it.
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.frame = rect.insetBy(dx: -10, dy: 0)
        halo.startPoint = CGPoint(x: 0.5, y: 0.48)
        halo.endPoint = CGPoint(x: 1, y: 1)
        halo.colors = [tint.withAlphaComponent(0.65 + Double(tier) * 0.1).cgColor,
                       tint.withAlphaComponent(0.4).cgColor, NSColor.clear.cgColor]
        halo.locations = [0, 0.55, 1]
        halo.add(oscillate("opacity", from: 0.6, to: 1, duration: 1.8), forKey: "haloPulse")
        aura.addSublayer(halo)

        let floor = CAGradientLayer()
        floor.type = .radial
        floor.frame = CGRect(x: rect.midX - rect.width * 0.5, y: rect.minY - 9,
                             width: rect.width, height: rect.height * 0.20)
        floor.startPoint = CGPoint(x: 0.5, y: 0.5)
        floor.endPoint = CGPoint(x: 1, y: 1)
        floor.colors = [cyan.withAlphaComponent(0.8).cgColor, tint.withAlphaComponent(0.5).cgColor, NSColor.clear.cgColor]
        floor.locations = [0, 0.45, 1]
        floor.add(oscillate("opacity", from: 0.7, to: 1, duration: 1.5), forKey: "floorPulse")
        aura.addSublayer(floor)

        // These rings sit in front of the art and remain legible at 220 points.
        for index in 0..<(2 + tier / 2) {
            let ring = CAShapeLayer()
            let inset = CGFloat(index) * 7
            ring.frame = CGRect(x: rect.minX + inset, y: rect.minY - 4 + CGFloat(index) * 4,
                                width: rect.width - inset * 2, height: rect.height * 0.15)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = (index.isMultiple(of: 2) ? cyan : tint).withAlphaComponent(0.9).cgColor
            ring.lineWidth = index == 0 ? 2 : 1.3
            ring.lineDashPattern = index == 0 ? [12, 5, 3, 5] : [3, 4]
            ring.shadowColor = ring.strokeColor
            ring.shadowOpacity = 1
            ring.shadowRadius = 5
            ring.shadowOffset = .zero
            let flow = CABasicAnimation(keyPath: "lineDashPhase")
            flow.fromValue = 0
            flow.toValue = index == 0 ? -25 : 7
            flow.duration = 1.2 + Double(index) * 0.4
            flow.repeatCount = .infinity
            ring.add(flow, forKey: "runeFlow")
            magic.addSublayer(ring)
        }
        for index in 0..<(1 + tier) {
            let arc = CAShapeLayer()
            arc.frame = rect.insetBy(dx: 2 + CGFloat(index) * 5, dy: rect.height * 0.10)
            arc.path = CGPath(ellipseIn: arc.bounds.insetBy(dx: 2, dy: 2), transform: nil)
            arc.fillColor = nil
            arc.strokeColor = (index.isMultiple(of: 2) ? tint : cyan).cgColor
            arc.lineWidth = 1.7
            arc.strokeStart = 0.03
            arc.strokeEnd = 0.23 + CGFloat(tier) * 0.035
            arc.shadowColor = arc.strokeColor
            arc.shadowOpacity = 1
            arc.shadowRadius = 6
            arc.shadowOffset = .zero
            let sweep = CABasicAnimation(keyPath: "strokeStart")
            sweep.fromValue = 0
            sweep.toValue = 0.76
            let tail = CABasicAnimation(keyPath: "strokeEnd")
            tail.fromValue = 0.24
            tail.toValue = 1
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.1, 0.8, 1]
            let group = CAAnimationGroup()
            group.animations = [sweep, tail, fade]
            group.duration = 2.8 + Double(index) * 0.4
            group.timeOffset = Double(index) * 0.8
            group.repeatCount = .infinity
            arc.add(group, forKey: "energySweep")
            magic.addSublayer(arc)
        }

        for index in 0..<(12 + tier * 8) {
            let particle = CAShapeLayer()
            let size = max(3, rect.height * (index.isMultiple(of: 3) ? 0.042 : 0.018))
            particle.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            let fraction = CGFloat((index * 37 + 13) % 100) / 100
            particle.position = CGPoint(x: rect.minX + rect.width * (0.02 + fraction * 0.96),
                                        y: rect.minY + rect.height * CGFloat((index * 23 + 9) % 85) / 100)
            if index.isMultiple(of: 3) {
                let star = CGMutablePath()
                for point in [CGPoint(x: 0.5, y: 1), CGPoint(x: 0.61, y: 0.61), CGPoint(x: 1, y: 0.5),
                              CGPoint(x: 0.61, y: 0.39), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.39, y: 0.39),
                              CGPoint(x: 0, y: 0.5), CGPoint(x: 0.39, y: 0.61)] {
                    let p = CGPoint(x: point.x * size, y: point.y * size)
                    if star.isEmpty { star.move(to: p) } else { star.addLine(to: p) }
                }
                star.closeSubpath()
                particle.path = star
            } else { particle.path = CGPath(ellipseIn: particle.bounds, transform: nil) }
            particle.fillColor = (index.isMultiple(of: 2) ? cyan : NSColor.white).cgColor
            particle.shadowColor = (index.isMultiple(of: 2) ? cyan : tint).cgColor
            particle.shadowRadius = 7
            particle.shadowOpacity = 1
            particle.shadowOffset = .zero
            particle.opacity = 0
            let rise = CABasicAnimation(keyPath: "transform.translation.y")
            rise.fromValue = -rect.height * 0.12
            rise.toValue = rect.height * 0.28
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 1, 1, 0]
            fade.keyTimes = [0, 0.25, 0.6, 1]
            let group = CAAnimationGroup()
            group.animations = [rise, fade]
            group.duration = 2.4 + Double(index % 4) * 0.4
            group.timeOffset = Double(index) * 0.73
            group.repeatCount = .infinity
            particle.add(group, forKey: "risingLight")
            magic.addSublayer(particle)
        }
    }

    private func flashOnChange() {
        guard shouldAnimate, window?.isVisible == true, portraitRect.width > 0 else { return }
        let ring = CAShapeLayer()
        ring.frame = portraitRect.insetBy(dx: portraitRect.width * 0.12, dy: portraitRect.height * 0.20)
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor(srgbRed: 0.87, green: 0.77, blue: 1, alpha: 0.7).cgColor
        ring.lineWidth = 3
        ring.shadowColor = ring.strokeColor
        ring.shadowRadius = 10
        ring.shadowOpacity = 1
        ring.shadowOffset = .zero
        ring.opacity = 0
        let expand = CABasicAnimation(keyPath: "transform.scale")
        expand.fromValue = 0.45
        expand.toValue = 1.3
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [expand, fade]
        group.duration = 0.7
        magic.addSublayer(ring)
        ring.add(group, forKey: "switchFlash")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak ring] in ring?.removeFromSuperlayer() }
    }

    func renderedBitmap() -> NSBitmapImageRep? {
        layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width), pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext, let layer else { return nil }
        layer.render(in: context)
        return rep
    }

    func verifyMotion() throws {
        layoutSubtreeIfNeeded()
        animationEnabled = true
        refreshAnimations()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let first = motion.presentation()?.transform.m42
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        let second = motion.presentation()?.transform.m42
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            guard let first, let second, abs(first - second) > 0.001 else { throw PetError.missingResource("动画时间轴未推进") }
        }
        animationEnabled = false
        guard (motion.animationKeys() ?? []).isEmpty, (magic.sublayers ?? []).isEmpty else {
            throw PetError.missingResource("关闭动态效果后仍有动画")
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
        } else if event.clickCount == 2 {
            toggleActivity?()
        } else {
            setAnimationVisibility(false)
            window?.performDrag(with: event)
            setAnimationVisibility(true)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let library: CharacterLibrary
    private let defaults: UserDefaults
    private let preferencesDomain: String
    private(set) var state: PetState
    private var petHeight: CGFloat
    private var keepOnTop: Bool
    private let panel: NSPanel
    private let petView = PetView(frame: .zero)
    private var statusItem: NSStatusItem?
    private var isRestoring = true
    private let bridge = CodexBridge()
    private let selectionMonitor = CodexSelectionMonitor()
    private var followCodex: Bool
    private var animationsEnabled: Bool
    private var bridgeLabel = "Codex 联动：等待任务（需信任插件 hooks）"
    private var statusTimer: Timer?
    private var lastRuntimeStatus: Data?

    static var runtimeStatusURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GPTCompanion/runtime-status.json")
    }

    init(library: CharacterLibrary, testing: Bool = false) {
        self.library = library
        preferencesDomain = testing ? "local.gptcompanion.pet.tests.\(UUID().uuidString)" : "local.gptcompanion.pet"
        defaults = testing ? UserDefaults(suiteName: preferencesDomain)! : .standard
        let savedEffort = testing ? "high" : UserDefaults.standard.string(forKey: "effort")
        let savedActivity = testing ? "idle" : UserDefaults.standard.string(forKey: "activity")
        state = PetState(effort: savedEffort.flatMap { CodexSelection.efforts.contains($0) ? $0 : nil } ?? "high", activity: savedActivity == "thinking" ? "thinking" : "idle")
        let savedHeight = testing ? 0 : UserDefaults.standard.double(forKey: "petHeight")
        petHeight = [220.0, 320.0, 440.0].contains(savedHeight) ? savedHeight : 320
        keepOnTop = testing || UserDefaults.standard.object(forKey: "keepOnTop") == nil || UserDefaults.standard.bool(forKey: "keepOnTop")
        followCodex = !testing && (UserDefaults.standard.object(forKey: "followCodex") == nil || UserDefaults.standard.bool(forKey: "followCodex"))
        animationsEnabled = !testing && (UserDefaults.standard.object(forKey: "animationsEnabled") == nil || UserDefaults.standard.bool(forKey: "animationsEnabled"))
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: petHeight, height: petHeight), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "GPT 桌宠"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = keepOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.delegate = self
        petView.frame = NSRect(origin: .zero, size: panel.frame.size)
        petView.autoresizingMask = [.width, .height]
        petView.setAccessibilityElement(true)
        petView.setAccessibilityRole(.image)
        panel.contentView = petView
        petView.animationEnabled = animationsEnabled
        petView.toggleActivity = { [weak self] in self?.toggleActivity() }
        petView.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        applyState(persist: false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "GPT 桌宠")
        item.button?.setAccessibilityLabel("GPT 桌宠")
        statusItem = item
        refreshMenu()
        restorePosition()
        isRestoring = false
        panel.orderFrontRegardless()
        selectionMonitor.onChange = { [weak self] selection in self?.receiveCodexSelection(selection) }
        selectionMonitor.start()
        if CommandLine.arguments.contains("--connect-slider") { selectionMonitor.requestPermission() }
        bridge.onChange = { [weak self] event in self?.receiveCodexEvent(event) }
        bridge.start()
        // Report the authorization of the actual LaunchServices app process.
        // A helper invoked from a trusted terminal can have a different TCC identity.
        writeRuntimeStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.writeRuntimeStatus() }
        refreshMenu()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(screensChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    private func writeRuntimeStatus() {
        let status: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "accessibilityTrusted": CodexSelectionMonitor.isTrusted,
            "followCodex": followCodex,
            "effort": state.effort,
            "activity": state.activity,
            "taskEvent": bridge.current?.event as Any? ?? NSNull(),
            "activeSessionCount": bridge.activeSessionCount,
            "selectionEffort": selectionMonitor.current?.effort as Any? ?? NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]), data != lastRuntimeStatus else { return }
        do {
            let url = Self.runtimeStatusURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            lastRuntimeStatus = data
        } catch { /* Cosmetic diagnostics must not interrupt the pet. */ }
    }

    private func applyState(persist: Bool = true) {
        petView.image = library.images[state.key]
        petView.petState = state
        petView.setAccessibilityLabel("GPT 桌宠，\(state.label)；拖动移动，右键打开菜单，双击切换动作")
        panel.title = "GPT 桌宠 · \(state.label)"
        if persist {
            defaults.set(state.effort, forKey: "effort")
            defaults.set(state.activity, forKey: "activity")
        }
        refreshMenu()
    }

    private func refreshMenu() {
        statusItem?.menu = makeMenu()
        statusItem?.button?.toolTip = "GPT 桌宠 · \(state.label)"
    }

    private func item(_ title: String, action: Selector? = nil, value: String? = nil, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = value
        item.state = checked ? .on : .off
        return item
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let heading = item("GPT 桌宠 · \(state.label)")
        heading.isEnabled = false
        menu.addItem(heading)
        let selectionNote: String
        if let selection = selectionMonitor.current {
            selectionNote = "滑块已同步：\(selection.label)"
        } else if !CodexSelectionMonitor.isTrusted {
            selectionNote = "滑块联动需要辅助功能权限"
        } else {
            selectionNote = "跟随已开启 · 尚未识别思考档位"
        }
        let note = item(followCodex ? selectionNote : "手动模式")
        note.isEnabled = false
        menu.addItem(note)
        let taskNote = item(bridgeLabel)
        taskNote.isEnabled = false
        menu.addItem(taskNote)
        menu.addItem(.separator())
        menu.addItem(item("跟随 Codex", action: #selector(toggleFollowCodex), checked: followCodex))
        if !CodexSelectionMonitor.isTrusted { menu.addItem(item("连接思考程度滑块…", action: #selector(connectSlider))) }
        let effortMenu = NSMenu()
        for value in CodexSelection.efforts {
            effortMenu.addItem(item(CodexSelection(effort: value).label, action: #selector(chooseEffort(_:)), value: value, checked: state.effort == value))
        }
        let effort = item("思考程度")
        effort.submenu = effortMenu
        menu.addItem(effort)
        let activityMenu = NSMenu()
        for (value, label) in [("idle", "待机"), ("thinking", "思考中")] {
            activityMenu.addItem(item(label, action: #selector(chooseActivity(_:)), value: value, checked: state.activity == value))
        }
        let activity = item("动作")
        activity.submenu = activityMenu
        menu.addItem(activity)
        let sizeMenu = NSMenu()
        for (value, label) in [(220, "小"), (320, "中"), (440, "大")] {
            sizeMenu.addItem(item(label, action: #selector(chooseSize(_:)), value: String(value), checked: Int(petHeight) == value))
        }
        let size = item("大小")
        size.submenu = sizeMenu
        menu.addItem(size)
        menu.addItem(item("动态效果", action: #selector(toggleAnimations), checked: animationsEnabled))
        menu.addItem(item("始终置顶", action: #selector(toggleOnTop), checked: keepOnTop))
        menu.addItem(.separator())
        menu.addItem(item(panel.isVisible ? "隐藏桌宠" : "显示桌宠", action: #selector(toggleVisibility)))
        menu.addItem(item("回到屏幕右下角", action: #selector(resetPosition)))
        menu.addItem(item("使用说明", action: #selector(showHelp)))
        menu.addItem(.separator())
        let quit = item("退出 GPT 桌宠", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        return menu
    }

    @objc private func chooseEffort(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, CodexSelection.efforts.contains(value) else { return }
        useManualMode()
        state.effort = value
        applyState()
    }

    @objc private func chooseActivity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, ["idle", "thinking"].contains(value) else { return }
        state.activity = value
        applyState()
    }

    @objc private func toggleActivity() {
        state.activity = state.activity == "idle" ? "thinking" : "idle"
        applyState()
    }

    private func useManualMode() {
        followCodex = false
        defaults.set(false, forKey: "followCodex")
    }

    @objc private func toggleFollowCodex() {
        followCodex.toggle()
        defaults.set(followCodex, forKey: "followCodex")
        if followCodex {
            selectionMonitor.refresh()
            bridge.refresh(force: true)
        }
        refreshMenu()
    }

    private func receiveCodexEvent(_ event: BridgeEvent?) {
        if let event {
            let activity = event.activity == "thinking" ? "任务进行中" : "任务已结束"
            bridgeLabel = "Codex 联动：\(activity)\(event.effort == nil ? "（思考程度未识别）" : "")"
            if followCodex {
                state.activity = event.activity
                state.effort = CodexSelection.resolveEffort(selection: selectionMonitor.current, eventEffort: event.effort, current: state.effort)
                applyState()
            }
        } else {
            bridgeLabel = "Codex 联动：等待任务（需信任插件 hooks）"
            if followCodex { state.activity = "idle"; applyState() }
        }
        refreshMenu()
    }

    @objc private func connectSlider() { selectionMonitor.requestPermission() }

    private func receiveCodexSelection(_ selection: CodexSelection) {
        guard followCodex else { return }
        // Slider changes affect the character, while task hooks still own its pose.
        state.effort = CodexSelection.resolveEffort(selection: selection, eventEffort: bridge.current?.effort, current: state.effort)
        applyState()
    }

    @objc private func chooseSize(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let height = Double(text), [220.0, 320.0, 440.0].contains(height) else { return }
        let bottomCenter = NSPoint(x: panel.frame.midX, y: panel.frame.minY)
        petHeight = height
        panel.setFrame(NSRect(x: bottomCenter.x - height / 2, y: bottomCenter.y, width: height, height: height), display: true)
        clampPosition()
        defaults.set(height, forKey: "petHeight")
        refreshMenu()
    }

    @objc private func toggleOnTop() {
        keepOnTop.toggle()
        panel.level = keepOnTop ? .floating : .normal
        defaults.set(keepOnTop, forKey: "keepOnTop")
        refreshMenu()
    }

    @objc private func toggleVisibility() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        petView.setAnimationVisibility(panel.isVisible)
        refreshMenu()
    }

    @objc private func toggleAnimations() {
        animationsEnabled.toggle()
        defaults.set(animationsEnabled, forKey: "animationsEnabled")
        petView.animationEnabled = animationsEnabled
        refreshMenu()
    }

    private func restorePosition() {
        if let x = defaults.object(forKey: "positionX") as? Double,
           let y = defaults.object(forKey: "positionY") as? Double, x.isFinite, y.isFinite {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            clampPosition()
        } else {
            resetPosition()
        }
    }

    private func clampPosition() {
        let screen = NSScreen.screens.max { lhs, rhs in
            let left = lhs.visibleFrame.intersection(panel.frame)
            let right = rhs.visibleFrame.intersection(panel.frame)
            return max(0, left.width) * max(0, left.height) < max(0, right.width) * max(0, right.height)
        } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let x = min(max(panel.frame.minX, area.minX), max(area.minX, area.maxX - panel.frame.width))
        let y = min(max(panel.frame.minY, area.minY), max(area.minY, area.maxY - panel.frame.height))
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func resetPosition() {
        guard let area = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: area.maxX - petHeight - 24, y: area.minY + 24))
        clampPosition()
        if !panel.isVisible { panel.orderFrontRegardless() }
        petView.setAnimationVisibility(true)
        refreshMenu()
    }

    @objc private func screensChanged() { clampPosition() }

    func windowDidMove(_ notification: Notification) {
        guard !isRestoring else { return }
        defaults.set(panel.frame.minX, forKey: "positionX")
        defaults.set(panel.frame.minY, forKey: "positionY")
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "GPT 桌宠"
        alert.informativeText = "拖动人物：移动位置\n右键人物：切换五档形象和大小，开关动态效果\n双击人物：手动切换待机／思考中\n菜单栏星光图标：隐藏、显示或退出\n\n待机时轻微呼吸、浮动；施法时有星光和缓慢旋转的光环。Ultra 使用独立的四翼、晶冠和三重星环立绘，光效更强。动态效果遵循系统「减少动态效果」设置。\n\n开启「跟随 Codex」，并在 macOS 辅助功能中允许 GPT 桌宠。打开 Codex 的思考程度选择器，拖动到 Light、Medium、High、Extra High 或 Ultra，桌宠会直接换形象，不用发送消息；关闭选择器后保留上次读到的程度。旧版四档滑块仍受支持。\n\n任务开始、完成和中断仍由插件 hooks 同步，首次使用须在 Codex 中信任 hooks。手动切换思考程度会暂停联动，可重新勾选恢复；切换动作不会关闭思考程度联动，动作仍会随下一次任务事件更新。"
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func selfTest() throws {
        // Exercise the actual menu handlers and slider callback together.
        defer { defaults.removePersistentDomain(forName: preferencesDomain) }
        followCodex = true
        let action = NSMenuItem()
        action.representedObject = "thinking"
        chooseActivity(action)
        receiveCodexSelection(CodexSelection(effort: "medium"))
        guard followCodex, state.activity == "thinking", state.effort == "medium" else {
            throw PetError.missingResource("右键动作后滑块联动")
        }
        toggleActivity()
        receiveCodexSelection(CodexSelection(effort: "low"))
        guard followCodex, state.activity == "idle", state.effort == "low" else {
            throw PetError.missingResource("双击动作后滑块联动")
        }
        followCodex = false
        petView.animationEnabled = false
        var verified: [[String: Any]] = []
        for effort in CodexSelection.efforts {
            for activity in ["idle", "thinking"] {
                state = PetState(effort: effort, activity: activity)
                applyState(persist: false)
                guard petView.image === library.images[state.key],
                      let rep = petView.renderedBitmap() else {
                    throw PetError.missingResource(state.key)
                }
                let transparent = rep.colorAt(x: 0, y: 0)?.alphaComponent == 0
                let visible = (0..<rep.pixelsHigh).contains { y in
                    (0..<rep.pixelsWide).contains { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 }
                }
                guard transparent && visible else { throw PetError.missingResource("\(state.key) 透明渲染") }
                verified.append(["state": state.key, "label": state.label, "transparent": transparent, "visible": visible])
            }
        }
        state = PetState(effort: "high", activity: "idle")
        applyState(persist: false)
        let now = Date().timeIntervalSince1970
        for (label, effort) in [("6.1 Sol Light, 1 of 5.", "low"), ("6.1 Sol Medium, 2 of 5.", "medium"), ("6.1 Sol High, 3 of 5.", "high"), ("6.1 Sol Extra High, 4 of 5.", "xhigh"), ("6.1 Sol Ultra, 5 of 5.", "ultra")] {
            guard CodexSelection.powerControl(role: "AXMenuItem", name: "Power", help: label, classes: [])?.effort == effort else { throw PetError.missingResource("Power 档位说明解析") }
        }
        // The shipped zh-CN picker uses these strings, not literal English names.
        for (label, effort) in [("轻度", "low"), ("中", "medium"), ("高", "high"), ("极高", "xhigh"), ("Ultra", "ultra")] {
            let announcement = "6.1 Sol \(label)，第 2 项，共 5 项。\n使用左右箭头键调整强度"
            guard CodexSelection.powerControl(role: "AXMenuItem", name: "强度", help: announcement, classes: [])?.effort == effort,
                  CodexSelection.powerControl(role: "AXMenuItem", name: "", help: announcement, classes: [], description: "强度")?.effort == effort else { throw PetError.missingResource("中文强度控件解析") }
        }
        for (name, label, effort) in [("強度", "輕度", "low"), ("效能", "極高", "xhigh")] {
            guard CodexSelection.powerControl(role: "AXMenuItem", name: name, help: "6.1 Sol \(label)，第 2 項，共 5 項。", classes: [])?.effort == effort else { throw PetError.missingResource("繁体强度控件解析") }
        }
        // Budget-limited polls must reach a late control, even with duplicate roots.
        var scan = CodexSelectionScan<Int>()
        scan.reset([0, 0])
        var reached = false
        for _ in 0..<8 {
            for _ in 0..<120 {
                guard let node = scan.next() else { break }
                if node == 850 { reached = true; break }
                scan.append([node + 1, node])
            }
            if reached { break }
        }
        guard reached else { throw PetError.missingResource("长窗口分批扫描未前进") }
        guard CodexSelection.powerControl(role: "AXTextArea", name: "Power", help: "Ultra", classes: []) == nil,
              CodexSelection.powerControl(role: "AXButton", name: "Send", help: "Ultra", classes: []) == nil,
              CodexSelection.powerControl(role: "AXButton", name: "普通按钮", help: "极高", classes: []) == nil,
              CodexSelection.powerLabel("6.1 Sol 极高，已锁定") == nil,
              CodexSelection.powerLabel("6.1 Sol Highlight") == nil,
              CodexSelection.powerLabel("6.1 Sol Ultra, locked") == nil else { throw PetError.missingResource("Power 控件范围") }
        for (index, effort) in ["low", "medium", "high", "xhigh"].enumerated() {
            guard CodexSelection.slider(value: Double(index), minimum: 0, maximum: 3)?.effort == effort else { throw PetError.missingResource("四档滑块映射") }
        }
        for (index, effort) in CodexSelection.efforts.enumerated() {
            guard CodexSelection.slider(value: Double(index), minimum: 0, maximum: 4)?.effort == effort else { throw PetError.missingResource("五档滑块映射") }
        }
        guard CodexSelection.named("Extra High")?.effort == "xhigh",
              CodexSelection.named("Light")?.effort == "low",
              CodexSelection.named("Ultra")?.effort == "ultra",
              CodexSelection.slider(value: 4, minimum: 0, maximum: 3) == nil,
              CodexSelection.slider(value: .nan, minimum: 0, maximum: 4) == nil,
              CodexSelection.resolveEffort(selection: nil, eventEffort: "ultra", current: "high") == "ultra",
              CodexSelection.slider(value: 40, minimum: 0, maximum: 100) == nil,
              CodexSelection.resolveEffort(selection: CodexSelection(effort: "high"), eventEffort: "xhigh", current: "xhigh") == "high" else { throw PetError.missingResource("滑块优先级") }
        let busy = BridgeEvent(schemaVersion: 1, sessionId: "a", turnId: "1", event: "UserPromptSubmit", effort: "xhigh", activity: "thinking", timestamp: now - 10)
        let done = BridgeEvent(schemaVersion: 1, sessionId: "b", turnId: "2", event: "Stop", effort: "high", activity: "idle", timestamp: now)
        let old = BridgeEvent(schemaVersion: 1, sessionId: "c", turnId: "3", event: "UserPromptSubmit", effort: "high", activity: "thinking", timestamp: now - 7 * 3600)
        guard CodexBridge.select([busy, done]) == busy,
              CodexBridge.select([done]) == done,
              CodexBridge.select([old, done]) == done else {
            throw PetError.missingResource("多会话状态选择")
        }
        func turnID(_ started: TimeInterval) -> String {
            let prefix = String(format: "%012llx", UInt64(started * 1000))
            return "\(prefix.prefix(8))-\(prefix.suffix(4))-7000-8000-000000000000"
        }
        let abandoned = BridgeEvent(schemaVersion: 1, sessionId: "same", turnId: turnID(now - 100), event: "UserPromptSubmit", effort: "high", activity: "thinking", timestamp: now - 100)
        let newerDone = BridgeEvent(schemaVersion: 1, sessionId: "same", turnId: turnID(now - 30), event: "Stop", effort: "high", activity: "idle", timestamp: now - 5)
        let newerBusy = BridgeEvent(schemaVersion: 1, sessionId: "same", turnId: turnID(now - 20), event: "UserPromptSubmit", effort: "high", activity: "thinking", timestamp: now - 20)
        let delayedStop = BridgeEvent(schemaVersion: 1, sessionId: "same", turnId: abandoned.turnId, event: "Stop", effort: "high", activity: "idle", timestamp: now)
        guard CodexBridge.select([abandoned, newerDone], now: now) == newerDone,
              CodexBridge.select([newerDone, abandoned], now: now) == newerDone,
              CodexBridge.select([newerBusy, delayedStop], now: now) == newerBusy,
              CodexBridge.select([delayedStop, newerBusy], now: now) == newerBusy,
              CodexBridge.select([abandoned, newerDone, busy], now: now) == busy else {
            throw PetError.missingResource("历史轮次完成状态归并")
        }
        followCodex = true
        receiveCodexEvent(busy)
        guard state.activity == "thinking" else { throw PetError.missingResource("开始任务后未施法") }
        receiveCodexEvent(CodexBridge.select([abandoned, newerDone], now: now))
        guard state.activity == "idle" else { throw PetError.missingResource("完成任务后未待机") }
        let interrupted = BridgeEvent(schemaVersion: 1, sessionId: "a", turnId: busy.turnId, event: "Interrupt", effort: "xhigh", activity: "idle", timestamp: now)
        receiveCodexEvent(interrupted)
        guard state.activity == "idle" else { throw PetError.missingResource("中断任务后未待机") }
        receiveCodexEvent(CodexBridge.select([newerDone, busy], now: now))
        guard state.activity == "thinking" else { throw PetError.missingResource("其他聊天运行时未保持施法") }
        receiveCodexEvent(nil)
        guard state.activity == "idle" else { throw PetError.missingResource("无任务时未待机") }
        followCodex = false
        state = PetState(effort: "high", activity: "idle")
        applyState(persist: false)
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        panel.orderFrontRegardless()
        try petView.verifyMotion()
        panel.orderOut(nil)
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "states": verified, "bridgeSelection": "passed", "motion": "passed", "menuItems": makeMenu().items.map(\.title)], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

}

let app = NSApplication.shared
do {
    let testing = CommandLine.arguments.contains("--self-test")
    if CommandLine.arguments.contains("--permission-status") {
        if let data = try? Data(contentsOf: AppDelegate.runtimeStatusURL),
           let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = status["pid"] as? Int, pid != ProcessInfo.processInfo.processIdentifier, kill(pid_t(pid), 0) == 0,
           let trusted = status["accessibilityTrusted"] as? Bool {
            print("{\"trusted\":\(trusted),\"source\":\"running-app\"}")
        } else {
            print("{\"trustedInThisProcess\":\(CodexSelectionMonitor.isTrusted),\"runningAppStatusAvailable\":false}")
        }
        exit(0)
    }
    let library = try CharacterLibrary()
    let delegate = AppDelegate(library: library, testing: testing)
    if testing {
        app.setActivationPolicy(.accessory)
        try delegate.selfTest()
    } else {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.gptcompanion.pet")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = running.first {
            existing.activate(options: [.activateAllWindows])
        } else {
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
} catch {
    if CommandLine.arguments.contains("--self-test") {
        fputs("GPT 桌宠检查失败：\(error.localizedDescription)\n", stderr)
        exit(1)
    }
    app.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = "GPT 桌宠无法启动"
    alert.informativeText = error.localizedDescription
    alert.runModal()
    exit(1)
}
