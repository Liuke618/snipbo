import Foundation

public enum ImageFileNaming {
    /// Returns a URL in `directory` for `preferredName`, appending `-2`, `-3`,
    /// ... before the extension when a file already exists.
    public static func uniqueURL(
        in directory: URL,
        preferredName: String,
        fileManager: FileManager = .default
    ) -> URL {
        guard !preferredName.isEmpty else {
            return directory.appendingPathComponent(preferredName)
        }
        let pathExtension = (preferredName as NSString).pathExtension
        let baseName = (preferredName as NSString).deletingPathExtension
        var candidate = preferredName
        var counter = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = pathExtension.isEmpty
                ? "\(baseName)-\(counter)"
                : "\(baseName)-\(counter).\(pathExtension)"
            counter += 1
        }
        return directory.appendingPathComponent(candidate)
    }
}
