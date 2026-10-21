import SwiftUI

// MARK: Modelos de Reels/Shorts
// Cada modelo cria uma NOVA VERSÃO (aparece na aba Cortes) a partir do que está aberto, sem apagar a edição original.
// Tudo o que o modelo coloca vira peça comum da linha do tempo: editável, removível e com ⌘Z.

enum ReelsTemplate: String, CaseIterable, Identifiable {
    case dinamica, imagens, recortado, janelinha, pergunta, lista, narracao
    var id: String { rawValue }
    var name: String {
        switch self {
        case .dinamica: return "Fala dinâmica"
        case .imagens: return "Fala + imagens de apoio"
        case .recortado: return "Apresentador recortado"
        case .janelinha: return "Vídeo com janelinha"
        case .pergunta: return "Pergunta na tela + resposta"
        case .lista: return "Lista com revelação progressiva"
        case .narracao: return "Narração + texto animado"
        }
    }
    var look: String {
        switch self {
        case .dinamica: return "Você em tela cheia, cortes ágeis e palavras destacadas acompanhando a fala."
        case .imagens: return "Você aparece e, em alguns momentos, imagens ou vídeos ilustram o assunto enquanto a voz continua."
        case .recortado: return "Você sem o fundo original, sobre uma notícia, imagem, gráfico ou vídeo."
        case .janelinha: return "Uma demonstração ou gravação de tela ocupa o fundo; você numa pequena janela."
        case .pergunta: return "Um cartão com a pergunta abre o vídeo, seguido da sua resposta."
        case .lista: return "“3 erros”, “5 sinais”: cada item aparece quando é mencionado."
        case .narracao: return "A voz conduz enquanto frases e imagens ocupam a tela, sem precisar de rosto."
        }
    }
    /// Precisa de mídia além do vídeo (imagens, vídeo de fundo…).
    var needsMedia: Bool { [.imagens, .recortado, .janelinha, .narracao].contains(self) }
    /// O que depende da IA (e a alternativa manual).
    var aiNote: String? {
        switch self {
        case .dinamica: return nil
        case .imagens, .recortado, .narracao: return "Buscar mídia pela narração usa a IA. Sem ela: escolha os arquivos (ficam na ordem, espalhados pelo vídeo)."
        case .janelinha: return "Buscar o conteúdo usa a IA. Sem ela: escolha o vídeo ou as imagens do fundo."
        case .pergunta: return "Sugerir a pergunta usa a IA. Sem ela: escreva a pergunta."
        case .lista: return "Encontrar os itens na fala usa a IA. Sem ela: adicione cada item no ponto do vídeo com “Adicionar item aqui”."
        }
    }
}

struct TemplateOptions {
    var pauses = "normal"            // leve, normal, forte
    var zoomIntensity = 0.14
    var zoomEvery = 7.0
    var captionStyle = "Hormozi"
    var media = "ia"                 // ia, arquivos, biblioteca
    var aiSource = "fotos"
    var files: [URL] = []
    var density = "médio (um apoio a cada ~12 s)"
    var scale = 1.0
    var position = ""
    var border = true
    var roundWindow = true
    var question = ""
    var questionSeconds = 3.5
    var listProgress = true
    var quoteCards = true
}

