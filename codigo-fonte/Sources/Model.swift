import Foundation
import CoreGraphics

struct StudioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Word: Codable, Equatable {
    var text: String
    var start: Double
    var end: Double
}

struct Caption: Codable, Identifiable, Equatable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    var included = true
    /// Tempos por palavra vindos da transcrição. Ausente em SRT importado; nesse caso os tempos são estimados.
    var words: [Word]? = nil
    /// Índices (no texto atual) de palavras removidas da edição, como vícios de linguagem ("hum", "tipo", "né").
    var removedWords: [Int]? = nil
    /// Na legenda remapeada para a edição: o ID da legenda original.
    var sourceID: Int? = nil
    /// Legenda oculta: a fala continua no vídeo, mas o texto não aparece nem vai para o SRT.
    var hidden: Bool? = nil

    static let obviousFillers: Set<String> = ["hum", "humm", "hmm", "hm", "hã", "ãh", "ahn", "ãã", "éé", "ééé", "eeh", "ehh", "uhm", "uh", "hãã"]
    /// Vícios inequívocos, detectados sem IA.
    var obviousFillerIndexes: [Int] {
        text.split(whereSeparator: { $0.isWhitespace }).enumerated().compactMap { i, token in
            Self.obviousFillers.contains(token.lowercased().trimmingCharacters(in: .punctuationCharacters)) ? i : nil
        }
    }
    var keptText: String {
        let removed = Set(removedWords ?? [])
        return text.split(whereSeparator: { $0.isWhitespace }).enumerated().filter { !removed.contains($0.offset) }.map { String($0.element) }.joined(separator: " ")
    }

    /// Palavras do texto atual com tempos: reais quando batem com a transcrição, estimados pela extensão quando o texto foi editado.
    func timedWords() -> [Word] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return [] }
        if let words, words.count == tokens.count { return zip(tokens, words).map { Word(text: $0, start: $1.start, end: $1.end) } }
        let total = Double(tokens.reduce(0) { $0 + $1.count + 1 })
        var cursor = start
        return tokens.map { token in
            let length = (end - start) * Double(token.count + 1) / total
            defer { cursor += length }
            return Word(text: token, start: cursor, end: cursor + length)
        }
    }
}

