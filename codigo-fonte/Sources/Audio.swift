import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit

/// Ajustes da voz de estúdio (0 a 1 cada).
struct VoiceParams: Hashable, Codable {
    var isolation = 0.8   // barulho de fundo (isolamento de voz da Apple)
    var echo = 0.4        // eco da sala
    var hiss = 0.3        // chiado (agudos de ruído)
    var hum = true        // zumbido elétrico (60 Hz)
    var clarity = 0.5     // presença e definição das palavras
    var warmth = 0.3      // corpo/graves da voz
    var leveling = 0.6    // iguala falas baixas e altas (compressão)
    var level = 0.6       // volume final

    var signature: String { [isolation, echo, hiss, clarity, warmth, leveling, level].map { String(Int(($0 * 100).rounded())) }.joined(separator: "-") + (hum ? "-h" : "") }
    /// Volume de referência da fala (RMS): de ≈ -24 dBFS (0) a ≈ -15 dBFS (1).
    var targetRMS: Float { Float(0.06 + 0.12 * level) }

    static let presets: [(id: String, name: String, help: String, params: VoiceParams)] = [
        ("estudio", "Estúdio", "Equilíbrio: tira ruído e eco, voz clara e volume padronizado.", VoiceParams()),
        ("natural", "Natural", "Tratamento leve, mantém o som da sala.", VoiceParams(isolation: 0.4, echo: 0.2, hiss: 0.2, hum: false, clarity: 0.3, warmth: 0.2, leveling: 0.4, level: 0.5)),
        ("podcast", "Podcast (forte)", "Voz próxima, encorpada e alta, como em podcast.", VoiceParams(isolation: 0.9, echo: 0.5, hiss: 0.4, hum: true, clarity: 0.7, warmth: 0.55, leveling: 0.85, level: 0.75)),
        ("eco", "Sala com eco", "Para salas vazias ou com paredes lisas.", VoiceParams(isolation: 1, echo: 0.9, hiss: 0.3, hum: true, clarity: 0.6, warmth: 0.2, leveling: 0.6, level: 0.6)),
        ("baixa", "Gravação baixa", "Sobe o volume e a clareza de uma gravação fraca, sem estourar.", VoiceParams(isolation: 0.7, echo: 0.3, hiss: 0.5, hum: true, clarity: 0.65, warmth: 0.3, leveling: 0.85, level: 0.85)),
    ]
}

/// Voz de estúdio: isolamento de voz da Apple (AUSoundIsolation), filtro de zumbido, equalização (corpo, clareza, chiado),
/// expansor contra eco/ruído nas pausas, compressor, limitador e volume padronizado. Processa só o trecho usado e guarda o resultado.
enum VoiceStudio {
    /// O arquivo tratado pode começar depois do início do vídeo (só o trecho usado); o deslocamento vai no nome.
    static func offset(of url: URL) -> Double {
        guard let part = url.deletingPathExtension().lastPathComponent.components(separatedBy: "-o").last, let ms = Double(part) else { return 0 }
        return ms / 1000
    }

