import Foundation

/// All trusted readers and the selected reader commit together in Keychain.
/// UserDefaults contain only display hints, never credentials.
public final class BluetoothPairingStore {
    public struct Record: Codable, Equatable {
        public let peripheralID: UUID
        public let connection: SavedConnection
        public init(peripheralID: UUID, connection: SavedConnection) {
            self.peripheralID = peripheralID; self.connection = connection
        }
    }
    private struct Catalog: Codable {
        var selectedID: UUID
        var records: [Record]
        var selected: Record? { records.first { $0.peripheralID == selectedID } }
    }
    private let defaults: UserDefaults
    private let read: (String) throws -> String?
    private let write: (String, String) throws -> Void
    private let account = "direct-reader-catalog"
    public init(defaults: UserDefaults = .standard,
                read: @escaping (String) throws -> String? = { try PairingStore.load(account: $0) },
                write: @escaping (String, String) throws -> Void = { try PairingStore.save($1, account: $0) }) {
        self.defaults = defaults; self.read = read; self.write = write
    }
    public var rememberedName: String? {
        rememberedDevices.first { $0.peripheralID == rememberedPeripheralID }?.connection.name
    }
    public var rememberedPeripheralID: UUID? {
        defaults.string(forKey: "directMacPeripheral").flatMap(UUID.init(uuidString:))
    }
    public var rememberedDevices: [Record] {
        if let data = defaults.data(forKey: "directReaderMetadata"),
           let records = try? JSONDecoder().decode([Record].self, from: data) { return records }
        guard let id = rememberedPeripheralID,
              let data = defaults.data(forKey: "directMacMetadata"),
              let connection = try? JSONDecoder().decode(SavedConnection.self, from: data) else { return [] }
        return [Record(peripheralID: id, connection: connection)]
    }
    private func catalog() throws -> Catalog? {
        if let value = try read(account) {
            let catalog = try JSONDecoder().decode(Catalog.self, from: Data(value.utf8))
            guard catalog.selected != nil, catalog.records.allSatisfy({ $0.connection.isValid }),
                  Set(catalog.records.map(\.peripheralID)).count == catalog.records.count,
                  Set(catalog.records.map { $0.connection.receiverID }).count == catalog.records.count else {
                throw CocoaError(.coderInvalidValue)
            }
            return catalog
        }
        let old: Record
        if let value = try read("direct-mac-record") {
            old = try JSONDecoder().decode(Record.self, from: Data(value.utf8))
        } else {
            guard let hint = rememberedDevices.first else { return nil }
            guard let token = try read("direct-mac-" + hint.peripheralID.uuidString) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let c = hint.connection
            old = Record(peripheralID: hint.peripheralID, connection: SavedConnection(receiverID: c.receiverID,
                name: c.name, endpoint: c.endpoint, token: token, deviceKind: c.deviceKind))
        }
        guard old.connection.isValid else { throw CocoaError(.coderInvalidValue) }
        let migrated = Catalog(selectedID: old.peripheralID, records: [old])
        // A temporary migration write failure must not erase a trusted connection.
        try? commit(migrated)
        return migrated
    }
    public func load() throws -> Record? { try catalog()?.selected }
    public func loadAll() throws -> [Record] { try catalog()?.records ?? [] }
    public func select(_ peripheralID: UUID) throws -> Record {
        guard var catalog = try catalog(), let record = catalog.records.first(where: { $0.peripheralID == peripheralID }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        catalog.selectedID = peripheralID
        try commit(catalog)
        return record
    }
    public func save(_ record: Record) throws {
        guard record.connection.isValid else { throw CocoaError(.coderInvalidValue) }
        var records = try catalog()?.records ?? []
        records.removeAll { $0.peripheralID == record.peripheralID || $0.connection.receiverID == record.connection.receiverID }
        records.append(record)
        try commit(Catalog(selectedID: record.peripheralID, records: records))
    }
    private func commit(_ catalog: Catalog) throws {
        let data = try JSONEncoder().encode(catalog)
        try write(account, String(decoding: data, as: UTF8.self))
        let hints = catalog.records.map { record -> Record in
            let c = record.connection
            return Record(peripheralID: record.peripheralID, connection: SavedConnection(receiverID: c.receiverID,
                name: c.name, endpoint: c.endpoint, token: "", deviceKind: c.deviceKind))
        }
        defaults.set(try JSONEncoder().encode(hints), forKey: "directReaderMetadata")
        if let selected = hints.first(where: { $0.peripheralID == catalog.selectedID }) {
            defaults.set(try JSONEncoder().encode(selected.connection), forKey: "directMacMetadata")
            defaults.set(selected.peripheralID.uuidString, forKey: "directMacPeripheral")
        }
    }
}
