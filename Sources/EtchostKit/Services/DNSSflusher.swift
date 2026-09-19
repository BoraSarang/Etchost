import Foundation

public final class DNSSflusher: @unchecked Sendable {
    public static let shared = DNSSflusher()

    private init() {}

    public func flush() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "dscacheutil -flushcache; killall -HUP mDNSResponder"]

        let pipe = Pipe()
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                throw EtchostError.dnsFlushFailed(msg)
            }
        } catch let error as EtchostError {
            throw error
        } catch {
            throw EtchostError.dnsFlushFailed(error.localizedDescription)
        }
    }
}
