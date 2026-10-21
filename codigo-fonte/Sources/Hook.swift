import SwiftUI

// MARK: Gancho em vídeo (cold open) e ações que a IA pode pedir pelo chat

extension Studio {
    /// A IA procura os melhores momentos para abrir o vídeo; o primeiro já é aplicado e os outros ficam para escolher.
    func findHooks() {
        operation("O Claude está procurando o ápice da fala para o gancho…") {
            if self.captions.isEmpty { try await self.performTranscriptionPublic() }
            if !self.connection.connected { await self.connection.restore() }
            guard self.connection.connected else { throw StudioError("Conecte sua conta Claude em IA e conta para encontrar o gancho.") }
            self.aiWorking = true
            let found = try await self.connection.findVideoHooks(captions: self.captions)
            self.aiWorking = false
            guard let best = found.first else { throw StudioError("A IA não encontrou um trecho forte o bastante para abrir o vídeo.") }
            self.hookCandidates = found
            self.useHook(best.hook)
            self.message = "Gancho em vídeo aplicado. Veja outras opções na aba Reels ou no painel do gancho."
        }
    }
    func useHook(_ hook: VideoHook) {
        commitHistory()
        var hook = hook
        if let current = videoHook { hook.transition = current.transition }
        videoHook = hook
        playHook()
    }
    func removeHook() { commitHistory(); videoHook = nil }
    /// Ajuste fino do início/fim do gancho (em segundos do original).
    func nudgeHook(start: Double = 0, end: Double = 0) {
        guard var hook = videoHook, let duration = media?.duration else { return }
        hook.start = max(0, hook.start + start); hook.end = min(duration, hook.end + end)
        guard hook.end - hook.start >= 1 else { return }
        videoHook = hook
    }
    /// Usa o trecho marcado na linha do tempo como gancho.
    func hookFromSelection(transition: String? = nil) {
        guard case .range(let a, let b)? = selection, let timeline = playhead.timeline else { return }
        let start = timeline.sourceTime(a), end = timeline.sourceTime(max(a, b - 0.001)) + 0.001
        guard end - start >= 1 else { message = "Selecione pelo menos 1 segundo para o gancho."; return }
        useHook(VideoHook(start: start, end: min(end, start + 15)))
        if let transition { videoHook?.transition = transition }
        selection = nil
        message = "Trecho usado como gancho: ele abre o vídeo e, com o efeito de rebobinar, o vídeo volta ao começo. Ajuste na aba Reels › Gancho em vídeo."
    }
    func playHook() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.seek(0); self.player?.play()
        }
    }
    var hookText: String { videoHook.map { VideoHook.text(captions: captions, start: $0.start, end: $0.end) } ?? "" }

    /// Operações que a IA pediu no chat ou na edição completa.
    func runActions(_ actions: [[String: Any]]) async throws {
        for action in actions {
            try Task.checkCancellation()
            let source = action["source"] as? String ?? "fotos"
            let density = ["poucos": "poucos (um apoio a cada ~40 s)", "muitos": "muitos (um apoio a cada ~10 s)"][action["density"] as? String ?? ""] ?? "médio (um apoio a cada ~20 s)"
            switch action["action"] as? String {
            case "buscar_imagens":
                try await placeBrollWork(target: .auto, source: source, folder: nil, density: density, display: action["layout"] as? String ?? "tela-cheia", entrance: "fade", minimum: 1)
            case "cobrir_olhadas":
                if gaze == nil { try await analyzeGaze() }
                if !lookAwaySegments().isEmpty { try await placeBrollWork(target: .lookAway, source: source, folder: nil, density: density, display: action["layout"] as? String ?? "tela-cheia", entrance: "fade", minimum: 1) }
            case "montar_reels":
                var options = ReelsOptions(); options.aiSource = ["fotos", "misto", "videos", "claude"].contains(source) ? source : "fotos"
                try await buildReelsWork(options)
            case "gerar_cortes":
                if let length = action["length"] as? String { clipOptions.length = length }
                if let prompt = action["prompt"] as? String { clipOptions.prompt = prompt }
                try await suggestClipsWork(count: min(20, max(1, action["count"] as? Int ?? clipOptions.count)))
                requestedTab = "Cortes"
            case "cartoes_citacao":
                await addQuoteCards()
            default: continue
            }
        }
        if !actions.isEmpty { aiWorking = false; scheduleLive(delay: 0) }
    }
}

