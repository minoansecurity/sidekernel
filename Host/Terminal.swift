import Foundation
import Darwin

public enum Terminal {

    // MARK: - Size

    public static func windowSize(_ fd: Int32 = STDOUT_FILENO) -> (cols: UInt16, rows: UInt16)? {
        var size = winsize()
        if ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 {
            return (size.ws_col, size.ws_row)
        }
        return nil
    }

    // MARK: - Palette

    static let colorEnabled: Bool = {
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        return isatty(STDERR_FILENO) != 0
    }()

    static let truecolorEnabled: Bool = {
        guard colorEnabled else { return false }
        let colorterm = (ProcessInfo.processInfo.environment["COLORTERM"] ?? "").lowercased()
        if colorterm.contains("truecolor") || colorterm.contains("24bit") { return true }
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        return term.contains("256color") || term.contains("kitty") || term.contains("alacritty")
    }()

    public static var reset: String { colorEnabled ? "\u{1B}[0m" : "" }
    public static var dim: String { colorEnabled ? "\u{1B}[2m" : "" }
    public static var red: String { colorEnabled ? "\u{1B}[31m" : "" }
    static var bold: String { colorEnabled ? "\u{1B}[1m" : "" }

    public static var accent: String { rgb(0, 190, 218) }

    /// Truecolor, else the nearest 256-color cube entry.
    static func rgb(_ r: Int, _ g: Int, _ b: Int) -> String {
        if truecolorEnabled { return "\u{1B}[38;2;\(r);\(g);\(b)m" }
        guard colorEnabled else { return "" }
        let ri = Int((Double(r) / 255.0 * 5.0).rounded())
        let gi = Int((Double(g) / 255.0 * 5.0).rounded())
        let bi = Int((Double(b) / 255.0 * 5.0).rounded())
        return "\u{1B}[38;5;\(16 + 36 * ri + 6 * gi + bi)m"
    }

    // MARK: - Header

    public static func header(hostDir: String) -> String {
        let commands = [
            ("sk-drop <path>", "import a host file or folder"),
            ("sk-net on|off", "switch network access"),
            ("save", "keep installs and config"),
        ]
        let width = commands.map { $0.0.count }.max() ?? 0
        let name = "SIDEKERNEL"
        let mount = "\(shortPath(hostDir)) \u{2192} /workspace"
        // Each row as (visible text, styled text): padding is measured on the visible text.
        var rows: [(String, String)] = [
            ("", ""),
            ("\u{25C6} \(name)  \(CLI.version)",
             "\(accent)\u{25C6}\(reset) \(bold)\(name)\(reset)  \(dim)\(CLI.version)\(reset)"),
            (mount, "\(dim)\(mount)\(reset)"),
            ("", ""),
        ]
        for (command, description) in commands {
            let pad = String(repeating: " ", count: width - command.count)
            rows.append(("\(command)\(pad)  \(description)",
                         "\(accent)\(command)\(reset)\(pad)  \(dim)\(description)\(reset)"))
        }
        rows.append(("", ""))
        let tip = "  \(bold)did you know?\(reset) \(dim)\(tips.randomElement() ?? "")\(reset)"

        let inner = (rows.map { $0.0.count }.max() ?? 0) + 6
        // Too narrow for the box: plain lines still read fine.
        if let cols = windowSize(STDERR_FILENO)?.cols, Int(cols) < inner + 4 {
            return "\n" + (rows.dropFirst().map { "  \($0.1)" } + [tip]).joined(separator: "\n") + "\n\n"
        }
        let edge = accent
        let lines = rows.map { plain, styled in
            "  \(edge)\u{2502}\(reset)   \(styled)\(String(repeating: " ", count: inner - 3 - plain.count))\(edge)\u{2502}\(reset)"
        }
        let rule = String(repeating: "\u{2500}", count: inner)
        let top = "  \(edge)\u{256D}\(rule)\u{256E}\(reset)"
        let bottom = "  \(edge)\u{2570}\(rule)\u{256F}\(reset)"
        return "\n" + ([top] + lines + [bottom, "", tip]).joined(separator: "\n") + "\n\n"
    }

    /// One is shown at every launch.
    static let tips = [
        "you can drag and drop host files into Claude",
        "you can paste images into Claude with Ctrl+V",
        "pbcopy works inside SideKernel",
        "typing 'ramblinwreck' makes you a helluva engineer",
        "sclaude on the Mac starts Claude in a sandbox",
        "Claude keeps working after sk-net off",
        "Claude's credentials stay on the host, and never enter the sandbox",
        "one Claude login covers the Mac and every sandbox",
        "your host skills and plugins come along",
        "every sk boots a fresh microVM",
        "Claude remembers conversations per folder",
        "SideKernel has zero external dependencies",
    ]

    private static func shortPath(_ hostDir: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return hostDir.hasPrefix(home) ? "~" + hostDir.dropFirst(home.count) : hostDir
    }

    // MARK: - Session boundary

    /// Undo the modes a full-screen guest app may have left on, without clearing the screen.
    static let sanitize =
        "\u{1B}[?1000l\u{1B}[?1002l\u{1B}[?1003l\u{1B}[?1006l\u{1B}[?1015l"  // mouse tracking off
        + "\u{1B}[?2004l"          // bracketed paste off
        + "\u{1B}[?1l\u{1B}>"      // normal cursor keys + normal keypad
        + "\u{1B}[r"               // reset scroll region
        + "\u{1B}[?25h"            // show cursor
        + "\u{1B}[0m"              // reset attributes