extension Studio {
    /// Cria uma versão nova (como um corte do vídeo inteiro aberto) e aplica o modelo nela.
    func applyTemplate(_ template: ReelsTemplate, _ o: TemplateOptions) {
        operation("Aplicando o modelo “\(template.name)”…") {
            if self.captions.isEmpty { try await self.performTranscriptionPublic() }
            let base = self.snapshot()
            let kept = base.captions.filter(\.included).map(\.id)
            guard let first = kept.min(), let last = kept.max() else { throw StudioError("Não há fala na edição para aplicar o modelo.") }
            var version = ClipSuggestion(title: "Reels · \(template.name)", hook: "", reason: "Versão criada pelo modelo \(template.name). A edição original continua guardada.", startID: first, endID: last)
            version.showHook = false; version.useVideoHook = base.videoHook != nil; version.videoHook = base.videoHook
            self.clips.append(version)
            self.openClip(version)
            self.restore(base)
            if !self.settings.vertical { self.settings.applyPlatform("Instagram Reels") }
            self.settings.fillFrame = true
            self.refreshTimelineNow()
            try await self.templateWork(template, o)
            self.commitHistory()
            self.refreshTimelineNow(); self.scheduleLive(delay: 0)
            self.message = "Modelo “\(template.name)” aplicado numa versão nova (aba Cortes). A edição original está guardada; ⌘Z desfaz passo a passo."
        }
    }
    func refreshTimelineNow() {
        if let t = try? makeTimeline(snapshot()) { playhead.timeline = t; playhead.duration = t.duration }
    }

    private func templateWork(_ template: ReelsTemplate, _ o: TemplateOptions) async throws {
        let connected: Bool = await {
            if !self.connection.connected { await self.connection.restore() }
            return self.connection.connected
        }()
        func mediaStep(target: BrollTarget, display: String) async throws {
            if o.media == "arquivos" {
                guard !o.files.isEmpty else { throw StudioError("Escolha os arquivos de mídia para este modelo.") }
                try await placeBrollWork(target: target, source: "arquivos", folder: nil, density: o.density, display: display, entrance: "fade", minimum: 1,
                                         files: o.files, ordered: !connected || target != .auto, alternateFull: false)
            } else if connected {
                try await placeBrollWork(target: target, source: o.media == "biblioteca" ? "biblioteca" : o.aiSource, folder: nil, density: o.density, display: display, entrance: "fade", minimum: 1)
            } else {
                throw StudioError("Buscar mídia pela narração precisa do Claude conectado (IA e conta). Alternativa: escolha “Meus arquivos” e selecione as imagens ou vídeos.")
            }
            // Ajustes do apresentador nas peças colocadas
            for i in effects.indices where (effects[i].kind == .imagem || effects[i].kind == .video) && effects[i].style == display {
                effects[i].scale = o.scale; effects[i].position = o.position; effects[i].border = o.border
            }
        }
        switch template {
        case .dinamica:
            settings.trimPauses = o.pauses != "leve"
            settings.tightPauses = o.pauses == "forte"
            settings.captions = true; settings.captionMode = "Dinâmica"; settings.captionStyle = o.captionStyle; settings.captionPosition = "Centro"
            refreshTimelineNow()
            addRhythmZooms(every: o.zoomEvery, intensity: o.zoomIntensity)
        case .imagens:
            settings.captions = true
            try await mediaStep(target: .auto, display: "tela-cheia")
        case .recortado:
            try await mediaStep(target: o.media == "arquivos" ? .cover(max(4, editedDuration / Double(max(1, o.files.count)))) : .cover(8), display: "fundo")
        case .janelinha:
            try await mediaStep(target: o.media == "arquivos" ? .cover(max(4, editedDuration / Double(max(1, o.files.count)))) : .cover(8), display: o.roundWindow ? "pip" : "pip-retangular")
        case .pergunta:
            var question = o.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if question.isEmpty {
                guard connected else { throw StudioError("Escreva a pergunta do cartão (ou conecte o Claude para sugerir uma).") }
                aiWorking = true; question = try await connection.suggestQuestion(captions: captions); aiWorking = false
            }
            guard let timeline = playhead.timeline, !question.isEmpty else { return }
            settings.question = ""; settings.captions = true
            let start = timeline.sourceTime(0), end = timeline.sourceTime(min(timeline.duration - 0.05, o.questionSeconds))
            effects.append(Effect(kind: .texto, start: start, end: max(end, start + 1), text: question, style: "pergunta", animation: "escala"))
        case .lista:
            guard connected else {
                throw StudioError("Encontrar os itens na fala precisa do Claude conectado. Alternativa manual: na aba Reels, pare o vídeo onde cada item começa e clique em “Adicionar item aqui”.")
            }
            aiWorking = true
            let items = try await connection.findListItems(captions: captions)
            aiWorking = false
            guard !items.isEmpty, let timeline = playhead.timeline else { throw StudioError("Não encontrei uma lista clara na fala. Adicione os itens à mão com “Adicionar item aqui”.") }
            let group = "lista-" + UUID().uuidString.prefix(6)
            let starts = items.compactMap { item in captions.first { $0.id == item.id }.map { (timeline.outputTime($0.start), item.text) } }.sorted { $0.0 < $1.0 }
            for (i, item) in starts.enumerated() {
                let outEnd = i + 1 < starts.count ? starts[i + 1].0 : min(timeline.duration, item.0 + 8)
                let a = timeline.sourceTime(item.0), b = timeline.sourceTime(max(item.0, outEnd - 0.05)) + 0.05
                var e = Effect(kind: .texto, start: a, end: max(b, a + 1.5), text: item.1, style: "lista", asset: group, animation: "deslizar")
                e.border = o.listProgress
                effects.append(e)
            }
        case .narracao:
            settings.captions = true; settings.captionStyle = o.captionStyle; settings.captionMode = o.captionStyle == "Bege" ? "Blocos" : "Dinâmica"; settings.captionPosition = "Centro"
            try await mediaStep(target: o.media == "arquivos" ? .cover(max(3, editedDuration / Double(max(1, o.files.count)))) : .cover(6), display: "so-apoio")
            if o.quoteCards && connected { await addQuoteCards() }
        }
        effects.sort { $0.start < $1.start }
    }

