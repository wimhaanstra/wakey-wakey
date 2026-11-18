import Foundation

/// Turns the keyboard's charging flag into debounced trigger transitions.
///
/// The mouse uses `DockSensor`, which has extra evidence requirements because a full dock reports
/// "discharging" while the mouse is still parked. The keyboard has no such ambiguity — its charging
/// flag only comes from the charger — so this needs nothing more than agreement over a couple of
/// samples.
final class KeyboardTrigger {

    enum State { case unknown, active, inactive }

    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .unknown
    private var pending: State?
    private var pendingCount = 0

    /// Samples that must agree before a transition is believed (≈4 s at the 2 s push rate).
    var confirmSamples = 2

    func ingest(charging: Bool, at _: Date = Date()) {
        let target: State = charging ? .active : .inactive
        guard target != state else {
            pending = nil
            pendingCount = 0
            return
        }

        if pending == target {
            pendingCount += 1
        } else {
            pending = target
            pendingCount = 1
        }

        guard pendingCount >= confirmSamples else { return }
        pending = nil
        pendingCount = 0
        state = target
        onStateChange?(target)
    }

    func reset() {
        state = .unknown
        pending = nil
        pendingCount = 0
    }
}
