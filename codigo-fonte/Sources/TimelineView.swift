import SwiftUI
import AVFoundation

private let gold = Color(red: 0.83, green: 0.66, blue: 0.29)
private let panel = Color(red: 0.085, green: 0.08, blue: 0.074)

// MARK: Miniaturas e forma de onda

@MainActor final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [Int: CGImage] = [:]
    static let step = 0.5
    private var generator: AVAssetImageGenerator?
    private var pending = Set<Int>()
    private var loading = false
    private var queue: [Int] = []

    func load(_ url: URL) {
        images = [:]; pending = []; queue = []
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 192)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        self.generator = generator
    }
    static func key(_ sourceTime: Double) -> Int { Int((sourceTime / step).rounded()) }
    func request(_ keys: [Int]) {
        let missing = keys.filter { images[$0] == nil && !pending.contains($0) }
        guard !missing.isEmpty else { return }
        missing.forEach { pending.insert($0) }
        queue.append(contentsOf: missing)
        pump()
    }
    private func pump() {
        guard !loading, let generator, !queue.isEmpty else { return }
        loading = true
        let batch = Array(queue.prefix(24)); queue.removeFirst(min(24, queue.count))
        Task { @MainActor in
            for await result in generator.images(for: batch.map { CMTime(seconds: Double($0) * Self.step, preferredTimescale: 600) }) {
                let k = Self.key(result.requestedTime.seconds)
                if let image = try? result.image { images[k] = image }
                pending.remove(k)
            }
            if images.count > 900 { images = images.filter { _ in Bool.random() } } // limita memória em vídeos longos
            loading = false
            pump()
        }
    }
}

@MainActor final class WaveformStore: ObservableObject {
    /// Pico de amplitude a cada 1/20 s do vídeo original.
    @Published private(set) var peaks: [Float] = []
    nonisolated static let rate = 20.0
    func load(_ url: URL) {
        peaks = []
        Task.detached(priority: .utility) {
            let values = (try? await Self.compute(url)) ?? []
            await MainActor.run { self.peaks = values }
        }
    }
    nonisolated private static func compute(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                                                                             AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1])
        reader.add(output); reader.startReading()
        let window = Int(8000 / rate)
        var peaks: [Float] = [], current: Int16 = 0, count = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: length / 2)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for v in data {
                current = max(current, v == Int16.min ? Int16.max : abs(v)); count += 1
                if count == window { peaks.append(Float(current) / Float(Int16.max)); current = 0; count = 0 }
            }
        }
        let top = max(0.05, peaks.sorted().dropLast(peaks.count / 100).last ?? 1)
        return peaks.map { min(1, $0 / top) }
    }
}

// MARK: Linha do tempo

struct TimelinePanel: View {
    @ObservedObject var studio: Studio
    @ObservedObject var playhead: Playhead
    @State private var zoom: Double = 40
    @State private var addMenu: AddMenu?

    struct AddMenu: Identifiable { let id = UUID(); let tile: Int; let point: CGPoint; let time: Double; let track: Track }
    enum Track: Int, CaseIterable { case ruler, video, captions, effects, audio
        var title: String { ["", "Vídeo", "Legendas", "Efeitos", "Áudio"][rawValue] }
        var height: CGFloat { [22, 58, 36, 50, 42][rawValue] }
        var top: CGFloat { Track.allCases.prefix(rawValue).reduce(0) { $0 + $1.height } }
    }
    static let tileWidth: CGFloat = 1200
    static var totalHeight: CGFloat { Track.allCases.reduce(0) { $0 + $1.height } }

