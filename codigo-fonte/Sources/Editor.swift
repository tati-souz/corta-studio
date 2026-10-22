import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

enum EditorSelection: Equatable {
    case effect(UUID)
    case caption(Int)
    /// Intervalo da edição (tempo de saída) marcado na linha do tempo.
    case range(Double, Double)
    /// Junção entre dois trechos (início do trecho seguinte, no tempo do original).
    case transition(Double)
}

/// Cursor de tempo, separado do Studio para que só a linha do tempo seja redesenhada 30 vezes por segundo.
@MainActor final class Playhead: ObservableObject {
    @Published var timeline: Timeline?
    @Published var duration: Double = 0
}
/// Só o instante atual: muda 30 vezes por segundo durante a reprodução.
@MainActor final class PlayClock: ObservableObject {
    @Published var time: Double = 0
    @Published var playing = false
}

extension Studio {
    var frameDuration: Double {
        let rate = Double(media?.frameRate ?? 30)
        return 1 / (rate.isFinite && rate >= 1 ? min(60, rate) : 30)
    }
    var liveTimeline: Timeline? { playhead.timeline }
    var showingLive: Bool { !showingOriginal && !showingRendered }

    // MARK: Montagem ao vivo

    /// Remonta a edição para o player (sem renderizar arquivo). Chamado a cada alteração, com pequena espera para agrupar ajustes.
    func scheduleLive(delay: Double = 0.18) {
        liveTask?.cancel()
        liveTask = Task { @MainActor in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await buildLive()
        }
    }