    /// Zooms pontuais no ritmo da fala: alterna aproximação rápida (punch-in) e suave, no início de frases.
    func addRhythmZooms(every: Double, intensity: Double) {
        guard let timeline = playhead.timeline else { return }
        var next = 1.5, n = 0
        for cue in timeline.captions where cue.start >= next {
            let a = timeline.sourceTime(cue.start), b = timeline.sourceTime(min(cue.end, cue.start + 3.2) - 0.01)
            guard b - a > 0.6 else { continue }
            effects.append(Effect(kind: .zoom, start: a, end: b, style: n % 2 == 0 ? "corte" : "suave", amount: 1 + intensity, speed: n % 2 == 0 ? 0 : 0.35))
            n += 1; next = cue.start + every
        }
    }

    /// Item de lista manual no ponto atual (mesmo grupo da lista mais próxima).
    func addListItemHere() {
        guard let timeline = playhead.timeline else { return }
        commitHistory()
        let t = clock.time, src = timeline.sourceTime(t)
        let group = effects.filter { $0.kind == .texto && $0.style == "lista" }.min { abs($0.start - src) < abs($1.start - src) }?.asset ?? "lista-" + UUID().uuidString.prefix(6)
        let count = effects.filter { $0.style == "lista" && $0.asset == group }.count
        let e = Effect(kind: .texto, start: src, end: timeline.sourceTime(min(timeline.duration - 0.05, t + 5)), text: "Item \(count + 1)", style: "lista", asset: group, animation: "deslizar")
        effects.append(e); effects.sort { $0.start < $1.start }
        selection = .effect(e.id); requestedTab = "Editar"
    }
}

// MARK: Galeria

