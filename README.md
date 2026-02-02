# Diagrama de Flujo - Arquitectura Login Con B2C usando Custom Web View

Este documento describe el flujo completo de autenticación implementado en la versión 3.1.0, utilizando el patrón de **Inversión de Control** donde la aplicación crea y gestiona el `WKWebView` en lugar de delegarlo a MSAL.

---

## Diagrama de Secuencia Principal

```mermaid
sequenceDiagram
    autonumber
    participant App as SwiftB2CLoginApp
    participant View as LoginView
    participant Auth as AuthenticationService
    participant Observer as B2CWebViewObserver
    participant WebView as WKWebView (Custom)
    participant MSAL as MSALPublicClientApplication
    participant B2C as Azure B2C

    %% ══════════════════════════════════════════════════════════════
    %% FASE 1: INICIALIZACIÓN
    %% ══════════════════════════════════════════════════════════════
    Note over App,MSAL: FASE 1: Inicialización (App Launch)
    App->>Auth: .task { warmUp() }
    Auth->>Observer: B2CWebViewObserver()
    Auth->>Auth: initializeMSAL()
    Auth->>MSAL: MSALPublicClientApplicationConfig()
    MSAL-->>Auth: MSALPublicClientApplication
    Auth->>Auth: isInitialized = true

    %% ══════════════════════════════════════════════════════════════
    %% FASE 2: INTENTO SILENCIOSO
    %% ══════════════════════════════════════════════════════════════
    Note over View,MSAL: FASE 2: Intento Silencioso (Auto-login)
    View->>Auth: .task { signInSilently() }
    Auth->>MSAL: allAccounts()
    MSAL-->>Auth: [nil] (sin cuenta cacheada)
    Auth->>View: state = .idle

    %% ══════════════════════════════════════════════════════════════
    %% FASE 3: USUARIO INICIA SESIÓN
    %% ══════════════════════════════════════════════════════════════
    Note over View,Auth: FASE 3: Usuario presiona "Iniciar Sesión"
    View->>View: [User Tap] signInButton
    View->>Auth: signIn(from: rootVC)
    Auth->>View: state = .authenticating
    Note right of View: UI muestra ProgressView

    %% ══════════════════════════════════════════════════════════════
    %% FASE 4: CREAR WEBVIEW (Inversión de Control)
    %% ══════════════════════════════════════════════════════════════
    Note over Auth,WebView: FASE 4: Crear WebView (Inversión de Control)
    Auth->>Observer: reset()
    Auth->>Auth: createConfiguredWebView()
    Note right of Auth: suppressesIncrementalRendering=true<br/>allowsInlineMediaPlayback=true<br/>websiteDataStore=.default()
    Auth->>WebView: WKWebView(config)
    Auth->>Observer: observe(customWebView)
    Observer->>WebView: webView.observe(\.url) [KVO]

    %% ══════════════════════════════════════════════════════════════
    %% FASE 5: PRESENTAR MODAL (Wrapper Modal Pattern)
    %% ══════════════════════════════════════════════════════════════
    Note over Auth,WebView: FASE 5: Presentar Modal (Wrapper Pattern)
    Auth->>Auth: UIViewController() → webAuthVC
    Auth->>WebView: webAuthVC.view.addSubview(customWebView)
    Auth->>View: rootVC.present(webAuthVC, animated: true)
    Note right of View: Modal aparece sobre SwiftUI

    %% ══════════════════════════════════════════════════════════════
    %% FASE 6: INVOCAR MSAL
    %% ══════════════════════════════════════════════════════════════
    Note over Auth,MSAL: FASE 6: Invocar MSAL con Custom WebView
    Auth->>MSAL: MSALWebviewParameters(authPresentationVC: rootVC)
    Note right of Auth: webviewType = .wkWebView<br/>customWebview = customWebView
    Auth->>MSAL: acquireToken(with: params)

    %% ══════════════════════════════════════════════════════════════
    %% FASE 7: NAVEGACIÓN B2C
    %% ══════════════════════════════════════════════════════════════
    Note over WebView,B2C: FASE 7: Navegación B2C
    MSAL->>WebView: load(loginURL)
    WebView->>B2C: GET /authorize
    B2C-->>WebView: Login Page HTML
    Observer-->>Observer: [KVO] parseURL()
    
    Note over WebView: Usuario ingresa credenciales
    WebView->>B2C: POST /login
    
    alt Error B2C Detectado
        B2C-->>WebView: redirect ?b2c_error_code=...
        Observer-->>Observer: [KVO] parseURL()
        Observer->>Observer: lastDetectedError = B2CCustomError
    else Éxito
        B2C-->>WebView: redirect → redirectUri
        WebView->>MSAL: Redirect interceptado
    end

    %% ══════════════════════════════════════════════════════════════
    %% FASE 8A: ÉXITO
    %% ══════════════════════════════════════════════════════════════
    Note over Auth,MSAL: FASE 8A: Éxito - Token Recibido
    MSAL-->>Auth: MSALResult (accessToken, idToken)
    Auth->>Observer: [defer] stopObserving()
    Auth->>View: [defer] webAuthVC.dismiss()
    Auth->>Auth: mapToUser(result) → decodeJWT()
    Auth->>View: state = .authenticated(user)
    Note right of View: UI muestra AuthenticatedView

    %% ══════════════════════════════════════════════════════════════
    %% FASE 8B: ERROR
    %% ══════════════════════════════════════════════════════════════
    Note over Auth,Observer: FASE 8B: Error - Flujo de Error
    MSAL-->>Auth: NSError
    Auth->>Auth: B2CErrorParser.parse(error)
    Auth->>Observer: lastDetectedError?
    Observer-->>Auth: B2CCustomError (si KVO detectó)
    Auth->>Auth: B2CErrorParser.toAuthError()
    Auth->>Observer: [defer] stopObserving()
    Auth->>View: [defer] webAuthVC.dismiss()
    Auth->>View: state = .failed(.custom(error))
    Note right of View: UI muestra ErrorBannerView
```
---

