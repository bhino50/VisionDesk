import DeskCore
import Foundation
import XCTest

/// Parsing is textual only. Nothing here resolves a name, opens a socket, or
/// claims a VPN is up, and the type exposes no API that could: a saved address
/// proves only that someone typed something well formed.
final class RemoteMacAddressTests: XCTestCase {
    func testAcceptsTailscaleAddressesMagicDNSNamesAndLANHosts() throws {
        let cases: [(String, String, UInt16)] = [
            ("100.64.0.42", "100.64.0.42", RemoteMacAddress.defaultPort),
            ("100.64.0.42:7000", "100.64.0.42", 7_000),
            ("192.168.1.42", "192.168.1.42", RemoteMacAddress.defaultPort),
            ("127.0.0.1:1", "127.0.0.1", 1),
            ("example-mac", "example-mac", RemoteMacAddress.defaultPort),
            ("example-mac.tail-example.ts.net", "example-mac.tail-example.ts.net", RemoteMacAddress.defaultPort),
            ("example-mac.tail-example.ts.net:58271", "example-mac.tail-example.ts.net", 58_271),
            ("mac-mini.local", "mac-mini.local", RemoteMacAddress.defaultPort),
            ("Mac-Mini.Local:65535", "mac-mini.local", 65_535),
            ("host123.example.net", "host123.example.net", RemoteMacAddress.defaultPort),
            (" 100.64.0.42\t", "100.64.0.42", RemoteMacAddress.defaultPort)
        ]
        for (input, host, port) in cases {
            let address = try XCTUnwrap(RemoteMacAddress(string: input), "Expected \(input) to parse.")
            XCTAssertEqual(address.host, host)
            XCTAssertEqual(address.port, port)
        }
    }

    func testDefaultPortIsThePinnedRemotePort() {
        XCTAssertEqual(RemoteMacAddress.defaultPort, 58_271)
        XCTAssertEqual(RemoteMacAddress(string: "example-mac")?.port, 58_271)
        XCTAssertEqual(RemoteMacAddress(host: "example-mac")?.port, 58_271)
    }

    func testBracketedIPv6ParsesAndCanonicalizesToOneComparableForm() throws {
        let plain = try XCTUnwrap(RemoteMacAddress(string: "[fd7a:115c:a1e0::53]"))
        XCTAssertEqual(plain.host, "fd7a:115c:a1e0::53")
        XCTAssertEqual(plain.port, RemoteMacAddress.defaultPort)
        XCTAssertEqual(plain.formatted, "[fd7a:115c:a1e0::53]:58271")

        // Upper case and expanded zero groups are the same address.
        let expanded = try XCTUnwrap(RemoteMacAddress(string: "[FD7A:115C:A1E0:0000:0000:0000:0000:0053]"))
        XCTAssertEqual(expanded, plain)

        let withPort = try XCTUnwrap(RemoteMacAddress(string: "[::1]:7000"))
        XCTAssertEqual(withPort.host, "::1")
        XCTAssertEqual(withPort.port, 7_000)
        XCTAssertNotEqual(withPort, plain)
    }

    func testTrickyColonAndBracketFormsAreRejected() {
        let rejected = [
            "fd7a:115c:a1e0::53",       // bare IPv6: colons cannot be told from a port
            "::1",
            "[fd7a::1",                 // unterminated bracket
            "fd7a::1]",
            "[]",
            "[]:58271",
            "[fd7a::1]:",               // bracket with an empty port
            "[fd7a::1]58271",           // bracket and port with no separator
            "[fd7a::1]extra",
            "[[fd7a::1]]",
            "[mac.local]",              // brackets are for IPv6 only
            "[mac.local]:7000",
            "[127.0.0.1]",
            "mac.local:",
            "mac.local::7000",
            ":58271",
            ":",
            "mac.local:7000:7001",
            "[fd7a::1]:[7000]"
        ]
        for input in rejected {
            XCTAssertNil(RemoteMacAddress(string: input), "Expected \(input) to be rejected.")
        }
    }

    func testPortBoundsRejectZeroOverflowAndSloppyDigits() {
        for input in ["mac.local:0", "mac.local:00", "mac.local:0080", "mac.local:08",
                      "mac.local:65536", "mac.local:99999", "mac.local:123456",
                      "mac.local:-1", "mac.local:+80", "mac.local:8o", "mac.local: 80",
                      "mac.local:0x50", "[::1]:0"] {
            XCTAssertNil(RemoteMacAddress(string: input), "Expected \(input) to be rejected.")
        }
        XCTAssertEqual(RemoteMacAddress(string: "mac.local:1")?.port, 1)
        XCTAssertEqual(RemoteMacAddress(string: "mac.local:65535")?.port, 65_535)
    }

    func testSchemesPathsAndCredentialsAreRejected() {
        for input in ["http://mac.local", "https://mac.local:58271", "vnc://100.64.0.42",
                      "rustdesk://100.64.0.42", "//mac.local", "mac.local/",
                      "mac.local/desk", "mac.local?display=1", "mac.local#one",
                      "user@mac.local", "user:pass@mac.local", "mac.local\\share",
                      "mac.local:58271/path"] {
            XCTAssertNil(RemoteMacAddress(string: input), "Expected \(input) to be rejected.")
        }
    }

