import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Cortes, exportação e projeto. Regra central: o que está na tela (edição ao vivo) é exatamente o que é exportado.
/// Cada corte guarda as próprias edições; o vídeo completo também.
extension Studio {

    // MARK: Cortes sugeridos

    func suggestClips(count: Int) {
        operation("O Claude está procurando os melhores cortes curtos…") { try await self.suggestClipsWork(count: count) }
    }
    func suggestClipsWork(count: Int) async throws {
        do {
            if self.captions.isEmpty { try await self.performTranscriptionPublic() }
            if !self.connection.connected { await self.connection.restore() }
            guard self.connection.connected else { throw StudioError("Conecte sua conta Claude em IA e conta para sugerir cortes.") }
            self.aiWorking = true
            let base = self.activeClipID == nil ? self.snapshot() : (self.mainEdit ?? self.snapshot())
            var options = self.clipOptions; options.count = count
            let found = try await self.connection.suggestClips(captions: base.captions, options: options)
            // Mantém os cortes que você já editou e acrescenta os novos.
            self.clips = self.clips.filter { $0.edit != nil || $0.id == self.activeClipID } + found
            self.message = found.isEmpty ? "Nenhum trecho autossuficiente encontrado." : "\(found.count) cortes sugeridos. Clique em um para abrir no editor."
            self.aiWorking = false
        }
    }

    var editingTitle: String {
        if let id = activeClipID, let clip = clips.first(where: { $0.id == id }) { return "Corte: \(clip.title)" }
        return "Vídeo completo"
    }

    /// Estado de um corte do jeito que a IA sugeriu, a partir da edição do vídeo completo.
    func generatedState(_ clip: ClipSuggestion) -> EditState {
        var state = activeClipID == nil ? snapshot() : (mainEdit ?? snapshot())
        state.captions = state.captions.map { var cue = $0; cue.included = cue.included && cue.id >= clip.startID && cue.id <= clip.endID; return cue }
        if !state.captions.contains(where: \.included) { state.captions = state.captions.map { var cue = $0; cue.included = cue.id >= clip.startID && cue.id <= clip.endID; return cue } }
        if !state.settings.vertical { state.settings.applyPlatform("Instagram Reels") }
        state.settings.shortVideo = true
        state.videoHook = clip.useVideoHook ? clip.videoHook : nil
        if !clip.showHook { state.settings.question = "" }
        else if state.settings.autoHook || state.settings.question.isEmpty { state.settings.question = clip.hook }
        switch clip.template {
        case "reels-ethos": state.settings.captions = true; state.settings.captionStyle = "Bege"; state.settings.captionMode = "Blocos"; state.settings.captionPosition = "Inferior"
        case "viral": state.settings.captions = true; state.settings.captionStyle = "Hormozi"; state.settings.captionMode = "Dinâmica"; state.settings.captionPosition = "Centro"
        case "classico": state.settings.captions = true; state.settings.captionStyle = "Ethos"; state.settings.captionMode = "Dinâmica"; state.settings.captionPosition = "Inferior"
        case "limpo": state.settings.captions = false
        default: break
        }
        return state
    }

    // MARK: Ajustes de cada corte (como num gerador de cortes)

