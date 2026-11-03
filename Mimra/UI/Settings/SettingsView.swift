import SwiftUI

public struct SettingsView: View {
    @State private var engineVersion: String = coreVersion()
    @ObservedObject private var accessibilityService = AccessibilityService.shared
    @AppStorage("pasteAutomatically") private var pasteAutomatically: Bool = true
    @AppStorage("showColorSwatches") private var showColorSwatches: Bool = true
    @AppStorage("showUrlPreviews") private var showUrlPreviews: Bool = true
    @AppStorage("showSourceAppIcon") private var showSourceAppIcon: Bool = true

    // Format enablement settings (F-013, F-015, T-TYPE-05)
    @AppStorage(ClipboardTypeConfiguration.storePlainTextKey) private var storePlainText: Bool = true
    @AppStorage(ClipboardTypeConfiguration.storeRichTextKey) private var storeRichText: Bool = true
    @AppStorage(ClipboardTypeConfiguration.storeImagesKey) private var storeImages: Bool = true
    @AppStorage(ClipboardTypeConfiguration.storeFilesKey) private var storeFiles: Bool = true

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
                Section("Item Previews") {
                    Toggle("Show HEX color swatch", isOn: $showColorSwatches)
                    Toggle("Show URL domain badges", isOn: $showUrlPreviews)
                    Toggle("Show source application icon", isOn: $showSourceAppIcon)
                }

                Section("Information") {
                    Text("When color swatches are enabled, recognized #RGB and #RRGGBB color codes display an inline visual color swatch. Copied text remains the primary payload on paste.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Appearance", systemImage: "paintpalette")
            }

            Form {
                Section("Supported Formats") {
                    Toggle("Plain text & URLs", isOn: $storePlainText)
                    Toggle("Rich text (HTML & RTF)", isOn: $storeRichText)
                    Toggle("Images (PNG, TIFF, JPEG, HEIC)", isOn: $storeImages)
                    Toggle("File references", isOn: $storeFiles)
                }

                Section("Information") {
                    Text("Disabled formats are dropped at the pasteboard boundary in Swift and never stored in SQLite or written to disk. If an item contains multiple formats, only enabled formats are retained.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem {
                Label("Storage", systemImage: "cylinder.split.1x2")
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
