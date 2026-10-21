import SwiftUI
import AVFoundation

private let gold = Color(red: 0.83, green: 0.66, blue: 0.29)
private let card = Color(red: 0.105, green: 0.098, blue: 0.090)

/// Miniaturas de cada estilo de texto aplicadas sobre o quadro real do vídeo, sem renderizar o vídeo.
@MainActor final class StylePreviewer: ObservableObject {
    @Published var images: [String: CGImage] = [:]
    private var task: Task<Void, Never>?
    private let context = CIContext()

    /// Miniaturas de cada efeito de vídeo aplicadas ao quadro real, no auge do efeito.
    func renderFX(effect: Effect, studio: Studio) {
        guard let source = studio.source, let timeline = studio.playhead.timeline, let range = studio.outputRange(of: effect) else { return }
        task?.cancel()
        let settings = studio.settings
        let size = settings.vertical ? CGSize(width: 216, height: 384) : CGSize(width: 320, height: 180)
        let context = self.context
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            let mid = range.0 + min(0.6, (range.1 - range.0) * 0.4)
            guard let frame = try? await generator.image(at: CMTime(seconds: timeline.sourceTime(mid), preferredTimescale: 600)).image else { return }
            let base = CIImage(cgImage: frame)
            var result: [String: CGImage] = [:]
            for fx in Effect.fxStyles {
                guard !Task.isCancelled else { return }
                var e = effect; e.style = fx.id
                let at = fx.id == "flash" || fx.id == "foco" ? range.0 + 0.08 : mid
                let painter = FramePainter(size: size, timeline: timeline, settings: settings, support: nil, effects: [PlacedEffect(effect: e, start: range.0, end: range.1)])
                result["fx:" + fx.id] = context.createCGImage(painter.frame(base, at: at), from: CGRect(origin: .zero, size: size))
            }
            images = result
        }
    }
    func render(effect: Effect, studio: Studio) {
        guard let source = studio.source, let timeline = studio.playhead.timeline, let range = studio.outputRange(of: effect) else { return }
        task?.cancel()
        let settings = studio.settings
        let mid = range.0 + min(1.2, (range.1 - range.0) * 0.6)
        let sourceTime = timeline.sourceTime(mid)
        let size = settings.vertical ? CGSize(width: 216, height: 384) : CGSize(width: 320, height: 180)
        let context = self.context
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            guard let frame = try? await generator.image(at: CMTime(seconds: sourceTime, preferredTimescale: 600)).image else { return }
            let base = CIImage(cgImage: frame)
            var result: [String: CGImage] = [:]
            for style in TextStyles.all {
                guard !Task.isCancelled else { return }
                var e = effect; e.style = style.id; e.animation = "fade"
                let painter = FramePainter(size: size, timeline: timeline, settings: settings, support: nil,
                                           effects: [PlacedEffect(effect: e, start: range.0, end: range.1)])
                let image = painter.frame(base, at: mid)
                result[style.id] = context.createCGImage(image, from: CGRect(origin: .zero, size: size))
            }
            images = result
        }
    }
}

