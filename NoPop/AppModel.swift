import AppKit
import Combine
import ServiceManagement

struct RunPolicy {
  static func shouldRun(
    enabled: Bool, pauseOnBattery: Bool, onBattery: Bool, sleeping: Bool, hasOutput: Bool
  ) -> Bool {
    enabled && !sleeping && hasOutput && !(pauseOnBattery && onBattery)
  }
}

struct PlaybackConfiguration: Equatable {
  let outputID: UInt32
  let level: Double
}

@MainActor
final class AppModel: ObservableObject {
  @Published var enabled: Bool {
    didSet {
      defaults.set(enabled, forKey: "enabled")
      reconcile()
    }
  }
  @Published var pauseOnBattery: Bool {
    didSet {
      defaults.set(pauseOnBattery, forKey: "pauseOnBattery")
      reconcile()
    }
  }
  @Published var level: Double {
    didSet {
      let safe = NoiseSignal.sanitizedLevel(level)
      if safe != level { level = safe }
      defaults.set(safe, forKey: "signalLevel")
      reconcile()
    }
  }
  @Published private(set) var isRunning = false
  @Published private(set) var outputName = "No audio output"
  @Published private(set) var detail = "Ready when you are"
  @Published private(set) var loginEnabled = false
  @Published private(set) var loginNeedsApproval = false
  @Published private(set) var loginError: String?
  private let defaults: UserDefaults
  private let audio: any AudioPlayback
  private let monitor: any SystemMonitoring
  private var restart: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var shuttingDown = false
  private var activeConfiguration: PlaybackConfiguration?

  init(
    defaults: UserDefaults = .standard,
    audio: (any AudioPlayback)? = nil,
    monitor: (any SystemMonitoring)? = nil
  ) {
    self.defaults = defaults
    self.audio = audio ?? KeepAliveAudio()
    self.monitor = monitor ?? SystemMonitor()
    defaults.register(defaults: ["enabled": false, "pauseOnBattery": true, "signalLevel": -90.0])
    enabled = defaults.bool(forKey: "enabled")
    pauseOnBattery = defaults.bool(forKey: "pauseOnBattery")
    level = NoiseSignal.sanitizedLevel(defaults.double(forKey: "signalLevel"))
    self.monitor.onChange = { [weak self] in self?.reconcile() }
    self.audio.onConfigurationChange = { [weak self] in self?.reconcile(forceRestart: true) }
    self.monitor.start()
    refreshLoginStatus()
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshLoginStatus() }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.shutdown() }
      })
  }

  func reconcile(forceRestart: Bool = false) {
    guard !shuttingDown else { return }
    outputName = monitor.outputName
    guard
      RunPolicy.shouldRun(
        enabled: enabled, pauseOnBattery: pauseOnBattery, onBattery: monitor.onBattery,
        sleeping: monitor.isSleeping, hasOutput: monitor.hasOutput)
    else {
      restart?.cancel()
      audio.stop()
      activeConfiguration = nil
      isRunning = false
      if !enabled {
        detail = "Ready when you are"
      } else if monitor.isSleeping {
        detail = "Paused while Mac sleeps"
      } else if pauseOnBattery && monitor.onBattery {
        detail = "Paused on battery power"
      } else {
        detail = "Waiting for an audio output"
      }
      return
    }
    let configuration = PlaybackConfiguration(outputID: monitor.deviceID, level: level)
    if !forceRestart, activeConfiguration == configuration, audio.isRunning {
      return
    }
    restart?.cancel()
    audio.stop()
    activeConfiguration = nil
    isRunning = false
    detail = "Starting audio stream…"
    restart = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      guard let self, !Task.isCancelled, !self.shuttingDown else { return }
      do {
        try self.audio.start(level: self.level)
        self.activeConfiguration = configuration
        self.isRunning = self.audio.isRunning
        self.detail = "Keep-alive stream is active"
      } catch {
        self.audio.stop()
        self.isRunning = false
        self.detail = "Audio unavailable. Turn off and on to retry."
      }
    }
  }

  func setLoginEnabled(_ enabled: Bool) {
    loginError = nil
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      loginError = "Could not update login settings. Move NoPop to Applications and try again."
    }
    refreshLoginStatus()
  }

  func refreshLoginStatus() {
    let status = SMAppService.mainApp.status
    loginEnabled = status == .enabled || status == .requiresApproval
    loginNeedsApproval = status == .requiresApproval
  }

  func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

  func shutdown() {
    shuttingDown = true
    restart?.cancel()
    audio.stop()
    monitor.stop()
    activeConfiguration = nil
    isRunning = false
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
  }
}
