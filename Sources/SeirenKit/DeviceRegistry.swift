import Foundation

/// Known Seiren models. The protocol is the same across the line (HID Feature
/// report to a Razer-audio vendor collection); only the PID and the captured
/// command bytes differ per model — so adding a model is just data.
public enum DeviceRegistry {
    /// Built-in models. Command tables are empty until captured.
    public static let builtins: [DeviceModel] = [
        DeviceModel(
            name: "Razer Seiren V3 Pro",
            pid: 0x058E,
            hidUsagePage: 0xFF53,
            commands: CommandTable(),
            notes: """
            HID interface 3, vendor usage page 0xFF53 (Razer audio), report 0x07, \
            Feature, 63 data bytes. Monitor command bytes not yet captured — see \
            docs/PROTOCOL.md and CONTRIBUTING.md.
            """
        ),
        // Community-captured models go here, or drop a JSON file in the
        // app-support devices directory (see `devicesDirectory()`):
        //   DeviceModel(name: "Razer Seiren V3 Mini",   pid: 0x056A, ...)
        //   DeviceModel(name: "Razer Seiren V3 Chroma", pid: 0x056F, ...)
    ]

    /// All known models: built-ins plus any user JSON overrides found in
    /// `~/Library/Application Support/seiren-mac/devices/*.json`. A user file
    /// with the same PID overrides the built-in (handy while capturing).
    public static func all() -> [DeviceModel] {
        var byPID: [UInt16: DeviceModel] = [:]
        for m in builtins { byPID[m.pid] = m }
        for m in loadUserModels() { byPID[m.pid] = m }
        return byPID.values.sorted { $0.name < $1.name }
    }

    public static func devicesDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("seiren-mac/devices", isDirectory: true)
    }

    static func loadUserModels() -> [DeviceModel] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: devicesDirectory(), includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = JSONDecoder()
        var models: [DeviceModel] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let model = try? decoder.decode(DeviceModel.self, from: data)
            else { continue }
            models.append(model)
        }
        return models
    }
}
