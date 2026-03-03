import SwiftUI
import QuartzCore

/// Vista principal de login.
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
                
                switch authService.state {
                case .idle, .failed:
                    SignInButtonView(action: signIn)
                    
                case .authenticating:
                    ProgressView("Autenticando...")
                        .progressViewStyle(.circular)
                    
                case .authenticated(let user):
                    AuthenticatedView(user: user, authService: authService)
                }
                
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
        .onAppear {
            // Medir First Frame: el completion se invoca cuando
            // Core Animation commitea el frame al render server.
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                authService.tracer.checkpoint(.firstFrameRendered)
            }
            CATransaction.commit()
        }
        .task {
            await authService.signInSilently()
        }
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

// MARK: - Sign In Button

private struct SignInButtonView: View {
    let action: () async -> Void
    
    var body: some View {
        Button("Iniciar Sesión con Azure B2C", systemImage: "person.badge.key") {
            Task { await action() }
        }
        .font(.headline)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding()
        .background(.blue)
        .clipShape(.rect(cornerRadius: 12))
        .padding(.horizontal, 40)
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
                .bold()
            
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
        .background(.thinMaterial)
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
                .bold()
            Text(value)
        }
        .font(.subheadline)
    }
}

#Preview {
    LoginView()
        .environment(AuthenticationService.shared)
}
