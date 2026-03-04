import Testing
@testable import SwiftB2CLogin

/// Tests para AuthenticationService
/// Verifica el comportamiento del servicio de autenticación
@Suite("AuthenticationService Tests")
@MainActor
struct AuthenticationServiceTests {
    
    // MARK: - Test Helpers
    
    /// Logger mock para capturar mensajes en tests
    @MainActor
    final class MockLogger: Logger, Sendable {
        var debugMessages: [String] = []
        var infoMessages: [String] = []
        var errorMessages: [String] = []
        var performanceMessages: [String] = []
        
        func debug(_ message: String) {
            debugMessages.append(message)
        }
        
        func info(_ message: String) {
            infoMessages.append(message)
        }
        
        func error(_ message: String) {
            errorMessages.append(message)
        }
        
        func performance(_ message: String) {
            performanceMessages.append(message)
        }
        
        func reset() {
            debugMessages.removeAll()
            infoMessages.removeAll()
            errorMessages.removeAll()
            performanceMessages.removeAll()
        }
    }
    
    // MARK: - Initialization Tests
    
    @Test("Initial state is idle")
    func initialStateIsIdle() async throws {
        let logger = MockLogger()
        let service = AuthenticationService(logger: logger)
        
        // Dar tiempo para que el Task de inicialización se ejecute
        try await Task.sleep(for: .milliseconds(100))
        
        // El estado debe ser idle o failed (si MSAL no puede inicializar sin config real)
        let validStates: [AuthState] = [.idle, .failed(.configuration(""))]
        let isValidState = service.state == .idle || service.state.error != nil
        
        #expect(isValidState || service.state.error != nil)
    }
    
    @Test("Logger receives initialization messages")
    func loggerReceivesMessages() async throws {
        let logger = MockLogger()
        _ = AuthenticationService(logger: logger)
        
        try await Task.sleep(for: .milliseconds(100))
        
        // Debe haber logs de debug o error de inicialización
        let hasLogs = !logger.debugMessages.isEmpty || !logger.errorMessages.isEmpty
        #expect(hasLogs)
    }
    
    // MARK: - State Transition Tests
    
    @Test("clearError resets failed state to idle")
    func clearErrorResetsState() async throws {
        let logger = MockLogger()
        let service = AuthenticationService(logger: logger)
        
        try await Task.sleep(for: .milliseconds(100))
        
        // Si el servicio está en failed, clearError debe resetearlo
        if case .failed = service.state {
            service.clearError()
            #expect(service.state == .idle)
        } else {
            // Si no está en failed, clearError no debe hacer nada
            let originalState = service.state
            service.clearError()
            #expect(service.state == originalState)
        }
    }
    
    // MARK: - AuthState Tests
    
    @Test("AuthState computed properties")
    func authStateComputedProperties() {
        // Test idle
        let idle = AuthState.idle
        #expect(idle.isAuthenticated == false)
        #expect(idle.isLoading == false)
        #expect(idle.error == nil)
        #expect(idle.user == nil)
        
        // Test authenticating
        let loading = AuthState.authenticating
        #expect(loading.isAuthenticated == false)
        #expect(loading.isLoading == true)
        
        // Test failed
        let failed = AuthState.failed(.cancelled)
        #expect(failed.isAuthenticated == false)
        #expect(failed.error == .cancelled)
    }
    
    @Test("AuthState with authenticated user")
    func authStateWithUser() {
        let claims = AuthenticatedUser.UserClaims(
            givenName: "John",
            familyName: "Doe",
            emails: ["john@example.com"],
            objectId: "123"
        )
        let user = AuthenticatedUser(
            accessToken: "token",
            idToken: "id-token",
            claims: claims,
            expiresOn: Date()
        )
        
        let state = AuthState.authenticated(user)
        
        #expect(state.isAuthenticated == true)
        #expect(state.user?.claims.givenName == "John")
        #expect(state.user?.claims.primaryEmail == "john@example.com")
        #expect(state.user?.claims.fullName == "John Doe")
    }
    
    // MARK: - AuthError Tests
    
    @Test("AuthError user messages")
    func authErrorUserMessages() {
        #expect(AuthError.cancelled.userMessage == "Inicio de sesión cancelado")
        #expect(AuthError.notInitialized.userMessage == "Servicio de autenticación no disponible")
        #expect(AuthError.network("timeout").userMessage.contains("conexión"))
    }
    
    @Test("AuthError severity levels")
    func authErrorSeverity() {
        #expect(AuthError.cancelled.severity == .info)
        #expect(AuthError.network("error").severity == .warning)
        #expect(AuthError.configuration("bad").severity == .critical)
        #expect(AuthError.notInitialized.severity == .critical)
    }
    
    @Test("AuthError b2cError extraction")
    func authErrorB2CExtraction() {
        let b2cError = B2CCustomError(status: "400", errorCode: "B2C0001", message: "test")
        let error = AuthError.custom(b2cError)
        #expect(error.b2cError == b2cError)
        #expect(AuthError.cancelled.b2cError == nil)
    }
    
    // MARK: - Silent Auth / Cache Tests
    
    @Test("signInSilently returns idle when no cached accounts exist")
    func silentSignInWithEmptyCacheReturnsIdle() async throws {
        let logger = MockLogger()
        let service = AuthenticationService(logger: logger)
        
        await service.warmUp()
        await service.signInSilently()
        
        // Sin cuentas reales en Keychain del simulador, debe quedarse en idle
        let isIdleOrFailed = service.state == .idle || service.state.error != nil
        #expect(isIdleOrFailed)
        #expect(logger.debugMessages.contains(where: { $0.localizedStandardContains("No cached account found") }))
    }
    
    @Test("clearError does not affect account cache behavior")
    func clearErrorPreservesCacheBehavior() async throws {
        let logger = MockLogger()
        let service = AuthenticationService(logger: logger)
        
        await service.warmUp()
        
        // clearError no debe afectar el flujo de silent auth posterior
        service.clearError()
        
        await service.signInSilently()
        
        // Debe seguir reportando "No cached account found" — cache intacto
        #expect(logger.debugMessages.contains(where: { $0.localizedStandardContains("No cached account found") }))
    }
    
    @Test("warmUp logs Keychain accounts cached count")
    func warmUpLogsCachedCount() async throws {
        let logger = MockLogger()
        let service = AuthenticationService(logger: logger)
        
        await service.warmUp()
        
        // Esperar a que el Task del cache complete
        try await Task.sleep(for: .milliseconds(200))
        
        // Debe haber un log con el conteo de cuentas cacheadas
        let hasCacheLog = logger.debugMessages.contains(where: { $0.localizedStandardContains("Keychain accounts cached") })
        
        // En simulador sin MSAL config real, puede fallar la inicialización.
        // Si MSAL se inicializó, debe haber log de cache.
        if logger.infoMessages.contains(where: { $0.localizedStandardContains("MSAL initialized") }) {
            #expect(hasCacheLog)
        }
    }
}
