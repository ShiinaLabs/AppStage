import AppKit
import Axe
import AppStage
import AppStageControl

@MainActor
enum StageAccessibilityController {
    static func handle(_ operation: StageAccessibilityOperation, pid: Int32) -> StageAccessibilityResult {
        do {
            guard Axe.App.checkAccessibility(prompt: false) else {
                throw StageControlError.remoteFailure("Grant Accessibility permission to appstage in System Settings > Privacy & Security > Accessibility")
            }
            guard let app = Axe.App.find(processID: pid) else {
                throw StageControlError.remoteFailure("No accessible application for controlled PID \(pid)")
            }
            switch operation {
            case let .resolve(locator):
                return .resolved(try resolve(locator, app: app).frame)
            case let .press(locator):
                let element = try resolve(locator, app: app).element
                try element.performAction(.press)
                return .pressed
            case let .exists(locator):
                do { _ = try resolve(locator, app: app); return .exists(true) }
                catch AccessibilityLookupError.notFound { return .exists(false) }
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private enum AccessibilityLookupError: Error, LocalizedError {
        case notFound
        case ambiguous(Int)
        case missingFrame
        var errorDescription: String? {
            switch self {
            case .notFound: "Accessibility target not found"
            case let .ambiguous(count): "Accessibility target is ambiguous (\(count) matches)"
            case .missingFrame: "Accessibility target has no current screen frame"
            }
        }
    }

    private static func resolve(_ locator: StageAccessibilityLocator, app: Application) throws -> (element: UIElement, frame: StageAccessibilityFrame) {
        var roots = (try? app.windows()) ?? []
        if roots.isEmpty { roots = [app] }
        var elements: [UIElement] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ element: UIElement) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            elements.append(element)
            for child in (try? element.getChildren()) ?? [] { walk(child) }
        }
        for root in roots { walk(root) }
        let matches: [UIElement]
        if let identifier = locator.identifier {
            matches = elements.filter { (try? $0.getIdentifier()) == identifier }
        } else {
            matches = elements.filter { element in
                guard locator.role == nil || (try? element.getRole()?.rawValue) == locator.role else { return false }
                if let title = locator.title, (try? element.getTitle()) != title { return false }
                if let value = locator.value, ((try? element.getValue() as String?) ?? nil) != value { return false }
                return locator.title != nil || locator.value != nil
            }
        }
        guard !matches.isEmpty else { throw AccessibilityLookupError.notFound }
        guard matches.count == 1, let element = matches.first else { throw AccessibilityLookupError.ambiguous(matches.count) }
        guard let rect = try element.getFrame() else { throw AccessibilityLookupError.missingFrame }
        return (element, StageAccessibilityFrame(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height))
    }
}
