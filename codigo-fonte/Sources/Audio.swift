import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit

/// Voz de estúdio: isolamento de voz da Apple (AUSoundIsolation, o mesmo princípio do "Isolamento de voz" do Final Cut),
/// filtro de graves, presença, compressor, limitador e volume padronizado. Processado uma vez por vídeo e reaproveitado.
enum VoiceStudio {
    static let targetRMS: Float = 0.10   // ≈ -20 dBFS na fala; o limitador segura os picos

    static func process(video: URL, isolation: Double, directory: URL, status: @escaping @Sendable (String) -> Void) async throws -> URL {
        let key = "\(video.path)|\((try? video.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0)|\(Int(isolation * 100))|v2"
        let name = "voz-" + SHA256.hash(data: Data(key.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + ".m4a"
        let cache = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: cache.path) { return cache }
        status("Voz de estúdio: separando o áudio…")
        let extracted = try await MediaEngine.audioFile(video, directory: directory)
        defer { try? FileManager.default.removeItem(at: extracted) }
        let raw = directory.appendingPathComponent("voz-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: raw) }
        let rms = try await Task.detached(priority: .userInitiated) { try render(input: extracted, output: raw, isolation: isolation, status: status) }.value
        status("Voz de estúdio: ajustando o volume…")
        let gain = max(0.6, min(6, targetRMS / max(rms, 0.0005)))
        try await Task.detached(priority: .userInitiated) { try applyGain(input: raw, output: cache, gain: gain) }.value
        return cache
    }

    /// Renderização offline da cadeia de efeitos. Devolve o RMS dos trechos com fala.
    private static func render(input: URL, output: URL, isolation: Double, status: @escaping @Sendable (String) -> Void) throws -> Float {
        let file = try AVAudioFile(forReading: input)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var chain: [AVAudioNode] = []
        if isolation > 0.01 {
            let isolator = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x766f6973 /* vois */,
                                                                                               componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            AudioUnitSetParameter(isolator.audioUnit, 0, kAudioUnitScope_Global, 0, AudioUnitParameterValue(isolation * 100), 0)
            // Modo "Voice" (1): nos testes com gravação real, o modo "High Quality Voice" (0) aumentou o ruído nas pausas.
            AudioUnitSetParameter(isolator.audioUnit, 1, kAudioUnitScope_Global, 0, 1, 0)
            chain.append(isolator)
        }
        let eq = AVAudioUnitEQ(numberOfBands: 3)
        eq.bands[0].filterType = .highPass; eq.bands[0].frequency = 80; eq.bands[0].bypass = false
        eq.bands[1].filterType = .parametric; eq.bands[1].frequency = 300; eq.bands[1].bandwidth = 1.2; eq.bands[1].gain = -2; eq.bands[1].bypass = false
        eq.bands[2].filterType = .parametric; eq.bands[2].frequency = 3500; eq.bands[2].bandwidth = 1.5; eq.bands[2].gain = 2; eq.bands[2].bypass = false
        chain.append(eq)
        let compressor = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                                                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0, -22, 0)
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0, 6, 0)
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.005, 0)
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.12, 0)
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0, 3, 0)
        // Expansor suave: abaixa o ruído de sala nas pausas sem cortar finais de palavra.
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, -50, 0)
        AudioUnitSetParameter(compressor.audioUnit, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 2, 0)
        chain.append(compressor)
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                                                                                          componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        chain.append(limiter)
        chain.forEach { engine.attach($0) }
        var previous: AVAudioNode = player
        for node in chain { engine.connect(previous, to: node, format: format); previous = node }
        engine.connect(previous, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()
        // Converte a entrada para mono 48 kHz e agenda no player.
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let total = AVAudioFramePosition(Double(file.length) * 48000 / file.processingFormat.sampleRate)
        var inputDone = false
        func nextBuffer() -> AVAudioPCMBuffer? {
            guard !inputDone else { return nil }
            let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
            var error: NSError?
            let state = converter.convert(to: out, error: &error) { count, flag in
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                do { try file.read(into: buffer, frameCount: count) } catch { flag.pointee = .endOfStream; return nil }
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
            let percent = Int(Double(rendered) / Double(total) * 100)
            if percent >= lastReport + 5 { lastReport = percent; status("Voz de estúdio: \(percent)%") }
        }
        engine.stop()
        return count > 0 ? Float((sum / Double(count)).squareRoot()) : targetRMS
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
