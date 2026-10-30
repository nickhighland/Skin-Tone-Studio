import XCTest
@testable import SkinToneCore

final class CaptureLifecycleTests: XCTestCase {
    private final class Rig {
        var time = 100.0
        var starts: [String] = []
        var stops = 0
        var ready = 0
        var startError: Error?
        lazy var lifecycle = CaptureLifecycle(
            now: { [unowned self] in time },
            start: { [unowned self] id in
                starts.append(id)
                if let startError { throw startError }
            },
            stop: { [unowned self] in stops += 1 },
            stateChanged: { _ in },
            streamStarted: { [unowned self] in ready += 1 }
        )

        func open() {
            lifecycle.select(deviceID: "usb", inUseByAnotherApp: false)
            lifecycle.setVisible(true)
            advance(1)
        }

        func advance(_ seconds: Double) {
            time += seconds
            lifecycle.tick()
        }
    }

    func testHiddenAppDoesNotOpenVideoStream() {
        let rig = Rig()
        rig.lifecycle.select(deviceID: "usb", inUseByAnotherApp: false)
        rig.advance(20)
        XCTAssertEqual(rig.lifecycle.state, .paused)
        XCTAssertTrue(rig.starts.isEmpty)
    }

    func testReadyRequiresAUsableFrameNotJustStartRunning() {
        let rig = Rig()
        rig.open()
        XCTAssertEqual(rig.starts, ["usb"])
        XCTAssertEqual(rig.lifecycle.state, .starting)
        XCTAssertEqual(rig.ready, 0)
        rig.lifecycle.receivedFrame()
        XCTAssertEqual(rig.lifecycle.state, .running)
        XCTAssertEqual(rig.ready, 1)
    }

