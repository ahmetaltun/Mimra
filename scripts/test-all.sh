#!/usr/bin/env bash
# ==============================================================================
# Mimra — Comprehensive Verification Test Script
# Runs environment check, Rust formatting, clippy, unit tests, static library build,
# binding generation, Swift FFI integration verification, Privacy Filter tests,
# Provenance tests, Capture Pipeline tests, Persistence Relaunch tests, and Xcode build.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PREVIEW_SOURCES=(
    "$PROJECT_ROOT/Mimra/macOS/AppearanceConfiguration.swift"
    "$PROJECT_ROOT/Mimra/macOS/HotkeyConfiguration.swift"
    "$PROJECT_ROOT/Mimra/UI/Preview/PreviewBoundsCalculator.swift"
    "$PROJECT_ROOT/Mimra/UI/Preview/PreviewPanel.swift"
    "$PROJECT_ROOT/Mimra/UI/Preview/NativeTextPreviewView.swift"
    "$PROJECT_ROOT/Mimra/UI/Preview/ImagePreviewService.swift"
    "$PROJECT_ROOT/Mimra/UI/Preview/ImagePreviewView.swift"
    "$PROJECT_ROOT/Mimra/UI/Preview/PreviewContainerView.swift"
    "$PROJECT_ROOT/Mimra/UI/Preview/PreviewCoordinator.swift"
)

SETTINGS_EXTRA_SOURCES=(
    "$PROJECT_ROOT/Mimra/macOS/LaunchAtLoginService.swift"
    "$PROJECT_ROOT/Mimra/macOS/SoundFeedbackService.swift"
    "$PROJECT_ROOT/Mimra/macOS/PrivacyConfiguration.swift"
    "$PROJECT_ROOT/Mimra/macOS/LocalizationService.swift"
    "$PROJECT_ROOT/Mimra/macOS/OnboardingService.swift"
    "$PROJECT_ROOT/Mimra/UI/Onboarding/OnboardingView.swift"
    "$PROJECT_ROOT/Mimra/UI/Settings/SettingsView.swift"
)

echo "=== 1. Validating Environment ==="
"$PROJECT_ROOT/scripts/check-env.sh"

echo -e "\n=== 2. Running Rust Quality Gates (fmt, clippy, test) ==="
cd "$PROJECT_ROOT/RustCore"
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test --all --locked

echo -e "\n=== 3. Building Rust Static Library ==="
"$PROJECT_ROOT/scripts/build-rust.sh" debug

echo -e "\n=== 4. Generating Swift UniFFI Bindings ==="
"$PROJECT_ROOT/scripts/generate-bindings.sh"

echo -e "\n=== 5. Running Swift <-> Rust FFI Integration Spike ==="
cd "$PROJECT_ROOT"
mkdir -p /tmp/swift-module-cache
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/tests/ffi_spike.swift" \
    -o /tmp/mimra_ffi_spike_runner

/tmp/mimra_ffi_spike_runner
rm -f /tmp/mimra_ffi_spike_runner

echo -e "\n=== 6. Running Privacy Filter Tests (T-PRIV-01..06) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/tests/privacy_filter_tests.swift" \
    -o /tmp/mimra_privacy_filter_test_runner

/tmp/mimra_privacy_filter_test_runner
rm -f /tmp/mimra_privacy_filter_test_runner

echo -e "\n=== 7. Running Clipboard Provenance Tests (T-CAP-05) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/tests/provenance_tests.swift" \
    -o /tmp/mimra_provenance_test_runner

/tmp/mimra_provenance_test_runner
rm -f /tmp/mimra_provenance_test_runner

echo -e "\n=== 8. Running Capture Pipeline & CoreClient Tests (T-CAP-01..03, T-HIST-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/tests/capture_pipeline_tests.swift" \
    -o /tmp/mimra_capture_pipeline_test_runner

/tmp/mimra_capture_pipeline_test_runner
rm -f /tmp/mimra_capture_pipeline_test_runner

echo -e "\n=== 9. Running Persistence & Cold Relaunch Tests (T-HIST-02, 1,000 items) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/tests/persistence_relaunch_tests.swift" \
    -o /tmp/mimra_persistence_relaunch_test_runner

/tmp/mimra_persistence_relaunch_test_runner
rm -f /tmp/mimra_persistence_relaunch_test_runner

echo -e "\n=== 10. Running Floating Panel & Coordinator Tests (T-UI-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/tests/panel_tests.swift" \
    -o /tmp/mimra_panel_test_runner

