// Claude Pet — a floating Pokémon for every Claude Code agent you're running,
// in the spirit of the Codex desktop pet.
//
// Status comes from herdr (`herdr agent list`) when it's running, and from
// Claude Code hooks (`ClaudePet --hook`, added by install.sh) for sessions
// outside herdr:
//   blocked → hops and flashes red, like it's taking hits
//   done    → jumps for joy over "<Pokémon> is done" (until you view the agent)
//   working → walks back and forth over a row of dots
//   idle    → steps in place, falls asleep (z's) after a quiet spell, and
//             goes back in its Poké Ball after 12 hours
// Only a pet off the ground casts a shadow.
//
// Each agent keeps its Pokémon (by herdr pane or session). Click a pet to jump to its
// agent, drag it anywhere, right-click to change Pokémon or line them up.
// Sprites come from fetch-sprites.sh. `ClaudePet --render <png>` writes a
// sheet of every mood and the whole roster, for checking without a screen.

import AppKit

// MARK: - Roster and sprites

let roster = [
    "bulbasaur", "charmander", "squirtle", "pikachu", "oddish", "psyduck", "poliwag", "abra",
    "geodude", "slowpoke", "gastly", "gengar", "cubone", "magikarp", "gyarados", "lapras", "ditto",
    "eevee", "vaporeon", "jolteon", "flareon", "espeon", "umbreon", "leafeon", "glaceon", "sylveon",
    "kabuto", "snorlax", "articuno", "zapdos", "moltres", "dragonite",
]

/// A follower sheet: square frames for down ×2, up ×2, left ×2, and
/// optionally right ×2 (otherwise left is mirrored).
struct SpriteSheet {
    let frames: [CGImage]
    /// The highest row any frame draws in, for stacking pets in a column by their real height.
    let top: Int
    /// The farthest any frame reaches from its centre column, for spacing pets in a row.
    let halfWidth: Int

    static let directory = NSHomeDirectory() + "/.local/share/claude-pet/sprites"
    static var cache: [String: SpriteSheet] = [:]

    static func named(_ name: String) -> SpriteSheet? {
        if let cached = cache[name] { return cached }
        guard let frames = frames(in: "\(directory)/\(name).png"), frames.count >= 6 else { return nil }
        let extents = frames.map(visibleExtent)
        let sheet = SpriteSheet(frames: frames, top: extents.map(\.top).min() ?? 0,
                                halfWidth: extents.map(\.halfWidth).max() ?? 0)
        cache[name] = sheet
        return sheet
    }

    /// Where an image's visible pixels reach: the first row with any, and the
    /// farthest they get from the centre column.
    static func visibleExtent(of image: CGImage) -> (top: Int, halfWidth: Int) {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = { context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                             return context.data?.assumingMemoryBound(to: UInt8.self) }()
        else { return (0, w / 2) }
        var top = h, first = w, last = -1
        for row in 0..<h {
            for x in 0..<w where pixels[(row * w + x) * 4 + 3] > 0 {
                top = min(top, row)
                first = min(first, x)
                last = max(last, x)
            }
        }
        guard last >= 0 else { return (h, 0) }
        return (top, max(w / 2 - first, last + 1 - w / 2))
    }

    /// Decodes a row of square frames and makes the background (palette entry 0) transparent.
    static func frames(in path: String) -> [CGImage]? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        if let key = backgroundColor(in: data),
           let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            for i in stride(from: 0, to: image.width * image.height * 4, by: 4)
            where abs(Int(pixels[i]) - Int(key.r)) < 3
                && abs(Int(pixels[i + 1]) - Int(key.g)) < 3
                && abs(Int(pixels[i + 2]) - Int(key.b)) < 3 {
                pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0
            }
        }

        guard let keyed = context.makeImage() else { return nil }
        let size = image.height
        return (0..<image.width / size).compactMap {
            keyed.cropping(to: CGRect(x: $0 * size, y: 0, width: size, height: size))
        }
    }

    /// The first PLTE entry, which Gen 3 graphics treat as transparent.
    static func backgroundColor(in png: Data) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let bytes = [UInt8](png)
        var offset = 8 // past the PNG signature
        while offset + 11 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) == "PLTE" {
                return (bytes[offset + 8], bytes[offset + 9], bytes[offset + 10])
            }
            offset += 12 + length
        }
        return nil
    }
}

/// FireRed's overworld item ball (16×16), thrown in to bring a resting pet back.
let pokeball = SpriteSheet.frames(in: "\(SpriteSheet.directory)/_pokeball.png")?.first

/// Draws a sprite with crisp pixels into a flipped view, optionally mirrored or faded.
func drawPixelSprite(_ image: CGImage, in rect: NSRect, mirrored: Bool = false, alpha: CGFloat = 1) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.interpolationQuality = .none
    context.setAlpha(alpha)
    // The view is flipped; flip back so the image draws upright.
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    if mirrored {
        context.translateBy(x: rect.width, y: 0)
        context.scaleBy(x: -1, y: 1)
    }
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}

// MARK: - Status art

let iconColors: [Character: NSColor] = [
    "B": NSColor(srgbRed: 0.341, green: 0.412, blue: 0.969, alpha: 1), // working dots
    "S": NSColor(srgbRed: 0.455, green: 0.471, blue: 0.533, alpha: 1), // snoring z's
]
/// The hit flash on a pet that needs you.
let hitRed = NSColor(srgbRed: 1, green: 0.12, blue: 0.12, alpha: 1)

/// The CTX bar: a Gen 3 HP bar that shows how much of an agent's context is left.
enum ContextBar {
    static let outline = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1)
    static let body = NSColor(srgbRed: 0.28, green: 0.28, blue: 0.31, alpha: 1)
    static let label = NSColor(srgbRed: 0.97, green: 0.69, blue: 0.19, alpha: 1)
    static let border = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1)
    static let empty = NSColor(srgbRed: 0.22, green: 0.22, blue: 0.25, alpha: 1)
    /// (light, shade) for more than half left, more than a fifth, and the rest.
    static let green = (NSColor(srgbRed: 0.44, green: 0.97, blue: 0.66, alpha: 1), NSColor(srgbRed: 0.28, green: 0.78, blue: 0.47, alpha: 1))
    static let yellow = (NSColor(srgbRed: 0.97, green: 0.88, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.78, green: 0.66, blue: 0.03, alpha: 1))
    static let red = (NSColor(srgbRed: 0.97, green: 0.35, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.69, green: 0.22, blue: 0.19, alpha: 1))
    /// "C", "T", "X" in a 3x5 pixel font.
    static let glyphs = [
        [".##", "#..", "#..", "#..", ".##"],
        ["###", ".#.", ".#.", ".#.", ".#."],
        ["#.#", "#.#", ".#.", "#.#", "#.#"],
    ]
}

// MARK: - Agents (from herdr)

/// One coding agent: a herdr pane, or a Claude Code session reported by the
/// pet's hooks (its `pane` is then "session:<id>").
struct Agent {
    let pane: String
    let status: String // idle, working, blocked, done, unknown
    let title: String
    let project: String
    /// For hook sessions: the terminal app to bring forward, and Claude's process.
    var app: String? = nil
    var pid: pid_t? = nil
    /// How full its context window is, 0 to 1, when known.
    var contextUsed: Double? = nil

    var label: String { title.isEmpty ? project : "\(project): \(title)" }
}

