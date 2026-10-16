import Foundation

// Use monotonic uptime so wall-clock adjustments cannot suspend following.
public struct WindowFollowCadence {
    private var lastDiscovery = -Double.infinity
    private var lastPresence = -Double.infinity
    private var lastDiagnostics = -Double.infinity
    private var visible: Bool?

    public init() {}

    public mutating func discover(now: TimeInterval, force: Bool = false) -> Bool {
        guard force || now - lastDiscovery >= 0.25 else { return false }
        lastDiscovery = now
        return true
    }

    public mutating func presence(now: TimeInterval, visible: Bool) -> Bool {
        guard self.visible != visible || now - lastPresence >= 1 else { return false }
        self.visible = visible
        lastPresence = now
        return true
    }

    public mutating func diagnostics(now: TimeInterval) -> Bool {
        guard now - lastDiagnostics >= 0.25 else { return false }
        lastDiagnostics = now
        return true
    }
}

// isVisible stays true when a panel slips behind its host (for example after
// switching Spaces or closing settings). Repair that ordering on discovery.
public enum WindowFollowOrdering {
    public static func needsOrdering(frontToBack: [Int], host: Int, panel: Int) -> Bool {
        guard let hostIndex = frontToBack.firstIndex(of: host) else { return false }
        guard let panelIndex = frontToBack.firstIndex(of: panel) else { return true }
        return panelIndex > hostIndex
    }
}
