import Testing
import UIKit
@testable import PatataTube

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
