import Testing
import UIKit
@testable import PatataTube

@MainActor
private final class OrientationLockTestScene: OrientationLockScene {
    var interfaceOrientationForLock: UIInterfaceOrientation
    private(set) var applications: [(UIInterfaceOrientationMask, UIInterfaceOrientation?)] = []
    private let customIdentifier: ObjectIdentifier?

    var orientationLockIdentifier: ObjectIdentifier {
        customIdentifier ?? ObjectIdentifier(self)
    }

    init(interfaceOrientation: UIInterfaceOrientation, identifierOwner: AnyObject? = nil) {
        self.interfaceOrientationForLock = interfaceOrientation
        customIdentifier = identifierOwner.map(ObjectIdentifier.init)
    }

    func applyOrientationLock(
        supportedOrientations: UIInterfaceOrientationMask,
        requestedOrientation: UIInterfaceOrientation?
    ) {
        applications.append((supportedOrientations, requestedOrientation))
    }
}

@MainActor
private final class DeviceOrientationNotificationsSpy: DeviceOrientationNotifications {
    var orientation: UIDeviceOrientation
    private(set) var beginCount = 0
    private(set) var endCount = 0

    init(orientation: UIDeviceOrientation = .portrait) {
        self.orientation = orientation
    }

    func beginGeneratingDeviceOrientationNotifications() { beginCount += 1 }
    func endGeneratingDeviceOrientationNotifications() { endCount += 1 }
}

@Suite("Player orientation lock state")
struct OrientationLockCoordinatorTests {
    @Test func phoneStartsUnlockedWithItsConfiguredMask() {
        let sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        #expect(!sut.isLocked)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
    }

    @Test func lockCapturesTheDisplayedInterfaceOrientation() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        let didLock = sut.lock(to: .landscapeLeft)
        #expect(didLock)
        #expect(sut.isLocked)
        #expect(sut.supportedMask == .landscapeLeft)
    }

    @Test func invalidInterfaceOrientationCannotLock() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        let didLock = sut.lock(to: .unknown)
        #expect(!didLock)
        #expect(!sut.isLocked)
    }

    @Test func rotationWhileLockedIsRememberedWithoutChangingTheMask() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock(to: .portrait)
        sut.record(deviceOrientation: .landscapeLeft)
        #expect(sut.supportedMask == .portrait)
        #expect(sut.latestRequestedInterfaceOrientation == .landscapeRight)
    }

    @Test func faceUpFaceDownAndUnknownReadingsAreIgnored() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .landscapeRight)
        sut.record(deviceOrientation: .faceUp)
        sut.record(deviceOrientation: .faceDown)
        sut.record(deviceOrientation: .unknown)
        #expect(sut.latestRequestedInterfaceOrientation == .landscapeLeft)
    }

    @Test func unlockRestoresNormalMaskAndReturnsLatestSupportedOrientation() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock(to: .portrait)
        sut.record(deviceOrientation: .landscapeRight)
        #expect(sut.unlock() == .landscapeLeft)
        #expect(!sut.isLocked)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
    }

    @Test func phoneRejectsUpsideDownButPadAcceptsIt() {
        var phone = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        phone.record(deviceOrientation: .portraitUpsideDown)
        #expect(phone.latestRequestedInterfaceOrientation == nil)

        var pad = OrientationLockState(normalMask: .all)
        pad.record(deviceOrientation: .portraitUpsideDown)
        #expect(pad.latestRequestedInterfaceOrientation == .portraitUpsideDown)
    }

    @Test func resetClearsLockAndPendingRotation() {
        var sut = OrientationLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock(to: .landscapeRight)
        sut.record(deviceOrientation: .portrait)
        sut.reset()
        #expect(!sut.isLocked)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
        #expect(sut.latestRequestedInterfaceOrientation == nil)
    }
}

@Suite("Player orientation lock scenes", .serialized)
@MainActor
struct OrientationLockSceneTests {
    private let phoneMask: UIInterfaceOrientationMask = [
        .portrait, .landscapeLeft, .landscapeRight
    ]