    static func windowTitle(_ text: String) -> String { "\u{1B}]2;\(text)\u{07}" }

    // No-op on terminals without a title stack.
    static let pushTitle = "\u{1B}[22;2t"
    static let popTitle = "\u{1B}[23;2t"

    /// Safe inside an escape sequence or a prompt.
    public static func sanitizedProjectName(_ hostDir: String = FileManager.default.currentDirectoryPath) -> String {
        let name = URL(fileURLWithPath: hostDir).lastPathComponent
        let safe = name.filter { $0.isLetter || $0.isNumber || " ._-".contains($0) }
        return safe.isEmpty ? "project" : safe
    }

    static func statusTitle(networkOn: Bool, hostDir: String = FileManager.default.currentDirectoryPath) -> String {
        // Control characters could end the title sequence early.
        let path = String(shortPath(hostDir).unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        // Posture first: tabs truncate from the end.
        return "\(networkOn ? "\u{1F7E2} network on" : "\u{1F534} network off") \u{00B7} \(path)"
    }

    /// Set while a session holds the operator's title; guarded by outputLock.
    private nonisolated(unsafe) static var ownsTitle = false

    public static func sessionEnter(networkOn: Bool) -> String {
        outputLock.lock(); ownsTitle = true; outputLock.unlock()
        return pushTitle + windowTitle(statusTitle(networkOn: networkOn))
    }

    public static func sessionLeave() -> String {
        outputLock.lock(); ownsTitle = false; outputLock.unlock()
        return sanitize + windowTitle("") + popTitle
    }

    public static func updateStatus(networkOn: Bool) {
        outputLock.lock()
        defer { outputLock.unlock() }
        guard ownsTitle else { return }
        FDIO.writeAll(STDERR_FILENO, Array(windowTitle(statusTitle(networkOn: networkOn)).utf8))
    }

    // MARK: - Notices

    /// Held by every terminal writer so escape sequences never interleave.
    public static let outputLock = NSLock()

    /// \r\n because the TTY is in raw mode.
    public static func notice(_ line: String) {
        let bytes = Array("\r\n  \(line)\r\n".utf8)
        outputLock.lock()
        defer { outputLock.unlock() }
        FDIO.writeAll(STDERR_FILENO, bytes)
    }

    // MARK: - Setup steps

    /// One line per setup step: a spinner and a clock while it runs, ✓ or ✗ when it ends.
    /// Plain lines when stderr is not a terminal.
    public final class Steps: @unchecked Sendable {
        private static let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        private let live = isatty(STDERR_FILENO) != 0
        private let lock = NSLock()
        private var label: String?
        private var detail: (() -> String?)?
        private var started = Date()
        private var frame = 0
        private var timer: DispatchSourceTimer?

        public init() {}
        deinit { timer?.cancel() }

        /// Ends the running step, if any, with ✓.
        public func start(_ label: String, detail: (() -> String?)? = nil) {
            lock.lock(); defer { lock.unlock() }
            end(ok: true)
            self.label = label
            self.detail = detail
            started = Date()
            frame = 0
            guard live else { write("  \(label)…\n"); return }
            draw()
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(80), repeating: .milliseconds(80))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }

        public func finish(ok: Bool = true) {
            lock.lock(); defer { lock.unlock() }
            end(ok: ok)
        }

        /// Printed above the running step.
        public func note(_ text: String) {
            lock.lock(); defer { lock.unlock() }
            let lines = text.split(separator: "\n").map { "  \(Terminal.dim)\($0)\(Terminal.reset)\n" }
            write((live ? "\r\u{1B}[2K" : "") + lines.joined())
            if live { draw() }
        }

        private func tick() {
            lock.lock(); defer { lock.unlock() }
            frame += 1
            draw()
        }

        private func draw() {
            guard let label else { return }
            let extra = [detail?(), clock()].compactMap { $0 }.joined(separator: "  ")
            write(line(Terminal.accent + String(Self.frames[frame % Self.frames.count]), label, extra))
        }

        private func end(ok: Bool) {
            timer?.cancel()
            timer = nil
            guard let label else { return }
            self.label = nil
            detail = nil
            if live { write(line(ok ? Terminal.accent + "✓" : Terminal.red + "✗", label, clock()) + "\n") }
        }

        /// Cut to the terminal width, so a redraw never wraps onto a second row.
        private func line(_ mark: String, _ label: String, _ extra: String) -> String {
            let room = Int(Terminal.windowSize(STDERR_FILENO)?.cols ?? 80) - 5
            let text = label.count + 2 + extra.count <= room
                ? "\(label)  \(Terminal.dim)\(extra)\(Terminal.reset)"
                : String(label.prefix(max(room, 0)))
            return "\r\u{1B}[2K  \(mark)\(Terminal.reset) \(text)"
        }

        private func clock() -> String {
            let seconds = Int(Date().timeIntervalSince(started))
            return seconds < 60 ? "\(seconds)s" : String(format: "%ld:%02ld", seconds / 60, seconds % 60)
        }

        private func write(_ text: String) {
            FDIO.writeAll(STDERR_FILENO, Array(text.utf8))
        }
    }
}