    private static func span(_ ranges: [Cut]?) -> (Double, Double)? {
        guard let ranges, let first = ranges.map(\.start).min(), let last = ranges.map(\.end).max() else { return nil }
        return (max(0, first - 1), last + 1)
    }
    private static func cacheURL(video: URL, params: VoiceParams, span: (Double, Double)?, directory: URL) -> URL {
        let modified = (try? video.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let spanKey = span.map { "\(Int($0.0 * 10))-\(Int($0.1 * 10))" } ?? "tudo"
        let key = "\(video.path)|\(modified)|\(params.signature)|\(spanKey)|v3"
        let offsetMs = Int((span?.0 ?? 0) * 1000)
        return directory.appendingPathComponent("voz-" + SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + "-o\(offsetMs).m4a")
    }
    /// Voz do vídeo inteiro já tratada com estes ajustes (botão "Aplicar no áudio do vídeo todo").
    static func wholeVideo(_ video: URL, params: VoiceParams, directory: URL) -> URL? {
        let url = cacheURL(video: video, params: params, span: nil, directory: directory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// ranges nil = o vídeo inteiro. Se o vídeo inteiro já foi tratado com os mesmos ajustes, reaproveita.
    static func process(video: URL, params: VoiceParams, ranges: [Cut]? = nil, directory: URL, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        let modified = (try? video.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        if let whole = wholeVideo(video, params: params, directory: directory) { return whole }
        let span = span(ranges)
        let cache = cacheURL(video: video, params: params, span: span, directory: directory)
        if FileManager.default.fileExists(atPath: cache.path) { return cache }
        let extracted = try await sourceAudio(video, modified: modified, directory: directory, status: status)
        let raw = directory.appendingPathComponent("voz-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: raw) }
        let rms = try await Task.detached(priority: .userInitiated) { try render(input: extracted, output: raw, params: params, span: span, status: status) }.value
        status("Voz de estúdio: ajustando o volume…")
        let gain = max(0.5, min(10, params.targetRMS / max(rms, 0.0005)))
        try await Task.detached(priority: .userInitiated) { try applyGain(input: raw, output: cache, gain: gain) }.value
        return cache
    }

    /// Áudio do vídeo extraído uma vez e guardado (antes era extraído a cada tratamento).
    private static func sourceAudio(_ video: URL, modified: Double, directory: URL, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        let name = "audio-" + SHA256.hash(data: Data("\(video.path)|\(modified)".utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".m4a"
        let cached = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        status("Voz de estúdio: separando o áudio do vídeo (só na primeira vez)…")
        let extracted = try await MediaEngine.audioFile(video, directory: directory)
        try? FileManager.default.moveItem(at: extracted, to: cached)
        return FileManager.default.fileExists(atPath: cached.path) ? cached : extracted
    }

    private static func effect(_ subtype: OSType) -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype,
                                                                              componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }

    /// Renderização offline da cadeia de efeitos no trecho pedido. Devolve o RMS dos trechos com fala.
    private static func render(input: URL, output: URL, params p: VoiceParams, span: (Double, Double)?, status: @escaping @Sendable (String) -> Void) throws -> Float {
        let file = try AVAudioFile(forReading: input)
        let sourceRate = file.processingFormat.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var chain: [AVAudioNode] = []
        // 1) Barulho de fundo: isolamento de voz da Apple.
        if p.isolation > 0.01 {
            let isolator = effect(0x766f6973 /* vois */)
            AudioUnitSetParameter(isolator.audioUnit, 0, kAudioUnitScope_Global, 0, AudioUnitParameterValue(p.isolation * 100), 0)
            // Modo "Voice" (1): nos testes com gravação real, o modo "High Quality Voice" (0) aumentou o ruído nas pausas.
            AudioUnitSetParameter(isolator.audioUnit, 1, kAudioUnitScope_Global, 0, 1, 0)
            chain.append(isolator)
        }
        // 2) Equalização: graves de ruído, zumbido, "caixa" de eco, corpo, clareza e chiado.
        let eq = AVAudioUnitEQ(numberOfBands: 10)
        func band(_ i: Int, _ type: AVAudioUnitEQFilterType, _ f: Float, _ bw: Float = 1, _ gain: Float = 0) {
            eq.bands[i].filterType = type; eq.bands[i].frequency = f; eq.bands[i].bandwidth = bw; eq.bands[i].gain = gain; eq.bands[i].bypass = false
        }
        band(0, .highPass, 80)
        if p.hum { band(1, .parametric, 60, 0.08, -24); band(2, .parametric, 120, 0.08, -18); band(3, .parametric, 180, 0.08, -12) } else { (1...3).forEach { eq.bands[$0].bypass = true } }
        band(4, .lowShelf, 160, 1, Float(5 * p.warmth))                                      // corpo
        band(5, .parametric, 380, 1.2, Float(-1.5 - 3.5 * p.echo - 1.5 * p.clarity))          // som de "caixa"/eco
        band(6, .parametric, 3400, 1.4, Float(6 * p.clarity))                                 // presença
        band(7, .parametric, 6500, 1.0, Float(-3 * p.hiss))                                   // sibilância/chiado
        band(8, .highShelf, 9000, 1, Float(1.5 * p.clarity - 9 * p.hiss))                     // ar x chiado
        band(9, .lowPass, Float(18000 - 7000 * p.hiss))
        chain.append(eq)
        // 3) Dinâmica: expansor contra eco/ruído nas pausas + compressor que iguala as falas.
        let dynamics = effect(kAudioUnitSubType_DynamicsProcessor)
        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, AudioUnitParameterValue(-14 - 16 * p.leveling), 0)
        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, AudioUnitParameterValue(8 - 4 * p.leveling), 0)
        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, AudioUnitParameterValue(0.18 - 0.1 * p.echo), 0)
        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, AudioUnitParameterValue(1 + 5 * p.leveling), 0)
        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, AudioUnitParameterValue(-55 + 17 * p.echo), 0)
        AudioUnitSetParameter(dynamics.audioUnit, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, AudioUnitParameterValue(1.5 + 3.5 * p.echo), 0)
        chain.append(dynamics)
        chain.append(effect(kAudioUnitSubType_PeakLimiter))
        chain.forEach { engine.attach($0) }
        var previous: AVAudioNode = player
        for node in chain { engine.connect(previous, to: node, format: format); previous = node }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        // Só o trecho pedido: posiciona a leitura no início e para no fim.
        let startFrame = AVAudioFramePosition(((span?.0 ?? 0) * sourceRate).rounded())
        let endFrame = min(file.length, span.map { AVAudioFramePosition(($0.1 * sourceRate).rounded()) } ?? file.length)
        file.framePosition = min(startFrame, file.length)
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let total = AVAudioFramePosition(Double(max(0, endFrame - startFrame)) * 48000 / sourceRate)
        var inputDone = false
        func nextBuffer() -> AVAudioPCMBuffer? {
            guard !inputDone else { return nil }
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            var error: NSError?
            let state = converter.convert(to: out, error: &error) { count, flag in
                let remaining = endFrame - file.framePosition
                guard remaining > 0 else { flag.pointee = .endOfStream; return nil }
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(count, AVAudioFrameCount(remaining)))!
                do { try file.read(into: buffer, frameCount: min(count, AVAudioFrameCount(remaining))) } catch { flag.pointee = .endOfStream; return nil }
                if buffer.frameLength == 0 { flag.pointee = .endOfStream; return nil }
                flag.pointee = .haveData; return buffer
            }
            if state == .endOfStream || state == .error { inputDone = true }
            return out.frameLength > 0 ? out : nil
        }
        var scheduled: AVAudioFramePosition = 0
        func feed() { if let b = nextBuffer() { scheduled += AVAudioFramePosition(b.frameLength); player.scheduleBuffer(b) } }
        for _ in 0..<4 { feed() }
        player.play()
        let writer = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var sum: Double = 0, count = 0, rendered: AVAudioFramePosition = 0, lastReport = 0
        while rendered < total {
            try Task.checkCancellation()
            while !inputDone && scheduled - rendered < 48000 * 3 { feed() }
            let frames = min(buffer.frameCapacity, AVAudioFrameCount(total - rendered))
            guard try engine.renderOffline(frames, to: buffer) == .success else { break }
            try writer.write(from: buffer)
            if let data = buffer.floatChannelData?[0] {
                // RMS por janela de ~85 ms, contando só janelas com fala (acima do ruído).
                var local: Float = 0
                for i in 0..<Int(buffer.frameLength) { local += data[i] * data[i] }
                let windowRMS = (local / Float(max(1, buffer.frameLength))).squareRoot()
                if windowRMS > 0.008 { sum += Double(local); count += Int(buffer.frameLength) }
            }
            rendered += AVAudioFramePosition(buffer.frameLength)
            let percent = Int(Double(rendered) / Double(max(1, total)) * 100)
            if percent >= lastReport + 5 { lastReport = percent; status("Voz de estúdio: \(percent)%") }
        }
        engine.stop()
        return count > 0 ? Float((sum / Double(count)).squareRoot()) : p.targetRMS
    }

