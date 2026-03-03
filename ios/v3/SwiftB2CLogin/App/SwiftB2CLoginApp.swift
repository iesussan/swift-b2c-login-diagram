import SwiftUI
import MSAL

/// Entry point de la aplicación.
@main
struct SwiftB2CLoginApp: App {
    
    /// Servicio de autenticación compartido.
    /// Se inicializa una sola vez a nivel de aplicación.
    @State private var authService = AuthenticationService.shared
    
    var body: some Scene {
        WindowGroup {
            LoginView()
                .environment(authService)
                .task {
                    await authService.warmUp()
                }
                .onOpenURL { url in
                    // Manejar el redirect URI de MSAL
                    MSALPublicClientApplication.handleMSALResponse(
                        url,
                        sourceApplication: nil
                    )
                }
        }
    }
}
