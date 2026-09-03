import Foundation

struct NoiseSignal {
  static let maximumPeak: Float = 0.0000316227766
  static let levels: [Double] = [-102, -96, -90]

  static func sanitizedLevel(_ value: Double) -> Double {
    guard value.isFinite else { return -90 }
    return levels.min(by: { abs($0 - value) < abs($1 - value) }) ?? -90
  }

  static func samples(level: Double) -> [Float] {
    let amplitude = min(maximumPeak, Float(pow(10, sanitizedLevel(level) / 20)))
    var state: UInt32 = 0x6D2B_79F5
    var values = [Float](repeating: 0, count: 32_768)
    for index in stride(from: 0, to: values.count, by: 2) {
      state ^= state << 13
      state ^= state >> 17
      state ^= state << 5
      let value = min(
        amplitude, max(-amplitude, (Float(state) / Float(UInt32.max) * 2 - 1) * amplitude))
      values[index] = value
      values[index + 1] = -value
    }
    return values
  }
}

final class NoiseRenderer {
  private let samples: [Float]
  private var position = 0

  init(level: Double) {
    samples = NoiseSignal.samples(level: level)
  }

  func next() -> Float {
    let sample = samples[position]
    position += 1
    if position == samples.count { position = 0 }
    return min(NoiseSignal.maximumPeak, max(-NoiseSignal.maximumPeak, sample))
  }
}