/// Efeito ancorado no tempo do vídeo ORIGINAL; assim continua no lugar certo quando os cortes mudam.
struct Effect: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case zoom, texto, imagem, video, fx }
    var id = UUID()
    var kind: Kind
    var start: Double
    var end: Double
    var text: String = ""
    /// texto: titulo | destaque | capitulo · imagem: tela-cheia | dividida
    var style: String = ""
    /// zoom: intensidade (1.08 a 1.35)
    var amount: Double = 1.15
    /// imagem: nome do arquivo na Biblioteca/Imagens
    var asset: String = ""
    /// texto: animação de entrada (fade, subir, escala, maquina, revelar)
    var animation: String = "fade"
    /// texto: posição na tela ("" automática, alto, centro, baixo)
    var position: String = ""
    /// Layouts com o apresentador (janelinha / fundo virtual): tamanho relativo (0,4–1,6) e borda.
    var scale: Double = 1
    var border = true
    /// zoom: duração da transição em segundos (0 = ao longo de todo o trecho)
    var speed: Double = 0.35

    static let zoomStyles: [(id: String, name: String)] = [("suave", "Aproximar e voltar"), ("zoom-in", "Zoom in"), ("zoom-out", "Zoom out"), ("corte", "Corte com aproximação"), ("batida", "Batida")]
    /// Efeitos de vídeo (estilo CapCut), aplicados à imagem no trecho.
    static let fxStyles: [(id: String, name: String, help: String)] = [
        ("tremor", "Tremor de câmera", "Sacode a imagem: impacto, surpresa, ênfase forte."),
        ("glitch", "Glitch", "Separação de cores e cortes digitais: virada, ironia, algo 'quebrando'."),
        ("flash", "Flash", "Clarão rápido no início do trecho: marca uma batida."),
        ("pulso", "Pulso", "Zoom pulsando no ritmo (2 batidas por segundo)."),
        ("zoom3d", "Zoom 3D", "Você se aproxima e o fundo quase não mexe: efeito de profundidade."),
        ("corpop", "Cor só em você", "Fundo em preto e branco, você colorida: foco total na fala."),
        ("filme", "Filme antigo", "Grão, tom quente e cintilação: memória, história, nostalgia."),
        ("brilho", "Brilho de luz", "Feixe de luz quente atravessando a imagem: esperança, revelação."),
        ("foco", "Desfoque → foco", "Começa desfocado e entra em foco: abertura, despertar."),
    ]
    static func fxName(_ id: String) -> String { fxStyles.first { $0.id == id }?.name ?? "Efeito" }
    /// Layouts para imagens e vídeos de apoio.
    static let layouts: [(id: String, name: String)] = [("tela-cheia", "Tela cheia"), ("degrade", "Degradê: imagem em cima, você embaixo"), ("dividida", "Dividida: você em cima"), ("dividida-invertida", "Dividida: apoio em cima"),
                                                         ("pip", "Você na janelinha redonda"), ("pip-retangular", "Você na janelinha retangular"),
                                                         ("fundo", "Apresentador recortado (fundo trocado)"), ("so-apoio", "Só a imagem (sem apresentador)")]
    static let presenterPositions: [(id: String, name: String)] = [("", "Automática"), ("sup-dir", "Alto à direita"), ("sup-esq", "Alto à esquerda"), ("inf-dir", "Embaixo à direita"),
                                                                   ("inf-esq", "Embaixo à esquerda"), ("centro", "Centro"), ("esquerda", "Esquerda"), ("direita", "Direita")]
    static func zoomName(_ id: String) -> String { zoomStyles.first { $0.id == id }?.name ?? "Aproximar e voltar" }
    static func defaultSpeed(_ zoomStyle: String) -> Double { ["zoom-in": 0, "zoom-out": 0, "corte": 0, "batida": 0.35][zoomStyle] ?? 0.35 }

    init(id: UUID = UUID(), kind: Kind, start: Double, end: Double, text: String = "", style: String = "", amount: Double = 1.15, asset: String = "", animation: String = "fade", position: String = "", speed: Double = 0.35) {
        self.id = id; self.kind = kind; self.start = start; self.end = end; self.text = text; self.style = style; self.amount = amount; self.asset = asset; self.animation = animation; self.position = position; self.speed = speed
    }

    /// Fator de zoom deste efeito no instante `t` (segundos desde o início do efeito), para um trecho de `d` segundos.
    func zoomFactor(at t: Double, duration d: Double) -> Double {
        let a = min(1.6, max(1, amount))
        func ease(_ x: Double) -> Double { let k = max(0, min(1, x)); return k * k * (3 - 2 * k) }
        let ramp = speed <= 0.001 ? d : min(speed, d)
        switch style {
        case "corte": return a
        case "zoom-in": return 1 + (a - 1) * ease(ramp <= 0.001 ? 1 : t / ramp)
        case "zoom-out": return a - (a - 1) * ease(ramp <= 0.001 ? 1 : t / ramp)
        case "batida":
            let up = min(0.12, d / 3), back = max(0.05, min(max(speed, 0.05), d - up))
            return 1 + (a - 1) * ease(t < up ? t / up : 1 - (t - up) / back)
        default:
            let r = min(speed <= 0.001 ? d / 2 : speed, d / 2)
            return 1 + (a - 1) * ease(r <= 0.001 ? 1 : min(t / r, (d - t) / r))
        }
    }
    /// Lê efeitos de versões anteriores, que não tinham todos os campos.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(Kind.self, forKey: .kind)
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        style = try c.decodeIfPresent(String.self, forKey: .style) ?? ""
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 1.15
        asset = try c.decodeIfPresent(String.self, forKey: .asset) ?? ""
        animation = try c.decodeIfPresent(String.self, forKey: .animation) ?? "fade"
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 0.35
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        border = try c.decodeIfPresent(Bool.self, forKey: .border) ?? true
    }

    var label: String {
        switch kind {
        case .zoom: return "\(Effect.zoomName(style)) \(Int((amount - 1) * 100))%"
        case .texto: return "\(TextStyles.name(style)): \(text)"
        case .imagem: return "Imagem \(asset)"
        case .video: return "Vídeo \(asset)"
        case .fx: return Effect.fxName(style)
        }
    }
}

/// Transição escolhida para uma junção de cortes (identificada pelo início do trecho seguinte, no tempo do original).
struct TransitionMark: Codable, Equatable {
    var sourceTime: Double
    var type: String
    var duration: Double = 0.5

