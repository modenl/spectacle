import ModernSpectacleCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Permissions") {
                HStack {
                    Text("Accessibility")
                    Spacer()
                    Text(model.accessibilityTrusted ? "Granted" : "Required")
                        .foregroundStyle(model.accessibilityTrusted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                }

                Button("Open Accessibility Prompt") {
                    model.requestAccessibilityAccess()
                }
                .disabled(model.accessibilityTrusted)
            }

            Section("Startup") {
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.loginItems.isEnabled },
                    set: { model.loginItems.setEnabled($0) }
                ))

                if let error = model.loginItems.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Shortcuts") {
                ForEach(WindowAction.allCases.filter { !$0.isHistoryAction }) { action in
                    HStack {
                        Text(action.title)
                        Spacer()
                        Text(action.defaultShortcutDescription)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Text(WindowAction.undo.title)
                    Spacer()
                    Text(WindowAction.undo.defaultShortcutDescription)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(WindowAction.redo.title)
                    Spacer()
                    Text(WindowAction.redo.defaultShortcutDescription)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}
