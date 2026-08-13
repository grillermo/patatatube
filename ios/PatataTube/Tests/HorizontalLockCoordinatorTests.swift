import Testing
import UIKit
@testable import PatataTube

@MainActor
private final class HorizontalLockTestScene: HorizontalLockScene {
    var interfaceOrientationForLock: UIInterfaceOrientation
    private(set) var applications: [(UIInterfaceOrientationMask, UIInterfaceOrientation?)] = []
    private let customIdentifier: ObjectIdentifier?

    var horizontalLockIdentifier: ObjectIdentifier {
        customIdentifier ?? ObjectIdentifier(self)
    }

    init(interfaceOrientation: UIInterfaceOrientation, identifierOwner: AnyObject? = nil) {
        self.interfaceOrientationForLock = interfaceOrientation
        customIdentifier = identifierOwner.map(ObjectIdentifier.init)
    }

    func applySupportedOrientations(
        _ supportedOrientations: UIInterfaceOrientationMask,
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
struct HorizontalLockCoordinatorTests {
    @Test func phoneStartsUnlockedWithItsConfiguredMask() {
        let sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        #expect(!sut.isHorizontal)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
    }

    @Test func faceUpFaceDownAndUnknownReadingsAreIgnored() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .landscapeRight)
        sut.record(deviceOrientation: .faceUp)
        sut.record(deviceOrientation: .faceDown)
        sut.record(deviceOrientation: .unknown)
        #expect(sut.latestRequestedInterfaceOrientation == .landscapeLeft)
    }

    @Test func phoneRejectsUpsideDownButPadAcceptsIt() {
        var phone = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        phone.record(deviceOrientation: .portraitUpsideDown)
        #expect(phone.latestRequestedInterfaceOrientation == nil)

        var pad = HorizontalLockState(normalMask: .all)
        pad.record(deviceOrientation: .portraitUpsideDown)
        #expect(pad.latestRequestedInterfaceOrientation == .portraitUpsideDown)
    }

    @Test func resetClearsLockAndPendingRotation() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock()
        sut.record(deviceOrientation: .portrait)
        sut.reset()
        #expect(!sut.isHorizontal)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
        #expect(sut.latestRequestedInterfaceOrientation == nil)
    }

    @Test func lockingWithoutAnySeenLandscapeDefaultsToLandscapeRight() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .portrait)
        let requested = sut.lock()
        #expect(requested == .landscapeRight)
        #expect(sut.isHorizontal)
        #expect(sut.supportedMask == [.landscapeLeft, .landscapeRight])
    }

    @Test func lockingFromPortraitRequestsTheLastSeenLandscape() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .landscapeRight)   // interface .landscapeLeft
        sut.record(deviceOrientation: .portrait)
        #expect(sut.lock() == .landscapeLeft)
        #expect(sut.supportedMask == [.landscapeLeft, .landscapeRight])
    }

    @Test func seededInterfaceOrientationCountsAsASeenLandscape() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(interfaceOrientation: .landscapeRight)
        #expect(sut.lock() == .landscapeRight)
    }

    @Test func unknownSeededInterfaceOrientationIsIgnored() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(interfaceOrientation: .unknown)
        #expect(sut.lock() == .landscapeRight)   // default, not remembered as .unknown
    }

    @Test func bothLandscapesStaySupportedSoAOneEightyFlipStillRotates() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock()
        sut.record(deviceOrientation: .landscapeLeft)
        #expect(sut.supportedMask == [.landscapeLeft, .landscapeRight])
        #expect(sut.isHorizontal)
    }

    @Test func portraitRotationsWhileLockedAreStillRecordedForTheUnlockRestore() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        _ = sut.lock()
        sut.record(deviceOrientation: .portrait)
        #expect(sut.supportedMask == [.landscapeLeft, .landscapeRight])
        #expect(sut.unlock() == .portrait)
        #expect(!sut.isHorizontal)
        #expect(sut.supportedMask == [.portrait, .landscapeLeft, .landscapeRight])
    }

    @Test func aPortraitOnlyMaskCannotGoHorizontal() {
        var sut = HorizontalLockState(normalMask: .portrait)
        #expect(sut.lock() == nil)
        #expect(!sut.isHorizontal)
        #expect(sut.supportedMask == .portrait)
    }

    @Test func resetClearsTheRememberedLandscape() {
        var sut = HorizontalLockState(normalMask: [.portrait, .landscapeLeft, .landscapeRight])
        sut.record(deviceOrientation: .landscapeRight)
        sut.reset()
        #expect(sut.lock() == .landscapeRight)   // back to the default, not .landscapeLeft
    }
}