    static let types: [(id: String, name: String, help: String)] = [
        ("corte", "Corte seco", "Sem transição: a forma mais limpa e mais usada."),
        ("fade", "Fade preto", "Escurece e volta. Sóbrio, bom para mudança de assunto."),
        ("flash", "Flash", "Clarão rápido. Dá energia em Reels e Shorts."),
        ("zoom", "Zoom", "Aproxima com desfoque de movimento e abre no próximo trecho."),
        ("desfoque", "Desfoque", "Desfoca e refoca. Suave e elegante."),
        ("chicote", "Chicote", "Desliza de lado com rastro de movimento (whip pan)."),
        ("vertical", "Chicote vertical", "Desliza para cima com rastro, como rolar o feed."),
        ("girar", "Girar", "Gira e aproxima com desfoque: energia de Reels."),
        ("glitch", "Glitch", "Separação de cores e cortes digitais na troca."),
        ("pixelar", "Pixelar", "A imagem vira pixels e volta."),
        ("tremor", "Tremor", "Sacode na troca, como um impacto."),
        ("luz", "Luz", "Clarão quente vazando pela imagem (light leak)."),
        ("rebobinar", "Rebobinar", "Efeito de fita voltando (◀◀): usado na volta do gancho em vídeo para o começo."),
    ]
    static func name(_ id: String) -> String { types.first { $0.id == id }?.name ?? "Corte seco" }
    /// Nome do ajuste global (como aparece no painel) para o identificador interno.
    static func id(forSetting name: String) -> String {
        ["Corte seco": "corte", "Fade": "fade", "Flash": "flash", "Zoom": "zoom", "Desfoque": "desfoque", "Chicote": "chicote",
         "Chicote vertical": "vertical", "Girar": "girar", "Glitch": "glitch", "Pixelar": "pixelar", "Tremor": "tremor", "Luz": "luz"][name] ?? "corte"
    }
}

/// Estado completo de uma edição: usado no desfazer/refazer, em cada corte e no projeto salvo.
/// Gancho em vídeo (cold open): um trecho forte do meio aparece no começo; depois o vídeo segue do início.
struct VideoHook: Codable, Equatable {
    var start: Double          // tempo do vídeo original
    var end: Double
    var transition = "rebobinar"
    var reason = ""
    /// Converte legendas + índices de palavra em tempos do original (com uma pequena folga), limitando a 2–12 s.
    static func range(captions: [Caption], startID: Int, startWord: Int, endID: Int, endWord: Int) -> (start: Double, end: Double)? {
        guard let a = captions.first(where: { $0.id == startID }), let b = captions.first(where: { $0.id == endID }) else { return nil }
        let wa = a.timedWords(), wb = b.timedWords()
        let start = wa.isEmpty ? a.start : wa[min(max(0, startWord), wa.count - 1)].start
        let end = wb.isEmpty ? b.end : (endWord < 0 ? wb.last!.end : wb[min(endWord, wb.count - 1)].end)
        guard end > start + 1 else { return nil }
        return (max(0, start - 0.08), min(start + 12, end + 0.15))
    }
    static func text(captions: [Caption], start: Double, end: Double) -> String {
        captions.flatMap { $0.timedWords() }.filter { $0.start >= start - 0.05 && $0.end <= end + 0.2 }.map(\.text).joined(separator: " ")
    }
    static let transitions: [(id: String, name: String)] = [("rebobinar", "Rebobinar (volta no tempo)"), ("flash", "Flash"), ("fade", "Mergulho no preto"),
                                                             ("chicote", "Chicote"), ("glitch", "Glitch"), ("corte", "Corte seco")]
}

struct EditState: Codable, Equatable {
    var captions: [Caption]
    var settings: EditSettings
    var effects: [Effect]
    var exclusions: [Cut]
    var transitionMarks: [TransitionMark] = []
    var splits: [Double] = []
    var videoHook: VideoHook? = nil
    init(captions: [Caption], settings: EditSettings, effects: [Effect], exclusions: [Cut], transitionMarks: [TransitionMark] = [], splits: [Double] = [], videoHook: VideoHook? = nil) {
        self.captions = captions; self.settings = settings; self.effects = effects; self.exclusions = exclusions; self.transitionMarks = transitionMarks; self.splits = splits; self.videoHook = videoHook
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        captions = try c.decode([Caption].self, forKey: .captions)
        // Ajustes de versões anteriores: completa com os padrões o que faltar (em vez de recusar o projeto).
        if let raw = try c.decodeIfPresent(JSONValue.self, forKey: .settings), case .object = raw, let dict = raw.any as? [String: Any] {
            settings = (try? EditSettings().merging(dict)) ?? EditSettings()
        } else { settings = EditSettings() }
        effects = try c.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        exclusions = try c.decodeIfPresent([Cut].self, forKey: .exclusions) ?? []
        transitionMarks = try c.decodeIfPresent([TransitionMark].self, forKey: .transitionMarks) ?? []
        splits = try c.decodeIfPresent([Double].self, forKey: .splits) ?? []
        videoHook = try c.decodeIfPresent(VideoHook.self, forKey: .videoHook)
    }
}

