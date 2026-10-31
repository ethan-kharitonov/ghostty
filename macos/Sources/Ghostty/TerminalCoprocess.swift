import Foundation
import Darwin
import OSLog

/// Owns a local process group and delivers its bytes in order on the main queue.
final class TerminalCoprocess {
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "coprocess")
    private let pid: pid_t
    private var openStreams = 2
    private var exited = false
    private var finished = false
    private var cancelled = false
    private var canSignal = true
    private var exitStatus: Int32 = 0
    private var diagnostic = Data()
    private var ioFailure: String?
    private let output: (Data) -> Void
    private let completion: (String?) -> Void

    init(command: String, output: @escaping (Data) -> Void, completion: @escaping (String?) -> Void) throws {
        self.output = output
        self.completion = completion
        let stdout = Pipe()
        let stderr = Pipe()
        pid = try Self.spawn(command, stdout: stdout.fileHandleForWriting.fileDescriptor,
                             stderr: stderr.fileHandleForWriting.fileDescriptor)
        Self.logger.debug("Started coprocess pid=\(self.pid, privacy: .public)")
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        drain(stdout.fileHandleForReading, isOutput: true)
        drain(stderr.fileHandleForReading, isOutput: false)
        observeExit()
    }

    func cancel() {
        guard !finished, !cancelled else { return }
        cancelled = true
        guard canSignal else { return }
        Self.logger.debug("Stopping coprocess pid=\(self.pid, privacy: .public)")
        kill(-pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.finished, self.canSignal else { return }
            Self.logger.debug("Killing unresponsive coprocess group pid=\(self.pid, privacy: .public)")
            kill(-self.pid, SIGKILL)
        }
    }

    private static func spawn(_ command: String, stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO))

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        sigdelset(&defaults, SIGKILL)
        sigdelset(&defaults, SIGSTOP)
        var mask = sigset_t()
        sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        try check(posix_spawnattr_setflags(&attributes, Int16(
            POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        )))

        var strings: [UnsafeMutablePointer<CChar>] = []
        defer { for string in strings { free(string) } }
        func copyCString(_ text: String) throws -> UnsafeMutablePointer<CChar> {
            guard let pointer = strdup(text) else { throw POSIXError(.ENOMEM) }
            strings.append(pointer)
            return pointer
        }
        var arguments: [UnsafeMutablePointer<CChar>?] = try ["/bin/sh", "-c", command].map { try copyCString($0) }
        arguments.append(nil)
        var environment: [UnsafeMutablePointer<CChar>?] = try ProcessInfo.processInfo.environment.map {
            try copyCString("\($0.key)=\($0.value)")
        }
        environment.append(nil)
        var pid: pid_t = 0
        try check(posix_spawn(&pid, "/bin/sh", &actions, &attributes, &arguments, &environment))
        return pid
    }

    private static func check(_ result: Int32) throws {
        if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
    }

    private func observeExit() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var info = siginfo_t()
            var result: Int32
            repeat {
                result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT)
            } while result < 0 && errno == EINTR
            let failure = result < 0 ? String(cString: strerror(errno)) : nil
            let status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status
            DispatchQueue.main.async {
                Self.logger.debug("Coprocess exited pid=\(self.pid, privacy: .public) status=\(status, privacy: .public)")
                self.canSignal = failure == nil
                self.ioFailure = failure ?? self.ioFailure
                self.exitStatus = status
                self.exited = true
                self.finishIfDrained()
            }
        }
    }

    private func drain(_ handle: FileHandle, isOutput: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer {
                try? handle.close()
                DispatchQueue.main.async {
                    self.openStreams -= 1
                    self.finishIfDrained()
                }
            }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                if count == 0 { return }
                if count < 0 {
                    if errno == EINTR { continue }
                    let failure = String(cString: strerror(errno))
                    DispatchQueue.main.async { self.ioFailure = failure }
                    return
                }
                let bytes = Data(buffer.prefix(count))
                // Waiting here bounds queued output without blocking the UI.
                DispatchQueue.main.sync {
                    guard !self.cancelled else { return }
                    if isOutput {
                        self.output(bytes)
                    } else {
                        self.diagnostic.append(bytes.prefix(max(0, 16_384 - self.diagnostic.count)))
                    }
                }
            }
        }
    }

    private func finishIfDrained() {
        guard !finished, exited, openStreams == 0 else { return }
        // Keep the exited child unreaped until its pipes close. Its PID remains
        // reserved while cancellation may still signal the owned process group.
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) < 0 && errno == EINTR {}
        finished = true
        Self.logger.debug("Coprocess drained pid=\(self.pid, privacy: .public)")
        if cancelled || (exitStatus == 0 && ioFailure == nil) {
            completion(nil)
            return
        }
        if let ioFailure {
            completion(ioFailure)
            return
        }
        // Shell diagnostics may contain invalid UTF-8; preserve readable bytes with replacement characters.
        // swiftlint:disable:next optional_data_string_conversion
        let detail = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        completion(detail.isEmpty ? "The command exited with status \(exitStatus)." : detail)
    }
}
