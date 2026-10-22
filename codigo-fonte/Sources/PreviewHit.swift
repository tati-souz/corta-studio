import SwiftUI

// MARK: Clicar nos textos da prévia para editá-los

/// O que está desenhado num ponto da prévia.
enum PreviewTarget: Equatable { case effect(UUID), caption(Int), question }

extension Studio {
    /// Tamanho de referência da imagem final (as posições são proporcionais, então serve para a prévia também).
    var frameSize: CGSize { settings.vertical ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080) }

    /// Caixas (em proporção 0–1, origem no alto à esquerda) dos textos visíveis agora, do de baixo para o de cima.
    func visibleTextBoxes() -> [(target: PreviewTarget, box: CGRect)] {
        guard let timeline = playhead.timeline else { return [] }
        let t = clock.time, size = frameSize
        var plain = settings; plain.watermark = false; plain.eyeContact = false
        let placed = effects.filter { $0.kind == .texto }.flatMap { e in timeline.outputRanges(start: e.start, end: e.end).map { PlacedEffect(effect: e, start: $0.0, end: $0.1) } }
        let painter = FramePainter(size: size, timeline: timeline, settings: plain, support: nil, effects: placed)
        func normalized(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX / size.width, y: 1 - r.maxY / size.height, width: r.width / size.width, height: r.height / size.height)
        }
        var result: [(PreviewTarget, CGRect)] = []
        // Legenda: faixa em torno da posição da legenda (o desenho exato varia com a palavra falada).
        if settings.captions, let cue = timeline.captions.last(where: { $0.start <= t && $0.end > t }) {
            let v = settings.vertical
            let y: CGFloat
            if settings.captionMode == "Uma palavra" { y = v ? 0.36 : 0.32 }
            else if settings.captionStyle == "Bege" { y = settings.captionPosition == "Centro" ? (v ? 0.36 : 0.30) : (v ? 0.25 : 0.12) }
            else { y = settings.captionPosition == "Centro" ? (v ? 0.33 : 0.30) : (v ? 0.19 : 0.11) }
            let band: CGFloat = v ? 0.10 : 0.12
            result.append((.caption(cue.sourceID ?? cue.id), CGRect(x: 0.06, y: 1 - y - band / 2, width: 0.88, height: band)))
        }
        for effect in effects where effect.kind == .texto && !effect.text.isEmpty {
            for range in timeline.outputRanges(start: effect.start, end: effect.end) where t >= range.0 && t <= range.1 {
                let box = painter.styledText(effect).box
                if box.width > 1 { result.append((.effect(effect.id), normalized(box))) }
            }
        }
        if !settings.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, t < min(5, timeline.duration) {
            let y: CGFloat = settings.vertical ? 0.85 : 0.78
            result.append((.question, CGRect(x: 0.1, y: 1 - y - 0.06, width: 0.8, height: 0.12)))
        }
        return result
    }

    /// Clique na prévia: seleciona o texto e abre o editor na lateral.
    func tapPreview(at point: CGPoint) {
        let hits = visibleTextBoxes().filter { $0.box.insetBy(dx: -0.015, dy: -0.015).contains(point) }
        // Textos na tela ficam por cima da legenda; o menor alvo ganha quando há sobreposição.
        guard let hit = hits.min(by: { ($0.box.width * $0.box.height) < ($1.box.width * $1.box.height) }) else { return }
        player?.pause()
        switch hit.target {
        case .effect(let id): selection = .effect(id); requestedTab = "Editar"
        case .caption(let id): selection = .caption(id); requestedTab = "Editar"
        case .question: requestedTab = "Reels"; message = "O gancho escrito fica em Reels › Formato (e em Destino e objetivo)."
        }
    }
}

/// Camada transparente sobre a prévia: realça o texto selecionado e recebe os cliques.
struct PreviewTapLayer: View {
    @ObservedObject var studio: Studio
    @ObservedObject var clock: PlayClock
    @State private var hover: CGRect?
    @State private var boxes: [(target: PreviewTarget, box: CGRect)] = []
    private let accent = Color(red: 0.83, green: 0.66, blue: 0.29)

    var body: some View {
        GeometryReader { g in
            let frame = studio.frameSize
            let scale = min(g.size.width / frame.width, g.size.height / frame.height)
            let w = frame.width * scale, h = frame.height * scale
            let origin = CGPoint(x: (g.size.width - w) / 2, y: (g.size.height - h) / 2)
            let rect: (CGRect) -> CGRect = { r in CGRect(x: origin.x + r.minX * w, y: origin.y + r.minY * h, width: r.width * w, height: r.height * h) }
            // Só as caixas de texto recebem cliques; o resto passa para o player (play, barra de tempo, volume).
            ZStack(alignment: .topLeading) {
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, item in
                    let selected: Bool = {
                        switch item.target {
                        case .effect(let id): return studio.selection == .effect(id)
                        case .caption(let id): return studio.selection == .caption(id)
                        case .question: return false
                        }
                    }()
                    let r = rect(item.box.insetBy(dx: -0.01, dy: -0.01))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.001))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(selected || hover == item.box ? 1 : 0), style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4])))
                        .frame(width: r.width, height: r.height)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            hover = inside ? item.box : (hover == item.box ? nil : hover)
                            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                        }
                        .onTapGesture { studio.tapPreview(at: CGPoint(x: item.box.midX, y: item.box.midY)) }
                        .help("Clique para editar este texto")
                        .offset(x: r.minX, y: r.minY)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .onAppear(perform: refresh)
        .onChange(of: clock.time) { if !clock.playing { refresh() } }
        .onChange(of: clock.playing) { refresh() }
        .onChange(of: studio.effects) { refresh() }
        .onChange(of: studio.settings) { refresh() }
        .onChange(of: studio.selection) { refresh() }
    }
    private func refresh() { boxes = clock.playing ? [] : studio.visibleTextBoxes() }
}
