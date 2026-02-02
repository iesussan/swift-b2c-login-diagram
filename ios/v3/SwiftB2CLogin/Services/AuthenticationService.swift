import Foundation
import UIKit
import WebKit
import MSAL
import Observation

// ═══════════════════════════════════════════════════════════════════════════════
// IMPORTANTE: Los marcadores [FLOW #X] corresponden al diagrama de secuencia
// documentado en DIAGRAM-FLOW.md. Consultar ese archivo para contexto visual.
// ═══════════════════════════════════════════════════════════════════════════════

/// Servicio de autenticación con Microsoft Authentication Library (MSAL).
///
/// Proporciona autenticación contra Azure AD B2C usando flujos interactivos
/// y silenciosos.
///
/// ## Uso
/// ```swift
/// let authService = AuthenticationService.shared
/// await authService.warmUp()
/// await authService.signIn(from: viewController)
/// ```
@MainActor
@Observable
final class AuthenticationService {
    
    // MARK: - Shared Instance
    
    /// Instancia compartida del servicio de autenticación.
    static let shared = AuthenticationService()
    
    // MARK: - Observable State
    
    /// Estado actual del servicio de autenticación.
    private(set) var state: AuthState = .idle
    
    /// Indica si el servicio ha sido inicializado.
    private(set) var isInitialized = false
    
    // MARK: - Private Properties
    
    private var msalApplication: MSALPublicClientApplication?
    private let logger: any Logger & Sendable
    
    /// Observer para detectar errores B2C en URL (pushState/replaceState).
    private var webViewObserver: B2CWebViewObserver?
    
    /// Continuations esperando que el servicio se inicialice.
    private var initializationContinuations: [CheckedContinuation<Void, Never>] = []
    
    // MARK: - Initialization
    
    nonisolated init(logger: some Logger & Sendable = PrintLogger()) {
        self.logger = logger
        // No inicializar automáticamente - usar warmUp() explícitamente
    }
    
    // MARK: - [FLOW #1-6] Warm Up
    
    /// Inicializa el servicio y pre-calienta recursos.
    /// Llamar lo antes posible, idealmente en el App struct.
    func warmUp() async {
        guard !isInitialized else { return }
        
        // [FLOW #2] Inicializar observer en contexto MainActor
        webViewObserver = B2CWebViewObserver()
        
        // [FLOW #3] Inicializar MSAL (internamente llama a createMSALApplication)
        await initializeMSAL()
        
        // [FLOW #6] Marcar como inicializado
        isInitialized = true
        
        // Notificar a todos los que esperaban inicialización
        for continuation in initializationContinuations {
            continuation.resume()
        }
        initializationContinuations.removeAll()
        
        logger.info("AuthenticationService warm up complete")
    }
    
    /// Espera a que el servicio esté inicializado.
    private func waitForInitialization() async {
        guard !isInitialized else { return }
        
        await withCheckedContinuation { continuation in
            initializationContinuations.append(continuation)
        }
    }
    
    // MARK: - [FLOW #12-13, #32-41] Public Methods
    
    /// Inicia el flujo de autenticación interactivo.
    func signIn(from viewController: UIViewController) async {
        // Esperar inicialización si es necesario
        await waitForInitialization()
        
        guard let application = msalApplication else {
            state = .failed(.notInitialized)
            return
        }
        
        // [FLOW #13] Actualizar estado a authenticating
        state = .authenticating
        
        do {
            // [FLOW #14-23] Flujo interactivo completo
            let result = try await acquireTokenInteractively(
                application: application,
                from: viewController
            )
            // [FLOW #32-33] Éxito: mapear resultado y actualizar estado
            state = .authenticated(mapToUser(result))
            logger.info("Authentication successful for: \(result.account.username ?? "unknown")")
        } catch {
            // [FLOW #34-41] Manejo de errores
            // === Logging detallado del error ===
            logger.debug("=== MSAL Error Analysis ===")
            logger.debug("Error type: \(type(of: error))")
            
            let nsError = error as NSError
            logger.debug("Domain: \(nsError.domain)")
            logger.debug("Code: \(nsError.code)")
            logger.debug("Description: \(nsError.localizedDescription)")
            
            // Log userInfo keys y valores (truncados)
            for (key, value) in nsError.userInfo {
                let valueStr = String(describing: value)
                let truncated = valueStr.count > 300 ? String(valueStr.prefix(300)) + "..." : valueStr
                logger.debug("  userInfo[\(key)]: \(truncated)")
            }
            
            // Intentar parsear error B2C de MSAL
            if let customError = B2CErrorParser.parse(from: error) {
                logger.debug("Parsed B2C Custom Error from MSAL:")
                logger.debug("   Code: \(customError.errorCode)")
                logger.debug("   Message: \(customError.message)")
                logger.debug("   Status: \(customError.status)")
                logger.debug("   Recoverable: \(customError.isRetryable)")
            } else {
                logger.debug("No B2C custom error found in MSAL error payload")
            }
            
            // [FLOW #35-37] Verificar si hay un error B2C detectado previamente via WebView observer
            // (puede venir de postMessage/DOM o de parseo de URL como fallback)
            if let detectedError = webViewObserver?.lastDetectedError {
                logger.debug("Using previously detected B2C error from WebView observer:")
                logger.debug("   Code: \(detectedError.errorCode)")
                logger.debug("   Message: \(detectedError.message)")
                logger.debug("===========================")
                webViewObserver?.reset()
                state = .failed(.custom(detectedError))
                return
            }
            
            // [FLOW #38] Parsear error con B2CErrorParser como fallback
            let authError = B2CErrorParser.toAuthError(error)
            logger.debug("Final AuthError: \(authError)")
            logger.debug("===========================")
            
            // [FLOW #41] Actualizar estado a failed
            state = .failed(authError)
            logger.error("Authentication failed: \(authError.userMessage)")
        }
    }
    
