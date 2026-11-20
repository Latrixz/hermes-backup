import Foundation

struct ShellResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
    /// The last few lines, for an error message.
    var tail: String {
        output.split(separator: "\n").suffix(6).joined(separator: "\n")
    }
}

struct ShellError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Shell {
    /// Runs a program and collects stdout + stderr together.
    ///
    /// Output is read as it arrives, and the call returns once the program exits even if a
    /// background child it started (`hermes import` can start the gateway) still holds the pipe.
    static func run(_ exe: String, _ args: [String], stdin: Data? = nil,
                    timeout: TimeInterval = 900) throws -> ShellResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = environment

        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        let input = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : input

        let buffer = Buffer()
        out.fileHandleForReading.readabilityHandler = { h in buffer.append(h.availableData) }

        try p.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try? input.fileHandleForWriting.close()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline {
                p.terminate()
                out.fileHandleForReading.readabilityHandler = nil
                throw ShellError(message: "\(URL(fileURLWithPath: exe).lastPathComponent) took too long and was stopped.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 0.1)   // let the last chunk land
        out.fileHandleForReading.readabilityHandler = nil
        buffer.append((try? out.fileHandleForReading.readToEnd()) ?? Data())
        return ShellResult(status: p.terminationStatus, output: buffer.string)
    }

    /// GUI apps start with a bare PATH; Hermes and its helpers live in the user's folders.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                       "/usr/bin", "/bin", "/usr/sbin", "/sbin", env["PATH"] ?? ""].joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["PYTHONIOENCODING"] = "utf-8"
        return env
    }()

    private final class Buffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}
