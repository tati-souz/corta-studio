import AppKit
import CoreImage

/// Catálogo de estilos de texto na tela (títulos, citações, rodapés…) e suas animações de entrada.
enum TextStyles {
    struct Style: Identifiable { var id: String; var name: String; var sample: String }
    static let all: [Style] = [
        Style(id: "titulo", name: "Título clássico", sample: "Virtude e hábito"),
        Style(id: "destaque", name: "Cartão creme", sample: "O hábito forma o caráter"),
        Style(id: "citacao", name: "Citação", sample: "A virtude nasce do hábito"),
        Style(id: "cartao", name: "Cartão de citação (Reels)", sample: "Enxergo o mundo como ele é"),
        Style(id: "lista", name: "Item de lista (revelação progressiva)", sample: "Ouvir antes de responder"),
        Style(id: "versiculo", name: "Versículo", sample: "Tudo tem o seu tempo — Eclesiastes 3,1"),
        Style(id: "palavra", name: "Palavra-chave", sample: "Prudência"),
        Style(id: "capitulo", name: "Capítulo", sample: "Parte 1 · O hábito"),
        Style(id: "nome", name: "Nome (rodapé)", sample: "Seu nome | Projeto Ethos"),
        Style(id: "manuscrito", name: "Manuscrito", sample: "Coragem"),
        Style(id: "minimal", name: "Minimalista", sample: "Formação do caráter"),
        Style(id: "caixa", name: "Caixa escura", sample: "3 hábitos que formam"),
        Style(id: "impacto", name: "Impacto", sample: "Pare de adiar"),
        Style(id: "pergunta", name: "Pergunta", sample: "Por que a virtude nasce do hábito?"),
    ]
    static let animations: [(id: String, name: String)] = [("fade", "Surgir"), ("subir", "Subir"), ("escala", "Aproximar"), ("pular", "Pular"), ("deslizar", "Deslizar de lado"),
                                                           ("maquina", "Máquina de escrever"), ("revelar", "Revelar")]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? "Texto" }

    static func font(_ names: [String], _ size: CGFloat, fallback: NSFont.Weight = .bold) -> NSFont {
        for n in names { if let f = NSFont(name: n, size: size) { return f } }
        return .systemFont(ofSize: size, weight: fallback)
    }
}

