import Foundation

/// Everything parrot prints goes to stderr through here.
enum LogOptions {
    nonisolated(unsafe) static var timestamps = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func stamp() -> String {
        timestamps ? formatter.string(from: Date()) + "  " : ""
    }
}

func logLine(_ message: String) {
    FileHandle.standardError.write(Data((LogOptions.stamp() + message + "\n").utf8))
}