/// Runs a tool and returns its output, or nil if it can't run or fails.
@discardableResult
func capture(_ path: String, _ args: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

// MARK: - Processes

/// A process's parent and short name, from the kernel.
func processInfo(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return (info.kp_eproc.e_ppid, name)
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// The app a process runs inside, such as its terminal, found by walking up its parents.
func hostApp(of pid: pid_t) -> NSRunningApplication? {
    var current = pid
    for _ in 0..<12 {
        if let app = NSRunningApplication(processIdentifier: current), app.bundleIdentifier != nil { return app }
        guard let parent = processInfo(current)?.ppid, parent > 1 else { return nil }
        current = parent
    }
    return nil
}

/// Switches to an agent: through herdr for its panes, otherwise by bringing its terminal forward.
func focus(_ agent: Agent) {
    guard agent.pane.hasPrefix(HookSessions.prefix) else {
        Herdr.focus(agent.pane)
        return
    }
    HookSessions.markSeen(String(agent.pane.dropFirst(HookSessions.prefix.count)))
    let app = agent.app.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        ?? agent.pid.flatMap(hostApp(of:))
    app?.activate()
}

// MARK: - herdr

enum Herdr {
    /// herdr wherever it's installed; apps don't get the shell's PATH.
    static let path = [
        NSHomeDirectory() + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    @discardableResult
    static func run(_ args: [String]) -> Data? {
        guard let path else { return nil }
        return capture(path, args)
    }

    /// nil when herdr isn't installed or running.
    static func agents() -> [Agent]? {
        guard let data = run(["agent", "list"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let list = result["agents"] as? [[String: Any]] else { return nil }
        return list.compactMap { entry in
            guard let pane = entry["pane_id"] as? String else { return nil }
            let cwd = entry["foreground_cwd"] as? String ?? entry["cwd"] as? String ?? ""
            return Agent(
                pane: pane,
                status: entry["agent_status"] as? String ?? "unknown",
                title: entry["terminal_title_stripped"] as? String ?? "",
                project: (cwd as NSString).lastPathComponent
            )
        }
    }

    /// Switches herdr to the agent (marking a done agent as seen) and raises
    /// the terminal herdr is open in.
    static func focus(_ pane: String) {
        DispatchQueue.global().async {
            run(["agent", "focus", pane])
            let client = clientPID()
            DispatchQueue.main.async {
                client.flatMap(hostApp(of:))?.activate()
            }
        }
    }

    /// The herdr client (not the background server), which runs in your terminal.
    static func clientPID() -> pid_t? {
        guard let data = capture("/bin/ps", ["-axo", "pid=,args="]) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = pid_t(parts[0]),
                  (String(parts[1]) as NSString).lastPathComponent == "herdr",
                  !parts.dropFirst(2).contains("server") else { continue }
            return pid
        }
        return nil
    }
}

// MARK: - Claude Code hooks (sessions outside herdr)

/// Claude Code sessions reported by the pet's own hooks, so it works without
/// herdr. `ClaudePet --hook` runs on each hook event and keeps one JSON file
/// per session; the app reads them alongside herdr's agents.
enum HookSessions {
    static let directory = NSHomeDirectory() + "/.local/share/claude-pet/sessions"
    static let prefix = "session:"

    struct Record: Codable {
        var session: String
        var status: String
        var cwd: String
        var pid: Int32?
        var started: Double
        var updated: Double
        var app: String?        // the terminal's bundle id, outside herdr
        var herdrPane: String?  // set when the session runs inside herdr
        var transcript: String?
        var model: String?      // from SessionStart, when Claude Code includes it
    }

    static func url(_ session: String) -> URL { URL(fileURLWithPath: "\(directory)/\(session).json") }

    static func read(_ url: URL) -> Record? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    static func write(_ record: Record) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: url(record.session), options: .atomic)
    }

    /// Runs as a Claude Code hook: records the session's state from the event on stdin.
    /// Prints nothing, since some events show a hook's output to Claude.
    static func handleHook() {
        let started = Date().timeIntervalSince1970 // the event's time, as hooks run in the background
        guard let event = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
              let session = event["session_id"] as? String, !session.isEmpty,
              !session.contains("/"),
              let name = event["hook_event_name"] as? String else { return }

        if name == "SessionEnd" {
            try? FileManager.default.removeItem(at: url(session))
            return
        }
        let status: String
        switch name {
        case "SessionStart", "StopFailure": status = "idle"
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure": status = "working"
        case "PermissionRequest", "Notification": status = "blocked" // Notification is matched to prompts only
        case "Stop": status = "done"
        default: return
        }

        var record = read(url(session)) ?? Record(session: session, status: status, cwd: "", pid: nil,
                                                  started: started, updated: 0)
        // A hook that started earlier but finished later mustn't undo a newer state.
        guard started >= record.updated else { return }
        let env = ProcessInfo.processInfo.environment
        record.status = status
        record.updated = started
        record.cwd = event["cwd"] as? String ?? record.cwd
        record.transcript = event["transcript_path"] as? String ?? record.transcript
        record.model = event["model"] as? String ?? record.model
        record.pid = claudePID()
        record.herdrPane = env["HERDR_PANE_ID"]
        record.app = record.herdrPane == nil ? env["__CFBundleIdentifier"] : nil
        write(record)
    }

    /// Claude Code's process: the hook's parent, skipping any shell in between.
    static func claudePID() -> pid_t {
        var pid = getppid()
        for _ in 0..<4 {
            guard let info = processInfo(pid), ["sh", "bash", "zsh", "dash", "fish"].contains(info.name) else { break }
            pid = info.ppid
        }
        return pid
    }

    /// Every live session, including ones inside herdr. Drops (and deletes)
    /// ones whose Claude has exited.
    static func liveRecords() -> [Record] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let now = Date().timeIntervalSince1970
        var records: [Record] = []
        for file in files where file.hasSuffix(".json") {
            let url = URL(fileURLWithPath: "\(directory)/\(file)")
            guard var record = read(url) else { continue }
            let gone = record.pid.map { !isAlive($0) } ?? (now - record.updated > 86_400)
            if gone {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if (record.status == "working" || record.status == "blocked") && wasInterrupted(record) {
                record.status = "idle"
                write(record)
            }
            records.append(record)
        }
        return records
    }

    /// The sessions to show as their own pets, oldest first: all of them, less
    /// the ones inside herdr while herdr is reporting them itself.
    static func agents(from records: [Record], herdrRunning: Bool) -> [Agent] {
        records.filter { !($0.herdrPane != nil && herdrRunning) }.sorted { $0.started < $1.started }.map {
            Agent(pane: prefix + $0.session, status: $0.status, title: "",
                  project: ($0.cwd as NSString).lastPathComponent, app: $0.app, pid: $0.pid)
        }
    }

    /// Whether you pressed Esc since the last hook. Claude Code runs no hook
    /// for an interrupt or a denied prompt, but writes a marker to the transcript.
    static func wasInterrupted(_ record: Record) -> Bool {
        guard let path = record.transcript,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              modified.timeIntervalSince1970 > record.updated,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        // The latest message, skipping the metadata lines written after it.
        let last = tail.split(separator: "\n").last {
            $0.contains("\"type\":\"user\"") || $0.contains("\"type\":\"assistant\"")
        }
        return last?.contains("[Request interrupted by user") ?? false
    }

    /// Clears a finished session's "done" once you've clicked through to it.
    static func markSeen(_ session: String) {
        guard var record = read(url(session)), record.status == "done" else { return }
        record.status = "idle"
        write(record)
    }
}

// MARK: - Pet

/// `stored` is back in its Poké Ball: 12 hours unused, or recalled from the menu.
enum Mood { case idle, working, alert, done, sleeping, stored }

/// Going into the Poké Ball (a red glow, shrinking away to nothing) or coming
/// out of it (a white flash).
struct Transition {
    enum Kind { case recall, release }
    let kind: Kind
    let start: Int // tick it began
    var ticks: Int { kind == .recall ? 8 : 6 }
}

/// When each herdr pane last worked or asked for input, kept across restarts.
enum LastActive {
    static let key = "lastActive"

    static func get(_ pane: String) -> Date? {
        (UserDefaults.standard.dictionary(forKey: key)?[pane] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func set(_ pane: String, _ date: Date) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[pane] = date.timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// How big the pets are, from the Size slider in the right-click menu. The
/// slider moves freely from small to large but holds for a moment at each of
/// the three sizes on the way.
enum PetSize {
    static let small: CGFloat = 1.5, medium: CGFloat = 3, large: CGFloat = 4.5
    static let locks = [small, medium, large]
    /// How close the knob has to come to one of the sizes before it holds there.
    static let pull: CGFloat = 0.3

    /// The slider's position, kept across restarts.
    static var saved: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: "petSize")
            return value == 0 ? medium : min(large, max(small, CGFloat(value)))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "petSize") }
    }

    /// The slider's value, pulled onto a size when it's close to one.
    static func settle(_ value: CGFloat) -> CGFloat { locks.first { abs($0 - value) <= pull } ?? value }

    /// Points per sprite pixel: whole pixels on a Retina screen, so the pixel art stays crisp.
    static func scale(for value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
}

final class PetView: NSView {
    static let width: CGFloat = 320
    /// Screen points per sprite pixel, from the Size slider (3 is medium).
    static var scale = PetSize.scale(for: PetSize.saved)
    static func height(for sheet: SpriteSheet) -> CGFloat {
        spriteTop + CGFloat(sheet.frames[0].width) * scale + bottomPad
    }
    /// Room under the ground for the working dots and the done caption.
    static let bottomPad: CGFloat = 22
    static let captionFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    /// Off for the render modes, so their pretend agents aren't saved.
    static var recordsActivity = true
    /// How far the "is done" caption reaches below the ground. The stack leaves
    /// this much room under every pet, so a caption never covers the pet below.
    static var captionDepth: CGFloat {
        2 + ("Ag" as NSString).size(withAttributes: [.font: captionFont]).height + 4
    }
    // Layout, top-down (the view is flipped): room for jumps and drifting z's,
    // the sprite, then room for the dots or the caption (its status, or "is
    // done") under it. The sprite is centred across the window.
    static let spriteTop: CGFloat = 40
    /// How far it paces either side while working. Less in a row, where
    /// neighbours stand close enough that they'd walk into each other.
    var pace = PetView.columnPace
    static let columnPace: CGFloat = 12
    static let rowPace: CGFloat = 4

    /// Where the sprite rests: the middle of the window, so the caption under
    /// it can centre. At a screen edge the window hangs past it (see PetPanel).
    var homeX: CGFloat { (bounds.width - spriteSize) / 2 }

    private(set) var agent: Agent
    private(set) var pokemon: String
    private var sheet: SpriteSheet

    var onMoved: ((PetView) -> Void)?
    var onChoosePokemon: ((PetView, String) -> Void)?
    var onLineUp: (() -> Void)?
    /// Called as the Size slider moves, with its value.
    var onSize: ((CGFloat) -> Void)?
    /// Called once it has gone into its ball, to close up the gap it leaves.
    var onVanish: (() -> Void)?
    /// Called when it's coming back out, to make room and throw its ball in.
    var onSummon: ((PetView) -> Void)?
    /// The pets resting out of sight, for Let Out.
    var restingPets: (() -> [PetView])?
    /// The Pokémon other live agents have, so the picker can show them as taken.
    var otherPokemon: (() -> Set<String>)?

    var mood = Mood.idle
    var tick = Int.random(in: 0..<64) // so pets don't move in lockstep
    var walkX: CGFloat = 0
    var walkDirection: CGFloat = 1
    var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            // Lift the hovered pet above its neighbours so its label shows on top.
            window?.level = hovering ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .floating
        }
    }
    var hopUntil = Date.distantPast
    var labelUntil = Date.distantPast
    var lastBusy: Date
    var previousStatus: String?
    var finishedAt: Date?
    var contextUsed: Double?
    var transition: Transition?
    /// While its Poké Ball is in the air there's nothing to draw here yet.
    var arriving = false
    /// Set by its first update, so a pet that starts out resting is simply out of sight.
    var settled = false

    /// Resting out of sight, once it has gone into its ball.
    var isGone: Bool { mood == .stored && transition == nil }

    init(agent: Agent, pokemon: String, sheet: SpriteSheet) {
        self.agent = agent
        self.pokemon = pokemon
        self.sheet = sheet
        if let saved = LastActive.get(agent.pane) {
            lastBusy = saved
        } else {
            lastBusy = Date()
            if Self.recordsActivity { LastActive.set(agent.pane, lastBusy) }
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(for: sheet)))
    }

    /// Records activity, saving it at most once a minute.
    func markActive(_ now: Date = Date()) {
        if now.timeIntervalSince(lastBusy) > 60 { LastActive.set(agent.pane, now) }
        lastBusy = now
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var name: String { pokemon.capitalized }
    var spriteSize: CGFloat { CGFloat(sheet.frames[0].width) * Self.scale }

    func setPokemon(_ name: String, sheet: SpriteSheet) {
        pokemon = name
        self.sheet = sheet
        fitSize()
    }

    /// Matches the view's height to its sprite at the current size.
    func fitSize() {
        setFrameSize(NSSize(width: Self.width, height: Self.height(for: sheet)))
        updateTrackingAreas()
        needsDisplay = true
    }

    func update(_ latest: Agent) {
        let now = Date()
        if previousStatus == "working" && latest.status != "working" {
            finishedAt = now
        } else if latest.status == "done" && finishedAt == nil {
            finishedAt = now
        }
        previousStatus = latest.status
        agent = latest
        contextUsed = latest.contextUsed

        let next: Mood
        switch latest.status {
        case "blocked": next = .alert
        case "working": next = .working
        default:
            // herdr's done lasts until the agent is viewed; a plain stop counts briefly.
            let quiet = now.timeIntervalSince(lastBusy)
            if let at = finishedAt,
               now.timeIntervalSince(at) < (latest.status == "done" ? 900 : 15) {
                next = .done
            } else if quiet > 12 * 3600 {
                next = .stored
            } else if quiet > 600 {
                next = .sleeping
            } else {
                next = .idle
            }
        }
        if next == .working || next == .alert { markActive(now) }
        setMood(next)
    }

    /// Changes mood. Going into its ball it glows red and shrinks away; coming
    /// back out, its ball is thrown in and it pops out where it lands.
    func setMood(_ next: Mood) {
        guard settled else {
            settled = true
            mood = next
            return
        }
        let wasGone = isGone
        if next == .stored && mood != .stored {
            transition = Transition(kind: .recall, start: tick)
        } else if mood == .stored && next != .stored {
            // Called back mid-recall, it just comes straight back out.
            transition = wasGone ? nil : Transition(kind: .release, start: tick)
            arriving = wasGone
        }
        if next != mood && next == .alert { // done has its own caption
            labelUntil = Date().addingTimeInterval(5)
        }
        mood = next
        if wasGone && next != .stored { onSummon?(self) }
    }

    /// Its ball has landed: out it comes.
    func land() {
        arriving = false
        transition = Transition(kind: .release, start: tick)
        hopUntil = Date().addingTimeInterval(1.6) // a happy hop once it's out
        updateTrackingAreas()
        needsDisplay = true
    }

    /// How far the pet reaches above the ground in points, from its topmost pixel.
    var visibleHeight: CGFloat { CGFloat(sheet.frames[0].height - sheet.top) * Self.scale }

    /// How much room the pet needs across, for lining up in a row: its sprite at
    /// its widest plus its pacing room.
    var footprintWidth: CGFloat { CGFloat(2 * sheet.halfWidth) * Self.scale + 2 * pace }

    /// Recalls the pet into its Poké Ball until you let it out or its agent gets busy.
    @objc func returnToBall() {
        lastBusy = .distantPast
        LastActive.set(agent.pane, .distantPast)
        finishedAt = nil
        setMood(.stored)
    }

    /// Brings the pet out of its ball, or wakes it from a nap.
    @objc func wake() {
        let now = Date()
        lastBusy = now
        LastActive.set(agent.pane, now)
        if mood == .stored || mood == .sleeping {
            setMood(.idle)
            if !arriving { hopUntil = now.addingTimeInterval(1.4) } // a happy hop once it's out
        }
    }

    var summary: String {
        switch mood {
        case .alert: return "\(name): \(agent.project) needs you"
        case .done: return "\(name): \(agent.project) is done"
        case .working: return "\(name): \(agent.project) is working"
        case .sleeping: return "\(name) is asleep"
        case .stored: return "\(name) is resting"
        case .idle: return "\(name): \(agent.project)"
        }
    }

    /// Advances one animation step: walks while working, and walks home after.
    func animate() {
        tick += 1
        if let transition, tick - transition.start >= transition.ticks {
            self.transition = nil
            if transition.kind == .recall {
                hovering = false
                onVanish?()
            }
        }
        let speed: CGFloat = 2
        if mood == .working {
            walkX += walkDirection * speed
            if abs(walkX) >= pace { walkDirection = walkX > 0 ? -1 : 1 }
        } else if walkX != 0 {
            walkDirection = walkX > 0 ? -1 : 1
            walkX = abs(walkX) <= speed ? 0 : walkX + walkDirection * speed
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let transition {
            let progress = CGFloat(tick - transition.start) / CGFloat(transition.ticks)
            if progress < 1 {
                drawTransition(transition.kind, progress: max(progress, 0), ball: pokeball)
                return
            }
        }
        if arriving || mood == .stored { return }
        let frames = sheet.frames
        let step = tick / 2 % 2
        var image = frames[tick / 6 % 2]
        var mirrored = false
        var lift: CGFloat = 0
        var flash = false
        let walking = walkX != 0 || mood == .working

        if walking {
            let right = walkDirection > 0
            if right && frames.count >= 8 {
                image = frames[6 + step]
            } else {
                image = frames[4 + step]
                mirrored = right
            }
        }

        switch mood {
        case .alert:
            if !walking { image = frames[step] }
            lift = tick / 3 % 2 == 0 ? 0 : 8
            flash = tick / 2 % 2 == 0 // hard on/off, like taking a hit: 250ms each
        case .done:
            if !walking { image = frames[step] }
            lift = [0, 6, 14, 18, 14, 6, 0, 0, 0, 0][tick % 10]
        case .working:
            break
        case .sleeping, .stored:
            if !walking { image = frames[0] }
        case .idle:
            if !walking && (hovering || Date() < hopUntil) {
                image = frames[step]
                lift = [0, 4, 6, 4][tick % 4]
            }
        }

        let rect = NSRect(x: homeX + walkX, y: Self.spriteTop - lift,
                          width: spriteSize, height: spriteSize)
        // Only a pet off the ground casts a shadow.
        if lift > 0 { drawShadow(frame: rect, pixels: sheet.frames[0].width, width: 14, lift: lift) }
        if flash {
            drawTinted(image, in: rect, color: hitRed, amount: 0.85, mirrored: mirrored)
        } else {
            drawSprite(image, in: rect, mirrored: mirrored)
        }

        switch mood {
        case .working: drawWorkingDots(under: rect)
        case .sleeping, .stored: drawSnores(over: rect)
        default: break
        }
        drawContextBarIfShown(headTop: Self.spriteTop + CGFloat(sheet.top) * Self.scale)
        // One caption under the pet: its status while hovered (or just after it
        // needs you), otherwise "is done" when it has finished.
        if hovering || Date() < labelUntil {
            drawCaption(summary)
        } else if mood == .done {
            drawCaption("\(name) is done")
        }
    }

    /// Where the ground is: the bottom of the resting sprite frame.
    var ground: CGFloat { Self.spriteTop + spriteSize }

    /// One to three dots, centred just under the pet, while it works.
    func drawWorkingDots(under rect: NSRect) {
        let count = tick / 3 % 3 + 1
        let dot: CGFloat = 4, spacing: CGFloat = 4
        let left = (rect.midX - (3 * dot + 2 * spacing) / 2).rounded()
        iconColors["B"]?.setFill()
        for i in 0..<count {
            NSRect(x: left + CGFloat(i) * (dot + spacing), y: ground + 4, width: dot, height: dot).fill()
        }
    }

    /// The part of this view that's on screen (all of it when rendering offscreen).
    var onScreenRect: NSRect {
        guard let window, let screen = window.screen ?? NSScreen.main else { return bounds }
        let shown = window.frame.intersection(screen.visibleFrame)
        guard !shown.isEmpty else { return bounds }
        let inWindow = NSRect(origin: NSPoint(x: shown.minX - window.frame.minX, y: shown.minY - window.frame.minY),
                              size: shown.size)
        return convert(inWindow, from: nil)
    }

    /// A caption centred under the pet, such as "Pikachu is done" or its status,
    /// slid inward only as far as it takes to stay on screen.
    func drawCaption(_ text: String) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.captionFont, .foregroundColor: NSColor.white]
        let room = onScreenRect.intersection(bounds).insetBy(dx: 4, dy: 0)
        var shown = text
        var keep = text.count
        while (shown as NSString).size(withAttributes: attrs).width + 12 > room.width && keep > 1 {
            keep -= 1
            shown = String(text.prefix(keep)) + "…"
        }
        let size = (shown as NSString).size(withAttributes: attrs)
        let width = size.width + 12
        let x = min(max(homeX + spriteSize / 2 - width / 2, room.minX), room.maxX - width)
        let pill = NSRect(x: x.rounded(), y: ground + 2, width: width, height: size.height + 4)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (shown as NSString).draw(at: NSPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attrs)
    }

    /// Three pixel z's drifting up and to the right off the top of the pet's
    /// head, each growing and fading in turn.
    func drawSnores(over rect: NSRect) {
        let glyph = ["SSSS", "..S.", ".S..", "SSSS"]
        let headTop = rect.minY + CGFloat(sheet.top) * Self.scale
        let startX = rect.midX + spriteSize * 0.15
        let period = 24 // 3 seconds per z
        // Anything rising past this line, a little above the head, is hidden.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSRect(x: 0, y: headTop - 32, width: bounds.width, height: bounds.height).clip()
        for k in 0..<3 {
            let t = CGFloat((tick + k * period / 3) % period) / CGFloat(period)
            // Far enough apart that neighbouring z's never touch.
            let pixel = (2 + t).rounded() // grows from 2pt to 3pt pixels
            let x = (startX + t * 33).rounded()
            let y = (headTop - 4 * pixel - 2 - t * 42).rounded()
            let alpha = t < 0.7 ? 1 : (1 - t) / 0.3
            iconColors["S"]?.withAlphaComponent(alpha).setFill()
            for (row, line) in glyph.enumerated() {
                for (col, key) in line.enumerated() where key == "S" {
                    NSRect(x: x + CGFloat(col) * pixel, y: y + CGFloat(row) * pixel,
                           width: pixel, height: pixel).fill()
                }
            }
        }
    }

    /// Where the Poké Ball sits: on the ground, centred where the pet stood.
    func ballRect(_ ball: CGImage?) -> NSRect {
        let size = CGFloat(ball?.width ?? 16) * Self.scale
        return NSRect(x: homeX + (spriteSize - size) / 2, y: Self.spriteTop + spriteSize - size,
                      width: size, height: size)
    }

    /// The CTX bar above the pet's head, while you hover over it or once its
    /// context is at least 80% used.
    func drawContextBarIfShown(headTop: CGFloat) {
        guard let used = contextUsed, hovering || used >= 0.8 else { return }
        drawContextBar(used: used, headTop: headTop)
    }

    /// A Gen 3 HP bar labelled CTX: it drains as the chat fills its context
    /// window, from green to yellow below half to red below a fifth.
    func drawContextBar(used: Double, headTop: CGFloat) {
        let px = max(1, (Self.scale * 4 / 3).rounded() / 2), width = 42, height = 7, track = 24 // 2 at medium
        let left = (homeX + spriteSize / 2 - CGFloat(width) * px / 2).rounded()
        let top = (headTop - 3 - CGFloat(height) * px).rounded()
        func fill(_ color: NSColor, _ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1) {
            color.setFill()
            NSRect(x: left + CGFloat(x) * px, y: top + CGFloat(y) * px, width: CGFloat(w) * px, height: CGFloat(h) * px).fill()
        }

        // A dark capsule with rounded ends around a grey body.
        fill(ContextBar.outline, 1, 0, width - 2)
        fill(ContextBar.outline, 1, height - 1, width - 2)
        fill(ContextBar.outline, 0, 1, 1, height - 2)
        fill(ContextBar.outline, width - 1, 1, 1, height - 2)
        fill(ContextBar.body, 1, 1, width - 2, height - 2)
        // "CTX" where the HP label would be.
        for (i, glyph) in ContextBar.glyphs.enumerated() {
            for (row, line) in glyph.enumerated() {
                for (col, key) in line.enumerated() where key == "#" { fill(ContextBar.label, 2 + i * 4 + col, 1 + row) }
            }
        }
        // The white-edged track, filled with what's left.
        fill(ContextBar.border, 14, 1, track + 2, 5)
        fill(ContextBar.empty, 15, 2, track, 3)
        let remaining = max(0, min(1, 1 - used))
        let filled = remaining > 0 ? max(1, Int((Double(track) * remaining).rounded())) : 0
        let (light, shade) = remaining > 0.5 ? ContextBar.green : remaining > 0.2 ? ContextBar.yellow : ContextBar.red
        if filled > 0 {
            fill(light, 15, 2, filled, 2)
            fill(shade, 15, 4, filled)
        }
    }

    /// Recall turns the pet red and shrinks it away to nothing where its ball
    /// would sit, as red sparkles close in; release pops it out of the ball in
    /// a white flash and sparkles. `progress` runs 0 → 1.
    func drawTransition(_ kind: Transition.Kind, progress p: CGFloat, ball: CGImage?) {
        let front = sheet.frames[0]
        let full = NSRect(x: homeX, y: Self.spriteTop, width: spriteSize, height: spriteSize)
        let ballFrame = ballRect(ball)

        switch kind {
        case .recall:
            let red = NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1)
            // A moment glowing red, then it shrinks, fading over the second half.
            let shrink = max(0, (p - 0.25) / 0.75)
            let size = (spriteSize * (1 - shrink) / Self.scale).rounded() * Self.scale
            let center = NSPoint(x: full.midX, y: full.midY + (ballFrame.midY - full.midY) * shrink)
            let rect = NSRect(x: (center.x - size / 2).rounded(), y: (center.y - size / 2).rounded(),
                              width: size, height: size)
            if size > 0 {
                drawTinted(front, in: rect, color: red, amount: min(1, 0.3 + p * 3), alpha: min(1, 2 - 2 * shrink))
            }
            if shrink > 0 {
                drawSparkles(around: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16),
                             progress: 1 - shrink, color: red, alpha: 1 - shrink * 0.7)
            }
        case .release:
            let size = spriteSize * (0.3 + 0.7 * p)
            let rect = NSRect(x: full.midX - size / 2, y: full.maxY - size, width: size, height: size)
            drawTinted(front, in: rect, color: .white, amount: 1 - p)
            if p < 0.5 {
                if let ball { drawSprite(ball, in: ballFrame, mirrored: false) }
                drawSparkles(around: ballFrame, progress: p * 2)
            }
        }
    }

    /// The sprite washed with a colour, keeping its silhouette.
    func drawTinted(_ image: CGImage, in rect: NSRect, color: NSColor, amount: CGFloat, mirrored: Bool = false,
                    alpha: CGFloat = 1) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawSprite(image, in: rect, mirrored: mirrored)
        if amount > 0 {
            context.setBlendMode(.sourceAtop)
            context.setFillColor(color.withAlphaComponent(amount).cgColor)
            context.fill(rect)
        }
        context.endTransparencyLayer()
    }

    /// Eight pixel sparkles, `progress` of the way out from `rect`.
    func drawSparkles(around rect: NSRect, progress p: CGFloat, color: NSColor? = nil, alpha: CGFloat? = nil) {
        let s = Self.scale
        let distance = rect.width / 2 + p * 30
        (color ?? NSColor(srgbRed: 0.97, green: 0.82, blue: 0.25, alpha: 1))
            .withAlphaComponent(alpha ?? 1 - p * 0.6).setFill()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let x = ((rect.midX + cos(angle) * distance) / s).rounded() * s
            let y = ((rect.midY + sin(angle) * distance) / s).rounded() * s
            // A small pixel "+".
            NSRect(x: x - s, y: y, width: 3 * s, height: s).fill()
            NSRect(x: x, y: y - s, width: s, height: 3 * s).fill()
        }
    }

    func drawSprite(_ image: CGImage, in rect: NSRect, mirrored: Bool) {
        drawPixelSprite(image, in: rect, mirrored: mirrored)
    }

    /// A pixel-art shadow on the ground, on the sprite's own pixel grid: a 3-row
    /// oval `width` pixels across under a frame `pixels` wide, shrinking as the pet lifts off.
    func drawShadow(frame: NSRect, pixels: Int, width: Int, lift: CGFloat) {
        let s = Self.scale
        var w = Int((CGFloat(width) * (1 - lift / 50)).rounded())
        w -= w % 2 // stay centred on the frame
        guard w >= 6 else { return }
        let ground = Self.spriteTop + spriteSize // bottom of the resting frame
        NSColor(white: 0, alpha: 0.18).setFill()
        for (row, inset) in [2, 0, 2].enumerated() {
            let rowPixels = w - inset * 2
            NSRect(x: frame.minX + CGFloat((pixels - rowPixels) / 2) * s,
                   y: ground - CGFloat(3 - row) * s,
                   width: CGFloat(rowPixels) * s, height: s).fill()
        }
    }

    // MARK: Mouse

    var dragStart: NSPoint?
    var windowStart: NSPoint?
    var dragged = false

    /// Just the part of the window the pet covers: its sprite's real width
    /// from its top pixel down to its feet. Neighbours packed close together
    /// never share any of it.
    var hoverRect: NSRect {
        let half = CGFloat(sheet.halfWidth) * Self.scale
        let top = ground - visibleHeight
        return NSRect(x: homeX + spriteSize / 2 - half, y: top, width: 2 * half, height: visibleHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: hoverRect, options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self))
        // The area may have shrunk out from under the mouse, which sends no exit.
        if let window {
            hovering = hoverRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart, let window else { return }
        let now = NSEvent.mouseLocation
        let offset = NSPoint(x: now.x - dragStart.x, y: now.y - dragStart.y)
        if hypot(offset.x, offset.y) > 3 { dragged = true }
        if dragged {
            window.setFrameOrigin(NSPoint(x: windowStart.x + offset.x, y: windowStart.y + offset.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if dragged { onMoved?(self) } else { clicked() }
        dragStart = nil
    }

    /// Lets the pet out (or wakes it), then jumps to its agent.
    func clicked() {
        finishedAt = nil
        hopUntil = Date().addingTimeInterval(0.6)
        wake()
        focus(agent)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "\(name) · \(agent.status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let detail = NSMenuItem(title: agent.label, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        menu.addItem(.separator())

        let go = NSMenuItem(title: "Go to Agent", action: #selector(goToAgent), keyEquivalent: "")
        go.target = self
        menu.addItem(go)

        let ball = NSMenuItem(title: "Return to Poké Ball", action: #selector(returnToBall), keyEquivalent: "")
        ball.target = self
        // A busy agent would pop it straight back out.
        ball.isEnabled = mood != .working && mood != .alert
        menu.addItem(ball)
        // Let Out ▸ each pet resting out of sight.
        let resting = restingPets?() ?? []
        if !resting.isEmpty {
            let out = NSMenuItem(title: "Let Out", action: nil, keyEquivalent: "")
            let list = NSMenu()
            for pet in resting {
                let item = NSMenuItem(title: "\(pet.name) · \(pet.agent.label)", action: #selector(wake), keyEquivalent: "")
                item.target = pet
                list.addItem(item)
            }
            out.submenu = list
            menu.addItem(out)
        }

        let choose = NSMenuItem(title: "Pokémon", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        let grid = NSMenuItem()
        grid.view = PokemonGrid(current: pokemon, taken: otherPokemon?() ?? []) { [weak self] name in
            guard let self else { return }
            self.onChoosePokemon?(self, name)
        }
        choices.addItem(grid)
        choose.submenu = choices
        menu.addItem(choose)

        menu.addItem(.separator())
        // Line Up Pets ▸ Vertical / Horizontal, then the four corners. Picking
        // any of them lines the pets up again, undoing drags.
        let lineUp = NSMenuItem(title: "Line Up Pets", action: nil, keyEquivalent: "")
        let arrange = NSMenu()
        arrange.autoenablesItems = false
        let current = Arrangement.saved
        for (title, vertical) in [("Vertical", true), ("Horizontal", false)] {
            let item = NSMenuItem(title: title, action: #selector(setDirection(_:)), keyEquivalent: "")
            item.target = self
            item.tag = vertical ? 1 : 0
            item.state = current.vertical == vertical ? .on : .off
            arrange.addItem(item)
        }
        arrange.addItem(.separator())
        for corner in Arrangement.Corner.allCases {
            let item = NSMenuItem(title: corner.title, action: #selector(setCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            item.state = current.corner == corner ? .on : .off
            arrange.addItem(item)
        }
        lineUp.submenu = arrange
        menu.addItem(lineUp)
        let size = NSMenuItem()
        size.view = SizeSlider(value: PetSize.saved) { [weak self] value in self?.onSize?(value) }
        menu.addItem(size)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Pet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc func goToAgent() { clicked() }
    @objc func setDirection(_ sender: NSMenuItem) {
        Arrangement.saved.vertical = sender.tag == 1
        onLineUp?()
    }

    @objc func setCorner(_ sender: NSMenuItem) {
        guard let corner = (sender.representedObject as? String).flatMap(Arrangement.Corner.init) else { return }
        Arrangement.saved.corner = corner
        onLineUp?()
    }
}

// MARK: - Size slider

/// The Size row in the right-click menu: a slider from Small to Large that
/// holds briefly at Small, Medium and Large (with a tick on a Force Touch
/// trackpad), resizing the pets as it moves.
final class SizeSlider: NSView {
    let slider: NSSlider
    let onChange: (CGFloat) -> Void
    var held: CGFloat?

    init(value: CGFloat, onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: Double(value), minValue: Double(PetSize.small), maxValue: Double(PetSize.large),
                          target: nil, action: nil)
        held = PetSize.locks.contains(value) ? value : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 62))

        let title = NSTextField(labelWithString: "Size")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 21, y: 4, width: 200, height: 18)
        addSubview(title)

        slider.numberOfTickMarks = PetSize.locks.count
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.frame = NSRect(x: 20, y: 22, width: 200, height: 24)
        addSubview(slider)

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for (text, alignment) in [("Small", NSTextAlignment.left), ("Medium", .center), ("Large", .right)] {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = .secondaryLabelColor
            label.alignment = alignment
            label.frame = NSRect(x: 20, y: 44, width: 200, height: 14)
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc func moved() {
        let raw = CGFloat(slider.doubleValue)
        let value = PetSize.settle(raw)
        if value != raw { slider.doubleValue = Double(value) }
        let lock = PetSize.locks.contains(value) ? value : nil
        if let lock, lock != held { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        held = lock
        onChange(value)
    }
}

// MARK: - Pokémon picker

/// Every Pokémon as its sprite in a grid, shown in the right-click menu. The
/// current one is highlighted, ones other agents have are faded (picking one
/// swaps), and the hovered one walks in place.
final class PokemonGrid: NSView {
    static let columns = 8
    static let cell = NSSize(width: 68, height: 84)
    static let padding: CGFloat = 8

    let names = roster.filter { SpriteSheet.named($0) != nil }
    let current: String
    let taken: Set<String>
    let onPick: (String) -> Void
    var hovered: Int?
    var step = 0
    var timer: Timer?

    init(current: String, taken: Set<String>, onPick: @escaping (String) -> Void) {
        self.current = current
        self.taken = taken
        self.onPick = onPick
        let rows = (names.count + Self.columns - 1) / Self.columns
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: CGFloat(Self.columns) * Self.cell.width + 2 * Self.padding,
                                 height: CGFloat(rows) * Self.cell.height + 2 * Self.padding))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func cellRect(_ i: Int) -> NSRect {
        NSRect(x: Self.padding + CGFloat(i % Self.columns) * Self.cell.width,
               y: Self.padding + CGFloat(i / Self.columns) * Self.cell.height,
               width: Self.cell.width, height: Self.cell.height)
    }

    func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return names.indices.first { cellRect($0).contains(point) }
    }

    /// Steps the hovered sprite, in the menu's run loop mode so it moves while the menu is open.
    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hovered != nil else { return }
                self.step += 1
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: event)) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    func setHovered(_ i: Int?) {
        guard i != hovered else { return }
        hovered = i
        step = 0
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        onPick(names[i])
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        for (i, name) in names.enumerated() {
            guard let sheet = SpriteSheet.named(name) else { continue }
            let cell = cellRect(i).insetBy(dx: 2, dy: 2)
            if name == current {
                NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()
            } else if i == hovered {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()
            }

            let frame = i == hovered ? sheet.frames[step % 2] : sheet.frames[0]
            let size = CGFloat(frame.width) * 2
            let sprite = NSRect(x: cell.midX - size / 2, y: cell.minY + 2, width: size, height: size)
            let inUse = taken.contains(name)
            drawPixelSprite(frame, in: sprite, alpha: inUse ? 0.4 : 1)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: inUse ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]
            let label = name.capitalized as NSString
            let width = label.size(withAttributes: attrs).width
            label.draw(at: NSPoint(x: cell.midX - width / 2, y: sprite.maxY), withAttributes: attrs)
        }
    }
}

// MARK: - Lining up

/// Bottom corners start just above Claude Code's prompt box at the bottom of the terminal.
let stackBase: CGFloat = 92
/// Top corners keep heads this far below the menu bar.
let stackTop: CGFloat = 24
/// Clear space between the bottom of a pet's caption room and the topmost pixel of the pet below it.
let stackGap: CGFloat = 8
/// Room between the sprites and the screen's side edge.
let stackMargin: CGFloat = 16

/// How the pets line up: a column or a row, tucked into one corner of the screen.
struct Arrangement {
    enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var title: String {
            ["topLeft": "Top Left", "topRight": "Top Right", "bottomLeft": "Bottom Left", "bottomRight": "Bottom Right"][rawValue]!
        }
    }

    var vertical = true
    var corner = Corner.bottomRight
    var onLeft: Bool { corner == .topLeft || corner == .bottomLeft }
    var atTop: Bool { corner == .topLeft || corner == .topRight }

    /// The choice from the right-click menu, kept across restarts.
    static var saved: Arrangement {
        get {
            let defaults = UserDefaults.standard
            return Arrangement(vertical: defaults.string(forKey: "lineUp.direction") != "horizontal",
                               corner: Corner(rawValue: defaults.string(forKey: "lineUp.corner") ?? "") ?? .bottomRight)
        }
        set {
            UserDefaults.standard.set(newValue.vertical ? "vertical" : "horizontal", forKey: "lineUp.direction")
            UserDefaults.standard.set(newValue.corner.rawValue, forKey: "lineUp.corner")
        }
    }
}

/// Where each pet's window goes, lined up in `arrangement` within `visible` in
/// `pets` order: top to bottom in a column, left to right in a row.
///
/// In a column each pet's ground sits its caption room plus the gap above the
/// head of the one below, and the gap shrinks if they won't fit. In a row they
/// share one ground line.
func stackOrigins(_ pets: [PetView], in visible: NSRect, arrangement: Arrangement) -> [NSPoint] {
    guard !pets.isEmpty else { return [] }
    let onLeft = arrangement.onLeft
    let heights = pets.map(\.visibleHeight)
    // The window's x that puts the pet's sprite with its left edge at `left`.
    func panelX(_ pet: PetView, spriteLeft left: CGFloat) -> CGFloat { left - pet.homeX }

    guard arrangement.vertical else {
        // Centre to centre, neighbours sit the gap apart at their widest (a Poké
        // Ball takes far less room than a Pokémon). Squeezed evenly if the row
        // won't fit.
        let widths = pets.map(\.footprintWidth)
        var steps = (0..<pets.count - 1).map { widths[$0] / 2 + stackGap + widths[$0 + 1] / 2 }
        let available = visible.width - 2 * stackMargin - pets[0].spriteSize
        let total = steps.reduce(0, +)
        if total > available { steps = steps.map { $0 * available / total } }

        // The row starts in the chosen corner: the first pet on the left, or the last on the right.
        var centers = [onLeft ? visible.minX + stackMargin + pets[0].spriteSize / 2
                              : visible.maxX - stackMargin - pets[0].spriteSize / 2 - steps.reduce(0, +)]
        for step in steps { centers.append(centers.last! + step) }

        let ground = arrangement.atTop ? visible.maxY - stackTop - heights.max()! : visible.minY + stackBase + 4
        return zip(pets, centers).map { pet, center in
            NSPoint(x: panelX(pet, spriteLeft: center - pet.spriteSize / 2), y: ground - PetView.bottomPad)
        }
    }

    let room = visible.height - stackBase - stackTop - heights.reduce(0, +) - CGFloat(pets.count) * PetView.captionDepth
    let gap = pets.count > 1 ? max(0, min(stackGap, room / CGFloat(pets.count - 1))) : 0
    let x = { (pet: PetView) in
        panelX(pet, spriteLeft: onLeft ? visible.minX + stackMargin : visible.maxX - stackMargin - pet.spriteSize)
    }

    var origins: [NSPoint] = []
    if arrangement.atTop {
        // Top down from just under the menu bar.
        var ground = visible.maxY - stackTop - heights[0]
        for (i, pet) in pets.enumerated() {
            origins.append(NSPoint(x: x(pet), y: ground - PetView.bottomPad))
            if i + 1 < pets.count { ground -= PetView.captionDepth + gap + heights[i + 1] }
        }
    } else {
        // Bottom up from just above the prompt box.
        var ground = visible.minY + stackBase + 4
        for pet in pets.reversed() {
            origins.append(NSPoint(x: x(pet), y: ground - PetView.bottomPad))
            ground += pet.visibleHeight + gap + PetView.captionDepth // the next pet's caption room
        }
        origins.reverse()
    }
    return origins
}

// MARK: - App

/// A Poké Ball's flight from just off the side of the screen onto the spot
/// where a pet comes out: from the right edge for a pet on the right half of
/// the screen, the left otherwise. One high arc, spinning, then a small bounce.
struct BallThrow {
    let start: NSPoint, end: NSPoint // the ball's bottom-left corner, on screen
    let arc: CGFloat
    let duration: CFTimeInterval
    let fromRight: Bool
    /// The arc's share of the flight; the bounce takes the rest.
    static let arcShare: CGFloat = 0.82

    init(onto landing: NSRect, screen: NSRect, visible: NSRect) {
        fromRight = landing.midX > screen.midX
        let top = visible.maxY - landing.height // under the menu bar
        start = NSPoint(x: fromRight ? screen.maxX + 2 : screen.minX - landing.width - 2,
                        y: min(landing.minY + 40, top))
        end = landing.origin
        let distance = abs(end.x - start.x)
        arc = max(0, min(max(90, distance * 0.3), 200, top - max(start.y, end.y)))
        duration = min(1.1, 0.65 + distance / 2000)
    }

    /// Where the ball is `t` (0 to 1) through its flight, and how many quarter
    /// turns it has spun clockwise (rolling the way it's going), upright again
    /// once it lands.
    func position(at t: CGFloat) -> (origin: NSPoint, quarterTurns: Int) {
        if t < Self.arcShare {
            let u = t / Self.arcShare
            let point = NSPoint(x: start.x + (end.x - start.x) * u,
                                y: start.y + (end.y - start.y) * u + arc * 4 * u * (1 - u))
            let turns = Int(Double(t) * duration / 0.07)
            return (NSPoint(x: point.x.rounded(), y: point.y.rounded()), fromRight ? -turns : turns)
        }
        let u = (t - Self.arcShare) / (1 - Self.arcShare)
        return (NSPoint(x: end.x, y: (end.y + 12 * 4 * u * (1 - u)).rounded()), 0)
    }
}

/// Draws the Poké Ball turned by quarter turns clockwise in a flipped view,
/// keeping its pixels square.
func drawBall(_ ball: CGImage, in rect: NSRect, quarterTurns: Int) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    context.rotate(by: CGFloat(quarterTurns) * .pi / 2)
    context.translateBy(x: -rect.midX, y: -rect.midY)
    drawPixelSprite(ball, in: rect)
    context.restoreGState()
}

/// The thrown ball, in a window spanning its whole flight.
final class BallThrowView: NSView {
    let ball: CGImage
    var ballRect = NSRect.zero
    var quarterTurns = 0

    init(ball: CGImage, frame: NSRect) {
        self.ball = ball
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawBall(ball, in: ballRect, quarterTurns: quarterTurns)
    }
}

/// Borderless panels can't normally take clicks without stealing focus; these never become key.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Lets a window hang past the screen edges and behind the menu bar. Pets
    /// sit in the middle of mostly empty windows (room for jumps and captions),
    /// and macOS would otherwise push a window at the edge onto its neighbour.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var pets: [String: PetView] = [:]      // by herdr pane
    var panels: [String: PetPanel] = [:]
    /// Panes in herdr's agent order, which matches its sidebar top to bottom.
    var order: [String] = []
    /// Panels already on screen, which slide to new spots instead of jumping.
    var placed: Set<ObjectIdentifier> = []
    var polling = false
    let defaults = UserDefaults.standard

    /// Which Pokémon each herdr pane gets, kept across restarts.
    var assignments: [String: String] {
        get { defaults.dictionary(forKey: "assignments") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "assignments") }
    }
    /// Where each Pokémon was dragged to; pets without one line up in the corner.
    var positions: [String: String] {
        get { defaults.dictionary(forKey: "positions") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "positions") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // In .common mode so pets keep moving while a right-click menu is open.
        let animation = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pets.values.forEach { $0.animate() } }
        }
        let polling = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(animation, forMode: .common)
        RunLoop.main.add(polling, forMode: .common)
        poll()
    }

    func poll() {
        guard !polling else { return }
        polling = true
        DispatchQueue.global().async {
            let agents = currentAgents()
            DispatchQueue.main.async {
                self.polling = false
                self.sync(agents)
            }
        }
    }

    /// Adds a pet for each new agent and removes pets whose agents have gone.
    func sync(_ agents: [Agent]) {
        var changed = false
        if agents.map(\.pane) != order {
            order = agents.map(\.pane)
            changed = true
        }
        let live = Set(order)
        for pane in pets.keys where !live.contains(pane) {
            if let panel = panels[pane] {
                panel.orderOut(nil)
                placed.remove(ObjectIdentifier(panel))
            }
            panels[pane] = nil
            pets[pane] = nil
            changed = true
        }
        for agent in agents {
            if let pet = pets[agent.pane] {
                pet.update(agent)
                continue
            }
            guard let name = pokemon(for: agent.pane), let sheet = SpriteSheet.named(name) else { continue }
            let pet = PetView(agent: agent, pokemon: name, sheet: sheet)
            pet.onMoved = { [weak self] pet in
                guard let origin = pet.window?.frame.origin else { return }
                self?.positions[pet.pokemon] = NSStringFromPoint(origin)
            }
            pet.onChoosePokemon = { [weak self] pet, name in self?.choose(name, for: pet) }
            pet.onLineUp = { [weak self] in
                self?.positions = [:]
                self?.layout()
            }
            pet.onVanish = { [weak self] in self?.layout() }
            pet.onSize = { [weak self] value in self?.resize(to: value) }
            pet.onSummon = { [weak self] pet in self?.summon(pet) }
            pet.restingPets = { [weak self] in
                guard let self else { return [] }
                return self.order.compactMap { self.pets[$0] }.filter(\.isGone)
            }
            pet.otherPokemon = { [weak self, weak pet] in
                Set(self?.pets.values.filter { $0 !== pet }.map(\.pokemon) ?? [])
            }
            pet.update(agent)
            pets[agent.pane] = pet
            panels[agent.pane] = makePanel(for: pet)
            changed = true
        }
        if changed { layout() }
    }

    /// The pane's Pokémon from last time, or a random one no live pet is using.
    func pokemon(for pane: String) -> String? {
        let taken = Set(pets.values.map(\.pokemon))
        if let name = assignments[pane], !taken.contains(name), SpriteSheet.named(name) != nil {
            return name
        }
        let available = roster.filter { !taken.contains($0) && SpriteSheet.named($0) != nil }
        guard let name = available.randomElement() ?? roster.first(where: { SpriteSheet.named($0) != nil })
        else { return nil }
        assignments[pane] = name
        return name
    }

    /// Gives a pet a new Pokémon, swapping with any live pet that already has it.
    func choose(_ name: String, for pet: PetView) {
        guard let sheet = SpriteSheet.named(name), name != pet.pokemon else { return }
        let previous = pet.pokemon
        if let other = pets.values.first(where: { $0 !== pet && $0.pokemon == name }),
           let previousSheet = SpriteSheet.named(previous) {
            other.setPokemon(previous, sheet: previousSheet)
            assignments[other.agent.pane] = previous
        }
        pet.setPokemon(name, sheet: sheet)
        assignments[pet.agent.pane] = name
        layout() // the new Pokémon may be taller or shorter
    }

    func makePanel(for pet: PetView) -> PetPanel {
        let panel = PetPanel(contentRect: pet.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none // it comes and goes with its own animations
        panel.contentView = pet
        if !pet.isGone { panel.orderFrontRegardless() }
        return panel
    }

    /// Pets coming back out this round, thrown in together once all have room.
    var summoning: [PetView] = []

    /// Brings a resting pet back, along with any others coming out at the same time.
    func summon(_ pet: PetView) {
        summoning.append(pet)
        guard summoning.count == 1 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pets = summoning
            summoning = []
            layout() // makes room for them all first, so none moves once its ball is in the air
            pets.forEach(throwBall)
        }
    }

    /// Throws a pet's Poké Ball in from the side of the screen it's on; the pet
    /// comes out where it lands.
    func throwBall(for pet: PetView) {
        guard let panel = panels[pet.agent.pane], panel.contentView === pet else { return pet.land() }
        panel.orderFrontRegardless()
        let landing = panel.convertToScreen(pet.convert(pet.ballRect(pokeball), to: nil))
        guard let ball = pokeball,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: landing.midX, y: landing.midY)) })
                ?? NSScreen.main else { return pet.land() }
        let flight = BallThrow(onto: landing, screen: screen.frame, visible: screen.visibleFrame)

        // A window spanning the whole flight, from just off the edge to the landing spot.
        let span = NSRect(x: min(flight.start.x, flight.end.x), y: min(flight.start.y, flight.end.y),
                          width: abs(flight.end.x - flight.start.x) + landing.width,
                          height: abs(flight.end.y - flight.start.y) + flight.arc + 16 + landing.height)
        let window = PetPanel(contentRect: span, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none // no zoom in or fade out, which would blur the pixels
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = BallThrowView(ball: ball, frame: NSRect(origin: .zero, size: span.size))
        window.contentView = view

        func show(_ t: CGFloat) {
            let (origin, turns) = flight.position(at: t)
            // The view is flipped: measured down from the window's top.
            view.ballRect = NSRect(x: origin.x - span.minX, y: span.maxY - origin.y - landing.height,
                                   width: landing.width, height: landing.height)
            view.quarterTurns = turns
            view.needsDisplay = true
        }
        show(0)
        window.orderFrontRegardless()
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = min(1, CGFloat((CACurrentMediaTime() - began) / flight.duration))
                show(t)
                guard t >= 1 else { return }
                timer.invalidate()
                // The pet draws its ball on the same spot, then pops out of it.
                pet.land()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { window.orderOut(nil) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Resizes every pet for the Size slider, keeping each one's feet where they were.
    func resize(to value: CGFloat) {
        PetSize.saved = value
        let scale = PetSize.scale(for: value)
        guard scale != PetView.scale else { return }
        PetView.scale = scale
        for (pane, pet) in pets {
            pet.fitSize()
            guard let panel = panels[pane] else { continue }
            // Bottom-left stays put, so the ground does too; the line-up then settles.
            panel.setFrame(NSRect(origin: panel.frame.origin, size: pet.frame.size), display: true)
        }
        layout(animated: false) // follows the slider as it moves
    }

    /// Puts dragged pets where they were left, and lines the rest up in agent
    /// order as chosen under Line Up Pets (by default a column in the bottom-right corner).
    func layout(animated: Bool = true) {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let arrangement = Arrangement.saved
        let saved = positions
        var stack: [(pet: PetView, panel: PetPanel)] = []
        for pane in order {
            guard let pet = pets[pane], let panel = panels[pane] else { continue }
            if pet.isGone {
                // Out of sight, taking no room; it's put straight in place when it comes back.
                panel.orderOut(nil)
                placed.remove(ObjectIdentifier(panel))
                continue
            }
            if let point = saved[pet.pokemon].map(NSPointFromString),
               NSScreen.screens.contains(where: { $0.visibleFrame.contains(point) }) {
                move(panel, to: point, animated: animated)
            } else {
                stack.append((pet, panel))
            }
        }
        for (pet, _) in stack { pet.pace = arrangement.vertical ? PetView.columnPace : PetView.rowPace }
        // Last first, each ordered in front of the next, so in a column a pet's
        // caption covers the z's rising from the one below, and they pass behind it.
        let origins = stackOrigins(stack.map(\.pet), in: visible, arrangement: arrangement)
        for ((_, panel), origin) in zip(stack, origins).reversed() {
            move(panel, to: origin, animated: animated)
            panel.orderFrontRegardless()
        }
    }

    /// Slides a panel that's already on screen; puts a new one straight in place.
    func move(_ panel: PetPanel, to point: NSPoint, animated: Bool = true) {
        guard panel.frame.origin != point else { return }
        let frame = NSRect(origin: point, size: panel.frame.size)
        if animated && placed.contains(ObjectIdentifier(panel)) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            placed.insert(ObjectIdentifier(panel))
        }
    }
}