    // MARK: - [FLOW #7-10] Silent Authentication
    
    /// Intenta autenticación silenciosa usando tokens en caché.
    func signInSilently() async {
        // Esperar inicialización si es necesario
        await waitForInitialization()
        
        guard let application = msalApplication else { return }
        
        do {
            // [FLOW #8] Buscar cuentas en Keychain
            guard let account = try application.allAccounts().first else {
                // [FLOW #9-10] Sin cuenta cacheada, mantener idle
                logger.debug("No cached account found")
                return
            }
            
            state = .authenticating
            let result = try await acquireTokenSilently(
                application: application,
                account: account
            )
            state = .authenticated(mapToUser(result))
            logger.info("Silent authentication successful")
        } catch {
            logger.debug("Silent auth failed: \(error.localizedDescription)")
            state = .idle
        }
    }
    
    // MARK: - [FLOW #15-16] WebView Factory
    
    /// Crea un WKWebView configurado con las optimizaciones de rendimiento v3.1.
    /// [FLOW #15] Factory method para crear el WebView customizado.
    private func createConfiguredWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        
        // v3.1: Apple gestiona automáticamente el processPool desde iOS 15.
        // Ya no es necesario (ni recomendado) asignarlo manualmente.
        
        // Persistencia de sesión B2C
        config.websiteDataStore = .default()
        
        // Optimización de Renderizado (MSAL 2.8.x style)
        config.suppressesIncrementalRendering = true
        config.allowsInlineMediaPlayback = true
        
        // [FLOW #16] Crear instancia de WKWebView con la configuración
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        
        // Seguridad: Evitar swipe back que rompe el flujo de B2C
        webView.allowsBackForwardNavigationGestures = false
        
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif
        