    private static func applyGain(input: URL, output: URL, gain: Float) throws {
        let source = try AVAudioFile(forReading: input)
        let format = source.processingFormat
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 160_000]
        let tmp = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            let writer = try AVAudioFile(forWriting: tmp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            while source.framePosition < source.length {
                try source.read(into: buffer)
                guard buffer.frameLength > 0, let data = buffer.floatChannelData?[0] else { break }
                for i in 0..<Int(buffer.frameLength) {
                    // Ganho com teto suave: sobe o volume sem estourar (sem distorção nos picos).
                    let v = data[i] * gain
                    data[i] = abs(v) < 0.8 ? v : (v > 0 ? 1 : -1) * (0.8 + 0.18 * tanh((abs(v) - 0.8) / 0.18))
                }
                try writer.write(from: buffer)
            }
        }
        try FileManager.default.moveItem(at: tmp, to: output)
    }
}

/// Efeitos sonoros discretos gerados por síntese, sem depender de arquivos de terceiros.
enum SoundEffects {
    enum Kind: String { case whoosh, tick }
    static let whooshLength = 0.55, tickLength = 0.12
    static func file(_ kind: Kind) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CortaStudio-sfx", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(kind.rawValue)-v2.m4a")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let length = kind == .whoosh ? whooshLength : tickLength
        let frames = AVAudioFrameCount(48000 * length)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!; buffer.frameLength = frames
        let data = buffer.floatChannelData![0]
        var low: Float = 0, band: Float = 0
        var seed: UInt32 = 12345
        for i in 0..<Int(frames) {
            let t = Float(i) / 48000, k = t / Float(length)
            seed = seed &* 1664525 &+ 1013904223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            switch kind {
            case .whoosh:
                // Ruído filtrado com frequência subindo e envelope em sino.
                let cutoff = 0.02 + 0.25 * k
                low += cutoff * (noise - low); band += cutoff * (low - band)
                data[i] = (low - band) * sin(.pi * k) * sin(.pi * k) * 2.2
            case .tick:
                data[i] = sin(2 * .pi * (1400 - 600 * k) * t) * exp(-t * 38) * 0.6
            }
        }
        let tmp = dir.appendingPathComponent(UUID().uuidString + ".m4a")
        do {
            let file = try AVAudioFile(forWriting: tmp, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000],
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
        return url
    }
}
