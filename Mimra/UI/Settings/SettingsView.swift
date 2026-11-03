import SwiftUI

public struct SettingsView: View {
    @State private var engineVersion: String = coreVersion()

    public init() {}

    public var body: some View {
        TabView {
            Form {
                Section("Application") {
                    LabeledContent("Name", value: "Mimra")
                    LabeledContent("Platform", value: "macOS 15.0+ (Apple Silicon)")
                    LabeledContent("Status", value: "Menu Bar Agent Active")
                }

                Section("Engine Core") {
                    LabeledContent("RustCore Engine", value: "v\(engineVersion)")
                    LabeledContent("Deduplication", value: "BLAKE3 Cryptographic Hashing")
                    LabeledContent("Search & Storage", value: "SQLite + FTS5 (WAL Mode)")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("General", systemImage: "gear")
            }

            Form {
                Section("Security & Privacy") {
                    Text("Mimra excludes sensitive markers from password managers and ignored applications before any data reaches disk.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    
                    LabeledContent("Network Access", value: "Zero (Strictly Offline)")
                    LabeledContent("Telemetry", value: "Disabled")
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Privacy", systemImage: "hand.raised")
            }
        }
        .frame(width: 480, height: 320)
    }
}
