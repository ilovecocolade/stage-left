import AppIntents
import SwiftUI
import WidgetKit

/// The Control Centre button.
///
/// It flips the app's master switch. Which screens that switch applies to is
/// chosen in the app's menu, and stays there — a Control Centre
/// button has room for one decision, not a list of monitors.
@main
struct StageLeftControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedState.controlKind, provider: StagingProvider()) { isStaging in
            ControlWidgetToggle("Stage Left", isOn: isStaging, action: SetStagingIntent()) { on in
                Label(on ? "Staging" : "Off",
                      systemImage: on ? "rectangle.stack.fill" : "rectangle.stack")
            }
        }
        .displayName("Stage Left")
        .description("Stage windows on the screens you picked in Stage Left.")
    }
}

/// Reads the switch each time Control Centre draws the button. Off whenever
/// the app is not running, since nothing is being staged then.
struct StagingProvider: ControlValueProvider {
    let previewValue = true

    func currentValue() async throws -> Bool {
        SharedState.publishedState
    }
}

/// Asks the running app to flip the switch.
struct SetStagingIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Stage selected screens"

    @Parameter(title: "Staging")
    var value: Bool

    func perform() async throws -> some IntentResult {
        await SharedState.request(value)
        return .result()
    }
}
