import SwiftUI

/// Vista principal de login.
/// Ver: DIAGRAM-FLOW.md para el flujo completo de autenticación.
struct LoginView: View {
    @Environment(AuthenticationService.self) private var authService
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 30) {
                Spacer()
                
                Image(systemName: "lock.shield")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.blue)
                
                Text("Swift B2C Login")
                    .font(.largeTitle)
                    .bold()
                
                Text("Azure AD B2C Authentication")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                contentView
                
                // Error después del flujo
                if let error = authService.state.error {
                    ErrorBannerView(error: error) {
                        authService.clearError()
                    }
                    .padding(.horizontal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                Spacer()
            }
            .padding()
            .toolbar(.hidden, for: .navigationBar)
            .animation(.easeInOut, value: authService.state)
        }
        .task {
            // [FLOW #7] Intento de auto-login silencioso al aparecer la vista
            await authService.signInSilently()
        }
    }
    
    @ViewBuilder
    private var contentView: some View {
        switch authService.state {
        case .idle, .failed:
            signInButton
            
        case .authenticating:
            ProgressView("Autenticando...")
                .progressViewStyle(.circular)
            
        case .authenticated(let user):
            AuthenticatedView(user: user, authService: authService)
        }
    }
    
    private var signInButton: some View {
        // [FLOW #11] Usuario presiona botón de login
        Button("Iniciar Sesión con Azure B2C", systemImage: "person.badge.key") {
            Task { await signIn() }  // [FLOW #12] Invoca signIn()
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding()
        .background(.blue)
        .clipShape(.rect(cornerRadius: 12))
        .padding(.horizontal, 40)
    }
    
    @MainActor
    private func signIn() async {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first?.rootViewController else {
            return
        }
        await authService.signIn(from: rootVC)
    }
}

// MARK: - Authenticated View

private struct AuthenticatedView: View {
    let user: AuthenticatedUser
    let authService: AuthenticationService
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .imageScale(.large)
                .foregroundStyle(.green)
            
            Text("¡Autenticado!")
                .font(.title)
                .fontWeight(.semibold)
            
            UserInfoCard(claims: user.claims)
            
            Button("Cerrar Sesión", systemImage: "arrow.right.square") {
                Task { await authService.signOut() }
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding()
            .background(.red)
            .clipShape(.rect(cornerRadius: 12))
            .padding(.horizontal, 40)
        }
    }
}

// MARK: - User Info Card

private struct UserInfoCard: View {
    let claims: AuthenticatedUser.UserClaims
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let name = claims.fullName {
                InfoRow(label: "Nombre", value: name)
            }
            
            if let email = claims.primaryEmail {
                InfoRow(label: "Correo", value: email)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(.rect(cornerRadius: 12))
        .padding(.horizontal)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label + ":")
                .fontWeight(.semibold)
            Text(value)
        }
        .font(.subheadline)
    }
}

#Preview {
    LoginView()
        .environment(AuthenticationService.shared)
}
