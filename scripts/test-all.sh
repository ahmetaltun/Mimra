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
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/tests/panel_tests.swift" \
    -o /tmp/mimra_panel_test_runner

/tmp/mimra_panel_test_runner
rm -f /tmp/mimra_panel_test_runner

echo -e "\n=== 11. Running Global Hotkey Manager Tests (T-UI-01, T-KEY-02) ==="
swiftc -module-cache-path /tmp/swift-module-cache \
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
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Settings/SettingsView.swift" \
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
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
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
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
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
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/PasteCoordinator.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AccessibilityService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
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
    "$PROJECT_ROOT/Mimra/macOS/ClipboardMonitor.swift" \
    "$PROJECT_ROOT/Mimra/macOS/ImageThumbnailService.swift" \
    "$PROJECT_ROOT/Mimra/macOS/AppIconService.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/ColorAndUrlPreview.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/PanelViewModel.swift" \
    "$PROJECT_ROOT/Mimra/UI/Panel/FloatingPanelView.swift" \
    "$PROJECT_ROOT/Mimra/UI/Settings/SettingsView.swift" \
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

echo -e "\n=== 33. Building Native macOS App (Mimra.app) via Xcode ==="
cd "$PROJECT_ROOT"
xcodebuild -project Mimra.xcodeproj \
    -scheme Mimra \
    -configuration Debug \
    -derivedDataPath /tmp/MimraDerivedData \
    -destination 'platform=macOS,arch=arm64' \
    build

echo -e "\n✓ ALL QUALITY GATES, FFI INTEGRATION, SUITE TESTS, AND NATIVE XCODE BUILDS PASSED!"
