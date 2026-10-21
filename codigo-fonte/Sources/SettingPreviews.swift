import SwiftUI
import AVFoundation

/// Miniaturas das opções do painel (cor, enquadramento, transições, legendas, vinheta, fundo),
/// desenhadas pelo mesmo motor da edição sobre o quadro atual do vídeo.
@MainActor final class SettingPreviews: ObservableObject {
    @Published var images: [String: CGImage] = [:]
    private var task: Task<Void, Never>?
    private let context = CIContext()

    struct Item: Identifiable { var id: String; var label: String; var help: String }
    static let looks: [Item] = [
        Item(id: "Natural", label: "Natural", help: "Sem tratamento de cor."),
        Item(id: "Ethos clássico", label: "Ethos clássico", help: "Mais quente e suave, com leve vinheta: tom de biblioteca e luz de vela."),
        Item(id: "Cinema", label: "Cinema", help: "Mais contraste e menos saturação, aspecto de filme."),
        Item(id: "Preto e branco", label: "Preto e branco", help: "Sem cor, com contraste: sóbrio e atemporal."),
        Item(id: "Vívido suave", label: "Vívido suave", help: "Cores um pouco mais vivas, sem exagero."),
    ]
    static let framings: [Item] = [
        Item(id: "fill", label: "Preencher", help: "Ocupa todo o quadro e acompanha o rosto (corta as laterais)."),
        Item(id: "fit", label: "Inteiro", help: "Mostra o vídeo inteiro, com o próprio vídeo desfocado ao fundo."),
    ]
    static let transitions: [Item] = [
        Item(id: "Corte seco", label: "Corte seco", help: "Sem transição."),
        Item(id: "Fade", label: "Fade preto", help: "Escurece e volta."),
        Item(id: "Flash", label: "Flash", help: "Clarão rápido."),
        Item(id: "Zoom", label: "Zoom", help: "Aproxima com rastro de movimento."),
        Item(id: "Desfoque", label: "Desfoque", help: "Desfoca e refoca."),
        Item(id: "Chicote", label: "Chicote", help: "Desliza de lado com rastro (whip pan)."),
        Item(id: "Chicote vertical", label: "Vertical", help: "Desliza para cima, como rolar o feed."),
        Item(id: "Girar", label: "Girar", help: "Gira e aproxima com desfoque."),
        Item(id: "Glitch", label: "Glitch", help: "Separação de cores e cortes digitais."),
        Item(id: "Pixelar", label: "Pixelar", help: "Vira pixels e volta."),
        Item(id: "Tremor", label: "Tremor", help: "Sacode na troca."),
        Item(id: "Luz", label: "Luz", help: "Clarão quente vazando (light leak)."),
    ]
    static let captionStyles: [Item] = [
        Item(id: "Ethos", label: "Ethos", help: "Serifada creme, palavra falada em dourado."),
        Item(id: "Contorno", label: "Contorno", help: "Branca com contorno preto, estilo Reels/TikTok."),
        Item(id: "Clássica", label: "Clássica", help: "Texto branco sobre caixa escura."),
        Item(id: "Destaque", label: "Destaque", help: "Texto verde-claro sobre caixa escura."),
        Item(id: "Hormozi", label: "Hormozi", help: "Maiúsculas pesadas, palavra falada amarela e maior: o estilo mais usado em Reels de conteúdo."),
        Item(id: "Bege", label: "Bege Ethos", help: "Frase inteira em serifa escura sobre uma faixa bege: o visual clássico dos Reels de estudo."),
        Item(id: "Caixa", label: "Caixa", help: "Palavra falada sobre uma caixa dourada, estilo CapCut."),
    ]

    /// Recalcula as miniaturas para o quadro do vídeo original em `sourceTime`.
    func refresh(source: URL?, sourceTime: Double, settings: EditSettings) {
        guard let source else { images = [:]; return }
        task?.cancel()
        let context = self.context
        task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 640)
            guard let frame = try? await generator.image(at: CMTime(seconds: max(0, sourceTime), preferredTimescale: 600)).image else { return }
            let base = CIImage(cgImage: frame)
            let size = settings.vertical ? CGSize(width: 108, height: 192) : CGSize(width: 192, height: 108)
            var plain = settings
            plain.captions = false; plain.question = ""; plain.progressBar = false; plain.watermark = false; plain.fadeInOut = false; plain.zoom = false
            plain.transitions = "Corte seco"
            let still = Timeline(cuts: [Cut(start: 0, end: 10)], captions: [])
            var result: [String: CGImage] = [:]
            func draw(_ key: String, _ s: EditSettings, timeline: Timeline = still, at t: Double = 1) {
                guard !Task.isCancelled else { return }
                let painter = FramePainter(size: size, timeline: timeline, settings: s, support: nil)
                result[key] = context.createCGImage(painter.frame(base, at: t), from: CGRect(origin: .zero, size: size))
            }
            for look in Self.looks { var s = plain; s.colorLook = look.id; draw("cor:" + look.id, s) }
            for f in Self.framings { var s = plain; s.fillFrame = f.id == "fill"; draw("enq:" + f.id, s) }
            // Transição: dois trechos e o quadro no meio do efeito.
            let twoCuts = Timeline(cuts: [Cut(start: 0, end: 3), Cut(start: 3.5, end: 6)], captions: [])
            for tr in Self.transitions { var s = plain; s.transitions = tr.id; s.transitionAllCuts = true; draw("tr:" + tr.id, s, timeline: twoCuts, at: 2.93) }
            // Legendas com uma frase de exemplo.
            let sample = Caption(id: 0, start: 0, end: 4, text: "A virtude nasce do hábito",
                                 words: [Word(text: "A", start: 0, end: 0.3), Word(text: "virtude", start: 0.3, end: 0.9), Word(text: "nasce", start: 0.9, end: 1.4), Word(text: "do", start: 1.4, end: 1.6), Word(text: "hábito", start: 1.6, end: 2.4)])
            let captioned = Timeline(cuts: [Cut(start: 0, end: 10)], captions: [sample])
            // Legendas: desenha maior e recorta a faixa da legenda, para dar para ler as letras.
            let big = settings.vertical ? CGSize(width: 360, height: 640) : CGSize(width: 640, height: 360)
            let centerY = big.height * (settings.captionPosition == "Centro" ? (settings.vertical ? 0.33 : 0.30) : (settings.vertical ? 0.19 : 0.11))
            let band = big.height * (settings.vertical ? 0.12 : 0.20)
            let side = big.width * (settings.vertical ? 0.04 : 0.17)
            let crop = CGRect(x: side, y: max(0, centerY - band / 2), width: big.width - side * 2, height: band)
            for style in Self.captionStyles {
                guard !Task.isCancelled else { return }
                var s = plain; s.captions = true; s.captionStyle = style.id
                let painter = FramePainter(size: big, timeline: captioned, settings: s, support: nil)
                result["leg:" + style.id] = context.createCGImage(painter.frame(base, at: 1.0), from: crop)
            }
            var v = plain; v.vignette = true; draw("efeito:vinheta", v)
            var p = plain; p.portraitBlur = true; draw("efeito:retrato", p)
            draw("efeito:nenhum", plain)
            guard !Task.isCancelled else { return }
            images = result
        }
    }
}