/// Painel do gancho em vídeo (usado na aba Reels e no painel de ajustes).
struct HookPanel: View {
    @ObservedObject var studio: Studio
    private let accent = Color(red: 0.83, green: 0.66, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("O momento mais forte da fala abre o vídeo por alguns segundos. Depois entra a transição e o vídeo segue do começo, passando de novo por esse trecho no lugar dele.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { studio.findHooks() } label: { Label(studio.videoHook == nil ? "Encontrar o melhor gancho" : "Procurar outro", systemImage: "sparkles") }
                    .buttonStyle(.borderedProminent).foregroundStyle(.black)
                Button("Usar trecho selecionado") { studio.hookFromSelection() }
                    .disabled({ if case .range? = studio.selection { return false }; return true }())
                    .help("Arraste na linha do tempo para marcar um trecho e use-o como gancho")
            }.font(.caption).disabled(studio.source == nil || studio.busy)
            if let hook = studio.videoHook {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(clockLabel(hook.start)) – \(clockLabel(hook.end)) · \(String(format: "%.1f", hook.end - hook.start)) s").font(.caption.monospacedDigit()).foregroundStyle(accent)
                        Spacer()
                        Button { studio.playHook() } label: { Label("Ver", systemImage: "play.fill") }.buttonStyle(.borderless)
                        Button(role: .destructive) { studio.removeHook() } label: { Label("Tirar", systemImage: "xmark") }.buttonStyle(.borderless)
                    }.font(.caption)
                    Text("“\(studio.hookText)”").font(.caption).italic().fixedSize(horizontal: false, vertical: true)
                    if !hook.reason.isEmpty { Text(hook.reason).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    HStack(spacing: 6) {
                        Text("Início").font(.caption2)
                        Button { studio.nudgeHook(start: -0.25) } label: { Image(systemName: "minus") }
                        Button { studio.nudgeHook(start: 0.25) } label: { Image(systemName: "plus") }
                        Spacer()
                        Text("Fim").font(.caption2)
                        Button { studio.nudgeHook(end: -0.25) } label: { Image(systemName: "minus") }
                        Button { studio.nudgeHook(end: 0.25) } label: { Image(systemName: "plus") }
                    }.buttonStyle(.bordered).controlSize(.small).help("Ajusta 0,25 s por clique")
                    Picker("Transição de volta", selection: Binding(get: { hook.transition }, set: { v in studio.commitHistory(); studio.videoHook?.transition = v })) {
                        ForEach(VideoHook.transitions, id: \.id) { Text($0.name).tag($0.id) }
                    }.font(.caption)
                }
                .padding(8).background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            }
            if studio.hookCandidates.count > 1 {
                Text("Outras opções da IA").font(.caption2.weight(.semibold))
                ForEach(Array(studio.hookCandidates.enumerated()), id: \.offset) { _, candidate in
                    let current = studio.videoHook.map { abs($0.start - candidate.hook.start) < 0.3 } ?? false
                    Button { studio.useHook(candidate.hook) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(candidate.text)”").font(.caption).italic().lineLimit(3).multilineTextAlignment(.leading)
                            Text("\(clockLabel(candidate.hook.start)) · \(String(format: "%.1f", candidate.hook.end - candidate.hook.start)) s\(candidate.hook.reason.isEmpty ? "" : " · " + candidate.hook.reason)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).stroke(current ? accent : Color.white.opacity(0.12)))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
