import OSLog

/// Writes to both OSLog (Console.app, `log stream`) and stdout, so logs are also visible
/// when the app is launched with a console attached — `devicectl device process launch --console`.
enum Log {
    static let speech = Channel("speech")
    static let trigger = Channel("trigger")
    static let api = Channel("api")
    static let cost = Channel("cost")

    struct Channel {
        private let name: String
        private let logger: Logger

        init(_ name: String) {
            self.name = name
            self.logger = Logger(subsystem: "Longform", category: name)
        }

        func notice(_ message: @autoclosure () -> String) {
            let message = message()
            logger.notice("\(message, privacy: .public)")
            print("[\(name)] \(message)")
        }

        func error(_ message: @autoclosure () -> String) {
            let message = message()
            logger.error("\(message, privacy: .public)")
            print("[\(name)] ERROR \(message)")
        }
    }
}
