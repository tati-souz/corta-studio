import SwiftUI
import AVFoundation

// MARK: Aba Cortes — gerador de cortes com IA (procura por tema, duração, trecho, nota de potencial, texto do post)

struct ClipsPanel: View {
    @ObservedObject var studio: Studio
    @State private var showFinder = true
    @State private var sort = "nota"
    @State private var onlyFavorites = false
    @State private var expanded: UUID?
    @State private var renaming: UUID?
    @State private var newTitle = ""
    @State private var confirmDelete: ClipSuggestion?
    private let accent = Color(red: 0.83, green: 0.66, blue: 0.29)
    private let surface = Color.white.opacity(0.05)
    private let canvas = Color(red: 0.06, green: 0.06, blue: 0.055)

    private var shown: [ClipSuggestion] {
        let list = onlyFavorites ? studio.clips.filter(\.favorite) : studio.clips
        return sort == "nota" ? list.sorted { $0.score > $1.score } : list.sorted { $0.startID < $1.startID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Gerador de cortes").font(.system(size: 15, weight: .medium, design: .serif))
                Spacer()
                Button { withAnimation { showFinder.toggle() } } label: { Label(showFinder ? "Ocultar opções" : "Opções de busca", systemImage: "slider.horizontal.3") }.font(.caption).buttonStyle(.borderless)
            }
            if showFinder { finder }
            if !studio.clips.isEmpty {
                HStack(spacing: 8) {
                    Picker("", selection: $sort) { Text("Maior nota").tag("nota"); Text("Ordem do vídeo").tag("tempo") }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    Toggle(isOn: $onlyFavorites) { Image(systemName: "star.fill") }.toggleStyle(.button).help("Mostrar só os favoritos")
                    Spacer()
                    Text("\(studio.clips.count) cortes").font(.caption2).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    if studio.source != nil { mainCard }
                    ForEach(shown) { clip in card(clip) }
                }
            }
            if !studio.clips.isEmpty {
                HStack {
                    Button { studio.exportAllClips() } label: { Label("Exportar todos", systemImage: "square.and.arrow.up.on.square").frame(maxWidth: .infinity) }
                    Button { studio.exportAllClips(onlyFavorites: true) } label: { Label("Exportar favoritos (\(studio.clips.filter(\.favorite).count))", systemImage: "star").frame(maxWidth: .infinity) }
                        .disabled(!studio.clips.contains(where: \.favorite))
                }.buttonStyle(.bordered).disabled(studio.busy)
                Text("Cada corte sai com as suas edições, as legendas (.srt/.vtt) e um .txt com título, texto do post e hashtags.").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .onAppear { if !studio.clips.isEmpty { showFinder = false } }
        .alert("Apagar este corte?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Apagar", role: .destructive) { if let c = confirmDelete { studio.deleteClip(c.id) }; confirmDelete = nil }
            Button("Cancelar", role: .cancel) { confirmDelete = nil }
        } message: { Text("O vídeo original não é alterado; só a sugestão (e as edições feitas nela) saem da lista.") }
    }

    // MARK: Busca

