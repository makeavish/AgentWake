import Foundation

public struct ControlRuntimeStore {
    public let paths: ClawShellPaths
    public let fileManager: FileManager

    public init(paths: ClawShellPaths = .defaultPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func prepareRuntimeDirectory() throws {
        try fileManager.createDirectory(at: paths.runtimeDirectory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.runtimeDirectory.path)
    }

    public func rotateToken() throws -> String {
        try prepareRuntimeDirectory()
        let token = "\(UUID().uuidString)\(UUID().uuidString)"
        try Data(token.utf8).write(to: paths.hookTokenURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.hookTokenURL.path)
        return token
    }

    public func loadToken() throws -> String {
        try String(contentsOf: paths.hookTokenURL, encoding: .utf8)
    }

    public func clearRuntimeFiles() throws {
        try? fileManager.removeItem(at: paths.controlSocketURL)
        try? fileManager.removeItem(at: paths.hookTokenURL)
    }

    public func runtimeDirectoryMode() throws -> Int? {
        try permissionMode(at: paths.runtimeDirectory)
    }

    public func tokenFileMode() throws -> Int? {
        try permissionMode(at: paths.hookTokenURL)
    }

    public func socketFileMode() throws -> Int? {
        try permissionMode(at: paths.controlSocketURL)
    }

    private func permissionMode(at url: URL) throws -> Int? {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }

        return permissions.intValue & 0o777
    }
}