/// Corte curto sugerido pela IA a partir de um vídeo longo.
struct ClipSuggestion: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var hook: String
    var reason: String
    var startID: Int
    var endID: Int
    /// Edições feitas neste corte (nil = ainda como a IA sugeriu).
    var edit: EditState? = nil
    /// Nota de potencial (0–99) e o detalhamento: gancho, fluxo, valor e atualidade (0–25 cada).
    var score = 0
    var scores: [String: Int] = [:]
    /// Texto do post, hashtags e tema, gerados com o corte.
    var caption = ""
    var hashtags: [String] = []
    var topic = ""
    var favorite = false
    /// Modelo visual aplicado ao corte ("" = o do vídeo completo) e se o gancho aparece escrito no início.
    var template = ""
    var showHook = true
    /// Gancho em vídeo do corte (um momento forte dele que abre o Reels) e se está ligado.
    var videoHook: VideoHook? = nil
    var useVideoHook = true

    static let scoreParts: [(id: String, name: String, help: String)] = [
        ("gancho", "Gancho", "Os primeiros segundos prendem a atenção?"),
        ("fluxo", "Fluxo", "A ideia se sustenta sozinha, com começo, meio e fim?"),
        ("valor", "Valor", "Quem assiste aprende ou leva algo?"),
        ("atualidade", "Atualidade", "O tema conversa com o que as pessoas buscam hoje?"),
    ]
    static let templates: [(id: String, name: String)] = [("", "Igual ao vídeo completo"), ("reels-ethos", "Reels Ethos (legenda bege)"), ("viral", "Viral (Hormozi, palavra a palavra)"),
                                                           ("classico", "Ethos clássico (creme e dourado)"), ("limpo", "Limpo (sem legenda)")]

    init(title: String, hook: String, reason: String, startID: Int, endID: Int) {
        self.title = title; self.hook = hook; self.reason = reason; self.startID = startID; self.endID = endID
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decode(String.self, forKey: .title); hook = try c.decode(String.self, forKey: .hook); reason = try c.decode(String.self, forKey: .reason)
        startID = try c.decode(Int.self, forKey: .startID); endID = try c.decode(Int.self, forKey: .endID)
        edit = try c.decodeIfPresent(EditState.self, forKey: .edit)
        score = try c.decodeIfPresent(Int.self, forKey: .score) ?? 0
        scores = try c.decodeIfPresent([String: Int].self, forKey: .scores) ?? [:]
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        hashtags = try c.decodeIfPresent([String].self, forKey: .hashtags) ?? []
        topic = try c.decodeIfPresent(String.self, forKey: .topic) ?? ""
        favorite = try c.decodeIfPresent(Bool.self, forKey: .favorite) ?? false
        template = try c.decodeIfPresent(String.self, forKey: .template) ?? ""
        showHook = try c.decodeIfPresent(Bool.self, forKey: .showHook) ?? true
        videoHook = try c.decodeIfPresent(VideoHook.self, forKey: .videoHook)
        useVideoHook = try c.decodeIfPresent(Bool.self, forKey: .useVideoHook) ?? true
    }
}

/// O que a IA deve procurar ao gerar cortes (como num gerador de cortes: duração, trecho, tema, estilo).
struct ClipFinderOptions: Codable, Equatable {
    var count = 6
    var length = "auto"
    var rangeStart = 0.0
    var rangeEnd = 0.0          // 0 = até o fim
    var prompt = ""
    var genre = "Aula ou reflexão"
    var template = "reels-ethos"
    var showHook = true
    var videoHook = true

    static let lengths: [(id: String, name: String, seconds: ClosedRange<Double>)] = [
        ("auto", "Automático (o que a ideia pedir)", 15...90), ("curto", "Menos de 30 s", 12...30), ("medio", "30 a 60 s", 30...60),
        ("longo", "60 a 90 s", 60...90), ("extra", "90 s a 3 min", 90...180)]
    static let genres = ["Aula ou reflexão", "Leitura comentada", "Conversa ou entrevista", "Pregação ou meditação", "Comentário de notícia", "Dica prática"]
}

struct ChatMessage: Codable, Equatable, Identifiable {
    var id = UUID()
    var fromUser: Bool
    var text: String
}

