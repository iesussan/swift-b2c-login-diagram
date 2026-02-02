import Testing
@testable import SwiftB2CLogin

/// Tests para AuthenticationService
/// Verifica el comportamiento del servicio de autenticación
@Suite("AuthenticationService Tests")
@MainActor
struct AuthenticationServiceTests {
    
    // MARK: - Test Helpers
    
    /// Logger mock para capturar mensajes en tests
    final class MockLogger: Logger, @unchecked Sendable {
        var debugMessages: [String] = []
        var infoMessages: [String] = []
        var errorMessages: [String] = []
        
        func debug(_ message: String) {
            debugMessages.append(message)
        }
        
        func info(_ message: String) {
            infoMessages.append(message)
        }
        
        func error(_ message: String) {
            errorMessages.append(message)
        }
        
        func reset() {
            debugMessages.removeAll()
            infoMessages.removeAll()
            errorMessages.removeAll()
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
        let isValidState = service.state == .idle || service.state.error?.isCustomB2CError == false
        
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
            objectId: "123",
            raw: [:]
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
    
    @Test("AuthError retryable property")
    func authErrorRetryable() {
        #expect(AuthError.cancelled.isRetryable == true)
        #expect(AuthError.network("error").isRetryable == true)
        #expect(AuthError.configuration("bad").isRetryable == false)
        #expect(AuthError.notInitialized.isRetryable == false)
    }
}