struct TemplateGallery: View {
    @ObservedObject var studio: Studio
    @State private var chosen: ReelsTemplate?
    @State private var o = TemplateOptions()
    @State private var pexels = PexelsKey.value ?? ""
    private let accent = Color(red: 0.83, green: 0.66, blue: 0.29)
    private let canvas = Color(red: 0.06, green: 0.06, blue: 0.055)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(ReelsTemplate.allCases) { t in
                    Button { withAnimation { chosen = chosen == t ? nil : t }; prepare(t) } label: {
                        VStack(spacing: 4) {
                            TemplateMock(template: t).frame(height: 150)
                            Text(t.name).font(.system(size: 10, weight: .semibold)).multilineTextAlignment(.center).lineLimit(2).frame(height: 26)
                        }
                        .padding(5).background(RoundedRectangle(cornerRadius: 8).fill(chosen == t ? accent.opacity(0.16) : Color.white.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(chosen == t ? accent : Color.white.opacity(0.1), lineWidth: chosen == t ? 1.5 : 1))
                    }.buttonStyle(.plain).help(t.look)
                }
            }
            if let t = chosen { options(t) }
        }
    }

    private func prepare(_ t: ReelsTemplate) {
        o.captionStyle = t == .narracao ? "Bege" : "Hormozi"
        o.media = t.needsMedia && studio.connection.connected ? "ia" : (t.needsMedia ? "arquivos" : "ia")
        o.density = t == .imagens ? "médio (um apoio a cada ~12 s)" : "muitos (um apoio a cada ~6 s)"
        o.position = t == .janelinha ? "inf-dir" : ""
        o.scale = t == .recortado ? 0.85 : 1
        o.files = []
    }

    @ViewBuilder private func options(_ t: ReelsTemplate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.name).font(.callout.weight(.semibold))
            Text(t.look).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = t.aiNote {
                Label(studio.connection.connected ? note : "IA não conectada. " + note, systemImage: studio.connection.connected ? "sparkles" : "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(studio.connection.connected ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
            }
            switch t {
            case .dinamica:
                Picker("Pausas", selection: $o.pauses) { Text("Leve (só as longas)").tag("leve"); Text("Normal").tag("normal"); Text("Forte (ritmo acelerado)").tag("forte") }
                HStack { Text("Zoom").font(.caption); Slider(value: $o.zoomIntensity, in: 0.05...0.3); Text("\(Int(o.zoomIntensity * 100))%").font(.caption.monospacedDigit()) }
                HStack { Text("A cada").font(.caption); Slider(value: $o.zoomEvery, in: 3...15, step: 1); Text("\(Int(o.zoomEvery)) s").font(.caption.monospacedDigit()) }
                captionPicker
            case .imagens, .recortado, .janelinha, .narracao:
                mediaPicker(t)
                if t == .recortado || t == .janelinha {
                    if t == .janelinha {
                        Picker("Janela", selection: $o.roundWindow) { Text("Redonda").tag(true); Text("Retangular").tag(false) }.pickerStyle(.segmented)
                        Toggle("Borda dourada", isOn: $o.border)
                    }
                    Picker("Posição", selection: $o.position) {
                        ForEach(Effect.presenterPositions.filter { t == .janelinha ? !["esquerda", "direita"].contains($0.id) : ["", "centro", "esquerda", "direita"].contains($0.id) }, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    HStack { Text("Tamanho").font(.caption); Slider(value: $o.scale, in: t == .janelinha ? 0.6...1.6 : 0.5...1.1); Text("\(Int(o.scale * 100))%").font(.caption.monospacedDigit()) }
                }
                if t == .narracao {
                    captionPicker
                    Toggle("Frases-chave em cartões (IA)", isOn: $o.quoteCards)
                    Text("Para narração só em áudio, use “Trocar vídeo” e escolha o arquivo de áudio (m4a, mp3, wav). Grave antes no app Gravador ou no QuickTime.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .pergunta:
                TextField(studio.connection.connected ? "Pergunta (vazio = a IA sugere)" : "Pergunta do cartão", text: $o.question, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3)
                HStack { Text("Duração").font(.caption); Slider(value: $o.questionSeconds, in: 2...8, step: 0.5); Text(String(format: "%.1f s", o.questionSeconds)).font(.caption.monospacedDigit()) }
            case .lista:
                Toggle("Indicador de progresso (“2 de 5”)", isOn: $o.listProgress)
                Button { studio.addListItemHere() } label: { Label("Adicionar item aqui (manual)", systemImage: "list.number") }.font(.caption)
                    .help("Pare o vídeo onde o item começa e clique; depois edite o texto na aba Editar")
            }
            Button { if !pexels.isEmpty, pexels != (PexelsKey.value ?? "") { PexelsKey.set(pexels) }; studio.applyTemplate(t, o) } label: {
                Label("Aplicar modelo (cria uma versão nova)", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).foregroundStyle(canvas)
            .disabled(studio.source == nil || studio.busy || (t.needsMedia && o.media == "arquivos" && o.files.isEmpty))
            Text("A edição original continua guardada. Depois de aplicar, tudo fica na linha do tempo para ajustar à mão (textos, imagens, zooms, transições) e ⌘Z desfaz.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
    }
    private var captionPicker: some View {
        Picker("Legenda", selection: $o.captionStyle) { ForEach(SettingPreviews.captionStyles) { Text($0.label).tag($0.id) } }
    }
    @ViewBuilder private func mediaPicker(_ t: ReelsTemplate) -> some View {
        Picker("Mídia", selection: $o.media) {
            Text("IA busca pela narração").tag("ia")
            Text("Meus arquivos").tag("arquivos")
            Text("Biblioteca (IA escolhe)").tag("biblioteca")
        }
        if o.media == "ia" {
            Picker("Buscar", selection: $o.aiSource) {
                Text("Fotos e pinturas").tag("fotos"); Text("Fotos + vídeos").tag("misto"); Text("Só vídeos (Pexels)").tag("videos"); Text("Ilustrações do Claude").tag("claude")
            }
            if o.aiSource == "videos" || o.aiSource == "misto" {
                HStack { SecureField("Chave do Pexels", text: $pexels).textFieldStyle(.roundedBorder); Button("Salvar") { PexelsKey.set(pexels) }.disabled(pexels.isEmpty) }
            }
        } else if o.media == "arquivos" {
            HStack {
                Button(o.files.isEmpty ? "Escolher arquivos…" : "Trocar arquivos…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.image, .movie, .folder]
                    panel.message = t == .janelinha ? "Escolha a gravação de tela ou o vídeo do fundo (ou imagens)." : "Escolha as imagens ou vídeos (ou uma pasta), na ordem em que devem aparecer."
                    if panel.runModal() == .OK { o.files = panel.urls }
                }
                Text(o.files.isEmpty ? "nenhum arquivo" : "\(o.files.count) item(ns)").font(.caption).foregroundStyle(.secondary)
            }
        }
        if t == .imagens {
            Picker("Quantidade", selection: $o.density) { ForEach(["poucos (um apoio a cada ~25 s)", "médio (um apoio a cada ~12 s)", "muitos (um apoio a cada ~6 s)"], id: \.self) { Text($0) } }
        }
    }
}

/// Prévia desenhada de cada modelo (9:16).
struct TemplateMock: View {
    let template: ReelsTemplate
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.29)
    private let beige = Color(red: 0.925, green: 0.885, blue: 0.80)
    private let room = LinearGradient(colors: [Color(red: 0.36, green: 0.27, blue: 0.19), Color(red: 0.2, green: 0.15, blue: 0.11)], startPoint: .top, endPoint: .bottom)
    private let picture = LinearGradient(colors: [Color(red: 0.48, green: 0.58, blue: 0.66), Color(red: 0.75, green: 0.62, blue: 0.40)], startPoint: .top, endPoint: .bottom)

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                switch template {
                case .dinamica:
                    room; person(w, h, scale: 1.25)
                    caption(["É", "O", "HÁBITO"], w: w, y: h * 0.62, hormozi: true)
                    Image(systemName: "plus.magnifyingglass").font(.system(size: w * 0.1)).foregroundStyle(.white.opacity(0.8)).position(x: w * 0.85, y: h * 0.1)
                case .imagens:
                    HStack(spacing: 2) {
                        ZStack { room; person(w / 2, h, scale: 1) }
                        ZStack { picture; Image(systemName: "building.columns.fill").resizable().scaledToFit().padding(w * 0.08).foregroundStyle(.black.opacity(0.3)) }
                    }
                    caption(["a voz continua"], w: w, y: h * 0.8)
                case .recortado:
                    picture
                    Image(systemName: "newspaper.fill").resizable().scaledToFit().frame(width: w * 0.6).foregroundStyle(.white.opacity(0.55)).position(x: w * 0.5, y: h * 0.28)
                    person(w, h, scale: 0.85)
                case .janelinha:
                    LinearGradient(colors: [Color(white: 0.85), Color(white: 0.7)], startPoint: .top, endPoint: .bottom)
                    VStack(spacing: 4) { ForEach(0..<6, id: \.self) { i in RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(i == 0 ? 0.45 : 0.2)).frame(width: w * (i == 0 ? 0.7 : 0.6), height: h * 0.025) } }.position(x: w * 0.5, y: h * 0.35)
                    ZStack { room; person(w * 0.36, w * 0.36, scale: 1) }.frame(width: w * 0.36, height: w * 0.36).clipShape(Circle()).overlay(Circle().stroke(gold, lineWidth: 2)).position(x: w * 0.74, y: h * 0.8)
                case .pergunta:
                    room; person(w, h, scale: 1.1)
                    Text("Por que adiamos o que importa?").font(.custom("Georgia-Bold", size: w * 0.075)).foregroundStyle(Color(white: 0.1)).multilineTextAlignment(.center)
                        .padding(w * 0.05).background(RoundedRectangle(cornerRadius: 4).fill(beige)).frame(width: w * 0.86).position(x: w / 2, y: h * 0.42)
                case .lista:
                    room; person(w, h, scale: 1.1)
                    VStack(alignment: .leading, spacing: h * 0.012) {
                        Text("2 de 3").font(.system(size: w * 0.05, weight: .semibold)).foregroundStyle(gold)
                        Text("1  Ouvir").font(.custom("Georgia", size: w * 0.065)).foregroundStyle(.white.opacity(0.6))
                        Text("2  Pensar").font(.custom("Georgia-Bold", size: w * 0.08)).foregroundStyle(.white)
                    }.padding(w * 0.05).background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.65))).position(x: w * 0.42, y: h * 0.25)
                case .narracao:
                    picture
                    Image(systemName: "mountain.2.fill").resizable().scaledToFit().frame(width: w * 0.7).foregroundStyle(.black.opacity(0.25)).position(x: w / 2, y: h * 0.62)
                    Text("A virtude nasce\ndo hábito").font(.custom("Baskerville-SemiBold", size: w * 0.09)).foregroundStyle(.black).multilineTextAlignment(.center)
                        .padding(w * 0.04).background(RoundedRectangle(cornerRadius: 3).fill(beige)).position(x: w / 2, y: h * 0.45)
                    Image(systemName: "waveform").font(.system(size: w * 0.12)).foregroundStyle(gold).position(x: w / 2, y: h * 0.88)
                }
            }
            .frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .aspectRatio(9 / 16, contentMode: .fit)
    }
    private func person(_ w: CGFloat, _ h: CGFloat, scale: CGFloat) -> some View {
        VStack(spacing: -w * 0.04 * scale) {
            Circle().fill(Color(red: 0.86, green: 0.70, blue: 0.58)).frame(width: w * 0.26 * scale)
            RoundedRectangle(cornerRadius: w * 0.12).fill(Color(red: 0.20, green: 0.24, blue: 0.36)).frame(width: w * 0.62 * scale, height: h * 0.32 * scale)
        }.frame(width: w, height: h, alignment: .bottom)
    }
    private func caption(_ words: [String], w: CGFloat, y: CGFloat, hormozi: Bool = false) -> some View {
        HStack(spacing: w * 0.02) {
            ForEach(Array(words.enumerated()), id: \.offset) { i, word in
                Text(word).font(.system(size: w * (hormozi && i == words.count - 1 ? 0.11 : 0.085), weight: .black))
                    .foregroundStyle(hormozi && i == words.count - 1 ? Color(red: 1, green: 0.86, blue: 0.12) : .white).shadow(radius: 1)
            }
        }.position(x: w / 2, y: y)
    }
}
