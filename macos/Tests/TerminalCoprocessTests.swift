import Foundation
import Testing
@testable import Ghostty

struct TerminalCoprocessTests {
    @Test @MainActor func preservesBytesAndDrainsBeforeCompletion() async throws {
        let result = try await collect("printf '\\033[200~h\\303\\251llo\\033[201~'; printf diagnostic >&2; exit 7")
        #expect(result.output == Data([27, 91, 50, 48, 48, 126, 104, 195, 169, 108, 108, 111, 27, 91, 50, 48, 49, 126]))
        #expect(result.failure == "diagnostic")
    }

    @Test @MainActor func drainsLargeOutputWithoutBlockingOnStderr() async throws {
        let result = try await collect("dd if=/dev/zero bs=65536 count=4 2>/dev/null; dd if=/dev/zero bs=65536 count=4 >&2 2>/dev/null")
        #expect(result.output == Data(repeating: 0, count: 262_144))
        #expect(result.failure == nil)
    }

    @Test @MainActor func cancellationStopsTheProcessAndSuppressesFailure() async throws {
        var child: TerminalCoprocess?
        var output = Data()
        let failure: String? = try await withCheckedThrowingContinuation { continuation in
            do {
                child = try TerminalCoprocess(command: "printf ready; sleep 10; printf finished") { bytes in
                    output.append(bytes)
                    child?.cancel()
                } completion: { continuation.resume(returning: $0) }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        #expect(failure == nil)
        #expect(output == Data("ready".utf8))
        child = nil
    }

    @MainActor private func collect(_ command: String) async throws -> (output: Data, failure: String?) {
        var bytes = Data()
        var child: TerminalCoprocess?
        let failure: String? = try await withCheckedThrowingContinuation { continuation in
            do {
                child = try TerminalCoprocess(command: command) { bytes.append($0) } completion: {
                    continuation.resume(returning: $0)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        withExtendedLifetime(child) {}
        return (bytes, failure)
    }
}
