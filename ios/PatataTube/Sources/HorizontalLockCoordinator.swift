import Combine
import UIKit

struct HorizontalLockState {
    let normalMask: UIInterfaceOrientationMask
    private(set) var supportedMask: UIInterfaceOrientationMask
    private(set) var lockedOrientation: UIInterfaceOrientation?
    private(set) var latestRequestedInterfaceOrientation: UIInterfaceOrientation?

    var isHorizontal: Bool { lockedOrientation != nil }

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
protocol HorizontalLockScene: AnyObject {
    var horizontalLockIdentifier: ObjectIdentifier { get }
    var interfaceOrientationForLock: UIInterfaceOrientation { get }

    func applySupportedOrientations(
        _ supportedOrientations: UIInterfaceOrientationMask,
        requestedOrientation: UIInterfaceOrientation?
    )
}

extension UIWindowScene: HorizontalLockScene {
    var horizontalLockIdentifier: ObjectIdentifier { ObjectIdentifier(self) }
    var interfaceOrientationForLock: UIInterfaceOrientation { interfaceOrientation }

    func applySupportedOrientations(
        _ supportedOrientations: UIInterfaceOrientationMask,
        requestedOrientation: UIInterfaceOrientation?
    ) {
        keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard let requestedOrientation else { return }
        requestGeometryUpdate(
            .iOS(interfaceOrientations: requestedOrientation.mask)
        ) { _ in
            // Non-fatal: the supported mask remains authoritative and playback continues.
        }
    }
}

@MainActor
protocol DeviceOrientationNotifications: AnyObject {
    var orientation: UIDeviceOrientation { get }
    func beginGeneratingDeviceOrientationNotifications()
    func endGeneratingDeviceOrientationNotifications()
}

extension UIDevice: DeviceOrientationNotifications {}

@MainActor
final class HorizontalLockRegistry {
    static let shared = HorizontalLockRegistry()

    private final class Entry {
        weak var owner: AnyObject?
        let ownerIdentifier: ObjectIdentifier
        var supportedOrientations: UIInterfaceOrientationMask

        init(owner: AnyObject, supportedOrientations: UIInterfaceOrientationMask) {
            self.owner = owner
            self.ownerIdentifier = ObjectIdentifier(owner)
            self.supportedOrientations = supportedOrientations
        }
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    @discardableResult
    func register(
        owner: AnyObject,
        scene: any HorizontalLockScene,
        supportedOrientations: UIInterfaceOrientationMask
    ) -> Bool {
        let identifier = scene.horizontalLockIdentifier
        let ownerIdentifier = ObjectIdentifier(owner)
        let previousEntry = entries[identifier]
        entries[identifier] = Entry(
            owner: owner,
            supportedOrientations: supportedOrientations
        )
        return previousEntry.map {
            $0.owner == nil || $0.ownerIdentifier != ownerIdentifier
        } ?? false
    }

    @discardableResult
    func update(
        owner: AnyObject,
        scene: any HorizontalLockScene,
        supportedOrientations: UIInterfaceOrientationMask
    ) -> Bool {
        guard let entry = entries[scene.horizontalLockIdentifier],
              entry.ownerIdentifier == ObjectIdentifier(owner),
              entry.owner != nil else { return false }
        entry.supportedOrientations = supportedOrientations
        return true
    }

    func unregister(owner: AnyObject, scene: any HorizontalLockScene) {
        unregister(owner: owner, sceneIdentifier: scene.horizontalLockIdentifier)
    }

    func unregister(owner: AnyObject, sceneIdentifier: ObjectIdentifier) {
        let identifier = sceneIdentifier
        guard let entry = entries[identifier],
              entry.ownerIdentifier == ObjectIdentifier(owner) else { return }
        entries.removeValue(forKey: identifier)
    }

    func supportedOrientations(
        for scene: (any HorizontalLockScene)?,
        default normalMask: UIInterfaceOrientationMask
    ) -> UIInterfaceOrientationMask {
        guard let scene else { return normalMask }
        let identifier = scene.horizontalLockIdentifier
        guard let entry = entries[identifier] else { return normalMask }
        guard entry.owner != nil else {
            entries.removeValue(forKey: identifier)
            return normalMask
        }
        return entry.supportedOrientations
    }
}

@MainActor
final class HorizontalLockCoordinator: ObservableObject {