/tmp/mimra_panel_test_runner
rm -f /tmp/mimra_panel_test_runner

echo -e "\n=== 11. Running Global Hotkey Manager Tests (T-UI-01, T-KEY-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "$PROJECT_ROOT/tests/hotkey_tests.swift" \
    -o /tmp/mimra_hotkey_test_runner

/tmp/mimra_hotkey_test_runner
rm -f /tmp/mimra_hotkey_test_runner

echo -e "\n=== 12. Running Status Bar Coordinator Tests (T-UI-01, T-HIST-01, T-PRIV-06) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "${SETTINGS_EXTRA_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/macOS/StatusBarCoordinator.swift" \
    "$PROJECT_ROOT/tests/status_bar_tests.swift" \
    -o /tmp/mimra_status_bar_test_runner

/tmp/mimra_status_bar_test_runner
rm -f /tmp/mimra_status_bar_test_runner

echo -e "\n=== 13. Running Search Interaction & Keyboard Tests (T-UI-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/tests/search_interaction_tests.swift" \
    -o /tmp/mimra_search_test_runner

/tmp/mimra_search_test_runner
rm -f /tmp/mimra_search_test_runner

echo -e "\n=== 14. Running Paste Replay Codec Tests (T-PASTE-01, T-PASTE-02, T-CAP-05) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/tests/paste_replay_tests.swift" \
    -o /tmp/mimra_paste_replay_test_runner

/tmp/mimra_paste_replay_test_runner
rm -f /tmp/mimra_paste_replay_test_runner

echo -e "\n=== 15. Running Auto-Paste & Focus Tracking Tests (T-PASTE-01, T-PASTE-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/tests/auto_paste_tests.swift" \
    -o /tmp/mimra_auto_paste_test_runner

/tmp/mimra_auto_paste_test_runner
rm -f /tmp/mimra_auto_paste_test_runner

echo -e "\n=== 16. Running Accessibility & Copy-Only Fallback Tests (T-PASTE-01, T-UI-04) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/tests/accessibility_tests.swift" \
    -o /tmp/mimra_accessibility_test_runner

/tmp/mimra_accessibility_test_runner
rm -f /tmp/mimra_accessibility_test_runner

echo -e "\n=== 17. Running Plain Paste & Formatted Downgrade Tests (T-PASTE-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/tests/plain_paste_tests.swift" \
    -o /tmp/mimra_plain_paste_test_runner

/tmp/mimra_plain_paste_test_runner
rm -f /tmp/mimra_plain_paste_test_runner

echo -e "\n=== 18. Running Paste Error Handling & Safety Guard Tests (T-PASTE-04) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/tests/paste_error_tests.swift" \
    -o /tmp/mimra_paste_error_test_runner

/tmp/mimra_paste_error_test_runner
rm -f /tmp/mimra_paste_error_test_runner

echo -e "\n=== 19. Running Rich Text & HTML Multi-Representation Tests (T-TYPE-01) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/tests/rich_text_tests.swift" \
    -o /tmp/mimra_rich_text_test_runner

/tmp/mimra_rich_text_test_runner
rm -f /tmp/mimra_rich_text_test_runner

echo -e "\n=== 20. Running Image Types & Thumbnail Cache Tests (T-TYPE-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/tests/image_type_tests.swift" \
    -o /tmp/mimra_image_type_test_runner

/tmp/mimra_image_type_test_runner
rm -f /tmp/mimra_image_type_test_runner

echo -e "\n=== 21. Running File Reference & Multi-File URL Tests (T-TYPE-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/tests/file_url_tests.swift" \
    -o /tmp/mimra_file_url_test_runner

/tmp/mimra_file_url_test_runner
rm -f /tmp/mimra_file_url_test_runner

echo -e "\n=== 22. Running URL & HEX Color Recognition Tests (T-TYPE-04, T-TYPE-06) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/tests/url_color_tests.swift" \
    -o /tmp/mimra_url_color_test_runner

/tmp/mimra_url_color_test_runner
rm -f /tmp/mimra_url_color_test_runner

echo -e "\n=== 23. Running Source Attribution & App Icon Tests (T-CAP-04) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/tests/source_attribution_tests.swift" \
    -o /tmp/mimra_source_attribution_test_runner

/tmp/mimra_source_attribution_test_runner
rm -f /tmp/mimra_source_attribution_test_runner

echo -e "\n=== 24. Running Deduplication Hardening Tests (T-CAP-05, F-012) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/tests/dedupe_hardening_tests.swift" \
    -o /tmp/mimra_dedupe_hardening_test_runner

/tmp/mimra_dedupe_hardening_test_runner
rm -f /tmp/mimra_dedupe_hardening_test_runner

echo -e "\n=== 25. Running Clipboard Type Settings Tests (T-TYPE-05, F-013, F-015) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/tests/type_settings_tests.swift" \
    -o /tmp/mimra_type_settings_test_runner

/tmp/mimra_type_settings_test_runner
rm -f /tmp/mimra_type_settings_test_runner

echo -e "\n=== 26. Running FTS5 Search Index & Pagination Tests (T-SRCH-01, F-019, F-048) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/tests/search_index_tests.swift" \
    -o /tmp/mimra_search_index_test_runner

/tmp/mimra_search_index_test_runner
rm -f /tmp/mimra_search_index_test_runner

echo -e "\n=== 27. Running Fuzzy Search, Ranking & Highlights Tests (T-SRCH-01, F-048) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/tests/fuzzy_search_tests.swift" \
    -o /tmp/mimra_fuzzy_test_runner

/tmp/mimra_fuzzy_test_runner
rm -f /tmp/mimra_fuzzy_test_runner

echo -e "\n=== 28. Running Exact & Regex Search Tests (T-SRCH-02, F-048) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/regex_search_tests.swift" \
    -o /tmp/mimra_regex_test_runner

/tmp/mimra_regex_test_runner
rm -f /tmp/mimra_regex_test_runner

echo -e "\n=== 29. Running Sorting, Pin Arrangement & Selection Stability Tests (P4-04 / T-UI-03, T-KEY-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/sorting_highlight_tests.swift" \
    -o /tmp/mimra_sorting_highlight_test_runner

/tmp/mimra_sorting_highlight_test_runner
rm -f /tmp/mimra_sorting_highlight_test_runner

echo -e "\n=== 30. Running History Limit, Retention & Pin Protection Tests (P4-05 / T-HIST-01, T-HIST-03, T-HIST-05) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/tests/history_limit_tests.swift" \
    -o /tmp/mimra_history_limit_test_runner

/tmp/mimra_history_limit_test_runner
rm -f /tmp/mimra_history_limit_test_runner

echo -e "\n=== 31. Running Storage UI & Metrics Update Tests (P4-06 / F-025, F-055, T-HIST-01, T-HIST-05) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppearanceConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyConfiguration.swift" \
    "${SETTINGS_EXTRA_SOURCES[@]}" \
    "$PROJECT_ROOT/tests/storage_ui_tests.swift" \
    -o /tmp/mimra_storage_ui_test_runner

/tmp/mimra_storage_ui_test_runner
rm -f /tmp/mimra_storage_ui_test_runner

echo -e "\n=== 32. Running Database Failure Recovery & Backup Tests (P4-07 / T-DB-01, F-052, F-055) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/tests/failure_recovery_tests.swift" \
    -o /tmp/mimra_failure_recovery_test_runner

/tmp/mimra_failure_recovery_test_runner
rm -f /tmp/mimra_failure_recovery_test_runner

echo -e "\n=== 33. Running Pinning & Keyboard Operations Tests (P5-01 / F-020, F-024, F-053, T-PIN-01, T-HIST-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/pin_tests.swift" \
    -o /tmp/mimra_pin_test_runner

/tmp/mimra_pin_test_runner
rm -f /tmp/mimra_pin_test_runner

echo -e "\n=== 34. Running Pin Shortcut Assignment & Punctuation Tests (P5-02 / F-024, T-PIN-01) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/pin_shortcut_assignment_tests.swift" \
    -o /tmp/mimra_pin_shortcut_test_runner

/tmp/mimra_pin_shortcut_test_runner
rm -f /tmp/mimra_pin_shortcut_test_runner

echo -e "\n=== 35. Running Pin Reordering & Keyboard Accessibility Tests (P5-03 / F-046, T-PIN-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/pin_reorder_tests.swift" \
    -o /tmp/mimra_pin_reorder_test_runner

/tmp/mimra_pin_reorder_test_runner
rm -f /tmp/mimra_pin_reorder_test_runner

echo -e "\n=== 36. Running Pin Editing & Reindexing Tests (P5-04 / F-045, T-PIN-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/pin_edit_tests.swift" \
    -o /tmp/mimra_pin_edit_test_runner

/tmp/mimra_pin_edit_test_runner
rm -f /tmp/mimra_pin_edit_test_runner

echo -e "\n=== 37. Running Quick Pick 1-9 & Modifier Tests (P5-05 / F-022, T-KEY-01) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/quick_pick_tests.swift" \
    -o /tmp/mimra_quick_pick_test_runner

/tmp/mimra_quick_pick_test_runner
rm -f /tmp/mimra_quick_pick_test_runner

echo -e "\n=== 38. Running Summon-Key Cycle Mode Tests (P5-06 / F-023, F-031, T-KEY-02, T-KEY-04) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/cycle_mode_tests.swift" \
    -o /tmp/mimra_cycle_mode_test_runner

/tmp/mimra_cycle_mode_test_runner
rm -f /tmp/mimra_cycle_mode_test_runner

echo -e "\n=== 39. Running Navigation Semantics & Delete Stability Tests (P5-07 / F-030, F-036, T-KEY-03, T-UI-10) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/nav_semantics_tests.swift" \
    -o /tmp/mimra_nav_semantics_test_runner

/tmp/mimra_nav_semantics_test_runner
rm -f /tmp/mimra_nav_semantics_test_runner

echo -e "\n=== 40. Running Slideout Preview Panel Tests (P6-01 / F-039, T-PREV-01) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/preview_panel_tests.swift" \
    -o /tmp/mimra_preview_panel_test_runner

/tmp/mimra_preview_panel_test_runner
rm -f /tmp/mimra_preview_panel_test_runner

echo -e "\n=== 41. Running Preview Settings & Auto-Open Tests (P6-02 / F-040, T-PREV-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/preview_settings_tests.swift" \
    -o /tmp/mimra_preview_settings_test_runner

/tmp/mimra_preview_settings_test_runner
rm -f /tmp/mimra_preview_settings_test_runner

echo -e "\n=== 42. Running Native Text Preview & 1 MB Buffer Tests (P6-03 / F-041, T-PREV-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/text_preview_tests.swift" \
    -o /tmp/mimra_text_preview_test_runner

/tmp/mimra_text_preview_test_runner
rm -f /tmp/mimra_text_preview_test_runner

echo -e "\n=== 43. Running Image Preview & Metadata Tests (P6-04 / F-042, T-PREV-04) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/image_preview_tests.swift" \
    -o /tmp/mimra_image_preview_test_runner

/tmp/mimra_image_preview_test_runner
rm -f /tmp/mimra_image_preview_test_runner

echo -e "\n=== 44. Running OCR Service & Multilingual Vision Recognition Tests (P6-05 / F-043, T-OCR-01) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/tests/ocr_service_tests.swift" \
    -o /tmp/mimra_ocr_service_test_runner

/tmp/mimra_ocr_service_test_runner
rm -f /tmp/mimra_ocr_service_test_runner

echo -e "\n=== 45. Running OCR Results & Copy Action Integration Tests (P6-06 / F-044, T-OCR-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Preview/ImagePreviewService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Preview/ImagePreviewView.swift" \
    "$PROJECT_ROOT/tests/ocr_results_tests.swift" \
    -o /tmp/mimra_ocr_results_test_runner

/tmp/mimra_ocr_results_test_runner
rm -f /tmp/mimra_ocr_results_test_runner

echo -e "\n=== 46. Running OCR Race Protection & High-Concurrency Dismissal Stress Tests (P6-07 / T-PREV-02, T-SRCH-04) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/ocr_race_protection_tests.swift" \
    -o /tmp/mimra_ocr_race_runner

/tmp/mimra_ocr_race_runner
rm -f /tmp/mimra_ocr_race_runner

echo -e "\n=== 47. Running General Settings Integration Tests (P7-01 / F-020, F-035, F-056, F-062, F-064) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/SoundFeedbackService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/LaunchAtLoginService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/tests/general_settings_tests.swift" \
    -o /tmp/mimra_general_settings_tests_runner

/tmp/mimra_general_settings_tests_runner
rm -f /tmp/mimra_general_settings_tests_runner

echo -e "\n=== 48. Running Appearance Settings Integration Tests (P7-02 / F-028, F-032, F-034, F-035, F-058) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "$PROJECT_ROOT/Mimra/macOS/AppearanceConfiguration.swift" \
    "$PROJECT_ROOT/tests/appearance_settings_tests.swift" \
    -o /tmp/mimra_appearance_settings_test_runner

/tmp/mimra_appearance_settings_test_runner
rm -f /tmp/mimra_appearance_settings_test_runner

echo -e "\n=== 49. Running Search & Storage Settings Integration Tests (P7-03 / F-013, F-049, F-050, F-055) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppearanceConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyConfiguration.swift" \
    "${SETTINGS_EXTRA_SOURCES[@]}" \
    "$PROJECT_ROOT/tests/search_storage_settings_tests.swift" \
    -o /tmp/mimra_search_storage_settings_test_runner

/tmp/mimra_search_storage_settings_test_runner
rm -f /tmp/mimra_search_storage_settings_test_runner

echo -e "\n=== 50. Running Privacy & Exclusions Settings Integration Tests (P7-04 / F-009, F-010, F-057) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyConfiguration.swift" \
    "$PROJECT_ROOT/tests/privacy_settings_tests.swift" \
    -o /tmp/mimra_privacy_settings_test_runner

/tmp/mimra_privacy_settings_test_runner
rm -f /tmp/mimra_privacy_settings_test_runner

echo -e "\n=== 51. Running Hotkey Settings & Collision Integration Tests (P7-05 / F-023, T-KEY-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -strict-concurrency=complete \
    -warnings-as-errors \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "$PROJECT_ROOT/tests/hotkey_settings_tests.swift" \
    -o /tmp/mimra_hotkey_settings_test_runner

/tmp/mimra_hotkey_settings_test_runner
rm -f /tmp/mimra_hotkey_settings_test_runner

echo -e "\n=== 52. Running Localization, String Catalog & IME Input Tests (P7-06 / F-033, F-059, T-I18N-01, T-I18N-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "$PROJECT_ROOT/Mimra/macOS/LocalizationService.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/localization_ime_tests.swift" \
    -o /tmp/mimra_loc_test_runner

/tmp/mimra_loc_test_runner
rm -f /tmp/mimra_loc_test_runner

echo -e "\n=== 53. Running VoiceOver & Keyboard Accessibility Integration Tests (P7-07 / F-060, T-A11Y-01) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "$PROJECT_ROOT/Mimra/macOS/LocalizationService.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/voiceover_accessibility_tests.swift" \
    -o /tmp/mimra_a11y_test_runner

/tmp/mimra_a11y_test_runner
rm -f /tmp/mimra_a11y_test_runner

echo -e "\n=== 54. Running Permissions & Onboarding Integration Tests (P7-08 / F-061, T-PASTE-03) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -strict-concurrency=complete \
    -warnings-as-errors \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OnboardingService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Onboarding/OnboardingView.swift" \
    "$PROJECT_ROOT/tests/onboarding_permissions_tests.swift" \
    -o /tmp/mimra_onboarding_test_runner

/tmp/mimra_onboarding_test_runner
rm -f /tmp/mimra_onboarding_test_runner

echo -e "\n=== 55. Running Appearance Accessibility, Fullscreen Clamping & Focus Tests (P7-09 / F-029, F-034, T-UI-06, T-UI-08) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
    -import-objc-header "$PROJECT_ROOT/Generated/mimra_coreFFI.h" \
    -I "$PROJECT_ROOT/Generated" \
    -L "$PROJECT_ROOT/RustCore/target/aarch64-apple-darwin/debug" \
    -lmimra_core \
    "$PROJECT_ROOT/Generated/mimra_core.swift" \
    "$PROJECT_ROOT/Mimra/Bridge/CoreClient.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardProvenance.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardTypeConfiguration.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PrivacyFilter.swift" \
    "$PROJECT_ROOT/Mimra/macOS/OCRService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/HotkeyManager.swift" \
    "$PROJECT_ROOT/Mimra/macOS/LocalizationService.swift" \
    "${PREVIEW_SOURCES[@]}" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/tests/appearance_accessibility_tests.swift" \
    -o /tmp/mimra_a11y_appear_runner

/tmp/mimra_a11y_appear_runner
rm -f /tmp/mimra_a11y_appear_runner

echo -e "\n=== 56. Building Native macOS App (Mimra.app) via Xcode ==="
cd "$PROJECT_ROOT"
xcodebuild -project Mimra.xcodeproj \
    -scheme Mimra \
    -configuration Debug \
    -derivedDataPath /tmp/MimraDerivedData \
    -destination 'platform=macOS,arch=arm64' \
    build

echo -e "\n✓ ALL QUALITY GATES, FFI INTEGRATION, SUITE TESTS, AND NATIVE XCODE BUILDS PASSED!"