/// A small Claude Code terminal window for the mock screenshot, mid-task.
func drawMockTerminal(centeredIn canvas: NSSize) {
    let font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    let text = NSColor(white: 0.9, alpha: 1), dim = NSColor(white: 0.55, alpha: 1)
    let orange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    let green = NSColor(srgbRed: 0.31, green: 0.73, blue: 0.40, alpha: 1)
    let amber = NSColor(srgbRed: 0.85, green: 0.64, blue: 0.25, alpha: 1)
    let border = NSColor(white: 0.42, alpha: 1)

    typealias Line = [(String, NSColor)]
    /// A row inside a box, indented past its border.
    func row(_ inner: Line) -> Line { [("  ", text)] + inner }
    // Boxes are stroked as rounded rects (box-drawing glyphs leave gaps at
    // this line height): (first line, last line, width in columns, colour).
    let boxes: [(Int, Int, Int, NSColor)] = [(0, 6, 52, orange), (20, 22, 76, border)]
    let lines: [Line] = [
        [],
        row([("✻", orange), (" Welcome to Claude Code!", text)]),
        [],
        row([("  /help for help, /status for your setup", dim)]),
        [],
        row([("  cwd: ~/projects/side-quest", dim)]),
        [],
        [],
        [("> add a dark mode toggle to the settings page", dim)],
        [],
        [("●", text), (" I'll add a toggle to the settings page and wire it to the theme.", text)],
        [],
        [("●", green), (" Read", text), ("(src/settings/SettingsPage.tsx)", dim)],
        [("  ⎿", dim), ("  Read 142 lines", dim)],
        [],
        [("●", green), (" Update", text), ("(src/settings/SettingsPage.tsx)", dim)],
        [("  ⎿", dim), ("  Updated src/settings/SettingsPage.tsx with 18 additions", dim)],
        [],
        [("✻", orange), (" Simmering…", orange), (" (14s · ↓ 1.2k tokens · esc to interrupt)", dim)],
        [],
        [],
        row([(">", text)]),
        [],
        [("  ⏵⏵ auto mode on", amber), (" (shift+tab to cycle)", dim)],
    ]

    let column = ("M" as NSString).size(withAttributes: [.font: font]).width
    let lineHeight: CGFloat = 17, titleBar: CGFloat = 28, padding: CGFloat = 14
    let size = NSSize(width: (78 * column + 2 * padding).rounded(),
                      height: titleBar + 2 * padding + CGFloat(lines.count) * lineHeight)
    let frame = NSRect(x: ((canvas.width - size.width) / 2).rounded(),
                       y: ((canvas.height - size.height) / 2 + 30).rounded(), // a touch above centre
                       width: size.width, height: size.height)

    // The window, with a soft shadow under it.
    let window = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
    shadow.set()
    NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.97).setFill()
    window.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.12).setStroke()
    window.lineWidth = 1
    window.stroke()

    // Title bar: traffic lights and the title.
    let lights = [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                  NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                  NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
    for (i, color) in lights.enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: frame.minX + 12 + CGFloat(i) * 20, y: frame.maxY - titleBar / 2 - 6,
                                    width: 12, height: 12)).fill()
    }
    let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                     .foregroundColor: dim]
    let title = "side-quest — claude" as NSString
    let titleSize = title.size(withAttributes: titleAttrs)
    title.draw(at: NSPoint(x: frame.midX - titleSize.width / 2, y: frame.maxY - titleBar / 2 - titleSize.height / 2),
               withAttributes: titleAttrs)

    // Each segment starts at its own column, so a wide fallback glyph can't shift what follows.
    let lineBottom = { (i: Int) in frame.maxY - titleBar - padding - CGFloat(i + 1) * lineHeight }
    for (i, line) in lines.enumerated() {
        var col = 0
        for (string, color) in line {
            (string as NSString).draw(at: NSPoint(x: frame.minX + padding + CGFloat(col) * column, y: lineBottom(i)),
                                      withAttributes: [.font: font, .foregroundColor: color])
            col += string.count
        }
    }

    // Box edges run through the middle of their first and last lines.
    for (first, last, width, color) in boxes {
        let box = NSRect(x: frame.minX + padding + column / 2,
                         y: lineBottom(last) + lineHeight / 2,
                         width: CGFloat(width - 1) * column,
                         height: lineBottom(first) - lineBottom(last))
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }
}