struct InspectorPanel: View {
    @ObservedObject var studio: Studio
    @ObservedObject var playhead: Playhead
    @StateObject private var previews = StylePreviewer()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch studio.selection {
                case .effect(let id)?:
                    if let effect = studio.effects.first(where: { $0.id == id }) { effectEditor(effect) } else { hint }
                case .caption(let id)?:
                    if let cue = studio.captions.first(where: { $0.id == id }) { captionEditor(cue) } else { hint }
                case .range(let a, let b)?:
                    rangeEditor(a, b)
                case .transition(let t)?:
                    transitionEditor(t)
                case nil: hint
                }
            }.padding(.top, 4)
        }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edição manual").font(.system(size: 16, weight: .medium, design: .serif))
            Text("Clique em um efeito ou legenda na linha do tempo para ajustar aqui. Clique numa faixa vazia para adicionar zoom, texto ou imagem naquele ponto. Arraste na faixa de vídeo ou na régua para selecionar um trecho e removê-lo.").font(.callout).foregroundStyle(.secondary)
            Text("Atalhos: espaço reproduz · ← → um quadro · ⇧← ⇧→ um segundo · ⌫ apaga o item selecionado").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button { studio.addEffect(.zoom) } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                Button { studio.addEffect(.texto) } label: { Label("Texto", systemImage: "textformat") }
                Button { studio.addEffect(.imagem) } label: { Label("Imagem", systemImage: "photo") }.disabled(Library.imageNames.isEmpty)
            }.disabled(studio.source == nil)
        }
    }

    // MARK: Tempo

    private func timing(start: Double, end: Double, set: @escaping (Double?, Double?) -> Void) -> some View {
        let f = studio.frameDuration
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Início").font(.caption).frame(width: 40, alignment: .leading)
                Text(timecode(start, fps: 1 / f)).font(.system(.caption, design: .monospaced)).foregroundStyle(gold)
                Spacer()
                Button("−1q") { set(start - f, nil) }; Button("+1q") { set(start + f, nil) }
                Button("Cursor") { set(studio.clock.time, nil) }
            }
            HStack {
                Text("Fim").font(.caption).frame(width: 40, alignment: .leading)
                Text(timecode(end, fps: 1 / f)).font(.system(.caption, design: .monospaced)).foregroundStyle(gold)
                Spacer()
                Button("−1q") { set(nil, end - f) }; Button("+1q") { set(nil, end + f) }
                Button("Cursor") { set(nil, studio.clock.time) }
            }
        }.buttonStyle(.borderless).font(.caption)
        .padding(10).background(card, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Efeitos

    @ViewBuilder private func effectEditor(_ effect: Effect) -> some View {
        HStack {
            Label(effect.kind == .zoom ? "Zoom" : effect.kind == .texto ? "Texto na tela" : effect.kind == .video ? "Vídeo de apoio" : "Imagem de apoio",
                  systemImage: effect.kind == .zoom ? "plus.magnifyingglass" : effect.kind == .texto ? "textformat" : effect.kind == .video ? "film" : "photo").font(.headline)
            Spacer()
            Button(role: .destructive) { studio.deleteSelection() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
        if let range = studio.outputRange(of: effect) {
            timing(start: range.0, end: range.1) { a, b in studio.setEffectTiming(effect.id, start: a, end: b) }
        }
        switch effect.kind {
        case .zoom:
            VStack(alignment: .leading, spacing: 8) {
                Text("Tipo de zoom").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(Effect.zoomStyles, id: \.id) { z in
                        let current = effect.style.isEmpty ? "suave" : effect.style
                        Button {
                            studio.updateEffect(effect.id, recordUndo: true) { $0.style = z.id; $0.speed = Effect.defaultSpeed(z.id) }
                            replay(effect)
                        } label: {
                            VStack(spacing: 3) {
                                ZoomCurve(effect: { var e = effect; e.style = z.id; e.speed = current == z.id ? effect.speed : Effect.defaultSpeed(z.id); return e }())
                                    .stroke(current == z.id ? gold : Color.white.opacity(0.5), lineWidth: 1.5).frame(height: 26)
                                Text(z.name).font(.caption2).foregroundStyle(current == z.id ? gold : .secondary)
                            }.padding(6).frame(maxWidth: .infinity)
                            .background(card, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(current == z.id ? gold : .clear, lineWidth: 1.5))
                        }.buttonStyle(.plain)
                    }
                }
                HStack { Text("Intensidade"); Spacer(); Text("\(Int((effect.amount - 1) * 100))%").foregroundStyle(gold) }.font(.caption)
                Slider(value: Binding(get: { effect.amount }, set: { v in studio.updateEffect(effect.id) { $0.amount = v } }), in: 1.04...1.5)
                if effect.style != "corte" {
                    let whole = effect.speed <= 0.001
                    if effect.style == "zoom-in" || effect.style == "zoom-out" {
                        Toggle("Ao longo de todo o trecho", isOn: Binding(get: { whole }, set: { on in studio.updateEffect(effect.id, recordUndo: true) { $0.speed = on ? 0 : 0.6 } })).font(.caption)
                    }
                    if !whole {
                        HStack { Text("Velocidade da transição"); Spacer(); Text(String(format: "%.2f s · %@", effect.speed, effect.speed < 0.2 ? "rápida" : effect.speed < 0.6 ? "normal" : effect.speed < 1.5 ? "lenta" : "muito lenta")).foregroundStyle(gold) }.font(.caption)
                        Slider(value: Binding(get: { log(max(0.05, effect.speed)) }, set: { v in studio.updateEffect(effect.id) { $0.speed = exp(v) } }), in: log(0.05)...log(4))
                        HStack {
                            ForEach([("Rápida", 0.12), ("Normal", 0.35), ("Lenta", 1.0), ("Muito lenta", 2.5)], id: \.0) { item in
                                Button(item.0) { studio.updateEffect(effect.id, recordUndo: true) { $0.speed = item.1 }; replay(effect) }
                            }
                        }.buttonStyle(.bordered).controlSize(.small).font(.caption2)
                    }
                }
                Text(zoomHelp(effect.style)).font(.caption2).foregroundStyle(.secondary)
                Button { replay(effect) } label: { Label("Ver o zoom", systemImage: "play.circle") }.buttonStyle(.borderless).font(.caption)
            }
        case .texto:
            VStack(alignment: .leading, spacing: 6) {
                Text("Texto").font(.caption).foregroundStyle(.secondary)
                TextField("Texto", text: Binding(get: { effect.text }, set: { v in studio.updateEffect(effect.id) { $0.text = v } }), axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder)
                if effect.style == "versiculo" { Text("Use: texto — referência (ex.: … — Provérbios 4,23). Confira a referência na Bíblia.").font(.caption2).foregroundStyle(.secondary) }
                if effect.style == "nome" { Text("Use: Nome | subtítulo").font(.caption2).foregroundStyle(.secondary) }
                if effect.style == "lista" {
                    Toggle("Mostrar o contador (“2 de 5”)", isOn: Binding(get: { effect.border }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.border = v } })).font(.caption)
                    Button { studio.addListItemHere() } label: { Label("Adicionar próximo item no ponto atual", systemImage: "list.number") }.font(.caption)
                    Text("Os itens anteriores da mesma lista continuam na tela, mais apagados; o atual fica em destaque.").font(.caption2).foregroundStyle(.secondary)
                }
                Picker("Animação", selection: Binding(get: { effect.animation }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.animation = v }; replay(effect) })) {
                    ForEach(TextStyles.animations, id: \.id) { Text($0.name).tag($0.id) }
                }.font(.caption)
                Picker("Posição", selection: Binding(get: { effect.position }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.position = v }; show(effect) })) {
                    Text("Automática (longe do rosto)").tag(""); Text("Alto").tag("alto"); Text("Centro").tag("centro"); Text("Baixo").tag("baixo")
                }.font(.caption)
                Button { replay(effect) } label: { Label("Ver a animação", systemImage: "play.circle") }.buttonStyle(.borderless).font(.caption)
            }
            Text("Estilo — clique para aplicar e ver na tela").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(TextStyles.all) { style in
                    Button {
                        studio.updateEffect(effect.id, recordUndo: true) { $0.style = style.id }
                        show(effect)
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6).fill(Color.black)
                                if let image = previews.images[style.id] { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                                else { ProgressView().controlSize(.small) }
                            }.aspectRatio(studio.settings.vertical ? 9 / 16 : 16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(effect.style == style.id ? gold : Color.white.opacity(0.1), lineWidth: effect.style == style.id ? 2 : 1))
                            Text(style.name).font(.caption2).foregroundStyle(effect.style == style.id ? gold : .secondary)
                        }
                    }.buttonStyle(.plain)
                }
            }
            .onAppear { previews.render(effect: effect, studio: studio) }
            .onChange(of: effect.text) { previews.render(effect: effect, studio: studio) }
            .onChange(of: effect.position) { previews.render(effect: effect, studio: studio) }
            .onChange(of: effect.id) { previews.render(effect: effect, studio: studio) }
            .onChange(of: studio.settings) { previews.render(effect: effect, studio: studio) }
        case .fx:
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Intensidade"); Spacer(); Text("\(Int(effect.amount * 100))%").foregroundStyle(gold) }.font(.caption)
                Slider(value: Binding(get: { min(1, max(0.2, effect.amount)) }, set: { v in studio.updateEffect(effect.id) { $0.amount = v } }), in: 0.2...1)
                Button { replay(effect) } label: { Label("Ver o efeito", systemImage: "play.circle") }.buttonStyle(.borderless).font(.caption)
                Text("Efeito — clique para trocar e ver na tela").font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(Effect.fxStyles, id: \.id) { fx in
                        Button {
                            studio.updateEffect(effect.id, recordUndo: true) { $0.style = fx.id }
                            show(effect)
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.black)
                                    if let image = previews.images["fx:" + fx.id] { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                                    else { ProgressView().controlSize(.small) }
                                }.aspectRatio(studio.settings.vertical ? 9 / 16 : 16 / 9, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(effect.style == fx.id ? gold : Color.white.opacity(0.1), lineWidth: effect.style == fx.id ? 2 : 1))
                                Text(fx.name).font(.caption2).foregroundStyle(effect.style == fx.id ? gold : .secondary)
                            }
                        }.buttonStyle(.plain).help(fx.help)
                    }
                }
                Text(Effect.fxStyles.first { $0.id == effect.style }?.help ?? "").font(.caption2).foregroundStyle(.secondary)
            }
            .onAppear { previews.renderFX(effect: effect, studio: studio) }
            .onChange(of: effect.id) { previews.renderFX(effect: effect, studio: studio) }
            .onChange(of: effect.amount) { previews.renderFX(effect: effect, studio: studio) }
        case .video:
            Button { studio.openBroll(target: .effect(effect.id)) } label: { Label("Trocar por outro vídeo ou imagem…", systemImage: "film.stack") }.buttonStyle(.borderedProminent).foregroundStyle(.black)
            Button { replaceWithFile(effect) } label: { Label("Usar um arquivo do computador…", systemImage: "folder") }
            Picker("Vídeo", selection: Binding(get: { effect.asset }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.asset = v } })) {
                ForEach(Library.videoNames, id: \.self) { Text($0).tag($0) }
            }
            Picker("Entrada", selection: Binding(get: { effect.animation }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.animation = v }; replay(effect) })) {
                Text("Suave").tag("fade"); Text("Deslizar").tag("deslizar"); Text("Aproximar").tag("zoom"); Text("Corte seco").tag("corte")
            }
            Picker("Exibição", selection: Binding(get: { effect.style.isEmpty ? "tela-cheia" : effect.style }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.style = v } })) {
                ForEach(Effect.layouts, id: \.id) { Text($0.name).tag($0.id) }
            }
            Text("O áudio do vídeo de apoio fica mudo: sua voz continua. Se o clipe for mais curto que o trecho, ele se repete.").font(.caption2).foregroundStyle(.secondary)
            presenterControls(effect)
        case .imagem:
            Button { studio.requestImage(forEffect: effect) } label: { Label("Buscar ou gerar outra imagem…", systemImage: "photo.on.rectangle.angled") }.buttonStyle(.borderedProminent).foregroundStyle(.black)
            Button { replaceWithFile(effect) } label: { Label("Usar um arquivo do computador…", systemImage: "folder") }
            Picker("Entrada", selection: Binding(get: { effect.animation }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.animation = v }; replay(effect) })) {
                Text("Suave").tag("fade"); Text("Deslizar").tag("deslizar"); Text("Aproximar").tag("zoom"); Text("Corte seco").tag("corte")
            }
            Picker("Imagem", selection: Binding(get: { effect.asset }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.asset = v } })) {
                ForEach(Library.imageNames, id: \.self) { Text($0).tag($0) }
            }
            Picker("Exibição", selection: Binding(get: { effect.style.isEmpty ? "tela-cheia" : effect.style }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.style = v } })) {
                ForEach(Effect.layouts, id: \.id) { Text($0.name).tag($0.id) }
            }
            presenterControls(effect)
            Button("Adicionar imagens à biblioteca…") { Library.add(to: Library.images, types: Library.imageTypes, message: "Imagens com nomes descritivos."); studio.libraryVersion += 1 }.font(.caption)
        }
    }
    /// Tamanho, posição e borda do apresentador nos layouts de janelinha e recorte.
    @ViewBuilder private func presenterControls(_ effect: Effect) -> some View {
        if ["pip", "pip-retangular", "fundo"].contains(effect.style) {
            Picker("Posição de você", selection: Binding(get: { effect.position }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.position = v } })) {
                ForEach(Effect.presenterPositions, id: \.id) { Text($0.name).tag($0.id) }
            }
            HStack {
                Text("Tamanho").font(.caption)
                Slider(value: Binding(get: { effect.scale }, set: { v in studio.updateEffect(effect.id) { $0.scale = v } }), in: effect.style == "fundo" ? 0.4...1.2 : 0.4...1.6)
                Text("\(Int(effect.scale * 100))%").font(.caption.monospacedDigit())
            }
            if effect.style != "fundo" { Toggle("Borda dourada", isOn: Binding(get: { effect.border }, set: { v in studio.updateEffect(effect.id, recordUndo: true) { $0.border = v } })) }
        }
    }
    /// Troca a imagem/vídeo deste apoio por um arquivo escolhido (copiado para a Biblioteca), mantendo tempo e layout.
    private func replaceWithFile(_ effect: Effect) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image, .movie]; panel.allowsMultipleSelection = false
        panel.message = "Escolha a imagem ou o vídeo para este trecho."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let isVideo = Library.videoTypes.contains(url.pathExtension.lowercased())
        guard let name = BrollSources.importLocal(LocalMedia(url: url, isVideo: isVideo, labels: "")) else { studio.error = "Não consegui copiar esse arquivo para a Biblioteca."; return }
        studio.libraryVersion += 1
        studio.updateEffect(effect.id, recordUndo: true) { $0.asset = name; $0.kind = isVideo ? .video : .imagem }
    }
    private func zoomHelp(_ style: String) -> String {
        switch style {
        case "zoom-in": return "Aproxima devagar e termina mais perto. Bom para construir tensão ou conduzir a uma conclusão."
        case "zoom-out": return "Começa perto e vai abrindo o quadro. Bom para respiro depois de uma frase forte."
        case "corte": return "Aproximação instantânea, como um corte de câmera. Muito usado em Reels e Shorts para dar ritmo."
        case "batida": return "Entra rápido e volta: marca uma palavra ou uma piada sem tirar o foco."
        default: return "Aproxima, segura e volta ao enquadramento normal no fim do trecho."
        }
    }
    /// Leva o cursor para dentro do efeito, para ele aparecer na tela.
    private func show(_ effect: Effect) {
        guard let range = studio.outputRange(of: effect) else { return }
        studio.player?.pause()
        if studio.clock.time < range.0 || studio.clock.time > range.1 { studio.seek(range.0 + min(1.0, (range.1 - range.0) * 0.6)) }
    }
    private func replay(_ effect: Effect) {
        guard let range = studio.outputRange(of: effect) else { return }
        studio.seek(max(0, range.0 - 0.2))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { studio.player?.play() }
    }

    // MARK: Transições

    @ViewBuilder private func transitionEditor(_ sourceTime: Double) -> some View {
        let current = studio.transition(at: sourceTime)
        HStack {
            Label("Transição entre trechos", systemImage: "rectangle.portrait.on.rectangle.portrait.angled").font(.headline)
            Spacer()
        }
        if let timeline = playhead.timeline { Text("Junção em \(timecode(timeline.outputTime(sourceTime)))").font(.system(.caption, design: .monospaced)).foregroundStyle(gold) }
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            ForEach(TransitionMark.types, id: \.id) { t in
                Button {
                    studio.setTransition(at: sourceTime, type: t.id)
                    if t.id != "corte" { studio.previewTransition(at: sourceTime) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(t.name).font(.caption.weight(.semibold)).foregroundStyle(current.type == t.id ? gold : .primary)
                        Text(t.help).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }.padding(8).frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                    .background(card, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(current.type == t.id ? gold : .clear, lineWidth: 1.5))
                }.buttonStyle(.plain)
            }
        }
        if current.type != "corte" {
            HStack { Text("Duração"); Spacer(); Text(String(format: "%.2f s", current.duration)).foregroundStyle(gold) }.font(.caption)
            Slider(value: Binding(get: { current.duration }, set: { v in studio.setTransition(at: sourceTime, duration: v) }), in: 0.15...2.0)
        }
        HStack {
            Button { studio.previewTransition(at: sourceTime) } label: { Label("Ver a transição", systemImage: "play.circle") }
            Spacer()
            Button("Usar em todos os cortes") { studio.setTransitionEverywhere(type: current.type, duration: current.duration) }
        }.buttonStyle(.borderless).font(.caption)
        Text("Os losangos na faixa de vídeo marcam cada junção. Dourado = com transição.").font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: Legendas

    @ViewBuilder private func captionEditor(_ cue: Caption) -> some View {
        HStack {
            Label("Legenda", systemImage: "captions.bubble").font(.headline)
            Spacer()
            Toggle("Manter", isOn: Binding(get: { cue.included }, set: { v in studio.setCaption(cue.id) { $0.included = v } })).toggleStyle(.checkbox).font(.caption)
        }
        TextField("Texto", text: Binding(get: { cue.text }, set: { v in studio.setCaption(cue.id, recordUndo: false) { $0.text = v; $0.removedWords = nil } }), axis: .vertical)
            .lineLimit(1...5).textFieldStyle(.roundedBorder)
        if let output = playhead.timeline?.captions.filter({ $0.sourceID == cue.id }), let first = output.first, let last = output.last {
            timing(start: first.start, end: last.end) { a, b in studio.setCaptionTiming(cue.id, start: a, end: b) }
        } else {
            Text("Este trecho está fora da edição atual. Marque Manter para trazê-lo de volta.").font(.caption).foregroundStyle(.secondary)
        }
        if let removed = cue.removedWords, !removed.isEmpty {
            let tokens = cue.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            HStack {
                Text("Vícios removidos: " + removed.compactMap { $0 < tokens.count ? tokens[$0] : nil }.joined(separator: ", ")).font(.caption).strikethrough()
                Spacer()
                Button("Restaurar") { studio.restoreWords(cue.id) }.font(.caption)
            }
        }
        Text("Ajustar início e fim corrige a sincronia da legenda com a fala.").font(.caption2).foregroundStyle(.secondary)
    }

    // MARK: Trecho selecionado

    @ViewBuilder private func rangeEditor(_ a: Double, _ b: Double) -> some View {
        Label("Trecho selecionado", systemImage: "selection.pin.in.out").font(.headline)
        Text("\(timecode(a)) → \(timecode(b)) · \(String(format: "%.2f", b - a)) s").font(.system(.caption, design: .monospaced)).foregroundStyle(gold)
        Button(role: .destructive) { studio.removeRange(a, b) } label: { Label("Remover este trecho do vídeo", systemImage: "scissors") }
        Button { studio.requestImage(outputStart: a, outputEnd: b) } label: { Label("Imagem para esta narração (buscar ou gerar)…", systemImage: "photo.on.rectangle.angled") }
        Divider()
        Text("Aplicar neste trecho").font(.caption).foregroundStyle(.secondary)
        HStack {
            Menu { ForEach(Effect.zoomStyles, id: \.id) { z in Button(z.name) { studio.addEffect(.zoom, zoomStyle: z.id) } } } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }.fixedSize()
            Button { studio.addEffect(.texto) } label: { Label("Texto", systemImage: "textformat") }
            Button { studio.addEffect(.imagem) } label: { Label("Imagem", systemImage: "photo") }.disabled(Library.imageNames.isEmpty)
        }
        if !studio.exclusions.isEmpty {
            Divider()
            Button("Restaurar os \(studio.exclusions.count) trecho(s) removido(s) manualmente") { studio.restoreExclusions() }.font(.caption)
        }
    }
}


/// Desenho da curva de zoom ao longo do trecho (pré-visualização do tipo escolhido).
struct ZoomCurve: Shape {
    let effect: Effect
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let d = 3.0, a = max(1.01, effect.amount)
        for i in 0...60 {
            let t = d * Double(i) / 60
            let z = (effect.zoomFactor(at: t, duration: d) - 1) / (a - 1)
            let p = CGPoint(x: rect.minX + rect.width * CGFloat(i) / 60, y: rect.maxY - rect.height * CGFloat(max(0, min(1, z))))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}
