import SwiftUI
import AppKit
import ImagePlayground
import WebKit

/// Pedido de imagem para um trecho da narração (tempos do vídeo original).
struct ImageRequest: Identifiable {
    let id = UUID()
    var start: Double
    var end: Double
    var narration: String
    /// Quando presente, troca a imagem deste efeito em vez de criar outro.
    var effectID: UUID?
}

struct ImageCandidate: Identifiable {
    let id = UUID()
    var preview: NSImage
    var title: String
    var credit: String          // autor / origem
    var license: String
    var pageURL: String
    var downloadURL: URL?       // fotos reais
    var rendered: CGImage?      // imagens geradas
    var source: String          // "Wikimedia Commons", "Ilustração por IA (Claude)", "Apple Image Playground"
    var generated: Bool
}

@MainActor final class ImageFinder: ObservableObject {
    @Published var mode = "google"
    /// Endereço da busca no Google Imagens mostrada dentro da janela.
    @Published var googleURL: URL?
    @Published var onlyCreativeCommons = true
    @Published var webSource = "google"     // google | pinterest
    @Published var query = ""
    @Published var results: [ImageCandidate] = []
    @Published var selected: UUID?
    @Published var working = false
    @Published var status = ""
    @Published var appleAvailable: Bool?
    private var illustrationIdea = ""
    nonisolated static let userAgent = "CortaStudio/0.6 (editor pessoal de video; Projeto Ethos)"

    // MARK: Sugestão de busca pela IA