struct EditSettings: Codable, Equatable {
    static let platforms = ["YouTube", "YouTube Shorts", "Instagram Reels", "TikTok"]
    var platform = "YouTube"
    var vertical = false
    var shortVideo = false
    var targetSeconds = 60.0
    var style = "Natural"
    var captions = true
    var zoom = true
    /// Zoom progressivo: segundos de um ciclo de aproximar e voltar (menor = mais rápido)
    var zoomCycle = 16.0
    var fillFrame = false
    var horizontalFocus = 0.5
    var question = ""
    var captionStyle = "Clássica"
    var trimPauses = false
    var splitScreen = false
    var fpsLimit = 30
    // Decisões da IA que podem ser ligadas ou desligadas
    var smartCuts = true
    var emphasisZoom = true
    var textHighlights = true
    var brollImages = false
    var autoHook = true
    // Legendas
    var captionMode = "Dinâmica"
    var captionPosition = "Inferior"
    // Visual
    var colorLook = "Natural"
    var vignette = false
    var transitions = "Corte seco"
    /// Aplica a transição global em todas as junções (e não só nas mudanças de assunto)
    var transitionAllCuts = false
    // Modo roteiro (gravação lendo roteiro, com erros e recomeços)
    var scriptMode = false
    var cutLookAway = true
    var tightPauses = false
    var fadeInOut = true
    var progressBar = false
    var watermark = false
    var portraitBlur = false
    var eyeContact = false
    var eyeContactStrength = 0.6
    // Áudio
    var studioVoice = false
    var voiceIsolation = 0.8
    var removeFillers = true
    var soundEffects = false
    // Personalização das legendas e volume da voz
    var captionFont = ""        // "" = a fonte do estilo
    var captionColor = ""       // "" = a cor do estilo
    var captionScale = 1.0
    var voiceVolume = 1.0
    /// Enquadramento vertical de vídeo horizontal: 1 = recorte justo; menor = mais aberto, com fundo desfocado em cima e embaixo.
    var frameScale = 1.0
    var musicFile = ""
    var musicVolume = 0.12
    var ducking = true

    static let captionStyles = ["Ethos", "Bege", "Contorno", "Hormozi", "Caixa", "Clássica", "Destaque"]
    static let captionFonts: [(id: String, name: String)] = [("", "Do estilo"), ("Baskerville-SemiBold", "Baskerville"), ("Georgia-Bold", "Georgia"), ("Didot-Bold", "Didot"),
                                                              ("AvenirNext-Bold", "Avenir"), ("HelveticaNeue-Bold", "Helvetica"), ("Futura-Bold", "Futura")]
    static let captionColors: [(id: String, name: String, color: (Double, Double, Double))] = [("", "Do estilo", (1, 1, 1)), ("branco", "Branco", (1, 1, 1)), ("creme", "Creme", (0.98, 0.95, 0.88)),
                                                                                              ("amarelo", "Amarelo", (1, 0.86, 0.12)), ("dourado", "Dourado", (0.83, 0.66, 0.29)), ("preto", "Preto", (0.08, 0.07, 0.06))]
    static let colorLooks = ["Natural", "Ethos clássico", "Cinema", "Preto e branco", "Vívido suave"]

    /// Ajustes iniciais recomendados para cada plataforma.
    mutating func applyPlatform(_ name: String) {
        platform = name
        vertical = name != "YouTube"
        if vertical {
            captionMode = "Dinâmica"; captionStyle = "Contorno"; captionPosition = "Centro"; fillFrame = true
            progressBar = false; autoHook = true; trimPauses = true; if style == "Natural" { style = "Dinâmico" }
        } else {
            captionMode = "Blocos"; captionStyle = "Ethos"; captionPosition = "Inferior"; autoHook = false; fillFrame = false
        }
    }

    /// Aplica um dicionário parcial (de um projeto antigo ou da IA) sobre estes ajustes, validando os tipos.
    func merging(_ partial: [String: Any]) throws -> EditSettings {
        var base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] ?? [:]
        for (key, value) in partial where base[key] != nil && !(value is NSNull) { base[key] = value }
        var merged = try JSONDecoder().decode(EditSettings.self, from: JSONSerialization.data(withJSONObject: base))
        merged.targetSeconds = min(600, max(10, merged.targetSeconds.isFinite ? merged.targetSeconds : 60))
        merged.horizontalFocus = min(1, max(0, merged.horizontalFocus.isFinite ? merged.horizontalFocus : 0.5))
        merged.eyeContactStrength = min(1, max(0, merged.eyeContactStrength.isFinite ? merged.eyeContactStrength : 0.6))
        merged.voiceIsolation = min(1, max(0, merged.voiceIsolation.isFinite ? merged.voiceIsolation : 0.8))
        merged.zoomCycle = min(40, max(4, merged.zoomCycle.isFinite ? merged.zoomCycle : 16))
        merged.musicVolume = min(0.6, max(0, merged.musicVolume.isFinite ? merged.musicVolume : 0.12))
        merged.captionScale = min(1.6, max(0.6, merged.captionScale.isFinite ? merged.captionScale : 1))
        merged.voiceVolume = min(2, max(0, merged.voiceVolume.isFinite ? merged.voiceVolume : 1))
        merged.frameScale = min(1, max(0.5, merged.frameScale.isFinite ? merged.frameScale : 1))
        merged.fpsLimit = min(60, max(1, merged.fpsLimit))
        if !Self.platforms.contains(merged.platform) { merged.platform = self.platform }
        if partial["platform"] == nil, let vertical = partial["vertical"] as? Bool, vertical != (self.platform != "YouTube") {
            merged.platform = vertical ? "Instagram Reels" : "YouTube"
        }
        merged.vertical = merged.platform != "YouTube"
        return merged
    }
}

