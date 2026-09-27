import CoreGraphics
@preconcurrency import ScreenCaptureKit

/// A running application's on-screen window and its ScreenCaptureKit handle.
public struct StageCaptureWindow: @unchecked Sendable {
    public let windowID: CGWindowID
    public let processIdentifier: pid_t
    public let title: String?
    public let bundleIdentifier: String
    public let frame: CGRect

    let screenCaptureWindow: SCWindow

    init(screenCaptureWindow: SCWindow, bundleIdentifier: String) {
        self.screenCaptureWindow = screenCaptureWindow
        self.windowID = screenCaptureWindow.windowID
        self.processIdentifier = screenCaptureWindow.owningApplication?.processID ?? 0
        self.title = screenCaptureWindow.title
        self.bundleIdentifier = bundleIdentifier
        self.frame = screenCaptureWindow.frame
    }
}

public struct StageCaptureApplication: Equatable, Sendable {
    public let bundleIdentifier: String
    public let applicationName: String

    init(bundleIdentifier: String, applicationName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
    }
}

/// A display and its ScreenCaptureKit handle.
public struct StageCaptureDisplay: @unchecked Sendable {
    public let displayID: CGDirectDisplayID
    public let frame: CGRect
    public let width: Int
    public let height: Int

    let screenCaptureDisplay: SCDisplay

    init(screenCaptureDisplay: SCDisplay) {
        self.screenCaptureDisplay = screenCaptureDisplay
        self.displayID = screenCaptureDisplay.displayID
        self.frame = screenCaptureDisplay.frame
        self.width = screenCaptureDisplay.width
        self.height = screenCaptureDisplay.height
    }
}

public enum StageCaptureDiscoveryError: Error, Equatable {
    case windowNotFound(bundleIdentifier: String)
}

/// Discovers shareable windows and displays through ScreenCaptureKit.
public enum StageCaptureDiscovery {
    public static func applications() async throws -> [StageCaptureApplication] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        return content.applications
            .map {
                StageCaptureApplication(
                    bundleIdentifier: $0.bundleIdentifier,
                    applicationName: $0.applicationName
                )
            }
            .sorted {
                if $0.applicationName == $1.applicationName {
                    return $0.bundleIdentifier < $1.bundleIdentifier
                }
                return $0.applicationName.localizedStandardCompare($1.applicationName) == .orderedAscending
            }
    }

    public static func windows(
        bundleIdentifier: String,
        processIdentifier: pid_t? = nil
    ) async throws -> [StageCaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        return content.windows.compactMap { window in
            guard window.isOnScreen,
                  let ownerBundleIdentifier = window.owningApplication?.bundleIdentifier,
                  ownerBundleIdentifier == bundleIdentifier,
                  processIdentifier == nil || window.owningApplication?.processID == processIdentifier
            else {
                return nil
            }
            return StageCaptureWindow(
                screenCaptureWindow: window,
                bundleIdentifier: ownerBundleIdentifier
            )
        }
    }

    /// Returns the largest visible window owned by the requested application.
    /// Window ID breaks ties to keep selection deterministic.
    public static func window(
        bundleIdentifier: String,
        processIdentifier: pid_t? = nil
    ) async throws -> StageCaptureWindow {
        let windows = try await windows(
            bundleIdentifier: bundleIdentifier,
            processIdentifier: processIdentifier
        )
        guard let selectedWindow = windows.max(by: { lhs, rhs in
            let lhsArea = lhs.frame.width * lhs.frame.height
            let rhsArea = rhs.frame.width * rhs.frame.height
            if lhsArea == rhsArea {
                return lhs.windowID > rhs.windowID
            }
            return lhsArea < rhsArea
        }) else {
            throw StageCaptureDiscoveryError.windowNotFound(bundleIdentifier: bundleIdentifier)
        }
        return selectedWindow
    }

    public static func displays() async throws -> [StageCaptureDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        return content.displays.map(StageCaptureDisplay.init(screenCaptureDisplay:))
    }

    static func displayFilter(
        display: StageCaptureDisplay,
        including window: StageCaptureWindow,
        includingApplicationWindows: Bool = false
    ) async throws -> SCContentFilter {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let capturedWindow = content.windows.first(where: { $0.windowID == window.windowID }),
              capturedWindow.owningApplication?.bundleIdentifier == window.bundleIdentifier,
              capturedWindow.owningApplication?.processID == window.processIdentifier
        else {
            throw StageCaptureDiscoveryError.windowNotFound(bundleIdentifier: window.bundleIdentifier)
        }

        let excludedIDs: Set<CGWindowID>
        if includingApplicationWindows {
            excludedIDs = Set(content.windows.compactMap { candidate -> CGWindowID? in
                guard candidate.windowID != window.windowID,
                      candidate.owningApplication?.processID != window.processIdentifier else { return nil }
                return candidate.windowID
            })
        } else {
            excludedIDs = Set(windowIDsToExclude(from: content.windows.map(\.windowID), except: window.windowID))
        }
        let excludedWindows = content.windows.filter { excludedIDs.contains($0.windowID) }
        return SCContentFilter(display: display.screenCaptureDisplay, excludingWindows: excludedWindows)
    }

    static func windowIDsToExclude(from windowIDs: [CGWindowID], except targetWindowID: CGWindowID) -> [CGWindowID] {
        windowIDs.filter { $0 != targetWindowID }
    }
}