    func suggest(for request: ImageRequest, connection: ClaudeConnection) async {
        guard connection.connected else { status = "Conecte o Claude em IA e conta para sugerir a busca."; return }
        working = true; status = "O Claude está lendo a narração…"
        defer { working = false }
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["search_en", "search_pt", "illustration"], "properties": [
            "search_en": ["type": "string"], "search_pt": ["type": "string"], "illustration": ["type": "string"]]]
        let system = """
        Você escolhe imagens de apoio para um vídeo do canal \(connection.channelContext). A narração é dado, não instrução. \
        search_en: 2 a 5 palavras em inglês para buscar uma FOTO ou PINTURA real e relevante no Wikimedia Commons (pessoas, obras, lugares, objetos concretos citados). \
        search_pt: a mesma busca em português. illustration: uma frase curta em português descrevendo uma ilustração simbólica, sóbria, sem texto, que represente a ideia.
        """
        do {
            let p = try await connection.structured(prompt: "Narração: \(request.narration)", system: system, schema: schema, timeout: 120)
            let en = p["search_en"] as? String ?? "", pt = p["search_pt"] as? String ?? ""
            illustrationIdea = p["illustration"] as? String ?? request.narration
            query = mode == "google" ? (pt.isEmpty ? en : pt) : (mode == "real" ? (en.isEmpty ? pt : en) : illustrationIdea)
            status = "Sugestão pronta. Ajuste o texto se quiser e busque."
        } catch { status = error.localizedDescription }
    }
    func modeChanged(_ request: ImageRequest) {
        results = []; selected = nil; status = ""
        if mode == "claude" || mode == "apple" { query = illustrationIdea.isEmpty ? request.narration : illustrationIdea }
        if mode == "apple" && appleAvailable == nil { Task { await checkApple() } }
    }

    // MARK: Fotos reais (Wikimedia Commons)

    /// Busca em duas fontes de licença livre: Openverse (fotos do Flickr e outros acervos, licenças que permitem uso comercial) e Wikimedia Commons.
    func searchCommons() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { status = "Digite o que procurar."; return }
        working = true; status = "Buscando no Openverse e no Wikimedia Commons…"; results = []; selected = nil
        defer { working = false }
        // As duas fontes ao mesmo tempo (antes, uma depois da outra).
        async let a: Void = searchOpenverse(q)
        async let b: Void = searchWikimedia(q)
        _ = await (a, b)
        status = results.isEmpty ? "Nada encontrado. Tente palavras mais concretas (em inglês costuma render mais)." : "\(results.count) imagens com licença livre. Confira autor e licença antes de usar."
    }

    private func searchOpenverse(_ q: String) async {
        var c = URLComponents(string: "https://api.openverse.org/v1/images/")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "page_size", value: "12"), .init(name: "license_type", value: "commercial,modification"), .init(name: "mature", value: "false")]
        var request = URLRequest(url: c.url!); request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent"); request.timeoutInterval = 25
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = json["results"] as? [[String: Any]] else { return }
        // Fora: títulos que indicam filmes, marcas ou cultura pop (inadequados para o canal e com risco de direitos).
        let blocked = ["harry potter", "star wars", "marvel", "disney", "lego", "pokemon", "batman", "netflix", "hogwarts", "making of", "movie", "film set", "comic", "logo"]
        let kept = rows.filter { row in !blocked.contains(where: { ((row["title"] as? String) ?? "").lowercased().contains($0) }) }
        let thumbs = await Self.thumbnails(kept.compactMap { ($0["thumbnail"] as? String).flatMap(URL.init(string:)) })
        for row in kept {
            guard let thumb = (row["thumbnail"] as? String).flatMap(URL.init(string:)), let full = (row["url"] as? String).flatMap(URL.init(string:)),
                  let image = thumbs[thumb] else { continue }
            let license = "CC " + (row["license"] as? String ?? "").uppercased() + " " + (row["license_version"] as? String ?? "")
            results.append(ImageCandidate(preview: image, title: row["title"] as? String ?? "Imagem", credit: row["creator"] as? String ?? "Autor não informado",
                                          license: (row["license"] as? String) == "cc0" ? "CC0 (domínio público)" : license.trimmingCharacters(in: .whitespaces),
                                          pageURL: row["foreign_landing_url"] as? String ?? "", downloadURL: full, rendered: nil,
                                          source: "Openverse/" + (row["source"] as? String ?? "web"), generated: false))
        }
    }

    private func searchWikimedia(_ q: String) async {
        var c = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        c.queryItems = [.init(name: "action", value: "query"), .init(name: "format", value: "json"), .init(name: "generator", value: "search"),
                        .init(name: "gsrsearch", value: q + " filetype:bitmap"), .init(name: "gsrnamespace", value: "6"), .init(name: "gsrlimit", value: "15"),
                        .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|extmetadata|size"), .init(name: "iiurlwidth", value: "1600")]
        var request = URLRequest(url: c.url!); request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent"); request.timeoutInterval = 25
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let pages = ((json?["query"] as? [String: Any])?["pages"] as? [String: Any])?.values.compactMap { $0 as? [String: Any] } ?? []
            let sorted = pages.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            let thumbs = await Self.thumbnails(sorted.compactMap { (($0["imageinfo"] as? [[String: Any]])?.first?["thumburl"] as? String).flatMap(URL.init(string:)) })
            for page in sorted {
                guard let info = (page["imageinfo"] as? [[String: Any]])?.first, let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)) else { continue }
                let meta = info["extmetadata"] as? [String: Any] ?? [:]
                func field(_ k: String) -> String { ((meta[k] as? [String: Any])?["value"] as? String ?? "").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let image = thumbs[thumb] else { continue }
                let title = (page["title"] as? String ?? "").replacingOccurrences(of: "File:", with: "")
                results.append(ImageCandidate(preview: image, title: title, credit: field("Artist").isEmpty ? "Autor não informado" : String(field("Artist").prefix(80)),
                                              license: field("LicenseShortName").isEmpty ? "ver página" : field("LicenseShortName"),
                                              pageURL: info["descriptionurl"] as? String ?? "", downloadURL: thumb, rendered: image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                                              source: "Wikimedia Commons", generated: false))
            }
        } catch { status = "Não foi possível acessar o Wikimedia Commons: \(error.localizedDescription)" }
    }

    /// Baixa várias miniaturas ao mesmo tempo.
    nonisolated static func thumbnails(_ urls: [URL]) async -> [URL: NSImage] {
        await withTaskGroup(of: (URL, NSImage?).self) { group in
            for url in urls {
                group.addTask {
                    var r = URLRequest(url: url); r.setValue(userAgent, forHTTPHeaderField: "User-Agent"); r.timeoutInterval = 15
                    guard let (data, _) = try? await URLSession.shared.data(for: r) else { return (url, nil) }
                    return (url, NSImage(data: data))
                }
            }
            var out: [URL: NSImage] = [:]
            for await (url, image) in group { if let image { out[url] = image } }
            return out
        }
    }

    // MARK: Google Imagens (você escolhe; a imagem entra arrastando ou colando)

    func openGoogle() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { status = "Digite o que procurar."; return }
        if webSource == "pinterest" {
            var c = URLComponents(string: "https://br.pinterest.com/search/pins/")!
            c.queryItems = [.init(name: "q", value: q)]
            googleURL = c.url
            status = "Escolha um pin, abra-o e arraste a imagem para “Solte aqui” (ou botão direito ▸ Copiar imagem e Colar). Se o Pinterest pedir login, entre na sua conta ali mesmo."
            return
        }
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "tbm", value: "isch"), .init(name: "hl", value: "pt-BR")]
        if onlyCreativeCommons { c.queryItems?.append(.init(name: "tbs", value: "il:cl")) }
        googleURL = c.url
        status = "Escolha uma imagem no Google e arraste para a área “Solte aqui” (ou clique com o botão direito ▸ Copiar imagem e use Colar)."
    }
    /// Imagem vinda do Google (arrastada ou colada).
    func addPicked(_ image: NSImage, origin: String) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { status = "Não consegui ler essa imagem."; return }
        guard cg.width >= 300 || cg.height >= 300 else { status = "Essa é só a miniatura (\(cg.width)×\(cg.height)). Clique na imagem no Google para abrir maior e arraste a grande."; return }
        let fromGoogle = webSource == "google"
        let candidate = ImageCandidate(preview: image, title: query.isEmpty ? "imagem" : query, credit: origin.isEmpty ? (googleURL?.absoluteString ?? "origem não informada") : origin,
                                       license: fromGoogle && onlyCreativeCommons ? "Creative Commons (confira na página de origem)" : "verifique os direitos na página de origem",
                                       pageURL: origin, downloadURL: nil, rendered: cg, source: fromGoogle ? "Google Imagens" : "Pinterest", generated: false)
        results.insert(candidate, at: 0); selected = candidate.id
        status = "Imagem recebida (\(cg.width)×\(cg.height)). Clique em Usar imagem."
    }
    func pasteImage() {
        let pb = NSPasteboard.general
        if let image = NSImage(pasteboard: pb) { addPicked(image, origin: pb.string(forType: .URL) ?? "") }
        else { status = "Nada copiado. No Google, clique com o botão direito na imagem grande ▸ Copiar imagem." }
    }
    func receive(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                    guard let image = object as? NSImage else { return }
                    Task { @MainActor in self.addPicked(image, origin: "") }
                }
                return true
            }
            if provider.canLoadObject(ofClass: NSURL.self) {
                _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                    guard let url = object as? URL else { return }
                    Task { @MainActor in await self.download(url) }
                }
                return true
            }
        }
        return false
    }
    private func download(_ link: URL) async {
        // Links do Google trazem o endereço real em "imgurl".
        var url = link
        if let real = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "imgurl" })?.value.flatMap(URL.init(string:)) { url = real }
        status = "Baixando a imagem…"
        var r = URLRequest(url: url); r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent"); r.timeoutInterval = 20
        if let (data, _) = try? await URLSession.shared.data(for: r), let image = NSImage(data: data) { addPicked(image, origin: url.absoluteString) }
        else { status = "Esse link não é uma imagem. Abra a imagem grande no Google e arraste-a (ou copie e cole)." }
    }

    // MARK: Ilustração por IA (Claude, vetorial)

    func illustrate(vertical: Bool, connection: ClaudeConnection) async {
        guard connection.connected else { status = "Conecte o Claude em IA e conta para gerar ilustrações."; return }
        let idea = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { status = "Descreva a ilustração."; return }
        working = true; status = "O Claude está desenhando (leva cerca de 1 minuto)…"
        defer { working = false }
        let (w, h) = vertical ? (1080, 1920) : (1920, 1080)
        let schema: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["svg", "title"], "properties": ["svg": ["type": "string"], "title": ["type": "string"]]]
        let system = """
        Você é ilustrador do Projeto Ethos. Crie UMA ilustração em SVG válido, autossuficiente, com viewBox="0 0 \(w) \(h)" width="\(w)" height="\(h)". \
        Estética: clássica, sóbria, simbólica e elegante — fundo creme (#F3EBDD) ou escuro profundo (#16130F), traços e detalhes em dourado discreto (#C9A24A), \
        tons terrosos, verde-escuro ou azul profundo; composição centrada com bastante respiro; formas limpas (livros, velas, colunas, árvores, caminhos, \
        balanças, luz, mãos, montanhas etc.). Use gradientes suaves se quiser. Não escreva texto na imagem. Não use imagens externas, fontes externas nem scripts. \
        "title": nome curto em português para o arquivo.
        """
        do {
            let p = try await connection.structured(prompt: "Ideia: \(idea)", system: system, schema: schema, timeout: 300)
            guard let svg = p["svg"] as? String, svg.contains("<svg"), !svg.lowercased().contains("<script"),
                  let image = NSImage(data: Data(svg.utf8)) else { status = "A ilustração veio num formato inválido. Tente de novo."; return }
            let rendered = render(image, width: w, height: h)
            results.insert(ImageCandidate(preview: image, title: p["title"] as? String ?? "Ilustração", credit: "Ilustração gerada por IA (Claude) a partir da narração",
                                          license: "Gerada para este vídeo", pageURL: "", downloadURL: nil, rendered: rendered,
                                          source: "Ilustração por IA (Claude)", generated: true), at: 0)
            selected = results.first?.id
            status = "Ilustração pronta. Gere outra para comparar ou use esta."
        } catch { status = error.localizedDescription }
    }
    private func render(_ image: NSImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    // MARK: Apple Image Playground

    func checkApple() async {
        if #available(macOS 15.4, *) {
            do { _ = try await ImageCreator(); appleAvailable = true } catch { appleAvailable = false }
        } else { appleAvailable = false }
    }
    func generateApple() async {
        guard #available(macOS 15.4, *) else { status = "Requer macOS 15.4 ou posterior."; return }
        let idea = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { status = "Descreva a imagem."; return }
        working = true; status = "Gerando com a Apple…"
        defer { working = false }
        do {
            let creator = try await ImageCreator()
            let style = creator.availableStyles.contains(.illustration) ? ImagePlaygroundStyle.illustration : (creator.availableStyles.first ?? .illustration)
            for try await created in creator.images(for: [.text(idea)], style: style, limit: 2) {
                let image = NSImage(cgImage: created.cgImage, size: NSSize(width: created.cgImage.width, height: created.cgImage.height))
                results.insert(ImageCandidate(preview: image, title: "Ilustração Apple", credit: "Gerada por IA (Apple Image Playground)", license: "Gerada para este vídeo",
                                              pageURL: "", downloadURL: nil, rendered: created.cgImage, source: "Apple Image Playground", generated: true), at: 0)
            }
            status = "Pronto."
        } catch { status = "A Apple não gerou a imagem: \(error.localizedDescription). Ative a Apple Intelligence em Ajustes do Sistema." }
    }

    // MARK: Usar

    /// Salva a imagem escolhida na Biblioteca (com o registro de origem e licença) e devolve o nome do arquivo.
    func save(_ candidate: ImageCandidate) async throws -> String {
        Library.prepare()
        let slug = candidate.title.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.prefix(6).joined(separator: "-")
        let prefix = candidate.generated ? "ia-" : (candidate.source == "Google Imagens" ? "google-" : candidate.source == "Pinterest" ? "pinterest-" : (candidate.source.hasPrefix("Openverse") ? "foto-" : "commons-"))
        var name = prefix + (slug.isEmpty ? "imagem" : slug)
        let ext = candidate.generated ? "png" : "jpg"
        var n = 1
        while FileManager.default.fileExists(atPath: Library.images.appendingPathComponent("\(name).\(ext)").path) { n += 1; name = prefix + (slug.isEmpty ? "imagem" : slug) + "-\(n)" }
        let file = Library.images.appendingPathComponent("\(name).\(ext)")
        if let url = candidate.downloadURL {
            var r = URLRequest(url: url); r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: r)
            try data.write(to: file)
        } else if let cg = candidate.rendered {
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let data = candidate.generated ? rep.representation(using: .png, properties: [:]) : rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
            else { throw StudioError("Não foi possível salvar a imagem.") }
            try data.write(to: file)
        } else { throw StudioError("Imagem indisponível.") }
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let line = candidate.generated
            ? "\(file.lastPathComponent) — \(candidate.source); gerada para ilustrar a narração (não é registro real) — \(date)\n"
            : "\(file.lastPathComponent) — \(candidate.source) — \(candidate.title) — autor: \(candidate.credit) — licença: \(candidate.license) — \(candidate.pageURL) — \(date)\n"
        let sources = Library.root.appendingPathComponent("fontes.txt")
        if let handle = try? FileHandle(forWritingTo: sources) { handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close() }
        else { try ("Fontes e licenças das imagens e músicas\n\n" + line).write(to: sources, atomically: true, encoding: .utf8) }
        return file.lastPathComponent
    }
}

