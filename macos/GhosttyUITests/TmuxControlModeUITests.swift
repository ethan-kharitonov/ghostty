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
        window-show-tab-bar = always
        keybind = ctrl+shift+u=tmux_command:rename-window Shortcut
        keybind = ctrl+shift+p=coprocess:printf 'coprocess-input\\n'
        """.write(to: config, atomically: true, encoding: .utf8)
        app = XCUIApplication()
        app.launchEnvironment["GHOSTTY_CONFIG_PATH"] = config.path
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if socket != nil { _ = try? tmux(["kill-server"]) }
        if let config { try? FileManager.default.removeItem(at: config) }
    }

    @MainActor
    func testFullScreenAttachUsesTheSelectedNativeTab() throws {
        let base = try String(contentsOf: config, encoding: .utf8)
        try (base + "\nfullscreen = false\ntmux-fullscreen = true\n")
            .write(to: config, atomically: true, encoding: .utf8)
        try tmux(["new-window", "-t", "native", "-n", "Second", "exec cat"])
        try tmux(["split-window", "-h", "-t", "native:1", "exec cat"])
        launchConnectedTerminal(windowTitle: "Second")
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertTrue(app.menuItems["Exit Full Screen"].waitForExistence(timeout: 5))
        app.menuItems["Exit Full Screen"].click()
        app.menuBars.menuBarItems["Window"].click()
        XCTAssertTrue(app.menuItems["Enter Full Screen"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testMovingPanesKeepsTheirTerminalViewsAndLiveOutput() throws {
        launchConnectedTerminal()
        try tmux(["new-window", "-d", "-t", "native", "-n", "Second", "exec cat"])
        try tmux(["new-window", "-d", "-t", "native", "-n", "Third", "exec cat"])
        try tmux(["split-window", "-h", "-t", "native:2", "exec cat"])
        for (name, target) in [("First", "native:0"), ("Third", "native:2")] {
            try tmux(["select-window", "-t", target])
            XCTAssertTrue(app.windows[name].waitForExistence(timeout: 5))
            let identifiers = app.windows[name].textViews.allElementsBoundByIndex.map(\.identifier)
            XCTAssertEqual(identifiers.count, 2)
            XCTAssertTrue(identifiers.allSatisfy { !$0.isEmpty })
            let panes = try tmux(["list-panes", "-t", target, "-F", "#{pane_id}"]).split(separator: "\n").map(String.init)
            for (pane, identifier) in zip(panes, identifiers) {
                try tmux(["join-pane", "-s", pane, "-t", "native:1", "-h"])
                let view = app.windows["Second"].textViews[identifier]
                XCTAssertTrue(view.waitForExistence(timeout: 5))
                let tty = try tmux(["display-message", "-p", "-t", pane, "#{pane_tty}"])
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tty))
                try handle.write(contentsOf: Data("OK\r\n".utf8))
                try handle.close()
                let output = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (view.value as? String)?.contains("OK") == true
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [output], timeout: 5), .completed)
            }
            XCTAssertTrue(app.windows[name].waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    func testImportingWindowGroupsPreservesITermMetadata() throws {
        let metadata = "a_302c7074792d6162633b57696e646f775374796c653d46756c6c53637265656e"
        try tmux(["set-option", "-t", "native", "@affinities", metadata])
        launchConnectedTerminal()
        waitForServerOutput(["show-options", "-v", "-t", "native", "@ghostty-affinities"], equals: "0")
        XCTAssertEqual(try tmux(["show-options", "-v", "-t", "native", "@affinities"]), metadata)
    }

    @MainActor
    func testMouseSelectionPreservesApplicationScrolling() throws {
        let base = try String(contentsOf: config, encoding: .utf8)
        try (base + "\nmouse-reporting-events = scroll\nfont-family = Monaco\nfont-size = 12\nwindow-padding-x = 8\nwindow-padding-y = 8\n")
            .write(to: config, atomically: true, encoding: .utf8)
        launchConnectedTerminal()
        let script = config.appendingPathExtension("py")
        defer { try? FileManager.default.removeItem(at: script) }
        try #"""
        import os, re, tty
        tty.setraw(0)
        os.write(1, b'\x1b[?1003h\x1b[?1006h\x1b[2J\x1b[HSELECTME\r\n')
        received = b''
        scrolled = False
        while chunk := os.read(0, 4096):
            received += chunk
            events = list(re.finditer(rb'\x1b\[<(\d+);\d+;\d+[Mm]', received))
            for event in events:
                if int(event[1]) & 64:
                    if not scrolled:
                        os.write(1, b'WHEEL\r\n')
                        scrolled = True
                else:
                    os.write(1, b'UNEXPECTED_INPUT\r\n')
            if events:
                received = received[events[-1].end():]
        """#.write(to: script, atomically: true, encoding: .utf8)
        try tmux(["respawn-pane", "-k", "-t", "native:0.1", "/usr/bin/python3", script.path])
        waitForServerOutput(["capture-pane", "-p", "-t", "native:0.1"], equals: "SELECTME")
        let pane = app.groups["Right pane"]
        let origin = pane.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: 9, dy: 14))
        let end = origin.withOffset(CGVector(dx: 200, dy: 14))
        start.click(forDuration: 0.1, thenDragTo: end)
        NSPasteboard.general.clearContents()
        app.typeKey("c", modifierFlags: .command)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), "SELECTME")
        pane.scroll(byDeltaX: 0, deltaY: -40)
        waitForServerOutput(["capture-pane", "-p", "-t", "native:0.1"], equals: "SELECTME\nWHEEL")
    }

    @MainActor
    func testITermStatusUpdatesTheNativeTab() throws {
        launchConnectedTerminal()
        try writePaneOutput("\u{1b}]21337;status=working;indicator=#ffa500\u{7}")
        XCTAssertTrue(app.staticTexts["working"].waitForExistence(timeout: 5))
        try writePaneOutput("\u{1b}]21337;status=waiting\u{7}")
        XCTAssertTrue(app.staticTexts["waiting"].waitForExistence(timeout: 5))
        try writePaneOutput("\u{1b}]21337;status=;indicator=\u{7}")
        XCTAssertTrue(app.staticTexts["waiting"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testProgramStatusUpdatesAndClearsTheNativeTab() throws {
        launchConnectedTerminal()
        try writePaneOutput("\u{1b}]7501;state=blocked:id=build/test:app=codex\u{7}")
        XCTAssertTrue(app.staticTexts["blocked"].waitForExistence(timeout: 5))
        try writePaneOutput("\u{1b}]7501;state=clear:id=build\u{7}")
        XCTAssertTrue(app.staticTexts["blocked"].waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testProgramStatusCapabilityReplyReachesTheRemoteProgram() throws {
        launchConnectedTerminal()
        let script = config.appendingPathExtension("py")
        defer { try? FileManager.default.removeItem(at: script) }
        try #"""
        import os, select, time, tty
        tty.setraw(0)
        os.write(1, b'\x1b]7501;?\x1b\\')
        expected = b'\x1b]7501;?:states=idle,working,done,blocked,error:kinds=permission,question,auth\x1b\\'
        received = b''
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and not received.endswith(b'\x1b\\'):
            if select.select([0], [], [], max(0, deadline - time.monotonic()))[0]:
                received += os.read(0, 4096)
        os.write(1, b'SUPPORTED\r\n' if received == expected else b'NO_RESPONSE\r\n')
        while os.read(0, 4096):
            pass
        """#.write(to: script, atomically: true, encoding: .utf8)
        try tmux(["respawn-pane", "-k", "-t", "native:0.1", "/usr/bin/python3", script.path])
        waitForServerOutput(["capture-pane", "-p", "-t", "native:0.1"], equals: "SUPPORTED")
    }

    private func writePaneOutput(_ output: String) throws {
        let tty = try tmux(["display-message", "-p", "-t", "native:0.1", "#{pane_tty}"])
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: tty))
        defer { try? handle.close() }
        try handle.write(contentsOf: Data(output.utf8))
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
    private func launchConnectedTerminal(windowTitle: String = "First") {
        app.launch()
        XCTAssertTrue(app.windows[windowTitle].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.groups["Right pane"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.windows.count, 1, app.debugDescription)
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