extension FramePainter {
    /// Desenha um efeito de texto. `visible` limita os caracteres visíveis (máquina de escrever) sem mudar o layout.
    /// Itens da mesma lista (mesmo grupo em `asset`), em ordem; os itens até este aparecem, o atual em destaque.
    func listItems(for effect: Effect) -> (items: [String], index: Int, total: Int) {
        let group = effects.map(\.effect).filter { $0.kind == .texto && $0.style == "lista" && $0.asset == effect.asset }
        var unique: [Effect] = []
        for e in group.sorted(by: { $0.start < $1.start }) where !unique.contains(where: { $0.id == e.id }) { unique.append(e) }
        if !unique.contains(where: { $0.id == effect.id }) { unique.append(effect) }
        let index = unique.firstIndex { $0.id == effect.id } ?? 0
        return (unique.prefix(index + 1).map(\.text), index, unique.count)
    }
    func styledText(_ effect: Effect, visible: Int? = nil) -> (image: CIImage, box: CGRect) {
        let listKey = effect.style == "lista" ? listItems(for: effect).items.joined(separator: "|") + "|\(listItems(for: effect).total)|\(effect.border)" : ""
        let key = "t|\(effect.style)|\(effect.position)|\(effect.text)|\(visible ?? -1)|\(listKey)" as NSString
        if let cached = styledCache.object(forKey: key) { return (cached.image, cached.box) }
        let unit = size.width * (settings.vertical ? 0.01 : 0.0058)
        let v = settings.vertical
        let lowY = size.height * (v ? (settings.captions && settings.captionPosition == "Inferior" ? 0.36 : 0.13) : 0.32)
        // Área livre do rosto para estilos centralizados: no horizontal o rosto ocupa o centro; no vertical, a metade de cima.
        let freeY = size.height * (v ? (settings.captions && settings.captionPosition == "Centro" ? 0.16 : 0.33) : 0.28)
        let chosen: CGFloat? = ["alto": size.height * (v ? 0.86 : 0.82), "centro": size.height * 0.5, "baixo": size.height * (v ? 0.16 : 0.2)][effect.position]
        let gold = FramePainter.gold, cream = FramePainter.cream, ink = FramePainter.ink
        let serif = { (s: CGFloat) in TextStyles.font(["Georgia-Bold"], s) }
        func para(_ alignment: NSTextAlignment, spacing: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle(); p.alignment = alignment; p.lineSpacing = spacing; return p
        }
        func attributed(_ text: String, _ attrs: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
            let s = NSMutableAttributedString(string: text, attributes: attrs)
            if let visible, visible < s.length { s.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: max(0, visible), length: s.length - max(0, visible))) }
            return s
        }
        var outline: NSAttributedString?
        let result: (CIImage, CGRect)
        switch effect.style {
        case "titulo":
            let s = attributed(effect.text, [.font: serif(unit * 8), .foregroundColor: cream, .paragraphStyle: para(.center)])
            result = drawText(s, width: size.width * 0.82, centerY: chosen ?? freeY, box: CGColor(red: 0.05, green: 0.045, blue: 0.04, alpha: 0.55), padding: unit * 5, shadow: true, accent: true, underline: false)
        case "citacao":
            let s = attributed("“" + effect.text + "”", [.font: TextStyles.font(["Georgia-BoldItalic", "Georgia-Italic"], unit * 6.2), .foregroundColor: cream, .paragraphStyle: para(.center, spacing: unit)])
            result = drawText(s, width: size.width * 0.80, centerY: chosen ?? freeY, box: nil, padding: unit * 3, shadow: true, underline: false)
        case "cartao":
            // Cartão claro no alto com a frase em itálico serifado, como nos Reels de estudo.
            let s = attributed("“" + effect.text + "”", [.font: TextStyles.font(["Baskerville-SemiBoldItalic", "Baskerville-Italic", "Georgia-Italic"], unit * 6.6), .foregroundColor: ink, .paragraphStyle: para(.center, spacing: unit * 0.3)])
            result = drawText(s, width: size.width * (v ? 0.90 : 0.56), centerY: chosen ?? size.height * (v ? 0.80 : 0.80), box: NSColor(red: 0.97, green: 0.95, blue: 0.91, alpha: 0.90).cgColor, padding: unit * 3.4, shadow: true, underline: false)
        case "lista":
            // Lista numerada: os itens já citados ficam visíveis (mais apagados) e o atual em destaque; contador opcional.
            let info = listItems(for: effect)
            let s = NSMutableAttributedString()
            if effect.border && info.total > 1 {
                s.append(attributed("\(info.index + 1) de \(info.total)\n", [.font: NSFont.systemFont(ofSize: unit * 3.4, weight: .semibold), .foregroundColor: gold, .kern: unit * 0.3, .paragraphStyle: para(.left, spacing: unit * 0.8)]))
            }
            for (i, item) in info.items.enumerated() {
                let current = i == info.index
                let line = (i > 0 ? "\n" : "") + "\(i + 1)  " + item
                let attrs: [NSAttributedString.Key: Any] = [.font: current ? serif(unit * 6.0) : TextStyles.font(["Georgia"], unit * 4.8),
                                                            .foregroundColor: current ? cream : cream.withAlphaComponent(0.62), .paragraphStyle: para(.left, spacing: unit * 1.1)]
                let piece = attributed(line, attrs)
                // O número em dourado
                let numberStart = (i > 0 ? 1 : 0)
                piece.addAttribute(.foregroundColor, value: current ? gold : gold.withAlphaComponent(0.6), range: NSRange(location: numberStart, length: "\(i + 1)".count))
                s.append(piece)
            }
            result = drawText(s, width: size.width * (v ? 0.88 : 0.50), centerY: chosen ?? size.height * (v ? 0.79 : 0.62), box: CGColor(red: 0.06, green: 0.05, blue: 0.045, alpha: 0.78),
                              padding: unit * 3, shadow: true, accent: true, leftAligned: true, underline: false)
        case "versiculo":
            let parts = effect.text.components(separatedBy: " — ")
            let s = attributed(parts[0], [.font: TextStyles.font(["Baskerville-SemiBold", "Georgia"], unit * 5.4), .foregroundColor: cream, .paragraphStyle: para(.center, spacing: unit * 0.8)])
            if parts.count > 1 { s.append(attributed("\n" + parts.dropFirst().joined(separator: " — ").uppercased(), [.font: NSFont.systemFont(ofSize: unit * 2.8, weight: .semibold), .foregroundColor: gold, .kern: unit * 0.4, .paragraphStyle: para(.center)])) }
            result = drawText(s, width: size.width * 0.80, centerY: chosen ?? freeY, box: CGColor(red: 0.06, green: 0.05, blue: 0.045, alpha: 0.72), padding: unit * 4.5, shadow: true, accent: true, underline: false)
        case "palavra":
            let s = attributed(effect.text.uppercased(), [.font: TextStyles.font(["BodoniSvtyTwoITCTT-Bold", "Didot-Bold", "Georgia-Bold"], unit * 12), .foregroundColor: gold, .kern: unit * 0.6, .paragraphStyle: para(.center)])
            result = drawText(s, width: size.width * 0.9, centerY: chosen ?? freeY, box: nil, padding: unit * 3, shadow: true, underline: false)
        case "capitulo":
            let s = attributed(effect.text.uppercased(), [.font: NSFont.systemFont(ofSize: unit * 3.4, weight: .semibold), .foregroundColor: cream, .kern: unit * 0.5, .paragraphStyle: para(.left)])
            result = drawText(s, width: size.width * 0.55, centerY: chosen ?? size.height * (v ? 0.935 : 0.91), box: CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 0.85), padding: unit * 2.2, shadow: false, accent: true, leftAligned: true, underline: false)
        case "nome":
            let parts = effect.text.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            let s = attributed(parts[0], [.font: serif(unit * 4.4), .foregroundColor: cream, .paragraphStyle: para(.left)])
            if parts.count > 1 { s.append(attributed("\n" + parts[1].uppercased(), [.font: NSFont.systemFont(ofSize: unit * 2.4, weight: .medium), .foregroundColor: gold, .kern: unit * 0.4, .paragraphStyle: para(.left)])) }
            result = drawText(s, width: size.width * 0.62, centerY: chosen ?? size.height * (v ? 0.30 : 0.24), box: CGColor(red: 0.07, green: 0.06, blue: 0.055, alpha: 0.86), padding: unit * 2.6, shadow: true, accent: true, leftAligned: true, underline: false)
        case "manuscrito":
            let s = attributed(effect.text, [.font: TextStyles.font(["SnellRoundhand-Bold", "SnellRoundhand", "Zapfino"], unit * 10), .foregroundColor: cream, .paragraphStyle: para(.center)])
            result = drawText(s, width: size.width * 0.86, centerY: chosen ?? freeY, box: nil, padding: unit * 3, shadow: true, underline: false)
        case "minimal":
            let s = attributed(effect.text.uppercased(), [.font: NSFont.systemFont(ofSize: unit * 3.6, weight: .medium), .foregroundColor: NSColor.white, .kern: unit * 0.9, .paragraphStyle: para(.center)])
            result = drawText(s, width: size.width * 0.8, centerY: chosen ?? lowY, box: nil, padding: unit * 2.5, shadow: true, underline: true)
        case "caixa":
            let s = attributed(effect.text, [.font: NSFont.systemFont(ofSize: unit * 4.6, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: para(.center)])
            result = drawText(s, width: size.width * 0.8, centerY: chosen ?? lowY, box: CGColor(red: 0, green: 0, blue: 0, alpha: 0.9), padding: unit * 2.4, shadow: false, underline: false)
        case "impacto":
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: unit * 7.5, weight: .black), .foregroundColor: NSColor.white, .paragraphStyle: para(.center)]
            let s = attributed(effect.text.uppercased(), attrs)
            let o = NSMutableAttributedString(attributedString: s)
            o.addAttributes([.strokeColor: NSColor.black, .strokeWidth: 16, .foregroundColor: NSColor.clear], range: NSRange(location: 0, length: o.length))
            if let visible, visible < o.length { o.addAttribute(.strokeColor, value: NSColor.clear, range: NSRange(location: visible, length: o.length - visible)) }
            outline = o
            result = drawText(s, width: size.width * 0.88, centerY: chosen ?? freeY, box: nil, padding: unit * 2, shadow: true, outline: outline, underline: false)
        case "pergunta":
            let s = attributed(effect.text, [.font: serif(unit * 5), .foregroundColor: ink, .paragraphStyle: para(.center)])
            result = drawText(s, width: size.width * 0.80, centerY: chosen ?? size.height * (v ? 0.85 : 0.78), box: cream.withAlphaComponent(0.96).cgColor, padding: unit * 3.5, shadow: true, accent: true, underline: false)
        default: // "destaque"
            let s = attributed(effect.text, [.font: serif(unit * 5), .foregroundColor: ink, .paragraphStyle: para(.center)])
            result = drawText(s, width: size.width * 0.78, centerY: chosen ?? lowY, box: cream.withAlphaComponent(0.95).cgColor, padding: unit * 3, shadow: true, accent: true, underline: false)
        }
        styledCache.setObject(StyledText(image: result.0, box: result.1), forKey: key)
        return result
    }

    /// Texto com a animação de entrada aplicada no instante `time`.
    func animatedText(_ placed: PlacedEffect, at time: Double) -> CIImage {
        let effect = placed.effect
        let since = time - placed.start, duration = placed.end - placed.start
        let k = max(0, min(1, since / min(0.45, duration / 3)))
        let ease = k * k * (3 - 2 * k)
        var visible: Int?
        if effect.animation == "maquina" {
            let span = min(1.4, duration * 0.45)
            visible = Int((Double(effect.text.count + 2) * min(1, since / span)).rounded(.down))
        }
        let (image, box) = styledText(effect, visible: visible)
        var out = image
        switch effect.animation {
        case "subir":
            out = out.transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(1 - ease) * size.height * 0.035))
        case "escala":
            let s = CGFloat(0.86 + 0.14 * ease)
            out = out.transformed(by: CGAffineTransform(translationX: -box.midX, y: -box.midY).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: box.midX, y: box.midY)))
        case "pular":
            // Entra maior e "quica" até o tamanho final (easeOutBack).
            let c: Double = 2.2, x = k - 1
            let s = CGFloat(max(0.2, 1 + c * x * x * x + (c - 1) * x * x)) * CGFloat(0.6 + 0.4 * min(1, k * 1.6))
            out = out.transformed(by: CGAffineTransform(translationX: -box.midX, y: -box.midY).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: box.midX, y: box.midY)))
        case "deslizar":
            out = out.transformed(by: CGAffineTransform(translationX: -CGFloat(1 - ease) * size.width * 0.5, y: 0))
        case "revelar":
            out = out.cropped(to: CGRect(x: 0, y: 0, width: box.minX + box.width * CGFloat(ease), height: size.height))
        default: break
        }
        let exit = max(0, min(1, (placed.end - time) / min(0.3, duration / 3)))
        let alpha = effect.animation == "maquina" || effect.animation == "revelar" ? exit : min(ease, exit)
        return faded(out, alpha)
    }
}
