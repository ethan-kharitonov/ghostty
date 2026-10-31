import XCTest
import AppKit

final class TmuxControlModeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var socket: String!
    private var config: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        socket = "ghostty-test-\(UUID().uuidString)"
        config = FileManager.default.temporaryDirectory.appendingPathComponent(socket)
        try tmux(["new-session", "-d", "-s", "native", "-n", "First", "-x", "100", "-y", "30", "exec cat"])
        try tmux(["set-option", "-t", "native", "automatic-rename", "off"])
        try tmux(["split-window", "-h", "-t", "native:0", "exec cat"])
        try """
        command = /opt/homebrew/bin/tmux -L \(socket!) -CC attach-session -t native
        confirm-close-surface = false
        window-save-state = never
        auto-update = off
        keybind = ctrl+shift+u=tmux_command:rename-window Shortcut
        keybind = ctrl+shift+p=coprocess:printf 'coprocess-input\\n'
        """.write(to: config, atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchArguments = [
            "--config-default-files=false", "--config-file=\(config.path)",
        ]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if socket != nil { _ = try? tmux(["kill-server"]) }
        if let config { try? FileManager.default.removeItem(at: config) }
    }

    @MainActor
    func testCustomTmuxCommandRunsOnServer() throws {
        launchConnectedTerminal()
        app.typeKey("u", modifierFlags: [.control, .shift])
        XCTAssertTrue(app.windows["Shortcut"].waitForExistence(timeout: 5))
        XCTAssertEqual(try tmux(["display-message", "-p", "-t", "native:0", "#{window_name}"]), "Shortcut")
    }

    @MainActor
    func testCoprocessSendsLocalOutputToSelectedRemotePane() throws {
        launchConnectedTerminal()
        app.typeKey("p", modifierFlags: [.control, .shift])
        waitForServerOutput(["capture-pane", "-p", "-t", "native:0.1"], equals: "coprocess-input\ncoprocess-input")
        XCTAssertEqual(try tmux(["capture-pane", "-p", "-t", "native:0.0"]), "")
    }

    @MainActor
    func testNativeTabCreationCreatesServerWindow() throws {
        launchConnectedTerminal()
        app.typeKey("t", modifierFlags: .command)
        waitForServerOutput(["display-message", "-p", "-t", "native", "#{session_windows}"], equals: "2")
        try tmux(["rename-window", "-t", "native:1", "Second"])
        XCTAssertTrue(app.windows["Second"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testNativePaneClosureClosesServerPane() throws {
        launchConnectedTerminal()
        app.typeKey("w", modifierFlags: .command)
        waitForServerOutput(["display-message", "-p", "-t", "native:0", "#{window_panes}"], equals: "1")
        XCTAssertTrue(app.groups["Right pane"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testQuitKeepsServerProgramsAlive() throws {
        launchConnectedTerminal()
        let pids = try tmux(["list-panes", "-t", "native:0", "-F", "#{pane_pid}"])
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        XCTAssertEqual(try tmux(["list-panes", "-t", "native:0", "-F", "#{pane_pid}"]), pids)
    }

    @MainActor
    func testServerSelectionChangesTabWithoutSendingInput() throws {
        launchConnectedTerminal()
        try tmux(["new-window", "-d", "-t", "native", "-n", "Second", "printf 'waiting\\n'; exec cat"])
        waitForServerOutput(["capture-pane", "-p", "-t", "native:1"], equals: "waiting")
        try tmux(["select-window", "-t", "native:1"])
        XCTAssertTrue(app.windows["Second"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.windows.firstMatch.title, "Second")
        XCTAssertEqual(try tmux(["capture-pane", "-p", "-t", "native:1"]), "waiting")
    }

    @MainActor
    func testAttachRestoresTheActiveAlternateScreen() throws {
        try tmux(["respawn-pane", "-k", "-t", "native:0.1",
                  "printf 'PRIMARY\\033[?1049hALTERNATE'; exec cat"])
        waitForServerOutput(["capture-pane", "-p", "-t", "native:0.1"], equals: "ALTERNATE")
        launchConnectedTerminal()
        XCTAssertEqual(selectedText().trimmingCharacters(in: .whitespacesAndNewlines), "ALTERNATE")
    }

    @MainActor
    func testAttachRestoresScrollback() throws {
        let expected = (1...80).map { "history-\($0)" }
        try tmux(["respawn-pane", "-k", "-t", "native:0.1",
                  "i=1; while [ \"$i\" -le 80 ]; do printf 'history-%s\\n' \"$i\"; i=$((i+1)); done; exec cat"])
        waitForServerOutput(["capture-pane", "-p", "-S", "-", "-t", "native:0.1"],
                            equals: expected.joined(separator: "\n"))
        launchConnectedTerminal()
        let lines = selectedText().split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, expected)
    }

    @MainActor
    private func selectedText() -> String {
        NSPasteboard.general.clearContents()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey("c", modifierFlags: .command)
        return NSPasteboard.general.string(forType: .string) ?? ""
    }

    @MainActor
    private func launchConnectedTerminal() {
        app.launch()
        XCTAssertTrue(app.windows["First"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.groups["Right pane"].waitForExistence(timeout: 5))
    }

    private func waitForServerOutput(_ arguments: [String], equals expected: String) {
        let matches = NSPredicate { [weak self] _, _ in
            guard let self else { return false }
            return (try? self.tmux(arguments)) == expected
        }
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "tmux \(arguments.joined(separator: " ")) should report \(expected)")
    }

    @discardableResult
    private func tmux(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/tmux")
        process.arguments = ["-L", socket!] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let decoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        let text = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TmuxControlModeUITests", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text
    }
}
