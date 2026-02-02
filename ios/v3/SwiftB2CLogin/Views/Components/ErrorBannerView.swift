import SwiftUI

/// Vista reutilizable para mostrar errores de autenticación
/// Diferencia visualmente entre errores B2C custom y errores genéricos
struct ErrorBannerView: View {
    let error: AuthError
    var onDismiss: (() -> Void)?
    
    var body: some View {
        Group {
            if let b2cError = error.b2cError {
                B2CErrorBanner(error: b2cError, onDismiss: onDismiss ?? {})
            } else {
                GenericErrorBanner(error: error, onDismiss: onDismiss ?? {})
            }
        }
    }
}

// MARK: - B2C Custom Error Banner

private struct B2CErrorBanner: View {
    let error: B2CCustomError
    var onDismiss: (() -> Void)?
    
    private var color: Color {
        switch error.knownCode {
        case .tokenValidationFailed, .invalidOTP, .invalidCredentials:
            return .orange
        case .maxAttemptsReached, .userBlocked, .accountLocked:
            return .red
        case .expiredOTP:
            return .yellow
        case nil:
            return .red
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: error.iconName)
                    .foregroundStyle(color)
                
                Text("Error \(error.errorCode)")
                    .font(.caption)
                    .bold()
                    .foregroundStyle(color)
                
                Spacer()
                
                if let onDismiss {
                    Button("Cerrar", systemImage: "xmark.circle.fill", action: onDismiss)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            
            // Message
            Text(error.message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            
            // Retry hint
            if error.isRetryable {
                Text("Puedes intentarlo de nuevo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
        .clipShape(.rect(cornerRadius: 12))
    }
}

// MARK: - Generic Error Banner

private struct GenericErrorBanner: View {
    let error: AuthError
    var onDismiss: (() -> Void)?
    
    private var color: Color {
        switch error.severity {
        case .info: return .blue
        case .warning: return .orange
        case .error, .critical: return .red
        }
    }
    
    private var icon: String {
        switch error.severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .critical: return "xmark.octagon.fill"
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)
            
            Text(error.userMessage)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            
            Spacer()
            
            if let onDismiss {
                Button("Cerrar", systemImage: "xmark.circle.fill", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(color.opacity(0.1))
        .clipShape(.rect(cornerRadius: 12))
    }
}

// MARK: - Preview

#Preview("B2C Custom Error") {
    VStack(spacing: 16) {
        ErrorBannerView(
            error: .custom(B2CCustomError(
                status: "400",
                errorCode: "B2C0001",
                message: "Revisa tus datos. Solo tienes 3 intentos. ¿No encuentras tu Token?"
            ))
        )
        
        ErrorBannerView(
            error: .custom(B2CCustomError(
                status: "400",
                errorCode: "B2C0002",
                message: "Has alcanzado el máximo de intentos permitidos."
            ))
        )
        
        ErrorBannerView(error: .cancelled)
        
        ErrorBannerView(error: .network("No hay conexión a internet"))
    }
    .padding()
}
