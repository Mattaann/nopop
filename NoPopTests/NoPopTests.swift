import AVFoundation
import XCTest

@testable import NoPop

final class NoPopTests: XCTestCase {
  @MainActor
  func testOfflineAudioGraphIsBoundedAndNonSilent() throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
    let mono = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let engine = AVAudioEngine()
    let source = KeepAliveAudio.makeSource(format: mono, level: 1000)
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: mono)
    engine.mainMixerNode.outputVolume = 1
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    try engine.start()
    defer { engine.stop() }
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    var nonzero = 0
    for _ in 0..<40 {
      let status = try engine.renderOffline(1024, to: buffer)
      XCTAssertEqual(status, .success)
      let channels = try XCTUnwrap(buffer.floatChannelData)
      for channel in 0..<Int(format.channelCount) {
        for frame in 0..<Int(buffer.frameLength) {
          let sample = channels[channel][frame]
          XCTAssertTrue(sample.isFinite)
          XCTAssertLessThanOrEqual(abs(sample), NoiseSignal.maximumPeak)
          if sample != 0 { nonzero += 1 }
        }
      }
    }
    XCTAssertGreaterThan(nonzero, 0)
  }

  func testSignalCannotExceedSafetyLimit() {
    for level in [-Double.infinity, Double.infinity, Double.nan, -1000, 0, 1000, -102, -96, -90] {
      let values = NoiseSignal.samples(level: level)
      XCTAssertTrue(values.allSatisfy { $0.isFinite && abs($0) <= NoiseSignal.maximumPeak })
      XCTAssertTrue(values.contains { $0 != 0 })
      XCTAssertEqual(values.reduce(0.0) { $0 + Double($1) }, 0, accuracy: 1e-12)
    }
  }

  func testSelectedPeakAndSignalEnergy() {
    for level in NoiseSignal.levels {
      let samples = NoiseSignal.samples(level: level)
      let peak = Double(samples.map(abs).max()!)
      XCTAssertEqual(20 * log10(peak), level, accuracy: 0.1)
      let rms = sqrt(samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count))
      XCTAssertEqual(20 * log10(rms), level - 4.77, accuracy: 0.15)
    }
  }

  func testRendererWrapsWithoutUnsafeSamples() {
    let renderer = NoiseRenderer(level: 100)
    let first = renderer.next()
    for _ in 1..<32_768 { XCTAssertLessThanOrEqual(abs(renderer.next()), NoiseSignal.maximumPeak) }
    XCTAssertEqual(renderer.next(), first)
  }

  @MainActor
  func testNotificationsPreserveStreamUntilPlaybackNeedsChange() async throws {
    let suite = "NoPopTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let audio = TestAudio()
    let monitor = TestMonitor()
    let model = AppModel(defaults: defaults, audio: audio, monitor: monitor)
    defer {
      model.shutdown()
      defaults.removePersistentDomain(forName: suite)
    }
    model.enabled = true
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(model.isRunning)
    XCTAssertEqual(audio.starts, 1)

    monitor.outputName = "Renamed output"
    monitor.onChange?()
    monitor.onChange?()
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(model.outputName, "Renamed output")
    XCTAssertTrue(model.isRunning)
    XCTAssertEqual(audio.starts, 1)

    monitor.deviceID = 2
    monitor.onChange?()
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertEqual(audio.starts, 2)

    monitor.onBattery = true
    monitor.onChange?()
    XCTAssertFalse(model.isRunning)
    XCTAssertFalse(audio.isRunning)
    XCTAssertTrue(model.enabled)
    XCTAssertEqual(model.detail, "Paused on battery power")
  }

  @MainActor
  func testTurningOffCancelsPendingStartup() async throws {
    let suite = "NoPopTests." + UUID().uuidString
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    let audio = TestAudio()
    let model = AppModel(defaults: defaults, audio: audio, monitor: TestMonitor())
    defer {
      model.shutdown()
      defaults.removePersistentDomain(forName: suite)
    }
    model.enabled = true
    model.enabled = false
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertFalse(model.isRunning)
    XCTAssertEqual(audio.starts, 0)
  }

  func testRunPolicyAcrossAllStates() {
    for mask in 0..<32 {
      let enabled = mask & 1 != 0
      let pause = mask & 2 != 0
      let battery = mask & 4 != 0
      let sleeping = mask & 8 != 0
      let output = mask & 16 != 0
      let actual = RunPolicy.shouldRun(
        enabled: enabled, pauseOnBattery: pause, onBattery: battery, sleeping: sleeping,
        hasOutput: output)
      if !enabled || sleeping || !output || (pause && battery) {
        XCTAssertFalse(actual)
      } else {
        XCTAssertTrue(actual)
      }
    }
  }
}

@MainActor
private final class TestAudio: AudioPlayback {
  var onConfigurationChange: (() -> Void)?
  var isRunning = false
  var starts = 0

  func start(level: Double) throws {
    starts += 1
    isRunning = true
  }

  func stop() { isRunning = false }
}

@MainActor
private final class TestMonitor: SystemMonitoring {
  var onChange: (() -> Void)?
  var deviceID: UInt32 = 1
  var isSleeping = false
  var onBattery = false
  var outputName = "Built-in Speakers"
  var hasOutput = true

  func start() { onChange?() }
  func stop() {}
}
