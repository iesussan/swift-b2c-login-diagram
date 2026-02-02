import WebKit

// ═══════════════════════════════════════════════════════════════════════════════
// IMPORTANTE: Los marcadores [FLOW #X] corresponden al diagrama de secuencia
// documentado en DIAGRAM-FLOW.md. Consultar ese archivo para contexto visual.
// ═══════════════════════════════════════════════════════════════════════════════

/// Observa errores B2C en WKWebView usando KVO nativo en la URL.
///
/// Detecta cambios en query params como `b2c_error_code` y `loading`.
/// No requiere JavaScript - 100% Swift nativo.
///
/// ## Uso
/// ```swift
/// let observer = B2CWebViewObserver()
/// observer.observe(webView)
///
/// // Reactivo (recomendado)
/// for await error in observer.errors {
///     print("Error: \(error.errorCode)")
/// }
///
/// // Lectura puntual
/// if let error = observer.lastDetectedError { ... }
/// ```
@MainActor
final class B2CWebViewObserver: NSObject {
    
    // MARK: - Properties
    
    /// Último error B2C detectado.
    private(set) var lastDetectedError: B2CCustomError?
    
    /// Stream de errores para consumo reactivo.
    private(set) var errors: AsyncStream<B2CCustomError>!
    private var errorContinuation: AsyncStream<B2CCustomError>.Continuation?
    
    /// Estado de loading actual.
    private(set) var isLoading = false
    
    private var observation: NSKeyValueObservation?
    private weak var webView: WKWebView?
    private let logger: any Logger & Sendable
    
    // MARK: - Initialization
    
    override init() {
        self.logger = PrintLogger()
        super.init()
        setupErrorStream()
    }
    
    init(logger: some Logger & Sendable) {
        self.logger = logger
        super.init()
        setupErrorStream()
    }
    
    private func setupErrorStream() {
        errors = AsyncStream { [weak self] continuation in
            self?.errorContinuation = continuation
        }
    }
    
    // MARK: - [FLOW #17-18] Public Methods
    
    /// Comienza a observar cambios de URL en el WKWebView.
    /// [FLOW #17] Llamado desde AuthenticationService.acquireTokenInteractively()
    func observe(_ webView: WKWebView) {
        stopObserving()
        self.webView = webView
        
        // [FLOW #18] Configurar KVO en la propiedad url del WebView
        observation = webView.observe(\.url, options: [.new, .old]) { [weak self] webView, change in
            guard let self, let url = change.newValue ?? nil else { return }
            Task { @MainActor in
                self.parseURL(url)
            }
        }
        
        // Check inicial
        if let url = webView.url {
            parseURL(url)
        }
        
        logger.debug("[B2CWebViewObserver] Observing URL changes")
    }
    
    /// Detiene la observación.
    func stopObserving() {
        observation?.invalidate()
        observation = nil
        errorContinuation?.finish()
        webView = nil
    }
    
    /// Limpia el estado.
    func reset() {
        lastDetectedError = nil
        isLoading = false
        setupErrorStream()
    }
    
    // MARK: - [FLOW #24-28] URL Parsing
    
    /// Parsea la URL para detectar errores B2C.
    /// [FLOW #24-28] Se ejecuta cada vez que cambia la URL durante la navegación B2C.
    private func parseURL(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty else { return }
        
        // Log URL formateada (solo path + params relevantes)
        logFormattedURL(components, queryItems: queryItems)
        
        // Parsear loading state
        if let loadingValue = queryItems.first(where: { $0.name == "loading" })?.value {
            let wasLoading = isLoading
            isLoading = loadingValue == "true"
            if wasLoading != isLoading {
                logger.debug("[B2CWebViewObserver] Loading: \(isLoading)")
            }
        }
        
        // Parsear error code
        if let errorCode = queryItems.first(where: { $0.name == "b2c_error_code" })?.value,
           !errorCode.isEmpty,
           errorCode.lowercased() != "null" {
            
            let rawMessage = queryItems.first(where: { $0.name == "error_description" })?.value ?? ""
            let message = decodeMessage(rawMessage)
            
            let error = B2CCustomError(
                status: "400",
                errorCode: errorCode,
                message: message
            )
            
            // [FLOW #27] Solo emitir si es diferente al último
            // Esto almacena el error para que AuthenticationService lo lea en FLOW #35-37
            if lastDetectedError?.errorCode != errorCode {
                lastDetectedError = error
                errorContinuation?.yield(error)
                
                logger.info("┌─────────────────────────────────────────────────────")
                logger.info("│ B2C ERROR DETECTED")
                logger.info("├─────────────────────────────────────────────────────")
                logger.info("│ Code:    \(errorCode)")
                logger.info("│ Message: \(message)")
                logger.info("└─────────────────────────────────────────────────────")
            }
        }
    }
    
    // MARK: - Helpers
    
    private func logFormattedURL(_ components: URLComponents, queryItems: [URLQueryItem]) {
        // Extraer solo los params relevantes para debugging
        let relevantParams = ["b2c_error_code", "error_description", "loading", "p"]
        let filteredItems = queryItems.filter { relevantParams.contains($0.name) }
        
        let host = components.host ?? ""
        let path = components.path
        
        // Acortar el host si es muy largo
        let shortHost = host.contains("b2clogin.com") 
            ? host.replacing(".b2clogin.com", with: "") 
            : host
        
        logger.debug("┌─ URL ─────────────────────────────────────────────")
        logger.debug("│ Host: \(shortHost)")
        logger.debug("│ Path: \(path)")
        
        if !filteredItems.isEmpty {
            logger.debug("│ Params:")
            for item in filteredItems {
                let value = item.value?.removingPercentEncoding ?? item.value ?? ""
                let displayValue = value.count > 60 ? String(value.prefix(60)) + "..." : value
                logger.debug("│   \(item.name): \(displayValue)")
            }
        }
        logger.debug("└───────────────────────────────────────────────────")
    }
    
    private func decodeMessage(_ encoded: String) -> String {
        // Decodificar URL encoding (puede estar doble-encoded)
        var decoded = encoded
        
        // Intentar decodificar hasta 3 veces (por doble/triple encoding)
        for _ in 0..<3 {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            decoded = next
        }
        
        return decoded
    }
}
