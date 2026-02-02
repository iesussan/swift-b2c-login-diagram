import Foundation

/// Configuración de Azure AD B2C
/// Centraliza todos los valores necesarios para la autenticación
/// Los secrets se cargan desde B2CSecrets (excluido del repo)
enum B2CConfiguration {
    // MARK: - Azure AD B2C Settings (from B2CSecrets)
    
    /// Nombre del tenant (sin .onmicrosoft.com)
    static var tenantName: String { B2CSecrets.tenantName }
    
    /// Client ID de la App Registration
    static var clientId: String { B2CSecrets.clientId }
    
    /// Nombre del User Flow / Policy
    static var signUpSignInPolicy: String { B2CSecrets.signUpSignInPolicy }
    
    /// Redirect URI (debe coincidir con App Registration)
    static let redirectUri = "msauth.org.cloud.anonymous.SwiftB2CLogin://auth"
    
    /// Scopes requeridos (MSAL añade automáticamente openid y profile)
    static let scopes: [String] = []
    
    // MARK: - Computed Properties
    
    /// URL completa del authority B2C
    static var authorityURL: String {
        "https://\(tenantName).b2clogin.com/\(tenantName).onmicrosoft.com/\(signUpSignInPolicy)"
    }
    
    /// Keychain group para el dispositivo
    static var keychainGroup: String {
        #if targetEnvironment(simulator)
        return Bundle.main.bundleIdentifier ?? "com.app.default"
        #else
        return "com.microsoft.adalcache"
        #endif
    }
    
    /// Indica si estamos en simulador
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Debug Description

extension B2CConfiguration {
    static var debugDescription: String {
        """
        === B2C Configuration ===
        Tenant: \(tenantName)
        Client ID: \(clientId)
        Policy: \(signUpSignInPolicy)
        Redirect URI: \(redirectUri)
        Authority URL: \(authorityURL)
        Scopes: \(scopes.isEmpty ? "[default: openid, profile]" : scopes.joined(separator: ", "))
        Keychain Group: \(keychainGroup)
        Environment: \(isSimulator ? "SIMULATOR" : "DEVICE")
        ===========================
        """
    }
}
