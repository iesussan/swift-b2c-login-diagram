import Foundation

/// Estado único de autenticación - Single Source of Truth.
///
/// Representa el estado completo del flujo de autenticación,
/// permitiendo pattern matching y actualizaciones reactivas de UI.
///
/// ## Estados
/// - ``idle``: Usuario no autenticado, listo para iniciar sesión
/// - ``authenticating``: Proceso de autenticación en curso
/// - ``authenticated(_:)``: Usuario autenticado exitosamente
/// - ``failed(_:)``: Error durante la autenticación
///
/// ## Ejemplo
/// ```swift
/// switch authService.state {
/// case .idle:
///     SignInButton()
/// case .authenticating:
///     ProgressView()
/// case .authenticated(let user):
///     WelcomeView(user: user)
/// case .failed(let error):
///     ErrorView(error: error)
/// }
/// ```
enum AuthState: Equatable, Sendable {
    /// Usuario no autenticado, listo para iniciar sesión.
    case idle
    
    /// Proceso de autenticación en curso.
    case authenticating
    
    /// Usuario autenticado exitosamente con sus datos.
    case authenticated(AuthenticatedUser)
    
    /// Error durante la autenticación.
    case failed(AuthError)
    
    // MARK: - Computed Properties
    
    /// Indica si el usuario está autenticado.
    var isAuthenticated: Bool {
        if case .authenticated = self { return true }
        return false
    }
    
    /// Indica si hay una operación de autenticación en curso.
    var isLoading: Bool {
        if case .authenticating = self { return true }
        return false
    }
    
    /// Error actual si el estado es `.failed`, `nil` en otro caso.
    var error: AuthError? {
        if case .failed(let error) = self { return error }
        return nil
    }
    
    /// Usuario actual si está autenticado, `nil` en otro caso.
    var user: AuthenticatedUser? {
        if case .authenticated(let user) = self { return user }
        return nil
    }
}

// MARK: - Authenticated User Model

struct AuthenticatedUser: Equatable, Sendable {
    let accessToken: String
    let idToken: String?
    let claims: UserClaims
    let expiresOn: Date?
    
    /// Claims tipados del usuario
    struct UserClaims: Equatable, Sendable {
        let givenName: String?
        let familyName: String?
        let emails: [String]
        let objectId: String?
        
        var primaryEmail: String? { emails.first }
        var fullName: String? {
            [givenName, familyName]
                .compactMap { $0 }
                .joined(separator: " ")
                .nilIfEmpty
        }
        
        init(givenName: String?, familyName: String?, emails: [String], objectId: String?) {
            self.givenName = givenName
            self.familyName = familyName
            self.emails = emails
            self.objectId = objectId
        }
    }
}

// MARK: - String Extension

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
