import AppKit
import CoreAudio
import IOKit.ps

@MainActor
protocol SystemMonitoring: AnyObject {
  var onChange: (() -> Void)? { get set }
  var deviceID: AudioDeviceID { get }
  var isSleeping: Bool { get }
  var onBattery: Bool { get }
  var outputName: String { get }
  var hasOutput: Bool { get }
  func start()
  func stop()
}

@MainActor
final class SystemMonitor: SystemMonitoring {
  var onChange: (() -> Void)?
  private var powerSource: CFRunLoopSource?
  private var outputListener: AudioObjectPropertyListenerBlock?
  private var deviceListener: AudioObjectPropertyListenerBlock?
  private(set) var deviceID = AudioDeviceID(kAudioObjectUnknown)
  private var workspaceObservers: [NSObjectProtocol] = []
  private(set) var isSleeping = false
  private(set) var onBattery = false
  private(set) var outputName = "No audio output"
  private(set) var hasOutput = false

  func start() {
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    outputListener = listener
    var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    AudioObjectAddPropertyListenerBlock(
      AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
    let context = Unmanaged.passUnretained(self).toOpaque()
    if let source = IOPSNotificationCreateRunLoopSource(
      { context in
        guard let context else { return }
        let monitor = Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in monitor.refresh() }
      }, context)?.takeRetainedValue()
    {
      powerSource = source
      CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }
    let center = NSWorkspace.shared.notificationCenter
    workspaceObservers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor [weak self] in
          self?.isSleeping = true
          self?.onChange?()
        }
      })
    workspaceObservers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor [weak self] in
          self?.isSleeping = false
          self?.refresh()
        }
      })
    refresh()
  }

  func refresh() {
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
      let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
    {
      onBattery = (type as String) == kIOPSBatteryPowerValue
    } else {
      onBattery = true
    }
    var currentID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
    let result = AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &currentID)
    if result != noErr { currentID = AudioDeviceID(kAudioObjectUnknown) }
    if currentID != deviceID {
      removeDeviceListeners()
      deviceID = currentID
      if deviceID != kAudioObjectUnknown {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
          Task { @MainActor [weak self] in self?.refresh() }
        }
        deviceListener = listener
        for selector in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceIsAlive] {
          var property = Self.address(selector)
          AudioObjectAddPropertyListenerBlock(deviceID, &property, .main, listener)
        }
      }
    }
    var alive: UInt32 = 0
    size = UInt32(MemoryLayout<UInt32>.size)
    address = Self.address(kAudioDevicePropertyDeviceIsAlive)
    hasOutput =
      deviceID != kAudioObjectUnknown
      && AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive) == noErr
      && alive != 0
    outputName = "No audio output"
    if hasOutput {
      var name: Unmanaged<CFString>?
      size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
      address = Self.address(kAudioObjectPropertyName)
      if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr {
        outputName = name?.takeRetainedValue() as String? ?? "Audio output"
      } else {
        outputName = "Audio output"
      }
    }
    onChange?()
  }

  func stop() {
    if let powerSource { CFRunLoopSourceInvalidate(powerSource) }
    powerSource = nil
    if let outputListener {
      var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
      AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject), &address, .main, outputListener)
    }
    outputListener = nil
    removeDeviceListeners()
    workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    workspaceObservers.removeAll()
  }

  private func removeDeviceListeners() {
    guard let deviceListener else { return }
    for selector in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceIsAlive] {
      var address = Self.address(selector)
      AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, deviceListener)
    }
    self.deviceListener = nil
  }

  private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress
  {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
  }
}
