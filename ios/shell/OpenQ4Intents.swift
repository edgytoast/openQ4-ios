// OpenQ4Intents.swift — App Intents for both shells (charter Phase 1, "Deep
// links + App Intents"; D-112).
//
// Three intents, each a thin front onto the `openq4://` handler D-096 built:
// they do NOT reach into the engine themselves. Every one of them hands a URL
// string to OpenQ4_iOS_HandleURL(), so an intent and a link share one parser,
// one argument validator, one queue that waits until the engine is past init
// (and, on iOS, past onboarding), and one console gate. That is also why there
// is no "run a console command" intent: the console/<cmd> route is OTA-only,
// and an intent that could reach it would be a second door around that rule.
//
// openAppWhenRun: every intent needs the game in front of the player. The
// system launches (or foregrounds) the app and calls perform() in-process.
//
// Compiled into BOTH targets from ios/shell: the iOS target reaches the C
// handler through ios/shell/OpenQ4-Bridging-Header.h, the visionOS target
// through its own OpenQ4Vision-Bridging-Header.h, which already imports it.

import AppIntents
import Foundation

@available(iOS 16.0, visionOS 1.0, *)
struct OpenQ4PlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Quake 4"
    static var description = IntentDescription("Opens openQ4.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        OpenQ4_iOS_HandleURL("openq4://")
        return .result()
    }
}

@available(iOS 16.0, visionOS 1.0, *)
struct OpenQ4ContinueIntent: AppIntent {
    static var title: LocalizedStringResource = "Continue"
    static var description = IntentDescription("Loads your most recent save, or opens openQ4 if there is none.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        OpenQ4_iOS_HandleURL("openq4://continue")
        return .result()
    }
}

@available(iOS 16.0, visionOS 1.0, *)
struct OpenQ4LoadMapIntent: AppIntent {
    static var title: LocalizedStringResource = "Load Map"
    static var description = IntentDescription("Starts a map by name, for example game/airdefense1 or mp/q4dm1.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Map", requestValueDialog: "Which map?")
    var map: String

    @MainActor
    func perform() async throws -> some IntentResult {
        // The handler validates the characters (A-Za-z0-9._-/: only) and
        // refuses anything else with a log line; percent-encoding here only
        // keeps the URL well-formed on the way in.
        let trimmed = map.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        OpenQ4_iOS_HandleURL("openq4://map/\(encoded)")
        return .result()
    }
}

// Registers the three with Shortcuts and Spotlight at install time, with no
// setup by the player. Phrases must name the app; the map is asked for after.
@available(iOS 16.0, visionOS 1.0, *)
struct OpenQ4Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: OpenQ4PlayIntent(),
                    phrases: ["Play Quake 4 in \(.applicationName)",
                              "Play \(.applicationName)"])
        AppShortcut(intent: OpenQ4ContinueIntent(),
                    phrases: ["Continue in \(.applicationName)",
                              "Continue my game in \(.applicationName)"])
        AppShortcut(intent: OpenQ4LoadMapIntent(),
                    phrases: ["Load a map in \(.applicationName)"])
    }
}
