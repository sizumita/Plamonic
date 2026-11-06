import AppKit
import ApplicationServices
import Foundation

/// "Inspect element under the mouse" for the rule editor.
final class AXInspector: ElementInspecting {
    private let ownPID: pid_t
    private let maxDepth: Int
    private static let plan = AXFetchPlan([
        .role, .subrole, .roleDescription, .frame, .value, .title, .description, .domClassList, .identifier, .parent,
    ])

    init(ownPID: pid_t = getpid(), maxDepth: Int = 64) {
        self.ownPID = ownPID
        self.maxDepth = maxDepth
    }

    func inspectElement(atAX point: CGPoint) -> InspectedElement? {
        guard let hit = hitTest(point), let pid = hit.pid, pid != ownPID else { return nil }
        var path: [ElementDescriptor] = []
        var current: AXElement? = hit
        var seen = Set<AXElement>()
        while let element = current, path.count < maxDepth, !seen.contains(element) {
            seen.insert(element)
            guard let info = element.fetch(AXInspector.plan) else { break }
            if info.role == "AXApplication" { break }
            path.append(AXInspector.descriptor(info))
            if info.role == "AXWindow" { break }
            current = info.parent
        }
        guard !path.isEmpty else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        return InspectedElement(
            bundleID: app?.bundleIdentifier ?? "", appName: app?.localizedName ?? "", path: path)
    }

    /// System-wide hit test; when it lands on our own windows, retries on the app whose window is below.
    private func hitTest(_ point: CGPoint) -> AXElement? {
        if let hit = AXElement.systemWide.element(atAX: point), let pid = hit.pid, pid != ownPID {
            return hit
        }
        guard let window = WindowLocator.topWindow(atAX: point, excludingPIDs: [ownPID]) else { return nil }
        return AXElement.application(pid: window.pid).element(atAX: point)
    }

    static func descriptor(_ info: AXNodeInfo) -> ElementDescriptor {
        let text = [info.stringValue, info.title, info.descriptionText]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        let preview = text.count > 80 ? String(text.prefix(79)) + "…" : text
        return ElementDescriptor(
            role: info.role,
            subrole: info.subrole,
            roleDescription: info.roleDescription,
            domClasses: info.domClasses,
            identifier: (info.identifier?.isEmpty ?? true) ? nil : info.identifier,
            axFrame: info.frame,
            textPreview: preview.replacingOccurrences(of: "\n", with: " "))
    }
}
