import Foundation

/// Modelo para errores personalizados de Azure B2C Custom Policies
/// Ejemplo: {"status": "400", "errorCode": "B2C0001", "message": "..."}
struct B2CCustomError: Codable, Sendable {
    let status: String
    let errorCode: String
    let message: String
    
    // MARK: - Computed Properties
    
    /// Código HTTP como entero
    var httpStatus: Int? {
        Int(status)
    }
    
    /// Descripción completa para logging
    var fullDescription: String {
        "[\(errorCode)] \(message) (HTTP \(status))"
    }
}

// MARK: - Known Error Codes

extension B2CCustomError {
    /// Códigos de error conocidos de Custom Policies
    enum KnownCode: String, CaseIterable {
        case tokenValidationFailed = "B2C0001"
        case maxAttemptsReached = "B2C0002"
        case userBlocked = "B2C0003"
        case invalidOTP = "B2C0004"
        case expiredOTP = "B2C0005"
        case invalidCredentials = "B2C0006"
        case accountLocked = "B2C0007"
        
        var isRecoverable: Bool {
            switch self {
            case .tokenValidationFailed, .invalidOTP, .expiredOTP, .invalidCredentials:
                return true
            case .maxAttemptsReached, .userBlocked, .accountLocked:
                return false
            }
        }
    }
    
    /// Código conocido (si aplica)
    var knownCode: KnownCode? {
        KnownCode(rawValue: errorCode)
    }
}

// MARK: - Equatable

extension B2CCustomError: Equatable {
    /// Implementación explícitamente no aislada para cumplir con Swift 6.
    nonisolated static func == (lhs: B2CCustomError, rhs: B2CCustomError) -> Bool {
        lhs.errorCode == rhs.errorCode && 
        lhs.status == rhs.status && 
        lhs.message == rhs.message
    }
}

extension B2CCustomError {
    /// Helpers para tipos comunes de error
    var isTokenValidationError: Bool { errorCode == KnownCode.tokenValidationFailed.rawValue }
    var isMaxAttemptsError: Bool { errorCode == KnownCode.maxAttemptsReached.rawValue }
    var isUserBlockedError: Bool { errorCode == KnownCode.userBlocked.rawValue }
    var isRetryable: Bool { knownCode?.isRecoverable ?? true }
}

// MARK: - UI Presentation

extension B2CCustomError {
    /// Icono SF Symbol según el tipo de error
    var iconName: String {
        switch knownCode {
        case .tokenValidationFailed, .invalidOTP, .invalidCredentials:
            return "exclamationmark.triangle.fill"
        case .maxAttemptsReached:
            return "xmark.octagon.fill"
        case .userBlocked, .accountLocked:
            return "person.crop.circle.badge.xmark"
        case .expiredOTP:
            return "clock.badge.exclamationmark"
        case .none:
            return "exclamationmark.circle.fill"
        }
    }
}
