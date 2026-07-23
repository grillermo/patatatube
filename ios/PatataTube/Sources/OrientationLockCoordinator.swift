import Combine
import UIKit

struct OrientationLockState {
    let normalMask: UIInterfaceOrientationMask
    private(set) var supportedMask: UIInterfaceOrientationMask
    private(set) var lockedOrientation: UIInterfaceOrientation?
    private(set) var latestRequestedInterfaceOrientation: UIInterfaceOrientation?

    var isLocked: Bool { lockedOrientation != nil }

    init(normalMask: UIInterfaceOrientationMask) {
        self.normalMask = normalMask
        self.supportedMask = normalMask
    }

    mutating func record(deviceOrientation: UIDeviceOrientation) {
        guard let interfaceOrientation = deviceOrientation.interfaceOrientation,
              normalMask.contains(interfaceOrientation.mask) else { return }
        latestRequestedInterfaceOrientation = interfaceOrientation
    }

    @discardableResult
    mutating func lock(to orientation: UIInterfaceOrientation) -> Bool {
        guard orientation != .unknown, normalMask.contains(orientation.mask) else { return false }
        lockedOrientation = orientation
        supportedMask = orientation.mask
        return true
    }

    mutating func unlock() -> UIInterfaceOrientation? {
        lockedOrientation = nil
        supportedMask = normalMask
        return latestRequestedInterfaceOrientation
    }

    mutating func reset() {
        lockedOrientation = nil
        latestRequestedInterfaceOrientation = nil
        supportedMask = normalMask
    }
}

private extension UIDeviceOrientation {
    var interfaceOrientation: UIInterfaceOrientation? {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }
}

private extension UIInterfaceOrientation {
    var mask: UIInterfaceOrientationMask {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: []
        }
    }
}

@MainActor
final class OrientationLockCoordinator: ObservableObject {
    static let shared = OrientationLockCoordinator()

    @Published private(set) var isLocked = false
    private var state = OrientationLockState(normalMask: OrientationLockCoordinator.normalMask)
    private weak var activeScene: UIWindowScene?
    private var orientationObserver: NSObjectProtocol?

    var supportedOrientations: UIInterfaceOrientationMask { state.supportedMask }

    private static var normalMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad
            ? .all
            : [.portrait, .landscapeLeft, .landscapeRight]
    }

    func beginPlayerSession(in scene: UIWindowScene?) {
        endObservation()
        state.reset()
        isLocked = false
        activeScene = scene
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        state.record(deviceOrientation: UIDevice.current.orientation)
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.state.record(deviceOrientation: UIDevice.current.orientation)
            }
        }
    }

    func toggle(in scene: UIWindowScene?) {
        if let scene { activeScene = scene }
        guard let activeScene else { return }
        if state.isLocked {
            let pending = state.unlock()
            isLocked = false
            applySupportedOrientations(in: activeScene, requested: pending)
        } else if state.lock(to: activeScene.interfaceOrientation) {
            isLocked = true
            applySupportedOrientations(in: activeScene, requested: activeScene.interfaceOrientation)
        }
    }

    func endPlayerSession(in scene: UIWindowScene?) {
        if let scene { activeScene = scene }
        let pending = state.unlock()
        isLocked = false
        if let activeScene { applySupportedOrientations(in: activeScene, requested: pending) }
        state.reset()
        activeScene = nil
        endObservation()
    }

    private func applySupportedOrientations(
        in scene: UIWindowScene,
        requested: UIInterfaceOrientation?
    ) {
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let requested else { return }
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: requested.mask)
        ) { _ in
            // Non-fatal: the supported mask remains authoritative and playback continues.
        }
    }

    private func endObservation() {
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
        orientationObserver = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first(where: \.isKeyWindow) }
}