    func testHideReleasesCaptureAndShowStartsFreshSession() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.receivedFrame()
        rig.lifecycle.setVisible(false)
        XCTAssertEqual(rig.stops, 1)
        XCTAssertFalse(rig.lifecycle.isCapturing)
        rig.advance(30)
        XCTAssertEqual(rig.starts.count, 1)
        rig.lifecycle.setVisible(true)
        rig.advance(1)
        XCTAssertEqual(rig.starts.count, 2)
        XCTAssertEqual(rig.lifecycle.state, .starting)
    }

    func testBrowserTakesPriorityEvenWithWindowVisible() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.receivedFrame()
        rig.lifecycle.setOtherAppUsingCamera(true)
        XCTAssertEqual(rig.lifecycle.state, .inUseByAnotherApp)
        XCTAssertEqual(rig.stops, 1)
        rig.advance(90)
        rig.lifecycle.retry()
        rig.advance(90)
        XCTAssertEqual(rig.starts.count, 1, "Retry must never steal the camera from a browser")
    }

    func testGapBetweenBrowsersDoesNotReacquireCamera() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.setOtherAppUsingCamera(true)
        rig.lifecycle.setOtherAppUsingCamera(false)
        rig.advance(1)
        XCTAssertEqual(rig.starts.count, 1)
        rig.lifecycle.setOtherAppUsingCamera(true)
        rig.advance(20)
        XCTAssertEqual(rig.starts.count, 1)
        rig.lifecycle.setOtherAppUsingCamera(false)
        rig.advance(3)
        XCTAssertEqual(rig.starts.count, 2)
    }

    func testNoFirstFrameTriggersRecoveryInsteadOfFalseReady() {
        let rig = Rig()
        rig.open()
        rig.advance(9)
        XCTAssertEqual(rig.lifecycle.state, .recovering)
        XCTAssertEqual(rig.stops, 1)
        XCTAssertEqual(rig.ready, 0)
        rig.advance(3)
        XCTAssertEqual(rig.starts.count, 2)
        rig.lifecycle.receivedFrame()
        XCTAssertEqual(rig.ready, 1)
    }

    func testLostFramesRebuildCaptureWithBackoff() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.receivedFrame()
        rig.advance(5)
        XCTAssertEqual(rig.lifecycle.state, .recovering)
        rig.advance(1)
        XCTAssertEqual(rig.starts.count, 1)
        rig.advance(2)
        XCTAssertEqual(rig.starts.count, 2)
    }

    func testRuntimeErrorReleasesBrokenSessionAndRetries() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.receivedFrame()
        rig.lifecycle.failed("Media services reset")
        XCTAssertFalse(rig.lifecycle.isCapturing)
        XCTAssertEqual(rig.stops, 1)
        rig.advance(3)
        XCTAssertEqual(rig.starts.count, 2)
        rig.lifecycle.receivedFrame()
        XCTAssertEqual(rig.lifecycle.state, .running)
    }

    func testFailedStartDoesNotSpinOrReportRunning() {
        let rig = Rig()
        rig.startError = NSError(domain: "test", code: 1)
        rig.open()
        XCTAssertEqual(rig.lifecycle.state, .recovering)
        for _ in 0..<20 { rig.lifecycle.tick() }
        XCTAssertEqual(rig.starts.count, 1)
        XCTAssertEqual(rig.ready, 0)
    }

    func testSleepReleasesCaptureAndWakeRespectsBrowserOwnership() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.setSuspended(true)
        XCTAssertEqual(rig.stops, 1)
        rig.advance(60)
        rig.lifecycle.setOtherAppUsingCamera(true)
        rig.lifecycle.setSuspended(false)
        rig.advance(10)
        XCTAssertEqual(rig.lifecycle.state, .inUseByAnotherApp)
        XCTAssertEqual(rig.starts.count, 1)
    }

    func testUnplugCancelsPendingRetryAndOldFramesCannotMarkReady() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.failed("Disconnected")
        rig.lifecycle.select(deviceID: nil, inUseByAnotherApp: false)
        rig.lifecycle.receivedFrame()
        rig.advance(60)
        XCTAssertEqual(rig.lifecycle.state, .idle)
        XCTAssertEqual(rig.ready, 0)
        XCTAssertEqual(rig.starts.count, 1)
        rig.lifecycle.select(deviceID: "usb", inUseByAnotherApp: false)
        rig.advance(1)
        XCTAssertEqual(rig.starts.count, 2)
    }

    func testSwitchingCameraReleasesOldInput() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.select(deviceID: "second", inUseByAnotherApp: false)
        rig.advance(1)
        XCTAssertEqual(rig.starts, ["usb", "second"])
        XCTAssertEqual(rig.stops, 1)
    }

    func testUnrelatedCameraNotificationsDoNotReconnectSelectedWebcam() {
        XCTAssertFalse(CameraSelectionPolicy.needsConnection(
            selectedID: "usb", connectedIDs: ["phone", "usb", "built-in"], activeID: "usb"))
        XCTAssertFalse(CameraSelectionPolicy.needsConnection(
            selectedID: "usb", connectedIDs: ["usb"], activeID: "usb"))
        XCTAssertFalse(CameraSelectionPolicy.needsConnection(
            selectedID: "usb", connectedIDs: ["phone"], activeID: nil))
        XCTAssertTrue(CameraSelectionPolicy.needsConnection(
            selectedID: "usb", connectedIDs: ["phone", "usb"], activeID: nil))
    }

    func testCoreMediaIOFallbackDoesNotMistakeOurStreamForAnotherApp() {
        XCTAssertFalse(CameraUsageMonitor.anotherAppIsUsingCamera(
            reportedByAVFoundation: false, ourCaptureIsActive: true, runningSomewhere: true))
        XCTAssertTrue(CameraUsageMonitor.anotherAppIsUsingCamera(
            reportedByAVFoundation: false, ourCaptureIsActive: false, runningSomewhere: true))
        XCTAssertFalse(CameraUsageMonitor.anotherAppIsUsingCamera(
            reportedByAVFoundation: false, ourCaptureIsActive: false, runningSomewhere: nil))
    }

    func testStallYieldsToRemainingConsumerInsteadOfReopeningItsStream() {
        let rig = Rig()
        rig.open()
        rig.lifecycle.receivedFrame()
        rig.advance(5)
        rig.lifecycle.setOtherAppUsingCamera(CameraUsageMonitor.anotherAppIsUsingCamera(
            reportedByAVFoundation: false, ourCaptureIsActive: rig.lifecycle.isCapturing,
            runningSomewhere: true))
        rig.advance(30)
        XCTAssertEqual(rig.lifecycle.state, .inUseByAnotherApp)
        XCTAssertEqual(rig.starts.count, 1)
        rig.lifecycle.setOtherAppUsingCamera(false)
        rig.advance(3)
        XCTAssertEqual(rig.starts.count, 2)
    }
}
