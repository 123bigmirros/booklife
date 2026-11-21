import XCTest
@testable import BookSlideCore

final class BluetoothPairingStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var vault: [String: String] = [:]
    private var locked = false
    private var rejectWrites = false
    override func setUp() {
        suite = "BookSlidePairingTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }
    private func store() -> BluetoothPairingStore {
        BluetoothPairingStore(defaults: defaults, read: { key in
            if self.locked { throw CocoaError(.fileReadNoPermission) }
            return self.vault[key]
        }, write: { key, value in
            if self.rejectWrites { throw CocoaError(.fileWriteNoPermission) }
            self.vault[key] = value
        })
    }
    private func record() -> BluetoothPairingStore.Record {
        .init(peripheralID: UUID(), connection: SavedConnection(receiverID: UUID(), name: "My Mac",
            endpoint: "http://mac.local:8765", token: String(repeating: "a", count: 32)))
    }
    func testRelaunchRestoresCompletePairingWithoutPairingWindow() throws {
        let original = record()
        try store().save(original)
        XCTAssertEqual(try store().load(), original)
        let hint = try XCTUnwrap(defaults.data(forKey: "directMacMetadata"))
        XCTAssertEqual(try JSONDecoder().decode(SavedConnection.self, from: hint).token, "")
        // Loss of non-secret hints cannot erase the actual pairing.
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(try store().load(), original)
    }
    func testIPadPairingPreservesDeviceKindAcrossRelaunchAndMetadata() throws {
        let original = BluetoothPairingStore.Record(peripheralID: UUID(), connection:
            SavedConnection(receiverID: UUID(), name: "iPad", endpoint: "http://bookslide-ipad.local:8765",
                            token: String(repeating: "b", count: 32), deviceKind: "ipad"))
        try store().save(original)
        XCTAssertEqual(try store().load(), original)
        let hint = try XCTUnwrap(defaults.data(forKey: "directMacMetadata"))
        let metadata = try JSONDecoder().decode(SavedConnection.self, from: hint)
        XCTAssertEqual(metadata.deviceKind, "ipad")
        XCTAssertEqual(metadata.token, "")
    }
    func testSwitchingBetweenMacAndIPadKeepsBothPairings() throws {
        let mac = record()
        let ipad = BluetoothPairingStore.Record(peripheralID: UUID(), connection: SavedConnection(
            receiverID: UUID(), name: "iPad", endpoint: "http://ipad.local:8765",
            token: String(repeating: "b", count: 32), deviceKind: "ipad"))
        try store().save(mac); try store().save(ipad)
        XCTAssertEqual(try store().load(), ipad)
        XCTAssertEqual(Set(try store().loadAll().map(\.peripheralID)), [mac.peripheralID, ipad.peripheralID])
        XCTAssertEqual(try store().select(mac.peripheralID), mac)
        XCTAssertEqual(try store().load(), mac)
        XCTAssertEqual(try store().select(ipad.peripheralID), ipad)
        XCTAssertTrue(store().rememberedDevices.allSatisfy { $0.connection.token.isEmpty })
    }
    func testFailedSelectionKeepsCurrentDeviceAndAllCredentials() throws {
        let mac = record(), other = record()
        try store().save(mac); try store().save(other)
        rejectWrites = true
        XCTAssertThrowsError(try store().select(mac.peripheralID))
        XCTAssertEqual(try store().load(), other)
        XCTAssertEqual(store().rememberedPeripheralID, other.peripheralID)
        XCTAssertEqual(try store().loadAll().count, 2)
    }
    func testBuild32RecordMigratesAndSurvivesMissingHints() throws {
        let mac = record()
        vault["direct-mac-record"] = String(decoding: try JSONEncoder().encode(mac), as: UTF8.self)
        XCTAssertEqual(try store().load(), mac)
        vault.removeValue(forKey: "direct-mac-record")
        defaults.removePersistentDomain(forName: suite)
        XCTAssertEqual(try store().loadAll(), [mac])
        XCTAssertEqual(try store().load(), mac)
    }
    func testReplacingPeripheralForSameReaderDoesNotDuplicateOrLoseOtherReader() throws {
        let mac = record(), ipad = record()
        try store().save(mac); try store().save(ipad)
        let replacement = BluetoothPairingStore.Record(peripheralID: UUID(), connection: ipad.connection)
        try store().save(replacement)
        XCTAssertEqual(try store().loadAll().count, 2)
        XCTAssertEqual(try store().load(), replacement)
        XCTAssertEqual(try store().select(mac.peripheralID), mac)
        XCTAssertThrowsError(try store().select(ipad.peripheralID))
        XCTAssertEqual(try store().load(), mac)
    }
    func testTemporaryKeychainLockDoesNotErasePairing() throws {
        let original = record()
        try store().save(original)
        locked = true
        XCTAssertThrowsError(try store().load())
        XCTAssertEqual(store().rememberedName, original.connection.name)
        locked = false
        XCTAssertEqual(try store().load(), original)
    }
    func testFailedReplacementKeepsPreviouslyTrustedMac() throws {
        let original = record()
        try store().save(original)
        rejectWrites = true
        XCTAssertThrowsError(try store().save(record()))
        XCTAssertEqual(try store().load(), original)
        XCTAssertEqual(store().rememberedPeripheralID, original.peripheralID)
    }
    func testBuild29PairingMigratesWithoutNewApproval() throws {
        let original = record(), c = original.connection
        let hint = SavedConnection(receiverID: c.receiverID, name: c.name, endpoint: c.endpoint, token: "")
        defaults.set(try JSONEncoder().encode(hint), forKey: "directMacMetadata")
        defaults.set(original.peripheralID.uuidString, forKey: "directMacPeripheral")
        vault["direct-mac-" + original.peripheralID.uuidString] = c.token
        XCTAssertEqual(try store().load(), original)
        vault.removeValue(forKey: "direct-mac-" + original.peripheralID.uuidString)
        XCTAssertEqual(try store().load(), original)
    }
    func testMigrationWriteFailureStillAllowsExistingConnection() throws {
        let original = record(), c = original.connection
        defaults.set(try JSONEncoder().encode(SavedConnection(receiverID: c.receiverID, name: c.name,
            endpoint: c.endpoint, token: "")), forKey: "directMacMetadata")
        defaults.set(original.peripheralID.uuidString, forKey: "directMacPeripheral")
        vault["direct-mac-" + original.peripheralID.uuidString] = c.token
        rejectWrites = true
        XCTAssertEqual(try store().load(), original)
    }
}
