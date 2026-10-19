import Foundation
import Security
@testable import DeskTransport
import XCTest

/// These tests never touch a real Keychain. Every case runs against an injected
/// in-memory implementation, so running the suite cannot add, change, or remove
/// an item in anyone's login keychain.
///
/// The one path not covered here is Security.framework itself:
/// `SystemPairingKeychain` needs a signed, entitled build on real hardware to
/// reach the data protection keychain, which is a manual gate rather than
/// something this suite can assert. What *is* covered is every decision the store
/// makes around it — which attributes it writes, which statuses mean "never
/// saved" versus "macOS refused", and what it refuses to send at all.
final class PairingKeyStoreTests: XCTestCase {
    private let service = "org.visiondesk.VisionDesk.pairing.tests"
    private let account = "Upstairs Mac"

    func testDefaultServiceIsThePinnedIdentifier() {
        XCTAssertEqual(PairingKeyStore.defaultService, "org.visiondesk.VisionDesk.pairing")
    }

    func testSaveThenLoadReturnsTheSameRememberedKey() throws {
        let keychain = FakeKeychain()
        let store = PairingKeyStore(service: service, keychain: keychain)
        let key = PairingKey.generate()
        try store.save(key, account: account)
        let loaded = try XCTUnwrap(store.load(account: account))
        // Compared with XCTAssertTrue so a failure never prints key material.
        XCTAssertTrue(loaded.displayValue == key.displayValue)
        XCTAssertEqual(keychain.items.count, 1)
    }

    func testLoadReturnsNilWhenNothingWasEverSaved() throws {
        let store = PairingKeyStore(service: service, keychain: FakeKeychain())
        XCTAssertNil(try store.load(account: account), "A Mac that was never remembered is not an error.")
    }

