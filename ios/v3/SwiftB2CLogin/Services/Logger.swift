import Foundation

// MARK: - Logger Protocol

/// Protocolo para logging en la aplicación.
/// Permite inyección de dependencias y testing.
protocol Logger: Sendable {
    /// Log de debug - Solo en builds DEBUG
    func debug(_ message: String)
    
    /// Log informativo - Eventos normales
    func info(_ message: String)
    
    /// Log de error - Problemas que requieren atención
    func error(_ message: String)
}

// MARK: - Print Logger

/// Implementación de Logger que imprime a la consola.
/// Thread-safe gracias a conformancia con Sendable.
struct PrintLogger: Logger, Sendable {
    
    func debug(_ message: String) {
        #if DEBUG
        print("[DEBUG] \(Self.timestamp()) \(message)")
        #endif
    }
    
    func info(_ message: String) {
        print("[INFO] \(Self.timestamp()) \(message)")
    }
    
    func error(_ message: String) {
        print("[ERROR] \(Self.timestamp()) \(message)")
    }
    
    // MARK: - Private
    
    private static let cachedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
    
    private static func timestamp() -> String {
        cachedFormatter.string(from: Date())
    }
}