struct Cut: Codable, Equatable {
    var start: Double
    var end: Double
    var duration: Double { end - start }
}

struct Timeline: Codable {
    var cuts: [Cut]
    var captions: [Caption]
    /// Quantos trechos do início são o gancho em vídeo (repetem um momento que aparece de novo depois).
    var hookCount = 0
    var hookTransition = "rebobinar"
    var duration: Double { cuts.reduce(0) { $0 + $1.duration } }
    var hookDuration: Double { cuts.prefix(hookCount).reduce(0) { $0 + $1.duration } }
    init(cuts: [Cut], captions: [Caption], hookCount: Int = 0) { self.cuts = cuts; self.captions = captions; self.hookCount = hookCount }

    static func make(captions: [Caption], duration: Double, trimPauses: Bool, exclusions: [Cut] = [], splits: [Double] = [],
                     lookAway: [Cut] = [], tightPauses: Bool = false, hook: VideoHook? = nil) throws -> Timeline {
        guard duration.isFinite, duration > 0 else { throw StudioError("O vídeo não tem duração válida.") }
        guard captions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.2 }) else {
            throw StudioError("Há legendas com tempos inválidos. Revise ou importe outro arquivo SRT.")
        }
        let sorted = captions.sorted { $0.start < $1.start }
        guard sorted.map(\.id).count == Set(sorted.map(\.id)).count else { throw StudioError("As legendas contêm identificadores repetidos.") }
        var cuts: [Cut] = []
        if sorted.isEmpty || (!trimPauses && sorted.allSatisfy(\.included)) {
            cuts = [Cut(start: 0, end: duration)]
        } else {
            for (index, cue) in sorted.enumerated() where cue.included {
                let previous = index > 0 ? sorted[index - 1] : nil
                let next = index + 1 < sorted.count ? sorted[index + 1] : nil
                // Padding must not leak words from deliberately excluded adjacent captions.
                let start = max(0, max(cue.start - 0.10, previous?.included == false ? previous!.end : 0))
                let end = min(duration, min(cue.end + 0.15, next?.included == false ? next!.start : duration))
                guard end > start else { continue }
                if let last = cuts.last, start <= last.end + (trimPauses ? 0.25 : 0.75), previous?.included != false {
                    cuts[cuts.count - 1].end = max(last.end, end)
                } else { cuts.append(Cut(start: start, end: end)) }
            }
        }
        // Remove palavras marcadas (vícios de linguagem) abrindo pequenos cortes dentro da fala.
        var holes: [(Double, Double)] = []
        for cue in sorted where cue.included {
            let removed = Set(cue.removedWords ?? []); guard !removed.isEmpty else { continue }
            let timed = cue.timedWords()
            for (i, word) in timed.enumerated() where removed.contains(i) {
                let next = i + 1 < timed.count ? timed[i + 1].start : word.end
                let end = next - word.end < 0.35 ? next : word.end
                if end - word.start > 0.04 { holes.append((word.start, end)) }
            }
        }
        holes += exclusions.map { ($0.start, $0.end) }
        // Modo roteiro: pausas de leitura no meio da fala e silêncios olhando para fora da câmera.
        let speech = sorted.filter(\.included).flatMap { cue -> [Word] in
            let removed = Set(cue.removedWords ?? [])
            return cue.timedWords().enumerated().filter { !removed.contains($0.offset) }.map(\.element)
        }.sorted { $0.start < $1.start }
        if tightPauses {
            for cue in sorted where cue.included && cue.words != nil {
                let w = cue.timedWords()
                for (a, b) in zip(w, w.dropFirst()) where b.start - a.end > 0.45 {
                    let s = a.end + 0.12, e = b.start - 0.10
                    if e - s > 0.15 { holes.append((s, e)) }
                }
            }
        }
        for away in lookAway {
            var pieces = [(away.start, away.end)]
            for w in speech where w.end > away.start - 0.1 && w.start < away.end + 0.1 {
                pieces = pieces.flatMap { p -> [(Double, Double)] in
                    let ws = w.start - 0.08, we = w.end + 0.08
                    guard ws < p.1, we > p.0 else { return [p] }
                    return [(p.0, ws), (we, p.1)].filter { $0.1 - $0.0 > 0.01 }
                }
            }
            holes += pieces.filter { $0.1 - $0.0 > 0.3 }
        }
        for hole in holes {
            cuts = cuts.flatMap { cut -> [Cut] in
                guard hole.0 < cut.end, hole.1 > cut.start else { return [cut] }
                return [Cut(start: cut.start, end: hole.0), Cut(start: hole.1, end: cut.end)].filter { $0.duration > 0.06 }
            }
        }
        guard !cuts.isEmpty else { throw StudioError("Selecione pelo menos um trecho para exportar.") }
        // Divisões manuais: separam um trecho em dois no ponto marcado (sem tirar nada).
        for point in splits.sorted() {
            cuts = cuts.flatMap { cut -> [Cut] in
                guard point > cut.start + 0.04, point < cut.end - 0.04 else { return [cut] }
                return [Cut(start: cut.start, end: point), Cut(start: point, end: cut.end)]
            }
        }
        // Gancho em vídeo: o trecho escolhido (já sem vícios e pausas) vai para o começo; o vídeo depois segue do início.
        var hookCount = 0
        if let hook, hook.end - hook.start >= 1 {
            var piece = cuts.compactMap { cut -> Cut? in
                let s = max(cut.start, hook.start), e = min(cut.end, hook.end)
                return e - s > 0.06 ? Cut(start: s, end: e) : nil
            }
            if piece.isEmpty { piece = [Cut(start: max(0, hook.start), end: min(duration, hook.end))] }
            hookCount = piece.count
            cuts = piece + cuts
        }
        var remapped: [Caption] = []
        var offset = 0.0
        for cut in cuts {
            for cue in sorted where cue.included && cue.end > cut.start && cue.start < cut.end {
                let start = max(cue.start, cut.start) - cut.start + offset
                let end = min(cue.end, cut.end) - cut.start + offset
                let shift = offset - cut.start
                let removed = Set(cue.removedWords ?? [])
                let words = cue.timedWords().enumerated().filter { !removed.contains($0.offset) && $0.element.end > cut.start && $0.element.start < cut.end }
                    .map { Word(text: $0.element.text, start: max($0.element.start, cut.start) + shift, end: min($0.element.end, cut.end) + shift) }
                guard !words.isEmpty || removed.isEmpty, cue.hidden != true else { continue }
                let text = removed.isEmpty ? cue.text : words.map(\.text).joined(separator: " ")
                if end > start {
                    // Uma legenda cortada só por uma divisão continua como um bloco único.
                    if let last = remapped.last, last.sourceID == cue.id, last.text == text, abs(last.end - start) < 0.01 {
                        remapped[remapped.count - 1].end = end
                        if let w = remapped[remapped.count - 1].words { remapped[remapped.count - 1].words = w + words }
                    } else {
                        remapped.append(Caption(id: remapped.count, start: start, end: end, text: text, words: removed.isEmpty && words.count != cue.timedWords().count ? nil : words, sourceID: cue.id))
                    }
                }
            }
            offset += cut.duration
        }
        var made = Timeline(cuts: cuts, captions: remapped, hookCount: hookCount)
        made.hookTransition = hook?.transition ?? "rebobinar"
        return made
    }

    /// Converte um intervalo do vídeo original para os intervalos correspondentes na edição.
    func outputRanges(start: Double, end: Double) -> [(Double, Double)] {
        var result: [(Double, Double)] = []; var offset = 0.0
        for cut in cuts {
            let s = max(start, cut.start), e = min(end, cut.end)
            if e > s { result.append((s - cut.start + offset, e - cut.start + offset)) }
            offset += cut.duration
        }
        return result
    }
    /// Junções da edição com a transição de cada uma (marcações manuais têm prioridade sobre o ajuste global).
    func junctions(settings: EditSettings, marks: [TransitionMark]) -> [(time: Double, sourceTime: Double, type: String, duration: Double)] {
        var result: [(Double, Double, String, Double)] = []
        var offset = 0.0
        let global = TransitionMark.id(forSetting: settings.transitions)
        for (i, cut) in cuts.enumerated() {
            if i > 0 && hookCount > 0 && i <= hookCount {
                // Dentro do gancho: cortes secos; na volta ao começo, a transição do gancho.
                result.append((offset, cut.start, i == hookCount ? hookTransition : "corte", i == hookCount ? (hookTransition == "rebobinar" ? 0.9 : 0.6) : 0.5))
            } else if i > 0 {
                let major = cut.start - cuts[i - 1].end > 1.5
                let mark = marks.first { abs($0.sourceTime - cut.start) < 0.05 }
                let type = mark?.type ?? ((major || settings.transitionAllCuts) ? global : "corte")
                result.append((offset, cut.start, type, mark?.duration ?? 0.5))
            }
            offset += cut.duration
        }
        return result
    }
    /// Instantes da edição em que há um salto grande no original (mudança de assunto), usados para transições.
    var majorCutTimes: [Double] {
        var times: [Double] = []; var offset = 0.0
        for (i, cut) in cuts.enumerated() {
            if i > 0, cut.start - cuts[i - 1].end > 1.5 { times.append(offset) }
            offset += cut.duration
        }
        return times
    }
}

