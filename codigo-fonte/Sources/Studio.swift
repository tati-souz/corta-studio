import SwiftUI
import AVKit
import UniformTypeIdentifiers

@MainActor final class Studio: ObservableObject {
    typealias Snapshot = EditState
    /// Studio em uso (para os atalhos de teclado do menu).
    nonisolated(unsafe) static weak var current: Studio?

    @Published var source: URL?
    @Published var support: URL?
    @Published var media: MediaInfo?
    @Published var settings = EditSettings()
    @Published var captions: [Caption] = []
    @Published var effects: [Effect] = []
    @Published var chat: [ChatMessage] = []
    @Published var faceTrack: [FacePoint] = []
    @Published var player: AVPlayer?
    @Published var busy = false
    @Published var aiWorking = false
    @Published var progress: Double?
    @Published var message = "Seu próximo vídeo começa aqui."
    @Published var summary = ""
    @Published var error: String?
    @Published var previewReady = false
    @Published var showingOriginal = true
    @Published var lastExport: URL?
    /// Histórico de edição: cada alteração vira um passo (ajustes rápidos, como digitar ou arrastar, são agrupados).
    @Published private(set) var history: [Snapshot] = []
    @Published private(set) var historyIndex = 0
    var historyTask: Task<Void, Never>?
    @Published private(set) var pendingChange = false
    var canUndo: Bool { historyIndex > 0 || pendingChange }
    var canRedo: Bool { historyIndex < history.count - 1 }
    @Published var libraryVersion = 0 { willSet { Library.invalidate() } }
    @Published var clips: [ClipSuggestion] = []
    @Published var extraLanguages: Set<String> = []
    @Published var requestedTab: String?
    // Editor ao vivo e linha do tempo
    @Published var exclusions: [Cut] = []
    @Published var transitionMarks: [TransitionMark] = []
    @Published var splits: [Double] = []
    /// Análise de olhar do vídeo (modo roteiro) e o roteiro colado pelo usuário.
    @Published var gaze: GazeReport?
    @Published var coverCount = 0
    @Published var showCoverSheet = false
    @Published var showBrollSheet = false
    @Published var showReelsSheet = false
    @Published var showSafeZones = false
    @Published var videoHook: VideoHook?
    /// "Editar com IA" também escolhe um gancho em vídeo.
    @Published var autoVideoHook = UserDefaults.standard.bool(forKey: "CortaAutoVideoHook") { didSet { UserDefaults.standard.set(autoVideoHook, forKey: "CortaAutoVideoHook") } }
    /// Candidatos a gancho em vídeo encontrados pela IA (para escolher).
    @Published var hookCandidates: [(hook: VideoHook, text: String)] = []
    @Published var clipOptions = ClipFinderOptions() { didSet { if let data = try? JSONEncoder().encode(clipOptions) { UserDefaults.standard.set(data, forKey: "CortaClipOptions") } } }
    @Published var brollTarget: BrollTarget = .auto
    @Published var script = ""
    /// Corte aberto no editor (nil = vídeo completo) e a edição do vídeo completo guardada enquanto isso.
    @Published var activeClipID: UUID?
    var mainEdit: EditState?
    /// Projeto salvo: pasta, horário do último salvamento e se há alterações desde então.
    @Published var projectFolder: URL?
    @Published var lastSaved: Date?
    @Published var unsavedChanges = false
    var autosaveTask: Task<Void, Never>?
    @Published var imageRequest: ImageRequest?
    @Published var selection: EditorSelection?
    @Published var liveStatus = ""
    @Published var showingRendered = false
    let playhead = Playhead()
    let clock = PlayClock()
    let thumbnails = ThumbnailStore()
    let waveform = WaveformStore()
    var liveBuilt: MediaEngine.Composed?
    var liveItem: AVPlayerItem?
    var liveTask: Task<Void, Never>?
    var voiceURL: URL?
    var voiceKey = ""
    var voiceTask: Task<Void, Never>?
    private var timeObserver: Any?
    nonisolated static let cacheDirectory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CortaStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    let connection = ClaudeConnection()
    let scratch: URL
    private var task: Task<Void, Never>?
    private var previewURL: URL?
    init() {
        defer { Studio.current = self }
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("CortaStudio-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        Library.prepare()
        if let data = UserDefaults.standard.data(forKey: "CortaClipOptions"), let saved = try? JSONDecoder().decode(ClipFinderOptions.self, from: data) { clipOptions = saved }
        clipOptions.rangeStart = 0; clipOptions.rangeEnd = 0
        let player = AVPlayer(); player.actionAtItemEnd = .pause
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerMoved(time.seconds) }
        }
    }
    /// Monta a linha do tempo de um estado de edição (mesma regra para a tela, a exportação e os cortes).
    func makeTimeline(_ state: EditState) throws -> Timeline {
        guard let media else { throw StudioError("Escolha um vídeo primeiro.") }
        let away = state.settings.scriptMode && state.settings.cutLookAway ? (gaze?.away ?? []) : []
        return try Timeline.make(captions: state.captions, duration: media.duration, trimPauses: state.settings.trimPauses, exclusions: state.exclusions,
                                 splits: state.splits, lookAway: away, tightPauses: state.settings.scriptMode || state.settings.tightPauses, hook: state.videoHook)
    }
    func snapshot() -> Snapshot { Snapshot(captions: captions, settings: settings, effects: effects, exclusions: exclusions, transitionMarks: transitionMarks, splits: splits, videoHook: videoHook) }
    var selectedCount: Int { captions.filter(\.included).count }
    var editedDuration: Double {
        guard let media else { return 0 }
        return (try? makeTimeline(snapshot()).duration) ?? 0
    }
    func operation(_ text: String, work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; message = text; progress = nil; error = nil
        player?.pause()
        task = Task {
            defer { busy = false; aiWorking = false; progress = nil; task = nil }
            do { try await work() }
            catch is CancellationError { message = "Operação cancelada. Seus arquivos originais foram preservados." }
            catch { NSLog("Corta Studio erro: %@", String(describing: error)); self.error = error.localizedDescription; message = "Não foi possível concluir esta etapa." }
        }
    }
    func cancel() { task?.cancel(); message = "Cancelando…" }
    /// Arquivos no iCloud que não estão no Mac (só o "atalho"): baixa antes, com aviso, em vez de o app ficar parado esperando.
    static func ensureDownloaded(_ url: URL, status: @MainActor @escaping (String) -> Void) async throws {
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let start = Date()
        while true {
            try Task.checkCancellation()
            var fresh = url; fresh.removeAllCachedResourceValues()
            if (try? fresh.resourceValues(forKeys: keys))?.ubiquitousItemDownloadingStatus == .current { return }
            let elapsed = Int(Date().timeIntervalSince(start))
            await status("Baixando “\(url.lastPathComponent)” do iCloud (\(elapsed / 60) min \(elapsed % 60) s)… Para não esperar da próxima vez: no Finder, botão direito ▸ Manter Baixado.")
            if elapsed > 3600 { throw StudioError("O iCloud não terminou de baixar o vídeo em 1 hora. Verifique a internet e o espaço livre do Mac.") }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
    func chooseVideo() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .audio]; panel.allowsMultipleSelection = false
        panel.message = "Escolha um vídeo (horizontal ou vertical) ou uma narração só em áudio. O original será preservado."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadVideo(url)
    }
    func loadVideo(_ url: URL) {
        operation("Abrindo seu vídeo…") {
            var url = url
            try await Self.ensureDownloaded(url) { text in self.message = text }
            // Narração só em áudio: vira um vídeo vertical para editar com imagens e textos (modelo Narração + texto animado).
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio), !type.conforms(to: .movie) {
                self.message = "Preparando a narração para edição…"
                url = try await MediaEngine.videoFromAudio(url, into: Library.root.appendingPathComponent("Narracoes", isDirectory: true))
            }
            let info = try await MediaEngine.info(url)
            self.source = url; self.media = info; self.captions = []; self.summary = ""
            self.effects = []; self.chat = []; self.faceTrack = MediaEngine.loadFaceCache(url); self.clips = []; self.exclusions = []; self.transitionMarks = []; self.splits = []; self.videoHook = nil; self.selection = nil; self.gaze = nil
            self.activeClipID = nil; self.mainEdit = nil; self.projectFolder = nil; self.lastSaved = nil; self.unsavedChanges = false
            self.voiceURL = nil; self.voiceKey = ""; self.liveItem = nil; self.liveBuilt = nil
            self.support = nil; self.lastExport = nil
            var fresh = EditSettings()
            fresh.applyPlatform(info.size.height > info.size.width ? "Instagram Reels" : "YouTube")
            self.settings = fresh
            self.previewReady = false; self.showingOriginal = false; self.showingRendered = false
            self.player?.replaceCurrentItem(with: AVPlayerItem(url: url))
            self.thumbnails.load(url); self.waveform.load(url)
            self.clock.time = 0
            self.scheduleLive(delay: 0)
            if let old = self.previewURL { try? FileManager.default.removeItem(at: old) }; self.previewURL = nil
            self.resetHistory()
            self.message = "Vídeo pronto. Marque as opções e clique em Editar com IA."
        }
    }
    func invalidatePreview() {
        previewReady = false
        scheduleLive()
        scheduleHistory()
    }

    // MARK: Desfazer / refazer

    func resetHistory() { historyTask?.cancel(); pendingChange = false; history = [snapshot()]; historyIndex = 0 }
    private func scheduleHistory() {
        historyTask?.cancel()
        if !pendingChange { pendingChange = true }
        historyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            commitHistory()
        }
    }
    /// Registra o estado atual como um passo, se ele mudou desde o último registrado.
    func commitHistory() {
        historyTask?.cancel(); historyTask = nil
        if pendingChange { pendingChange = false }
        guard source != nil else { return }
        let now = snapshot()
        if history.isEmpty { history = [now]; historyIndex = 0; return }
        guard history[historyIndex] != now else { return }
        unsavedChanges = true
        scheduleAutosave()
        history = Array(history.prefix(historyIndex + 1)) + [now]
        if history.count > 150 { history.removeFirst(history.count - 150) }
        historyIndex = history.count - 1
    }
    func restore(_ s: Snapshot) {
        captions = s.captions; settings = s.settings; effects = s.effects; exclusions = s.exclusions; transitionMarks = s.transitionMarks; splits = s.splits; videoHook = s.videoHook
        if case .effect(let id)? = selection, !effects.contains(where: { $0.id == id }) { selection = nil }
    }
    func showOriginal(at time: Double = 0) {
        guard let source else { return }
        player?.pause(); player?.replaceCurrentItem(with: AVPlayerItem(url: source)); showingOriginal = true; showingRendered = false
        player?.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func showPreview() {
        guard previewReady, let previewURL else { return }
        player?.pause(); player?.replaceCurrentItem(with: AVPlayerItem(url: previewURL)); showingOriginal = false; showingRendered = true
    }
    func transcribe() {
        operation("Preparando a transcrição local…") {
            try await self.performTranscription()
            self.message = "Legendas prontas. Revise o texto ou clique em Editar com IA."
        }
    }
    func performTranscriptionPublic() async throws { try await performTranscription() }
    /// Analisa o olhar do vídeo inteiro (uma vez por vídeo; depois vem do cache).
    func analyzeGaze() async throws {
        guard gaze == nil, let source, let media else { return }
        message = "Analisando para onde você olha (câmera, roteiro, lado)…"
        gaze = try await MediaEngine.analyzeGaze(source, duration: media.duration, cache: Studio.cacheDirectory) { text in Task { @MainActor in self.message = text } }
        scheduleLive(delay: 0)
    }
    func analyzeGazeNow() { operation("Analisando o olhar…") { self.gaze = nil; try await self.analyzeGaze(); self.message = self.gazeSummary ?? "Análise pronta." } }
    var gazeSummary: String? {
        guard let gaze else { return nil }
        let camera = max(0, 1 - gaze.down - gaze.side)
        return "Olhar no vídeo: \(Int(camera * 100))% para a câmera · \(Int(gaze.down * 100))% para baixo (roteiro) · \(Int(gaze.side * 100))% para o lado"
    }
    /// Depois da edição: quanto do que ficou ainda foi falado olhando para fora — e o que o app fez a respeito.
    func lookAwayNote() -> String? {
        guard let gaze, let timeline = try? makeTimeline(snapshot()), timeline.duration > 0 else { return nil }
        var away = 0.0
        for cut in timeline.cuts { for a in gaze.away { away += max(0, min(cut.end, a.end) - max(cut.start, a.start)) } }
        let share = away / timeline.duration
        guard share > 0.03 else { return "Olhar: praticamente toda a edição ficou com você olhando para a câmera." }
        if share > 0.10 && !settings.eyeContact { settings.eyeContact = true; settings.eyeContactStrength = 0.6 }
        return "Olhar: em \(Int(share * 100))% do vídeo editado você ainda fala olhando para fora (não havia outra tomada boa). Esses trechos aparecem em laranja na faixa de vídeo\(settings.eyeContact ? "; liguei a correção de olhar" : ""). Para escondê-los, clique em “Cobrir olhadas” na barra da linha do tempo: o app põe imagens ligadas à narração sobre esses trechos."
    }
    /// Quando um corte está aberto, a IA só pode mexer dentro dele.
    var clipScope: String {
        guard let id = activeClipID, let clip = clips.first(where: { $0.id == id }) else { return "" }
        return "IMPORTANTE: você está editando o corte curto “\(clip.title)” (legendas \(clip.startID) a \(clip.endID)). Não inclua falas fora desse intervalo; ajuste apenas dentro dele.\n\n"
    }
    private func performTranscription() async throws {
        guard let source else { throw StudioError("Escolha um vídeo primeiro.") }
        // Transcrição guardada em disco por vídeo: reabrir o mesmo vídeo não transcreve de novo.
        let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let cached = Self.cacheDirectory.appendingPathComponent("transcricao-" + SHA256Hex.of("\(source.path)|\(modified)|t-v1") + ".json")
        if let data = try? Data(contentsOf: cached), let saved = try? JSONDecoder().decode([Caption].self, from: data), !saved.isEmpty {
            captions = saved; invalidatePreview(); return
        }
        defer { if !captions.isEmpty, let data = try? JSONEncoder().encode(captions) { try? data.write(to: cached, options: .atomic) } }
        if #available(macOS 26.0, *) {
            let result = try await MediaEngine.transcribe(source, directory: scratch) { text in Task { @MainActor in self.message = text } }
            try Task.checkCancellation()
            guard let media else { throw StudioError("O vídeo não está mais aberto.") }
            self.captions = result.compactMap { cue in
                var cue = cue; cue.start = max(0, cue.start); cue.end = min(media.duration, cue.end)
                return cue.end > cue.start ? cue : nil
            }.enumerated().map { i, cue in var cue = cue; cue.id = i; return cue }
            invalidatePreview()
        } else { throw StudioError("A transcrição local desta versão precisa do macOS 26 ou posterior. Neste sistema, importe um SRT para continuar editando.") }
    }
    func prepareFace() async {
        guard let source, let media, settings.fillFrame,
              (settings.vertical && media.size.width > media.size.height) || (!settings.vertical && media.size.height > media.size.width) else { return }
        message = "Acompanhando o rosto para o reenquadramento…"
        // Só os trechos da edição atual (num vídeo longo, rastrear tudo levava minutos); o resultado fica guardado em disco.
        let ranges = (try? makeTimeline(snapshot()).cuts) ?? [Cut(start: 0, end: media.duration)]
        if let track = try? await MediaEngine.trackFace(source, ranges: ranges, known: faceTrack, status: { text in Task { @MainActor in self.message = text } }) {
            faceTrack = track
        }
    }

    // MARK: IA

    /// Edição completa: transcreve (se preciso), acompanha o rosto, pede ao Claude as decisões e gera a prévia.
    func runAIEdit() {
        operation("Preparando a edição…") {
            if self.captions.isEmpty { try await self.performTranscription() }
            if self.settings.removeFillers { self.markObviousFillers() }
            if self.settings.scriptMode { try await self.analyzeGaze() }
            await self.prepareFace()
            if !self.connection.connected { await self.connection.restore() }
            guard self.connection.connected else {
                self.message = "Modo básico (sem IA): aplicando seus ajustes, redução de pausas e legendas."
                self.summary = "Modo básico: a IA não está conectada, então não houve cortes inteligentes, zooms de ênfase, textos nem imagens. Conecte em IA e conta para a edição completa."
                self.showingOriginal = false; self.scheduleLive(delay: 0)
                return
            }
            self.aiWorking = true
            self.message = "O Claude está montando a edição a partir das opções marcadas…"
            let request = """
            Faça a edição completa deste vídeo de acordo com os ajustes marcados (plataforma \(self.settings.platform), \
            \(self.settings.shortVideo ? "corte curto de ~\(Int(self.settings.targetSeconds)) s" : "vídeo completo"), ritmo \(self.settings.style)). \
            Decida cortes, efeitos, correções de legenda e o gancho conforme os interruptores.
            \(self.autoVideoHook ? "GANCHO EM VÍDEO LIGADO: escolha em video_hook o ápice da fala (3 a 8 s) para abrir o vídeo, com transition \"rebobinar\"." : "Não mexa em video_hook.")
            \(self.settings.scriptMode ? "MODO ROTEIRO ATIVO: escolha as melhores tomadas, remova recomeços, erros e leituras, e monte uma narração fluida, como se eu falasse olhando para a câmera o tempo todo." : "")
            """
            let result = try await self.connection.edit(request: self.clipScope + request, captions: self.captions, settings: self.settings, effects: self.effects,
                                                        duration: self.media?.duration ?? 0, history: [], gaze: self.settings.scriptMode ? self.gaze : nil, script: self.settings.scriptMode ? self.script : "",
                                                        videoHook: self.videoHook, transitionMarks: self.transitionMarks)
            try Task.checkCancellation()
            try self.apply(result)
            var reply = result.reply + (result.warnings.isEmpty ? "" : "\n\nAtenção: " + result.warnings.joined(separator: " · "))
            if self.settings.scriptMode, let note = self.lookAwayNote() { reply += "\n\n" + note }
            self.chat.append(ChatMessage(fromUser: false, text: reply))
            self.aiWorking = false
            try await self.runActions(result.actions)
            self.showingOriginal = false; self.scheduleLive(delay: 0)
            self.message = "Edição pronta. Confira na tela e peça ajustes no chat."
        }
    }

    func sendChat(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, source != nil else { return }
        let history = chat
        chat.append(ChatMessage(fromUser: true, text: request))
        operation("O Claude está ajustando a edição…") {
            if self.captions.isEmpty { try await self.performTranscription() }
            if !self.connection.connected { await self.connection.restore() }
            guard self.connection.connected else { throw StudioError("Conecte sua conta Claude em IA e conta para usar o chat.") }
            self.aiWorking = true
            let result = try await self.connection.edit(request: self.clipScope + request, captions: self.captions, settings: self.settings, effects: self.effects,
                                                        duration: self.media?.duration ?? 0, history: history, gaze: self.settings.scriptMode ? self.gaze : nil, script: self.settings.scriptMode ? self.script : "",
                                                        videoHook: self.videoHook, transitionMarks: self.transitionMarks)
            try Task.checkCancellation()
            try self.apply(result)
            self.chat.append(ChatMessage(fromUser: false, text: result.reply + (result.warnings.isEmpty ? "" : "\n\nAtenção: " + result.warnings.joined(separator: " · "))))
            self.aiWorking = false
            try await self.runActions(result.actions)
            if self.settings.fillFrame { await self.prepareFace() }
            self.showingOriginal = false; self.scheduleLive(delay: 0)
            self.message = "Ajuste aplicado. Confira a prévia."
        }
    }

    /// Remove vícios inequívocos ("hum", "hã", "ééé") sem precisar da IA.
    func markObviousFillers() {
        captions = captions.map { cue in
            var cue = cue
            let found = cue.obviousFillerIndexes
            if !found.isEmpty, found.count < cue.text.split(whereSeparator: { $0.isWhitespace }).count {
                cue.removedWords = Array(Set(cue.removedWords ?? []).union(found)).sorted()
            }
            return cue
        }
    }
    func restoreWords(_ id: Int) {
        commitHistory()
        if let i = captions.firstIndex(where: { $0.id == id }) { captions[i].removedWords = nil }
    }
    private func apply(_ result: ClaudeConnection.EditResult) throws {
        let newSettings = try settings.merging(result.settings)
        commitHistory()
        captions = captions.map { cue in
            var cue = cue
            if let keep = result.keep { cue.included = keep.contains(cue.id) }
            if let text = result.captionEdits[cue.id], text != cue.text { cue.text = text; cue.removedWords = nil }
            if let removed = result.removedWords[cue.id] { cue.removedWords = removed.isEmpty ? nil : removed }
            return cue
        }
        if let list = result.effects { effects = list }
        if let hook = result.videoHook { videoHook = hook }
        if let marks = result.transitionMarks { transitionMarks = marks }
        settings = newSettings
        summary = result.reply + (result.warnings.isEmpty ? "" : "\nAtenção ao contexto: " + result.warnings.joined(separator: " · "))
        invalidatePreview()
    }
    func undo() {
        commitHistory()
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        restore(history[historyIndex])
        message = "Desfeito (\(historyIndex) passo(s) restantes para trás)."
    }
    func redo() {
        commitHistory()
        guard historyIndex < history.count - 1 else { return }
        historyIndex += 1
        restore(history[historyIndex])
        message = "Refeito (\(history.count - 1 - historyIndex) passo(s) à frente)."
    }
    func restoreCuts() {
        commitHistory()
        captions = captions.map { var cue = $0; cue.included = true; return cue }
        summary = "Todos os trechos restaurados. Gere uma nova prévia."; invalidatePreview()
    }
    func removeEffect(_ id: UUID) {
        commitHistory()
        effects.removeAll { $0.id == id }
    }

    // MARK: Vários cortes (ver Workspace.swift)

    func writeTranslations(_ captions: [Caption], base: URL) async throws {
        guard !extraLanguages.isEmpty, !captions.isEmpty else { return }
        if !connection.connected { await connection.restore() }
        guard connection.connected else { throw StudioError("Conecte sua conta Claude para traduzir as legendas, ou desmarque as legendas traduzidas.") }
        for language in extraLanguages.sorted() {
            message = "Traduzindo legendas para \(language)…"
            let lines = try await connection.translate(captions.map(\.text), to: language)
            let translated = zip(captions, lines).map { var cue = $0; cue.text = $1; return cue }
            let code = ["Inglês": "en", "Espanhol": "es", "Italiano": "it", "Francês": "fr"][language] ?? language
            try Subtitles.write(translated).write(to: URL(fileURLWithPath: base.path + "-\(code).srt"), atomically: true, encoding: .utf8)
            try Subtitles.write(translated, vtt: true).write(to: URL(fileURLWithPath: base.path + "-\(code).vtt"), atomically: true, encoding: .utf8)
        }
    }

    // MARK: Arquivos

    func importSRT() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey]); guard (values.fileSize ?? 0) < 10_000_000 else { throw StudioError("O arquivo de legendas é grande demais.") }
            let loaded = try Subtitles.parse(String(contentsOf: url, encoding: .utf8))
            guard let media else { throw StudioError("Escolha um vídeo antes de importar legendas.") }
            _ = try Timeline.make(captions: loaded, duration: media.duration, trimPauses: false)
            commitHistory()
            captions = loaded; invalidatePreview(); message = "Legendas importadas. Revise o texto e selecione os trechos."
        } catch { self.error = error.localizedDescription }
    }
    func chooseSupport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        support = url; settings.splitScreen = true; invalidatePreview()
    }
    func trackFaceNow() {
        guard let source, let media else { return }
        operation("Acompanhando o rosto ao longo do vídeo…") {
            self.faceTrack = try await MediaEngine.trackFace(source, duration: media.duration) { text in Task { @MainActor in self.message = text } }
            self.settings.fillFrame = true; self.invalidatePreview()
            self.message = "Reenquadramento pelo rosto pronto (\(self.faceTrack.count) pontos). Gere a prévia para conferir."
        }
    }
    private func studioVoice() async throws -> URL? {
        guard settings.studioVoice, let source else { return nil }
        return try await VoiceStudio.process(video: source, isolation: settings.voiceIsolation, directory: Self.cacheDirectory) { text in Task { @MainActor in self.message = text } }
    }
    func cleanUp() { task?.cancel(); liveTask?.cancel(); voiceTask?.cancel(); player?.pause(); try? FileManager.default.removeItem(at: scratch) }
    func testExport() {
        operation("Testando a exportação com um vídeo sintético…") {
            let directory = self.scratch.appendingPathComponent("test-\(UUID().uuidString)")
            try await StudioTests.run(directory: directory)
            self.message = "Teste concluído: cortes, legendas, efeitos, áudio e exportação horizontal/vertical verificados."
            NSWorkspace.shared.activateFileViewerSelecting([directory])
        }
    }
}

