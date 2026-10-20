// Remembered pairing storage.
//
// One 128-bit pairing key per remembered device. macOS uses its encrypted login
// Keychain with a trusted-application ACL; visionOS uses the data-protection
// Keychain with ThisDeviceOnly accessibility. After reboot the Mac must be
// logged in and unlocked before it can share again. This supports dropped links — including when the headset is on
// another network and reaches this Mac over a VPN the owner already runs.
//
// Scope, stated plainly: retaining a key is the whole mechanism. This file adds
// no cryptography, no key agreement, no certificate chain, no rendezvous or relay
// service, and no network code of any kind. It also never reports whether a VPN
// is up; holding an address or a saved key says nothing about that.
//
// The store writes the raw secret and nothing else. No account label carries it,
// nothing reaches UserDefaults, and no success or failure path logs it.

import Foundation
import Security

/// A Keychain outcome the caller can act on. No case carries secret material.
/// A missing item is not represented here: `load` reports that as `nil`.
public enum PairingKeyStoreError: Error, Equatable, Sendable, LocalizedError {
    /// The saved-device label was empty, oversized, or not plain ASCII.
    case invalidAccount
    /// macOS refused access: the Keychain is locked, or a prompt was denied or cancelled.
    case accessDenied(OSStatus)
    /// This build is not signed with the entitlement needed to reach its own item.
    case notEntitled(OSStatus)
    /// An item exists for this account but is not a 128-bit pairing key.
    case unreadableItem
    /// Any other Security.framework failure, carried as its status for support reports.
    case keychainFailure(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidAccount:
            return "That saved-Mac name cannot be used. Use 1 to 128 plain characters with no line breaks, and no leading or trailing space."
        case let .accessDenied(status):
            return "macOS would not unlock the saved pairing key (Keychain status \(status)). Unlock this Mac, allow VisionDesk access to its keychain item, then try again."
        case let .notEntitled(status):
            return "This build of VisionDesk is not signed with the entitlement needed to reach its keychain item (Keychain status \(status)). Run a signed build, then pair again."
        case .unreadableItem:
            return "The saved pairing key is not readable. Forget this Mac and pair again to replace it."
        case let .keychainFailure(status):
            return "macOS could not read or write the saved pairing key (Keychain status \(status)). Try again, or forget this Mac and pair again."
        }
    }
}

/// The four Keychain primitives the store needs.
///
/// `SystemPairingKeychain` is the only implementation that touches a real
/// Keychain. Tests inject their own, so running the suite cannot add, change, or
/// remove an item in anyone's login keychain.
public protocol PairingKeychain: Sendable {
    func addItem(_ attributes: [String: Any]) -> OSStatus
    func copyItemData(_ query: [String: Any]) -> (status: OSStatus, data: Data?)
    func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func deleteItem(_ query: [String: Any]) -> OSStatus
}

/// Security.framework. The macOS backend uses an explicit signed-app ACL.
public struct SystemPairingKeychain: PairingKeychain {
    public init() {}

    public func addItem(_ attributes: [String: Any]) -> OSStatus {
        #if os(macOS)
        var attributes = attributes
        let (accessStatus, candidate) = Self.makeAccess()
        guard accessStatus == errSecSuccess, let access = candidate else { return accessStatus }
        attributes[kSecAttrAccess as String] = access
        return SecItemAdd(attributes as CFDictionary, nil)
        #else
        return SecItemAdd(attributes as CFDictionary, nil)
        #endif
    }

