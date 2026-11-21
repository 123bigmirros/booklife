import Foundation

public enum ConnectionStore {
    /// Keep all paired targets so switching back never requires pairing again.
    public static func remembered() throws -> [SavedConnection] {
        let data = UserDefaults.standard.data(forKey: "pairedReadingTargets") ?? Data()
        let metadata = (try? JSONDecoder().decode([SavedConnection].self, from: data)) ?? []
        var result: [UUID: SavedConnection] = [:]
        for saved in metadata {
            guard let token = try PairingStore.load(account: "target-" + saved.receiverID.uuidString) else { continue }
            let connection = SavedConnection(receiverID: saved.receiverID, name: saved.name,
                endpoint: saved.endpoint, token: token, deviceKind: saved.deviceKind)
            if connection.isValid { result[connection.receiverID] = connection }
        }
        // Migrate existing installations without replacing their current target.
        if let library = try load() { result[library.receiverID] = library }
        if let remote = try loadRemote() { result[remote.receiverID] = remote }
        return result.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func remember(_ connection: SavedConnection) throws {
        guard connection.isValid else { throw CocoaError(.coderInvalidValue) }
        var connections = try remembered().filter { $0.receiverID != connection.receiverID }
        connections.append(connection)
        for saved in connections {
            try PairingStore.save(saved.token, account: "target-" + saved.receiverID.uuidString)
        }
        let metadata = connections.map { SavedConnection(receiverID: $0.receiverID, name: $0.name,
            endpoint: $0.endpoint, token: "", deviceKind: $0.deviceKind) }
        UserDefaults.standard.set(try JSONEncoder().encode(metadata), forKey: "pairedReadingTargets")
    }
    /// Remote control may target an iPad without replacing the Mac library source.
    public static func loadRemote() throws -> SavedConnection? {
        guard let data = UserDefaults.standard.data(forKey: "remoteReceiver"),
              let token = try PairingStore.load(account: "remote-receiver"),
              let saved = try? JSONDecoder().decode(SavedConnection.self, from: data) else { return try load() }
        let connection = SavedConnection(receiverID: saved.receiverID, name: saved.name,
            endpoint: saved.endpoint, token: token, deviceKind: saved.deviceKind)
        return connection.isValid ? connection : nil
    }
    public static func saveRemote(_ connection: SavedConnection) throws {
        guard connection.isValid else { throw CocoaError(.coderInvalidValue) }
        try remember(connection)
        try PairingStore.save(connection.token, account: "remote-receiver")
        let metadata = SavedConnection(receiverID: connection.receiverID, name: connection.name,
            endpoint: connection.endpoint, token: "", deviceKind: connection.deviceKind)
        UserDefaults.standard.set(try JSONEncoder().encode(metadata), forKey: "remoteReceiver")
    }
    public static func load() throws -> SavedConnection? {
        guard let token = try PairingStore.load(),
              let idString = UserDefaults.standard.string(forKey: "receiverID"), let id = UUID(uuidString: idString),
              let endpoint = UserDefaults.standard.string(forKey: "receiverURL"),
              let name = UserDefaults.standard.string(forKey: "receiverName") else { return nil }
        let connection = SavedConnection(receiverID: id, name: name, endpoint: endpoint, token: token)
        return connection.isValid ? connection : nil
    }
    public static func save(_ connection: SavedConnection) throws {
        guard connection.isValid else { throw CocoaError(.coderInvalidValue) }
        try PairingStore.save(connection.token)
        UserDefaults.standard.set(connection.endpoint, forKey: "receiverURL")
        UserDefaults.standard.set(connection.receiverID.uuidString, forKey: "receiverID")
        UserDefaults.standard.set(connection.name, forKey: "receiverName")
    }
}