extension Timeline {
    /// Converte um instante da edição para o tempo do vídeo original.
    func sourceTime(_ output: Double) -> Double {
        var offset = 0.0
        for cut in cuts {
            if output < offset + cut.duration { return cut.start + max(0, output - offset) }
            offset += cut.duration
        }
        return cuts.last?.end ?? output
    }
    /// Instante da edição correspondente a um tempo do original (o início do próximo trecho mantido, se ele foi cortado).
    func outputTime(_ source: Double) -> Double {
        // O gancho repete um momento do meio: a posição "de verdade" é a da sequência normal, depois dele.
        var offset = hookDuration
        for cut in cuts.dropFirst(hookCount) {
            if source < cut.start { return offset }
            if source <= cut.end { return offset + source - cut.start }
            offset += cut.duration
        }
        return offset
    }
}

/// Uma edição posicionada no tempo da saída, pronta para o renderizador.
struct PlacedEffect {
    var effect: Effect
    var start: Double
    var end: Double
}

enum Subtitles {
    static func timestamp(_ value: Double, vtt: Bool = false) -> String {
        let ms = max(0, Int((value * 1000).rounded()))
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, vtt ? "." : ",", ms % 1000)
    }
    static func write(_ captions: [Caption], vtt: Bool = false) -> String {
        (vtt ? "WEBVTT\n\n" : "") + captions.enumerated().map { i, c in
            "\(i + 1)\n\(timestamp(c.start, vtt: vtt)) --> \(timestamp(c.end, vtt: vtt))\n\(c.text)\n"
        }.joined(separator: "\n")
    }
    static func parse(_ text: String) throws -> [Caption] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{FEFF}", with: "")
        let blocks = normalized.components(separatedBy: "\n\n")
        var captions: [Caption] = []
        func seconds(_ string: String) -> Double? {
            let parts = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]), h >= 0, m >= 0, m < 60, s >= 0, s < 60 else { return nil }
            return h * 3600 + m * 60 + s
        }
        for block in blocks where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let lines = block.components(separatedBy: "\n")
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { throw StudioError("SRT inválido: um bloco não contém os tempos da legenda.") }
            let times = lines[i].components(separatedBy: "-->")
            guard times.count == 2, let start = seconds(times[0]), let end = seconds(times[1]), end > start else { throw StudioError("SRT inválido: confira os tempos das legendas.") }
            let body = lines.dropFirst(i + 1).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, body.count <= 1000 else { throw StudioError("Uma legenda está vazia ou é longa demais.") }
            captions.append(Caption(id: captions.count, start: start, end: end, text: body))
        }
        guard !captions.isEmpty else { throw StudioError("Nenhuma legenda encontrada no arquivo.") }
        return captions
    }
}