    func testSaveReplacesAnExistingKeyInPlace() throws {
        let keychain = FakeKeychain()
        let store = PairingKeyStore(service: service, keychain: keychain)
        let first = PairingKey.generate()
        let second = PairingKey.generate()
        try store.save(first, account: account)
        try store.save(second, account: account)
        XCTAssertEqual(keychain.items.count, 1, "A remembered Mac maps to exactly one secret.")
        XCTAssertEqual(keychain.addAttributes.count, 1, "The second save updates rather than adding.")
        let loaded = try XCTUnwrap(store.load(account: account))
        XCTAssertTrue(loaded.displayValue == second.displayValue)
        XCTAssertFalse(loaded.displayValue == first.displayValue)
        let updated = try XCTUnwrap(keychain.updateAttributes.last)
        #if os(macOS)
        XCTAssertNil(updated[kSecAttrAccessible as String])
        #else
        XCTAssertEqual(updated[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #endif
    }

    func testSavedItemIsDeviceOnlyAndCarriesTheSecretOnlyAsItsValue() throws {
        let keychain = FakeKeychain()
        let store = PairingKeyStore(service: service, keychain: keychain)
        let key = PairingKey.generate()
        try store.save(key, account: account)
        let attributes = try XCTUnwrap(keychain.addAttributes.last)
        XCTAssertEqual(attributes[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(attributes[kSecAttrService as String] as? String, service)
        XCTAssertEqual(attributes[kSecAttrAccount as String] as? String, account)
        #if os(macOS)
        XCTAssertNil(attributes[kSecAttrAccessible as String])
        #else
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #endif
        XCTAssertEqual(attributes[kSecUseDataProtectionKeychain as String] as? Bool, PairingKeyStore.usesDataProtectionKeychain)
        XCTAssertEqual(attributes[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual((attributes[kSecValueData as String] as? Data)?.count, 16)

        // Nothing but the item's value may carry the secret: no label, service, or
        // account field may contain its hexadecimal form.
        let hexadecimal = key.displayValue.replacingOccurrences(of: "-", with: "").lowercased()
        for (name, value) in attributes where name != kSecValueData as String {
            guard let text = value as? String else { continue }
            XCTAssertFalse(text.lowercased().contains(hexadecimal), "\(name) must not carry the secret.")
        }
    }

    func testDeniedAndUnentitledFailuresAreDistinguishedFromMissing() throws {
        let cases: [(OSStatus, PairingKeyStoreError)] = [
            (errSecInteractionNotAllowed, .accessDenied(errSecInteractionNotAllowed)),
            (errSecInteractionRequired, .accessDenied(errSecInteractionRequired)),
            (errSecAuthFailed, .accessDenied(errSecAuthFailed)),
            (errSecUserCanceled, .accessDenied(errSecUserCanceled)),
            (errSecMissingEntitlement, .notEntitled(errSecMissingEntitlement)),
            (errSecDecode, .keychainFailure(errSecDecode)),
            (errSecNotAvailable, .keychainFailure(errSecNotAvailable))
        ]
        for (status, expected) in cases {
            let keychain = FakeKeychain()
            keychain.forcedStatus = status
            let store = PairingKeyStore(service: service, keychain: keychain)
            XCTAssertThrowsError(try store.load(account: account)) {
                XCTAssertEqual($0 as? PairingKeyStoreError, expected)
            }
            XCTAssertThrowsError(try store.save(.generate(), account: account)) {
                XCTAssertEqual($0 as? PairingKeyStoreError, expected)
            }
            XCTAssertThrowsError(try store.delete(account: account)) {
                XCTAssertEqual($0 as? PairingKeyStoreError, expected)
            }
            let message = try XCTUnwrap(expected.errorDescription)
            XCTAssertTrue(message.contains("\(status)"), "A support report needs the status code.")
        }
    }

    func testUnreadableStoredItemIsReportedRatherThanTreatedAsMissing() throws {
        for payload in [Data(), Data(repeating: 7, count: 15), Data(repeating: 7, count: 17)] {
            let keychain = FakeKeychain()
            keychain.items[FakeKeychain.Entry(service: service, account: account)] = payload
            let store = PairingKeyStore(service: service, keychain: keychain)
            XCTAssertThrowsError(try store.load(account: account)) {
                XCTAssertEqual($0 as? PairingKeyStoreError, .unreadableItem)
            }
        }
    }

    func testDeleteForgetsTheKeyAndIsSafeToRepeat() throws {
        let keychain = FakeKeychain()
        let store = PairingKeyStore(service: service, keychain: keychain)
        try store.save(.generate(), account: account)
        try store.delete(account: account)
        XCTAssertNil(try store.load(account: account))
        XCTAssertTrue(keychain.items.isEmpty)
        // Forgetting a Mac that is already forgotten succeeds.
        try store.delete(account: account)
        XCTAssertEqual(keychain.deleteCount, 2)
    }

    func testInvalidAccountLabelsAreRejectedBeforeAnyKeychainCall() {
        let keychain = FakeKeychain()
        let store = PairingKeyStore(service: service, keychain: keychain)
        for label in ["", " ", "  ", "upstairs\n", "upstairs\r", "upstairs\u{0}mac",
                      " upstairs", "upstairs ", "ùpstairs", "upstairs\u{2028}",
                      String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try store.load(account: label)) {
                XCTAssertEqual($0 as? PairingKeyStoreError, .invalidAccount)
            }
            XCTAssertThrowsError(try store.save(.generate(), account: label)) {
                XCTAssertEqual($0 as? PairingKeyStoreError, .invalidAccount)
            }
            XCTAssertThrowsError(try store.delete(account: label)) {
                XCTAssertEqual($0 as? PairingKeyStoreError, .invalidAccount)
            }
        }
        XCTAssertTrue(keychain.items.isEmpty)
        XCTAssertTrue(keychain.addAttributes.isEmpty)
        XCTAssertTrue(keychain.updateAttributes.isEmpty)
        XCTAssertEqual(keychain.deleteCount, 0)
    }

    func testOrdinaryLabelsAreAccepted() throws {
        let store = PairingKeyStore(service: service, keychain: FakeKeychain())
        for label in ["Upstairs Mac", "upstairs-mac", "mac_studio.1", String(repeating: "a", count: 128)] {
            XCTAssertNoThrow(try store.save(.generate(), account: label))
            XCTAssertNotNil(try store.load(account: label))
        }
    }

    func testDifferentAccountsAndServicesStayIsolated() throws {
        let keychain = FakeKeychain()
        let primary = PairingKeyStore(service: service, keychain: keychain)
        let other = PairingKeyStore(service: service + ".other", keychain: keychain)
        let key = PairingKey.generate()
        try primary.save(key, account: account)
        XCTAssertNil(try primary.load(account: "Laptop"))
        XCTAssertNil(try other.load(account: account))
        XCTAssertTrue(try XCTUnwrap(primary.load(account: account)).displayValue == key.displayValue)
    }
}

/// Single-threaded test storage. Records every attribute dictionary the store
/// passes in, so the tests can assert on accessibility and on what is *not*
/// stored. `@unchecked Sendable` is accurate here: these instances are created
/// and used on one test thread only.
private final class FakeKeychain: PairingKeychain, @unchecked Sendable {
    struct Entry: Hashable {
        let service: String
        let account: String
    }

    var items: [Entry: Data] = [:]
    var addAttributes: [[String: Any]] = []
    var updateAttributes: [[String: Any]] = []
    var deleteCount = 0
    /// When set, every primitive reports this status instead of succeeding.
    var forcedStatus: OSStatus?

    func addItem(_ attributes: [String: Any]) -> OSStatus {
        addAttributes.append(attributes)
        if let forcedStatus { return forcedStatus }
        guard let entry = Self.entry(attributes),
              let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        guard items[entry] == nil else { return errSecDuplicateItem }
        items[entry] = data
        return errSecSuccess
    }

    func copyItemData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        if let forcedStatus { return (forcedStatus, nil) }
        guard let entry = Self.entry(query) else { return (errSecParam, nil) }
        guard let data = items[entry] else { return (errSecItemNotFound, nil) }
        return (errSecSuccess, data)
    }

    func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        updateAttributes.append(attributes)
        if let forcedStatus { return forcedStatus }
        guard let entry = Self.entry(query) else { return errSecParam }
        guard items[entry] != nil else { return errSecItemNotFound }
        guard let data = attributes[kSecValueData as String] as? Data else { return errSecParam }
        items[entry] = data
        return errSecSuccess
    }

    func deleteItem(_ query: [String: Any]) -> OSStatus {
        deleteCount += 1
        if let forcedStatus { return forcedStatus }
        guard let entry = Self.entry(query) else { return errSecParam }
        guard items.removeValue(forKey: entry) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }

    private static func entry(_ attributes: [String: Any]) -> Entry? {
        guard let service = attributes[kSecAttrService as String] as? String,
              let account = attributes[kSecAttrAccount as String] as? String else { return nil }
        return Entry(service: service, account: account)
    }
}