    private var finder: some View {
        let duration = studio.media?.duration ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Procurar por (opcional): ex. “momentos sobre paciência”, “histórias pessoais”", text: $studio.clipOptions.prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            Picker("Duração", selection: $studio.clipOptions.length) { ForEach(ClipFinderOptions.lengths, id: \.id) { Text($0.name).tag($0.id) } }
            Picker("Conteúdo", selection: $studio.clipOptions.genre) { ForEach(ClipFinderOptions.genres, id: \.self) { Text($0) } }
            if duration > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Trecho analisado").font(.caption)
                        Spacer()
                        Text("\(clockLabel(studio.clipOptions.rangeStart)) – \(clockLabel(studio.clipOptions.rangeEnd > 0 ? studio.clipOptions.rangeEnd : duration))").font(.caption.monospacedDigit()).foregroundStyle(accent)
                    }
                    Slider(value: Binding(get: { studio.clipOptions.rangeStart }, set: { studio.clipOptions.rangeStart = min($0, (studio.clipOptions.rangeEnd > 0 ? studio.clipOptions.rangeEnd : duration) - 10) }), in: 0...max(1, duration)) { Text("De").font(.caption2) }
                    Slider(value: Binding(get: { studio.clipOptions.rangeEnd > 0 ? studio.clipOptions.rangeEnd : duration }, set: { studio.clipOptions.rangeEnd = $0 >= duration - 0.5 ? 0 : max($0, studio.clipOptions.rangeStart + 10) }), in: 0...max(1, duration)) { Text("Até").font(.caption2) }
                }
            }
            Picker("Visual dos cortes", selection: $studio.clipOptions.template) { ForEach(ClipSuggestion.templates, id: \.id) { Text($0.name).tag($0.id) } }
            Toggle("Gancho escrito nos primeiros segundos", isOn: $studio.clipOptions.showHook)
            Toggle("Gancho em vídeo: abrir com o ápice do corte e voltar ao começo", isOn: $studio.clipOptions.videoHook)
            HStack {
                Stepper("\(studio.clipOptions.count) cortes", value: $studio.clipOptions.count, in: 1...20).font(.caption)
                Spacer()
                Button { studio.suggestClips(count: studio.clipOptions.count) } label: { Label("Encontrar cortes", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).foregroundStyle(canvas)
            }.disabled(studio.source == nil || studio.busy)
            Text("A IA lê a transcrição, escolhe trechos que se sustentam sozinhos e dá uma nota de 0 a 99 (gancho, fluxo, valor e atualidade). Os cortes que você já editou são mantidos.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout).padding(10).background(surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Cartões

    private var mainCard: some View {
        let isMain = studio.activeClipID == nil
        return HStack {
            Image(systemName: "film").foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Vídeo completo").font(.callout.weight(.semibold))
                Text(isMain ? "Aberto no editor" : "Clique para voltar a ele").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if isMain { badge("NA TELA", filled: true) }
        }
        .padding(10).background(surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(isMain ? accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle()).onTapGesture { if !studio.busy { studio.openMainVideo() } }
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 75 ? Color(red: 0.45, green: 0.80, blue: 0.50) : score >= 55 ? accent : Color.gray
    }
    private func badge(_ text: String, filled: Bool) -> some View {
        Text(text).font(.system(size: 9, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 3)
            .background(filled ? accent : .clear, in: Capsule()).overlay(Capsule().stroke(accent)).foregroundStyle(filled ? canvas : accent)
    }

    private func card(_ clip: ClipSuggestion) -> some View {
        let open = clip.id == studio.activeClipID
        let edited = studio.clipWasEdited(clip)
        let isExpanded = expanded == clip.id
        let span = studio.clipSpan(clip)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                ClipThumb(url: studio.source, time: (span?.start ?? 0) + 0.6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        if renaming == clip.id {
                            TextField("Título", text: $newTitle, onCommit: { studio.updateClip(clip.id) { $0.title = newTitle.isEmpty ? $0.title : newTitle }; renaming = nil })
                                .textFieldStyle(.roundedBorder).font(.callout)
                        } else {
                            Text(clip.title).font(.callout.weight(.semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button { studio.updateClip(clip.id) { $0.favorite.toggle() } } label: { Image(systemName: clip.favorite ? "star.fill" : "star") }
                            .buttonStyle(.borderless).foregroundStyle(clip.favorite ? accent : .secondary).help("Favorito")
                    }
                    HStack(spacing: 6) {
                        if clip.score > 0 {
                            Text("\(clip.score)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(canvas)
                                .padding(.horizontal, 7).padding(.vertical, 2).background(scoreColor(clip.score), in: Capsule()).help("Nota de potencial (0–99)")
                        }
                        if let span { Text("\(clockLabel(span.start)) · \(Int(span.end - span.start)) s").font(.system(.caption2, design: .monospaced)).foregroundStyle(accent) }
                        if !clip.topic.isEmpty { Text(clip.topic).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(surface, in: Capsule()) }
                    }
                    HStack(spacing: 4) {
                        if open { badge("NA TELA", filled: true) }
                        if edited { badge("editado", filled: false) }
                        if clip.useVideoHook && clip.videoHook != nil { badge("▶ GANCHO", filled: false).help("Abre com um momento forte do corte e volta ao começo") }
                    }
                    Text("“\(clip.hook)”").font(.caption).italic().lineLimit(isExpanded ? nil : 2)
                }
            }
            if isExpanded { details(clip) }
            HStack(spacing: 10) {
                if !open { Button { studio.openClip(clip) } label: { Label("Abrir", systemImage: "pencil") } }
                Button { studio.exportClip(clip) } label: { Label("Exportar", systemImage: "square.and.arrow.up") }
                Button { studio.copyPost(clip) } label: { Label("Copiar post", systemImage: "doc.on.doc") }.disabled(clip.caption.isEmpty && clip.hashtags.isEmpty)
                Spacer()
                Button { withAnimation { expanded = isExpanded ? nil : clip.id } } label: { Label(isExpanded ? "Menos" : "Mais", systemImage: isExpanded ? "chevron.up" : "chevron.down") }
            }.font(.caption).buttonStyle(.borderless).disabled(studio.busy)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(open ? accent : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { if !studio.busy { studio.openClip(clip) } }
        .contextMenu {
            Button("Abrir no editor") { studio.openClip(clip) }
            Button("Renomear") { newTitle = clip.title; renaming = clip.id }
            Button(clip.favorite ? "Tirar dos favoritos" : "Favoritar") { studio.updateClip(clip.id) { $0.favorite.toggle() } }
            Button("Montar Reels Ethos neste corte") { studio.openClip(clip); studio.requestedTab = "Reels" }
            Button("Copiar texto do post") { studio.copyPost(clip) }
            Divider()
            if edited { Button("Desfazer edições deste corte") { studio.revertClip(clip) } }
            Button("Apagar corte", role: .destructive) { confirmDelete = clip }
        }
        .help(open ? "Este corte está aberto no editor" : "Clique para abrir este corte no editor; botão direito para mais opções")
    }

    private func details(_ clip: ClipSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !clip.scores.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(ClipSuggestion.scoreParts, id: \.id) { part in
                        let v = clip.scores[part.id] ?? 0
                        HStack(spacing: 6) {
                            Text(part.name).font(.caption2).frame(width: 64, alignment: .leading)
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.08))
                                    Capsule().fill(scoreColor(v * 4)).frame(width: g.size.width * CGFloat(v) / 25)
                                }
                            }.frame(height: 5)
                            Text("\(v)/25").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        }.help(part.help)
                    }
                    Text("Atualidade é uma estimativa da IA (ela não consulta a internet).").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            if !clip.reason.isEmpty { Text(clip.reason).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            // Início e fim em frases inteiras
            HStack(spacing: 6) {
                Text("Início").font(.caption2)
                Button { studio.adjustClip(clip.id, start: -1) } label: { Image(systemName: "backward.end") }.help("Começar uma frase antes")
                Button { studio.adjustClip(clip.id, start: 1) } label: { Image(systemName: "forward.end") }.help("Começar uma frase depois")
                Spacer()
                Text("Fim").font(.caption2)
                Button { studio.adjustClip(clip.id, end: -1) } label: { Image(systemName: "backward.end") }.help("Terminar uma frase antes")
                Button { studio.adjustClip(clip.id, end: 1) } label: { Image(systemName: "forward.end") }.help("Terminar uma frase depois")
            }.buttonStyle(.bordered).controlSize(.small)
            Picker("Visual", selection: Binding(get: { clip.template }, set: { v in studio.updateClip(clip.id) { $0.template = v } })) {
                ForEach(ClipSuggestion.templates, id: \.id) { Text($0.name).tag($0.id) }
            }.font(.caption)
            Toggle("Gancho escrito no início", isOn: Binding(get: { clip.showHook }, set: { v in studio.updateClip(clip.id) { $0.showHook = v } })).font(.caption)
            if let hook = clip.videoHook {
                Toggle(isOn: Binding(get: { clip.useVideoHook }, set: { v in studio.updateClip(clip.id) { $0.useVideoHook = v } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Gancho em vídeo (\(String(format: "%.1f", hook.end - hook.start)) s)").font(.caption)
                        Text("“\(VideoHook.text(captions: studio.captions, start: hook.start, end: hook.end))”").font(.caption2).italic().foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Fala do corte").font(.caption2.weight(.semibold))
                Text(studio.transcript(of: clip)).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !clip.caption.isEmpty || !clip.hashtags.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Texto do post").font(.caption2.weight(.semibold))
                    TextEditor(text: Binding(get: { clip.caption }, set: { v in studio.updateClip(clip.id) { $0.caption = v } }))
                        .font(.caption).frame(minHeight: 60, maxHeight: 110).scrollContentBackground(.hidden).background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    TextField("Hashtags", text: Binding(get: { clip.hashtags.joined(separator: " ") },
                                                        set: { v in studio.updateClip(clip.id) { $0.hashtags = v.split(separator: " ").map(String.init) } }))
                        .textFieldStyle(.roundedBorder).font(.caption)
                }
            }
            HStack {
                Button("Montar Reels Ethos neste corte") { studio.openClip(clip); studio.requestedTab = "Reels" }
                Spacer()
                Button("Renomear") { newTitle = clip.title; renaming = clip.id }
                Button("Apagar", role: .destructive) { confirmDelete = clip }
            }.font(.caption).buttonStyle(.borderless)
        }
        .padding(8).background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Miniatura vertical do primeiro quadro do corte.
struct ClipThumb: View {
    let url: URL?
    let time: Double
    @State private var image: NSImage?
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
            if let image { Image(nsImage: image).resizable().scaledToFill() } else { Image(systemName: "film").foregroundStyle(.secondary) }
        }
        .frame(width: 54, height: 96).clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: "\(url?.path ?? "")|\(Int(time * 10))") { await load() }
    }
    private func load() async {
        guard let url else { return }
        let key = "\(url.path)|\(Int(time * 10))" as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 320, height: 320)
        guard let cg = try? await g.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { return }
        // Recorte vertical central (como o corte 9:16 aparece no celular).
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let cropW = min(w, h * 9 / 16)
        let rect = CGRect(x: (w - cropW) / 2, y: 0, width: cropW, height: h)
        let cropped = cg.cropping(to: rect) ?? cg
        let ns = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        Self.cache.setObject(ns, forKey: key)
        image = ns
    }
}
