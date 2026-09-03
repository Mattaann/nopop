import AVFoundation

@MainActor
protocol AudioPlayback: AnyObject {
  var onConfigurationChange: (() -> Void)? { get set }
  var isRunning: Bool { get }
  func start(level: Double) throws
  func stop()
}

@MainActor
final class KeepAliveAudio: AudioPlayback {
  private var engine: AVAudioEngine?
  private var configurationObserver: NSObjectProtocol?
  var onConfigurationChange: (() -> Void)?
  var isRunning: Bool { engine?.isRunning == true }

  func start(level: Double) throws {
    stop()
    let engine = AVAudioEngine()
    let output = engine.outputNode.inputFormat(forBus: 0)
    guard output.sampleRate.isFinite, output.sampleRate > 0, output.channelCount > 0,
      let format = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 1)
    else {
      throw AudioError.noOutput
    }
    let source = Self.makeSource(format: format, level: level)
    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = 1
    engine.prepare()
    do {
      try engine.start()
    } catch {
      engine.stop()
      throw error
    }
    self.engine = engine
    configurationObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in self?.onConfigurationChange?() }
    }
  }

  static func makeSource(format: AVAudioFormat, level: Double) -> AVAudioSourceNode {
    let renderer = NoiseRenderer(level: level)
    return AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
      isSilence.pointee = false
      let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
      for frame in 0..<Int(frameCount) {
        let sample = renderer.next()
        for buffer in buffers {
          guard let data = buffer.mData else { continue }
          let channelCount = Int(buffer.mNumberChannels)
          let values = data.assumingMemoryBound(to: Float.self)
          for channel in 0..<channelCount {
            values[frame * channelCount + channel] = sample
          }
        }
      }
      return noErr
    }
  }

  func stop() {
    if let configurationObserver {
      NotificationCenter.default.removeObserver(configurationObserver)
    }
    configurationObserver = nil
    engine?.stop()
    engine = nil
  }

  enum AudioError: Error { case noOutput }
}