    var body: some View {
        VStack(spacing: 0) {
            TimelineToolbar(studio: studio, clock: studio.clock, playhead: playhead, zoom: $zoom)
            Divider().opacity(0.3)
            // Rola na vertical quando a linha do tempo está mais baixa que as faixas.
            ScrollView(.vertical, showsIndicators: true) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ForEach(Track.allCases, id: \.self) { track in
                        HStack(spacing: 4) {
                            Text(track.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            Spacer()
                            switch track {
                            case .captions: plus("Legenda no cursor") { studio.addCaption() }
                            case .effects:
                                Menu { addButtons(nil) } label: { Image(systemName: "plus.circle") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Adicionar efeito no cursor")
                            case .video: plus("Remover o trecho selecionado") { if case .range(let a, let b)? = studio.selection { studio.removeRange(a, b) } }.opacity(isRange ? 1 : 0.3)
                            default: EmptyView()
                            }
                        }.padding(.horizontal, 8).frame(height: track.height)
                        .background(track == .ruler ? Color.clear : panel.opacity(0.6))
                        .overlay(alignment: .bottom) { Divider().opacity(0.25) }
                    }
                }.frame(width: 104)
                Divider().opacity(0.3)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        LazyHStack(spacing: 0) {
                            ForEach(0..<tileCount, id: \.self) { index in
                                TimelineTile(studio: studio, clock: studio.clock, playhead: playhead, thumbnails: studio.thumbnails, waveform: studio.waveform,
                                             index: index, zoom: zoom, lanes: lanes, addMenu: $addMenu)
                                    .frame(width: Self.tileWidth, height: Self.totalHeight).id(index)
                                    .popover(item: Binding(get: { addMenu?.tile == index ? addMenu : nil }, set: { if $0 == nil { addMenu = nil } }),
                                             attachmentAnchor: .rect(.rect(CGRect(origin: addMenu?.point ?? .zero, size: CGSize(width: 1, height: 1)))), arrowEdge: .top) { menu in
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Em \(timecode(menu.time))").font(.caption).foregroundStyle(.secondary)
                                            addButtons(menu.time)
                                            if menu.track == .captions { Button("Legenda aqui") { studio.seek(menu.time); studio.addCaption(); addMenu = nil } }
                                            if isRange { Divider(); Button("Remover o trecho selecionado", role: .destructive) { if case .range(let a, let b)? = studio.selection { studio.removeRange(a, b) }; addMenu = nil } }
                                        }.buttonStyle(.borderless).padding(12).frame(minWidth: 200, alignment: .leading)
                                    }
                            }
                        }
                    }
                    .onReceive(studio.clock.$time) { time in
                        guard studio.clock.playing else { return }
                        let tile = Int(CGFloat(time * zoom) / Self.tileWidth)
                        if tile != followTile { followTile = tile; withAnimation(.linear(duration: 0.2)) { proxy.scrollTo(tile, anchor: .leading) } }
                    }
                }
            }.frame(height: Self.totalHeight)
            }
        }
        .background(Color(red: 0.06, green: 0.056, blue: 0.052))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { studio.togglePlay(); return .handled }
        .onKeyPress(.leftArrow) { studio.step(NSEvent.modifierFlags.contains(.shift) ? -Int(1 / studio.frameDuration) : -1); return .handled }
        .onKeyPress(.rightArrow) { studio.step(NSEvent.modifierFlags.contains(.shift) ? Int(1 / studio.frameDuration) : 1); return .handled }
        .onKeyPress(.delete) { studio.deleteSelection(); return .handled }
        .onKeyPress(.deleteForward) { studio.deleteSelection(); return .handled }
    }
    @State private var followTile = -1
    private var isRange: Bool { if case .range? = studio.selection { return true }; return false }
    private var tileCount: Int { max(1, Int(ceil((CGFloat(playhead.duration) * zoom + 80) / Self.tileWidth))) }
    @ViewBuilder private func addButtons(_ time: Double?) -> some View {
        Menu { ForEach(Effect.zoomStyles, id: \.id) { z in Button(z.name) { add(.zoom, time, zoom: z.id) } } } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
        Menu { ForEach(Effect.fxStyles, id: \.id) { f in Button(f.name) { if let time { studio.addEffect(.fx, start: time, end: nil, fxStyle: f.id) } else { studio.addEffect(.fx, fxStyle: f.id) }; addMenu = nil } } } label: { Label("Efeito de vídeo", systemImage: "sparkles.tv") }
        Menu {
            ForEach(TextStyles.all) { style in
                Button(style.name) { if let time { studio.addEffect(.texto, start: time, end: nil, textStyle: style.id) } else { studio.addEffect(.texto, textStyle: style.id) }; addMenu = nil }
            }
        } label: { Label("Texto (destaque, capítulo, citação, lista…)", systemImage: "textformat") }
        Button { imageHere(time) } label: { Label("Buscar ou gerar imagem para a narração…", systemImage: "photo.on.rectangle.angled") }
        Button { add(.imagem, time) } label: { Label("Imagem da biblioteca", systemImage: "photo") }.disabled(Library.imageNames.isEmpty)
    }
    private func imageHere(_ time: Double?) {
        addMenu = nil
        if case .range(let a, let b)? = studio.selection, time == nil { studio.requestImage(outputStart: a, outputEnd: b) }
        else { let t = time ?? studio.clock.time; studio.requestImage(outputStart: t, outputEnd: min(playhead.duration, t + 4)) }
    }
    private func add(_ kind: Effect.Kind, _ time: Double?, zoom: String = "suave") {
        if let time { studio.addEffect(kind, start: time, end: nil, zoomStyle: zoom) } else { studio.addEffect(kind, zoomStyle: zoom) }
        addMenu = nil
    }
    private func plus(_ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "plus.circle") }.buttonStyle(.borderless).help(help)
    }
    /// Efeitos posicionados na edição, em faixas que não se sobrepõem.
    private var lanes: [LanedEffect] {
        guard let timeline = playhead.timeline else { return [] }
        var ends: [Double] = []
        var result: [LanedEffect] = []
        for effect in studio.effects.sorted(by: { $0.start < $1.start }) {
            let pieces = timeline.outputRanges(start: effect.start, end: effect.end)
            guard let first = pieces.first, let last = pieces.last else { continue }
            let lane = ends.firstIndex(where: { $0 <= first.0 }) ?? ends.count
            if lane == ends.count { ends.append(last.1) } else { ends[lane] = last.1 }
            result.append(LanedEffect(effect: effect, start: first.0, end: last.1, lane: min(lane, 2)))
        }
        return result
    }
}

