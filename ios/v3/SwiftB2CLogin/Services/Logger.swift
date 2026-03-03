import Foundation
import os

// MARK: - Logger Protocol

/// Protocolo para logging en la aplicación.
/// Permite inyección de dependencias y testing.
protocol Logger: Sendable {
    /// Log de debug — solo en builds DEBUG.
    func debug(_ message: String)

    /// Log informativo — eventos normales.
    func info(_ message: String)

    /// Log de error — problemas que requieren atención.
    func error(_ message: String)

    /// Log de rendimiento — métricas de tiempos y checkpoints.
    func performance(_ message: String)
}

// MARK: - Print Logger

/// Implementación de Logger con formato columnar alineado.
///
/// Formato: `HH:mm:ss.SSS ┃ LEVEL ┃ message`
/// - `print()` para consola Xcode (solo DEBUG builds).
/// - `os.Logger` para Instruments y Console.app (todos los builds).
struct PrintLogger: Logger, Sendable {

    private static let osLog = os.Logger(
        subsystem: "org.cloud.anonymous.SwiftB2CLogin",
        category: "Auth"
    )

    func debug(_ message: String) {
        #if DEBUG
        emit("DEBUG", message)
        #endif
    }

    func info(_ message: String) {
        #if DEBUG
        emit("INFO ", message)
        #else
        Self.osLog.info("\(message)")
        #endif
    }

    func error(_ message: String) {
        #if DEBUG
        emit("ERROR", message)
        #else
        Self.osLog.error("\(message)")
        #endif
    }

    func performance(_ message: String) {
        #if DEBUG
        emit("PERF ", message)
        #else
        Self.osLog.notice("\(message)")
        #endif
    }

    // MARK: - Private

    private func emit(_ level: String, _ message: String) {
        print("\(Self.timestamp()) ┃ \(level) ┃ \(message)")
    }

    private static let timestampFormat: Date.FormatStyle = Date.FormatStyle()
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
        .secondFraction(.fractional(3))

    private static func timestamp() -> String {
        Date.now.formatted(timestampFormat)
    }
}
