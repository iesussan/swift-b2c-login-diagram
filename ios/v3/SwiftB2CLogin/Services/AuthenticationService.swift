import Foundation
import UIKit
import MSAL
import Observation

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
    
    /// Instrumentación de tiempos del flujo de autenticación.
    let tracer: AuthFlowTracer
    
    /// Cuentas MSAL pre-cacheadas desde `warmUp()`.
    ///
    /// En dispositivos con shared keychain (`com.microsoft.adalcache`),
    /// `allAccounts()` puede tomar segundos escaneando entries de
    /// Outlook/Teams/OneDrive. Pre-cachear durante `warmUp()` evita
    /// bloquear main thread en flujos interactivos.
    private var cachedAccounts: [MSALAccount] = []
    
    /// Task que pre-cachea cuentas del Keychain.
    ///
    /// Almacenar la referencia permite a `signInSilently()` y `signOut()`
    /// hacer `await accountsCacheTask?.value` para garantizar que el
    /// cache esté poblado antes de leer `cachedAccounts`.
    private var accountsCacheTask: Task<Void, Never>?
    
    /// Continuations esperando que el servicio se inicialice.
    private var initializationContinuations: [CheckedContinuation<Void, Never>] = []
    
    // MARK: - Initialization
    
    nonisolated init(logger: some Logger & Sendable = PrintLogger()) {
        self.logger = logger
        self.tracer = AuthFlowTracer(logger: logger)
        // No inicializar automáticamente - usar warmUp() explícitamente
    }
    
    // MARK: - Warm Up
    
    /// Inicializa el servicio y pre-calienta recursos.
    ///
    /// Crea la instancia de `MSALPublicClientApplication` y pre-fetches DNS+TLS
    /// al dominio B2C. Llamar lo antes posible, idealmente en el App struct.
    func warmUp() async {
        guard !isInitialized else { return }
        
        tracer.begin(.warmUp)
        tracer.checkpoint(.warmUpStart)
        
        initializeMSAL()
        tracer.checkpoint(.msalAppCreated)
        
        // Pre-cachear cuentas del Keychain.
        // En dispositivos con shared keychain (com.microsoft.adalcache),
        // allAccounts() puede tomar segundos — no bloquear warmUp().
        // La referencia permite a signInSilently() esperar el resultado.
        if let app = msalApplication {
            accountsCacheTask = Task {
                self.cachedAccounts = (try? app.allAccounts()) ?? []
                self.logger.debug("Keychain accounts cached: \(self.cachedAccounts.count)")
            }
        }
        
        // DNS pre-resolution (fire-and-forget): cachear la conexión TCP/TLS
        // al endpoint B2C en paralelo, sin bloquear la inicialización.
        Task { await prefetchB2CDomain() }
        
        isInitialized = true
        
        for continuation in initializationContinuations {
            continuation.resume()
        }
        initializationContinuations.removeAll()
        
        tracer.checkpoint(.warmUpEnd)
        tracer.end(.warmUp)
        logger.info("AuthenticationService warm up complete")
    }
    
    /// Espera a que el servicio esté inicializado.
    private func waitForInitialization() async {
        guard !isInitialized else { return }
        
        await withCheckedContinuation { continuation in
            initializationContinuations.append(continuation)
        }
    }
    
    // MARK: - Public Methods
    
    /// Inicia el flujo de autenticación interactivo.
    ///
    /// Usa `ASWebAuthenticationSession` (MSAL default) para presentar
    /// el diálogo de autenticación del sistema. Soporta SSO con Safari.
    func signIn(from viewController: UIViewController) async {
        // Esperar inicialización si es necesario
        await waitForInitialization()
        
        guard let application = msalApplication else {
            state = .failed(.notInitialized)
            return
        }
        
        // Instrumentación: nueva sesión de medición
        tracer.reset()
        tracer.begin(.interactiveSignIn)
        tracer.checkpoint(.signInTapped)
        
        state = .authenticating
        
        do {
            let result = try await acquireTokenInteractively(
                application: application,
                from: viewController
            )
            let user = mapToUser(result)
            tracer.checkpoint(.userMapped)
            state = .authenticated(user)
            tracer.checkpoint(.signInComplete)
            tracer.end(.interactiveSignIn)
            tracer.printSummary()
            
            // Refrescar cache de cuentas tras autenticación exitosa (fire-and-forget).
            // Actualizar referencia para que signOut() pueda esperar si es necesario.
            accountsCacheTask = Task {
                self.cachedAccounts = (try? application.allAccounts()) ?? []
                self.logger.debug("Keychain accounts refreshed: \(self.cachedAccounts.count)")
            }
            
            let displayName = user.claims.primaryEmail ?? user.claims.fullName ?? "unknown"
            logger.info("Authentication successful for: \(displayName)")
        } catch {
            logMSALError(error)
            
            let authError = B2CErrorParser.toAuthError(error)
            state = .failed(authError)
            tracer.end(.interactiveSignIn)
            tracer.printSummary()
            logger.error("Authentication failed: \(authError.userMessage)")
        }
    }
    
    // MARK: - Silent Authentication
    
    /// Intenta autenticación silenciosa usando tokens en caché.
    func signInSilently() async {
        // Esperar inicialización si es necesario
        await waitForInitialization()
        
        guard let application = msalApplication else { return }
        
        // Esperar a que el cache de cuentas del Keychain esté poblado.
        // El await cede control al executor → SwiftUI renderiza primer frame
        // antes de que allAccounts() bloquee el run loop.
        await accountsCacheTask?.value
        
        tracer.begin(.silentSignIn)
        tracer.checkpoint(.silentSignInStart)
        
        do {
            guard let account = cachedAccounts.first else {
                tracer.end(.silentSignIn)
                logger.debug("No cached account found")
                return
            }
            
            state = .authenticating
            tracer.checkpoint(.silentTokenRequested)
            let result = try await acquireTokenSilently(
                application: application,
                account: account
            )
            state = .authenticated(mapToUser(result))
            tracer.checkpoint(.silentSignInEnd)
            tracer.end(.silentSignIn)
            tracer.printSummary()
            logger.info("Silent authentication successful")
        } catch {
            tracer.checkpoint(.silentSignInEnd)
            tracer.end(.silentSignIn)
            tracer.printSummary()
            logger.debug("Silent auth failed: \(error.localizedDescription)")
            state = .idle
        }
    }
    
    /// Cierra la sesión del usuario actual.
    func signOut() async {
        guard let application = msalApplication else { return }
        
        // Asegurar que el cache esté poblado antes de iterar.
        await accountsCacheTask?.value
        
        tracer.begin(.signOut)
        tracer.checkpoint(.signOutStart)
        defer {
            tracer.checkpoint(.signOutEnd)
            tracer.end(.signOut)
        }
        
        do {
            for account in cachedAccounts {
                try application.remove(account)
            }
            cachedAccounts = []
            accountsCacheTask = nil
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
    
    // MARK: - Private Methods
    
    /// Inicializa MSAL creando la instancia de `MSALPublicClientApplication`.
    private func initializeMSAL() {
        configureMSALLogging()
        logger.debug(B2CConfiguration.debugDescription)
        
        do {
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
    
    /// Configura el logging interno de MSAL para capturar sub-fases
    /// del flujo interactivo como checkpoints del tracer.
    private func configureMSALLogging() {
        MSALGlobalConfig.loggerConfig.logLevel = .verbose
        MSALGlobalConfig.loggerConfig.logMaskingLevel = .settingsMaskAllPII
        
        // Mapa de keywords MSAL → milestones del tracer.
        // MSAL emite logs en hilos internos; los checkpoints se
        // despachan a @MainActor para consistencia con el tracer.
        let tracer = self.tracer
        MSALGlobalConfig.loggerConfig.setLogCallback { _, message, _ in
            guard let message else { return }
            
            let keyword: AuthFlowTracer.Milestone? = if message.localizedStandardContains("Start webview authorization session") {
                .browserPresented
            } else if message.localizedStandardContains("Resolving authority") {
                .authorityValidated
            } else if message.localizedStandardContains("Result from authorization session") {
                .redirectReceived
            } else if message.localizedStandardContains("Sending network request") {
                .tokenExchangeStart
            } else {
                nil
            }
            
            if let milestone = keyword {
                Task { @MainActor in
                    tracer.checkpoint(milestone)
                }
            }
        }
    }
    
    /// Pre-fetches DNS y establece conexión TCP/TLS con el dominio B2C.
    private func prefetchB2CDomain() async {
        guard let url = URL(string: "https://\(B2CConfiguration.tenantName).b2clogin.com") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        
        do {
            let _ = try await URLSession.shared.data(for: request)
            logger.debug("B2C domain prefetch complete (DNS + TLS cached)")
        } catch {
            logger.debug("B2C domain prefetch failed (non-critical): \(error.localizedDescription)")
        }
    }
    
    /// Registra los detalles de un error MSAL en el log para diagnóstico.
    private func logMSALError(_ error: Error) {
        let nsError = error as NSError
        logger.debug("=== MSAL Error Analysis ===")
        logger.debug("Domain: \(nsError.domain) | Code: \(nsError.code)")
        logger.debug("Description: \(nsError.localizedDescription)")
        
        for (key, value) in nsError.userInfo {
            let valueStr = String(describing: value)
            let truncated = valueStr.count > 300 ? String(valueStr.prefix(300)) + "..." : valueStr
            logger.debug("  userInfo[\(key)]: \(truncated)")
        }
        
        if let customError = B2CErrorParser.parse(from: error) {
            logger.debug("B2C Error → \(customError.errorCode): \(customError.message)")
        }
        logger.debug("===========================")
    }
    
    // MARK: - Interactive Token Acquisition
    
    /// Adquiere un token interactivamente usando ASWebAuthenticationSession.
    ///
    /// MSAL gestiona la presentación y dismiss del diálogo de autenticación
    /// automáticamente.
    private func acquireTokenInteractively(
        application: MSALPublicClientApplication,
        from viewController: UIViewController
    ) async throws -> MSALResult {
        let hasAccounts = !cachedAccounts.isEmpty
        
        return try await withCheckedThrowingContinuation { continuation in
            // .default usa ASWebAuthenticationSession (iOS 12+)
            // Comparte cookies con Safari → SSO automático
            let webViewParameters = MSALWebviewParameters(
                authPresentationViewController: viewController
            )
            
            let parameters = MSALInteractiveTokenParameters(
                scopes: B2CConfiguration.scopes,
                webviewParameters: webViewParameters
            )
            
            // Optimización: Si hay cuentas cacheadas, usar .login para saltar selección
            parameters.promptType = hasAccounts ? .login : .selectAccount
            
            // Instrumentación: medir duración del round-trip MSAL ↔ B2C
            self.tracer.checkpoint(.msalAcquireTokenStart)
            self.tracer.begin(.msalTokenAcquire)
            
            application.acquireToken(with: parameters) { result, error in
                if let error {
                    Task { @MainActor in self.tracer.end(.msalTokenAcquire) }
                    continuation.resume(throwing: error)
                } else if let result {
                    Task { @MainActor in
                        self.tracer.checkpoint(.tokenReceived)
                        self.tracer.end(.msalTokenAcquire)
                    }
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
                objectId: claims["oid"] as? String
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
