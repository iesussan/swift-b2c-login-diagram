import Foundation
import os

// MARK: - Auth Flow Tracer

/// Instrumenta los tiempos de carga del flujo de autenticación B2C.
///
/// Registra checkpoints con `ContinuousClock` para medir duraciones precisas
/// y emite intervalos con `OSSignposter` para análisis en Instruments.app.
///
/// ## Uso
/// ```swift
/// tracer.begin(.interactiveSignIn)
/// tracer.checkpoint(.msalAcquireTokenStart)
/// tracer.checkpoint(.tokenReceived)
/// tracer.end(.interactiveSignIn)
/// tracer.printSummary()
/// ```
@MainActor
final class AuthFlowTracer {

    // MARK: - Milestone

    /// Hitos medibles del flujo de autenticación.
    enum Milestone: String, Sendable {
        // Warm-up
        case warmUpStart            = "warm_up_start"
        case msalAppCreated         = "msal_app_created"
        case warmUpEnd              = "warm_up_end"

        // First frame
        case firstFrameRendered     = "first_frame_rendered"

        // Login interactivo
        case signInTapped           = "sign_in_tapped"
        case msalAcquireTokenStart  = "msal_acquire_token_start"
        case browserPresented       = "browser_presented"
        case authorityValidated     = "authority_validated"
        case redirectReceived       = "redirect_received"
        case tokenExchangeStart     = "token_exchange_start"
        case tokenReceived          = "token_received"
        case userMapped             = "user_mapped"
        case signInComplete         = "sign_in_complete"

        // Login silencioso
        case silentSignInStart      = "silent_sign_in_start"
        case silentTokenRequested   = "silent_token_requested"
        case silentSignInEnd        = "silent_sign_in_end"

        // Sign-out
        case signOutStart           = "sign_out_start"
        case signOutEnd             = "sign_out_end"
    }

    // MARK: - Interval

    /// Intervalos de alto nivel para Instruments.
    enum Interval: String, Sendable {
        case warmUp             = "WarmUp"
        case interactiveSignIn  = "InteractiveSignIn"
        case silentSignIn       = "SilentSignIn"
        case signOut            = "SignOut"
        case msalTokenAcquire   = "MSALTokenAcquire"
    }

    // MARK: - Private Types

    private struct CheckpointRecord: Sendable {
        let milestone: Milestone
        let instant: ContinuousClock.Instant
        let deltaFromPrevious: Duration?
    }

    // MARK: - Properties

    private let clock = ContinuousClock()
    private let signposter: OSSignposter
    private let logger: any Logger & Sendable

    /// Instante de referencia absoluto para calcular tiempos totales.
    /// Se captura en `init()` y se reinicia en `reset()`.
    private var origin: ContinuousClock.Instant

    private var checkpoints: [CheckpointRecord] = []
    private var activeIntervals: [Interval: OSSignpostIntervalState] = [:]
    private var intervalStartInstants: [Interval: ContinuousClock.Instant] = [:]

    // MARK: - Initialization

    nonisolated init(logger: some Logger & Sendable = PrintLogger()) {
        self.logger = logger
        self.origin = ContinuousClock().now
        self.signposter = OSSignposter(
            subsystem: "org.cloud.anonymous.SwiftB2CLogin",
            category: "AuthFlow"
        )
    }

    // MARK: - Checkpoints

    /// Registra un checkpoint con timestamp preciso.
    /// Calcula el delta desde el checkpoint anterior y emite log + signpost event.
    func checkpoint(_ milestone: Milestone) {
        let now = clock.now
        let previous = checkpoints.last?.instant
        let delta = previous.map { now - $0 }

        let record = CheckpointRecord(
            milestone: milestone,
            instant: now,
            deltaFromPrevious: delta
        )
        checkpoints.append(record)

        // Log en consola con duración
        let deltaText = delta.map { formatDuration($0) } ?? formatDuration(now - origin)
        let totalText = formatDuration(now - origin)
        logger.performance("[\(milestone.rawValue)] Δ \(deltaText) | Total: \(totalText)")

        // Signpost event puntual
        emitSignpostEvent(milestone)
    }

    // MARK: - Intervals (Signpost)

    /// Inicia un intervalo con nombre para visualización en Instruments.
    func begin(_ interval: Interval) {
        let state = beginSignpostInterval(interval)
        activeIntervals[interval] = state
        intervalStartInstants[interval] = clock.now

        logger.performance("▶ Interval START: \(interval.rawValue)")
    }

    /// Finaliza un intervalo y logea la duración total.
    func end(_ interval: Interval) {
        if let state = activeIntervals.removeValue(forKey: interval) {
            endSignpostInterval(interval, state)
        }

        let duration = intervalStartInstants.removeValue(forKey: interval).map { clock.now - $0 }
        let durationText = duration.map { formatDuration($0) } ?? "?"

        logger.performance("■ Interval END: \(interval.rawValue) → \(durationText)")
    }

    // MARK: - Summary

