import Foundation

public enum MediaCache {
    public static func removeOldFiles(in directory: URL, keeping: URL?) {
        let keepPath = keeping?.resolvingSymlinksInPath().standardizedFileURL.path
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            // iOS can return /private/var from enumeration and /var from the source URL.
            if file.resolvingSymlinksInPath().standardizedFileURL.path != keepPath {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