@Suite("Player orientation lock scenes", .serialized)
@MainActor
struct HorizontalLockSceneTests {
    private let phoneMask: UIInterfaceOrientationMask = [
        .portrait, .landscapeLeft, .landscapeRight
    ]
    private let landscapeMask: UIInterfaceOrientationMask = [.landscapeLeft, .landscapeRight]

    @Test func simultaneousPlayerSessionsKeepSceneMasksAndObservationIndependent() {
        let registry = HorizontalLockRegistry()
        let firstDevice = DeviceOrientationNotificationsSpy()
        let secondDevice = DeviceOrientationNotificationsSpy()
        let first = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: firstDevice,
            notificationCenter: NotificationCenter()
        )
        let second = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: secondDevice,
            notificationCenter: NotificationCenter()
        )
        let portraitScene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        let landscapeScene = HorizontalLockTestScene(interfaceOrientation: .landscapeRight)

        first.beginPlayerSession(in: portraitScene)
        first.toggle()
        second.beginPlayerSession(in: landscapeScene)
        second.toggle()

        #expect(registry.supportedOrientations(for: portraitScene, default: phoneMask) == landscapeMask)
        #expect(registry.supportedOrientations(for: landscapeScene, default: phoneMask) == landscapeMask)
        #expect(first.isHorizontal)
        #expect(second.isHorizontal)

        first.endPlayerSession()

        #expect(registry.supportedOrientations(for: portraitScene, default: phoneMask) == phoneMask)
        #expect(registry.supportedOrientations(for: landscapeScene, default: phoneMask) == landscapeMask)
        #expect(!first.isHorizontal)
        #expect(second.isHorizontal)
        #expect(firstDevice.endCount == 1)
        #expect(secondDevice.endCount == 0)
    }

    /// A portrait phone has no seen landscape, so it takes the default; a scene
    /// that is already landscape seeds the memory and keeps that side.
    @Test func lockTargetComesFromTheSceneWhenTheDeviceHasNeverBeenLandscape() {
        let registry = HorizontalLockRegistry()
        let portraitCoordinator = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: DeviceOrientationNotificationsSpy(orientation: .portrait),
            notificationCenter: NotificationCenter()
        )
        let landscapeCoordinator = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: DeviceOrientationNotificationsSpy(orientation: .faceUp),
            notificationCenter: NotificationCenter()
        )
        let portraitScene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        let landscapeScene = HorizontalLockTestScene(interfaceOrientation: .landscapeLeft)

        portraitCoordinator.beginPlayerSession(in: portraitScene)
        portraitCoordinator.toggle()
        landscapeCoordinator.beginPlayerSession(in: landscapeScene)
        landscapeCoordinator.toggle()

        #expect(portraitScene.applications.last?.1 == .landscapeRight)
        #expect(landscapeScene.applications.last?.1 == .landscapeLeft)
    }

    @Test func sceneHandoffUnlocksOnlyTheOldSceneAndThenTargetsTheExactNewScene() {
        let registry = HorizontalLockRegistry()
        let device = DeviceOrientationNotificationsSpy()
        let sut = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: device,
            notificationCenter: NotificationCenter()
        )
        let firstScene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        let secondScene = HorizontalLockTestScene(interfaceOrientation: .landscapeLeft)

        sut.beginPlayerSession(in: firstScene)
        sut.toggle()
        sut.beginPlayerSession(in: secondScene)
        sut.toggle()

        #expect(registry.supportedOrientations(for: firstScene, default: phoneMask) == phoneMask)
        #expect(registry.supportedOrientations(for: secondScene, default: phoneMask) == landscapeMask)
        #expect(firstScene.applications.count == 2)
        #expect(firstScene.applications.last?.0 == phoneMask)
        #expect(secondScene.applications.count == 1)
        #expect(secondScene.applications.last?.0 == landscapeMask)
        #expect(secondScene.applications.last?.1 == .landscapeLeft)
        #expect(device.beginCount == 2)
        #expect(device.endCount == 1)
    }

    @Test func staleOwnerCannotUnregisterTheCurrentSceneSession() {
        let registry = HorizontalLockRegistry()
        let scene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        let oldOwner = NSObject()
        let currentOwner = NSObject()

        registry.register(owner: oldOwner, scene: scene, supportedOrientations: .portrait)
        registry.register(owner: currentOwner, scene: scene, supportedOrientations: .landscapeRight)
        registry.unregister(owner: oldOwner, scene: scene)

        #expect(registry.supportedOrientations(for: scene, default: phoneMask) == .landscapeRight)
    }

    @Test func replacingALockedOwnerInTheSameSceneAppliesTheNewNormalMaskOnce() {
        let registry = HorizontalLockRegistry()
        let scene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        let first = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: DeviceOrientationNotificationsSpy(),
            notificationCenter: NotificationCenter()
        )
        let second = HorizontalLockCoordinator(
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
        let registry = HorizontalLockRegistry()
        let device = DeviceOrientationNotificationsSpy()
        let identifierOwner = NSObject()
        let sut = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: registry,
            deviceOrientationNotifications: device,
            notificationCenter: NotificationCenter()
        )
        var scene: HorizontalLockTestScene? = HorizontalLockTestScene(
            interfaceOrientation: .portrait,
            identifierOwner: identifierOwner
        )

        sut.beginPlayerSession(in: scene!)
        sut.toggle()
        scene = nil
        sut.endPlayerSession()

        let sceneProbe = HorizontalLockTestScene(
            interfaceOrientation: .portrait,
            identifierOwner: identifierOwner
        )
        #expect(!sut.isHorizontal)
        #expect(sut.supportedOrientations == phoneMask)
        #expect(registry.supportedOrientations(for: sceneProbe, default: phoneMask) == phoneMask)
        #expect(device.endCount == 1)
    }

    @Test func deallocationBalancesAnOwnedNotificationSession() {
        let registry = HorizontalLockRegistry()
        let device = DeviceOrientationNotificationsSpy()
        let notificationCenter = NotificationCenter()
        let scene = HorizontalLockTestScene(interfaceOrientation: .portrait)
        var sut: HorizontalLockCoordinator? = HorizontalLockCoordinator(
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
        HorizontalLockRegistry.shared.register(
            owner: owner,
            scene: scene,
            supportedOrientations: .landscapeLeft
        )
        defer { HorizontalLockRegistry.shared.unregister(owner: owner, scene: scene) }
        let window = UIWindow(windowScene: scene)

        let result = AppDelegate().application(
            UIApplication.shared,
            supportedInterfaceOrientationsFor: window
        )

        #expect(result == .landscapeLeft)
    }

    @Test func notificationGenerationEndsExactlyOnceOnlyAfterThisCoordinatorBeginsIt() {
        let device = DeviceOrientationNotificationsSpy()
        let sut = HorizontalLockCoordinator(
            normalMask: phoneMask,
            registry: HorizontalLockRegistry(),
            deviceOrientationNotifications: device,
            notificationCenter: NotificationCenter()
        )
        let scene = HorizontalLockTestScene(interfaceOrientation: .portrait)

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
