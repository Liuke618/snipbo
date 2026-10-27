import Foundation

let usage = """
Usage:
  snipbo capture [--mode region|window|app-windows|screen|all|timed-region|timed-screen|timed-window|last|scrolling|scroll-horizontal|scroll-auto]
                 [--action editor|copy|save|pin] [--app <name>]
  snipbo capture --mode record-region|record-screen [--format mp4|gif]
  snipbo capture --mode record-stop|record-cancel
  snipbo settings
  snipbo history

Examples:
  snipbo capture --mode region --action copy
  snipbo capture --mode window --action editor
  snipbo history
"""

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func openURL(_ url: String) -> Never {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [url]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        fail("Could not launch Snipbo: \(error.localizedDescription)")
    }
    exit(process.terminationStatus)
}

var arguments = Array(CommandLine.arguments.dropFirst())
let knownModes: Set<String> = [
    "region", "window", "app-windows", "screen", "all", "timed-region",
    "timed-screen", "timed-window", "last", "scrolling",
    "scroll-horizontal", "scroll-auto", "record-region", "record-screen",
    "record-stop", "record-cancel",
]

guard let first = arguments.first else {
    openURL("snipbo://capture?mode=region")
}

switch first {
case "-h", "--help", "help":
    print(usage)
    exit(0)
case "settings":
    openURL("snipbo://settings")
case "history":
    openURL("snipbo://history")
case "capture":
    arguments.removeFirst()
default:
    // Allow `snipbo region`, `snipbo window`, etc.
    if knownModes.contains(first) {
        arguments.removeFirst()
    } else {
        // `snipbo` with an unknown positional token still defaults to region;
        // report it instead of silently ignoring a likely typo.
        fail("Unknown command: \(first)\n\n\(usage)")
    }
}

var mode = knownModes.contains(first) ? first : "region"
var action: String?
var format: String?
var appName: String?
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--mode", "-m":
        guard index + 1 < arguments.count else { fail("Missing value for --mode") }
        mode = arguments[index + 1]
        index += 2
    case "--action", "-a":
        guard index + 1 < arguments.count else { fail("Missing value for --action") }
        action = arguments[index + 1]
        index += 2
    case "--format", "-f":
        guard index + 1 < arguments.count else { fail("Missing value for --format") }
        format = arguments[index + 1]
        index += 2
    case "--app":
        guard index + 1 < arguments.count else { fail("Missing value for --app") }
        appName = arguments[index + 1]
        index += 2
    default:
        fail("Unknown option: \(arguments[index])\n\n\(usage)")
    }
}

guard knownModes.contains(mode) else {
    fail("Unknown mode: \(mode)\n\n\(usage)")
}

var components = URLComponents()
components.scheme = "snipbo"
components.host = "capture"
var items = [URLQueryItem(name: "mode", value: mode)]
if let action {
    items.append(URLQueryItem(name: "action", value: action))
}
if let format {
    items.append(URLQueryItem(name: "format", value: format))
}
if let appName {
    items.append(URLQueryItem(name: "app", value: appName))
}
components.queryItems = items
guard let url = components.url else {
    fail("Could not build the Snipbo URL.")
}
openURL(url.absoluteString)
