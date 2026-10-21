import SwiftUI

/// Trecho da edição em que você fala olhando para fora da câmera (para cobrir com imagem).
struct CoverSegment: Identifiable {
    let id = UUID()
    var outStart: Double, outEnd: Double
    var srcStart: Double, srcEnd: Double
    var narration: String
}

extension Studio {
    /// Trechos laranja que ficaram na edição atual (fala olhando para fora), já descontando os que têm imagem por cima.
    func lookAwaySegments(minimum: Double = 1.0) -> [CoverSegment] {
        guard let gaze, let timeline = playhead.timeline ?? (try? makeTimeline(snapshot())) else { return [] }
        var pieces: [(Double, Double)] = []
        for away in gaze.away { pieces += timeline.outputRanges(start: away.start, end: away.end) }
        pieces.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for p in pieces { if let last = merged.last, p.0 - last.1 < 0.6 { merged[merged.count - 1].1 = max(last.1, p.1) } else { merged.append(p) } }
        let covered = effects.filter { $0.kind == .imagem }.flatMap { timeline.outputRanges(start: $0.start, end: $0.end) }
        return merged.compactMap { p -> CoverSegment? in
            let a = max(0, p.0 - 0.2), b = min(timeline.duration, p.1 + 0.2)
            guard b - a >= minimum else { return nil }
            let overlap = covered.reduce(0.0) { $0 + max(0, min(b, $1.1) - max(a, $1.0)) }
            guard overlap < (b - a) * 0.5 else { return nil }
            let sa = timeline.sourceTime(a), sb = timeline.sourceTime(max(a, b - 0.001)) + 0.001
            let text = timeline.captions.filter { $0.end > a && $0.start < b }.map(\.text).joined(separator: " ")
            return CoverSegment(outStart: a, outEnd: b, srcStart: sa, srcEnd: sb, narration: text.isEmpty ? "trecho sem fala" : text)
        }
    }

}
