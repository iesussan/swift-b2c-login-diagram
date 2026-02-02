import Foundation

/// Secrets de Azure AD B2C
/// IMPORTANTE: ESTE ARCHIVO DEBE ESTAR EN .gitignore
/// En producción, usar configuración desde un archivo .plist excluido del repo
/// o variables de entorno en el pipeline de CI/CD
enum B2CSecrets {
    /// Nombre del tenant (sin .onmicrosoft.com)
    static let tenantName = ""
    
    /// Client ID de la App Registration
    static let clientId = ""
    
    /// Nombre del User Flow / Policy
    static let signUpSignInPolicy = ""
}