    func testWhitespaceLineBreaksAndNonASCIIAreRejected() {
        for input in ["", "   ", "\t", "mac.local\n", "mac.local\r\n", "\nmac.local",
                      "mac .local", "mac\t.local", "100.64.0.42 :7000",
                      "mac.local\u{0}", "mäc.local", "ｍac.local", "100.93.136.３9",
                      "mac.local\u{2028}", String(repeating: "a", count: 400)] {
            XCTAssertNil(RemoteMacAddress(string: input), "Expected \(input.debugDescription) to be rejected.")
        }
    }

    func testMalformedAddressLiteralsCannotPassAsHostNames() {
        for input in ["100.93.136", "1.2.3.4.5", "010.1.1.1", "1.2.3.256", "1.2.3.-4",
                      "256.256.256.256", "1..2.3.4", "12345", "0.0.0.0", "[::]",
                      "0.0.0.0:7000"] {
            XCTAssertNil(RemoteMacAddress(string: input), "Expected \(input) to be rejected.")
        }
    }

    func testHostNameSyntaxIsBoundedAndStrict() {
        for input in ["-mac.local", "mac-.local", "mac..local", ".mac.local", "mac.local.",
                      "mac_mini.local", "mac*.local", "mac!.local",
                      String(repeating: "a", count: 64) + ".local",
                      Array(repeating: String(repeating: "a", count: 50), count: 5).joined(separator: ".")] {
            XCTAssertNil(RemoteMacAddress(string: input), "Expected \(input) to be rejected.")
        }
        // A 63-character label and a name within 253 bytes are the documented limits.
        XCTAssertNotNil(RemoteMacAddress(string: String(repeating: "a", count: 63) + ".local"))
        let longest = Array(repeating: String(repeating: "a", count: 61), count: 4).joined(separator: ".") + ".net"
        XCTAssertEqual(longest.utf8.count, 251)
        XCTAssertNotNil(RemoteMacAddress(string: longest))
    }

    func testFormattedAlwaysShowsThePortAndRoundTrips() throws {
        for input in ["100.64.0.42", "100.64.0.42:7000", "example-mac",
                      "example-mac.tail-example.ts.net:58271", "mac-mini.local",
                      "[fd7a:115c:a1e0::53]", "[::1]:7000"] {
            let address = try XCTUnwrap(RemoteMacAddress(string: input))
            XCTAssertTrue(address.formatted.hasSuffix(":\(address.port)"))
            XCTAssertEqual(RemoteMacAddress(string: address.formatted), address, "\(input) did not round-trip.")
        }
        XCTAssertEqual(RemoteMacAddress(string: "example-mac")?.formatted, "example-mac:58271")
    }

    func testSeparatePartsInitializerMatchesStringParsing() throws {
        XCTAssertEqual(RemoteMacAddress(host: "Mac-Mini.Local", port: 7_000),
                       RemoteMacAddress(string: "mac-mini.local:7000"))
        // With the port supplied separately there is no ambiguity, so an IPv6
        // literal is accepted bare or bracketed.
        let bare = try XCTUnwrap(RemoteMacAddress(host: "fd7a::1", port: 7_000))
        XCTAssertEqual(bare, RemoteMacAddress(host: "[fd7a::1]", port: 7_000))
        XCTAssertEqual(bare, RemoteMacAddress(string: "[fd7a::1]:7000"))
        XCTAssertEqual(bare.formatted, "[fd7a::1]:7000")

        XCTAssertNil(RemoteMacAddress(host: "mac.local", port: 0))
        XCTAssertNil(RemoteMacAddress(host: "", port: 7_000))
        XCTAssertNil(RemoteMacAddress(host: "mac.local:7000"), "A host must not carry a port.")
        XCTAssertNil(RemoteMacAddress(host: "mac.local\n"))
        XCTAssertNil(RemoteMacAddress(host: "[]"))
    }

    func testEqualityComparesCanonicalHostAndPort() throws {
        let first = try XCTUnwrap(RemoteMacAddress(string: "EXAMPLE-MAC.ts.net:7000"))
        XCTAssertEqual(first, RemoteMacAddress(string: "example-mac.ts.net:7000"))
        XCTAssertNotEqual(first, RemoteMacAddress(string: "example-mac.ts.net:7001"))
        XCTAssertNotEqual(first, RemoteMacAddress(string: "example-mac.ts.net"))
        XCTAssertNotEqual(first, RemoteMacAddress(string: "laptop.ts.net:7000"))
    }

    func testParsingNeverResolvesTheName() throws {
        // A name that cannot resolve still parses: if parsing consulted DNS this
        // would fail or block. It is also why a parsed address never implies the
        // Mac is reachable, or that any VPN is connected.
        let unresolvable = "absent-\(UUID().uuidString.lowercased()).invalid"
        let address = try XCTUnwrap(RemoteMacAddress(string: unresolvable))
        XCTAssertEqual(address.host, unresolvable)
        XCTAssertEqual(address.port, RemoteMacAddress.defaultPort)
    }
}
