import Foundation

/// Keep one last readable snapshot so a damaged index cannot silently empty a library.
public struct LibraryIndexStore {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    private var primary: URL { directory.appendingPathComponent("library.json") }
    private var backup: URL { directory.appendingPathComponent("library.backup.json") }
    public func load<T: Decodable>(_ type: T.Type) throws -> (value: T, recovered: Bool)? {
        let fm = FileManager.default
        guard fm.fileExists(atPath:primary.path) || fm.fileExists(atPath:backup.path) else { return nil }
        do { return (try JSONDecoder().decode(type,from:Data(contentsOf:primary)),false) }
        catch {
            // A future schema is valid data, not a damaged file. Falling back
            // here could overwrite newer content with an older backup.
            if let graphError = error as? ReadingGraphError, case .unsupportedVersion = graphError { throw error }
            if let data = try? Data(contentsOf:backup), let value = try? JSONDecoder().decode(type,from:data) { return (value,true) }
            throw error
        }
    }
    public func save<T: Codable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let previous = try? Data(contentsOf:primary), (try? JSONDecoder().decode(T.self,from:previous)) != nil {
            try previous.write(to:backup,options:.atomic)
        } else if !FileManager.default.fileExists(atPath:backup.path) {
            try data.write(to:backup,options:.atomic)
        }
        try data.write(to:primary,options:.atomic)
    }
}
