import SwiftUI

public struct SettingsView: View {
    @State private var engineVersion: String = coreVersion()
    @ObservedObject private var accessibilityService = AccessibilityService.shared
    @AppStorage("pasteAutomatically") private var pasteAutomatically: Bool = true

    public init() {}

    public var body: some View {
        TabView {
            Form {
                Section("Application") {
                    LabeledContent("Name", value: "Mimra")
                    LabeledContent("Platform", value: "macOS 15.0+ (Apple Silicon)")
                    LabeledContent("Status", value: "Menu Bar Agent Active")
                }

                Section("Paste Behavior & Permissions") {
                    Toggle("Paste automatically into target app", isOn: $pasteAutomatically)

                    HStack {
                        Text("Accessibility Permission")
                        Spacer()
                        if accessibilityService.isTrusted {
                            Label("Granted", systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Grant Permission...") {
                                accessibilityService.promptForPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    if !accessibilityService.isTrusted {
                        HStack {
                            Text("Copy-Only Mode active until permission is granted in macOS System Settings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("Open System Settings") {
                                accessibilityService.openSystemSettings()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
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
        .frame(width: 520, height: 380)
        .task {
            accessibilityService.startObserving()
        }
        .onDisappear {
            accessibilityService.stopObserving()
        }
    }
}
