import SwiftUI

struct MenuView: View {
  @ObservedObject var model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 12) {
        Image(systemName: "waveform")
          .font(.system(size: 23, weight: .medium))
          .foregroundStyle(.teal)
          .frame(width: 44, height: 44)
          .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        VStack(alignment: .leading, spacing: 3) {
          Text("NoPop").font(.title2.weight(.semibold))
          Text("Quietly keeping sound ready").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          Label(
            model.isRunning ? "Speakers awake" : "Inactive",
            systemImage: model.isRunning ? "checkmark.circle.fill" : "pause.circle"
          )
          .font(.headline)
          .foregroundStyle(model.isRunning ? Color.teal : Color.secondary)
          Text(model.detail).font(.caption).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        }
        Spacer(minLength: 12)
        Button(model.enabled ? "Turn Off" : "Turn On") { model.enabled.toggle() }
          .buttonStyle(.borderedProminent)
          .tint(model.enabled ? .secondary : .teal)
          .controlSize(.large)
          .fixedSize()
          .accessibilityLabel(model.enabled ? "Turn keep-alive off" : "Turn keep-alive on")
      }
      Divider()
      VStack(alignment: .leading, spacing: 7) {
        Text("AUDIO OUTPUT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
        Label(model.outputName, systemImage: "hifispeaker")
          .font(.callout).lineLimit(2).textSelection(.enabled)
          .help(model.outputName)
      }
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("Keep-alive level").font(.callout.weight(.medium))
          Spacer()
          Text("Peak dBFS").font(.caption).foregroundStyle(.secondary)
        }
        Picker("Keep-alive level", selection: $model.level) {
          ForEach(NoiseSignal.levels, id: \.self) { level in
            Text("\(Int(level)) dB").tag(level)
          }
        }
        .pickerStyle(.segmented).labelsHidden()
        Text("Very faint noise · Hard limit at −90 dBFS")
          .font(.caption).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Pause on battery power", isOn: $model.pauseOnBattery)
        Toggle(
          "Launch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLoginEnabled))
        if model.loginNeedsApproval {
          Button("Approve in System Settings…", action: model.openLoginSettings)
            .font(.caption)
        }
        if let error = model.loginError {
          Text(error).font(.caption).foregroundStyle(.secondary)
        }
      }
      .toggleStyle(.switch).controlSize(.small)
      Divider()
      HStack {
        Spacer()
        Button("Quit NoPop") { NSApplication.shared.terminate(nil) }
          .buttonStyle(.plain).font(.caption)
          .keyboardShortcut("q")
      }
    }
    .padding(20)
    .frame(width: 348)
    .onAppear { model.refreshLoginStatus() }
  }
}