    /// Estende ou encurta o corte em frases inteiras, no início ou no fim. Mantém as edições já feitas.
    func adjustClip(_ id: UUID, start delta: Int = 0, end endDelta: Int = 0) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let base = activeClipID == nil ? snapshot().captions : (mainEdit?.captions ?? captions)
        let ids = base.map(\.id).sorted()
        guard let a = ids.firstIndex(of: clips[i].startID), let b = ids.firstIndex(of: clips[i].endID) else { return }
        let na = min(max(0, a + delta), b), nb = max(min(ids.count - 1, b + endDelta), na)
        let (oldA, oldB) = (clips[i].startID, clips[i].endID)
        let (newA, newB) = (ids[na], ids[nb])
        guard (newA, newB) != (oldA, oldB) else { return }
        func reshape(_ list: [Caption]) -> [Caption] {
            list.map { cue in
                var cue = cue
                if cue.id < newA || cue.id > newB { cue.included = false }
                else if cue.id < oldA || cue.id > oldB { cue.included = base.first { $0.id == cue.id }?.included ?? true }
                return cue
            }
        }
        if id == activeClipID {
            clips[i].startID = newA; clips[i].endID = newB
            captions = reshape(captions); commitHistory(); invalidatePreview(); scheduleLive(delay: 0.2)
        } else {
            if var edit = clips[i].edit { edit.captions = reshape(edit.captions); clips[i].edit = edit }
            clips[i].startID = newA; clips[i].endID = newB
        }
        scheduleAutosave()
    }
    func updateClip(_ id: UUID, _ change: (inout ClipSuggestion) -> Void) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        let before = clips[i]
        change(&clips[i])
        // Modelo visual ou gancho mudaram: um corte ainda não editado é refeito; um aberto, atualizado na tela.
        if before.template != clips[i].template || before.showHook != clips[i].showHook || before.useVideoHook != clips[i].useVideoHook || before.videoHook != clips[i].videoHook {
            if id == activeClipID { restore(generatedState(clips[i])); commitHistory(); scheduleLive(delay: 0) }
            else if clips[i].edit != nil, var edit = clips[i].edit {
                let fresh = generatedState(clips[i])
                edit.settings.captions = fresh.settings.captions; edit.settings.captionStyle = fresh.settings.captionStyle
                edit.settings.captionMode = fresh.settings.captionMode; edit.settings.captionPosition = fresh.settings.captionPosition
                edit.settings.question = fresh.settings.question
                edit.videoHook = fresh.videoHook
                clips[i].edit = edit
            }
        }
        scheduleAutosave()
    }
    func deleteClip(_ id: UUID) {
        if id == activeClipID { openMainVideo() }
        clips.removeAll { $0.id == id }
        scheduleAutosave()
    }
    /// Título, texto do post e hashtags, prontos para colar no Instagram/TikTok/YouTube.
    func postText(_ clip: ClipSuggestion) -> String {
        [clip.title, clip.caption, clip.hashtags.joined(separator: " ")].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    func copyPost(_ clip: ClipSuggestion) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(postText(clip), forType: .string)
        message = "Texto do post de “\(clip.title)” copiado."
    }
    /// Texto falado no corte (para ler sem abrir).
    func transcript(of clip: ClipSuggestion) -> String {
        let base = activeClipID == nil ? captions : (mainEdit?.captions ?? captions)
        return base.filter { $0.id >= clip.startID && $0.id <= clip.endID }.map(\.keptText).joined(separator: " ")
    }
    func clipSpan(_ clip: ClipSuggestion) -> (start: Double, end: Double)? {
        let base = activeClipID == nil ? captions : (mainEdit?.captions ?? captions)
        guard let a = base.first(where: { $0.id == clip.startID }), let b = base.first(where: { $0.id == clip.endID }) else { return nil }
        return (a.start, b.end)
    }
    /// Estado atual de um corte: o que está na tela (se aberto), as edições guardadas ou a sugestão original.
    func state(of clip: ClipSuggestion) -> EditState {
        if clip.id == activeClipID { return snapshot() }
        return clip.edit ?? generatedState(clip)
    }
    private func stashCurrent() {
        commitHistory()
        if let id = activeClipID, let i = clips.firstIndex(where: { $0.id == id }) {
            // Só marca como editado se for diferente do que a IA sugeriu.
            let now = snapshot()
            clips[i].edit = now == generatedState(clips[i]) ? nil : now
        } else { mainEdit = snapshot() }
    }

    /// Abre um corte no editor ao vivo (com as edições que você já fez nele, se houver).
    func openClip(_ clip: ClipSuggestion) {
        guard clip.id != activeClipID else { return }
        stashCurrent()
        let target = clips.first(where: { $0.id == clip.id })?.edit ?? generatedState(clip)
        activeClipID = clip.id
        restore(target)
        resetHistory()
        selection = nil; clock.time = 0; showingOriginal = false; showingRendered = false
        summary = "Editando o corte “\(clip.title)”. Tudo o que você mudar fica guardado neste corte."
        scheduleLive(delay: 0)
        message = "Corte aberto no editor. O que aparece na tela é o que será exportado."
    }
    func openMainVideo() {
        guard activeClipID != nil else { return }
        stashCurrent()
        activeClipID = nil
        if let main = mainEdit { restore(main) }
        resetHistory()
        selection = nil; showingOriginal = false; showingRendered = false
        summary = "De volta ao vídeo completo."
        scheduleLive(delay: 0)
    }
    func clipWasEdited(_ clip: ClipSuggestion) -> Bool {
        if clip.id == activeClipID { return canUndo || clip.edit != nil }
        if activeClipID == nil, let edit = clip.edit { return edit != generatedState(clip) }
        return clip.edit != nil
    }
    func revertClip(_ clip: ClipSuggestion) {
        guard let i = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[i].edit = nil
        if clip.id == activeClipID { restore(generatedState(clip)); resetHistory() }
    }

    // MARK: Exportação

    private func safeName(_ text: String) -> String {
        String(text.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-").prefix(80))
    }
    var currentExportName: String {
        let base = source?.deletingPathExtension().lastPathComponent ?? "video"
        if let id = activeClipID, let clip = clips.first(where: { $0.id == id }) { return safeName(clip.title) }
        return safeName(base + " - editado")
    }

    /// Exporta exatamente o que está na tela.
    func exportCurrent() { export(state: snapshot(), name: currentExportName) }
    func exportClip(_ clip: ClipSuggestion) { export(state: state(of: clip), name: safeName(clip.title), post: clip.caption.isEmpty ? nil : postText(clip)) }

    private func export(state: EditState, name: String, post: String? = nil) {
        guard source != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = name + ".mp4"
        panel.canCreateDirectories = true
        panel.message = "Escolha o nome e a pasta. As legendas (.srt e .vtt) são salvas ao lado, com o mesmo nome."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operation("Exportando \(url.lastPathComponent)…") {
            try await self.render(state: state, to: url)
            if let post { try? post.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8) }
            self.lastExport = url
            self.message = "Exportado: \(url.lastPathComponent). Seu vídeo está pronto para revisão final e postagem."
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func exportAllClips(onlyFavorites: Bool = false) {
        let chosen = onlyFavorites ? clips.filter(\.favorite) : clips
        guard source != nil, !chosen.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "Exportar cortes aqui"; panel.message = "Cada corte é exportado com as suas edições (vídeo + legendas)."
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        commitHistory()
        let states = chosen.map { (clip: $0, state: state(of: $0)) }
        operation("Exportando os cortes…") {
            for (n, item) in states.enumerated() {
                try Task.checkCancellation()
                self.message = "Exportando corte \(n + 1) de \(states.count): \(item.clip.title)"
                let url = directory.appendingPathComponent(String(format: "%02d - %@.mp4", n + 1, self.safeName(item.clip.title)))
                try await self.render(state: item.state, to: url)
                let post = self.postText(item.clip)
                if !item.clip.caption.isEmpty { try? post.write(to: url.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8) }
            }
            self.lastExport = directory; self.message = "\(states.count) cortes exportados com as suas edições."
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }

    /// Renderiza um estado de edição em alta resolução, com legendas ao lado.
    func render(state: EditState, to url: URL) async throws {
        guard let source, let media else { throw StudioError("Escolha um vídeo primeiro.") }
        let timeline = try makeTimeline(state)
        if state.settings.fillFrame, faceTrack.isEmpty, (state.settings.vertical && media.size.width > media.size.height) || (!state.settings.vertical && media.size.height > media.size.width) {
            faceTrack = (try? await MediaEngine.trackFace(source, duration: media.duration) { text in Task { @MainActor in self.message = text } }) ?? []
        }
        let voice = state.settings.studioVoice ? try await VoiceStudio.process(video: source, isolation: state.settings.voiceIsolation, directory: Studio.cacheDirectory) { text in Task { @MainActor in self.message = text } } : nil
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        message = "Exportando \(url.lastPathComponent)…"
        try await MediaEngine.render(source: source, support: support, timeline: timeline, settings: state.settings, effects: state.effects,
                                     faceTrack: state.settings.fillFrame ? faceTrack : [], voice: voice, transitions: state.transitionMarks,
                                     destination: url, preview: false) { p in Task { @MainActor in self.progress = p } }
        let base = url.deletingPathExtension()
        if state.settings.captions || !timeline.captions.isEmpty {
            try Subtitles.write(timeline.captions).write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
            try Subtitles.write(timeline.captions, vtt: true).write(to: base.appendingPathExtension("vtt"), atomically: true, encoding: .utf8)
            try await writeTranslations(timeline.captions, base: base)
        }
        let used = Set(state.effects.filter { $0.kind == .imagem }.map(\.asset))
        let sources = Library.root.appendingPathComponent("fontes.txt")
        if FileManager.default.fileExists(atPath: sources.path), !used.isEmpty || !state.settings.musicFile.isEmpty {
            let target = URL(fileURLWithPath: base.path + " - fontes e licencas.txt")
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: sources, to: target)
        }
    }

    // MARK: Projeto

    /// Salva o projeto (só as decisões de edição; o vídeo original continua onde está). Depois do primeiro salvamento, salva sozinho.
    func saveProject(asNew: Bool = false) {
        guard source != nil else { return }
        commitHistory()
        if projectFolder == nil || asNew {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = (source?.deletingPathExtension().lastPathComponent ?? "Projeto") + ".cortaproject"
            panel.message = "O projeto guarda todas as edições (vídeo completo e cortes). O vídeo original não é copiado: mantenha-o no lugar."
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            projectFolder = folder
        }
        do { try writeProject(); message = "Projeto salvo. A partir de agora ele é salvo automaticamente." }
        catch { self.error = "Não foi possível salvar o projeto: \(error.localizedDescription)" }
    }
    func scheduleAutosave() {
        guard projectFolder != nil else { return }
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            try? writeProject()
        }
    }
    func writeProject() throws {
        guard let folder = projectFolder, let source, let media else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var supportName: String?
        if let support {
            let name = "apoio." + support.pathExtension
            let target = folder.appendingPathComponent(name)
            if support.standardizedFileURL != target.standardizedFileURL {
                try? FileManager.default.removeItem(at: target); try FileManager.default.copyItem(at: support, to: target)
            }
            supportName = name
        }
        var savedClips = clips
        if let id = activeClipID, let i = savedClips.firstIndex(where: { $0.id == id }) { savedClips[i].edit = snapshot() }
        var saved = SavedProject(mediaFile: "", supportFile: supportName, duration: media.duration, captions: captions, settings: settings,
                                 editSummary: summary, effects: effects, chat: chat, faceTrack: faceTrack, clips: savedClips, exclusions: exclusions,
                                 transitionMarks: transitionMarks)
        saved.splits = splits; saved.mainEdit = activeClipID == nil ? nil : mainEdit; saved.activeClip = activeClipID; saved.mediaPath = source.path
        saved.script = script.isEmpty ? nil : script; saved.gaze = gaze; saved.videoHook = videoHook
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(saved).write(to: folder.appendingPathComponent("projeto.json"), options: .atomic)
        lastSaved = Date(); unsavedChanges = false
    }

    func openProject() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.treatsFilePackagesAsDirectories = true
        panel.message = "Selecione a pasta .cortaproject."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        operation("Abrindo o projeto…") {
            let data = try Data(contentsOf: folder.appendingPathComponent("projeto.json"))
            guard data.count < 60_000_000 else { throw StudioError("Projeto grande demais.") }
            let saved = try SavedProject.decode(data)
            guard saved.version == 1 else { throw StudioError("Esta versão de projeto ainda não é compatível.") }
            func inside(_ name: String) throws -> URL {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else { throw StudioError("O projeto contém um caminho inválido.") }
                return folder.appendingPathComponent(name)
            }
            var source: URL
            if let path = saved.mediaPath, FileManager.default.fileExists(atPath: path) { source = URL(fileURLWithPath: path) }
            else if !saved.mediaFile.isEmpty, FileManager.default.fileExists(atPath: try inside(saved.mediaFile).path) { source = try inside(saved.mediaFile) }
            else {
                let locate = NSOpenPanel(); locate.allowedContentTypes = [.movie]
                locate.message = "Não encontrei o vídeo original deste projeto\(saved.mediaPath.map { " (\(URL(fileURLWithPath: $0).lastPathComponent))" } ?? ""). Mostre onde ele está."
                guard locate.runModal() == .OK, let picked = locate.url else { throw StudioError("O vídeo original não foi encontrado.") }
                source = picked
            }
            let info = try await MediaEngine.info(source)
            self.source = source; self.media = info; self.captions = saved.captions; self.settings = saved.settings
            self.support = try saved.supportFile.map(inside); self.summary = saved.editSummary
            self.effects = saved.effects ?? []; self.chat = saved.chat ?? []; self.faceTrack = saved.faceTrack ?? []; self.clips = saved.clips ?? []
            self.exclusions = saved.exclusions ?? []; self.transitionMarks = saved.transitionMarks ?? []; self.splits = saved.splits ?? []; self.videoHook = saved.videoHook
            self.mainEdit = saved.mainEdit; self.activeClipID = saved.activeClip
            self.script = saved.script ?? ""; self.gaze = saved.gaze
            self.projectFolder = folder; self.lastSaved = Date(); self.unsavedChanges = false
            self.thumbnails.load(source); self.waveform.load(source); self.selection = nil
            self.resetHistory(); self.showingOriginal = false; self.invalidatePreview()
            self.message = "Projeto aberto: \(self.editingTitle). Continue editando; ele é salvo automaticamente."
        }
    }

    // MARK: Divisões e trechos

    /// Divide o vídeo no ponto do cursor (tempo da edição), criando uma junção. Depois é só clicar no trecho e apagar.
    func splitAtPlayhead() { split(at: clock.time) }
    func split(at outputTime: Double) {
        guard let timeline = playhead.timeline, outputTime > 0.05, outputTime < playhead.duration - 0.05 else { return }
        let point = timeline.sourceTime(outputTime)
        guard !splits.contains(where: { abs($0 - point) < 0.04 }) else { return }
        commitHistory()
        splits.append(point); splits.sort()
        summary = "Vídeo dividido em \(timecode(outputTime)). Clique no trecho na faixa de vídeo para selecioná-lo e apagar (⌫)."
    }
    /// Trecho entre duas junções que contém o instante dado (tempo da edição).
    func segment(at outputTime: Double) -> (Double, Double)? {
        guard let timeline = playhead.timeline else { return nil }
        var offset = 0.0, bounds: [Double] = [0]
        for cut in timeline.cuts { offset += cut.duration; bounds.append(offset) }
        // Junções de pausas curtas não contam como divisões visíveis; usa as junções reais da linha do tempo.
        guard let i = bounds.lastIndex(where: { $0 <= outputTime + 0.0001 }), i + 1 < bounds.count else { return nil }
        return (bounds[i], bounds[i + 1])
    }
    func removeSplits() {
        guard !splits.isEmpty else { return }
        commitHistory(); splits = []
    }
    func hideCaption(_ id: Int) { setCaption(id) { $0.hidden = $0.hidden == true ? nil : true } }
}


