import AVFoundation
import UIKit

/// Estimates room brightness from time to time with the front camera (iOS has no
/// public ambient light sensor API) and maps it to a level from 0 (dark room) to
/// 1 (bright room). The level drives the screen brightness and the palette.
///
/// Each sample runs the camera without preview for about a second so auto-exposure
/// can settle, reads the exposure the camera chose (duration, ISO, aperture) and
/// stops again. No frames are read or kept.
///
/// Only AVCaptureDevice properties are used: CoreMedia attachment functions as
/// linked by the current SDK don't exist on iOS 12 and crash the app.
final class AmbientLight {
    static let shared = AmbientLight()
    /// Posted after each reading or failure (for the Settings page).
    static let didUpdate = Notification.Name("AmbientLightDidUpdate")

    /// 0 = dark room ... 1 = bright room; 1 while monitoring is off.
    private(set) var level: CGFloat = 1
    private(set) var lastLux: Double?
    private(set) var lastReading: Date?
    private(set) var unavailableReason: String?

    // Lux range mapped onto 0...1 on a log scale: ~3 lux (night light) to ~300 lux (lit room).
    private let darkLux = 3.0
    private let brightLux = 300.0
    private let settleTime: TimeInterval = 1.2

    private let queue = DispatchQueue(label: "AmbientLight")
    // Used on `queue` only.
    private var session: AVCaptureSession?
    private var camera: AVCaptureDevice?
    private var sampling = false
    private var timer: Timer?

    var isOn: Bool { return Settings.ambientInterval > 0 }

    /// (Re)schedules sampling according to the setting; samples once right away.
    func start() {
        timer?.invalidate()
        timer = nil
        guard isOn else {
            apply(level: 1)
            return
        }
        #if DEBUG
        // Simulators have no camera: IPADDASH_LUX=<lux> fakes a reading.
        if let fake = ProcessInfo.processInfo.environment["IPADDASH_LUX"].flatMap(Double.init) {
            record(lux: fake)
            return
        }
        #endif
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: Settings.ambientInterval, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    private func sample() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { self.runSession() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { granted ? self.sample() : self.fail("camera access denied") }
            }
        default:
            fail("camera access denied (Settings > iPadDash)")
        }
    }

    /// Built once, on `queue`, and only started and stopped for each sample.
    private func makeSession() -> (AVCaptureSession, AVCaptureDevice)? {
        if let session = session, let camera = camera { return (session, camera) }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera) else {
            DispatchQueue.main.async { self.fail("no front camera") }
            return nil
        }
        let session = AVCaptureSession()
        session.sessionPreset = .low
        // An output keeps the camera streaming so auto-exposure runs; frames are discarded.
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        guard session.canAddInput(input), session.canAddOutput(output) else {
            DispatchQueue.main.async { self.fail("camera unavailable") }
            return nil
        }
        session.addInput(input)
        session.addOutput(output)
        self.session = session
        self.camera = camera
        return (session, camera)
    }

    private func runSession() {
        guard !sampling, let (session, camera) = makeSession() else { return }
        sampling = true
        session.startRunning()

        queue.asyncAfter(deadline: .now() + settleTime) {
            let exposure = camera.exposureDuration
            let duration = exposure.timescale > 0 ? Double(exposure.value) / Double(exposure.timescale) : 0
            let iso = Double(camera.iso)
            let aperture = Double(camera.lensAperture)
            session.stopRunning()
            self.sampling = false
            DispatchQueue.main.async {
                guard duration > 0, iso > 0, aperture > 0 else { return self.fail("no exposure data") }
                // Exposure value at ISO 100, then illuminance (incident-light constant ~250).
                let ev100 = log2(aperture * aperture / duration) - log2(iso / 100)
                self.record(lux: 2.5 * pow(2, ev100))
            }
        }
    }

    private func record(lux: Double) {
        lastLux = lux
        lastReading = Date()
        unavailableReason = nil
        NotificationCenter.default.post(name: AmbientLight.didUpdate, object: nil)
        let t = (log10(max(lux, 0.01)) - log10(darkLux)) / (log10(brightLux) - log10(darkLux))
        apply(level: CGFloat(min(max(t, 0), 1)))
    }

    private func fail(_ reason: String) {
        unavailableReason = reason
        NotificationCenter.default.post(name: AmbientLight.didUpdate, object: nil)
    }

    private func apply(level newLevel: CGFloat) {
        // Ignore small changes so the screen doesn't flicker between samples.
        let changed = abs(newLevel - level) >= 0.04 || (newLevel == 1) != (level == 1)
        if changed {
            level = newLevel
            NotificationCenter.default.post(name: Theme.didChange, object: nil)
        }
        if isOn {
            UIScreen.main.brightness = 0.1 + 0.8 * level
        }
    }
}
