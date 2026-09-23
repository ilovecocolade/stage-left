import AppIntents
import SwiftUI
import WidgetKit

/// The Control Centre button.
///
/// It flips one master switch shared with the app. Which screens that switch
/// applies to is chosen in the app's menu, and stays there — a Control Centre
/// button has room for one decision, not a list of monitors.
@main
struct StagehandControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedState.controlKind, provider: StagingProvider()) { isStaging in
            ControlWidgetToggle("Stagehand", isOn: isStaging, action: SetStagingIntent()) { on in
                Label(on ? "Staging" : "Off",
                      systemImage: on ? "rectangle.stack.fill" : "rectangle.stack")
            }
        }
        .displayName("Stagehand")
        .description("Stage windows on the screens you picked in Stagehand.")
    }
}

/// Reads the switch each time Control Centre draws the button.
struct StagingProvider: ControlValueProvider {
    let previewValue = true

    func currentValue() async throws -> Bool {
        SharedState.isStaging
    }
}

/// Writes the switch, then tells the app to act on it.
struct SetStagingIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Stage selected screens"

    @Parameter(title: "Staging")
    var value: Bool

    func perform() async throws -> some IntentResult {
        SharedState.isStaging = value
        SharedState.announceChange()
        return .result()
    }
}