private let accent = Color(red: 0.83, green: 0.66, blue: 0.29)
private let canvas = Color(red: 0.067, green: 0.063, blue: 0.058)
private let surface = Color(red: 0.105, green: 0.098, blue: 0.090)

struct StudioView: View {
    @StateObject private var studio = Studio()
    @State private var accountSheet = false
    @State private var rightTab = "Chat"
    @State private var draft = ""
    @State private var timelineHeight: CGFloat = 250
    @State private var scriptSheet = false
    @StateObject private var looks = SettingPreviews()
    private func refreshLooks() {
        looks.refresh(source: studio.source, sourceTime: studio.playhead.timeline?.sourceTime(studio.clock.time) ?? studio.clock.time, settings: studio.settings)
    }
    @State private var dragStartHeight: CGFloat?
    var body: some View {
        GeometryReader { window in
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            // Colunas redimensionáveis: arraste as divisórias entre os painéis.
            HSplitView {
                settingsPanel.frame(minWidth: 210, idealWidth: 276, maxWidth: 420)
                previewPanel.frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
                rightPanel.frame(minWidth: 290, idealWidth: 370, maxWidth: 560)
            }
            .frame(minHeight: 260)
            .clipped()
            // Alça para aumentar ou diminuir a linha do tempo
            ZStack {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 7)
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 46, height: 3)
            }
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture().onChanged { value in
                if dragStartHeight == nil { dragStartHeight = timelineHeight }
                timelineHeight = min(560, max(120, (dragStartHeight ?? 250) - value.translation.height))
            }.onEnded { _ in dragStartHeight = nil })
            // A linha do tempo nunca ocupa mais que ~40% da janela, para tudo caber em telas menores.
            TimelinePanel(studio: studio, playhead: studio.playhead).frame(height: max(110, min(timelineHeight, window.size.height - 440)))
            Divider().opacity(0.4)
            footer
        }
        }
        .background(canvas).foregroundStyle(Color.white.opacity(0.92)).tint(accent)
        .frame(minWidth: 960, minHeight: 600)
        .onChange(of: studio.requestedTab) { if let tab = studio.requestedTab { rightTab = tab; studio.requestedTab = nil } }
        .onChange(of: studio.exclusions) { studio.invalidatePreview() }
        .onChange(of: studio.transitionMarks) { studio.invalidatePreview() }
        .onChange(of: studio.videoHook) { studio.invalidatePreview() }
        .onChange(of: studio.source) { refreshLooks() }
        .onChange(of: studio.settings) { refreshLooks() }
        .onChange(of: studio.clock.playing) { if !studio.clock.playing { refreshLooks() } }
        .onReceive(studio.clock.$time.debounce(for: .milliseconds(700), scheduler: RunLoop.main)) { _ in if !studio.clock.playing { refreshLooks() } }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $accountSheet) { AccountView(connection: studio.connection) }
        .sheet(item: $studio.imageRequest) { request in ImageFinderSheet(studio: studio, request: request) }
        .sheet(isPresented: $scriptSheet) { ScriptSheet(studio: studio) }
        .sheet(isPresented: $studio.showBrollSheet) { BrollSheet(studio: studio) }
        .sheet(isPresented: $studio.showReelsSheet) { ReelsEthosSheet(studio: studio) }
        .alert("Confira esta etapa", isPresented: Binding(get: { studio.error != nil }, set: { if !$0 { studio.error = nil } })) {
            Button("Entendi", role: .cancel) { studio.error = nil }
        } message: { Text(studio.error ?? "") }
        .onChange(of: studio.settings) { studio.invalidatePreview() }
        .onChange(of: studio.captions) { studio.invalidatePreview() }
        .onChange(of: studio.effects) { studio.invalidatePreview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in studio.cleanUp() }
        .task { await studio.connection.restore() }
        .task { await runDiagnostics() }
    }
    /// Modo de diagnóstico: `--open vídeo [--demo] [--snapshot arquivo.png]` abre um vídeo, exercita o editor e salva a janela.
    private func runDiagnostics() async {
        let args = CommandLine.arguments
        if args.contains("--open") { FileHandle.standardError.write("DIAG inicio \(args.count) args\n".data(using: .utf8)!) }
        guard let i = args.firstIndex(of: "--open"), args.count > i + 1 else { return }
        setvbuf(stdout, nil, _IONBF, 0)
        while studio.busy { try? await Task.sleep(nanoseconds: 200_000_000) }
        studio.loadVideo(URL(fileURLWithPath: args[i + 1]))
        print("DIAG load requested busy=\(studio.busy) msg=\(studio.message)")
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        print("DIAG after load src=\(studio.source?.lastPathComponent ?? "-") msg=\(studio.message) erro=\(studio.error ?? "-")")
        if args.contains("--workflow-test") {
            func wait() async { try? await Task.sleep(nanoseconds: 900_000_000) }
            studio.captions = (0..<6).map { Caption(id: $0, start: Double($0) * 3 + 0.2, end: Double($0) * 3 + 2.6, text: "frase número \($0)") }
            await wait()
            let a = ClipSuggestion(title: "Corte A", hook: "Gancho A", reason: "teste", startID: 1, endID: 3)
            let b = ClipSuggestion(title: "Corte B", hook: "Gancho B", reason: "teste", startID: 4, endID: 5)
            studio.clips = [a, b]
            let mainDuration = studio.editedDuration
            studio.openClip(a); await wait()
            print("FLOW abriu A: \(studio.editingTitle) duração \(String(format: "%.1f", studio.editedDuration)) (vídeo completo \(String(format: "%.1f", mainDuration)))")
            studio.hideCaption(2); studio.split(at: 2.0); await wait()
            if let seg = studio.segment(at: 1.0) { studio.selection = .range(seg.0, seg.1); studio.deleteSelection() }
            studio.addEffect(.zoom, start: 0.5, end: 1.5, zoomStyle: "corte"); await wait()
            let editedA = studio.editedDuration
            print("FLOW editou A: duração \(String(format: "%.1f", editedA)), efeitos \(studio.effects.count), legenda 2 oculta \(studio.captions[2].hidden == true)")
            studio.openClip(b); await wait()
            print("FLOW abriu B: \(studio.editingTitle) efeitos \(studio.effects.count) oculta2 \(studio.captions[2].hidden == true)")
            studio.openMainVideo(); await wait()
            print("FLOW vídeo completo: duração \(String(format: "%.1f", studio.editedDuration)) igual ao início \(abs(studio.editedDuration - mainDuration) < 0.01)")
            let stateA = studio.state(of: studio.clips[0])
            let tA = try? Timeline.make(captions: stateA.captions, duration: studio.media!.duration, trimPauses: stateA.settings.trimPauses, exclusions: stateA.exclusions, splits: stateA.splits)
            print("FLOW A guardado (fechado): duração \(String(format: "%.1f", tA?.duration ?? -1)) = editada \(abs((tA?.duration ?? 0) - editedA) < 0.01), editado \(studio.clipWasEdited(studio.clips[0]))")
            studio.openClip(studio.clips[0]); await wait()
            print("FLOW reabriu A: duração \(String(format: "%.1f", studio.editedDuration)) efeitos \(studio.effects.count)")
            let out = URL(fileURLWithPath: NSTemporaryDirectory() + "corta-corteA.mp4")
            do { try await studio.render(state: studio.state(of: studio.clips[1]), to: out); let d = try await MediaEngine.info(out).duration; print("FLOW exportou B fechado: \(String(format: "%.1f", d)) s") } catch { print("FLOW erro export \(error)") }
            studio.projectFolder = URL(fileURLWithPath: NSTemporaryDirectory() + "corta-teste.cortaproject")
            do {
                try studio.writeProject()
                let saved = try SavedProject.decode(Data(contentsOf: studio.projectFolder!.appendingPathComponent("projeto.json")))
                print("FLOW projeto salvo: corte ativo \(saved.activeClip == studio.activeClipID), vídeo \(saved.mediaPath != nil), cortes editados \(saved.clips?.filter { $0.edit != nil }.count ?? 0), principal guardado \(saved.mainEdit != nil)")
            } catch { print("FLOW erro projeto \(error)") }
            studio.openMainVideo(); await wait()
            print("FLOW B não editado aparece como editado? \(studio.clipWasEdited(studio.clips[1]))")
            exit(0)
        }
        if args.contains("--clip-ui") {
            studio.captions = (0..<6).map { Caption(id: $0, start: Double($0) * 3 + 0.2, end: Double($0) * 3 + 2.6, text: "frase número \($0)") }
            studio.clips = [ClipSuggestion(title: "O que você pode melhorar", hook: "E se o problema não for a opinião dos outros?", reason: "Tem começo, meio e fim.", startID: 1, endID: 3),
                            ClipSuggestion(title: "A virtude nasce do hábito", hook: "Por que repetir te transforma?", reason: "Ideia completa em 40 s.", startID: 4, endID: 5)]
            for (i, parts) in [[21, 18, 22, 14], [15, 13, 17, 9]].enumerated() {
                for (p, part) in ClipSuggestion.scoreParts.enumerated() { studio.clips[i].scores[part.id] = parts[p] }
                studio.clips[i].score = parts.reduce(0, +); studio.clips[i].topic = i == 0 ? "maturidade" : "hábito"
                studio.clips[i].caption = "Texto de exemplo do post, no tom do canal. Qual hábito você quer formar?"; studio.clips[i].hashtags = ["#virtude", "#formação", "#caráter"]
            }
            studio.clips[0].favorite = true
            try? await Task.sleep(nanoseconds: 800_000_000)
            studio.openClip(studio.clips[0]); try? await Task.sleep(nanoseconds: 800_000_000)
            studio.hideCaption(2); try? await Task.sleep(nanoseconds: 1_200_000_000)
            rightTab = "Cortes"; try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if args.contains("--ui-load-test") {
            // Vídeo longo transcrito + alguns cortes, para medir se a interface fica pesada.
            try? await studio.performTranscriptionPublic()
            studio.clips = stride(from: 40, to: 900, by: 140).map { ClipSuggestion(title: "Corte \($0)", hook: "Gancho", reason: "teste", startID: $0, endID: $0 + 10) }
            if let tab = args.firstIndex(of: "--tab").map({ args[$0 + 1] }) { rightTab = tab }
            studio.seek(600)
            print("CARREGADO \(studio.captions.count) legendas · \(studio.clips.count) cortes")
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            exit(0)
        }
        if let k = args.firstIndex(of: "--clip-export-test"), args.count > k + 1 {
            // Abre um corte (legendas a–b, com gancho em vídeo) como o usuário faria e exporta, medindo cada passo.
            let parts = args[k + 1].split(separator: ":").map(String.init)
            let a = Int(parts[0]) ?? 433, b = Int(parts[1]) ?? 444
            var tt = Date()
            try? await studio.performTranscriptionPublic()
            print("TEMPO transcrição: \(Int(Date().timeIntervalSince(tt))) s · \(studio.captions.count) legendas"); tt = Date()
            var clip = ClipSuggestion(title: "Teste", hook: "Gancho", reason: "teste", startID: a, endID: b)
            clip.template = "reels-ethos"
            if let ca = studio.captions.first(where: { $0.id == a + 4 }) { clip.videoHook = VideoHook(start: ca.start, end: ca.end) }
            studio.clips = [clip]
            var t0 = Date()
            studio.openClip(clip)
            print("TEMPO abrir corte (bloqueando a tela): \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
            t0 = Date(); _ = studio.editedDuration; print("TEMPO duração editada: \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
            t0 = Date(); _ = studio.clipWasEdited(clip); print("TEMPO clipWasEdited: \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
            t0 = Date(); _ = studio.generatedState(clip); print("TEMPO generatedState: \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
            t0 = Date(); _ = studio.visibleTextBoxes(); print("TEMPO caixas da prévia: \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
            t0 = Date(); _ = Library.imageNames; _ = Library.musicNames; print("TEMPO ler biblioteca: \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
            if let v = ProcessInfo.processInfo.environment["CORTA_FRAME_SCALE"].flatMap(Double.init) { studio.settings.frameScale = v; studio.invalidatePreview() }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            print("ROSTO \(studio.faceTrack.count) pontos")
            print("PRÉVIA ao vivo pronta: \(studio.liveItem != nil) · erro \(studio.error ?? "-") · duração \(String(format: "%.1f", studio.editedDuration)) s · status \(studio.liveStatus) · item \(studio.player?.currentItem?.status.rawValue ?? -1)")
            if let item = studio.player?.currentItem, let out = ProcessInfo.processInfo.environment["CORTA_PREVIEW_PNG"] {
                let g = AVAssetImageGenerator(asset: item.asset); g.videoComposition = item.videoComposition
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                for t in [1.0, 10.0] {
                    if let cg = try? await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out + "-\(Int(t)).png"))
                        print("QUADRO da prévia em \(t) s salvo (\(cg.width)×\(cg.height))")
                    } else { print("QUADRO da prévia em \(t) s: FALHOU") }
                }
            }
            if parts.count > 2 {
                t0 = Date()
                do { try await studio.render(state: studio.state(of: clip), to: URL(fileURLWithPath: parts[2])); print("EXPORTOU em \(Int(Date().timeIntervalSince(t0))) s · \(String(format: "%.1f", try await MediaEngine.info(URL(fileURLWithPath: parts[2])).duration)) s") }
                catch { print("ERRO export \(error)") }
            }
            exit(0)
        }
        if let k = args.firstIndex(of: "--template-test"), args.count > k + 1, let t = ReelsTemplate(rawValue: args[k + 1]) {
            var o = TemplateOptions()
            if let files = ProcessInfo.processInfo.environment["CORTA_TEMPLATE_FILES"] { o.files = files.split(separator: ":").map { URL(fileURLWithPath: String($0)) }; o.media = "arquivos" }
            o.question = "Por que adiamos o que mais importa?"
            o.captionStyle = t == .narracao ? "Bege" : "Hormozi"
            if t == .janelinha { o.position = "inf-dir" }
            if t == .recortado { o.scale = 0.8; o.position = "direita" }
            studio.applyTemplate(t, o)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while studio.busy { try? await Task.sleep(nanoseconds: 500_000_000) }
            if t == .lista {
                for (i, at) in [3.0, 8.0, 13.0].enumerated() {
                    studio.seek(at); try? await Task.sleep(nanoseconds: 400_000_000)
                    studio.addListItemHere()
                    if let j = studio.effects.lastIndex(where: { $0.style == "lista" }) { studio.effects[j].text = ["Ouvir antes de responder", "Pensar antes de se defender", "Agradecer a correção"][i] }
                }
            }
            print("MODELO \(t.name) · erro \(studio.error ?? "-") · versão aberta \(studio.activeClipID != nil) · cortes \(studio.clips.count) · efeitos \(studio.effects.map { "\($0.kind.rawValue):\($0.style)" })")
            print("AJUSTES vertical \(studio.settings.vertical) legenda \(studio.settings.captionStyle)/\(studio.settings.captionMode) pausas \(studio.settings.trimPauses)/\(studio.settings.tightPauses)")
            if let out = args.firstIndex(of: "--template-out").map({ args[$0 + 1] }) {
                do { try await studio.render(state: studio.snapshot(), to: URL(fileURLWithPath: out)); print("EXPORTOU") } catch { print("ERRO export \(error)") }
            }
            exit(0)
        }
        if let k = args.firstIndex(of: "--web-image-test"), args.count > k + 1 {
            // Abre a busca de imagem na aba Google/Pinterest com uma busca pronta (para conferir a página dentro da janela).
            studio.imageRequest = ImageRequest(start: 1, end: 4, narration: "Você pode estudar muito sobre casamento")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NotificationCenter.default.post(name: .init("CortaWebImageTest"), object: args[k + 1])
            try? await Task.sleep(nanoseconds: 9_000_000_000)
        }
        if args.contains("--tap-test") {
            studio.effects = [Effect(kind: .texto, start: 2, end: 12, text: "O hábito forma o caráter", style: "destaque"),
                              Effect(kind: .texto, start: 2, end: 12, text: "Primeiro: a correção", style: "capitulo")]
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            studio.seek(5); try? await Task.sleep(nanoseconds: 1_500_000_000)
            let boxes = studio.visibleTextBoxes()
            for b in boxes { print("CAIXA \(b.target) \(String(format: "%.2f %.2f %.2f %.2f", b.box.minX, b.box.minY, b.box.width, b.box.height))") }
            if let chapter = boxes.first(where: { if case .effect(let id) = $0.target { return id == studio.effects[1].id }; return false }) {
                studio.tapPreview(at: CGPoint(x: chapter.box.midX, y: chapter.box.midY))
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                print("CLIQUE selecionou capítulo: \(studio.selection == .effect(studio.effects[1].id)) aba \(rightTab)")
            }
        }
        if let k = args.firstIndex(of: "--hook-test"), args.count > k + 1 {
            let start = Date()
            studio.findHooks()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while studio.busy { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            print("GANCHO tempo \(Int(Date().timeIntervalSince(start))) s · erro \(studio.error ?? "-") · \(String(describing: studio.videoHook))")
            for c in studio.hookCandidates { print("CANDIDATO \(String(format: "%.1f–%.1f", c.hook.start, c.hook.end)) “\(c.text)” — \(c.hook.reason)") }
            if let tl = studio.playhead.timeline { print("LINHA gancho \(tl.hookCount) trechos, \(String(format: "%.1f", tl.hookDuration)) s · total \(String(format: "%.1f", tl.duration)) s · junção \(tl.junctions(settings: studio.settings, marks: studio.transitionMarks).first.map { "\($0.type) em \(String(format: "%.1f", $0.time))" } ?? "-")") }
            let out = URL(fileURLWithPath: args[k + 1])
            do { try await studio.render(state: studio.snapshot(), to: out); print("EXPORTOU \(String(format: "%.1f", try await MediaEngine.info(out).duration)) s") } catch { print("ERRO export \(error)") }
            rightTab = "Reels"; try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if let k = args.firstIndex(of: "--clips-test"), args.count > k + 1 {
            let start = Date()
            studio.clipOptions.prompt = args.firstIndex(of: "--clips-prompt").map { args[$0 + 1] } ?? ""
            studio.clipOptions.length = "curto"
            studio.suggestClips(count: Int(args[k + 1]) ?? 3)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while studio.busy { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            print("CORTES tempo \(Int(Date().timeIntervalSince(start))) s · \(studio.clips.count) cortes · erro \(studio.error ?? "-")")
            for c in studio.clips { print("HOOK \(c.videoHook.map { String(format: "%.1f–%.1f “%@”", $0.start, $0.end, VideoHook.text(captions: studio.captions, start: $0.start, end: $0.end)) } ?? "-")"); print("CORTE \(c.score) \(c.scores) [\(c.startID)-\(c.endID)] \(Int((studio.clipSpan(c)?.end ?? 0) - (studio.clipSpan(c)?.start ?? 0))) s · \(c.title) · \(c.topic)\n  gancho: \(c.hook)\n  post: \(c.caption)\n  \(c.hashtags.joined(separator: " "))") }
            if let first = studio.clips.first {
                let before = studio.clipSpan(first)
                studio.adjustClip(first.id, start: -1, end: 1)
                print("AJUSTE \(String(describing: before)) → \(String(describing: studio.clipSpan(studio.clips.first { $0.id == first.id }!)))")
            }
            rightTab = "Cortes"; try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        if args.contains("--script-test") {
            let start = Date()
            studio.settings.scriptMode = true; studio.settings.cutLookAway = true
            if let k = args.firstIndex(of: "--script-file"), let text = try? String(contentsOfFile: args[k + 1], encoding: .utf8) { studio.script = text }
            studio.runAIEdit()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while studio.busy { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            let kept = studio.captions.filter(\.included)
            print("ROTEIRO tempo \(Int(Date().timeIntervalSince(start))) s · legendas \(studio.captions.count), mantidas \(kept.count) · palavras removidas \(studio.captions.reduce(0) { $0 + ($1.removedWords?.count ?? 0) })")
            print("ROTEIRO duração \(String(format: "%.1f", studio.media?.duration ?? 0)) → \(String(format: "%.1f", studio.editedDuration)) s · \(studio.gazeSummary ?? "-") · erro \(studio.error ?? "-")")
            print("ROTEIRO resposta: " + (studio.chat.last?.text ?? "-"))
            print("ROTEIRO modo roteiro ainda ligado: \(studio.settings.scriptMode) · nota: \(studio.lookAwayNote() ?? "nil")")
            let dump = studio.captions.map { "\($0.included ? "✓" : "✗") [\(String(format: "%5.1f", $0.start))] cam \(studio.gaze?.cameraShare($0.start, $0.end) ?? -1)% \($0.removedWords.map { "(-\($0.count))" } ?? "") \($0.text)" }.joined(separator: "\n")
            try? dump.write(toFile: NSTemporaryDirectory() + "corta-roteiro.txt", atomically: true, encoding: .utf8)
        }
        if let k = args.firstIndex(of: "--broll-test"), args.count > k + 1 {
            // --broll-test fonte[:alvo][:pasta]  (fonte: pasta, biblioteca, fotos, videos, claude; alvo: auto ou olhadas)
            let parts = args[k + 1].split(separator: ":", maxSplits: 2).map(String.init)
            let previous = UserDefaults.standard.string(forKey: "CortaLibraryPath")
            let temp = NSTemporaryDirectory() + "corta-biblioteca-teste"
            try? FileManager.default.removeItem(atPath: temp)
            UserDefaults.standard.set(temp, forKey: "CortaLibraryPath"); Library.prepare()
            defer { if let previous { UserDefaults.standard.set(previous, forKey: "CortaLibraryPath") } else { UserDefaults.standard.removeObject(forKey: "CortaLibraryPath") } }
            let target: BrollTarget = parts.count > 1 && parts[1] == "olhadas" ? .lookAway : .auto
            let folder = parts.count > 2 ? URL(fileURLWithPath: parts[2]) : nil
            let start = Date()
            studio.placeBroll(target: target, source: parts[0], folder: folder, density: "médio (um apoio a cada ~20 s)", display: "tela-cheia", entrance: "fade", minimum: 1)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while studio.busy { try? await Task.sleep(nanoseconds: 1_000_000_000) }
            let broll = studio.effects.filter { $0.kind == .imagem || $0.kind == .video }
            print("BROLL \(parts[0]) em \(Int(Date().timeIntervalSince(start))) s · \(studio.message) · erro \(studio.error ?? "-")")
            for e in broll { print("BROLL  \(e.kind.rawValue) \(String(format: "%.1f–%.1f", e.start, e.end)) \(e.asset)") }
            print("BROLL fontes: " + ((try? String(contentsOfFile: temp + "/fontes.txt", encoding: .utf8))?.components(separatedBy: "\n").filter { $0.contains(" — ") }.prefix(4).joined(separator: " | ") ?? "-"))
            if let e = broll.first(where: { $0.kind == .video }) ?? broll.first, let source = studio.source, let tl = studio.playhead.timeline, let r = studio.outputRange(of: e) {
                if let built = try? await MediaEngine.compose(source: source, support: nil, timeline: tl, settings: studio.settings, effects: studio.effects, preview: true) {
                    let g = AVAssetImageGenerator(asset: built.composition); g.videoComposition = built.videoComposition
                    g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                    do {
                        let cg = try await g.image(at: CMTime(seconds: (r.0 + r.1) / 2, preferredTimescale: 600)).image
                        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "corta-broll.png"))
                        print("BROLL quadro com \(e.kind.rawValue) salvo")
                    } catch { print("BROLL erro no quadro: \(error)") }
                }
            }
        }
        if let k = args.firstIndex(of: "--video-broll-test"), args.count > k + 1 {
            let previous = UserDefaults.standard.string(forKey: "CortaLibraryPath")
            let temp = NSTemporaryDirectory() + "corta-biblioteca-teste"
            try? FileManager.default.removeItem(atPath: temp)
            UserDefaults.standard.set(temp, forKey: "CortaLibraryPath"); Library.prepare()
            defer { if let previous { UserDefaults.standard.set(previous, forKey: "CortaLibraryPath") } else { UserDefaults.standard.removeObject(forKey: "CortaLibraryPath") } }
            let clip = URL(fileURLWithPath: args[k + 1])
            try? FileManager.default.copyItem(at: clip, to: Library.videos.appendingPathComponent("apoio.mp4"))
            studio.effects = [Effect(kind: .video, start: 3, end: 7, style: "tela-cheia", asset: "apoio.mp4", animation: "fade"),
                              Effect(kind: .video, start: 10, end: 13, style: "dividida", asset: "apoio.mp4", animation: "deslizar")]
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let source = studio.source, let tl = studio.playhead.timeline else { print("VB sem linha do tempo"); exit(1) }
            do {
                let built = try await MediaEngine.compose(source: source, support: nil, timeline: tl, settings: studio.settings, effects: studio.effects, preview: true)
                let g = AVAssetImageGenerator(asset: built.composition); g.videoComposition = built.videoComposition
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
                for t in [5.0, 11.5, 15.0] {
                    let cg = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                    try NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "corta-vb-\(Int(t)).png"))
                }
                print("VB quadros ok · compositor \(built.videoComposition.customVideoCompositorClass != nil ? "dois vídeos" : "simples")")
                let out = URL(fileURLWithPath: NSTemporaryDirectory() + "corta-vb.mp4")
                let start = Date()
                try await studio.render(state: studio.snapshot(), to: out)
                let info = try await MediaEngine.info(out)
                print("VB exportação: \(Int(info.size.width))x\(Int(info.size.height)) \(String(format: "%.1f", info.duration)) s em \(Int(Date().timeIntervalSince(start))) s")
                print("VB ao vivo: item \(studio.player?.currentItem?.status.rawValue ?? -1) erro \(studio.player?.currentItem?.error?.localizedDescription ?? "-")")
            } catch { print("VB erro: \(error)") }
            exit(0)
        }
        if args.contains("--undo-test") {
            func state() -> String { "efeitos=\(studio.effects.count) zoomProg=\(studio.settings.zoom) removidos=\(studio.exclusions.count) passo=\(studio.historyIndex)/\(studio.history.count - 1)" }
            func wait() async { try? await Task.sleep(nanoseconds: 900_000_000) }
            print("UNDO inicio  " + state())
            studio.addEffect(.zoom, start: 2, end: 4); await wait(); print("UNDO +zoom   " + state())
            studio.addEffect(.texto, start: 6, end: 9); await wait(); print("UNDO +texto  " + state())
            studio.settings.zoom.toggle(); await wait(); print("UNDO toggle  " + state())
            studio.removeRange(12, 13); print("UNDO -trecho " + state() + " (sem esperar)")
            studio.undo(); await wait(); print("UNDO desfaz1 " + state())
            studio.undo(); await wait(); print("UNDO desfaz2 " + state())
            studio.undo(); await wait(); print("UNDO desfaz3 " + state())
            studio.undo(); await wait(); print("UNDO desfaz4 " + state())
            studio.undo(); await wait(); print("UNDO desfaz5 " + state() + " (nada mais)")
            studio.redo(); await wait(); print("UNDO refaz1  " + state())
            studio.redo(); await wait(); print("UNDO refaz2  " + state())
            studio.addEffect(.zoom, start: 14, end: 15); await wait(); print("UNDO novo ramo " + state() + " podeRefazer=\(studio.canRedo)")
            exit(0)
        }
        if args.contains("--demo") {
            studio.seek(2); studio.step(1); studio.step(-1)
            studio.addEffect(.zoom, start: 3, end: 6)
            studio.addEffect(.texto, start: 8, end: 12)
            if case .effect(let id)? = studio.selection { studio.updateEffect(id) { $0.text = "A virtude nasce do hábito"; $0.style = "citacao" } }
            studio.selection = .range(14, 15.5)
            studio.removeRange(14, 15.5)
            studio.addEffect(.texto, start: 9, end: 12)
            studio.undo()
            if let first = studio.effects.first(where: { $0.kind == .texto }) { studio.selection = .effect(first.id); rightTab = "Editar" }
            studio.captions = [Caption(id: 0, start: 0.5, end: 3, text: "E o tema desse vídeo não tá muito diferente"), Caption(id: 1, start: 3.2, end: 5.5, text: "na verdade")]
            try? await Task.sleep(nanoseconds: 800_000_000)
            studio.setOpeningTitle(text: "Virtude e hábito"); studio.setOpeningTitle(style: "palavra"); studio.setOpeningTitle(seconds: 4)
            studio.effectOnCaption(0, kind: .texto, style: "citacao")
            if args.contains("--transition-demo"), let j = studio.playhead.timeline?.junctions(settings: studio.settings, marks: []).first {
                studio.setTransition(at: j.sourceTime, type: "chicote", duration: 0.7)
                try? await Task.sleep(nanoseconds: 600_000_000)
                studio.selection = .transition(j.sourceTime)
            }
            if args.contains("--image-demo") {
                studio.requestImage(forCaption: 0)
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if let sheet = NSApp.windows.first(where: { $0.isSheet || $0.sheetParent != nil }), let v = sheet.contentView, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                    v.cacheDisplay(in: v.bounds, to: r)
                    try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "corta-sheet.png"))
                    print("DIAG sheet salvo")
                }
            }
            if args.contains("--zoom-demo") { studio.effectOnCaption(1, kind: .zoom, zoomStyle: "zoom-in") }
            print("DIAG titulo=\(studio.openingTitle?.text ?? "-") estilo=\(studio.openingTitle?.style ?? "-") dur=\(studio.openingTitleSeconds) efeitos=\(studio.effects.map { $0.style + ":" + $0.text })")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let tab = args.firstIndex(of: "--tab").map({ args[$0 + 1] }) { rightTab = tab }
            studio.seek(10)
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
        if let tab = args.firstIndex(of: "--tab").map({ args[$0 + 1] }), rightTab != tab { rightTab = tab; try? await Task.sleep(nanoseconds: 1_500_000_000) }
        if let k = args.firstIndex(of: "--scroll"), args.count > k + 1 { settingsScroll = args[k + 1]; try? await Task.sleep(nanoseconds: 2_500_000_000) }
        if let k = args.firstIndex(of: "--size"), args.count > k + 1, let window = NSApp.windows.first(where: { $0.isVisible }) {
            let parts = args[k + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { window.setContentSize(NSSize(width: parts[0], height: parts[1])); try? await Task.sleep(nanoseconds: 1_500_000_000) }
            print("DIAG janela \(window.frame.size) mínimo \(window.minSize) conteúdo \(window.contentView?.frame.size ?? .zero)")
        }
        if let j = args.firstIndex(of: "--snapshot"), args.count > j + 1, let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[j + 1]))
            if let item = studio.player?.currentItem {
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); item.add(output)
                studio.seek(10); try? await Task.sleep(nanoseconds: 1_500_000_000)
                let t = item.currentTime()
                let ok = output.hasNewPixelBuffer(forItemTime: t) || output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil
                if let buffer = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
                   let cg = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent) {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[j + 1] + ".player.png"))
                }
                print("PLAYER status=\(item.status.rawValue) erro=\(item.error?.localizedDescription ?? "-") quadro=\(ok) tempo=\(t.seconds)")
            }
            print("SNAPSHOT_OK msg=\(studio.message) src=\(studio.source?.lastPathComponent ?? "-") busy=\(studio.busy) erro=\(studio.error ?? "-") effects=\(studio.effects.count) exclusions=\(studio.exclusions.count) duration=\(studio.playhead.duration) live=\(studio.liveItem != nil) status=\(studio.liveStatus)")
            exit(0)
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "scissors").font(.system(size: 21, weight: .semibold)).foregroundStyle(accent)
                .frame(width: 40, height: 40).background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Corta Studio").font(.system(size: 20, weight: .semibold, design: .serif))
                Text("PROJETO ETHOS · EDIÇÃO COM IA").font(.system(size: 9, weight: .medium)).tracking(1.4).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Circle().fill(studio.connection.connected ? accent : .gray).frame(width: 6, height: 6)
                Text(studio.connection.connected ? "Claude conectado · \(studio.connection.selectedModel.capitalized)" : "Claude desconectado").font(.caption).foregroundStyle(.secondary)
            }
            Button { studio.openProject() } label: { Label("Abrir projeto", systemImage: "folder") }.buttonStyle(.borderless).padding(.horizontal, 12).disabled(studio.busy)
            Button { accountSheet = true } label: { Label("IA e conta", systemImage: "sparkles") }.buttonStyle(.bordered).disabled(studio.busy)
        }.padding(.horizontal, 22).padding(.vertical, 9)
    }

    // MARK: Opções

    @State private var settingsScroll: String?
    private var settingsPanel: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                sectionLabel("01", "Seu vídeo")
                Button(action: studio.chooseVideo) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "plus.rectangle.on.rectangle").font(.title3).foregroundStyle(accent)
                        Text(studio.source == nil ? "Escolher vídeo" : "Trocar vídeo").font(.system(size: 14, weight: .semibold))
                        Text(studio.source?.lastPathComponent ?? "Horizontal ou vertical · MP4 · MOV").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    .background(surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.10), style: StrokeStyle(lineWidth: 1, dash: [5])))
                }.buttonStyle(.plain)

                sectionLabel("02", "Destino e objetivo")
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Plataforma", selection: Binding(get: { studio.settings.platform }, set: { studio.settings.applyPlatform($0) })) {
                        ForEach(EditSettings.platforms, id: \.self) { Text($0) }
                    }
                    Button { studio.showReelsSheet = true } label: { Label("Modelo Reels Ethos (imagens em degradê + legenda bege)…", systemImage: "rectangle.portrait.on.rectangle.portrait.angled") }
                        .font(.caption).disabled(studio.source == nil || studio.busy)
                    Picker("Objetivo", selection: $studio.settings.shortVideo) { Text("Vídeo completo").tag(false); Text("Corte curto").tag(true) }.pickerStyle(.segmented).labelsHidden()
                    if studio.settings.shortVideo {
                        HStack { Text("Duração").font(.caption); Spacer(); Text("\(Int(studio.settings.targetSeconds)) s").font(.caption.monospacedDigit()).foregroundStyle(accent) }
                        Slider(value: $studio.settings.targetSeconds, in: 15...180, step: 5)
                    }
                    Text("Ritmo").font(.caption).foregroundStyle(.secondary)
                    RhythmCards(style: $studio.settings.style)
                }.font(.callout)

                sectionLabel("03", "O que a IA decide")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Cortes inteligentes", isOn: $studio.settings.smartCuts)
                    Toggle("Reduzir pausas", isOn: $studio.settings.trimPauses)
                    Toggle("Zooms de ênfase", isOn: $studio.settings.emphasisZoom)
                    Toggle("Textos de destaque na tela", isOn: $studio.settings.textHighlights)
                    Toggle("Imagens da biblioteca (\(Library.imageNames.count))", isOn: $studio.settings.brollImages).id(studio.libraryVersion)
                    Toggle("Gancho escrito na abertura", isOn: $studio.settings.autoHook)
                    Toggle(isOn: $studio.autoVideoHook) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Gancho em vídeo no início")
                            Text(studio.videoHook == nil ? "A IA põe o ápice da fala nos primeiros segundos e volta ao começo" : "Ativo: \(clockLabel(studio.videoHook!.start)) · ajuste na aba Reels").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Remover vícios (hum, tipo, né…)", isOn: $studio.settings.removeFillers)
                    Divider().opacity(0.3)
                    Toggle(isOn: $studio.settings.scriptMode) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Gravei lendo um roteiro")
                            Text("Escolhe as melhores tomadas, tira recomeços, erros e olhadas para o roteiro").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if studio.settings.scriptMode {
                        VStack(alignment: .leading, spacing: 6) {
                            Button { scriptSheet = true } label: { Label(studio.script.isEmpty ? "Colar o roteiro (opcional, ajuda muito)" : "Roteiro: \(studio.script.split(whereSeparator: \.isWhitespace).count) palavras · editar", systemImage: "doc.text") }.font(.caption)
                            Toggle("Cortar silêncios olhando para fora", isOn: $studio.settings.cutLookAway).font(.caption)
                            Button { studio.openCover() } label: { Label(studio.coverCount > 0 ? "Cobrir olhadas com imagens (\(studio.coverCount))…" : "Cobrir olhadas com imagens…", systemImage: "photo.stack") }.font(.caption).disabled(studio.source == nil || studio.busy)
                            HStack {
                                Text(studio.gazeSummary ?? "O olhar é analisado ao clicar em Editar com IA.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Spacer()
                                Button(studio.gaze == nil ? "Analisar agora" : "Refazer") { studio.analyzeGazeNow() }.font(.caption2).disabled(studio.source == nil || studio.busy)
                            }
                        }.padding(.leading, 20)
                    }
                }.font(.callout)

                sectionLabel("04", "Legendas").id("legendas")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Legendas no vídeo", isOn: $studio.settings.captions)
                    if studio.settings.captions {
                        Picker("Animação", selection: $studio.settings.captionMode) { Text("Dinâmica (palavra a palavra)").tag("Dinâmica"); Text("Uma palavra por vez (grande)").tag("Uma palavra"); Text("Blocos").tag("Blocos") }
                        Text("Estilo da legenda").font(.caption).foregroundStyle(.secondary)
                        PreviewGrid(previews: looks, prefix: "leg:", items: SettingPreviews.captionStyles, isSelected: { $0 == studio.settings.captionStyle }, vertical: studio.settings.vertical, columns: 2, aspect: studio.settings.vertical ? (360 * 0.92) / (640 * 0.12) : (640 * 0.66) / (360 * 0.20)) { studio.settings.captionStyle = $0 }
                        Picker("Posição", selection: $studio.settings.captionPosition) { Text("Inferior").tag("Inferior"); Text("Centro").tag("Centro") }
                    }
                }.font(.callout)

                sectionLabel("05", "Imagem").id("imagem")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Zoom progressivo", isOn: $studio.settings.zoom)
                    if studio.settings.zoom {
                        HStack { Text("Velocidade").font(.caption); Slider(value: Binding(get: { 44 - studio.settings.zoomCycle }, set: { studio.settings.zoomCycle = 44 - $0 }), in: 4...40); Text(studio.settings.zoomCycle < 10 ? "rápido" : studio.settings.zoomCycle < 22 ? "normal" : "lento").font(.caption2).foregroundStyle(.secondary).frame(width: 42) }
                    }
                    Text("Enquadrar").font(.caption).foregroundStyle(.secondary)
                    PreviewGrid(previews: looks, prefix: "enq:", items: SettingPreviews.framings, isSelected: { $0 == (studio.settings.fillFrame ? "fill" : "fit") }, vertical: studio.settings.vertical, columns: 2) { studio.settings.fillFrame = $0 == "fill" }
                    if studio.settings.fillFrame {
                        HStack {
                            Text("Aproximação").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $studio.settings.frameScale, in: 0.5...1)
                            Text(studio.settings.frameScale > 0.99 ? "justa" : "\(Int((1 - studio.settings.frameScale) * 200))% mais aberta").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
                        }.help("Se o rosto ficar perto demais (vídeo horizontal virando vertical), deixe mais aberto: o alto e o baixo são completados com o próprio vídeo desfocado.")
                        HStack {
                            Button(studio.faceTrack.isEmpty ? "Acompanhar rosto" : "Rosto acompanhado ✓", action: studio.trackFaceNow).font(.caption).disabled(studio.source == nil)
                            Spacer()
                            if !studio.faceTrack.isEmpty { Button("Manual") { studio.faceTrack = [] }.font(.caption).buttonStyle(.borderless) }
                        }
                        if studio.faceTrack.isEmpty {
                            Text("Posição horizontal").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $studio.settings.horizontalFocus, in: 0...1)
                        }
                    }
                    Text("Cor").font(.caption).foregroundStyle(.secondary)
                    PreviewGrid(previews: looks, prefix: "cor:", items: SettingPreviews.looks, isSelected: { $0 == studio.settings.colorLook }, vertical: studio.settings.vertical) { studio.settings.colorLook = $0 }
                    Text("Transições").font(.caption).foregroundStyle(.secondary)
                    PreviewGrid(previews: looks, prefix: "tr:", items: SettingPreviews.transitions, isSelected: { $0 == studio.settings.transitions }, vertical: studio.settings.vertical) { studio.settings.transitions = $0 }
                    if studio.settings.transitions != "Corte seco" {
                        Picker("Onde", selection: $studio.settings.transitionAllCuts) { Text("Mudanças de assunto").tag(false); Text("Todos os cortes").tag(true) }.pickerStyle(.segmented).labelsHidden()
                    }
                    Text("Para escolher a transição de um corte específico, clique no losango da junção na faixa de vídeo.").font(.caption2).foregroundStyle(.secondary)
                    Text("Efeitos de imagem (clique para ligar ou desligar)").font(.caption).foregroundStyle(.secondary)
                    PreviewGrid(previews: looks, prefix: "efeito:", items: [SettingPreviews.Item(id: "vinheta", label: "Vinheta", help: "Escurece levemente as bordas e leva o olhar ao centro."),
                                                                           SettingPreviews.Item(id: "retrato", label: "Fundo desfocado", help: "Modo retrato: separa você do fundo e desfoca só o fundo.")],
                                isSelected: { ($0 == "vinheta" && studio.settings.vignette) || ($0 == "retrato" && studio.settings.portraitBlur) }, vertical: studio.settings.vertical, columns: 2) { id in
                        if id == "vinheta" { studio.settings.vignette.toggle() } else { studio.settings.portraitBlur.toggle() }
                    }
                    Toggle("Correção de olhar (experimental)", isOn: $studio.settings.eyeContact)
                    if studio.settings.eyeContact {
                        HStack { Text("Intensidade").font(.caption); Slider(value: $studio.settings.eyeContactStrength, in: 0.2...1) }
                        Text("Leve: aproxima a íris do centro do olho. Confira a prévia.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Toggle("Fade na abertura e no fim", isOn: $studio.settings.fadeInOut)
                    Toggle("Barra de progresso", isOn: $studio.settings.progressBar)
                    Toggle("Marca d'água (logo)", isOn: $studio.settings.watermark).disabled(Library.logo == nil).id(studio.libraryVersion)
                    TextField("Pergunta/gancho na abertura (opcional)", text: $studio.settings.question, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
                    Button(studio.support == nil ? "Imagem fixa em tela dividida…" : "Trocar imagem fixa…", action: studio.chooseSupport).font(.caption)
                    if studio.support != nil {
                        Toggle("Tela dividida", isOn: $studio.settings.splitScreen)
                        Button("Remover imagem fixa") { studio.support = nil; studio.settings.splitScreen = false }.font(.caption)
                    }
                }.font(.callout)

                sectionLabel("06", "Áudio")
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Voz de estúdio", isOn: $studio.settings.studioVoice)
                    if studio.settings.studioVoice {
                        HStack { Text("Isolar voz").font(.caption); Slider(value: $studio.settings.voiceIsolation, in: 0...1) }
                        Text("Remove ruído e eco, equaliza e padroniza o volume. Processa uma vez por vídeo.").font(.caption2).foregroundStyle(.secondary)
                    }
                    Toggle("Efeitos sonoros sutis", isOn: $studio.settings.soundEffects)
                    Picker("Música", selection: $studio.settings.musicFile) {
                        Text("Nenhuma").tag("")
                        ForEach(Library.musicNames, id: \.self) { Text($0).tag($0) }
                    }.id(studio.libraryVersion)
                    if !studio.settings.musicFile.isEmpty {
                        HStack { Text("Volume").font(.caption); Slider(value: $studio.settings.musicVolume, in: 0.03...0.4) }
                        Toggle("Abaixar durante a fala", isOn: $studio.settings.ducking)
                    }
                }.font(.callout)

                sectionLabel("07", "Biblioteca")
                VStack(alignment: .leading, spacing: 6) {
                    Button("Adicionar imagens de apoio…") { Library.add(to: Library.images, types: Library.imageTypes, message: "Imagens com nomes descritivos ajudam a IA a escolher."); studio.libraryVersion += 1 }
                    Button("Adicionar músicas…") { Library.add(to: Library.music, types: Library.audioTypes, message: "Use músicas com licença para publicação."); studio.libraryVersion += 1 }
                    Button("Adicionar logo…") { Library.add(to: Library.brand, types: Library.imageTypes, message: "PNG com fundo transparente."); studio.libraryVersion += 1 }
                    Button("Abrir pasta da biblioteca") { Library.reveal() }
                }.buttonStyle(.borderless).font(.caption)

                Divider().opacity(0.4)
                if studio.source != nil {
                    Button { studio.saveProject() } label: { Label("Salvar projeto", systemImage: "square.and.arrow.down") }.buttonStyle(.borderless).font(.caption)
                }
                Button("Testar exportação neste Mac", action: studio.testExport).buttonStyle(.borderless).font(.caption2).foregroundStyle(.secondary)
            }.padding(20)
        }.disabled(studio.busy)
        .onChange(of: settingsScroll) { if let id = settingsScroll { withAnimation { proxy.scrollTo(id, anchor: .top) } } }
        }
    }

    // MARK: Prévia

    private var previewPanel: some View {
        VStack(spacing: 10) {
            if studio.media != nil { editingBanner } else {
                Text("Sua história, em foco.").font(.system(size: 17, weight: .medium, design: .serif)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(Color.black.opacity(0.45))
                if let player = studio.player {
                    NativeVideoPreview(player: player).clipShape(RoundedRectangle(cornerRadius: 16))
                    if !studio.showingOriginal { PreviewTapLayer(studio: studio, clock: studio.clock) }
                    if studio.showSafeZones && studio.settings.vertical { SafeZoneOverlay() }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "film.stack").font(.system(size: 40)).foregroundStyle(accent)
                        Text("Um bom vídeo começa\ncom uma boa história.").font(.system(size: 25, weight: .medium, design: .serif)).multilineTextAlignment(.center)
                        Text("Escolha o vídeo, marque o que quer e deixe a IA editar.").font(.callout).foregroundStyle(.secondary)
                        Button("Escolher meu vídeo", action: studio.chooseVideo).buttonStyle(.borderedProminent).foregroundStyle(canvas).controlSize(.large).padding(.top, 6)
                    }.padding(24)
                }
                if studio.aiWorking {
                    VStack(spacing: 10) { ProgressView(); Text("O Claude está editando…").font(.callout) }
                        .padding(22).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }.frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
            if let media = studio.media {
                // Com espaço, botões com nome; em janelas estreitas, só ícones (o nome aparece ao passar o mouse).
                ViewThatFits(in: .horizontal) {
                    playerControls(media, compact: false)
                    playerControls(media, compact: true)
                }.disabled(studio.busy).fixedSize(horizontal: false, vertical: true).layoutPriority(2)
            }
            Button { studio.runAIEdit() } label: { Label(studio.activeClipID == nil ? "Editar com IA" : "Editar este corte com IA", systemImage: "sparkles").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large).foregroundStyle(canvas)
                .disabled(studio.source == nil || studio.busy).fixedSize(horizontal: false, vertical: true).layoutPriority(2)
        }.padding(16)
        .help("A IA lê a transcrição e decide cortes e efeitos. O vídeo é montado e renderizado no seu Mac.")
    }
    private func playerControls(_ media: MediaInfo, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            modeButton(compact ? "wand.and.stars" : nil, "Edição", on: !studio.showingOriginal) { studio.showLive() }
            modeButton(compact ? "eye" : nil, "Original (sem edição)", on: studio.showingOriginal) { studio.showOriginal(at: studio.playhead.timeline?.sourceTime(studio.clock.time) ?? 0) }
            Button { studio.undo() } label: { if compact { Image(systemName: "arrow.uturn.backward") } else { Label("Desfazer", systemImage: "arrow.uturn.backward") } }.buttonStyle(.borderless).disabled(!studio.canUndo).help("Desfazer (⌘Z)")
            Button { studio.redo() } label: { if compact { Image(systemName: "arrow.uturn.forward") } else { Label("Refazer", systemImage: "arrow.uturn.forward") } }.buttonStyle(.borderless).disabled(!studio.canRedo).help("Refazer (⇧⌘Z)")
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(clockLabel(media.duration)) → \(clockLabel(studio.editedDuration))").font(.system(.callout, design: .monospaced)).lineLimit(1)
                if !compact { Text(studio.showingOriginal ? "Vendo o original, sem edição" : "Original → editado").font(.caption2).foregroundStyle(Color.secondary).lineLimit(1) }
            }.fixedSize()
        }
    }
    private func modeButton(_ icon: String?, _ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { if let icon { Image(systemName: icon) } else { Text(title).lineLimit(1).fixedSize() } }
            .buttonStyle(.bordered).tint(on ? accent : .gray).help(title)
    }

    // MARK: Chat, legendas e efeitos

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $rightTab) { Text("Chat").tag("Chat"); Text("Editar").tag("Editar"); Text("Cortes").tag("Cortes"); Text("Reels").tag("Reels"); Text("Legendas").tag("Legendas"); Text("Efeitos").tag("Efeitos") }
                .pickerStyle(.segmented).labelsHidden()
            switch rightTab {
            case "Editar": InspectorPanel(studio: studio, playhead: studio.playhead)
            case "Legendas": transcriptPanel
            case "Efeitos": effectsPanel
            case "Cortes": ClipsPanel(studio: studio)
            case "Reels": ReelsPanel(studio: studio)
            default: chatPanel
            }
        }.padding(18)
    }
    private var chatPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if studio.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Converse com o editor").font(.system(size: 16, weight: .medium, design: .serif))
                                Text("Depois da primeira edição, peça ajustes como pediria a um editor. A IA altera cortes, legendas, efeitos e estilo, e a prévia é refeita.").font(.callout).foregroundStyle(.secondary)
                                ForEach(["Deixe a abertura mais forte", "Abra o vídeo com o momento mais forte e volte ao começo", "Busque imagens para a narração", "Faça um corte de 45 s para Reels", "Coloque um título no início", "Menos zoom, mais sóbrio", "Corrija os nomes próprios nas legendas"], id: \.self) { idea in
                                    Button { draft = idea } label: { Text(idea).font(.caption).padding(.horizontal, 10).padding(.vertical, 6).background(surface, in: Capsule()) }.buttonStyle(.plain)
                                }
                            }.padding(.top, 8)
                        }
                        ForEach(studio.chat) { msg in
                            HStack {
                                if msg.fromUser { Spacer(minLength: 30) }
                                Text(msg.text).font(.callout).textSelection(.enabled).padding(10)
                                    .background(msg.fromUser ? accent.opacity(0.22) : surface, in: RoundedRectangle(cornerRadius: 12))
                                if !msg.fromUser { Spacer(minLength: 30) }
                            }.id(msg.id)
                        }
                        if studio.aiWorking { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Editando…").font(.caption).foregroundStyle(.secondary) }.id("working") }
                    }
                }
                .onChange(of: studio.chat.count) { if let last = studio.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(studio.source == nil ? "Escolha um vídeo para conversar" : "Peça uma alteração…", text: $draft, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }.buttonStyle(.plain).foregroundStyle(accent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || studio.busy || studio.source == nil)
            }
            Text(studio.connection.connected ? "Cada mensagem usa o seu plano Claude." : "Conecte sua conta Claude em IA e conta.").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func send() {
        guard !studio.busy else { return }
        let text = draft; draft = ""
        studio.sendChat(text)
    }
    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Transcrever", action: studio.transcribe).buttonStyle(.bordered)
                Button("Importar SRT", action: studio.importSRT).buttonStyle(.borderless)
                Spacer()
                if !studio.captions.isEmpty { Button("Restaurar tudo", action: studio.restoreCuts).buttonStyle(.borderless) }
            }.font(.caption).disabled(studio.source == nil || studio.busy)
            if studio.source != nil { titleEditor }
            if studio.captions.isEmpty {
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "text.bubble").font(.system(size: 28)).foregroundStyle(accent.opacity(0.7))
                    Text("Sua fala vira legenda.").font(.system(size: 16, weight: .medium))
                    Text("A transcrição é feita em português no Mac. Editar com IA transcreve automaticamente.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                Text("\(studio.selectedCount) de \(studio.captions.count) trechos mantidos").font(.caption).foregroundStyle(.secondary)
                if !studio.summary.isEmpty { Text(studio.summary).font(.caption).foregroundStyle(accent).lineLimit(6) }
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach($studio.captions) { $caption in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Toggle("Manter trecho", isOn: $caption.included).labelsHidden().toggleStyle(.checkbox)
                                    Button { studio.showOriginal(at: caption.start) } label: { Text(clockLabel(caption.start)).font(.system(.caption2, design: .monospaced)).foregroundStyle(accent) }.buttonStyle(.plain)
                                    Spacer()
                                    if studio.effects.contains(where: { $0.kind == .texto && $0.asset != Studio.titleMarker && abs($0.start - caption.start) < 0.05 }) {
                                        Image(systemName: "textformat").font(.caption2).foregroundStyle(accent).help("Este trecho tem texto em destaque")
                                    }
                                    if caption.hidden == true { Image(systemName: "eye.slash").font(.caption2).foregroundStyle(.secondary).help("Texto oculto: a fala continua no vídeo") }
                                    Image(systemName: caption.included ? "checkmark" : "scissors").font(.caption2).foregroundStyle(.secondary)
                                    captionMenu(caption)
                                }
                                TextField("Legenda", text: $caption.text, axis: .vertical).textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...6)
                                if let removed = caption.removedWords, !removed.isEmpty {
                                    let tokens = caption.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                                    HStack {
                                        Text("Removido: " + removed.compactMap { $0 < tokens.count ? tokens[$0] : nil }.joined(separator: ", ")).font(.caption2).strikethrough().foregroundStyle(.secondary)
                                        Spacer()
                                        Button("Restaurar") { studio.restoreWords(caption.id) }.font(.caption2).buttonStyle(.borderless)
                                    }
                                }
                            }.padding(10).background(surface.opacity(caption.included ? 1 : 0.35), in: RoundedRectangle(cornerRadius: 10)).opacity(caption.included ? 1 : 0.5)
                        }
                    }
                }.disabled(studio.busy)
            }
        }
    }
    /// Título de abertura e gancho, editáveis à mão no topo da aba Legendas.
    private var titleEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Título de abertura", systemImage: "textformat.size").font(.callout.weight(.semibold))
                Spacer()
                if studio.openingTitle != nil {
                    Button("Ver") { if let t = studio.openingTitle { studio.selection = .effect(t.id); studio.seek(min(1.0, studio.openingTitleSeconds / 2)) } }.buttonStyle(.borderless).font(.caption)
                    Button { studio.removeOpeningTitle() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).font(.caption).help("Remover título")
                }
            }
            TextField("Digite o título que aparece no início", text: Binding(get: { studio.openingTitle?.text ?? "" }, set: { studio.setOpeningTitle(text: $0) }), axis: .vertical)
                .lineLimit(1...3).textFieldStyle(.roundedBorder)
            if studio.openingTitle != nil {
                HStack {
                    Picker("Estilo", selection: Binding(get: { studio.openingTitle?.style ?? "titulo" }, set: { studio.setOpeningTitle(style: $0) })) {
                        ForEach(TextStyles.all) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 150)
                    Picker("Animação", selection: Binding(get: { studio.openingTitle?.animation ?? "subir" }, set: { studio.setOpeningTitle(animation: $0) })) {
                        ForEach(TextStyles.animations, id: \.id) { Text($0.name).tag($0.id) }
                    }.labelsHidden().frame(maxWidth: 130)
                }.font(.caption)
                Stepper("Duração: \(Int(studio.openingTitleSeconds)) s", value: Binding(get: { studio.openingTitleSeconds }, set: { studio.setOpeningTitle(seconds: $0) }), in: 1...12, step: 1).font(.caption)
            }
            Divider().opacity(0.3)
            Text("Pergunta / gancho nos primeiros segundos").font(.caption).foregroundStyle(.secondary)
            TextField("Ex.: Por que a virtude nasce do hábito?", text: $studio.settings.question, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
        }
        .padding(10).background(surface, in: RoundedRectangle(cornerRadius: 10))
        .disabled(studio.busy)
    }
    /// Ações rápidas de cada legenda.
    private func captionMenu(_ caption: Caption) -> some View {
        Menu {
            Section("Usar este texto em destaque") {
                ForEach(["destaque", "citacao", "palavra", "impacto", "caixa", "minimal", "versiculo", "manuscrito", "titulo"], id: \.self) { style in
                    Button(TextStyles.name(style)) { studio.effectOnCaption(caption.id, kind: .texto, style: style) }
                }
            }
            Section("Neste trecho") {
                Menu { ForEach(Effect.fxStyles, id: \.id) { f in Button(f.name) { studio.effectOnCaption(caption.id, kind: .fx, fxStyle: f.id) } } } label: { Label("Efeito de vídeo", systemImage: "sparkles.tv") }
                Menu { ForEach(Effect.zoomStyles, id: \.id) { z in Button(z.name) { studio.effectOnCaption(caption.id, kind: .zoom, zoomStyle: z.id) } } } label: { Label("Zoom neste trecho", systemImage: "plus.magnifyingglass") }
                Button { studio.requestImage(forCaption: caption.id) } label: { Label("Buscar ou gerar imagem para esta fala…", systemImage: "photo.on.rectangle.angled") }
                Button { studio.effectOnCaption(caption.id, kind: .imagem) } label: { Label("Imagem da biblioteca", systemImage: "photo") }.disabled(Library.imageNames.isEmpty)
                Button { studio.setOpeningTitle(text: caption.keptText) } label: { Label("Usar como título de abertura", systemImage: "textformat.size") }
            }
            Section {
                Button { studio.goToCaption(caption.id) } label: { Label("Ir para este trecho", systemImage: "play") }
                Button { studio.hideCaption(caption.id) } label: { Label(caption.hidden == true ? "Mostrar o texto da legenda" : "Apagar só o texto (a fala continua)", systemImage: caption.hidden == true ? "eye" : "eye.slash") }
                Button { studio.setCaption(caption.id) { $0.included.toggle() } } label: { Label(caption.included ? "Tirar do vídeo" : "Trazer de volta ao vídeo", systemImage: caption.included ? "scissors" : "arrow.uturn.backward") }
                if caption.removedWords?.isEmpty == false { Button("Restaurar palavras removidas") { studio.restoreWords(caption.id) } }
            }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Opções desta legenda: destacar, zoom, imagem…")
    }
    /// Faixa acima do vídeo: o que está aberto e a garantia de que a tela = exportação.
    private var editingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: studio.activeClipID == nil ? "film" : "scissors").foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(studio.editingTitle).font(.system(size: 14, weight: .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text("Na tela: a edição completa, igual ao que será exportado.").font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if studio.activeClipID != nil { Button { studio.openMainVideo() } label: { Label("Vídeo completo", systemImage: "arrow.uturn.backward") }.font(.caption).buttonStyle(.bordered).disabled(studio.busy).help("Voltar ao vídeo completo (as edições deste corte ficam guardadas)") }
            Text("\(studio.settings.platform) · \(studio.settings.vertical ? "9:16" : "16:9")").font(.caption.monospacedDigit()).padding(.horizontal, 8).padding(.vertical, 4).background(surface, in: Capsule()).fixedSize()
        }
    }
    private var effectsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { studio.showReelsSheet = true } label: {
                Label("Modelo Reels Ethos…", systemImage: "rectangle.portrait.on.rectangle.portrait.angled").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).foregroundStyle(canvas).disabled(studio.source == nil || studio.busy)
            .help("Vertical com imagens no alto em degradê, legenda serifada sobre faixa bege e cartões de citação. Você só escolhe as imagens (ou deixa a IA buscar).")
            Button { studio.openBroll(target: .auto) } label: {
                Label("Imagens e vídeos para a narração…", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).foregroundStyle(canvas).disabled(studio.source == nil || studio.busy)
            .help("De uma pasta do seu computador, da biblioteca ou da internet (fotos, vídeos curtos, ilustrações), escolhidos pela narração")
            Button { studio.openCover() } label: {
                Label(studio.coverCount > 0 ? "Cobrir olhadas (\(studio.coverCount) trechos)" : "Cobrir olhadas", systemImage: "photo.stack").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).disabled(studio.source == nil || studio.busy)
            .help("Põe imagens ligadas à narração sobre os trechos em que você fala olhando para fora da câmera")
            if studio.effects.isEmpty {
                Text("Nenhum efeito ainda. Clique em Editar com IA ou peça no chat, por exemplo: \"coloque um zoom quando eu falar da virtude\".").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("Tempos do vídeo original. Clique no tempo para assistir; remova o que não quiser.").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(studio.effects) { effect in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: effect.kind == .zoom ? "plus.magnifyingglass" : (effect.kind == .texto ? "textformat" : "photo")).foregroundStyle(accent).frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Button { studio.showOriginal(at: effect.start) } label: { Text("\(clockLabel(effect.start)) – \(clockLabel(effect.end))").font(.system(.caption2, design: .monospaced)).foregroundStyle(accent) }.buttonStyle(.plain)
                                    Text(effect.label).font(.caption).lineLimit(3)
                                }
                                Spacer()
                                Button { studio.removeEffect(effect.id) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }.padding(10).background(surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }.disabled(studio.busy)
            }
        }
    }
    private var footer: some View {
        HStack(spacing: 16) {
            if studio.busy {
                if let progress = studio.progress { ProgressView(value: progress).frame(width: 95); Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()) }
                else { ProgressView().controlSize(.small) }
            } else { Image(systemName: studio.lastExport != nil ? "checkmark.circle" : "leaf").foregroundStyle(accent) }
            Text(studio.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if studio.busy { Button("Cancelar", action: studio.cancel).buttonStyle(.bordered) }
            Menu {
                ForEach(["Inglês", "Espanhol", "Italiano", "Francês"], id: \.self) { language in
                    Toggle(language, isOn: Binding(get: { studio.extraLanguages.contains(language) }, set: { on in if on { studio.extraLanguages.insert(language) } else { studio.extraLanguages.remove(language) } }))
                }
            } label: { Label(studio.extraLanguages.isEmpty ? "Legendas traduzidas" : "Traduzir: " + studio.extraLanguages.sorted().joined(separator: ", "), systemImage: "globe") }
                .menuStyle(.borderlessButton).fixedSize().font(.caption).disabled(studio.busy)
            saveStatus
            Button { studio.exportCurrent() } label: { Label(studio.activeClipID == nil ? "Exportar vídeo…" : "Exportar este corte…", systemImage: "square.and.arrow.up").padding(.horizontal, 5) }
                .buttonStyle(.borderedProminent).foregroundStyle(canvas).controlSize(.large).disabled(studio.source == nil || studio.busy)
                .help("Exporta exatamente o que está na tela: \(studio.editingTitle)")
        }.padding(.horizontal, 26).padding(.vertical, 14).background(surface.opacity(0.35))
    }
    private var saveStatus: some View {
        Button { studio.saveProject() } label: {
            VStack(alignment: .trailing, spacing: 1) {
                Label("Salvar projeto", systemImage: "square.and.arrow.down").font(.caption)
                Group {
                    if studio.projectFolder == nil { Text("ainda não salvo").foregroundStyle(accent) }
                    else if studio.unsavedChanges { Text("salvando…").foregroundStyle(.secondary) }
                    else if let saved = studio.lastSaved { Text("salvo às " + saved.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary) }
                }.font(.system(size: 9))
            }
        }.buttonStyle(.borderless).disabled(studio.source == nil || studio.busy).help("Salvar projeto (⌘S). Depois do primeiro salvamento, salva sozinho a cada alteração.")
    }
    private func sectionLabel(_ number: String, _ title: String) -> some View {
        HStack(spacing: 9) { Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(accent); Text(title).font(.system(size: 14, weight: .semibold)) }
    }
}

