import Foundation

/// Parser de errores personalizados de B2C Custom Policies
/// Extrae errores JSON del userInfo de NSError de MSAL
enum B2CErrorParser {
    
    // MARK: - Cached Regex (compiled once for performance)
    
    private static let cachedRegexPatterns: [NSRegularExpression] = {
        let patterns = [
            #"\{[^{}]*"errorCode"\s*:\s*"[^"]+"\s*[^{}]*\}"#,
            #"\{"status"[^}]+"errorCode"[^}]+"message"[^}]+\}"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()
    
    // MARK: - Cached JSON Decoder
    
    private static let jsonDecoder = JSONDecoder()
    
    /// Intenta extraer un B2CCustomError de un error de MSAL
    /// - Parameter error: Error original de MSAL
    /// - Returns: B2CCustomError si se encuentra, nil si no
    static func parse(from error: Error) -> B2CCustomError? {
        let nsError = error as NSError
        
        // Estrategia 1: Buscar en claves conocidas del userInfo
        let searchKeys = [
            "MSALErrorDescriptionKey",
            "MSALHTTPResponseBodyKey",
            "MSALOAuthErrorKey",
            "body",
            "NSLocalizedDescription"
        ]
        
        for key in searchKeys {
            if let customError = extractFromUserInfo(nsError.userInfo, key: key) {
                return customError
            }
        }
        
        // Estrategia 2: Buscar en underlying error
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return parse(from: underlying)
        }
        
        // Estrategia 3: Buscar en toda la descripción
        let fullDescription = nsError.localizedDescription + " " + String(describing: nsError.userInfo)
        return extractFromEmbeddedJSON(fullDescription)
    }
    
    // MARK: - Private Methods
    
    private static func extractFromUserInfo(_ userInfo: [String: Any], key: String) -> B2CCustomError? {
        guard let value = userInfo[key] else { return nil }
        
        // Si es Data, intentar decodificar directamente
        if let data = value as? Data {
            return decode(from: data)
        }
        
        // Si es String, intentar parsear como JSON
        if let string = value as? String {
            // Intento directo
            if let error = decode(from: string) {
                return error
            }
            // Intento con JSON embebido
            if let error = extractFromEmbeddedJSON(string) {
                return error
            }
        }
        
        return nil
    }
    
    private static func extractFromEmbeddedJSON(_ text: String) -> B2CCustomError? {
        // Usar regex cacheados para mejor performance
        for regex in cachedRegexPatterns {
            guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else {
                continue
            }
            
            let jsonString = String(text[range])
            if let error = decode(from: jsonString) {
                return error
            }
        }
        
        return nil
    }
    
    private static func decode(from string: String) -> B2CCustomError? {
        guard let data = string.data(using: .utf8) else { return nil }
        return decode(from: data)
    }
    
    private static func decode(from data: Data) -> B2CCustomError? {
        try? jsonDecoder.decode(B2CCustomError.self, from: data)
    }
}

// MARK: - URL Query Parameter Parsing

extension B2CErrorParser {
    
    /// Nombres de query params donde B2C puede inyectar errores.
    private enum URLQueryParam {
        static let errorCode = "b2c_error_code"
        static let errorDescription = "error_description"
        static let errorMessage = "error_message"
        static let error = "error"
    }
    
    /// Extrae un error B2C de los query params de una URL.
    ///
    /// Azure B2C inyecta errores en la URL durante validaciones fallidas.
    /// Este método parsea esos query params y construye un `B2CCustomError`.
    ///
    /// - Parameter url: URL con posibles query params de error.
    /// - Returns: `B2CCustomError` si se encuentra un código de error, `nil` en otro caso.
    static func parse(from url: URL) -> B2CCustomError? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }
        
        // Buscar b2c_error_code primero (formato de Custom Policies)
        if let errorCode = queryItems.first(where: { $0.name == URLQueryParam.errorCode })?.value,
           !errorCode.isEmpty {
            let message = extractErrorMessage(from: queryItems)
            return B2CCustomError(
                status: "400",
                errorCode: errorCode,
                message: message
            )
        }
        
        // Fallback: Buscar error estándar OAuth (formato de B2C estándar)
        if let error = queryItems.first(where: { $0.name == URLQueryParam.error })?.value,
           !error.isEmpty {
            let description = queryItems.first(where: { $0.name == URLQueryParam.errorDescription })?.value
            let message = description?.removingPercentEncoding ?? description ?? error
            
            // Intentar extraer código B2C del mensaje si existe
            let extractedCode = extractB2CCode(from: message) ?? error.uppercased()
            
            return B2CCustomError(
                status: "400",
                errorCode: extractedCode,
                message: message
            )
        }
        
        return nil
    }
    
    /// Extrae el mensaje de error de los query items.
    private static func extractErrorMessage(from queryItems: [URLQueryItem]) -> String {
        let descriptionItem = queryItems.first {
            $0.name == URLQueryParam.errorDescription || $0.name == URLQueryParam.errorMessage
        }
        
        if let rawMessage = descriptionItem?.value {
            return rawMessage.removingPercentEncoding ?? rawMessage
        }
        
        return "Error de validación"
    }
    
    /// Intenta extraer un código B2C (ej: "B2C0001") de un mensaje.
    private static func extractB2CCode(from message: String) -> String? {
        let pattern = #"B2C\d{4}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let range = Range(match.range, in: message) else {
            return nil
        }
        return String(message[range])
    }
}

// MARK: - AuthError Factory

extension B2CErrorParser {
    
    /// Convierte un error de MSAL a AuthError tipado
    /// - Parameter error: Error original
    /// - Returns: AuthError categorizado
    static func toAuthError(_ error: Error) -> AuthError {
        // Primero intentar extraer error custom de B2C
        if let customError = parse(from: error) {
            return .custom(customError)
        }
        
        let nsError = error as NSError
        
        // Categorizar según el dominio y código
        switch (nsError.domain, nsError.code) {
        case ("MSALErrorDomain", -50005): // userCanceled
            return .cancelled
            
        case ("MSALErrorDomain", -50000):
            return .configuration(extractMessage(from: nsError))
            
        case ("NSURLErrorDomain", _):
            return .network(nsError.localizedDescription)
            
        case ("MSALErrorDomain", let code):
            return .msal(code: code, message: extractMessage(from: nsError))
            
        default:
            return .unknown(nsError.localizedDescription)
        }
    }
    
    private static func extractMessage(from error: NSError) -> String {
        if let desc = error.userInfo["MSALErrorDescriptionKey"] as? String {
            return desc
        }
        return error.localizedDescription
    }
}