struct LanedEffect { var effect: Effect; var start: Double; var end: Double; var lane: Int }

func timecode(_ t: Double, fps: Double = 30) -> String {
    guard t.isFinite else { return "—" }
    let total = max(0, t)
    let frames = Int((total - floor(total)) * fps)
    return String(format: "%02d:%02d.%02d", Int(total) / 60, Int(total) % 60, frames)
}

private struct TimelineToolbar: View {
    @ObservedObject var studio: Studio
    @ObservedObject var clock: PlayClock
    @ObservedObject var playhead: Playhead
    @Binding var zoom: Double
    var body: some View {
        HStack(spacing: 10) {
            Button { studio.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("Desfazer (⌘Z ou Ctrl+Z)").disabled(!studio.canUndo)
            Button { studio.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("Refazer (⇧⌘Z ou Ctrl+Y)").disabled(!studio.canRedo)
            Divider().frame(height: 16)
            Button { studio.step(-1) } label: { Image(systemName: "backward.frame.fill") }.help("Quadro anterior (←)")
            Button { studio.togglePlay() } label: { Image(systemName: clock.playing ? "pause.fill" : "play.fill").frame(width: 16) }.help("Reproduzir/pausar (espaço)")
            Button { studio.step(1) } label: { Image(systemName: "forward.frame.fill") }.help("Próximo quadro (→)")
            Text("\(timecode(clock.time, fps: 1 / studio.frameDuration)) / \(timecode(playhead.duration, fps: 1 / studio.frameDuration))").font(.system(.caption, design: .monospaced))
            // Sempre visível, logo ao lado do tempo (não some em janelas estreitas).
            Button { studio.showReelsSheet = true } label: { Label("Reels Ethos", systemImage: "rectangle.portrait.on.rectangle.portrait.angled") }
                .help("Modelo Reels Ethos: imagens no alto em degradê, legenda bege serifada e cartões de citação").fixedSize().disabled(studio.source == nil || studio.busy)
            Button { studio.openBroll(target: .auto) } label: { Label("Imagens e vídeos", systemImage: "photo.on.rectangle.angled") }
                .help("Imagens ou vídeos de apoio escolhidos pela narração: de uma pasta do computador, da biblioteca ou da internet").fixedSize()
            Button { studio.openCover() } label: {
                Label(studio.gaze == nil ? "Cobrir olhadas" : "Cobrir olhadas (\(studio.coverCount))", systemImage: "photo.stack")
            }
            .foregroundStyle(studio.coverCount > 0 ? Color(red: 0.95, green: 0.55, blue: 0.2) : .secondary)
            .help("Cobrir com imagens os trechos em que você fala olhando para fora da câmera (faixa laranja). Se o olhar ainda não foi analisado, analisa antes.")
            .fixedSize()
            if !studio.liveStatus.isEmpty { Text(studio.liveStatus).font(.caption2).foregroundStyle(gold).lineLimit(1) }
            Spacer()
            if case .range(let a, let b)? = studio.selection {
                Text("Seleção \(String(format: "%.2f", b - a)) s").font(.caption2).foregroundStyle(gold)
                Button("Remover trecho") { studio.removeRange(a, b) }
                Menu("Efeito") { ForEach(Effect.fxStyles, id: \.id) { f in Button(f.name) { studio.addEffect(.fx, fxStyle: f.id) } } }.fixedSize()
                Menu("Zoom") { ForEach(Effect.zoomStyles, id: \.id) { z in Button(z.name) { studio.addEffect(.zoom, zoomStyle: z.id) } } }.fixedSize()
                Button("Texto") { studio.addEffect(.texto) }
                Button("Imagem ou vídeo aqui") { studio.openBroll(target: .range(a, b)) }
                Button("Limpar") { studio.selection = nil }
            }

            if !studio.exclusions.isEmpty {
                Button("Restaurar \(studio.exclusions.count) trecho(s) removido(s)") { studio.restoreExclusions() }.font(.caption)
            }
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log(zoom) }, set: { zoom = exp($0) }), in: log(2)...log(400)).frame(width: 130)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless).font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .disabled(studio.source == nil)
    }
}

