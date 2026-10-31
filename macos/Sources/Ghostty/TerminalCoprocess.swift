import Foundation
import Darwin

/// Owns a local process and delivers its bytes in order on the main queue.
final class TerminalCoprocess {
    private let process = Process()
    private let stdout = Pipe()
    private let stderr = Pipe()
    private var openStreams = 2
    private var exited = false
    private var cancelled = false
    private var diagnostic = Data()
    private var readFailure: String?
    private let output: (Data) -> Void
    private let completion: (String?) -> Void

    init(command: String, output: @escaping (Data) -> Void, completion: @escaping (String?) -> Void) throws {
        self.output = output
        self.completion = completion
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.exited = true
                self.finishIfDrained()
            }
        }
        try process.run()
        drain(stdout.fileHandleForReading, isOutput: true)
        drain(stderr.fileHandleForReading, isOutput: false)
    }

    func cancel() {
        cancelled = true
        if process.isRunning { process.terminate() }
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
                    DispatchQueue.main.async { self.readFailure = failure }
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
        guard exited, openStreams == 0 else { return }
        if cancelled || (process.terminationStatus == 0 && readFailure == nil) {
            completion(nil)
            return
        }
        if let readFailure {
            completion(readFailure)
            return
        }
        // Shell diagnostics may contain invalid UTF-8; preserve readable bytes with replacement characters.
        // swiftlint:disable:next optional_data_string_conversion
        let detail = String(decoding: diagnostic, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        completion(detail.isEmpty ? "The command exited with status \(process.terminationStatus)." : detail)
    }
}