    private func buildLive() async {
        guard let source, let media else { return }
        do {
            let timeline = try makeTimeline(snapshot())
            let voice = settings.studioVoice ? readyVoice() : nil
            let built = try await MediaEngine.compose(source: source, support: support, timeline: timeline, settings: settings, effects: effects,
                                                      faceTrack: settings.fillFrame ? faceTrack : [], voice: voice, transitions: transitionMarks, preview: true)
            guard !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: built.composition)
            item.videoComposition = built.videoComposition
            item.audioMix = built.audioMix
            liveBuilt = built; liveItem = item
            let resume = min(clock.time, max(0, timeline.duration - frameDuration))
            playhead.timeline = timeline; playhead.duration = timeline.duration
            coverCount = gaze != nil ? lookAwaySegments().count : 0
            liveStatus = ""
            if showingLive || player?.currentItem == nil {
                let wasPlaying = (player?.rate ?? 0) > 0
                showingOriginal = false; showingRendered = false
                player?.replaceCurrentItem(with: item)
                await player?.seek(to: CMTime(seconds: resume, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying { player?.play() }
            }
        } catch {
            liveStatus = error.localizedDescription
        }
    }

    /// Voz de estúdio para a edição ao vivo: usa a versão já processada; se não houver, processa em segundo plano e remonta.
    private func readyVoice() -> URL? {
        guard let source else { return nil }
        let key = "\(source.path)|\(Int(settings.voiceIsolation * 100))"
        if key == voiceKey, let voiceURL { return voiceURL }
        if voiceTask == nil || voiceKey != key {
            voiceTask?.cancel(); voiceKey = key; voiceURL = nil
            let isolation = settings.voiceIsolation
            voiceTask = Task { @MainActor in
                liveStatus = "Preparando a voz de estúdio…"
                let url = try? await VoiceStudio.process(video: source, isolation: isolation, directory: Studio.cacheDirectory) { text in Task { @MainActor in self.liveStatus = text } }
                guard !Task.isCancelled, self.voiceKey == key else { return }
                guard url != nil else { self.liveStatus = "Não foi possível preparar a voz de estúdio; o áudio original foi mantido."; self.settings.studioVoice = false; self.voiceTask = nil; return }
                self.voiceURL = url; self.voiceTask = nil; self.liveStatus = ""
                self.scheduleLive(delay: 0)
            }
        }
        return nil
    }

    func showLive() {
        guard let liveItem else { scheduleLive(delay: 0); showingOriginal = false; showingRendered = false; return }
        player?.pause()
        showingOriginal = false; showingRendered = false
        player?.replaceCurrentItem(with: liveItem)
        player?.seek(to: CMTime(seconds: clock.time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func playerMoved(_ seconds: Double) {
        guard seconds.isFinite else { return }
        clock.playing = (player?.rate ?? 0) > 0
        if showingLive { clock.time = seconds }
        else if showingOriginal, let timeline = playhead.timeline { clock.time = timeline.outputTime(seconds) }
    }

    // MARK: Navegação

    func seek(_ time: Double) {
        let t = max(0, min(time, max(0, playhead.duration - frameDuration * 0.5)))
        clock.time = t
        if !showingLive { showLive() }
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func step(_ frames: Int) {
        player?.pause()
        seek((clock.time / frameDuration).rounded() * frameDuration + Double(frames) * frameDuration)
    }
    func togglePlay() {
        guard let player else { return }
        if player.rate > 0 { player.pause() }
        else {
            if !showingLive && !showingOriginal && !showingRendered { showLive() }
            if clock.time >= playhead.duration - 0.05 { seek(0) }
            player.play()
        }
    }

    // MARK: Edição manual

    /// Converte um intervalo da edição em intervalo do original (âncora dos efeitos).
    private func sourceRange(_ start: Double, _ end: Double) -> (Double, Double) {
        guard let timeline = playhead.timeline else { return (start, end) }
        let a = timeline.sourceTime(start)
        var b = timeline.sourceTime(max(start, end - 0.001)) + 0.001
        if b <= a { b = a + max(0.2, end - start) }
        return (a, b)
    }
    func outputRange(of effect: Effect) -> (Double, Double)? {
        guard let timeline = playhead.timeline else { return nil }
        let ranges = timeline.outputRanges(start: effect.start, end: effect.end)
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return (first.0, last.1)
    }

    func addEffect(_ kind: Effect.Kind, start: Double? = nil, end: Double? = nil, zoomStyle: String = "suave", fxStyle: String = "tremor", textStyle: String = "destaque") {
        guard source != nil else { return }
        var a = start ?? clock.time, b = end ?? (a + (kind == .zoom ? 2.5 : 3.5))
        if case .range(let s, let e)? = selection, start == nil { a = s; b = e }
        b = min(b, playhead.duration); if b - a < 0.3 { a = max(0, b - 1) }
        let (sa, sb) = sourceRange(a, b)
        var effect = Effect(kind: kind, start: sa, end: sb)
        switch kind {
        case .zoom: effect.amount = zoomStyle == "corte" ? 1.22 : 1.18; effect.style = zoomStyle; effect.speed = Effect.defaultSpeed(zoomStyle)
        case .texto:
            effect.style = textStyle
            effect.text = TextStyles.all.first { $0.id == textStyle && textStyle != "destaque" }?.sample ?? "Seu texto aqui"
            effect.animation = ["cartao": "deslizar", "lista": "deslizar", "capitulo": "revelar", "impacto": "pular", "pergunta": "escala"][textStyle] ?? "subir"
            if textStyle == "lista" {
                effect.asset = effects.filter { $0.kind == .texto && $0.style == "lista" }.min { abs($0.start - sa) < abs($1.start - sa) }?.asset ?? "lista-" + UUID().uuidString.prefix(6)
            }
        case .imagem: effect.asset = Library.imageNames.first ?? ""; effect.style = "tela-cheia"
        case .video: effect.asset = Library.videoNames.first ?? ""; effect.style = "tela-cheia"
        case .fx: effect.style = fxStyle; effect.amount = 0.6
        }
        commitHistory()
        effects.append(effect); effects.sort { $0.start < $1.start }
        selection = .effect(effect.id)
        requestedTab = "Editar"
        seek(a + min(0.6, (b - a) / 2))
    }
    func updateEffect(_ id: UUID, recordUndo: Bool = false, _ change: (inout Effect) -> Void) {
        guard let i = effects.firstIndex(where: { $0.id == id }) else { return }
        if recordUndo { commitHistory() }
        change(&effects[i])
        effects[i].end = max(effects[i].end, effects[i].start + 0.1)
    }
    /// Define início/fim de um efeito em tempo da edição.
    func setEffectTiming(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        guard let effect = effects.first(where: { $0.id == id }), let current = outputRange(of: effect) else { return }
        let a = max(0, start ?? current.0), b = min(playhead.duration, end ?? current.1)
        guard b - a >= 0.1 else { return }
        let (sa, sb) = sourceRange(a, b)
        updateEffect(id, recordUndo: true) { $0.start = sa; $0.end = sb }
    }
    func moveEffect(_ id: UUID, by delta: Double) {
        guard let effect = effects.first(where: { $0.id == id }), let current = outputRange(of: effect) else { return }
        let length = current.1 - current.0
        let a = max(0, min(playhead.duration - length, current.0 + delta))
        setEffectTiming(id, start: a, end: a + length)
    }
    func deleteSelection() {
        switch selection {
        case .effect(let id)?: commitHistory(); effects.removeAll { $0.id == id }; selection = nil
        case .caption(let id)?:
            hideCaption(id); selection = nil
            summary = "Texto da legenda apagado (a fala continua no vídeo). Para tirar a fala: botão direito › Remover esta fala do vídeo."
        case .range(let a, let b)?: removeRange(a, b)
        case .transition(let t)?: setTransition(at: t, type: "corte")
        case nil: break
        }
    }

    /// Remove manualmente um trecho da edição (qualquer parte do vídeo, com ou sem fala).
    func removeRange(_ start: Double, _ end: Double) {
        guard let timeline = playhead.timeline, end - start > 0.02 else { return }
        commitHistory()
        // Dentro do gancho em vídeo: encurta ou tira o gancho, sem apagar a fala do lugar original.
        if timeline.hookCount > 0, start < timeline.hookDuration - 0.01, var hook = videoHook {
            let hookEnd = timeline.hookDuration
            if start <= 0.05 && end >= hookEnd - 0.05 { videoHook = nil; summary = "Gancho em vídeo removido. Desfazer volta atrás."; selection = nil; return }
            if start <= 0.05 { hook.start = timeline.sourceTime(min(end, hookEnd - 0.01)) }
            else if end >= hookEnd - 0.05 { hook.end = timeline.sourceTime(max(0, start - 0.001)) + 0.001 }
            else { message = "No gancho dá para tirar só o começo ou o fim (ou o gancho todo)."; return }
            if hook.end - hook.start >= 1 { videoHook = hook } else { videoHook = nil }
            selection = nil; seek(0); summary = "Gancho em vídeo ajustado."
            return
        }
        var offset = 0.0, added: [Cut] = []
        for cut in timeline.cuts {
            let a = max(start, offset), b = min(end, offset + cut.duration)
            if b > a { added.append(Cut(start: cut.start + a - offset, end: cut.start + b - offset)) }
            offset += cut.duration
        }
        var all = (exclusions + added).sorted { $0.start < $1.start }, merged: [Cut] = []
        for cut in all { if let last = merged.last, cut.start <= last.end + 0.01 { merged[merged.count - 1].end = max(last.end, cut.end) } else { merged.append(cut) } }
        all = merged
        exclusions = all
        selection = nil
        seek(start)
        summary = "Trecho de \(String(format: "%.2f", end - start)) s removido manualmente. Desfazer volta atrás."
    }
    func restoreExclusions() {
        guard !exclusions.isEmpty else { return }
        commitHistory(); exclusions = []
    }

    func setCaption(_ id: Int, recordUndo: Bool = true, _ change: (inout Caption) -> Void) {
        guard let i = captions.firstIndex(where: { $0.id == id }) else { return }
        if recordUndo { commitHistory() }
        change(&captions[i])
        if captions[i].end <= captions[i].start { captions[i].end = captions[i].start + 0.2 }
    }
    /// Ajusta início/fim de uma legenda pelo tempo da edição (para acertar sincronia).
    func setCaptionTiming(_ id: Int, start: Double? = nil, end: Double? = nil) {
        guard let timeline = playhead.timeline else { return }
        setCaption(id) { cue in
            if let start { cue.start = max(0, timeline.sourceTime(start)); cue.words = nil }
            if let end { cue.end = timeline.sourceTime(max(0, end - 0.001)) + 0.001; cue.words = nil }
        }
    }
    func addCaption(text: String = "Nova legenda") {
        guard let timeline = playhead.timeline, let media else { return }
        let a = timeline.sourceTime(clock.time), b = min(media.duration, a + 2)
        let id = (captions.map(\.id).max() ?? -1) + 1
        commitHistory()
        captions.append(Caption(id: id, start: a, end: b, text: text))
        captions.sort { $0.start < $1.start }
        settings.captions = true
        selection = .caption(id); requestedTab = "Editar"
    }

}

// MARK: Título de abertura e ações por legenda

extension Studio {
    static let titleMarker = "abertura"
    /// O título de abertura é um efeito de texto marcado, posicionado no início da edição.
    var openingTitle: Effect? { effects.first { $0.kind == .texto && $0.asset == Studio.titleMarker } }

    func setOpeningTitle(text: String? = nil, style: String? = nil, seconds: Double? = nil, animation: String? = nil) {
        if var title = openingTitle {
            if let text { title.text = text }
            if let style { title.style = style }
            if let animation { title.animation = animation }
            if let seconds, let timeline = playhead.timeline {
                title.end = timeline.sourceTime(max(0.5, min(seconds, playhead.duration) - 0.001)) + 0.001
            }
            if let i = effects.firstIndex(where: { $0.id == title.id }) { effects[i] = title }
        } else {
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty, let timeline = playhead.timeline else { return }
            let length = min(seconds ?? 3.5, max(1, playhead.duration))
            let start = timeline.sourceTime(0), end = timeline.sourceTime(max(0.5, length - 0.001)) + 0.001
            commitHistory()
            effects.insert(Effect(kind: .texto, start: start, end: end, text: text, style: style ?? "titulo", asset: Studio.titleMarker, animation: animation ?? "subir"), at: 0)
        }
    }
    func removeOpeningTitle() {
        guard let title = openingTitle else { return }
        commitHistory(); effects.removeAll { $0.id == title.id }
    }
    var openingTitleSeconds: Double {
        guard let title = openingTitle, let range = outputRange(of: title) else { return 3.5 }
        return (range.1 - range.0).rounded()
    }

    /// Cria um efeito ocupando exatamente o tempo de uma legenda.
    func effectOnCaption(_ id: Int, kind: Effect.Kind, style: String = "destaque", zoomStyle: String = "suave", fxStyle: String = "tremor") {
        guard let cue = captions.first(where: { $0.id == id }) else { return }
        commitHistory()
        if !cue.included, let i = captions.firstIndex(where: { $0.id == id }) { captions[i].included = true }
        var effect = Effect(kind: kind, start: cue.start, end: max(cue.end, cue.start + (kind == .zoom ? 1.5 : 2.2)))
        switch kind {
        case .texto: effect.text = cue.keptText.trimmingCharacters(in: .whitespacesAndNewlines); effect.style = style; effect.animation = style == "impacto" || style == "palavra" ? "escala" : "subir"
        case .zoom: effect.amount = zoomStyle == "corte" ? 1.22 : 1.18; effect.style = zoomStyle; effect.speed = Effect.defaultSpeed(zoomStyle)
        case .imagem: effect.asset = Library.imageNames.first ?? ""; effect.style = "tela-cheia"
        case .video: effect.asset = Library.videoNames.first ?? ""; effect.style = "tela-cheia"
        case .fx: effect.style = fxStyle; effect.amount = 0.6
        }
        effects.append(effect); effects.sort { $0.start < $1.start }
        selection = .effect(effect.id)
        requestedTab = "Editar"
        if let timeline = playhead.timeline { seek(timeline.outputTime(cue.start) + 0.4) }
    }
    func goToCaption(_ id: Int) {
        guard let cue = captions.first(where: { $0.id == id }) else { return }
        selection = .caption(id)
        if cue.included, let timeline = playhead.timeline { seek(timeline.outputTime(cue.start)) } else { showOriginal(at: cue.start) }
    }
}


// MARK: Transições por junção

extension Studio {
    func transition(at sourceTime: Double) -> (type: String, duration: Double) {
        guard let timeline = playhead.timeline,
              let j = timeline.junctions(settings: settings, marks: transitionMarks).first(where: { abs($0.sourceTime - sourceTime) < 0.05 }) else { return ("corte", 0.5) }
        return (j.type, j.duration)
    }
    func setTransition(at sourceTime: Double, type: String? = nil, duration: Double? = nil) {
        commitHistory()
        let current = transition(at: sourceTime)
        let mark = TransitionMark(sourceTime: sourceTime, type: type ?? current.type, duration: min(2.5, max(0.15, duration ?? current.duration)))
        transitionMarks.removeAll { abs($0.sourceTime - sourceTime) < 0.05 }
        transitionMarks.append(mark)
    }
    /// Aplica o mesmo tipo a todas as junções da edição atual.
    func setTransitionEverywhere(type: String, duration: Double) {
        guard let timeline = playhead.timeline else { return }
        commitHistory()
        transitionMarks = timeline.junctions(settings: settings, marks: []).map { TransitionMark(sourceTime: $0.sourceTime, type: type, duration: duration) }
    }
    func previewTransition(at sourceTime: Double) {
        guard let timeline = playhead.timeline else { return }
        seek(max(0, timeline.outputTime(sourceTime) - 1.0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.player?.play() }
    }
}


// MARK: Imagens para a narração

extension Studio {
    /// Abre o buscador/gerador de imagens para um trecho (em tempo da edição).
    func requestImage(outputStart: Double, outputEnd: Double, effectID: UUID? = nil) {
        guard let timeline = playhead.timeline else { return }
        let a = timeline.sourceTime(outputStart), b = timeline.sourceTime(max(outputStart, outputEnd - 0.001)) + 0.001
        let text = captions.filter { $0.included && $0.end > a && $0.start < b }.map(\.keptText).joined(separator: " ")
        imageRequest = ImageRequest(start: a, end: max(b, a + 1), narration: text.isEmpty ? "Trecho sem fala transcrita" : text, effectID: effectID)
    }
    func requestImage(forCaption id: Int) {
        guard let cue = captions.first(where: { $0.id == id }) else { return }
        imageRequest = ImageRequest(start: cue.start, end: max(cue.end, cue.start + 2.5), narration: cue.keptText, effectID: nil)
    }
    func requestImage(forEffect effect: Effect) {
        let text = captions.filter { $0.included && $0.end > effect.start && $0.start < effect.end }.map(\.keptText).joined(separator: " ")
        imageRequest = ImageRequest(start: effect.start, end: effect.end, narration: text.isEmpty ? effect.asset : text, effectID: effect.id)
    }
    func placeImage(_ name: String, request: ImageRequest, display: String, entrance: String) {
        commitHistory()
        if let id = request.effectID, let i = effects.firstIndex(where: { $0.id == id }) {
            effects[i].asset = name; effects[i].style = display; effects[i].animation = entrance
            selection = .effect(id)
        } else {
            let effect = Effect(kind: .imagem, start: request.start, end: request.end, style: display, asset: name, animation: entrance)
            effects.append(effect); effects.sort { $0.start < $1.start }
            selection = .effect(effect.id)
        }
        requestedTab = "Editar"
        if let timeline = playhead.timeline { seek(timeline.outputTime(request.start) + 0.6) }
    }
}