private struct TimelineTile: View {
    @ObservedObject var studio: Studio
    @ObservedObject var clock: PlayClock
    @ObservedObject var playhead: Playhead
    @ObservedObject var thumbnails: ThumbnailStore
    @ObservedObject var waveform: WaveformStore
    let index: Int
    let zoom: Double
    let lanes: [LanedEffect]
    @Binding var addMenu: TimelinePanel.AddMenu?
    @State private var drag: DragMode?
    @State private var ghost: (id: UUID, start: Double, end: Double)?
    @State private var rangeAnchor: Double?
    @State private var hoverPoint: CGPoint = .zero

    /// Menu do botão direito (ou Control+clique): ações no ponto clicado.
    @ViewBuilder private func contextMenu(at p: CGPoint) -> some View {
        let t = max(0, min(time(p.x), playhead.duration))
        let tr = track(p.y)
        Text("Em \(timecode(t))")
        Button("Dividir aqui  (⌘B)") { studio.split(at: t) }
        if tr == .effects, let (item, _) = hitEffect(p) {
            Divider()
            Button("Editar este efeito") { studio.selection = .effect(item.effect.id); studio.requestedTab = "Editar" }
            Button("Apagar este efeito  (⌫)") { studio.selection = .effect(item.effect.id); studio.deleteSelection() }
        }
        if tr == .captions, let (cue, _) = hitCaption(p), let id = cue.sourceID {
            Divider()
            Button("Editar esta legenda") { studio.selection = .caption(id); studio.requestedTab = "Editar" }
            Button("Apagar só o texto da legenda  (⌫)") { studio.hideCaption(id) }
            Button("Remover esta fala do vídeo") { studio.setCaption(id) { $0.included = false } }
        }
        Divider()
        if case .range(let a, let b)? = studio.selection {
            Button("Apagar o trecho selecionado (\(String(format: "%.1f", b - a)) s)  (⌫)") { studio.removeRange(a, b) }
            Button("Usar este trecho como gancho no começo (◀◀ rebobinar)") { studio.hookFromSelection(transition: "rebobinar") }
                .disabled(b - a < 1)
        }
        if let seg = studio.segment(at: t) {
            Button("Selecionar este trecho (\(String(format: "%.1f", seg.1 - seg.0)) s)") { studio.selection = .range(seg.0, seg.1) }
            Button("Apagar este trecho (\(String(format: "%.1f", seg.1 - seg.0)) s)") { studio.removeRange(seg.0, seg.1) }
        }
        Button("Apagar do início até aqui") { studio.removeRange(0, t) }
        Button("Apagar daqui até o fim") { studio.removeRange(t, playhead.duration) }
        Divider()
        Menu("Adicionar efeito de vídeo aqui") { ForEach(Effect.fxStyles, id: \.id) { f in Button(f.name) { studio.addEffect(.fx, start: t, end: nil, fxStyle: f.id) } } }
        Menu("Adicionar zoom aqui") { ForEach(Effect.zoomStyles, id: \.id) { z in Button(z.name) { studio.addEffect(.zoom, start: t, end: nil, zoomStyle: z.id) } } }
        Menu("Adicionar texto aqui") {
            ForEach(TextStyles.all) { style in Button(style.name) { studio.addEffect(.texto, start: t, end: nil, textStyle: style.id) } }
        }
        Button("Imagem para a narração aqui…") { studio.requestImage(outputStart: t, outputEnd: min(playhead.duration, t + 4)) }
        Button("Imagem ou vídeo de uma pasta / internet aqui…") { studio.openBroll(target: .range(t, min(playhead.duration, t + 4))) }
        Button("Adicionar legenda aqui") { studio.seek(t); studio.addCaption() }
        if !studio.splits.isEmpty { Divider(); Button("Remover todas as divisões") { studio.removeSplits() } }
    }

