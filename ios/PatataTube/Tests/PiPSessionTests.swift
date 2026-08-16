import AVKit
import Testing
import UIKit
@testable import PatataTube

/// AVKit has no API to start Picture in Picture, so `PiPSession` fires AVKit's
/// own button — which means finding it in a view hierarchy we don't own. These
/// cover the finder; the hierarchy it runs against is AVKit's and can change,
/// which is why a miss only leaves the player full screen.
@Suite("Picture in Picture button finder")
@MainActor
struct PiPSessionTests {
    @Test func findsAButtonNestedAnywhereUnderTheRoot() {
        let root = UIView()
        let branch = UIView()
        let decoy = UIButton()
        let target = UIButton()
        target.accessibilityIdentifier = "PictureInPictureButton"
        root.addSubview(decoy)
        root.addSubview(branch)
        branch.addSubview(UIView())
        branch.addSubview(target)

        #expect(PiPSession.pictureInPictureButton(in: root) === target)
    }

    @Test func returnsNilWhenNothingMatches() {
        let root = UIView()
        root.addSubview(UIButton())
        root.addSubview(UIView())

        #expect(PiPSession.pictureInPictureButton(in: root) == nil)
    }

    @Test func matchesOnAccessibilityLabelOrTheDocumentedStartImage() {
        let labelled = UIButton()
        labelled.accessibilityLabel = "Picture in Picture"
        #expect(PiPSession.isPictureInPictureButton(labelled))

        let imaged = UIButton()
        imaged.setImage(AVPictureInPictureController.pictureInPictureButtonStartImage, for: .normal)
        #expect(PiPSession.isPictureInPictureButton(imaged))

        let plain = UIButton()
        plain.accessibilityLabel = "Play"
        plain.setImage(UIImage(systemName: "play.fill"), for: .normal)
        #expect(!PiPSession.isPictureInPictureButton(plain))
    }

    @Test func startIsARefusalWhenNoControllerHasRegistered() {
        let sut = PiPSession()
        let started = sut.start(
            player: AVPlayer(), positionObserver: nil, videos: [], index: 0,
            sleepMode: false, scope: nil, randomize: false, onStart: {}
        )

        #expect(!started)
        #expect(!sut.isActive)
    }
}
