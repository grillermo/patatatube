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
protocol OrientationLockScene: AnyObject {
    var orientationLockIdentifier: ObjectIdentifier { get }
    var interfaceOrientationForLock: UIInterfaceOrientation { get }

    func applyOrientationLock(
        supportedOrientations: UIInterfaceOrientationMask,
        requestedOrientation: UIInterfaceOrientation?
    )
}

extension UIWindowScene: OrientationLockScene {
    var orientationLockIdentifier: ObjectIdentifier { ObjectIdentifier(self) }
    var interfaceOrientationForLock: UIInterfaceOrientation { interfaceOrientation }

    func applyOrientationLock(
        supportedOrientations: UIInterfaceOrientationMask,
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
final class OrientationLockRegistry {
    static let shared = OrientationLockRegistry()

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
        scene: any OrientationLockScene,
        supportedOrientations: UIInterfaceOrientationMask
    ) -> Bool {
        let identifier = scene.orientationLockIdentifier
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
        scene: any OrientationLockScene,
        supportedOrientations: UIInterfaceOrientationMask
    ) -> Bool {
        guard let entry = entries[scene.orientationLockIdentifier],
              entry.ownerIdentifier == ObjectIdentifier(owner),
              entry.owner != nil else { return false }
        entry.supportedOrientations = supportedOrientations
        return true
    }

    func unregister(owner: AnyObject, scene: any OrientationLockScene) {
        unregister(owner: owner, sceneIdentifier: scene.orientationLockIdentifier)
    }

    func unregister(owner: AnyObject, sceneIdentifier: ObjectIdentifier) {
        let identifier = sceneIdentifier
        guard let entry = entries[identifier],
              entry.ownerIdentifier == ObjectIdentifier(owner) else { return }
        entries.removeValue(forKey: identifier)
    }

    func supportedOrientations(
        for scene: (any OrientationLockScene)?,
        default normalMask: UIInterfaceOrientationMask
    ) -> UIInterfaceOrientationMask {
        guard let scene else { return normalMask }
        let identifier = scene.orientationLockIdentifier
        guard let entry = entries[identifier] else { return normalMask }
        guard entry.owner != nil else {
            entries.removeValue(forKey: identifier)
            return normalMask
        }
        return entry.supportedOrientations
    }
}

@MainActor
final class OrientationLockCoordinator: ObservableObject {

    @Published private(set) var isLocked = false
    private var state: OrientationLockState
    private weak var activeScene: (any OrientationLockScene)?
    private var activeSceneIdentifier: ObjectIdentifier?
    private let registry: OrientationLockRegistry
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
        normalMask: UIInterfaceOrientationMask = OrientationLockCoordinator.normalMask,
        registry: OrientationLockRegistry = .shared,
        deviceOrientationNotifications: any DeviceOrientationNotifications = UIDevice.current,
        notificationCenter: NotificationCenter = .default
    ) {
        state = OrientationLockState(normalMask: normalMask)
        self.registry = registry
        self.deviceOrientationNotifications = deviceOrientationNotifications
        self.notificationCenter = notificationCenter
    }

    func beginPlayerSession(in scene: any OrientationLockScene) {
        if activeScene?.orientationLockIdentifier == scene.orientationLockIdentifier { return }
        if activeSceneIdentifier != nil { endPlayerSession() }
        state.reset()
        isLocked = false
        activeScene = scene
        activeSceneIdentifier = scene.orientationLockIdentifier
        let replacedOwner = registry.register(
            owner: self,
            scene: scene,
            supportedOrientations: state.supportedMask
        )
        if replacedOwner {
            scene.applyOrientationLock(
                supportedOrientations: state.supportedMask,
                requestedOrientation: nil
            )
        }
        beginObservation()
    }

    func toggle() {
        guard let activeScene else { return }
        let requestedOrientation: UIInterfaceOrientation?
        if state.isLocked {
            requestedOrientation = state.unlock()
            isLocked = false
        } else {
            let interfaceOrientation = activeScene.interfaceOrientationForLock
            guard state.lock(to: interfaceOrientation) else { return }
            isLocked = true
            requestedOrientation = interfaceOrientation
        }
        guard registry.update(
            owner: self,
            scene: activeScene,
            supportedOrientations: state.supportedMask
        ) else { return }
        activeScene.applyOrientationLock(
            supportedOrientations: state.supportedMask,
            requestedOrientation: requestedOrientation
        )
    }

    func endPlayerSession() {
        let pending = state.unlock()
        isLocked = false
        if let activeScene {
            if registry.update(
                owner: self,
                scene: activeScene,
                supportedOrientations: state.supportedMask
            ) {
                activeScene.applyOrientationLock(
                    supportedOrientations: state.supportedMask,
                    requestedOrientation: pending
                )
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