    enum DragMode { case done, scrub, range(Double), move(UUID, Double, Double), resize(UUID, Bool, Double, Double), captionEdge(Int, Bool), pending(TimelinePanel.Track, Double) }
    typealias Track = TimelinePanel.Track

    private var origin: Double { Double(CGFloat(index) * TimelinePanel.tileWidth) / zoom }
    private func x(_ t: Double) -> CGFloat { CGFloat((t - origin) * zoom) }
    private func time(_ x: CGFloat) -> Double { origin + Double(x) / zoom }
    private func track(_ y: CGFloat) -> Track { Track.allCases.last(where: { y >= $0.top }) ?? .ruler }

    var body: some View {
        Canvas { context, size in draw(&context, size) }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged(changed).onEnded(ended))
            .onContinuousHover { phase in if case .active(let p) = phase { hoverPoint = p } }
            .contextMenu { contextMenu(at: hoverPoint) }
            .onAppear(perform: requestThumbs)
            .onChange(of: zoom) { requestThumbs() }
            .onChange(of: playhead.timeline?.duration) { requestThumbs() }
    }

    // MARK: Desenho

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        let span = (origin, origin + Double(size.width) / zoom)
        let duration = playhead.duration
        guard let timeline = playhead.timeline else { return }
        // Régua
        let rulerStep: Double = zoom > 150 ? 0.5 : zoom > 60 ? 1 : zoom > 20 ? 5 : zoom > 6 ? 15 : 60
        var t = (span.0 / rulerStep).rounded(.down) * rulerStep
        while t <= span.1 {
            if t <= duration {
                context.fill(Path(CGRect(x: x(t), y: 14, width: 1, height: 8)), with: .color(.white.opacity(0.35)))
                context.draw(Text(timecode(t).dropLast(3)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary), at: CGPoint(x: x(t) + 3, y: 7), anchor: .leading)
            }
            t += rulerStep
        }
        let endX = min(size.width, x(duration))
        guard endX > 0 else { return }
        // Vídeo: miniaturas
        let video = CGRect(x: 0, y: Track.video.top + 3, width: endX, height: Track.video.height - 6)
        context.fill(Path(roundedRect: video, cornerRadius: 4), with: .color(Color(white: 0.16)))
        let thumbW = video.height * 16 / 9
        var tx = (floor(0 / thumbW)) * thumbW
        while tx < endX {
            let mid = time(tx + thumbW / 2)
            if mid < duration, let image = thumbnails.images[ThumbnailStore.key(timeline.sourceTime(mid))] {
                var c = context; c.clip(to: Path(roundedRect: video, cornerRadius: 4))
                c.draw(Image(decorative: image, scale: 1), in: CGRect(x: tx, y: video.minY, width: thumbW, height: video.height))
            }
            tx += thumbW
        }
        // Olhar fora da câmera (modo roteiro): faixa laranja no topo da faixa de vídeo
        if let gaze = studio.gaze, studio.settings.scriptMode {
            for away in gaze.away {
                for piece in timeline.outputRanges(start: away.start, end: away.end) where piece.1 >= span.0 && piece.0 <= span.1 {
                    context.fill(Path(CGRect(x: x(piece.0), y: video.minY, width: max(2, x(piece.1) - x(piece.0)), height: 5)), with: .color(Color(red: 0.95, green: 0.55, blue: 0.2)))
                }
            }
        }
        // Gancho em vídeo: o começo repete o ápice da fala
        if timeline.hookCount > 0 {
            let end = timeline.hookDuration
            if end >= span.0 {
                let rect = CGRect(x: x(0), y: video.minY, width: max(2, x(end) - x(0)), height: video.height)
                context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(red: 0.55, green: 0.35, blue: 0.85).opacity(0.28)))
                context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(red: 0.70, green: 0.50, blue: 1.0)), lineWidth: 1.5)
            }
        }
        // Junções de cortes, com losango clicável para escolher a transição
        for j in timeline.junctions(settings: studio.settings, marks: studio.transitionMarks) where j.time >= span.0 - 1 && j.time <= span.1 + 1 {
            let jx = x(j.time)
            let selected = studio.selection == .transition(j.sourceTime)
            context.fill(Path(CGRect(x: jx - 1, y: video.minY, width: 2, height: video.height)), with: .color(gold.opacity(0.85)))
            if j.type != "corte" {
                let half = CGFloat(j.duration / 2 * zoom)
                context.fill(Path(roundedRect: CGRect(x: jx - half, y: video.maxY - 6, width: half * 2, height: 4), cornerRadius: 2), with: .color(gold.opacity(0.6)))
            }
            var diamond = Path()
            let cy = video.midY, r: CGFloat = selected ? 8 : 6
            diamond.move(to: CGPoint(x: jx, y: cy - r)); diamond.addLine(to: CGPoint(x: jx + r, y: cy)); diamond.addLine(to: CGPoint(x: jx, y: cy + r)); diamond.addLine(to: CGPoint(x: jx - r, y: cy)); diamond.closeSubpath()
            context.fill(diamond, with: .color(j.type == "corte" ? Color(white: 0.15) : gold))
            context.stroke(diamond, with: .color(selected ? .white : gold), lineWidth: selected ? 2 : 1)
        }
        // Legendas
        let capRow = CGRect(x: 0, y: Track.captions.top + 4, width: endX, height: Track.captions.height - 8)
        for cue in timeline.captions where cue.end >= span.0 && cue.start <= span.1 {
            let r = CGRect(x: x(cue.start), y: capRow.minY, width: max(2, x(cue.end) - x(cue.start) - 1), height: capRow.height)
            let selected = studio.selection == .caption(cue.sourceID ?? -1)
            context.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(selected ? gold.opacity(0.55) : Color(red: 0.25, green: 0.33, blue: 0.42)))
            if r.width > 24 {
                var c = context; c.clip(to: Path(r.insetBy(dx: 3, dy: 0)))
                c.draw(Text(cue.text).font(.system(size: 10)).foregroundStyle(.white), at: CGPoint(x: r.minX + 4, y: r.midY), anchor: .leading)
            }
        }
        // Efeitos
        for item in lanes where item.end >= span.0 && item.start <= span.1 {
            var a = item.start, b = item.end
            if let ghost, ghost.id == item.effect.id { a = ghost.start; b = ghost.end }
            let laneH = (Track.effects.height - 8) / 3
            let r = CGRect(x: x(a), y: Track.effects.top + 4 + CGFloat(item.lane) * laneH, width: max(4, x(b) - x(a)), height: laneH - 2)
            let color: Color = item.effect.kind == .zoom ? Color(red: 0.55, green: 0.40, blue: 0.20) : item.effect.kind == .texto ? Color(red: 0.42, green: 0.30, blue: 0.48) : item.effect.kind == .video ? Color(red: 0.22, green: 0.35, blue: 0.55) : item.effect.kind == .fx ? Color(red: 0.62, green: 0.22, blue: 0.28) : Color(red: 0.25, green: 0.42, blue: 0.33)
            let selected = studio.selection == .effect(item.effect.id)
            context.fill(Path(roundedRect: r, cornerRadius: 3), with: .color(selected ? gold : color))
            if selected { context.stroke(Path(roundedRect: r, cornerRadius: 3), with: .color(.white), lineWidth: 1) }
            if r.width > 30 {
                var c = context; c.clip(to: Path(r.insetBy(dx: 3, dy: 0)))
                let label = item.effect.kind == .zoom || item.effect.kind == .fx ? item.effect.label : item.effect.kind == .texto ? item.effect.text : item.effect.asset
                c.draw(Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(selected ? .black : .white), at: CGPoint(x: r.minX + 4, y: r.midY), anchor: .leading)
            }
        }
        // Áudio: forma de onda
        let audio = CGRect(x: 0, y: Track.audio.top + 3, width: endX, height: Track.audio.height - 6)
        context.fill(Path(roundedRect: audio, cornerRadius: 4), with: .color(Color(red: 0.10, green: 0.16, blue: 0.14)))
        if !waveform.peaks.isEmpty {
            var path = Path()
            var px: CGFloat = 0
            while px < endX {
                let src = timeline.sourceTime(time(px))
                let i = Int(src * WaveformStore.rate)
                let v = i >= 0 && i < waveform.peaks.count ? CGFloat(waveform.peaks[i]) : 0
                let h = max(1, v * audio.height * 0.9)
                path.addRect(CGRect(x: px, y: audio.midY - h / 2, width: 1.5, height: h))
                px += 2
            }
            context.fill(path, with: .color(Color(red: 0.45, green: 0.75, blue: 0.6).opacity(0.8)))
        }
        if !studio.settings.musicFile.isEmpty {
            context.draw(Text("♪ " + studio.settings.musicFile).font(.system(size: 9)).foregroundStyle(gold), at: CGPoint(x: 6, y: audio.minY + 7), anchor: .leading)
        }
        // Seleção de trecho
        if case .range(let a, let b)? = studio.selection, b >= span.0, a <= span.1 {
            let r = CGRect(x: x(a), y: 0, width: x(b) - x(a), height: size.height)
            context.fill(Path(r), with: .color(gold.opacity(0.16)))
            context.stroke(Path(r), with: .color(gold.opacity(0.8)), lineWidth: 1)
        }
        // Cursor
        let px = x(clock.time)
        if px >= -2, px <= size.width + 2 {
            context.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.white))
            var head = Path(); head.move(to: CGPoint(x: px - 6, y: 0)); head.addLine(to: CGPoint(x: px + 6, y: 0)); head.addLine(to: CGPoint(x: px, y: 9)); head.closeSubpath()
            context.fill(head, with: .color(gold))
        }
    }

    private func requestThumbs() {
        guard let timeline = playhead.timeline else { return }
        let thumbW = (Track.video.height - 6) * 16 / 9
        var keys: [Int] = []
        var tx: CGFloat = 0
        while tx < TimelinePanel.tileWidth {
            let mid = time(tx + thumbW / 2)
            if mid < playhead.duration { keys.append(ThumbnailStore.key(timeline.sourceTime(mid))) }
            tx += thumbW
        }
        thumbnails.request(keys)
    }

    // MARK: Interação

    private func hitEffect(_ p: CGPoint) -> (LanedEffect, edge: Bool?)? {
        let laneH = (Track.effects.height - 8) / 3
        for item in lanes.reversed() {
            let r = CGRect(x: x(item.start), y: Track.effects.top + 4 + CGFloat(item.lane) * laneH, width: max(4, x(item.end) - x(item.start)), height: laneH - 2)
            guard r.insetBy(dx: -4, dy: 0).contains(p) else { continue }
            if p.x <= r.minX + 6 { return (item, true) }
            if p.x >= r.maxX - 6 { return (item, false) }
            return (item, nil)
        }
        return nil
    }
    private func hitCaption(_ p: CGPoint) -> (Caption, edge: Bool?)? {
        guard let timeline = playhead.timeline else { return nil }
        let t = time(p.x)
        guard let cue = timeline.captions.first(where: { t >= $0.start - 4 / zoom && t <= $0.end + 4 / zoom }) else { return nil }
        if abs(x(cue.start) - p.x) < 5 { return (cue, true) }
        if abs(x(cue.end) - p.x) < 5 { return (cue, false) }
        return (cue, nil)
    }

    private func changed(_ value: DragGesture.Value) {
        let moved = abs(value.translation.width) > 3
        if drag == nil {
            let p = value.startLocation, tr = track(p.y), t = time(p.x)
            switch tr {
            case .effects:
                if let (item, edge) = hitEffect(p) {
                    studio.selection = .effect(item.effect.id); studio.requestedTab = "Editar"
                    drag = edge == nil ? .move(item.effect.id, item.start, item.end) : .resize(item.effect.id, edge!, item.start, item.end)
                } else { drag = .pending(tr, t) }
            case .captions:
                if let (cue, edge) = hitCaption(p), let id = cue.sourceID {
                    studio.selection = .caption(id); studio.requestedTab = "Editar"
                    drag = edge == nil ? .scrub : .captionEdge(id, edge!)
                    if edge == nil { studio.seek(cue.start) }
                } else { drag = .pending(tr, t) }
            case .ruler: drag = .scrub; studio.seek(t)
            case .video:
                if let timeline = playhead.timeline,
                   let j = timeline.junctions(settings: studio.settings, marks: studio.transitionMarks).first(where: { abs(x($0.time) - p.x) < 9 }) {
                    studio.selection = .transition(j.sourceTime); studio.requestedTab = "Editar"; drag = .done
                } else { drag = .pending(tr, t) }
            default: drag = .pending(tr, t)
            }
        }
        let t = time(value.location.x)
        let delta = Double(value.translation.width) / zoom
        switch drag {
        case .scrub?: studio.seek(t)
        case .pending(_, let start)? where moved: drag = .range(start); studio.selection = .range(min(start, t), max(start, t))
        case .range(let start)?: studio.selection = .range(max(0, min(start, t)), min(playhead.duration, max(start, t)))
        case .move(let id, let a, let b)?: ghost = (id, max(0, a + delta), max(0, a + delta) + (b - a))
        case .resize(let id, let leading, let a, let b)?: ghost = leading ? (id, min(b - 0.1, max(0, a + delta)), b) : (id, a, max(a + 0.1, b + delta))
        case .captionEdge?: break
        default: break
        }
    }
    private func ended(_ value: DragGesture.Value) {
        let moved = abs(value.translation.width) > 3
        let t = time(value.location.x)
        switch drag {
        case .move(let id, _, _)?, .resize(let id, _, _, _)?:
            if moved, let ghost, ghost.id == id { studio.setEffectTiming(id, start: ghost.start, end: ghost.end) }
            else if !moved, let item = lanes.first(where: { $0.effect.id == id }) { studio.seek(item.start + min(0.6, (item.end - item.start) / 2)) }
        case .captionEdge(let id, let leading)?:
            if moved { leading ? studio.setCaptionTiming(id, start: t) : studio.setCaptionTiming(id, end: t) }
        case .pending(let tr, let start)?:
            studio.seek(start)
            // Clique simples na faixa de vídeo seleciona o trecho (entre duas junções), pronto para apagar com ⌫.
            if tr == .video, let seg = studio.segment(at: start) { studio.selection = .range(seg.0, seg.1) }
            else if case .range? = studio.selection { studio.selection = nil }
            else if case .caption? = studio.selection { studio.selection = nil }
            else if case .effect? = studio.selection { studio.selection = nil }
        default: break
        }
        drag = nil; ghost = nil
    }
}