    /// Imprime un resumen tabular con todos los checkpoints registrados.
    func printSummary() {
        guard !checkpoints.isEmpty else {
            logger.performance("No checkpoints recorded")
            return
        }

        let totalDuration = formatDuration(clock.now - origin)

        logger.performance("┌─────────────────────────────────────────────────────────┐")
        logger.performance("│            AUTH FLOW PERFORMANCE SUMMARY                 │")
        logger.performance("├────┬─────────────────────────┬──────────┬───────────────┤")
        logger.performance("│  # │ Checkpoint              │ Delta    │ Cumulative    │")
        logger.performance("├────┼─────────────────────────┼──────────┼───────────────┤")

        for (index, record) in checkpoints.enumerated() {
            let stepNumber = index + 1
            let step = stepNumber < 10 ? "0\(stepNumber)" : "\(stepNumber)"
            let delta = record.deltaFromPrevious.map { formatDuration($0) } ?? formatDuration(record.instant - origin)
            let cumulative = formatDuration(record.instant - origin)
            let name = record.milestone.rawValue
                .replacing("_", with: " ")

            let line = "│ \(step) │ \(name.padding(toLength: 23, withPad: " ", startingAt: 0)) │ \(delta.padding(toLength: 8, withPad: " ", startingAt: 0)) │ \(cumulative.padding(toLength: 13, withPad: " ", startingAt: 0)) │"
            logger.performance(line)
        }

        let totalLine = "│ TOTAL: \(totalDuration)"
        let padded = totalLine.padding(toLength: 59, withPad: " ", startingAt: 0) + "│"
        logger.performance("├────┴─────────────────────────┴──────────┴───────────────┤")
        logger.performance(padded)
        logger.performance("└─────────────────────────────────────────────────────────┘")
    }

    // MARK: - Reset

    /// Limpia todos los checkpoints e intervalos para una nueva sesión.
    func reset() {
        // Finalizar intervalos activos pendientes
        for (interval, state) in activeIntervals {
            endSignpostInterval(interval, state)
        }
        activeIntervals.removeAll()
        intervalStartInstants.removeAll()
        checkpoints.removeAll()
        origin = clock.now

        logger.performance("Tracer reset — ready for new session")
    }

    // MARK: - Private

    private func formatDuration(_ duration: Duration) -> String {
        let ms = duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000
        if ms >= 1000 {
            let seconds = Double(ms) / 1000.0
            let formatted = seconds.formatted(
                .number
                    .precision(.fractionLength(2))
                    .grouping(.never)
                    .locale(Locale(identifier: "en_US_POSIX"))
            )
            return formatted + "s"
        }
        return "\(ms)ms"
    }

    // MARK: - Signpost Helpers

    /// OSSignposter requiere StaticString — no acepta interpolaciones String.
    /// Cada case mapea a un literal compilado en tiempo de compilación.

    private func beginSignpostInterval(_ interval: Interval) -> OSSignpostIntervalState {
        switch interval {
        case .warmUp:            return signposter.beginInterval("WarmUp")
        case .interactiveSignIn: return signposter.beginInterval("InteractiveSignIn")
        case .silentSignIn:      return signposter.beginInterval("SilentSignIn")
        case .signOut:           return signposter.beginInterval("SignOut")
        case .msalTokenAcquire:  return signposter.beginInterval("MSALTokenAcquire")
        }
    }

    private func endSignpostInterval(_ interval: Interval, _ state: OSSignpostIntervalState) {
        switch interval {
        case .warmUp:            signposter.endInterval("WarmUp", state)
        case .interactiveSignIn: signposter.endInterval("InteractiveSignIn", state)
        case .silentSignIn:      signposter.endInterval("SilentSignIn", state)
        case .signOut:           signposter.endInterval("SignOut", state)
        case .msalTokenAcquire:  signposter.endInterval("MSALTokenAcquire", state)
        }
    }

    private func emitSignpostEvent(_ milestone: Milestone) {
        switch milestone {
        case .warmUpStart:           signposter.emitEvent("warm_up_start")
        case .msalAppCreated:        signposter.emitEvent("msal_app_created")
        case .warmUpEnd:             signposter.emitEvent("warm_up_end")
        case .signInTapped:          signposter.emitEvent("sign_in_tapped")
        case .msalAcquireTokenStart: signposter.emitEvent("msal_acquire_token_start")
        case .browserPresented:      signposter.emitEvent("browser_presented")
        case .authorityValidated:    signposter.emitEvent("authority_validated")
        case .redirectReceived:      signposter.emitEvent("redirect_received")
        case .tokenExchangeStart:    signposter.emitEvent("token_exchange_start")
        case .tokenReceived:         signposter.emitEvent("token_received")
        case .userMapped:            signposter.emitEvent("user_mapped")
        case .signInComplete:        signposter.emitEvent("sign_in_complete")
        case .silentSignInStart:     signposter.emitEvent("silent_sign_in_start")
        case .silentTokenRequested:  signposter.emitEvent("silent_token_requested")
        case .silentSignInEnd:       signposter.emitEvent("silent_sign_in_end")
        case .signOutStart:          signposter.emitEvent("sign_out_start")
        case .signOutEnd:            signposter.emitEvent("sign_out_end")
        case .firstFrameRendered:    signposter.emitEvent("first_frame_rendered")
        }
    }
}
