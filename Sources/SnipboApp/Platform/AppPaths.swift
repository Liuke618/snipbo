import Foundation

enum AppPaths {
    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Snipbo", isDirectory: true)
    }

    static var historyDirectory: URL {
        applicationSupport.appendingPathComponent("History", isDirectory: true)
    }

    static var pinsDirectory: URL {
        applicationSupport.appendingPathComponent("Pins", isDirectory: true)
    }
}