/// Grade de miniaturas clicáveis para escolher uma opção.
struct PreviewGrid: View {
    @ObservedObject var previews: SettingPreviews
    let prefix: String
    let items: [SettingPreviews.Item]
    let isSelected: (String) -> Bool
    let vertical: Bool
    var columns = 3
    /// Proporção das miniaturas (padrão: a do vídeo)
    var aspect: CGFloat? = nil
    let pick: (String) -> Void
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
                ForEach(items) { item in
                    Button { pick(item.id) } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 5).fill(Color.black)
                                if let image = previews.images[prefix + item.id] { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                                else { ProgressView().controlSize(.mini) }
                            }
                            .aspectRatio(aspect ?? (vertical ? 9 / 16 : 16 / 9), contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected(item.id) ? gold : Color.white.opacity(0.08), lineWidth: isSelected(item.id) ? 2 : 1))
                            Text(item.label).font(.system(size: 10)).foregroundStyle(isSelected(item.id) ? gold : .secondary).lineLimit(1).minimumScaleFactor(0.8)
                        }
                    }.buttonStyle(.plain).help(item.help)
                }
            }
            if let current = items.first(where: { isSelected($0.id) }) { Text(current.help).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Cartões de ritmo: mostram, num mini-gráfico, a densidade de cortes e de zooms e a amplitude do zoom progressivo.
struct RhythmCards: View {
    @Binding var style: String
    private let gold = Color(red: 0.83, green: 0.66, blue: 0.29)
    static let info: [(id: String, cuts: Int, zooms: Int, amplitude: Double, help: String)] = [
        ("Natural", 3, 2, 0.035, "Respiro e sobriedade: cortes só onde há erro ou repetição, zoom de ênfase a cada 20–40 s, movimento de câmera quase imperceptível. Ideal para aulas e reflexões no YouTube."),
        ("Dinâmico", 6, 4, 0.07, "Ritmo de canal de conteúdo: pausas mais curtas, zoom a cada 10–20 s e movimento suave mais visível. Bom para YouTube e Reels."),
        ("Intenso", 10, 7, 0.10, "Ritmo de Reels/TikTok: cortes secos frequentes, zooms a cada 6–12 s e mais movimento. Prende a atenção, mas cansa em vídeos longos."),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.info, id: \.id) { item in
                    Button { style = item.id } label: {
                        VStack(spacing: 4) {
                            Canvas { context, size in
                                // Faixa do vídeo com os cortes
                                let bar = CGRect(x: 0, y: size.height * 0.62, width: size.width, height: size.height * 0.22)
                                context.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(Color.white.opacity(0.12)))
                                for i in 1...item.cuts {
                                    let x = size.width * CGFloat(i) / CGFloat(item.cuts + 1)
                                    context.fill(Path(CGRect(x: x - 0.75, y: bar.minY - 2, width: 1.5, height: bar.height + 4)), with: .color(gold))
                                }
                                // Zoom progressivo (onda) e zooms de ênfase (picos)
                                var wave = Path()
                                for i in 0...40 {
                                    let x = size.width * CGFloat(i) / 40
                                    var z = (1 - cos(Double(i) / 40 * .pi * 4)) / 2 * item.amplitude * 3
                                    for k in 1...item.zooms where abs(Double(i) / 40 - Double(k) / Double(item.zooms + 1)) < 0.03 { z += 0.35 }
                                    let y = size.height * 0.5 - CGFloat(z) * size.height * 0.9
                                    if i == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
                                }
                                context.stroke(wave, with: .color(style == item.id ? gold : Color.white.opacity(0.55)), lineWidth: 1.3)
                            }.frame(height: 34)
                            Text(item.id).font(.system(size: 10)).foregroundStyle(style == item.id ? gold : .secondary)
                        }
                        .padding(6).frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(style == item.id ? gold : .clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).help(item.help)
                }
            }
            if let current = Self.info.first(where: { $0.id == style }) { Text(current.help).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("Traços dourados = cortes · linha = movimento do zoom").font(.system(size: 9)).foregroundStyle(.tertiary)
        }
    }
}
