import Foundation

/// The user-owned wallpaper store format used by the macOS 26 aerial renderer.
enum AerialConfiguration {
    static func selecting(_ assetID: String, in original: [String: Any], now: Date = Date()) throws -> [String: Any] {
        guard UUID(uuidString: assetID) != nil else { throw CocoaError(.fileReadCorruptFile) }
        let configuration = try PropertyListSerialization.data(fromPropertyList: ["assetID": assetID], format: .binary, options: 0)
        let choice: [String: Any] = ["Provider": "com.apple.wallpaper.choice.aerials", "Files": [Any](), "Configuration": configuration]
        let entry: [String: Any] = ["Type": "linked", "Linked": ["Content": ["Choices": [choice]], "LastSet": now, "LastUse": now]]
        var result = original
        result["SystemDefault"] = entry
        result["AllSpacesAndDisplays"] = entry
        if var displays = result["Displays"] as? [String: Any] {
            for id in displays.keys { displays[id] = entry }
            result["Displays"] = displays
        }
        if var spaces = result["Spaces"] as? [String: Any] {
            for id in spaces.keys {
                guard var space = spaces[id] as? [String: Any] else { continue }
                space["Default"] = entry
                if var displays = space["Displays"] as? [String: Any] {
                    for displayID in displays.keys { displays[displayID] = entry }
                    space["Displays"] = displays
                }
                spaces[id] = space
            }
            result["Spaces"] = spaces
        }
        return result
    }

    static func assetID(in entry: Any?) -> String? {
        guard let entry = entry as? [String: Any] else { return nil }
        for key in ["Linked", "Desktop", "Idle"] {
            guard let section = entry[key] as? [String: Any],
                  let content = section["Content"] as? [String: Any],
                  let choices = content["Choices"] as? [[String: Any]],
                  let choice = choices.first,
                  choice["Provider"] as? String == "com.apple.wallpaper.choice.aerials",
                  let data = choice["Configuration"] as? Data,
                  let configuration = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = configuration["assetID"] as? String else { continue }
            return id
        }
        return nil
    }

    static func restoring(_ original: [String: Any], in current: [String: Any], slotID: String) -> [String: Any] {
        var result = current
        func restored(_ entry: Any?, previous: Any?) -> Any? {
            assetID(in: entry) == slotID ? (previous ?? original["SystemDefault"]) : entry
        }
        for key in ["SystemDefault", "AllSpacesAndDisplays"] {
            result[key] = restored(result[key], previous: original[key])
        }
        if var displays = result["Displays"] as? [String: Any] {
            let previous = original["Displays"] as? [String: Any] ?? [:]
            for id in displays.keys { displays[id] = restored(displays[id], previous: previous[id]) }
            result["Displays"] = displays
        }
        if var spaces = result["Spaces"] as? [String: Any] {
            let previousSpaces = original["Spaces"] as? [String: Any] ?? [:]
            for id in spaces.keys {
                guard var space = spaces[id] as? [String: Any] else { continue }
                let previous = previousSpaces[id] as? [String: Any] ?? [:]
                space["Default"] = restored(space["Default"], previous: previous["Default"])
                if var displays = space["Displays"] as? [String: Any] {
                    let previousDisplays = previous["Displays"] as? [String: Any] ?? [:]
                    for displayID in displays.keys { displays[displayID] = restored(displays[displayID], previous: previousDisplays[displayID]) }
                    space["Displays"] = displays
                }
                spaces[id] = space
            }
            result["Spaces"] = spaces
        }
        return result
    }
}
