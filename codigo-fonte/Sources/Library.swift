import Foundation
import AppKit

/// Biblioteca de materiais do usuário: imagens de apoio, músicas e identidade visual.
/// Fica ao lado do código (pasta Biblioteca), definida pelo build.sh.
enum Library {
    static let imageTypes: Set<String> = ["jpg", "jpeg", "png", "heic", "tif", "tiff", "webp"]
    static let audioTypes: Set<String> = ["mp3", "m4a", "wav", "aif", "aiff", "caf"]
    static let videoTypes: Set<String> = ["mp4", "mov", "m4v"]

    static var root: URL {
        if let custom = UserDefaults.standard.string(forKey: "CortaLibraryPath") { return URL(fileURLWithPath: custom, isDirectory: true) }
        let appFolder = Bundle.main.bundleURL.deletingLastPathComponent()
        if appFolder.lastPathComponent == "app" { return appFolder.deletingLastPathComponent().appendingPathComponent("Biblioteca", isDirectory: true) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Corta Studio/Biblioteca", isDirectory: true)
    }
    static var images: URL { root.appendingPathComponent("Imagens", isDirectory: true) }
    static var music: URL { root.appendingPathComponent("Musicas", isDirectory: true) }
    static var brand: URL { root.appendingPathComponent("Marca", isDirectory: true) }
    static var videos: URL { root.appendingPathComponent("Videos", isDirectory: true) }
    static var videoNames: [String] { files(in: videos, types: videoTypes) }

    static func prepare() {
        for folder in [images, music, brand, videos] { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let notes = root.appendingPathComponent("LEIA-ME.txt")
        if !FileManager.default.fileExists(atPath: notes.path) {
            try? """
            Biblioteca do Corta Studio

            Imagens/  fotos, pinturas e ilustrações que a IA pode usar como imagens de apoio. Dê nomes descritivos
                      (ex.: "biblioteca-antiga.jpg", "santo-agostinho-pintura.jpg"): a IA escolhe pelo nome.
            Musicas/  trilhas de fundo com licença para uso (ex.: Biblioteca de Áudio do YouTube).
            Marca/    coloque aqui "logo.png" (fundo transparente) para a marca d'água.

            Registre a origem e a licença de cada arquivo em "fontes.txt" nesta pasta. O Corta Studio copia esse
            registro para cada exportação.
            """.write(to: notes, atomically: true, encoding: .utf8)
        }
    }
    /// Listagens recentes: a interface pede os nomes a cada redesenho, e ler a pasta (no iCloud) toda vez travava a tela.
    nonisolated(unsafe) private static var listings: [String: (time: Date, names: [String])] = [:]
    private static let lock = NSLock()
    static func invalidate() { lock.lock(); listings = [:]; lock.unlock() }
    static func files(in folder: URL, types: Set<String>) -> [String] {
        let key = folder.path + "|" + types.sorted().joined(separator: ",")
        lock.lock()
        if let cached = listings[key], Date().timeIntervalSince(cached.time) < 4 { lock.unlock(); return cached.names }
        lock.unlock()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { types.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        lock.lock(); listings[key] = (Date(), names); lock.unlock()
        return names
    }
    static var imageNames: [String] { files(in: images, types: imageTypes) }
    static var musicNames: [String] { files(in: music, types: audioTypes) }
    static var logo: URL? {
        files(in: brand, types: imageTypes).first { $0.lowercased().hasPrefix("logo") }.map { brand.appendingPathComponent($0) }
            ?? files(in: brand, types: imageTypes).first.map { brand.appendingPathComponent($0) }
    }
    /// Resolve um nome da biblioteca sem permitir sair da pasta.
    static func file(_ name: String, in folder: URL) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != "..", name != "." else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    static func add(to folder: URL, types: Set<String>, message: String) {
        prepare()
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.message = message
        panel.allowedFileTypes = Array(types)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let target = folder.appendingPathComponent(url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) { try? FileManager.default.copyItem(at: url, to: target) }
        }
        invalidate()
    }
    static func reveal() { prepare(); NSWorkspace.shared.open(root) }
}