    @Published private(set) var isHorizontal = false
    private var state: HorizontalLockState
    private weak var activeScene: (any HorizontalLockScene)?
    private var activeSceneIdentifier: ObjectIdentifier?
    private let registry: HorizontalLockRegistry
    private let deviceOrientationNotifications: any DeviceOrientationNotifications
    private let notificationCenter: NotificationCenter
    private var orientationObserver: NSObjectProtocol?
    private var ownsDeviceOrientationNotifications = false

    var supportedOrientations: UIInterfaceOrientationMask { state.supportedMask }

    static var normalMask: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad
            ? .all
            : [.portrait, .landscapeLeft, .landscapeRight]
    }

    init(
        normalMask: UIInterfaceOrientationMask = HorizontalLockCoordinator.normalMask,
        registry: HorizontalLockRegistry = .shared,
        deviceOrientationNotifications: any DeviceOrientationNotifications = UIDevice.current,
        notificationCenter: NotificationCenter = .default
    ) {
        state = HorizontalLockState(normalMask: normalMask)
        self.registry = registry
        self.deviceOrientationNotifications = deviceOrientationNotifications
        self.notificationCenter = notificationCenter
    }

    func beginPlayerSession(in scene: any HorizontalLockScene) {
        if activeScene?.horizontalLockIdentifier == scene.horizontalLockIdentifier { return }
        if activeSceneIdentifier != nil { endPlayerSession() }
        state.reset()
        isHorizontal = false
        activeScene = scene
        activeSceneIdentifier = scene.horizontalLockIdentifier
        let replacedOwner = registry.register(
            owner: self,
            scene: scene,
            supportedOrientations: state.supportedMask
        )
        if replacedOwner {
            scene.applySupportedOrientations(state.supportedMask, requestedOrientation: nil)
        }
        beginObservation()
    }

    func toggle() {
        guard let activeScene else { return }
        let requestedOrientation: UIInterfaceOrientation?
        if state.isHorizontal {
            requestedOrientation = state.unlock()
            isHorizontal = false
        } else {
            let interfaceOrientation = activeScene.interfaceOrientationForLock
            guard state.lock(to: interfaceOrientation) else { return }
            isHorizontal = true
            requestedOrientation = interfaceOrientation
        }
        guard registry.update(
            owner: self,
            scene: activeScene,
            supportedOrientations: state.supportedMask
        ) else { return }
        activeScene.applySupportedOrientations(state.supportedMask, requestedOrientation: requestedOrientation)
    }

    func endPlayerSession() {
        let pending = state.unlock()
        isHorizontal = false
        if let activeScene {
            if registry.update(
                owner: self,
                scene: activeScene,
                supportedOrientations: state.supportedMask
            ) {
                activeScene.applySupportedOrientations(state.supportedMask, requestedOrientation: pending)
            }
        }
        if let activeSceneIdentifier {
            registry.unregister(owner: self, sceneIdentifier: activeSceneIdentifier)
        }
        state.reset()
        self.activeScene = nil
        activeSceneIdentifier = nil
        endObservation()
    }

    isolated deinit {
        endPlayerSession()
    }

    private func beginObservation() {
        guard !ownsDeviceOrientationNotifications else { return }
        deviceOrientationNotifications.beginGeneratingDeviceOrientationNotifications()
        ownsDeviceOrientationNotifications = true
        state.record(deviceOrientation: deviceOrientationNotifications.orientation)
        orientationObserver = notificationCenter.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.state.record(deviceOrientation: self.deviceOrientationNotifications.orientation)
            }
        }
    }

    private func endObservation() {
        if let orientationObserver { notificationCenter.removeObserver(orientationObserver) }
        orientationObserver = nil
        guard ownsDeviceOrientationNotifications else { return }
        deviceOrientationNotifications.endGeneratingDeviceOrientationNotifications()
        ownsDeviceOrientationNotifications = false
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? { windows.first(where: \.isKeyWindow) }
}
