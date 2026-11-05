import Foundation

/// Points the Vulkan loader at the bundled MoltenVK before mpv creates its Vulkan instance.
enum MoltenVK {
    /// Scripts/build_mpv.sh copies Homebrew's manifest into `Mpv.bundle/vulkan/MoltenVK_icd.json`. Its
    /// `library_path` is rewritten to the bundled dylib's absolute path in a copy in Caches (the bundle is
    /// signed and read-only), so nothing depends on how the loader resolves relative paths.
    /// False when it couldn't: then mpv would find no Vulkan driver, and the caller uses OpenGL.
    static func configure() -> Bool {
        if ProcessInfo.processInfo.environment["VK_DRIVER_FILES"] != nil { return true }   // set by hand, for debugging
        guard let mpv = Bundle.main.url(forResource: "Mpv", withExtension: "bundle") else { return false }
        let template = mpv.appending(path: "vulkan/MoltenVK_icd.json")
        let library = mpv.appending(path: "lib/libMoltenVK.dylib")
        guard let data = try? Data(contentsOf: template),
              var manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var icd = manifest["ICD"] as? [String: Any] else {
            NSLog("MoltenVK: no manifest at %@", template.path)
            return false
        }
        icd["library_path"] = library.path
        manifest["ICD"] = icd
        let out = URL.cachesDirectory.appending(path: "MoltenVK_icd.json")
        do {
            try JSONSerialization.data(withJSONObject: manifest).write(to: out, options: .atomic)
            setenv("VK_DRIVER_FILES", out.path, 1)
            return true
        } catch {
            NSLog("MoltenVK: can't write %@: %@", out.path, error.localizedDescription)
            return false
        }
    }
}