struct AccountView: View {
    @ObservedObject var connection: ClaudeConnection
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("Sua IA de edição: Claude", systemImage: "sparkles").font(.title2.weight(.semibold)); Spacer(); Button("Fechar") { dismiss() } }
            Text("O Corta Studio usa o Claude Code deste Mac, conectado à sua assinatura Claude. Cada edição e cada mensagem do chat consomem os limites do seu plano (janela de 5 horas e limite semanal), sem cobrança por API.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Label("O vídeo e o áudio são processados no Mac.", systemImage: "desktopcomputer")
            Label("Somente o texto transcrito, os tempos e os ajustes vão para a Anthropic.", systemImage: "text.bubble")
            Label("Sua senha é digitada apenas no site oficial do Claude.", systemImage: "lock")
            Divider()
            if connection.connected {
                Text(connection.email.isEmpty ? "Conta Claude conectada" : connection.email).font(.headline)
                if !connection.plan.isEmpty { Text("Plano: \(connection.plan)").font(.caption).foregroundStyle(.secondary) }
            }
            Picker("Modelo", selection: $connection.selectedModel) { ForEach(connection.models) { model in Text(model.name).tag(model.id) } }
            Text(connection.models.first(where: { $0.id == connection.selectedModel })?.note ?? "").font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Contexto do canal (orienta as escolhas de edição)").font(.caption).foregroundStyle(.secondary)
                TextField("Contexto", text: $connection.channelContext, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                Button("Restaurar contexto do Projeto Ethos") { connection.channelContext = ClaudeConnection.defaultContext }.font(.caption).buttonStyle(.borderless)
            }
            if connection.cliPath == nil {
                Button("Localizar o Claude Code manualmente…", action: connection.chooseCLIManually)
            } else if !connection.connected {
                Button(action: connection.startSignIn) {
                    Text(connection.connecting ? "Aguardando o login…" : "Entrar com Claude").frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).tint(Color(red: 0.85, green: 0.47, blue: 0.34)).disabled(connection.connecting)
                if connection.connecting { Button("Cancelar", action: connection.cancelSignIn) }
            } else {
                HStack {
                    Button("Verificar novamente") { Task { await connection.restore() } }
                    Spacer()
                    Button("Sair da conta Claude", action: connection.disconnect)
                }
            }
            Text(connection.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let path = connection.cliPath { Text("Claude Code: \(path)").font(.caption2).foregroundStyle(.tertiary).lineLimit(2).textSelection(.enabled) }
            Text("Para ver quanto do limite resta, abra claude.ai › Configurações › Uso.").font(.caption2).foregroundStyle(.secondary)
        }.padding(28).frame(width: 540).preferredColorScheme(.dark)
        .task { await connection.restore() }
    }
}

