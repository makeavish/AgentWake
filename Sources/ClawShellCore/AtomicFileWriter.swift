import Darwin
import Foundation

enum AtomicFileWriter {
    static func write(
        _ data: Data,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directoryURL = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let temporaryURL = directoryURL.appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            defer {
                try? handle.close()
            }

            try handle.write(contentsOf: data)
            try handle.synchronize()

            if fileManager.fileExists(atPath: destinationURL.path) {
                _ = try fileManager.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: destinationURL)
            }

            fsyncDirectory(directoryURL)
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func fsyncDirectory(_ directoryURL: URL) {
        let descriptor = open(directoryURL.path, O_RDONLY)
        guard descriptor >= 0 else {
            return
        }

        _ = fsync(descriptor)
        _ = close(descriptor)
    }
}