## Resumen de Clases y Métodos

### 1. `SwiftB2CLoginApp` (Entry Point)

| Método/Propiedad | Descripción |
|------------------|-------------|
| `authService` | `@State` que mantiene la instancia singleton |
| `.task { warmUp() }` | Pre-calienta el servicio al iniciar |
| `.onOpenURL` | Maneja el redirect URI de MSAL |

### 2. `LoginView` (Vista Principal)

| Método | Descripción |
|--------|-------------|
| `signIn()` | Obtiene `rootViewController` y llama a `authService.signIn()` |
| `signInSilently()` | Se ejecuta en `.task` al aparecer la vista |
| `contentView` | Switch sobre `authService.state` para mostrar UI apropiada |

### 3. `AuthenticationService` (Singleton @MainActor @Observable)

| Método | Descripción |
|--------|-------------|
| `warmUp()` | Inicializa MSAL y crea `B2CWebViewObserver` |
| `signIn(from:)` | Flujo interactivo completo |
| `signInSilently()` | Intenta usar tokens del Keychain |
| `signOut()` | Elimina cuentas del Keychain |
| `createConfiguredWebView()` | **Factory v3.1** - Crea WKWebView optimizado |
| `acquireTokenInteractively()` | Orquesta modal + MSAL + observer |
| `acquireTokenSilently()` | Adquiere token sin UI |
| `createMSALApplication()` | Configura MSAL con B2C authority |
| `mapToUser()` | Convierte MSALResult a AuthenticatedUser |
| `decodeJWT()` | Decodifica el ID Token |

### 4. `B2CWebViewObserver` (KVO Nativo)

| Método | Descripción |
|--------|-------------|
| `observe(_:)` | Inicia KVO en `webView.url` |
| `stopObserving()` | Invalida la observación y limpia referencias |
| `parseURL(_:)` | Extrae `b2c_error_code` y `error_description` de query params |
| `reset()` | Limpia `lastDetectedError` y reinicia el stream |
| `errors` | `AsyncStream<B2CCustomError>` para consumo reactivo |

### 5. `B2CErrorParser` (Utilidad Estática)

| Método | Descripción |
|--------|-------------|
| `parse(from:)` | Extrae `B2CCustomError` del `NSError` de MSAL |
| `toAuthError(_:)` | Convierte error genérico a `AuthError` tipado |
| `extractFromUserInfo()` | Busca JSON en claves conocidas del userInfo |
| `extractFromEmbeddedJSON()` | Usa regex para encontrar JSON embebido |

---

## Puntos Clave de la Arquitectura v3.1

### 1. Inversión de Control
La aplicación **crea** el `WKWebView` y se lo pasa a MSAL, en lugar de dejar que MSAL lo cree internamente.

```swift
let customWebView = createConfiguredWebView()  // Nosotros lo creamos
webViewParameters.customWebview = customWebView  // Se lo pasamos a MSAL
```

### 2. Observación Síncrona (t=0)
El observer KVO se conecta **inmediatamente** después de crear el WebView, antes de que MSAL cargue contenido.

```swift
let customWebView = createConfiguredWebView()
webViewObserver?.observe(customWebView)  // ← Observación desde el momento 0
// ... luego MSAL usa el WebView
```

### 3. Patrón Wrapper Modal
Un `UIViewController` temporal contiene el WebView y se presenta modalmente para evitar conflictos con la jerarquía de `UIHostingController` de SwiftUI.

```swift
let webAuthVC = UIViewController()
webAuthVC.view.addSubview(customWebView)
viewController.present(webAuthVC, animated: true)
```

### 4. Doble Detección de Errores

| Fuente | Método | Prioridad |
|--------|--------|-----------|
| KVO (URL) | `B2CWebViewObserver.lastDetectedError` | Alta |
| MSAL NSError | `B2CErrorParser.parse(from:)` | Fallback |

```swift
// Primero verificar KVO
if let detectedError = webViewObserver?.lastDetectedError {
    state = .failed(.custom(detectedError))
    return
}

// Fallback: parsear NSError de MSAL
let authError = B2CErrorParser.toAuthError(error)
state = .failed(authError)
```

---

## Configuración del WKWebView (Factory v3.1)

| Parámetro | Valor | Propósito |
|-----------|-------|-----------|
| `websiteDataStore` | `.default()` | Persistencia de cookies de sesión B2C |
| `suppressesIncrementalRendering` | `true` | Evita "flash" blanco durante redirects |
| `allowsInlineMediaPlayback` | `true` | Soporta flujos QR+PIN |
| `allowsBackForwardNavigationGestures` | `false` | Previene swipe-back accidental |
| `isInspectable` | `true` (DEBUG) | Permite Web Inspector |

---

## Estados de la Aplicación (`AuthState`)

```mermaid
stateDiagram-v2
    [*] --> idle: App Launch
    idle --> authenticating: signIn() / signInSilently()
    authenticating --> authenticated: Token Recibido
    authenticating --> failed: Error
    authenticated --> idle: signOut()
    failed --> idle: clearError() / Retry
    failed --> authenticating: signIn()
```

---

*Última actualización: Febrero 2026*