struct SavedProject: Codable {
    var version = 1
    var mediaFile: String
    var supportFile: String?
    var duration: Double
    var captions: [Caption]
    var settings: EditSettings
    var editSummary: String
    var effects: [Effect]? = nil
    var chat: [ChatMessage]? = nil
    var faceTrack: [FacePoint]? = nil
    var clips: [ClipSuggestion]? = nil
    var exclusions: [Cut]? = nil
    var transitionMarks: [TransitionMark]? = nil
    var splits: [Double]? = nil
    /// Edição do vídeo completo guardada enquanto um corte está aberto.
    var mainEdit: EditState? = nil
    var activeClip: UUID? = nil
    /// Caminho do vídeo original quando o projeto não guarda uma cópia.
    var mediaPath: String? = nil
    var script: String? = nil
    var gaze: GazeReport? = nil
    var videoHook: VideoHook? = nil

    /// Lê projetos de versões anteriores, completando ajustes novos com os valores padrão.
    static func decode(_ data: Data) throws -> SavedProject {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StudioError("Projeto inválido.") }
        let partial = object["settings"] as? [String: Any] ?? [:]
        let settings = try EditSettings().merging(partial)
        object["settings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        return try JSONDecoder().decode(SavedProject.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

func clockLabel(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "—" }
    let n = max(0, Int(seconds))
    return String(format: "%02d:%02d", n / 60, n % 60)
}

/// JSON genérico, para ler dados de versões anteriores com tolerância.
enum JSONValue: Decodable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }
}