/// The four agents in the mock screenshot, top to bottom. The picker render
/// shows the same party, as if you'd right-clicked Gengar.
let demoParty = ["charmander", "snorlax", "gengar", "ditto"]

/// The Pokémon picker on white, as if right-clicking Gengar in the mock
/// screenshot: Gengar current, the rest of the party taken, Pikachu hovered.
@MainActor
func renderPicker(to path: String) {
    let grid = PokemonGrid(current: "gengar", taken: Set(demoParty).subtracting(["gengar"])) { _ in }
    grid.hovered = grid.names.firstIndex(of: "pikachu")
    guard let rep = grid.bitmapImageRepForCachingDisplay(in: grid.bounds),
          let canvas = NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
    grid.cacheDisplay(in: grid.bounds, to: rep)
    let rect = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    rect.fill()
    rep.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// A mock screenshot: four pets in different moods stacked on a wallpaper
/// image, laid out exactly as on screen, at one pixel per point.
@MainActor
func renderDesktop(background path: String, to out: String, arrangement: Arrangement = Arrangement()) {
    guard let wallpaper = NSImage(contentsOfFile: path), let rep = wallpaper.representations.first else { return }
    let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    let poses: [(mood: Mood, tick: Int, walkX: CGFloat)] = [
        (.working, 4, 6),   // Charmander walking right over its dots
        (.done, 3, 0),      // Snorlax at the top of its jump, over "Snorlax is done"
        (.alert, 3, 0),     // Gengar mid-hop between red flashes, so it reads as Gengar
        (.sleeping, 8, 0),  // Ditto with z's drifting up
    ]
    let cast = zip(demoParty, poses).map { (pokemon: $0, mood: $1.mood, tick: $1.tick, walkX: $1.walkX) }
    let pets = cast.enumerated().compactMap { i, c -> PetView? in
        guard let sheet = SpriteSheet.named(c.pokemon) else { return nil }
        let pet = PetView(agent: Agent(pane: "demo:\(i)", status: "idle", title: "", project: "demo"),
                          pokemon: c.pokemon, sheet: sheet)
        pet.mood = c.mood
        pet.tick = c.tick
        pet.walkX = c.walkX
        return pet
    }
    let origins = stackOrigins(pets, in: NSRect(origin: .zero, size: size), arrangement: arrangement)

    guard let canvas = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    wallpaper.draw(in: NSRect(origin: .zero, size: size))
    drawMockTerminal(centeredIn: size)
    // Pets render at the screen's 2x; sampled straight down to 1x, a 3-point
    // sprite pixel is exactly 3 pixels, so they stay crisp.
    context.imageInterpolation = .none
    for (pet, origin) in zip(pets, origins).reversed() { // bottom first, so upper pets draw on top
        guard let petRep = pet.bitmapImageRepForCachingDisplay(in: pet.bounds) else { continue }
        pet.cacheDisplay(in: pet.bounds, to: petRep)
        petRep.draw(in: NSRect(origin: origin, size: pet.bounds.size), from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }
    NSGraphicsContext.restoreGraphicsState()
    try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
}

/// Renders every mood (top row), the whole roster, and a Poké Ball thrown in
/// from the right edge (bottom strip, every few frames) into a PNG.
@MainActor
func renderSheet(to path: String) {
    guard let sample = SpriteSheet.named("pikachu") else { return }
    // (mood, tick, walkX, hovering, Poké Ball animation and how far through, context used)
    let moods: [(Mood, Int, CGFloat, Bool, (Transition.Kind, Int)?, Double?)] = [
        (.idle, 0, 0, false, nil, nil), (.idle, 2, 0, true, nil, nil), (.working, 2, 12, false, nil, nil),
        (.working, 4, -12, false, nil, nil), (.alert, 4, 0, false, nil, nil), (.alert, 3, 0, false, nil, nil),
        (.done, 3, 0, false, nil, nil), (.sleeping, 0, 0, false, nil, nil),
        (.stored, 10, 0, false, (.recall, 1), nil), (.stored, 10, 0, false, (.recall, 4), nil),
        (.stored, 10, 0, false, (.recall, 6), nil), (.idle, 10, 0, false, (.release, 1), nil),
        (.idle, 10, 0, false, (.release, 3), nil),
        (.idle, 0, 0, true, nil, 0.3), (.working, 2, 12, true, nil, 0.65), (.idle, 0, 0, false, nil, 0.93),
    ]
    let cell = NSSize(width: PetView.width, height: PetView.height(for: sample))
    let rows = (roster.count + 7) / 8
    let strip = NSSize(width: 900, height: 260)
    let size = NSSize(width: cell.width * CGFloat(moods.count), height: cell.height + CGFloat(rows) * 110 + strip.height)
    guard let sheet = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: sheet) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(white: 0.9, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    for (i, (mood, tick, walkX, hover, transition, context)) in moods.enumerated() {
        let agent = Agent(pane: "w1:p1", status: "idle", title: "", project: "side-quest")
        let view = PetView(agent: agent, pokemon: "pikachu", sheet: sample)
        view.mood = mood
        view.tick = tick
        view.walkX = walkX
        view.walkDirection = walkX < 0 ? -1 : 1
        view.hovering = hover
        view.transition = transition.map { Transition(kind: $0.0, start: tick - $0.1) }
        view.contextUsed = context
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        rep.draw(in: NSRect(x: CGFloat(i) * cell.width, y: size.height - cell.height,
                            width: cell.width, height: cell.height))
    }

    context.cgContext.interpolationQuality = .none
    for (i, name) in roster.enumerated() {
        guard let frame = SpriteSheet.named(name)?.frames.first else { continue }
        let x = CGFloat(i % 8) * cell.width + (cell.width - 96) / 2
        let y = size.height - cell.height - CGFloat(i / 8 + 1) * 110
        context.cgContext.draw(frame, in: CGRect(x: x, y: y, width: 96, height: 96))
    }
    if let pokeball {
        // The strip stands in for the screen, its own right edge the screen's.
        let screen = NSRect(origin: .zero, size: strip)
        NSColor(white: 0.8, alpha: 1).setFill()
        screen.fill()
        let ball = CGFloat(pokeball.width) * PetView.scale
        let landing = NSRect(x: 640, y: 30, width: ball, height: ball)
        let flight = BallThrow(onto: landing, screen: screen, visible: screen)
        context.cgContext.translateBy(x: 0, y: strip.height) // drawBall expects a flipped view
        context.cgContext.scaleBy(x: 1, y: -1)
        for t in stride(from: CGFloat(0), through: 1, by: 0.06) {
            let (origin, turns) = flight.position(at: t)
            drawBall(pokeball, in: NSRect(x: origin.x, y: strip.height - origin.y - ball, width: ball, height: ball),
                     quarterTurns: turns)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? sheet.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// herdr's agents in its sidebar order, then Claude sessions outside herdr, oldest first.
func currentAgents() -> [Agent] {
    let herdr = Herdr.agents()
    let records = HookSessions.liveRecords()
    var agents = (herdr ?? []) + HookSessions.agents(from: records, herdrRunning: herdr != nil)
    for i in agents.indices {
        agents[i].contextUsed = Context.used(by: agents[i], records: records)
    }
    return agents
}

// MARK: - Context

/// How full each agent's context window is, from the token counts Claude Code
/// writes to the session transcript. Uses the same input-only sum as Claude
/// Code's own context percentage.
enum Context {
    /// Token counts by transcript, re-read only when the file changes.
    private static var cache: [String: (modified: Date, tokens: Int?)] = [:]

    static func used(by agent: Agent, records: [HookSessions.Record]) -> Double? {
        // A herdr pane's session is whichever reported from that pane most recently.
        let record = agent.pane.hasPrefix(HookSessions.prefix)
            ? records.first { HookSessions.prefix + $0.session == agent.pane }
            : records.filter { $0.herdrPane == agent.pane }.max { $0.updated < $1.updated }
        // A herdr pane that hasn't run a hook since the pets were installed is
        // found through its process instead.
        let path = record?.transcript ?? (agent.pane.hasPrefix(HookSessions.prefix) ? nil : paneTranscript(agent.pane))
        guard let path, let tokens = tokens(in: path) else { return nil }
        return Double(tokens) / Double(window(model: record?.model, tokens: tokens))
    }

    /// Panes' transcripts found by process, re-checked every half minute.
    private static var paneTranscripts: [String: (checked: Date, path: String?)] = [:]

    /// The transcript of the Claude Code session in a herdr pane. herdr names
    /// the pane's foreground process, and Claude Code keeps a file per process
    /// in ~/.claude/sessions naming its session, or the background job it was
    /// parked in.
    static func paneTranscript(_ pane: String) -> String? {
        if let cached = paneTranscripts[pane], Date().timeIntervalSince(cached.checked) < 30 { return cached.path }
        var path: String?
        if let data = Herdr.run(["pane", "process-info", "--pane", pane]),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let info = (json["result"] as? [String: Any])?["process_info"] as? [String: Any],
           let processes = info["foreground_processes"] as? [[String: Any]] {
            path = processes.lazy.compactMap { ($0["pid"] as? Int).flatMap(session(ofPid:)) }.compactMap(transcript(of:)).first
        }
        paneTranscripts[pane] = (Date(), path)
        return path
    }

    static let sessionsDirectory = NSHomeDirectory() + "/.claude/sessions"

    static func sessionFile(_ name: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: sessionsDirectory + "/" + name) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The session a Claude Code process is showing.
    static func session(ofPid pid: Int) -> String? {
        guard let file = sessionFile("\(pid).json") else { return nil }
        guard let job = file["parkedJobId"] as? String else { return file["sessionId"] as? String }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory)) ?? []
        return names.lazy.filter { $0.hasSuffix(".json") }.compactMap(sessionFile).first {
            $0["jobId"] as? String == job && ($0["pid"] as? Int).map { isAlive(pid_t($0)) } == true
        }?["sessionId"] as? String
    }

    static func transcript(of session: String) -> String? {
        let projects = NSHomeDirectory() + "/.claude/projects"
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        return folders.lazy.map { "\(projects)/\($0)/\(session).jsonl" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func tokens(in path: String) -> Int? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        if let cached = cache[path], cached.modified == modified { return cached.tokens }
        let tokens = latestTokens(in: path)
        cache[path] = (modified, tokens)
        return tokens
    }

    /// The input tokens of the main conversation's latest reply. nil before the
    /// first reply, and after a compaction until the next one.
    static func latestTokens(in path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() {
            if line.contains("\"subtype\":\"compact_boundary\"") { return nil }
            guard line.contains("\"type\":\"assistant\""), line.contains("\"usage\""),
                  !line.contains("\"isSidechain\":true"),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            if tokens > 0 { return tokens } // skip error placeholders with empty usage
        }
        return nil
    }

    /// 1M for extended-context sessions, otherwise 200k. Transcripts don't say
    /// which, so: past 200k it must be 1M; below that, the session's model if
    /// SessionStart reported it, else the default model in Claude Code's settings.
    static func window(model: String?, tokens: Int) -> Int {
        if tokens > 200_000 { return 1_000_000 }
        return (model ?? defaultModel() ?? "").contains("[1m]") ? 1_000_000 : 200_000
    }

    static func defaultModel() -> String? {
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json"),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return settings["model"] as? String
    }
}

@main
struct ClaudePet {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--hook") {
            HookSessions.handleHook()
            return
        }
        if args.contains("--status") {
            for agent in currentAgents() {
                let context = agent.contextUsed.map { "ctx \(Int(($0 * 100).rounded()))%" } ?? "ctx ?"
                print(agent.pane, agent.status, agent.project, context, agent.app ?? "")
            }
            return
        }
        if args.contains(where: { $0.hasPrefix("--render") }) {
            PetView.recordsActivity = false
            PetView.scale = PetSize.medium // the docs show the default size
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            renderSheet(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--render-desktop"), i + 2 < args.count {
            // Optional: "horizontal" and/or a corner such as "topLeft".
            var arrangement = Arrangement()
            arrangement.vertical = !args.contains("horizontal")
            if let corner = args.compactMap(Arrangement.Corner.init(rawValue:)).first { arrangement.corner = corner }
            renderDesktop(background: args[i + 1], to: args[i + 2], arrangement: arrangement)
            return
        }
        if let i = args.firstIndex(of: "--render-picker"), i + 1 < args.count {
            renderPicker(to: args[i + 1])
            return
        }
        // One Claude Pet at a time.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
