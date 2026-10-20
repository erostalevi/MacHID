import AppKit
import MacHIDDomain

/// A device drawing that passed every check, ready to show.
struct LoadedArtwork {
    let image: NSImage
    let layout: ArtworkLayout
}

enum ArtworkLoader {
    /// Reads `definition.artwork` from under `root`. The file is user data (it may come from a plugin), so it is checked
    /// again here: the path must stay inside `root` after resolving links, and the content must pass `SVGSafety`.
    static func load(for definition: DeviceDefinition, root: URL) -> LoadedArtwork? {
        guard let relative = definition.artwork, PluginManifest.isSafeRelativePath(relative) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let file = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(base.path + "/") else { return nil }
        guard let data = try? Data(contentsOf: file), SVGSafety.validate(data).isEmpty,
              let layout = ArtworkLayout.parse(data), let image = NSImage(data: data) else { return nil }
        return LoadedArtwork(image: image, layout: layout)
    }
}
