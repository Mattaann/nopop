import SwiftUI

@main
struct NoPopApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuView(model: model)
    } label: {
      Image(systemName: model.isRunning ? "speaker.wave.2.fill" : "speaker.slash")
        .accessibilityLabel("NoPop: \(model.isRunning ? "Speakers awake" : "Inactive")")
    }
    .menuBarExtraStyle(.window)
  }
}