    @Test func simultaneousPlayerSessionsKeepSceneMasksAndObservationIndependent() {
        let registry = OrientationLockRegistry()
        let firstDevice = DeviceOrientationNotificationsSpy()
        let secondDevice = DeviceOrientationNotificationsSpy()
        let first = OrientationLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: firstDevice,
            notificationCenter: NotificationCenter()
        )
        let second = OrientationLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: secondDevice,
            notificationCenter: NotificationCenter()
        )
        let portraitScene = OrientationLockTestScene(interfaceOrientation: .portrait)
        let landscapeScene = OrientationLockTestScene(interfaceOrientation: .landscapeRight)

        first.beginPlayerSession(in: portraitScene)
        first.toggle()
        second.beginPlayerSession(in: landscapeScene)
        second.toggle()

        #expect(registry.supportedOrientations(for: portraitScene, default: phoneMask) == .portrait)
        #expect(registry.supportedOrientations(for: landscapeScene, default: phoneMask) == .landscapeRight)
        #expect(first.isLocked)
        #expect(second.isLocked)

        first.endPlayerSession()

        #expect(registry.supportedOrientations(for: portraitScene, default: phoneMask) == phoneMask)
        #expect(registry.supportedOrientations(for: landscapeScene, default: phoneMask) == .landscapeRight)
        #expect(!first.isLocked)
        #expect(second.isLocked)
        #expect(firstDevice.endCount == 1)
        #expect(secondDevice.endCount == 0)
    }

    @Test func sceneHandoffUnlocksOnlyTheOldSceneAndThenTargetsTheExactNewScene() {
        let registry = OrientationLockRegistry()
        let device = DeviceOrientationNotificationsSpy()
        let sut = OrientationLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: device,
            notificationCenter: NotificationCenter()
        )
        let firstScene = OrientationLockTestScene(interfaceOrientation: .portrait)
        let secondScene = OrientationLockTestScene(interfaceOrientation: .landscapeLeft)

        sut.beginPlayerSession(in: firstScene)
        sut.toggle()
        sut.beginPlayerSession(in: secondScene)
        sut.toggle()

        #expect(registry.supportedOrientations(for: firstScene, default: phoneMask) == phoneMask)
        #expect(registry.supportedOrientations(for: secondScene, default: phoneMask) == .landscapeLeft)
        #expect(firstScene.applications.count == 2)
        #expect(firstScene.applications.last?.0 == phoneMask)
        #expect(secondScene.applications.count == 1)
        #expect(secondScene.applications.last?.0 == .landscapeLeft)
        #expect(device.beginCount == 2)
        #expect(device.endCount == 1)
    }

    @Test func staleOwnerCannotUnregisterTheCurrentSceneSession() {
        let registry = OrientationLockRegistry()
        let scene = OrientationLockTestScene(interfaceOrientation: .portrait)
        let oldOwner = NSObject()
        let currentOwner = NSObject()

        registry.register(owner: oldOwner, scene: scene, supportedOrientations: .portrait)
        registry.register(owner: currentOwner, scene: scene, supportedOrientations: .landscapeRight)
        registry.unregister(owner: oldOwner, scene: scene)

        #expect(registry.supportedOrientations(for: scene, default: phoneMask) == .landscapeRight)
    }

    @Test func replacingALockedOwnerInTheSameSceneAppliesTheNewNormalMaskOnce() {
        let registry = OrientationLockRegistry()
        let scene = OrientationLockTestScene(interfaceOrientation: .portrait)
        let first = OrientationLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: DeviceOrientationNotificationsSpy(),
            notificationCenter: NotificationCenter()
        )
        let second = OrientationLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: DeviceOrientationNotificationsSpy(),
            notificationCenter: NotificationCenter()
        )

        first.beginPlayerSession(in: scene)
        first.toggle()
        second.beginPlayerSession(in: scene)

        #expect(scene.applications.count == 2)
        #expect(scene.applications.last?.0 == phoneMask)
        #expect(scene.applications.last?.1 == nil)

        first.endPlayerSession()

        #expect(scene.applications.count == 2)
        #expect(registry.supportedOrientations(for: scene, default: phoneMask) == phoneMask)
    }

    @Test func endingAfterTheSceneDisappearsStillResetsAndUnregistersTheSession() {
        let registry = OrientationLockRegistry()
        let device = DeviceOrientationNotificationsSpy()
        let identifierOwner = NSObject()
        let sut = OrientationLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: device,
            notificationCenter: NotificationCenter()
        )
        var scene: OrientationLockTestScene? = OrientationLockTestScene(
            interfaceOrientation: .portrait,
            identifierOwner: identifierOwner
        )

        sut.beginPlayerSession(in: scene!)
        sut.toggle()
        scene = nil
        sut.endPlayerSession()

        let sceneProbe = OrientationLockTestScene(
            interfaceOrientation: .portrait,
            identifierOwner: identifierOwner
        )
        #expect(!sut.isLocked)
        #expect(sut.supportedOrientations == phoneMask)
        #expect(registry.supportedOrientations(for: sceneProbe, default: phoneMask) == phoneMask)
        #expect(device.endCount == 1)
    }

    @Test func deallocationBalancesAnOwnedNotificationSession() {
        let registry = OrientationLockRegistry()
        let device = DeviceOrientationNotificationsSpy()
        let notificationCenter = NotificationCenter()
        let scene = OrientationLockTestScene(interfaceOrientation: .portrait)
        var sut: OrientationLockCoordinator? = OrientationLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: device,
            notificationCenter: notificationCenter
        )

        sut?.beginPlayerSession(in: scene)
        weak let weakSUT = sut
        sut = nil

        #expect(weakSUT == nil)
        #expect(device.beginCount == 1)
        #expect(device.endCount == 1)
    }

    @Test func appDelegateUsesTheSceneBelongingToTheSuppliedWindow() throws {
        let scene = try #require(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        )
        let owner = NSObject()
        OrientationLockRegistry.shared.register(
            owner: owner,
            scene: scene,
            supportedOrientations: .landscapeLeft
        )
        defer { OrientationLockRegistry.shared.unregister(owner: owner, scene: scene) }
        let window = UIWindow(windowScene: scene)

        let result = AppDelegate().application(
            UIApplication.shared,
            supportedInterfaceOrientationsFor: window
        )

        #expect(result == .landscapeLeft)
    }

    @Test func notificationGenerationEndsExactlyOnceOnlyAfterThisCoordinatorBeginsIt() {
        let device = DeviceOrientationNotificationsSpy()
        let sut = OrientationLockCoordinator(
            normalMask: phoneMask,
            registry: OrientationLockRegistry(),
            deviceOrientationNotifications: device,
            notificationCenter: NotificationCenter()
        )
        let scene = OrientationLockTestScene(interfaceOrientation: .portrait)

        sut.endPlayerSession()
        #expect(device.beginCount == 0)
        #expect(device.endCount == 0)

        sut.beginPlayerSession(in: scene)
        sut.beginPlayerSession(in: scene)
        sut.endPlayerSession()
        sut.endPlayerSession()

        #expect(device.beginCount == 1)
        #expect(device.endCount == 1)
    }
}