/// Janela para colar ou importar o roteiro (texto, Markdown ou Word).
struct ScriptSheet: View {
    @ObservedObject var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Roteiro do vídeo", systemImage: "doc.text").font(.title3.weight(.semibold))
            Text("Cole aqui o texto que você leu na gravação. A IA usa o roteiro para saber a ordem certa das ideias e escolher, para cada frase, a tomada mais fiel e fluida. Ele não aparece no vídeo.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 13)).scrollContentBackground(.hidden).padding(8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Importar arquivo (.txt, .md, .docx)…", action: importFile)
                Text("\(text.split(whereSeparator: \.isWhitespace).count) palavras").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar") { dismiss() }
                Button("Usar este roteiro") { studio.script = text.trimmingCharacters(in: .whitespacesAndNewlines); studio.unsavedChanges = true; studio.scheduleAutosave(); dismiss() }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
            }
        }
        .padding(22).frame(width: 640, height: 520).preferredColorScheme(.dark).tint(Color(red: 0.83, green: 0.66, blue: 0.29))
        .onAppear { text = studio.script }
    }
    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText, UTType(filenameExtension: "docx") ?? .data, .rtf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if url.pathExtension.lowercased() == "docx" || url.pathExtension.lowercased() == "rtf",
           let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { text = attributed.string }
        else if let plain = try? String(contentsOf: url, encoding: .utf8) { text = plain }
    }
}