/// Desfazer/refazer: dentro de um campo de texto vale o desfazer da digitação; fora dele, o histórico da edição.
@MainActor enum EditKeys {
    static func textUndoManager() -> UndoManager? {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return nil }
        return editor.undoManager
    }
    static func undo() { if let m = textUndoManager(), m.canUndo { m.undo() } else { Studio.current?.undo() } }
    static func redo() { if let m = textUndoManager(), m.canRedo { m.redo() } else { Studio.current?.redo() } }
    static var monitor: Any?
    static var deleteMonitor: Any?
    /// Delete apaga o item selecionado na linha do tempo (fora de campos de texto); ⌘B divide no cursor.
    static func installEditorShortcuts() {
        guard deleteMonitor == nil else { return }
        deleteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let typing = NSApp.keyWindow?.firstResponder is NSTextView
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !typing, flags.isDisjoint(with: [.command, .control, .option]), event.keyCode == 51 || event.keyCode == 117, let studio = Studio.current, studio.selection != nil {
                studio.deleteSelection(); return nil
            }
            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "b", let studio = Studio.current { studio.splitAtPlayhead(); return nil }
            return event
        }
    }
    /// Também aceita Ctrl+Z, Ctrl+Shift+Z e Ctrl+Y (hábito do Windows).
    static func installControlShortcuts() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.control), !flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            if key == "z" { flags.contains(.shift) ? redo() : undo(); return nil }
            if key == "y" { redo(); return nil }
            return event
        }
    }
}

