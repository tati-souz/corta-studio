import Foundation
import AVFoundation
import AppKit

enum StudioTests {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw StudioError("Teste: " + message) }
    }
    @MainActor static func run(directory: URL? = nil) async throws {
        let args = CommandLine.arguments
        let folder: URL
        if let directory { folder = directory }
        else if let index = args.firstIndex(of: "--self-test"), args.count > index + 1 {
            folder = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        } else { folder = FileManager.default.temporaryDirectory.appendingPathComponent("CortaTests-\(UUID().uuidString)") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cues = [Caption(id: 0, start: 0.4, end: 1.7, text: "Uma história começa aqui."), Caption(id: 1, start: 2.0, end: 3.0, text: "Esta repetição será removida.", included: false), Caption(id: 2, start: 4.0, end: 5.6, text: "E termina com uma boa ideia.")]
        let timeline = try Timeline.make(captions: cues, duration: 6, trimPauses: true)
        try check(timeline.cuts.count == 2, "dois trechos independentes")
        try check(abs(timeline.duration - 3.4) < 0.001, "duração calculada após cortes")
        try check(timeline.captions.count == 2 && timeline.captions[1].start < 2, "legendas remapeadas após corte")
        let roundTrip = try Subtitles.parse(Subtitles.write(timeline.captions))
        try check(roundTrip.count == 2 && abs(roundTrip[1].start - timeline.captions[1].start) < 0.002, "SRT mantém os novos tempos")
        do { _ = try Subtitles.parse("1\n00:00:xx,000 --> 00:00:02,000\nOlá"); throw StudioError("SRT inválido foi aceito") } catch let error as StudioError { try check(error.message != "SRT inválido foi aceito", "validação SRT") }
        let bad = [Caption(id: 0, start: .nan, end: 1, text: "x")]
        do { _ = try Timeline.make(captions: bad, duration: 6, trimPauses: true); throw StudioError("NaN aceito") } catch let error as StudioError { try check(error.message != "NaN aceito", "validação tempos") }
        print("PASS timeline, timestamps, SRT, invalid input")
        // Vícios de linguagem: palavra removida abre um corte e some da legenda
        var filler = Caption(id: 0, start: 1, end: 3, text: "Então hum a virtude", words: [Word(text: "Então", start: 1, end: 1.4), Word(text: "hum", start: 1.5, end: 1.9), Word(text: "a", start: 2.0, end: 2.1), Word(text: "virtude", start: 2.2, end: 2.9)])
        try check(filler.obviousFillerIndexes == [1], "detecta vício inequívoco")
        filler.removedWords = [1]
        let fillerTimeline = try Timeline.make(captions: [filler], duration: 4, trimPauses: true)
        try check(fillerTimeline.cuts.count == 2 && abs(fillerTimeline.duration - (3.15 - 0.9 - 0.5)) < 0.02, "corte dentro da fala")
        try check(fillerTimeline.captions.map(\.text).joined(separator: " ") == "Então a virtude", "legenda sem o vício")
        try check(Caption(id: 0, start: 0, end: 1, text: "Isso é bom").obviousFillerIndexes.isEmpty, "não remove 'é' verbo")
        print("PASS vícios de linguagem")
        // Remoção manual de trechos e conversão de tempos edição ↔ original
        let base = [Caption(id: 0, start: 0, end: 10, text: "um dois três")]
        // Gancho em vídeo: o trecho 6–8 s abre a edição e a fala aparece de novo no lugar dela.
        let hooked = try Timeline.make(captions: base, duration: 10, trimPauses: false, hook: VideoHook(start: 6, end: 8))
        try check(hooked.hookCount == 1 && abs(hooked.hookDuration - 2) < 0.01 && abs(hooked.duration - 12) < 0.01, "gancho em vídeo no começo")
        try check(abs(hooked.sourceTime(1) - 7) < 0.01 && abs(hooked.sourceTime(3) - 1) < 0.01 && abs(hooked.outputTime(7) - 9) < 0.01, "tempos com gancho")
        try check(hooked.junctions(settings: EditSettings(), marks: []).first?.type == "rebobinar", "transição de volta do gancho")
        print("PASS gancho em vídeo: \(hooked.cuts.map { "\($0.start)-\($0.end)" }) legendas \(hooked.captions.count)")
        let cutTimeline = try Timeline.make(captions: base, duration: 10, trimPauses: false, exclusions: [Cut(start: 2, end: 4), Cut(start: 6, end: 7)])
        try check(abs(cutTimeline.duration - 7) < 0.01, "trechos removidos manualmente")
        try check(abs(cutTimeline.sourceTime(2.5) - 4.5) < 0.01 && abs(cutTimeline.outputTime(4.5) - 2.5) < 0.01, "tempo edição ↔ original")
        try check(abs(cutTimeline.outputTime(3) - 2) < 0.01, "tempo removido aponta para o próximo trecho")
        try check(cutTimeline.captions.allSatisfy { $0.sourceID == 0 }, "legenda remapeada guarda a origem")
        let oldEffect = try JSONDecoder().decode(Effect.self, from: Data(#"{"kind":"texto","start":1,"end":2,"text":"x","style":"titulo","amount":1.1,"asset":""}"#.utf8))
        try check(oldEffect.animation == "fade", "efeito antigo ganha animação padrão")
        print("PASS edição manual: trechos removidos, tempos, compatibilidade")
        // Tipos de zoom e velocidade
        func z(_ style: String, _ speed: Double, _ t: Double) -> Double { Effect(kind: .zoom, start: 0, end: 4, style: style, amount: 1.2, speed: speed).zoomFactor(at: t, duration: 4) }
        try check(abs(z("suave", 0.35, 0) - 1) < 0.001 && abs(z("suave", 0.35, 2) - 1.2) < 0.001 && abs(z("suave", 0.35, 4) - 1) < 0.001, "suave aproxima e volta")
        try check(z("suave", 0.1, 0.1) > z("suave", 1.0, 0.1), "velocidade rápida chega antes")
        try check(abs(z("zoom-in", 0, 0) - 1) < 0.001 && abs(z("zoom-in", 0, 2) - 1.1) < 0.01 && abs(z("zoom-in", 0, 4) - 1.2) < 0.001, "zoom in ao longo do trecho")
        try check(abs(z("zoom-in", 0.5, 1) - 1.2) < 0.001, "zoom in rápido e segura")
        try check(abs(z("zoom-out", 0, 0) - 1.2) < 0.001 && abs(z("zoom-out", 0, 4) - 1) < 0.001, "zoom out")
        try check(abs(z("corte", 0, 0) - 1.2) < 0.001 && abs(z("corte", 0, 3.9) - 1.2) < 0.001, "corte com aproximação instantânea")
        try check(abs(z("batida", 0.35, 0.12) - 1.2) < 0.001 && abs(z("batida", 0.35, 1) - 1) < 0.001, "batida entra e volta")
        let legacyZoom = try JSONDecoder().decode(Effect.self, from: Data(#"{"kind":"zoom","start":1,"end":3,"amount":1.2}"#.utf8))
        try check(abs(legacyZoom.zoomFactor(at: 1, duration: 2) - 1.2) < 0.001, "zoom de projeto antigo continua igual")
        print("PASS zoom: suave, in, out, corte, batida, velocidade")
        let testImage = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 180, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 1280, bitsPerPixel: 32)!
        let cg = CGContext(data: testImage.bitmapData, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.2, alpha: 1)); cg.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        var testSettings = EditSettings(); testSettings.question = "Como contar uma boa história?"
        let painter = FramePainter(size: CGSize(width: 540, height: 960), timeline: timeline, settings: testSettings, support: nil)
        let ci = painter.frame(CIImage(cgImage: cg.makeImage()!), at: 0.8)
        let cpuContext = CIContext(options: [.useSoftwareRenderer: true])
        if let frame = cpuContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: 540, height: 960)) {
            try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("caption-layout.png"))
            print("PASS caption layout rasterized")
        }
        // Biblioteca temporária só para o teste
        let library = folder.appendingPathComponent("Biblioteca")
        let previousLibrary = UserDefaults.standard.string(forKey: "CortaLibraryPath")
        UserDefaults.standard.set(library.path, forKey: "CortaLibraryPath")
        defer { if let previousLibrary { UserDefaults.standard.set(previousLibrary, forKey: "CortaLibraryPath") } else { UserDefaults.standard.removeObject(forKey: "CortaLibraryPath") } }
        Library.prepare()
        let still = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        still.setFillColor(CGColor(red: 0.55, green: 0.35, blue: 0.2, alpha: 1)); still.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        still.setFillColor(CGColor(red: 0.95, green: 0.9, blue: 0.75, alpha: 1)); still.fill(CGRect(x: 120, y: 60, width: 160, height: 180))
        try NSBitmapImageRep(cgImage: still.makeImage()!).representation(using: .png, properties: [:])!.write(to: Library.images.appendingPathComponent("biblioteca-antiga.png"))
        try makeAudio(Library.music.appendingPathComponent("trilha-teste.wav"))
        try check(Library.imageNames == ["biblioteca-antiga.png"] && Library.musicNames == ["trilha-teste.wav"], "biblioteca lista imagens e músicas")

        // Validação de respostas da IA: aceita o válido, descarta o inválido
        let fakeCaptions = (0..<6).map { Caption(id: $0, start: Double($0), end: Double($0) + 0.9, text: "frase \($0)") }
        let payload: [String: Any] = ["reply": "ok", "warnings": [], "keep_ranges": [["start_id": 0, "end_id": 1], ["start_id": 3, "end_id": 5]],
                                      "caption_edits": [["id": 2, "text": "Frase corrigida"], ["id": 99, "text": "inexistente"]],
                                      "effects": [["kind": "zoom", "start": 0.5, "end": 2.0, "amount": 3.0], ["kind": "texto", "start": 1, "end": 3, "text": "", "style": "titulo"],
                                                  ["kind": "imagem", "start": 1, "end": 3, "asset": "../segredo.png"], ["kind": "imagem", "start": 3, "end": 4, "asset": "biblioteca-antiga.png", "style": "tela-cheia"]],
                                      "settings": ["captionStyle": "Ethos", "musicFile": "nao-existe.mp3", "platform": "TikTok"]]
        let decision = try ClaudeConnection.validate(payload, reply: "ok", captions: fakeCaptions, duration: 6)
        try check(decision.keep == [0, 1, 3, 4, 5], "intervalos mantidos")
        try check(decision.captionEdits == [2: "Frase corrigida"], "correções só em IDs existentes")
        try check(decision.effects?.count == 2 && decision.effects?[0].amount == 1.35, "efeitos inválidos descartados e zoom limitado")
        try check(decision.settings["musicFile"] == nil, "música inexistente ignorada")
        let merged = try EditSettings().merging(decision.settings)
        try check(merged.platform == "TikTok" && merged.vertical && merged.captionStyle == "Ethos", "ajustes parciais aplicados")
        do { _ = try ClaudeConnection.validate(["reply": "x", "keep_ranges": [["start_id": 4, "end_id": 2]]], reply: "x", captions: fakeCaptions, duration: 6); throw StudioError("intervalo invertido aceito") }
        catch let error as StudioError { try check(error.message != "intervalo invertido aceito", "rejeita intervalo invertido") }
        let legacy = try SavedProject.decode(Data(#"{"version":1,"mediaFile":"original.mp4","duration":6,"captions":[],"editSummary":"","settings":{"vertical":true,"shortVideo":false,"targetSeconds":60,"style":"Natural","captions":true,"zoom":true,"fillFrame":false,"horizontalFocus":0.5,"question":"","captionStyle":"Clássica","trimPauses":false,"splitScreen":false,"fpsLimit":30}}"#.utf8))
        try check(legacy.settings.vertical && legacy.settings.platform == "Instagram Reels" && legacy.effects == nil, "abre projeto da versão 0.1")
        print("PASS IA: validação, ajustes parciais, projeto antigo")

        // Quadros com todos os recursos visuais, para inspeção
        var rich = EditSettings(); rich.applyPlatform("Instagram Reels"); rich.colorLook = "Ethos clássico"; rich.progressBar = true; rich.captionStyle = "Contorno"
        rich.question = "Por que a virtude nasce do hábito?"
        let words = [Caption(id: 0, start: 0.2, end: 2.8, text: "A virtude não nasce do impulso", words: nil), Caption(id: 1, start: 3.0, end: 5.8, text: "mas do hábito repetido todos os dias")]
        let richTimeline = try Timeline.make(captions: words, duration: 6, trimPauses: false)
        let richEffects = [PlacedEffect(effect: Effect(kind: .zoom, start: 1, end: 3, amount: 1.25), start: 1, end: 3),
                           PlacedEffect(effect: Effect(kind: .texto, start: 3.2, end: 5.5, text: "O hábito forma o caráter", style: "destaque"), start: 3.2, end: 5.5),
                           PlacedEffect(effect: Effect(kind: .texto, start: 0, end: 6, text: "Capítulo 1 · Virtude", style: "capitulo"), start: 0, end: 6),
                           PlacedEffect(effect: Effect(kind: .imagem, start: 5.6, end: 6, style: "dividida", asset: "biblioteca-antiga.png"), start: 5.6, end: 6)]
        let richPainter = FramePainter(size: CGSize(width: 540, height: 960), timeline: richTimeline, settings: rich, support: nil, effects: richEffects, faceTrack: [FacePoint(time: 0, x: 0.3), FacePoint(time: 6, x: 0.7)])
        for t in [1.0, 2.0, 4.0, 5.8] {
            let image = richPainter.frame(CIImage(cgImage: cg.makeImage()!), at: t)
            if let frame = cpuContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: 540, height: 960)) {
                try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("efeitos-\(t).png"))
            }
        }
        var wide = EditSettings(); wide.applyPlatform("YouTube"); wide.colorLook = "Cinema"
        let widePainter = FramePainter(size: CGSize(width: 960, height: 540), timeline: richTimeline, settings: wide, support: nil,
                                       effects: [PlacedEffect(effect: Effect(kind: .texto, start: 0, end: 6, text: "Virtude e hábito", style: "titulo"), start: 0, end: 6)])
        if let frame = cpuContext.createCGImage(widePainter.frame(CIImage(cgImage: cg.makeImage()!), at: 4.2), from: CGRect(x: 0, y: 0, width: 960, height: 540)) {
            try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("youtube-titulo.png"))
        }
        print("PASS quadros com efeitos rasterizados")
        // Folha com todos os estilos de texto
        for vertical in [true, false] {
            var st = EditSettings(); st.applyPlatform(vertical ? "Instagram Reels" : "YouTube"); st.captions = false
            let size = vertical ? CGSize(width: 270, height: 480) : CGSize(width: 480, height: 270)
            let cols = vertical ? 6 : 4, rows = (TextStyles.all.count + cols - 1) / cols
            let sheet = CGContext(data: nil, width: Int(size.width) * cols, height: Int(size.height) * rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            let backdrop: CIImage = {
                if let sample = ProcessInfo.processInfo.environment["CORTA_FRAME"], let img = NSImage(contentsOfFile: sample)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return CIImage(cgImage: img) }
                return CIImage(cgImage: cg.makeImage()!)
            }()
            for (i, style) in TextStyles.all.enumerated() {
                let fx = Effect(kind: .texto, start: 0, end: 6, text: style.sample, style: style.id)
                let painter = FramePainter(size: size, timeline: richTimeline, settings: st, support: nil, effects: [PlacedEffect(effect: fx, start: 0, end: 6)])
                if let img = cpuContext.createCGImage(painter.frame(backdrop, at: 3), from: CGRect(origin: .zero, size: size)) {
                    sheet.draw(img, in: CGRect(x: CGFloat(i % cols) * size.width, y: CGFloat(rows - 1 - i / cols) * size.height, width: size.width, height: size.height))
                }
            }
            try NSBitmapImageRep(cgImage: sheet.makeImage()!).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("estilos-\(vertical ? "vertical" : "horizontal").png"))
        }
        // Animações: o texto entra com o tempo
        let anim = FramePainter(size: CGSize(width: 270, height: 480), timeline: richTimeline, settings: rich, support: nil, effects: [])
        let typed = PlacedEffect(effect: Effect(kind: .texto, start: 1, end: 5, text: "Máquina", style: "palavra", animation: "maquina"), start: 1, end: 5)
        try check(anim.animatedText(typed, at: 1.05).extent.width >= 0, "animação máquina de escrever")
        print("PASS estilos de texto e animações")
        // Transições: folha com cada tipo no meio da transição (antes, na junção e depois)
        let tl = Timeline(cuts: [Cut(start: 0, end: 3), Cut(start: 3.5, end: 6)], captions: [])
        try check(tl.junctions(settings: EditSettings(), marks: []).count == 1, "junção encontrada")
        let tsize = CGSize(width: 320, height: 180)
        let tsheet = CGContext(data: nil, width: 320 * 3, height: 180 * 5, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let tframe: CIImage = {
            if let sample = ProcessInfo.processInfo.environment["CORTA_FRAME"], let img = NSImage(contentsOfFile: sample)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return CIImage(cgImage: img) }
            return CIImage(cgImage: cg.makeImage()!)
        }()
        var tsettings = EditSettings(); tsettings.captions = false; tsettings.zoom = false; tsettings.fadeInOut = false
        for (row, type) in ["fade", "flash", "zoom", "desfoque", "chicote"].enumerated() {
            let painter = FramePainter(size: tsize, timeline: tl, settings: tsettings, support: nil, transitions: [TransitionMark(sourceTime: 3.5, type: type, duration: 0.6)])
            for (col, t) in [2.82, 3.0, 3.15].enumerated() {
                if let img = cpuContext.createCGImage(painter.frame(tframe, at: t), from: CGRect(origin: .zero, size: tsize)) {
                    tsheet.draw(img, in: CGRect(x: col * 320, y: (4 - row) * 180, width: 320, height: 180))
                }
            }
        }
        try NSBitmapImageRep(cgImage: tsheet.makeImage()!).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("transicoes.png"))
        print("PASS transições desenhadas")
        // Recursos estilo CapCut: layouts, efeitos de vídeo, transições novas e legendas virais (folhas para inspeção visual)
        do {
            let size = CGSize(width: 270, height: 480)
            let photo: CIImage = {
                if let p = ProcessInfo.processInfo.environment["CORTA_BROLL"], let img = NSImage(contentsOfFile: p)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { return CIImage(cgImage: img) }
                return CIImage(color: CIColor(red: 0.5, green: 0.3, blue: 0.2)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
            }()
            let still = Timeline(cuts: [Cut(start: 0, end: 10)], captions: [])
            var vs = EditSettings(); vs.applyPlatform("Instagram Reels"); vs.captions = false; vs.zoom = false; vs.fadeInOut = false
            func sheet(_ name: String, _ frames: [CIImage]) throws {
                let cols = frames.count
                let ctx = CGContext(data: nil, width: Int(size.width) * cols, height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                for (i, f) in frames.enumerated() { if let img = cpuContext.createCGImage(f, from: CGRect(origin: .zero, size: size)) { ctx.draw(img, in: CGRect(x: CGFloat(i) * size.width, y: 0, width: size.width, height: size.height)) } }
                try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
            }
            // Layouts com um vídeo de apoio (simulado pelo quadro da foto)
            var layoutFrames: [CIImage] = []
            for layout in Effect.layouts {
                let e = Effect(kind: .video, start: 0, end: 10, style: layout.id, asset: "x", animation: "corte")
                let painter = FramePainter(size: size, timeline: still, settings: vs, support: nil, effects: [PlacedEffect(effect: e, start: 0, end: 10)])
                layoutFrames.append(painter.frame(tframe, at: 5, videos: [e.id: photo]))
            }
            try sheet("capcut-layouts.png", layoutFrames)
            var fxFrames: [CIImage] = []
            for fx in Effect.fxStyles {
                let e = Effect(kind: .fx, start: 0, end: 4, style: fx.id, amount: 0.8)
                let painter = FramePainter(size: size, timeline: still, settings: vs, support: nil, effects: [PlacedEffect(effect: e, start: 0, end: 4)])
                fxFrames.append(painter.frame(tframe, at: fx.id == "flash" || fx.id == "foco" ? 0.08 : 2.1))
            }
            try sheet("capcut-efeitos.png", fxFrames)
            let cuts2 = Timeline(cuts: [Cut(start: 0, end: 3), Cut(start: 3.5, end: 6)], captions: [])
            var trFrames: [CIImage] = []
            for t in ["vertical", "girar", "glitch", "pixelar", "tremor", "luz"] {
                let painter = FramePainter(size: size, timeline: cuts2, settings: vs, support: nil, transitions: [TransitionMark(sourceTime: 3.5, type: t, duration: 0.6)])
                trFrames.append(painter.frame(tframe, at: 2.93))
            }
            try sheet("capcut-transicoes.png", trFrames)
            let words = [Word(text: "A", start: 0, end: 0.3), Word(text: "virtude", start: 0.3, end: 0.9), Word(text: "nasce", start: 0.9, end: 1.4)]
            let capTimeline = Timeline(cuts: [Cut(start: 0, end: 10)], captions: [Caption(id: 0, start: 0, end: 3, text: "A virtude nasce", words: words)])
            var capFrames: [CIImage] = []
            for (style, mode) in [("Hormozi", "Dinâmica"), ("Caixa", "Dinâmica"), ("Hormozi", "Uma palavra"), ("Ethos", "Uma palavra")] {
                var cs = vs; cs.captions = true; cs.captionStyle = style; cs.captionMode = mode
                capFrames.append(FramePainter(size: size, timeline: capTimeline, settings: cs, support: nil).frame(tframe, at: 0.6))
            }
            try sheet("capcut-legendas.png", capFrames)
            // Modelo Reels Ethos: degradê + legenda Bege + cartão de citação
            let longWords = "Nós não percebemos a nossa leitura das coisas como uma leitura".split(separator: " ").enumerated().map { Word(text: String($0.element), start: Double($0.offset) * 0.3, end: Double($0.offset) * 0.3 + 0.28) }
            let reelsTimeline = Timeline(cuts: [Cut(start: 0, end: 10)], captions: [Caption(id: 0, start: 0, end: 3.6, text: longWords.map(\.text).joined(separator: " "), words: longWords)])
            var rs = vs; rs.captions = true; rs.captionStyle = "Bege"; rs.captionMode = "Blocos"; rs.captionPosition = "Inferior"
            let img = Effect(kind: .video, start: 0, end: 10, style: "degrade", asset: "x", animation: "corte")
            let card = Effect(kind: .texto, start: 0, end: 10, text: "Enxergo o mundo como ele é", style: "cartao", animation: "fade")
            var reels: [CIImage] = []
            reels.append(FramePainter(size: size, timeline: reelsTimeline, settings: rs, support: nil, effects: [PlacedEffect(effect: img, start: 0, end: 10)]).frame(tframe, at: 0.5, videos: [img.id: photo]))
            reels.append(FramePainter(size: size, timeline: reelsTimeline, settings: rs, support: nil, effects: [PlacedEffect(effect: img, start: 0, end: 10)]).frame(tframe, at: 2.6, videos: [img.id: photo]))
            reels.append(FramePainter(size: size, timeline: reelsTimeline, settings: rs, support: nil, effects: [PlacedEffect(effect: card, start: 0, end: 10)]).frame(tframe, at: 2.6))
            var full = img; full.style = "tela-cheia"
            reels.append(FramePainter(size: size, timeline: reelsTimeline, settings: rs, support: nil, effects: [PlacedEffect(effect: full, start: 0, end: 10)]).frame(tframe, at: 1.0, videos: [full.id: photo]))
            try sheet("reels-ethos.png", reels)
            print("PASS recursos estilo CapCut desenhados")
        }
        // Imagens para a narração: Wikimedia Commons (rede) e SVG
        let finder = ImageFinder()
        finder.query = "Saint Augustine painting"
        await finder.searchCommons()
        if let first = finder.results.first {
            let saved = try await finder.save(first)
            let log = try String(contentsOf: Library.root.appendingPathComponent("fontes.txt"), encoding: .utf8)
            try check(Library.imageNames.contains(saved) && log.contains("licença"), "imagem do Commons salva com licença")
            print("PASS Commons: \(finder.results.count) resultados; salvo \(saved) (\(first.license))")
        } else { print("AVISO Commons sem resultados: \(finder.status)") }
        let svg = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1920 1080" width="1920" height="1080"><rect width="1920" height="1080" fill="#16130F"/><circle cx="960" cy="540" r="220" fill="none" stroke="#C9A24A" stroke-width="10"/></svg>"##
        if let vector = NSImage(data: Data(svg.utf8)) {
            let candidate = ImageCandidate(preview: vector, title: "Círculo dourado", credit: "teste", license: "teste", pageURL: "", downloadURL: nil,
                                           rendered: vector.cgImage(forProposedRect: nil, context: nil, hints: nil), source: "Ilustração por IA (Claude)", generated: true)
            let saved = try await finder.save(candidate)
            try check(saved.hasPrefix("ia-") && saved.hasSuffix(".png"), "ilustração gerada salva e marcada como IA")
            print("PASS ilustração vetorial salva: \(saved)")
        }
        if CommandLine.arguments.contains("--core-only") { return }
        for vertical in [false, true] {
            let name = vertical ? "vertical" : "horizontal"
            let silent = folder.appendingPathComponent("\(name)-silent.mp4")
            let source = folder.appendingPathComponent("\(name)-source.mp4")
            try await Task.detached { try makeVideo(silent, width: vertical ? 180 : 320, height: vertical ? 320 : 180) }.value
            let audioURL = folder.appendingPathComponent("\(name)-audio.wav")
            try makeAudio(audioURL)
            let composition = AVMutableComposition()
            let v = AVURLAsset(url: silent); let a = AVURLAsset(url: audioURL)
            let vt = try await v.loadTracks(withMediaType: .video)[0]
            let at = try await a.loadTracks(withMediaType: .audio)[0]
            let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 6, preferredTimescale: 600))
            try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: vt, at: .zero)
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: at, at: .zero)
            let e = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
            e.outputURL = source; e.outputFileType = .mp4
            try await MediaEngine.runExport(e, progress: { _ in })
            var settings = EditSettings(); settings.vertical = !vertical; settings.question = "Como contar uma boa história?"; settings.captionStyle = "Destaque"
            let output = folder.appendingPathComponent("\(name)-edited.mp4")
            settings.musicFile = "trilha-teste.wav"; settings.musicVolume = 0.4; settings.ducking = false; settings.transitions = "Fade"
            settings.soundEffects = vertical; settings.portraitBlur = vertical; settings.eyeContact = vertical; settings.colorLook = vertical ? "Preto e branco" : "Vívido suave"
            let fx = [Effect(kind: .zoom, start: 0.5, end: 1.6, amount: 1.2), Effect(kind: .texto, start: 4.1, end: 5.5, text: "Uma boa ideia", style: "destaque"),
                      Effect(kind: .imagem, start: 4.0, end: 5.0, style: "tela-cheia", asset: "biblioteca-antiga.png")]
            try await MediaEngine.render(source: source, support: nil, timeline: timeline, settings: settings, effects: fx, destination: output, preview: true, progress: { _ in })
            let info = try await MediaEngine.info(output)
            try check(abs(info.duration - timeline.duration) < 0.15, "duração exportada de \(name)")
            try check(info.size == (settings.vertical ? CGSize(width: 540, height: 960) : CGSize(width: 960, height: 540)), "dimensões exportadas de \(name)")
            // Mesma montagem usada pelo player ao vivo
            let live = try await MediaEngine.compose(source: source, support: nil, timeline: timeline, settings: settings, effects: fx, preview: true)
            let liveGenerator = AVAssetImageGenerator(asset: live.composition); liveGenerator.videoComposition = live.videoComposition
            let liveFrame = try await liveGenerator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            let liveDuration = try await live.composition.load(.duration).seconds
            try check(abs(liveDuration - timeline.duration) < 0.05 && liveFrame.width > 0, "montagem ao vivo de \(name)")
            let asset = AVURLAsset(url: output)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            try check(audioTracks.count == 1, "uma faixa de áudio mixada em \(name)")
            if !vertical {
                var plain = settings; plain.musicFile = ""; plain.fadeInOut = false
                let dry = folder.appendingPathComponent("sem-musica.mp4")
                try await MediaEngine.render(source: source, support: nil, timeline: timeline, settings: plain, destination: dry, preview: true, progress: { _ in })
                let withMusic = try await rms(output, from: 1.0, to: 1.6), without = try await rms(dry, from: 1.0, to: 1.6)
                print("  RMS com música \(withMusic), sem música \(without)")
                try check(abs(withMusic - without) > without * 0.03, "música presente na mixagem")
            }
            let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
            let frame = try await generator.image(at: CMTime(seconds: 0.8, preferredTimescale: 600)).image
            let rep = NSBitmapImageRep(cgImage: frame)
            try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(name)-frame.png"))
            try Subtitles.write(timeline.captions).write(to: folder.appendingPathComponent("\(name)-edited.srt"), atomically: true, encoding: .utf8)
            print("PASS render \(name): \(Int(info.size.width))x\(Int(info.size.height)), \(info.duration)s, voz + música, zoom, texto, imagem")
        }
    }
    /// `--sample-test vídeo pasta`: aplica voz de estúdio, olhar, fundo desfocado e reenquadramento vertical a uma gravação real.
    @MainActor static func sample(video: URL, folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = try await MediaEngine.info(video)
        let start = Date()
        let voice = try await VoiceStudio.process(video: video, isolation: 0.8, directory: folder) { _ in }
        print("voz de estúdio: \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        let dry = try await VoiceStudio.process(video: video, isolation: 0, directory: folder) { _ in }
        let full = try await VoiceStudio.process(video: video, isolation: 1, directory: folder) { _ in }
        let original = try await MediaEngine.audioFile(video, directory: folder)
        for (label, url) in [("original", original), ("sem isolar", dry), ("isolar 0.8", voice), ("isolar 1.0", full)] {
            var levels: [Double] = []
            for s in stride(from: 0.0, to: info.duration - 0.25, by: 0.25) { levels.append(try await rms(url, from: s, to: s + 0.25)) }
            let sorted = levels.sorted()
            let speech = sorted[Int(Double(sorted.count) * 0.9)], floor = sorted[Int(Double(sorted.count) * 0.1)]
            print("\(label): fala (p90) \(String(format: "%.4f", speech)), fundo (p10) \(String(format: "%.5f", floor)), relação \(String(format: "%.1f", speech / max(floor, 1e-6)))")
        }
        if CommandLine.arguments.contains("--audio-only") { return }
        var settings = EditSettings(); settings.applyPlatform("Instagram Reels"); settings.captions = false
        settings.eyeContact = true; settings.portraitBlur = true; settings.studioVoice = true; settings.colorLook = "Ethos clássico"
        let track = info.size.width > info.size.height ? try await MediaEngine.trackFace(video, duration: info.duration) { _ in } : []
        let timeline = Timeline(cuts: [Cut(start: 0, end: info.duration)], captions: [])
        let fx = [Effect(kind: .zoom, start: 3, end: 6, amount: 1.2), Effect(kind: .texto, start: 8, end: 12, text: "A virtude nasce do hábito", style: "destaque")]
        let out = folder.appendingPathComponent("amostra-editada.mp4")
        let renderStart = Date()
        try await MediaEngine.render(source: video, support: nil, timeline: timeline, settings: settings, effects: fx, faceTrack: track, voice: voice, destination: out, preview: false) { _ in }
        print("render 1080x1920 de \(Int(info.duration)) s: \(String(format: "%.1f", Date().timeIntervalSince(renderStart))) s")
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: out)); generator.appliesPreferredTrackTransform = true
        for t in [2.0, 5.0, 10.0] {
            let frame = try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            try NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("amostra-\(Int(t)).png"))
        }
    }
    static func rms(_ url: URL, from: Double, to: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .audio)[0]
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), end: CMTime(seconds: to, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); reader.startReading()
        var sum = 0.0, count = 0
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &data)
            for v in data { sum += Double(v * v) }; count += data.count
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }
    static func makeAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
        buffer.frameLength = 48000
        for second in 0..<6 {
            for frame in 0..<48000 { buffer.floatChannelData![0][frame] = Float(sin(Double(frame + second * 48000) / 48000 * .pi * 2 * (url.lastPathComponent.hasPrefix("trilha") ? 330 : 440))) * 0.025 }
            try file.write(from: buffer)
        }
    }
    static func makeVideo(_ url: URL, width: Int, height: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        guard writer.canAdd(input) else { throw StudioError("O codificador de teste não está disponível neste ambiente.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError("Não foi possível iniciar o codificador de teste.") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<144 {
            while !input.isReadyForMoreMediaData { if writer.status == .failed { throw writer.error! }; Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? StudioError("O sistema não disponibilizou os buffers de vídeo neste ambiente.") }
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw StudioError("Falha no vídeo de teste") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
            context.setFillColor(CGColor(red: 0.09, green: 0.23, blue: 0.20, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 0.7, green: 0.94, blue: 0.6, alpha: 1)); context.fillEllipse(in: CGRect(x: Double(frame % 100) / 100 * Double(width - 70), y: Double(height) * 0.5, width: 70, height: 70))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else { throw writer.error ?? StudioError("Falha no quadro de teste") }
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0); writer.finishWriting { sem.signal() }; sem.wait()
        guard writer.status == .completed else { throw writer.error ?? StudioError("Falha no vídeo de teste") }
    }
}
