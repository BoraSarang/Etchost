import Foundation

/// /etc/hosts 특권 쓰기. unsigned 앱 전제:
/// temp 파일 → `osascript ... with administrator privileges` 로 `cp`.
/// 합성 내용은 절대 쉘 명령에 보간하지 않음 (경로만 전달).
public struct Applier: Sendable {
    public static let shared = Applier()

    private let hostsPath = "/etc/hosts"

    private init() {}

    public func apply(_ content: String) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("etchost-\(UUID().uuidString).hosts")

        do {
            try content.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            throw EtchostError.applyFailed(Loc.str("applier.tempWriteFailed", error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // 쓰기 + DNS 플러시를 하나의 특권 스크립트로 묶음.
        // killall -HUP mDNSResponder는 root 소유 프로세스라 일반 권한에서
        // "No matching processes" 로 실패하므로 반드시 관리자 권한 안에서 실행.
        let script = #"cp "\#(tempURL.path)" "\#(hostsPath)" && dscacheutil -flushcache && killall -HUP mDNSResponder"#
        let result = await runPrivileged(script, prompt: Loc.str("applier.prompt"))
        guard result.success else {
            if (result.error ?? "").contains("User canceled") || (result.error ?? "").contains("-128") {
                throw EtchostError.permissionDenied
            }
            throw EtchostError.applyFailed(result.error ?? Loc.str("applier.unknownError"))
        }
    }

    public func readCurrentHosts() -> String? {
        try? String(contentsOfFile: hostsPath, encoding: .utf8)
    }

    private func runPrivileged(_ shell: String, prompt: String) async -> (success: Bool, error: String?) {
        let escapedShell = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let fullScript = "do shell script \"\(escapedShell)\" with administrator privileges with prompt \"\(escapedPrompt)\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", fullScript]
        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (process.terminationStatus == 0, err?.isEmpty == false ? err : nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }
}