@main struct CortaStudioApp: App {
    init() {
        // Sempre abre a janela principal: ignora o "estado salvo" do macOS, que após uma queda pode restaurar zero janelas.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
        Task { @MainActor in EditKeys.installControlShortcuts(); EditKeys.installEditorShortcuts() }
        NSApplication.shared.setActivationPolicy(.regular)
        if let i = CommandLine.arguments.firstIndex(of: "--gaze-test"), CommandLine.arguments.count > i + 2 {
            let args = CommandLine.arguments
            Task { @MainActor in
                do { try await GazeLab.run(video: URL(fileURLWithPath: args[i + 1]), folder: URL(fileURLWithPath: args[i + 2])); exit(0) }
                catch { fputs("GAZE_TEST_FAILED: \(error)\n", stderr); exit(1) }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--sample-test"), CommandLine.arguments.count > i + 2 {
            let args = CommandLine.arguments
            Task { @MainActor in
                do { try await StudioTests.sample(video: URL(fileURLWithPath: args[i + 1]), folder: URL(fileURLWithPath: args[i + 2])); exit(0) }
                catch { fputs("SAMPLE_TEST_FAILED: \(error)\n", stderr); exit(1) }
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--video-test"), CommandLine.arguments.count > i + 1 {
            let q = CommandLine.arguments[i + 1]
            Task { @MainActor in
                // --video-test URL: testa o recorte parcial de um vídeo remoto (o mesmo usado para o Pexels)
                let previous = UserDefaults.standard.string(forKey: "CortaLibraryPath")
                UserDefaults.standard.set(NSTemporaryDirectory() + "corta-video-teste", forKey: "CortaLibraryPath")
                let start = Date()
                let saved = await BrollSources.trimAndSave(URL(string: q)!, from: 30, seconds: 4, slug: "teste", credit: "teste")
                if let previous { UserDefaults.standard.set(previous, forKey: "CortaLibraryPath") } else { UserDefaults.standard.removeObject(forKey: "CortaLibraryPath") }
                let file = URL(fileURLWithPath: NSTemporaryDirectory() + "corta-video-teste/Videos/" + (saved?.name ?? "x"))
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
                let info = try? await MediaEngine.info(file)
                print("VIDEO recorte: \(saved?.name ?? "falhou") em \(Int(Date().timeIntervalSince(start))) s · \(size / 1024) KB · \(info.map { "\(Int($0.size.width))x\(Int($0.size.height)) \(String(format: "%.1f", $0.duration)) s" } ?? "-")")
                exit(0)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--gaze-full"), CommandLine.arguments.count > i + 1 {
            let path = CommandLine.arguments[i + 1]
            Task { @MainActor in
                let url = URL(fileURLWithPath: path); let start = Date()
                let duration = (try? await MediaEngine.info(url).duration) ?? 0
                guard let report = try? await MediaEngine.analyzeGaze(url, duration: duration, cache: Studio.cacheDirectory, status: { _ in }) else { print("falhou"); exit(1) }
                print("GAZE \(Int(Date().timeIntervalSince(start))) s para \(Int(duration)) s · baixo \(Int(report.down * 100))% · lado \(Int(report.side * 100))% · trechos \(report.away.count)")
                // Janelas de 2 minutos com mais olhar para fora
                var best: [(Double, Double)] = []
                for w in stride(from: 0.0, to: duration - 120, by: 30) { best.append((w, 1 - Double(report.cameraShare(w, w + 120)) / 100)) }
                for (w, a) in best.sorted(by: { $0.1 > $1.1 }).prefix(5) { print(String(format: "GAZE janela %4.0f s: %2.0f%% fora", w, a * 100)) }
                exit(0)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--illustrate-test"), CommandLine.arguments.count > i + 1 {
            let out = CommandLine.arguments[i + 1]
            Task { @MainActor in
                let connection = ClaudeConnection(); await connection.restore()
                let finder = ImageFinder(); finder.query = "uma vela acesa sobre um livro aberto, simbolizando a formação do caráter pela leitura"
                let start = Date()
                await finder.illustrate(vertical: false, connection: connection)
                if let cg = finder.results.first?.rendered { try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out)) }
                print("ILUSTRACAO \(finder.results.count) em \(Int(Date().timeIntervalSince(start))) s: \(finder.status)")
                exit(0)
            }
        }
        if CommandLine.arguments.contains("--self-test") {
            Task { @MainActor in
                do { try await StudioTests.run(); print("SELF_TEST_OK"); exit(0) }
                catch { fputs("SELF_TEST_FAILED: \(error)\n", stderr); exit(1) }
            }
        }
    }
    var body: some Scene {
        WindowGroup("Corta Studio") { StudioView() }
            .defaultSize(width: 1400, height: 840)
            .windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .saveItem) {
                    Button("Salvar projeto") { Studio.current?.saveProject() }.keyboardShortcut("s", modifiers: .command)
                    Button("Salvar projeto como…") { Studio.current?.saveProject(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
                    Button("Exportar o que está na tela…") { Studio.current?.exportCurrent() }.keyboardShortcut("e", modifiers: .command)
                }
                CommandGroup(after: .pasteboard) {
                    Button("Dividir no cursor") { Studio.current?.splitAtPlayhead() }.keyboardShortcut("b", modifiers: .command)
                }
                CommandGroup(replacing: .undoRedo) {
                    Button("Desfazer") { EditKeys.undo() }.keyboardShortcut("z", modifiers: .command)
                    Button("Refazer") { EditKeys.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
                }
                CommandGroup(replacing: .help) {
                    Button("Sobre esta versão") {
                        let alert = NSAlert(); alert.messageText = "Corta Studio 0.10.0 (Projeto Ethos) — Apple Silicon"
                        alert.informativeText = "Edição e renderização nativas no Mac. Transcrição local requer macOS 26. A IA usa o Claude Code com a sua assinatura Claude. A correção de olhar é experimental (desloca a íris; não recria o olho como ferramentas generativas). Não há busca automática de imagens na internet nem pesquisa de tendências: imagens e músicas vêm da sua Biblioteca."
                        alert.runModal()
                    }
                }
            }
    }
}
