import Foundation

@main
struct SpikeRunner {
    static func main() {
        print("Starting Swift <-> Rust UniFFI Integration Spike...")

        // 1. Test version retrieval across FFI
        let version = coreVersion()
        print("RustCore Version via FFI: \(version)")
        assert(version == "0.2.0", "Version must match Cargo.toml version")

        // 2. Test BLAKE3 fingerprinting across FFI
        let testData = "Hello Mimra Bridge".data(using: .utf8)!
        do {
            let hash = try fingerprint(payload: testData)
            print("BLAKE3 Hash via FFI: \(hash)")
            assert(hash.count == 64, "Hash length must be 64 characters")
        } catch {
            assertionFailure("Fingerprint failed unexpectedly: \(error)")
        }

        // 3. Test typed error handling across FFI (Empty payload)
        let emptyData = Data()
        do {
            _ = try fingerprint(payload: emptyData)
            assertionFailure("Expected EmptyPayload error, but call succeeded")
        } catch CoreError.EmptyPayload {
            print("✓ Successfully caught expected CoreError.EmptyPayload across FFI!")
        } catch {
            assertionFailure("Caught unexpected error type: \(error)")
        }

        print("✓ All Swift <-> Rust UniFFI spike tests PASSED!")
    }
}
