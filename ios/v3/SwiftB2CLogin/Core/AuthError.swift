import Foundation

/// Jerarquía tipada de errores de autenticación.
///
/// Proporciona errores específicos para diferentes escenarios de fallo,
/// permitiendo pattern matching y manejo granular en la UI.
///
/// ## Tipos de Error
/// - ``custom(_:)``: Errores de Azure B2C Custom Policy
/// - ``msal(code:message:)``: Errores estándar de MSAL
/// - ``cancelled``: Usuario canceló el flujo
/// - ``network(_:)``: Problemas de conectividad
/// - ``configuration(_:)``: Errores de configuración
/// - ``notInitialized``: MSAL no inicializado
/// - ``unknown(_:)``: Errores no categorizados
///
/// ## Ejemplo
/// ```swift
/// switch error {
/// case .cancelled:
///     // No mostrar nada, el usuario canceló
///     break
/// case .network:
///     showRetryButton()
/// case .custom(let b2cError) where b2cError.isMaxAttemptsError:
///     showBlockedMessage()
/// default:
///     showGenericError(error.userMessage)
/// }
/// ```
enum AuthError: Error, Equatable, Sendable {
    /// Error personalizado de Azure B2C Custom Policy.
    /// Contiene códigos y mensajes específicos del backend.
    case custom(B2CCustomError)
    
    /// Error estándar de MSAL con código y mensaje.
    case msal(code: Int, message: String)
    
    /// Usuario canceló el flujo de autenticación.
    case cancelled
    
    /// Error de red o conectividad.
    case network(String)
    
    /// Error de configuración (redirect URI, authority, etc.).
    case configuration(String)
    
    /// MSAL no fue inicializado correctamente.
    case notInitialized
    
    /// Error desconocido o no categorizado.
    case unknown(String)
}

// MARK: - User-Friendly Messages

extension AuthError {
    /// Mensaje amigable para mostrar en UI
    var userMessage: String {
        switch self {
        case .custom(let b2cError):
            return b2cError.message
            
        case .msal(let code, let message):
            return "Error de autenticación (\(code)): \(message)"
            
        case .cancelled:
            return "Inicio de sesión cancelado"
            
        case .network(let detail):
            return "Error de conexión: \(detail)"
            
        case .configuration(let detail):
            return "Error de configuración: \(detail)"
            
        case .notInitialized:
            return "Servicio de autenticación no disponible"
            
        case .unknown(let detail):
            return "Error inesperado: \(detail)"
        }
    }
    
    /// Indica si es un error custom de B2C
    var isCustomB2CError: Bool {
        if case .custom = self { return true }
        return false
    }
    
    /// Obtiene el error B2C si existe
    var b2cError: B2CCustomError? {
        if case .custom(let error) = self { return error }
        return nil
    }
    
    /// Indica si el usuario puede reintentar
    var isRetryable: Bool {
        switch self {
        case .cancelled, .network:
            return true
        case .custom(let error):
            return !error.isMaxAttemptsError && !error.isUserBlockedError
        default:
            return false
        }
    }
}

// MARK: - Error Severity

extension AuthError {
    enum Severity {
        case info       // Cancelación, información
        case warning    // Errores recuperables
        case error      // Errores que requieren acción
        case critical   // Errores de configuración
    }
    
    var severity: Severity {
        switch self {
        case .cancelled:
            return .info
        case .network:
            return .warning
        case .custom(let e) where e.isRetryable:
            return .warning
        case .custom:
            return .error
        case .configuration, .notInitialized:
            return .critical
        case .msal, .unknown:
            return .error
        }
    }
}
