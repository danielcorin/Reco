import Foundation

enum CLIInstaller {
    enum InstallerError: LocalizedError {
        case bundledCLIMissing
        case destinationOccupied(String)

        var errorDescription: String? {
            switch self {
            case .bundledCLIMissing:
                "The bundled reco CLI is missing. Rebuild or reinstall Reco."
            case .destinationOccupied(let path):
                "A file already exists at \(path). Move it before installing Reco's CLI."
            }
        }
    }

    static var destinationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("reco")
    }

    static var bundledCLIURL: URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("reco")
    }

    static var isInstalled: Bool {
        guard
            let destination = try? FileManager.default.destinationOfSymbolicLink(
                atPath: destinationURL.path
            )
        else { return false }
        return URL(fileURLWithPath: destination).standardizedFileURL
            == bundledCLIURL.standardizedFileURL
    }

    static func install() throws -> URL {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: bundledCLIURL.path) else {
            throw InstallerError.bundledCLIMissing
        }

        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let exists =
            fileManager.fileExists(atPath: destinationURL.path)
            || ((try? destinationURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
        if exists {
            if isInstalled { return destinationURL }
            throw InstallerError.destinationOccupied(destinationURL.path)
        }

        try fileManager.createSymbolicLink(
            at: destinationURL,
            withDestinationURL: bundledCLIURL
        )
        return destinationURL
    }
}