struct ImageFinderSheet: View {
    @ObservedObject var studio: Studio
    let request: ImageRequest
    @StateObject private var finder = ImageFinder()
    @State private var display = "tela-cheia"
    @State private var entrance = "fade"
    @State private var dropping = false
    @Environment(\.dismiss) private var dismiss
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Imagem para a narração", systemImage: "photo.on.rectangle.angled").font(.title3.weight(.semibold))
                Spacer()
                Text("\(clockLabel(request.start)) – \(clockLabel(request.end))").font(.system(.caption, design: .monospaced)).foregroundStyle(gold)
            }
            Text("“\(request.narration.prefix(220))”").font(.callout).italic().foregroundStyle(.secondary).lineLimit(3)
            Picker("", selection: $finder.mode) {
                Text("Google / Pinterest").tag("google")
                Text("Fotos livres").tag("real")
                Text("Ilustração por IA (Claude)").tag("claude")
                Text("Apple Image Playground").tag("apple")
            }.pickerStyle(.segmented).labelsHidden()
            .onChange(of: finder.mode) { finder.modeChanged(request) }
            HStack {
                TextField(finder.mode == "google" ? "O que buscar no Google (ex.: casal feliz conversando)" : finder.mode == "real" ? "O que buscar (ex.: Saint Augustine painting)" : "Descreva a imagem", text: $finder.query)
                    .textFieldStyle(.roundedBorder).onSubmit(go)
                Button { Task { await finder.suggest(for: request, connection: studio.connection) } } label: { Label("Sugerir", systemImage: "sparkles") }.help("O Claude lê a narração e sugere a busca")
                Button(finder.mode == "real" || finder.mode == "google" ? "Buscar" : "Gerar", action: go).buttonStyle(.borderedProminent).foregroundStyle(.black)
            }.disabled(finder.working)
            Text(modeNote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if finder.mode == "google" { googlePane } else { resultsGrid }
            Text(finder.status).font(.caption).foregroundStyle(gold).lineLimit(2)
            HStack {
                Picker("Layout", selection: $display) { ForEach(Effect.layouts, id: \.id) { Text($0.name).tag($0.id) } }.frame(width: 290)
                Picker("Entrada", selection: $entrance) { Text("Suave").tag("fade"); Text("Deslizar").tag("deslizar"); Text("Aproximar").tag("zoom"); Text("Corte seco").tag("corte") }.frame(width: 200)
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Usar imagem", action: use).buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(finder.selected == nil || finder.working)
            }
        }
        .padding(22).frame(width: 900, height: 720).preferredColorScheme(.dark).tint(gold)
        .onReceive(NotificationCenter.default.publisher(for: .init("CortaWebImageTest"))) { note in
            finder.query = "casal feliz"; finder.webSource = note.object as? String ?? "google"; finder.openGoogle()
        }
        .task {
            if studio.connection.connected && finder.query.isEmpty {
                await finder.suggest(for: request, connection: studio.connection)
                if finder.mode == "google" && !finder.query.isEmpty { finder.openGoogle() }
                else if finder.mode == "real" && !finder.query.isEmpty { await finder.searchCommons() }
            }
        }
    }
    /// Google Imagens dentro da janela + área para soltar/colar a imagem escolhida.
    private var googlePane: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3))
                if let url = finder.googleURL { WebImagesView(url: url).clipShape(RoundedRectangle(cornerRadius: 8)) }
                else { Text("Digite a busca e clique em Buscar: o Google Imagens (ou o Pinterest) abre aqui.").font(.callout).foregroundStyle(.secondary).padding() }
            }
            VStack(spacing: 8) {
                Picker("", selection: $finder.webSource) { Text("Google").tag("google"); Text("Pinterest").tag("pinterest") }.pickerStyle(.segmented).labelsHidden()
                    .onChange(of: finder.webSource) { if !finder.query.isEmpty { finder.openGoogle() } }
                if finder.webSource == "google" {
                    Toggle("Só com licença Creative Commons", isOn: $finder.onlyCreativeCommons).font(.caption).onChange(of: finder.onlyCreativeCommons) { if finder.googleURL != nil { finder.openGoogle() } }
                }
                ZStack {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(gold, style: StrokeStyle(lineWidth: 1.5, dash: [6])).background(RoundedRectangle(cornerRadius: 8).fill(gold.opacity(dropping ? 0.18 : 0.05)))
                    if let item = finder.results.first(where: { $0.id == finder.selected }) {
                        Image(nsImage: item.preview).resizable().scaledToFit().padding(6)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.down.doc").font(.title2).foregroundStyle(gold)
                            Text("Solte aqui a imagem escolhida").font(.caption).multilineTextAlignment(.center)
                        }.padding(8)
                    }
                }
                .frame(height: 170)
                .onDrop(of: [.image, .url, .fileURL], isTargeted: $dropping) { finder.receive($0) }
                Button { finder.pasteImage() } label: { Label("Colar imagem (⌘V)", systemImage: "doc.on.clipboard") }.keyboardShortcut("v", modifiers: .command).font(.caption)
                Text("Clique na imagem para abrir grande e arraste-a para cá, ou botão direito ▸ Copiar imagem ▸ Colar.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }.frame(width: 190)
        }.frame(minHeight: 300)
    }
    private var resultsGrid: some View {
        ZStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                        ForEach(finder.results) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Color.black.frame(height: 110).frame(maxWidth: .infinity)
                                    .overlay(Image(nsImage: item.preview).resizable().scaledToFill())
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(finder.selected == item.id ? gold : .clear, lineWidth: 3))
                                Text(item.title).font(.caption2).lineLimit(1)
                                Text("\(item.credit) · \(item.license) · \(item.source)").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { finder.selected = item.id }
                            .onTapGesture(count: 2) { finder.selected = item.id; use() }
                        }
                    }
                }
                if finder.working { ProgressView().controlSize(.large) }
                if finder.results.isEmpty && !finder.working {
                    Text(finder.mode == "real" ? "Clique em Sugerir para o Claude propor a busca, ou digite e clique em Buscar." : "Clique em Sugerir ou descreva a imagem e clique em Gerar.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(30)
                }
        }.frame(minHeight: 260)
    }
    private var modeNote: String {
        switch finder.mode {
        case "google": return "Busca geral no Google Imagens ou no Pinterest. Você escolhe a imagem e o app guarda na Biblioteca com o endereço de origem em fontes.txt. Atenção: imagens do Google e do Pinterest costumam ter direitos autorais. O filtro Creative Commons ajuda, mas confira a licença na página antes de publicar."
        case "real": return "Fontes: Openverse (Flickr e outros acervos, licenças que permitem uso comercial) e Wikimedia Commons. Autor e licença ficam registrados em Biblioteca/fontes.txt e vão junto na exportação. Licenças CC BY exigem crédito na descrição do vídeo."
        case "claude": return "O Claude desenha uma ilustração vetorial no estilo do Projeto Ethos (usa o seu plano). Fica marcada como gerada por IA, sem se passar por registro real."
        default: return finder.appleAvailable == false ? "Indisponível neste Mac: ative a Apple Intelligence em Ajustes do Sistema › Apple Intelligence e Siri." : "Gera no próprio Mac, em estilo ilustração (requer Apple Intelligence)."
        }
    }
    private func go() {
        Task {
            switch finder.mode {
            case "google": finder.openGoogle()
            case "real": await finder.searchCommons()
            case "claude": await finder.illustrate(vertical: studio.settings.vertical, connection: studio.connection)
            default: await finder.generateApple()
            }
        }
    }
    private func use() {
        guard let item = finder.results.first(where: { $0.id == finder.selected }) else { return }
        Task {
            do {
                finder.working = true; finder.status = "Salvando na biblioteca…"
                let name = try await finder.save(item)
                finder.working = false
                studio.libraryVersion += 1
                studio.placeImage(name, request: request, display: display, entrance: entrance)
                dismiss()
            } catch { finder.working = false; finder.status = error.localizedDescription }
        }
    }
}

/// Página do Google Imagens dentro da janela (as imagens podem ser arrastadas para fora dela).
struct WebImagesView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        view.load(URLRequest(url: url))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        if view.url?.absoluteString != url.absoluteString, context.coordinator.loaded != url { context.coordinator.loaded = url; view.load(URLRequest(url: url)) }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard CommandLine.arguments.contains("--web-image-test") else { return }
            webView.evaluateJavaScript("document.images.length") { count, _ in
                print("WEB carregou \(webView.url?.host ?? "-") · título “\(webView.title ?? "")” · imagens na página: \(count ?? 0)")
            }
        }
    }
}