        return webView
    }
    
    /// Cierra la sesión del usuario actual.
    func signOut() async {
        guard let application = msalApplication else { return }
        
        do {
            for account in try application.allAccounts() {
                try application.remove(account)
            }
            state = .idle
            logger.info("Sign out successful")
        } catch {
            logger.error("Sign out failed: \(error.localizedDescription)")
            state = .failed(.unknown(error.localizedDescription))
        }
    }
    
    /// Limpia el error actual.
    func clearError() {
        if case .failed = state {
            state = .idle
        }
    }
    
    // MARK: - [FLOW #3-5] Private Methods
    
    /// Inicializa MSAL.
    /// [FLOW #3] Llamado desde warmUp()
    private func initializeMSAL() async {
        logger.debug(B2CConfiguration.debugDescription)
        
        do {
            // [FLOW #4-5] Crear y retornar MSALPublicClientApplication
            msalApplication = try createMSALApplication()
            logger.info("MSAL initialized successfully")
        } catch {
            logger.error("MSAL initialization failed: \(error.localizedDescription)")
            state = .failed(.configuration(error.localizedDescription))
        }
    }
    
    private func createMSALApplication() throws -> MSALPublicClientApplication {
        guard let authorityURL = URL(string: B2CConfiguration.authorityURL) else {
            throw AuthError.configuration("Invalid authority URL")
        }
        
        let authority = try MSALB2CAuthority(url: authorityURL)
        
        let config = MSALPublicClientApplicationConfig(
            clientId: B2CConfiguration.clientId,
            redirectUri: B2CConfiguration.redirectUri,
            authority: authority
        )
        config.knownAuthorities = [authority]
        
        return try MSALPublicClientApplication(configuration: config)
    }
    
    // MARK: - [FLOW #14-23] Interactive Token Acquisition
    
    private func acquireTokenInteractively(
        application: MSALPublicClientApplication,
        from viewController: UIViewController
    ) async throws -> MSALResult {
        // [FLOW #14] Resetear observer antes de iniciar
        webViewObserver?.reset()
        
        // [FLOW #15-16] v3.1: Crear WebView con factory
        let customWebView = createConfiguredWebView()
        // [FLOW #17] Conectar observer al WebView (KVO desde t=0)
        webViewObserver?.observe(customWebView)
        
        // [FLOW #19] CRITICAL FIX: Presentar el WebView en un UIViewController modal
        // Evita errores de jerarquía con UIHostingController al no modificar su view directamente.
        let webAuthVC = UIViewController()
        webAuthVC.modalPresentationStyle = .pageSheet // Estilo adecuado para login
        webAuthVC.view.backgroundColor = .systemBackground
        // [FLOW #20] Añadir WebView como subview del modal
        webAuthVC.view.addSubview(customWebView)
        
        NSLayoutConstraint.activate([
            customWebView.topAnchor.constraint(equalTo: webAuthVC.view.safeAreaLayoutGuide.topAnchor),
            customWebView.bottomAnchor.constraint(equalTo: webAuthVC.view.bottomAnchor),
            customWebView.leadingAnchor.constraint(equalTo: webAuthVC.view.leadingAnchor),
            customWebView.trailingAnchor.constraint(equalTo: webAuthVC.view.trailingAnchor)
        ])
        
        // [FLOW #21] Presentar el controlador modalmente para evitar conflictos con SwiftUI
        viewController.present(webAuthVC, animated: true)
        
        defer {
            // [FLOW #30] Detener observación
            webViewObserver?.stopObserving()
            // [FLOW #31] Limpieza: Cerrar el modal al terminar
            webAuthVC.dismiss(animated: true)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            // [FLOW #22] Configurar parámetros de WebView para MSAL
            // FIX: Usamos 'viewController' (el padre original) porque 'webAuthVC' 
            // aún no está en la jerarquía de ventanas (la animación de present no terminó)
            // y MSAL valida validController.view.window != nil.
            let webViewParameters = MSALWebviewParameters(
                authPresentationViewController: viewController
            )
            webViewParameters.webviewType = .wkWebView
            webViewParameters.customWebview = customWebView
            
            let parameters = MSALInteractiveTokenParameters(
                scopes: B2CConfiguration.scopes,
                webviewParameters: webViewParameters
            )
            
            // Optimización: Si hay cuentas cacheadas, usar .login para saltar selección
            let hasAccounts = (try? application.allAccounts().isEmpty == false) ?? false
            parameters.promptType = hasAccounts ? .login : .selectAccount
            
            // [FLOW #23] Invocar MSAL para adquirir token
            // [FLOW #24-28] La navegación B2C ocurre aquí (ver B2CWebViewObserver)
            // [FLOW #29] Callback con resultado o error
            application.acquireToken(with: parameters) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: AuthError.unknown("No result returned"))
                }
            }
        }
    }
    
    private func acquireTokenSilently(
        application: MSALPublicClientApplication,
        account: MSALAccount
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            let parameters = MSALSilentTokenParameters(
                scopes: B2CConfiguration.scopes,
                account: account
            )
            
            application.acquireTokenSilent(with: parameters) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: AuthError.unknown("No result returned"))
                }
            }
        }
    }
    
    private func mapToUser(_ result: MSALResult) -> AuthenticatedUser {
        let claims = result.idToken.flatMap { decodeJWT($0) } ?? [:]
        
        return AuthenticatedUser(
            accessToken: result.accessToken,
            idToken: result.idToken,
            claims: AuthenticatedUser.UserClaims(
                givenName: claims["given_name"] as? String,
                familyName: claims["family_name"] as? String,
                emails: claims["emails"] as? [String] ?? [],
                objectId: claims["oid"] as? String,
                raw: claims
            ),
            expiresOn: result.expiresOn
        )
    }
    
    private func decodeJWT(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        
        var base64 = String(parts[1])
            .replacing("-", with: "+")
            .replacing("_", with: "/")
        
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