    public func copyItemData(_ query: [String: Any]) -> (status: OSStatus, data: Data?) {
        #if os(macOS)
        let (validation, itemRef) = Self.validatedItem(query)
        guard validation == errSecSuccess, let itemRef else { return (validation, nil) }
        // Read the validated object, never repeat a mutable service/account lookup.
        let query: [String: Any] = [kSecValueRef as String: itemRef, kSecReturnData as String: true]
        #endif
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return (status, nil) }
        // A match that is not raw data is a foreign item, not a key. Reporting nil
        // data here makes the store raise `unreadableItem` rather than guess.
        return (status, item as? Data)
    }

    public func updateItem(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        #if os(macOS)
        let (status, item) = Self.validatedItem(query)
        guard status == errSecSuccess, let item else { return status }
        // Its complete policy has already matched the policy we create. Preserve
        // that verified ACL; resetting an identical ChangeACL policy can prompt.
        return SecItemUpdate([kSecValueRef as String: item] as CFDictionary, attributes as CFDictionary)
        #else
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        #endif
    }

    #if os(macOS)
    static func makeAccess() -> (OSStatus, SecAccess?) {
        var application: SecTrustedApplication?
        let status = SecTrustedApplicationCreateFromPath(nil, &application)
        guard status == errSecSuccess, let application else { return (status, nil) }
        var access: SecAccess?
        let result = SecAccessCreate("VisionDesk remembered pairing" as CFString, [application] as CFArray, &access)
        return (result, access)
    }

    /// Labels are attacker-controlled. Compare the complete classic policy, including
    /// ChangeACL/owner entries and every operation, before requesting secret data.
    private static func validatedItem(_ query: [String: Any]) -> (OSStatus, SecKeychainItem?) {
        var lookup = query
        lookup.removeValue(forKey: kSecReturnData as String)
        lookup[kSecReturnRef as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        guard status == errSecSuccess else { return (status, nil) }
        guard let value, CFGetTypeID(value) == SecKeychainItemGetTypeID() else { return (errSecInvalidItemRef, nil) }
        let item = unsafeBitCast(value, to: SecKeychainItem.self)
        var actual: SecAccess?
        let accessStatus = SecKeychainItemCopyAccess(item, &actual)
        let (expectedStatus, expected) = makeAccess()
        guard accessStatus == errSecSuccess, expectedStatus == errSecSuccess,
              let actual, let expected, hasSamePolicy(actual, as: expected) else { return (errSecAuthFailed, nil) }
        return (errSecSuccess, item)
    }

    static func hasSamePolicy(_ actual: SecAccess, as expected: SecAccess) -> Bool {
        guard let actualPolicy = policy(actual), let expectedPolicy = policy(expected) else { return false }
        return actualPolicy == expectedPolicy
    }

    private struct Policy: Equatable {
        let user: uid_t
        let group: gid_t
        let owner: SecAccessOwnerType
        let entries: [String]
    }

    private static func policy(_ access: SecAccess) -> Policy? {
        var user: uid_t = 0
        var group: gid_t = 0
        var owner: SecAccessOwnerType = 0
        var list: CFArray?
        guard SecAccessCopyOwnerAndACL(access, &user, &group, &owner, nil) == errSecSuccess,
              SecAccessCopyACLList(access, &list) == errSecSuccess,
              let entries = list as? [SecACL] else { return nil }
        var result: [String] = []
        for entry in entries {
            var applications: CFArray?
            var description: CFString?
            var prompt: SecKeychainPromptSelector = []
            guard SecACLCopyContents(entry, &applications, &description, &prompt) == errSecSuccess else { return nil }
            var identities: [String] = []
            if let applications {
                guard let trusted = applications as? [SecTrustedApplication] else { return nil }
                for application in trusted {
                    var data: CFData?
                    guard SecTrustedApplicationCopyData(application, &data) == errSecSuccess, let data else { return nil }
                    identities.append((data as Data).base64EncodedString())
                }
            } else {
                identities.append("ANY_APPLICATION")
            }
            let authorizations = (SecACLCopyAuthorizations(entry) as NSArray).map { String(describing: $0) }.sorted()
            result.append("\(authorizations)|\(identities.sorted())|\(prompt.rawValue)")
        }
        return Policy(user: user, group: group, owner: owner, entries: result.sorted())
    }
    #endif

    public func deleteItem(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// Reads and writes the pairing key this Mac remembers for a saved device.
public struct PairingKeyStore: Sendable {
    public static let defaultService = "org.visiondesk.VisionDesk.pairing"

    /// Long enough for a device name a person would actually type.
    private static let maximumAccountLength = 128
    /// Stays on this device and never syncs, so a remembered key cannot follow the
    /// user's account onto hardware that was never paired.
    private static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    private let service: String
    private let keychain: any PairingKeychain

    public init(service: String = PairingKeyStore.defaultService) {
        self.init(service: service, keychain: SystemPairingKeychain())
    }

    /// Internal rather than `package`: the Xcode project compiles these sources as
    /// plain frameworks without `-package-name`, and `@testable import` already
    /// reaches this. Mirrors `DeskServer.startLoopback`.
    init(service: String = PairingKeyStore.defaultService, keychain: any PairingKeychain) {
        // The service is a build-time constant chosen by the developer, not user
        // input, so misuse fails loudly here instead of at every call site.
        precondition(Self.isValidLabel(service), "The Keychain service must be 1 to 128 plain ASCII characters.")
        self.service = service
        self.keychain = keychain
    }

    /// The key remembered for `account`, or `nil` when this Mac has never stored
    /// one. A missing item is an ordinary answer; a refused or unreadable one is an
    /// error, so "pair again" is never confused with "macOS said no".
    public func load(account: String) throws -> PairingKey? {
        var query = try baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = keychain.copyItemData(query)
        switch result.status {
        case errSecSuccess:
            guard let data = result.data, let key = PairingKey(keychainSecret: data) else {
                throw PairingKeyStoreError.unreadableItem
            }
            return key
        case errSecItemNotFound:
            return nil
        default:
            throw Self.failure(result.status)
        }
    }

    /// Remembers `key` for `account`, replacing any key already stored for it, so
    /// a saved device always maps to exactly one secret.
    public func save(_ key: PairingKey, account: String) throws {
        let query = try baseQuery(account: account)
        let value: [String: Any] = [
            kSecValueData as String: key.keychainSecret
        ]
        var changes = value
        #if !os(macOS)
        changes[kSecAttrAccessible as String] = Self.accessibility
        #endif
        let updated = keychain.updateItem(query, attributes: changes)
        switch updated {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw Self.failure(updated)
        }
        var attributes = query
        attributes.merge(changes) { _, new in new }
        let added = keychain.addItem(attributes)
        guard added == errSecSuccess else { throw Self.failure(added) }
    }

    /// Forgets the key for `account`. Forgetting a device that was never saved
    /// succeeds, so repeating the call is safe.
    public func delete(account: String) throws {
        let status = keychain.deleteItem(try baseQuery(account: account))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.failure(status)
        }
    }

    private func baseQuery(account: String) throws -> [String: Any] {
        guard Self.isValidLabel(account) else { throw PairingKeyStoreError.invalidAccount }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Backend choice is explicit at compile time, never an error fallback.
            // macOS login Keychain needs no provisioning profile and restricts the
            // credential to this signed application. visionOS uses its native group.
            kSecUseDataProtectionKeychain as String: Self.usesDataProtectionKeychain,
            kSecAttrSynchronizable as String: false
        ]
    }

    /// Bounded, printable ASCII with no edge whitespace. Keeps a pasted line break,
    /// an empty label, or an oversized string from reaching Security.framework as
    /// an attribute.
    private static func isValidLabel(_ value: String) -> Bool {
        guard (1...maximumAccountLength).contains(value.utf8.count),
              value.utf8.allSatisfy({ (0x20...0x7E).contains($0) }),
              value.first != " ", value.last != " " else { return false }
        return true
    }

    static var usesDataProtectionKeychain: Bool {
        #if os(macOS)
        return false
        #else
        return true
        #endif
    }

    private static func failure(_ status: OSStatus) -> PairingKeyStoreError {
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled:
            return .accessDenied(status)
        case errSecMissingEntitlement:
            return .notEntitled(status)
        default:
            return .keychainFailure(status)
        }
    }
}
