import AppKit
import AVFoundation
import Speech
import CoreImage
import CoreText
import Vision

struct MediaInfo {
    var duration: Double
    var size: CGSize
    var frameRate: Float
}

enum MediaEngine {
    /// Narração só em áudio (m4a, mp3, wav…): vira um vídeo vertical escuro com o mesmo som, para ser editado como qualquer vídeo.
    static func videoFromAudio(_ audioURL: URL, into folder: URL) async throws -> URL {
        let audioAsset = AVURLAsset(url: audioURL)
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else { throw StudioError("Esse arquivo não tem áudio.") }
        let duration = try await audioAsset.load(.duration)
        guard duration.seconds > 1 else { throw StudioError("A narração é curta demais.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // 1) Um segundo de imagem escura (1080 × 1920).
        let still = folder.appendingPathComponent(".base-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: still, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1080, AVVideoHeightKey: 1920])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1080, kCVPixelBufferHeightKey as String: 1920])
        writer.add(input); writer.startWriting(); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1080, 1920, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw StudioError("Não foi possível preparar o vídeo da narração.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            let bytes = CVPixelBufferGetBytesPerRow(buffer) * 1920
            let p = base.bindMemory(to: UInt8.self, capacity: bytes)
            for i in stride(from: 0, to: bytes, by: 4) { p[i] = 22; p[i + 1] = 24; p[i + 2] = 28; p[i + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for t in [0.0, 0.5] {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 10_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600))
        }
        input.markAsFinished(); writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
        await writer.finishWriting()
        defer { try? FileManager.default.removeItem(at: still) }
        // 2) Repete a imagem pela duração do áudio e junta a narração.
        let stillAsset = AVURLAsset(url: still)
        guard let stillTrack = try await stillAsset.loadTracks(withMediaType: .video).first else { throw StudioError("Não foi possível preparar o vídeo da narração.") }
        let composition = AVMutableComposition()
        guard let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError("Falha ao montar a narração.") }
        let one = try await stillTrack.load(.timeRange)
        var at = CMTime.zero
        while at < duration {
            let piece = CMTimeMinimum(one.duration, duration - at)
            try v.insertTimeRange(CMTimeRange(start: one.start, duration: piece), of: stillTrack, at: at)
            at = at + piece
        }
        try a.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: .zero)
        let name = audioURL.deletingPathExtension().lastPathComponent + " (narração).mov"
        let out = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: out)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw StudioError("Falha ao exportar a narração.") }
        session.outputURL = out; session.outputFileType = .mov
        try await runExport(session) { _ in }
        return out
    }

    static func info(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw StudioError("O macOS não consegue reproduzir este arquivo. Use um vídeo MOV ou MP4 compatível e confirme que ele foi baixado do iCloud.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw StudioError("Não foi possível abrir o vídeo. Use um arquivo MOV ou MP4 válido.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform)
        guard display.width.isFinite, display.height.isFinite, abs(display.width) >= 1, abs(display.height) >= 1 else {
            throw StudioError("O arquivo não contém dimensões de vídeo válidas.")
        }
        return MediaInfo(duration: duration, size: CGSize(width: abs(display.width), height: abs(display.height)), frameRate: try await track.load(.nominalFrameRate))
    }

    static func runExport(_ session: AVAssetExportSession, progress: @escaping @Sendable (Double) -> Void) async throws {
        let monitor = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { monitor.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    switch session.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: session.error ?? StudioError("A exportação não foi concluída."))
                    }
                }
            }
        } onCancel: { session.cancelExport() }
        try Task.checkCancellation()
        progress(1)
    }

    static func audioFile(_ url: URL, directory: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw StudioError("Este vídeo não contém áudio. Você pode importar legendas SRT ou editar sem legendas.") }
        let dest = directory.appendingPathComponent("audio-\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { throw StudioError("Não foi possível preparar o áudio.") }
        session.outputURL = dest; session.outputFileType = .m4a
        try await runExport(session, progress: { _ in })
        return dest
    }

    @available(macOS 26.0, *)
    static func transcribe(_ url: URL, directory: URL, status: @escaping @Sendable (String) -> Void) async throws -> [Caption] {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "pt-BR")) else {
            throw StudioError("A transcrição local em português não está disponível neste Mac. Você ainda pode importar um arquivo SRT.")
        }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let alreadyReserved = await AssetInventory.reservedLocales.contains(locale)
        if !alreadyReserved { _ = try await AssetInventory.reserve(locale: locale) }
        defer {
            if !alreadyReserved { Task { await AssetInventory.release(reservedLocale: locale) } }
        }
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            status("Preparando português no Mac. O primeiro uso pode baixar o modelo da Apple…")
            let reporter = Task {
                while !Task.isCancelled {
                    let p = install.progress
                    status(p.totalUnitCount > 0 ? "Baixando modelo local: \(Int(p.fractionCompleted * 100))%" : "Baixando o modelo de português da Apple…")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            defer { reporter.cancel() }
            try await install.downloadAndInstall()
        }
        try Task.checkCancellation()
        status("Preparando o áudio…")
        let audioURL = try await audioFile(url, directory: directory)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let audio = try AVAudioFile(forReading: audioURL)
        let analyzer = SpeechAnalyzer(modules: [module])
        let collector = Task { () throws -> [Caption] in
            var captions: [Caption] = []
            for try await result in module.results {
                try Task.checkCancellation()
                var words: [(String, Double, Double)] = []
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty, let range = run.audioTimeRange {
                        words.append((text, range.start.seconds, CMTimeRangeGetEnd(range).seconds))
                    }
                }
                if words.isEmpty {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { words = [(text, result.range.start.seconds, CMTimeRangeGetEnd(result.range).seconds)] }
                }
                var group: [(String, Double, Double)] = []
                func flush() {
                    guard let first = group.first, let last = group.last, last.2 > first.1 else { group.removeAll(); return }
                    captions.append(Caption(id: captions.count, start: first.1, end: last.2, text: group.map { $0.0 }.joined(separator: " "),
                                            words: group.map { Word(text: $0.0, start: $0.1, end: $0.2) }))
                    group.removeAll()
                }
                for word in words {
                    if !group.isEmpty && (group.map { $0.0.count + 1 }.reduce(0, +) + word.0.count > 48 || word.2 - group[0].1 > 3.8) { flush() }
                    group.append(word)
                    if word.0.last.map({ ".!?".contains($0) }) == true { flush() }
                }
                flush()
                status("Transcrevendo no Mac: \(clockLabel(CMTimeRangeGetEnd(result.range).seconds)) de áudio…")
            }
            return captions
        }
        return try await withTaskCancellationHandler {
            do {
                status("Transcrevendo em português no Mac…")
                try await analyzer.start(inputAudioFile: audio, finishAfterFile: true)
                let captions = try await collector.value
                guard !captions.isEmpty else { throw StudioError("Não encontrei fala reconhecível. Confira o áudio ou importe uma legenda SRT.") }
                return captions
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    static func findFace(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) else {
            throw StudioError("Não encontrei um rosto no início do vídeo. Ajuste a posição manualmente.")
        }
        return face.boundingBox.midX
    }

    /// Acompanha o rosto principal amostrando um quadro por segundo; devolve posições horizontais suavizadas (0…1).
    /// Rosto só nos trechos pedidos (ex.: os do corte aberto), juntando com o que já se conhece e guardando em disco.
    static func trackFace(_ url: URL, ranges: [Cut], known: [FacePoint], status: @escaping @Sendable (String) -> Void) async throws -> [FacePoint] {
        let missing = ranges.filter { r in !known.contains { $0.time >= r.start - 2.5 && $0.time <= r.end + 2.5 } }
        guard !missing.isEmpty else { return known }
        var found: [FacePoint] = []
        for (i, r) in missing.enumerated() {
            status("Acompanhando o rosto no corte: \(i + 1) de \(missing.count)…")
            if let points = try? await trackFace(url, duration: r.end, from: max(0, r.start - 1), step: 1) { found += points }
        }
        let merged = (known + found).sorted { $0.time < $1.time }
        saveFaceCache(url, merged)
        return merged
    }
    private static func faceCacheURL(_ url: URL) -> URL {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        return Studio.cacheDirectory.appendingPathComponent("rosto-" + SHA256Hex.of("\(url.path)|\(modified)|face-v1") + ".json")
    }
    static func loadFaceCache(_ url: URL) -> [FacePoint] {
        (try? JSONDecoder().decode([FacePoint].self, from: Data(contentsOf: faceCacheURL(url)))) ?? []
    }
    static func saveFaceCache(_ url: URL, _ points: [FacePoint]) {
        try? JSONEncoder().encode(points).write(to: faceCacheURL(url), options: .atomic)
    }
    static func trackFace(_ url: URL, duration: Double, from start: Double = 0, step fixedStep: Double? = nil, status: @escaping @Sendable (String) -> Void = { _ in }) async throws -> [FacePoint] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let step = fixedStep ?? (duration > 900 ? 2.0 : 1.0)
        let times = stride(from: start + 0.2, to: max(start + 0.3, duration), by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var raw: [FacePoint] = []
        var done = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            done += 1
            if done % 10 == 0 { status("Acompanhando o rosto: \(Int(Double(done) / Double(times.count) * 100))%") }
            guard let image = try? result.image else { continue }
            let request = VNDetectFaceRectanglesRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request])
            if let face = request.results?.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }) {
                raw.append(FacePoint(time: result.requestedTime.seconds, x: face.boundingBox.midX))
            }
        }
        guard !raw.isEmpty else { throw StudioError("Não encontrei rosto ao longo do vídeo. Ajuste a posição manualmente.") }
        // Suavização: zona morta para pequenos movimentos e média móvel para evitar saltos.
        var steady: [FacePoint] = []; var current = raw[0].x
        for point in raw {
            if abs(point.x - current) > 0.06 { current = point.x }
            steady.append(FacePoint(time: point.time, x: current))
        }
        return steady.indices.map { i in
            let window = steady[max(0, i - 2)...min(steady.count - 1, i + 2)]
            return FacePoint(time: steady[i].time, x: window.map(\.x).reduce(0, +) / Double(window.count))
        }
    }

    struct Composed {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let audioMix: AVAudioMix?
        let painter: FramePainter
        let keepAlive: [AVAsset]
    }

    static func render(source: URL, support: URL?, timeline: Timeline, settings: EditSettings, effects: [Effect] = [], faceTrack: [FacePoint] = [], voice: URL? = nil,
                       transitions: [TransitionMark] = [], destination: URL, preview: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        let built = try await compose(source: source, support: support, timeline: timeline, settings: settings, effects: effects, faceTrack: faceTrack, voice: voice, transitions: transitions, preview: preview)
        guard let exporter = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else { throw StudioError("Não foi possível iniciar a exportação.") }
        exporter.outputURL = destination
        exporter.outputFileType = .mp4
        exporter.videoComposition = built.videoComposition
        exporter.audioMix = built.audioMix
        exporter.shouldOptimizeForNetworkUse = true
        do { try await runExport(exporter, progress: progress) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        withExtendedLifetime(built.keepAlive) {}
    }

    /// Monta a edição (vídeo, áudio e efeitos). A mesma montagem toca ao vivo no player e é usada na exportação.
    static func compose(source: URL, support: URL?, timeline: Timeline, settings: EditSettings, effects: [Effect] = [], faceTrack: [FacePoint] = [], voice: URL? = nil,
                        transitions: [TransitionMark] = [], preview: Bool) async throws -> Composed {
        var keepAlive: [AVAsset] = []
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw StudioError("Vídeo indisponível.") }
        var audio = try await asset.loadTracks(withMediaType: .audio).first
        let voiceAsset = voice.map { AVURLAsset(url: $0) }
        var voiceOffset = 0.0
        if let voiceAsset, let track = try await voiceAsset.loadTracks(withMediaType: .audio).first {
            keepAlive.append(voiceAsset); audio = track; voiceOffset = VoiceStudio.offset(of: voiceAsset.url)
        }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError("Não foi possível preparar a edição.") }
        let audioTrack = audio != nil ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil
        videoTrack.preferredTransform = try await video.load(.preferredTransform)
        let audioRange = try await audio?.load(.timeRange)
        defer { withExtendedLifetime(voiceAsset) {} }
        var cursor = CMTime.zero
        for cut in timeline.cuts {
            try Task.checkCancellation()
            let range = CMTimeRange(start: CMTime(seconds: cut.start, preferredTimescale: 60000), duration: CMTime(seconds: cut.duration, preferredTimescale: 60000))
            try videoTrack.insertTimeRange(range, of: video, at: cursor)
            if let audio, let audioRange, let audioTrack {
                // A voz tratada pode começar depois do início do vídeo (só o trecho usado): desloca a leitura.
                let shift = CMTime(seconds: voiceOffset, preferredTimescale: 60000)
                let wanted = CMTimeRange(start: range.start - shift, duration: range.duration)
                let available = CMTimeRangeGetIntersection(wanted, otherRange: audioRange)
                if available.duration.seconds > 0 {
                    try audioTrack.insertTimeRange(available, of: audio, at: cursor + available.start - wanted.start)
                }
            }
            cursor = cursor + range.duration
        }
        let total = cursor.seconds
        // Áudio: fade da voz, música de fundo em loop com redução automática durante a fala.
        var mixInputs: [AVMutableAudioMixInputParameters] = []
        if let audioTrack, settings.fadeInOut || abs(settings.voiceVolume - 1) > 0.01 {
            let voice = AVMutableAudioMixInputParameters(track: audioTrack)
            let gain = settings.voiceVolume, fade = settings.fadeInOut
            applyRamps(voice, total: total) { t in gain * (fade ? min(1, t / 0.35, (total - t) / 0.5) : 1) }
            mixInputs.append(voice)
        }
        if let musicURL = Library.file(settings.musicFile, in: Library.music) {
            let music = AVURLAsset(url: musicURL); keepAlive.append(music)
            if let musicSource = try await music.loadTracks(withMediaType: .audio).first,
               let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let length = try await music.load(.duration)
                guard length.seconds > 0.5 else { throw StudioError("A música escolhida é curta demais.") }
                var at = CMTime.zero
                while at.seconds < total - 0.01 {
                    let piece = CMTimeMinimum(length, CMTime(seconds: total, preferredTimescale: 60000) - at)
                    try musicTrack.insertTimeRange(CMTimeRange(start: .zero, duration: piece), of: musicSource, at: at)
                    at = at + piece
                }
                var speech: [(Double, Double)] = []
                for cue in timeline.captions {
                    if let last = speech.last, cue.start - last.1 < 1.0 { speech[speech.count - 1].1 = max(last.1, cue.end) } else { speech.append((cue.start, cue.end)) }
                }
                let high = settings.musicVolume, low = settings.musicVolume * 0.28
                let params = AVMutableAudioMixInputParameters(track: musicTrack)
                let breaks = speech.flatMap { [$0.0 - 0.3, $0.0, $0.1, $0.1 + 0.4] }
                applyRamps(params, total: total, extra: breaks) { t in
                    var level = high
                    if settings.ducking {
                        for (s, e) in speech {
                            let v: Double
                            if t >= s && t <= e { v = low }
                            else if t > s - 0.3 && t < s { v = high - (high - low) * (t - (s - 0.3)) / 0.3 }
                            else if t > e && t < e + 0.4 { v = low + (high - low) * (t - e) / 0.4 }
                            else { continue }
                            level = min(level, v)
                        }
                    }
                    return level * max(0, min(1, t / 0.8, (total - t) / 1.5))
                }
                mixInputs.append(params)
            }
        }
        let placed = effects.flatMap { effect in timeline.outputRanges(start: effect.start, end: effect.end).map { PlacedEffect(effect: effect, start: $0.0, end: $0.1) } }
        // Efeitos sonoros sutis, sintetizados (sem arquivos de terceiros): "whoosh" em zooms e imagens, "toque" em textos.
        if settings.soundEffects, !placed.isEmpty, let sfxTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let whoosh = try SoundEffects.file(.whoosh), tick = try SoundEffects.file(.tick)
            // Os AVAsset precisam continuar vivos: a faixa guarda só uma referência fraca a eles.
            let whooshAsset = AVURLAsset(url: whoosh), tickAsset = AVURLAsset(url: tick); keepAlive += [whooshAsset, tickAsset]
            let whooshTrack = try await whooshAsset.loadTracks(withMediaType: .audio)[0], tickTrack = try await tickAsset.loadTracks(withMediaType: .audio)[0]
            let whooshRange = try await whooshTrack.load(.timeRange), tickRange = try await tickTrack.load(.timeRange)
            var busyUntil = -1.0
            for item in placed.sorted(by: { $0.start < $1.start }) {
                let source = item.effect.kind == .texto ? tickTrack : whooshTrack
                let range = item.effect.kind == .texto ? tickRange : whooshRange
                let length = range.duration.seconds
                let at = max(0, item.start - (item.effect.kind == .texto ? 0 : length * 0.6))
                guard at > busyUntil + 0.05, at + length < total else { continue }
                let position = CMTime(seconds: at, preferredTimescale: 48000)
                let trackEnd = sfxTrack.timeRange.end.isValid ? sfxTrack.timeRange.end : .zero
                if position > trackEnd { sfxTrack.insertEmptyTimeRange(CMTimeRange(start: trackEnd, end: position)) }
                try sfxTrack.insertTimeRange(range, of: source, at: position)
                busyUntil = at + length
            }
            let p = AVMutableAudioMixInputParameters(track: sfxTrack); p.setVolume(0.35, at: .zero); mixInputs.append(p)
            withExtendedLifetime((whooshAsset, tickAsset)) {}
        }
        let size = settings.vertical ? CGSize(width: preview ? 540 : 1080, height: preview ? 960 : 1920) : CGSize(width: preview ? 960 : 1920, height: preview ? 540 : 1080)
        let painter = FramePainter(size: size, timeline: timeline, settings: settings, support: support, effects: placed, faceTrack: faceTrack, transitions: transitions)
        // Vídeos de apoio (b-roll): cada um numa faixa própria, posicionada no tempo da edição, sem áudio.
        var brollTracks: [UUID: CMPersistentTrackID] = [:], brollTransforms: [UUID: CGAffineTransform] = [:]
        for item in placed where item.effect.kind == .video {
            guard brollTracks[item.effect.id] == nil, let url = Library.file(item.effect.asset, in: Library.videos) else { continue }
            let clip = AVURLAsset(url: url); keepAlive.append(clip)
            guard let clipTrack = try? await clip.loadTracks(withMediaType: .video).first,
                  let range = try? await clipTrack.load(.timeRange), range.duration.seconds > 0.2,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let firstRange = timeline.outputRanges(start: item.effect.start, end: item.effect.end)
            guard let first = firstRange.first, let last = firstRange.last else { continue }
            let start = CMTime(seconds: first.0, preferredTimescale: 60000)
            if start.seconds > 0.001 { track.insertEmptyTimeRange(CMTimeRange(start: .zero, duration: start)) }
            var at = start, remaining = last.1 - first.0
            while remaining > 0.04 {   // repete o clipe se ele for mais curto que o trecho
                let piece = min(remaining, range.duration.seconds)
                try track.insertTimeRange(CMTimeRange(start: range.start, duration: CMTime(seconds: piece, preferredTimescale: 60000)), of: clipTrack, at: at)
                at = at + CMTime(seconds: piece, preferredTimescale: 60000); remaining -= piece
            }
            brollTracks[item.effect.id] = track.trackID
            brollTransforms[item.effect.id] = (try? await clipTrack.load(.preferredTransform)) ?? .identity
        }
        let videoComposition: AVMutableVideoComposition
        if brollTracks.isEmpty {
            videoComposition = AVMutableVideoComposition(asset: composition) { request in
                autoreleasepool {
                    let image = painter.frame(request.sourceImage, at: request.compositionTime.seconds)
                    request.finish(with: image, context: painter.context)
                }
            }
        } else {
            videoComposition = AVMutableVideoComposition()
            videoComposition.customVideoCompositorClass = BrollCompositor.self
            videoComposition.instructions = [BrollInstruction(timeRange: CMTimeRange(start: .zero, duration: composition.duration), painter: painter,
                                                              mainTrack: videoTrack.trackID, mainTransform: videoTrack.preferredTransform,
                                                              brollTracks: brollTracks, brollTransforms: brollTransforms)]
        }
        videoComposition.renderSize = size
        let originalRate = try await video.load(.nominalFrameRate)
        let rate = max(1, min(Double(originalRate > 0 ? originalRate : 30), Double(settings.fpsLimit)))
        videoComposition.frameDuration = CMTime(seconds: 1 / rate, preferredTimescale: 60000)
        var mix: AVMutableAudioMix?
        if !mixInputs.isEmpty { mix = AVMutableAudioMix(); mix!.inputParameters = mixInputs }
        keepAlive.append(asset)
        return Composed(composition: composition, videoComposition: videoComposition, audioMix: mix, painter: painter, keepAlive: keepAlive)
    }

    /// Converte uma curva de volume em rampas lineares contínuas, sem sobreposição.
    private static func applyRamps(_ params: AVMutableAudioMixInputParameters, total: Double, extra: [Double] = [], volume: (Double) -> Double) {
        var points = Set([0, 0.35, 0.8, total - 1.5, total - 0.5, total].map { ($0 * 1000).rounded() / 1000 })
        for t in extra { points.insert((t * 1000).rounded() / 1000) }
        let times = points.filter { $0 >= 0 && $0 <= total }.sorted()
        for (a, b) in zip(times, times.dropFirst()) where b - a > 0.001 {
            let range = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 60000), end: CMTime(seconds: b, preferredTimescale: 60000))
            params.setVolumeRamp(fromStartVolume: Float(max(0, volume(a))), toEndVolume: Float(max(0, volume(b))), timeRange: range)
        }
    }
}

final class StyledText { let image: CIImage; let box: CGRect; init(image: CIImage, box: CGRect) { self.image = image; self.box = box } }

struct FacePoint: Codable, Equatable {
    var time: Double
    var x: Double
}

final class FramePainter: @unchecked Sendable {
    let size: CGSize
    let timeline: Timeline
    let settings: EditSettings
    let context = CIContext(options: [.cacheIntermediates: false])
    let textCache = NSCache<NSString, CIImage>()
    let styledCache = NSCache<NSString, StyledText>()
    private let supportImage: CIImage?
    private let cutStarts: [Double]
    let effects: [PlacedEffect]
    private let faceTrack: [FacePoint]
    private var images: [String: CIImage] = [:]
    private let logo: CIImage?
    private let junctions: [(time: Double, sourceTime: Double, type: String, duration: Double)]
    private let gaze: GazeCorrector?

    static let gold = NSColor(red: 0.83, green: 0.66, blue: 0.29, alpha: 1)
    static let cream = NSColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1)
    static let ink = NSColor(red: 0.10, green: 0.09, blue: 0.08, alpha: 1)

    init(size: CGSize, timeline: Timeline, settings: EditSettings, support: URL?, effects: [PlacedEffect] = [], faceTrack: [FacePoint] = [], transitions: [TransitionMark] = []) {
        self.size = size; self.timeline = timeline; self.settings = settings; self.effects = effects; self.faceTrack = faceTrack
        supportImage = support.flatMap { Self.load($0) }
        textCache.countLimit = 40
        var offset = 0.0
        cutStarts = timeline.cuts.map { cut in defer { offset += cut.duration }; return offset }
        junctions = timeline.junctions(settings: settings, marks: transitions).filter { $0.type != "corte" }
        for effect in effects where effect.effect.kind == .imagem && images[effect.effect.asset] == nil {
            if let url = Library.file(effect.effect.asset, in: Library.images), let image = Self.load(url) { images[effect.effect.asset] = image }
        }
        logo = settings.watermark ? Library.logo.flatMap { Self.load($0) } : nil
        gaze = settings.eyeContact ? GazeCorrector(strength: settings.eyeContactStrength) : nil
    }
    /// Máscara da pessoa (branco = pessoa), no tamanho da imagem.
    func personMask(_ image: CIImage) -> CIImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        return mask.transformed(by: CGAffineTransform(scaleX: image.extent.width / mask.extent.width, y: image.extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2]).cropped(to: image.extent)
    }
    /// Tremor de câmera: deslocamento e leve rotação pseudoaleatórios.
    func shake(_ image: CIImage, strength: Double, time: Double) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let dx = CGFloat(sin(time * 53) * cos(time * 31)) * size.width * 0.014 * CGFloat(strength)
        let dy = CGFloat(cos(time * 47) * sin(time * 23)) * size.width * 0.014 * CGFloat(strength)
        let angle = CGFloat(sin(time * 37)) * 0.012 * CGFloat(strength)
        let z = 1 + 0.05 * CGFloat(strength)
        return image.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2).concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(scaleX: z, y: z)).concatenating(CGAffineTransform(translationX: size.width / 2 + dx, y: size.height / 2 + dy))).clampedToExtent().cropped(to: bounds)
    }
    /// Glitch: separação de canais de cor e faixas deslocadas, mudando ~12 vezes por segundo.
    func glitch(_ image: CIImage, strength: Double, time: Double) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let step = Int(time * 12)
        func rnd(_ n: Int) -> Double { let x = sin(Double(step * 127 + n * 311)) * 43758.5453; return x - floor(x) }
        let off = size.width * 0.012 * CGFloat(strength) * CGFloat(0.5 + rnd(1))
        // Canais separados: vermelho para um lado, azul para o outro.
        let solid = image.clampedToExtent()
        func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat, _ dx: CGFloat) -> CIImage {
            solid.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                                                               "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
        }
        // Máximo por canal: (R,0,0) ∨ (0,G,0) ∨ (0,0,B) = (R,G,B), cada canal deslocado.
        let shifted = channel(1, 0, 0, 1, off).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(0, 1, 0, 1, 0)])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: channel(0, 0, 1, 1, -off)])
        var out = shifted.cropped(to: bounds)
        for n in 0..<3 where rnd(10 + n) < 0.75 * strength {
            let h = size.height * CGFloat(0.02 + 0.06 * rnd(20 + n)), y = size.height * CGFloat(rnd(30 + n))
            let band = CGRect(x: 0, y: y, width: size.width, height: h)
            let dx = size.width * 0.06 * CGFloat(strength) * CGFloat(rnd(40 + n) - 0.5) * 2
            out = shifted.cropped(to: band.offsetBy(dx: -dx, dy: 0)).transformed(by: CGAffineTransform(translationX: dx, y: 0)).cropped(to: band).composited(over: out)
        }
        return out
    }
    /// Textura de grão para o efeito filme (gerada uma vez).
    static let grain: CGImage = {
        let w = 256, h = 256
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 7
        for i in 0..<(w * h) { seed = seed &* 1664525 &+ 1013904223; let v = UInt8(seed >> 24); pixels[i * 4] = v; pixels[i * 4 + 1] = v; pixels[i * 4 + 2] = v; pixels[i * 4 + 3] = 255 }
        let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()
    /// Modo retrato: separa a pessoa do fundo (Vision) e desfoca só o fundo.
    private func portrait(_ image: CIImage) -> CIImage {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return image }
        var mask = CIImage(cvPixelBuffer: buffer)
        mask = mask.transformed(by: CGAffineTransform(scaleX: image.extent.width / mask.extent.width, y: image.extent.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX, y: image.extent.minY))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2]).cropped(to: image.extent)
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: image.extent.width * 0.012]).cropped(to: image.extent)
        return image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: blurred, kCIInputMaskImageKey: mask])
    }
    static func load(_ url: URL) -> CIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1920, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return CIImage(cgImage: thumbnail)
    }

    func fit(_ source: CIImage, into rect: CGRect, fill: Bool, zoom: Double = 1, focus: Double = 0.5, focusY: Double = 0.5) -> CIImage {
        let normalized = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        let scale = (fill ? max(rect.width / source.extent.width, rect.height / source.extent.height) : min(rect.width / source.extent.width, rect.height / source.extent.height)) * zoom
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        func place(_ length: CGFloat, _ slot: CGFloat, _ minimum: CGFloat, _ f: Double) -> CGFloat {
            if length <= slot { return minimum + (slot - length) / 2 }
            return min(minimum, max(minimum + slot - length, minimum + slot / 2 - CGFloat(f) * length))
        }
        let x = place(scaled.extent.width, rect.width, rect.minX, focus)
        let y = place(scaled.extent.height, rect.height, rect.minY, focusY)
        return scaled.transformed(by: CGAffineTransform(translationX: x, y: y)).cropped(to: rect)
    }

    private func sourceTime(_ time: Double) -> Double {
        guard let index = cutStarts.lastIndex(where: { $0 <= time }) else { return time }
        return timeline.cuts[index].start + (time - cutStarts[index])
    }
    private func focus(at time: Double) -> Double {
        guard settings.fillFrame, !faceTrack.isEmpty else { return settings.horizontalFocus }
        let t = sourceTime(time)
        guard let after = faceTrack.firstIndex(where: { $0.time >= t }) else { return faceTrack.last!.x }
        guard after > 0 else { return faceTrack[0].x }
        let a = faceTrack[after - 1], b = faceTrack[after]
        let k = (t - a.time) / max(0.001, b.time - a.time)
        let eased = k * k * (3 - 2 * k)
        return a.x + (b.x - a.x) * eased
    }
    func faded(_ image: CIImage, _ alpha: Double) -> CIImage {
        guard alpha < 0.999 else { return image }
        let a = CGFloat(max(0, alpha))
        return image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                                                                  "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }
    /// Entrada e saída suaves de um efeito.
    private func envelope(_ effect: PlacedEffect, at time: Double, fade: Double = 0.3) -> Double {
        let d = min(fade, (effect.end - effect.start) / 3)
        return max(0, min(1, (time - effect.start) / d, (effect.end - time) / d))
    }
    private func grade(_ image: CIImage) -> CIImage {
        switch settings.colorLook {
        case "Ethos clássico":
            return image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 5600, y: 0)])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.88, kCIInputContrastKey: 1.06, kCIInputBrightnessKey: 0.0])
        case "Cinema":
            return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.82, kCIInputContrastKey: 1.12, kCIInputBrightnessKey: -0.02])
                .applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6900, y: 8)])
        case "Preto e branco":
            return image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0, kCIInputContrastKey: 1.15, kCIInputBrightnessKey: 0.0])
        case "Vívido suave":
            return image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.35])
        default: return image
        }
    }

    func frame(_ original: CIImage, at time: Double, videos: [UUID: CIImage] = [:]) -> CIImage {
        var source = original
        if let gaze { source = gaze.apply(source, at: sourceTime(time)) }
        if settings.portraitBlur { source = portrait(source) }
        let bounds = CGRect(origin: .zero, size: size)
        var output = CIImage(color: CIColor(red: 0.035, green: 0.035, blue: 0.035)).cropped(to: bounds)
        let start = cutStarts.last(where: { $0 <= time }) ?? 0
        let cycle = max(4, settings.zoomCycle)
        let phase = (time - start).truncatingRemainder(dividingBy: cycle)
        let amplitude = settings.style == "Intenso" ? 0.10 : (settings.style == "Dinâmico" ? 0.07 : 0.035)
        var zoom = settings.zoom ? 1 + amplitude * (1 - cos(phase / cycle * .pi * 2)) / 2 : 1
        // Transição ativa: u vai de -1 (fim do trecho anterior) a 1 (começo do seguinte); k é a intensidade (1 na junção).
        var transition: (type: String, u: Double, k: Double)?
        if let j = junctions.first(where: { abs(time - $0.time) < $0.duration / 2 }) {
            let u = (time - j.time) / (j.duration / 2)
            transition = (j.type, u, 1 - abs(u))
        }
        if let tr = transition, tr.type == "zoom" { zoom *= 1 + 0.45 * tr.k * tr.k }
        for effect in effects where effect.effect.kind == .zoom && time >= effect.start && time <= effect.end {
            zoom *= effect.effect.zoomFactor(at: time - effect.start, duration: effect.end - effect.start)
        }
        let fx = focus(at: time)
        let focusY = zoom > 1.02 ? 0.62 : 0.5
        // Apoio visual: imagem da biblioteca ou quadro do vídeo de apoio.
        func brollImage(_ p: PlacedEffect) -> CIImage? { p.effect.kind == .video ? videos[p.effect.id] : images[p.effect.asset] }
        let broll = effects.last { ($0.effect.kind == .imagem || $0.effect.kind == .video) && time >= $0.start && time <= $0.end && brollImage($0) != nil }

        func presenter(in rect: CGRect) -> CIImage {
            let fill = settings.fillFrame || rect.size != size
            // Enquadramento mais aberto: mostra mais do vídeo e completa com o próprio vídeo desfocado.
            let open = fill && rect.size == size && settings.frameScale < 0.999
            var layer = fit(source, into: rect, fill: fill, zoom: zoom * (open ? settings.frameScale : 1), focus: fx, focusY: focusY)
            if !fill || open {
                // Fundo: o próprio quadro bem desfocado (vira só cor e luz, sem formas), um pouco mais escuro.
                let back = fit(source, into: rect, fill: true).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: size.width * (open ? 0.09 : 0.03)])
                    .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: open ? -0.08 : -0.18, kCIInputSaturationKey: 0.75]).cropped(to: rect)
                layer = layer.composited(over: back)
            }
            return grade(layer)
        }
        let activeFX = effects.filter { $0.effect.kind == .fx && time >= $0.start && time <= $0.end }
        // Base: você em tela cheia (com os efeitos que dependem de separar você do fundo).
        var base = presenter(in: bounds)
        for item in activeFX where item.effect.style == "zoom3d" || item.effect.style == "corpop" {
            guard let mask = personMask(base) else { continue }
            let k = envelope(item, at: time, fade: 0.25), amount = min(1, max(0.2, item.effect.amount))
            if item.effect.style == "zoom3d" {
                let p = (time - item.start) / max(0.1, item.end - item.start)
                let personScale = CGFloat(1 + 0.16 * amount * p * k), backScale = CGFloat(1 + 0.03 * p * k)
                func around(_ img: CIImage, _ s: CGFloat) -> CIImage {
                    img.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height * 0.45).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height * 0.45))).cropped(to: bounds)
                }
                let person = base.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
                base = around(person, personScale).composited(over: around(base, backScale))
            } else {
                let gray = base.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - k, kCIInputContrastKey: 1 + 0.1 * k])
                base = base.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: gray, kCIInputMaskImageKey: mask])
            }
        }
        output = base.composited(over: output)
        // Apoio visual (imagem/vídeo) no layout escolhido, com entrada suave.
        let supportLayout = broll == nil && settings.splitScreen && supportImage != nil
        if let image = broll.flatMap(brollImage) ?? (supportLayout ? supportImage : nil) {
            let layout = broll?.effect.style ?? "dividida"
            let progress = broll.map { (time - $0.start) / max(0.1, $0.end - $0.start) } ?? 0
            let kenBurns = broll?.effect.kind == .video || broll == nil ? 0 : 0.04 + 0.08 * progress
            func picture(_ rect: CGRect) -> CIImage { grade(fit(image, into: rect, fill: true, zoom: 1 + kenBurns, focus: 0.5)) }
            var layered: CIImage
            switch layout {
            case "dividida", "dividida-invertida":
                let invert = layout == "dividida-invertida"
                let (you, pic): (CGRect, CGRect)
                if settings.vertical {
                    let top = CGRect(x: 0, y: size.height * (invert ? 0.5 : 0.42), width: size.width, height: size.height * (invert ? 0.5 : 0.58))
                    let bottom = CGRect(x: 0, y: 0, width: size.width, height: size.height * (invert ? 0.5 : 0.42))
                    (you, pic) = invert ? (bottom, top) : (top, bottom)
                } else {
                    let left = CGRect(x: 0, y: 0, width: size.width * 0.5, height: size.height), right = CGRect(x: size.width * 0.5, y: 0, width: size.width * 0.5, height: size.height)
                    (you, pic) = invert ? (right, left) : (left, right)
                }
                layered = picture(pic).composited(over: presenter(in: you))
                let line = settings.vertical ? CGRect(x: 0, y: pic.maxY == size.height ? pic.minY - 1.5 : pic.maxY - 1.5, width: size.width, height: 3)
                                             : CGRect(x: size.width / 2 - 1.5, y: 0, width: 3, height: size.height)
                layered = CIImage(color: CIColor(cgColor: Self.gold.cgColor)).cropped(to: line).composited(over: layered)
            case "degrade":
                // Apoio no alto que se dissolve num degradê sobre você (estilo Reels de estudo).
                if settings.vertical {
                    // Você ocupa os 64% de baixo (enquadramento mais aberto, a cabeça fica abaixo da imagem); a imagem cobre o alto e se dissolve sobre a parede.
                    let youRect = CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.64)
                    let you = grade(fit(source, into: youRect, fill: true, zoom: zoom, focus: fx, focusY: 0.62))
                    let rect = CGRect(x: 0, y: size.height * 0.48, width: size.width, height: size.height * 0.52)
                    let mask = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: size.height * 0.50), "inputPoint1": CIVector(x: 0, y: size.height * 0.63),
                                                                              "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0), "inputColor1": CIColor.white])!.outputImage!.cropped(to: bounds)
                    layered = picture(rect).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: you, kCIInputMaskImageKey: mask])
                } else {
                    let rect = CGRect(x: 0, y: 0, width: size.width * 0.58, height: size.height)
                    let mask = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: size.width * 0.58, y: 0), "inputPoint1": CIVector(x: size.width * 0.40, y: 0),
                                                                              "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0), "inputColor1": CIColor.white])!.outputImage!.cropped(to: bounds)
                    layered = picture(rect).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: base, kCIInputMaskImageKey: mask])
                }
            case "pip", "pip-retangular":
                // Conteúdo em tela cheia (com os zooms) e você numa janela redonda ou retangular, com posição, tamanho e borda ajustáveis.
                let effect = broll?.effect
                let round = layout == "pip"
                let s = CGFloat(min(1.6, max(0.4, effect?.scale ?? 1)))
                let d = min(size.width, size.height) * (settings.vertical ? 0.42 : 0.30) * s
                let wBox = round ? d : d * (settings.vertical ? 1.0 : 1.25), hBox = round ? d : d * (settings.vertical ? 1.25 : 0.95)
                let margin = size.width * 0.05
                let pos = effect?.position ?? ""
                let left = pos.hasSuffix("esq") || pos == "esquerda", top = pos.hasPrefix("sup") || (pos.isEmpty && settings.vertical)
                var cx = left ? margin + wBox / 2 : size.width - margin - wBox / 2
                var cy = top ? size.height - margin * (settings.vertical ? 2.6 : 1) - hBox / 2 : margin * (settings.vertical ? 3.2 : 1) + hBox / 2
                if pos == "centro" { cx = size.width / 2; cy = size.height / 2 }
                let rect = CGRect(x: cx - wBox / 2, y: cy - hBox / 2, width: wBox, height: hBox)
                let content = grade(fit(image, into: bounds, fill: true, zoom: (1 + kenBurns) * zoom, focus: 0.5))
                let you = grade(fit(source, into: rect, fill: true, zoom: 1, focus: fx, focusY: 0.6))
                let shape: CIImage = round ? CIImage.radialMask(center: CGPoint(x: cx, y: cy), radius: d / 2)
                                           : CIImage(color: .white).cropped(to: rect)
                layered = content
                if effect?.border ?? true {
                    let w = max(3, d * 0.025)
                    let ring: CIImage = round ? CIImage.radialMask(center: CGPoint(x: cx, y: cy), radius: d / 2 + w) : CIImage(color: .white).cropped(to: rect.insetBy(dx: -w, dy: -w))
                    layered = CIImage(color: CIColor(cgColor: Self.gold.cgColor)).cropped(to: bounds).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: layered, kCIInputMaskImageKey: ring])
                }
                layered = you.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: layered, kCIInputMaskImageKey: shape])
            case "fundo":
                // Apresentador recortado sobre o conteúdo, com tamanho e posição ajustáveis.
                if let mask = personMask(base) {
                    let effect = broll?.effect
                    let s = CGFloat(min(1.2, max(0.4, effect?.scale ?? 1)))
                    let person = base.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
                    let pos = effect?.position ?? ""
                    let dx: CGFloat = pos.contains("esq") || pos == "esquerda" ? -size.width * (1 - s) / 2 - size.width * 0.04 * s : (pos.contains("dir") || pos == "direita" ? size.width * (1 - s) / 2 + size.width * 0.04 * s : 0)
                    // Encolhe a partir da base da imagem (a pessoa continua "apoiada" embaixo).
                    let moved = person.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: 0).concatenating(CGAffineTransform(scaleX: s, y: s))
                        .concatenating(CGAffineTransform(translationX: size.width / 2 + dx, y: 0))).cropped(to: bounds)
                    layered = moved.composited(over: picture(bounds))
                } else { layered = picture(bounds) }
            case "so-apoio":
                layered = picture(bounds)
            default:
                layered = picture(bounds)
            }
            layered = layered.cropped(to: bounds)
            var alpha = 1.0
            if let broll {
                let since = time - broll.start, entry = min(0.45, (broll.end - broll.start) / 3)
                let e = max(0, min(1, since / entry)), eased = e * e * (3 - 2 * e)
                alpha = envelope(broll, at: time, fade: 0.25)
                switch broll.effect.animation {
                case "deslizar": layered = layered.transformed(by: CGAffineTransform(translationX: size.width * CGFloat(1 - eased), y: 0)).cropped(to: bounds); alpha = min(1, (broll.end - time) / 0.25)
                case "zoom": let z = CGFloat(1.12 - 0.12 * eased); layered = layered.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2).concatenating(CGAffineTransform(scaleX: z, y: z)).concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))).cropped(to: bounds)
                case "corte": alpha = 1
                default: break
                }
            }
            output = faded(layered, alpha).composited(over: output)
        }
        // Efeitos de vídeo sobre a imagem montada.
        for item in activeFX {
            let k = envelope(item, at: time, fade: 0.15), amount = min(1, max(0.2, item.effect.amount))
            let since = time - item.start
            switch item.effect.style {
            case "tremor": output = shake(output, strength: k * amount, time: time)
            case "glitch": output = glitch(output, strength: k * amount, time: time)
            case "flash": output = faded(CIImage(color: CIColor(red: 1, green: 0.98, blue: 0.94)).cropped(to: bounds), max(0, 1 - since / 0.35) * amount).composited(over: output)
            case "pulso":
                let beat = abs(sin(.pi * since * 2))
                let z = CGFloat(1 + 0.07 * amount * k * beat)
                output = output.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2).concatenating(CGAffineTransform(scaleX: z, y: z)).concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))).cropped(to: bounds)
            case "filme":
                let noise = CIImage(cgImage: Self.grain).transformed(by: CGAffineTransform(translationX: CGFloat(Int(time * 24) % 7) * 37, y: CGFloat(Int(time * 24) % 5) * 53)).clampedToExtent().cropped(to: bounds)
                output = output.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.35 * amount * k])
                    .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.015 * sin(time * 40) * k, kCIInputContrastKey: 1 + 0.08 * k])
                output = faded(noise, 0.10 * amount * k).applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: output]).cropped(to: bounds)
                output = output.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: 1.2 * k, kCIInputRadiusKey: 1.4]).cropped(to: bounds)
            case "brilho":
                let p = since / max(0.1, item.end - item.start)
                let glow = CIImage.radialGlow(center: CGPoint(x: size.width * CGFloat(-0.2 + 1.4 * p), y: size.height * 0.75), radius: size.width * 0.7, color: CIColor(red: 1, green: 0.72, blue: 0.35, alpha: CGFloat(0.55 * amount * k)))
                output = glow.cropped(to: bounds).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: output]).cropped(to: bounds)
            case "foco":
                let blur = max(0, 1 - since / min(1.2, (item.end - item.start) * 0.6)) * 30 * amount * Double(size.width / 1080)
                if blur > 0.2 { output = output.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: bounds) }
            default: break
            }
        }
        // Transições entre trechos (aplicadas só à imagem, antes de legendas e textos)
        if let tr = transition {
            let scale = size.width / 1080
            switch tr.type {
            case "zoom":
                output = output.clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2), kCIInputAmountKey: 28 * tr.k * scale]).cropped(to: bounds)
            case "desfoque":
                output = output.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 26 * tr.k * scale]).cropped(to: bounds)
            case "chicote", "vertical":
                let shift = CGFloat(tr.u < 0 ? -1 : 1) * (tr.type == "vertical" ? size.height : size.width) * 0.35 * CGFloat(tr.k * tr.k)
                output = output.transformed(by: tr.type == "vertical" ? CGAffineTransform(translationX: 0, y: -shift) : CGAffineTransform(translationX: shift, y: 0)).clampedToExtent()
                    .applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: 70 * tr.k * scale, kCIInputAngleKey: tr.type == "vertical" ? Double.pi / 2 : 0]).cropped(to: bounds)
            case "flash":
                output = faded(CIImage(color: CIColor(red: 1, green: 0.98, blue: 0.94)).cropped(to: bounds), pow(tr.k, 1.6)).composited(over: output)
            case "girar":
                let angle = CGFloat(tr.u < 0 ? 1 : -1) * CGFloat(tr.k * tr.k) * .pi / 7
                let z = CGFloat(1 + 0.35 * tr.k)
                output = output.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2).concatenating(CGAffineTransform(rotationAngle: angle)).concatenating(CGAffineTransform(scaleX: z, y: z)).concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)))
                    .clampedToExtent().applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2), kCIInputAmountKey: 18 * tr.k * scale]).cropped(to: bounds)
            case "glitch": output = glitch(output, strength: tr.k, time: time)
            case "pixelar":
                output = output.clampedToExtent().applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: max(1, 70 * tr.k * tr.k * scale), kCIInputCenterKey: CIVector(x: size.width / 2, y: size.height / 2)]).cropped(to: bounds)
            case "tremor": output = shake(output, strength: tr.k * 1.4, time: time)
            case "rebobinar":
                // Fita voltando: imagem dessaturada, faixas deslocadas, linhas de varredura e o símbolo ◀◀.
                let k = tr.k
                output = output.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - 0.75 * k, kCIInputContrastKey: 1 + 0.25 * k, kCIInputBrightnessKey: 0.04 * k])
                output = glitch(output, strength: k * 0.9, time: time * 3)
                let lines = CIFilter(name: "CIStripesGenerator", parameters: ["inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0.28 * k), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                                                                              "inputWidth": max(2, size.height / 220), "inputSharpness": 1])!.outputImage!
                    .transformed(by: CGAffineTransform(rotationAngle: .pi / 2)).cropped(to: bounds)
                output = lines.composited(over: output)
                output = faded(rewindGlyph(), min(1, k * 1.6)).composited(over: output)
                let glow = CIImage.radialGlow(center: CGPoint(x: size.width * (tr.u < 0 ? 0.25 : 0.75), y: size.height * 0.6), radius: size.width * 0.9, color: CIColor(red: 1, green: 0.78, blue: 0.45, alpha: CGFloat(0.9 * tr.k)))
                output = glow.cropped(to: bounds).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: output]).cropped(to: bounds)
            default: break
            }
        }
        if settings.vignette || settings.colorLook == "Ethos clássico" || settings.colorLook == "Cinema" {
            output = output.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: settings.vignette ? 0.9 : 0.45, kCIInputRadiusKey: 1.6]).cropped(to: bounds)
        }
        // Quando a fala já está em destaque na tela, a legenda daquele trecho some para não repetir o texto.
        func norm(_ t: String) -> String { t.lowercased().filter { $0.isLetter || $0.isNumber } }
        if settings.captions, let cue = caption(at: time),
           !effects.contains(where: { $0.effect.kind == .texto && time >= $0.start && time <= $0.end && !norm(cue.text).isEmpty && norm($0.effect.text).contains(norm(cue.text)) }) {
            let lowered = broll?.effect.style == "degrade" && settings.vertical
            output = (settings.captionStyle == "Bege" && settings.captionMode != "Uma palavra" ? phraseCaption(cue, at: time, lowered: lowered) : captionImage(cue, at: time)).composited(over: output)
        }
        for effect in effects where effect.effect.kind == .texto && time >= effect.start && time <= effect.end && !effect.effect.text.isEmpty {
            output = animatedText(effect, at: time).composited(over: output)
        }
        if !settings.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, time < min(5, timeline.duration) {
            output = faded(questionImage(settings.question), min(1, (min(5, timeline.duration) - time) / 0.35)).composited(over: output)
        }
        if settings.progressBar, timeline.duration > 0 {
            let h = max(4, size.height * 0.005)
            output = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.18)).cropped(to: CGRect(x: 0, y: size.height - h, width: size.width, height: h)).composited(over: output)
            output = CIImage(color: CIColor(cgColor: Self.gold.cgColor)).cropped(to: CGRect(x: 0, y: size.height - h, width: size.width * CGFloat(min(1, time / timeline.duration)), height: h)).composited(over: output)
        }
        if let logo {
            let w = size.width * (settings.vertical ? 0.16 : 0.09)
            let scale = w / logo.extent.width
            let mark = logo.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            let margin = size.width * 0.035
            output = faded(mark.transformed(by: CGAffineTransform(translationX: size.width - mark.extent.width - margin - mark.extent.minX, y: size.height - mark.extent.height - margin * (settings.vertical ? 2.6 : 1) - mark.extent.minY)), 0.72).composited(over: output)
        }
        // Transições: mergulho rápido no preto nas mudanças de assunto; fade na abertura e no fim.
        var black = 0.0
        if let tr = transition, tr.type == "fade" { black = max(black, tr.k) }
        if settings.fadeInOut { black = max(black, 1 - time / 0.35, 1 - (timeline.duration - time) / 0.5) }
        if black > 0.001 { output = faded(CIImage(color: .black).cropped(to: bounds), min(1, black)).composited(over: output) }
        return output.cropped(to: bounds)
    }
    private func caption(at time: Double) -> Caption? {
        let captions = timeline.captions
        var low = 0; var high = captions.count
        while low < high { let mid = (low + high) / 2; if captions[mid].start <= time { low = mid + 1 } else { high = mid } }
        guard low > 0, captions[low - 1].end > time else { return nil }
        return captions[low - 1]
    }

    // MARK: Texto

    private struct TextLook { var font: NSFont; var color: NSColor; var highlight: NSColor; var stroke: Bool; var box: CGColor?; var shadow: Bool }
    private func captionLook(size fontSize: CGFloat) -> TextLook {
        var look = baseCaptionLook(size: fontSize)
        if !settings.captionFont.isEmpty, let font = NSFont(name: settings.captionFont, size: fontSize) { look.font = font }
        if let custom = EditSettings.captionColors.first(where: { $0.id == settings.captionColor && !$0.id.isEmpty }) {
            look.color = NSColor(red: custom.color.0, green: custom.color.1, blue: custom.color.2, alpha: 1)
        }
        return look
    }
    private func baseCaptionLook(size fontSize: CGFloat) -> TextLook {
        switch settings.captionStyle {
        case "Ethos":
            return TextLook(font: NSFont(name: "Georgia-Bold", size: fontSize) ?? .boldSystemFont(ofSize: fontSize), color: Self.cream, highlight: Self.gold, stroke: false, box: nil, shadow: true)
        case "Bege":
            return TextLook(font: TextStyles.font(["Baskerville-SemiBold", "Baskerville-Bold", "Georgia-Bold"], fontSize), color: Self.ink, highlight: Self.ink, stroke: false, box: Self.beige, shadow: false)
        case "Contorno":
            return TextLook(font: .systemFont(ofSize: fontSize, weight: .heavy), color: .white, highlight: NSColor(red: 0.98, green: 0.80, blue: 0.30, alpha: 1), stroke: true, box: nil, shadow: true)
        case "Destaque":
            return TextLook(font: .systemFont(ofSize: fontSize, weight: .semibold), color: NSColor(red: 0.73, green: 1, blue: 0.62, alpha: 1), highlight: .white, stroke: false, box: CGColor(red: 0.025, green: 0.035, blue: 0.035, alpha: 0.82), shadow: false)
        case "Hormozi":
            return TextLook(font: .systemFont(ofSize: fontSize, weight: .black), color: .white, highlight: NSColor(red: 1, green: 0.86, blue: 0.12, alpha: 1), stroke: true, box: nil, shadow: true)
        case "Caixa":
            return TextLook(font: .systemFont(ofSize: fontSize, weight: .heavy), color: .white, highlight: Self.ink, stroke: true, box: nil, shadow: true)
        default:
            return TextLook(font: .systemFont(ofSize: fontSize, weight: .semibold), color: .white, highlight: Self.gold, stroke: false, box: CGColor(red: 0.025, green: 0.035, blue: 0.035, alpha: 0.82), shadow: false)
        }
    }
    private func captionImage(_ cue: Caption, at time: Double) -> CIImage {
        let single = settings.captionMode == "Uma palavra"
        let dynamic = settings.captionMode == "Dinâmica" || single
        let perGroup = single ? 1 : (settings.vertical ? 3 : 5)
        let base = size.width * (settings.vertical ? (dynamic ? 0.068 : 0.052) : (dynamic ? 0.036 : 0.028)) * (single ? 1.55 : 1) * CGFloat(settings.captionScale)
        let upper = dynamic && ["Contorno", "Hormozi", "Caixa"].contains(settings.captionStyle)
        let look = captionLook(size: base)
        let centerY = settings.captionPosition == "Centro" ? size.height * (settings.vertical ? 0.33 : 0.30) : size.height * (settings.vertical ? 0.19 : 0.11)
        var words = cue.timedWords().map(\.text); var active = -1
        if dynamic {
            let timed = cue.timedWords()
            let index = timed.lastIndex(where: { $0.start <= time }) ?? 0
            let groupStart = (index / perGroup) * perGroup
            words = Array(timed[groupStart..<min(timed.count, groupStart + perGroup)].map(\.text))
            active = index - groupStart
        }
        var pop: CGFloat = 1
        if dynamic {
            let timed = cue.timedWords()
            let index = timed.lastIndex(where: { $0.start <= time }) ?? 0
            let since = time - timed[(index / perGroup) * perGroup].start
            if since < 0.12 { pop = (single ? 0.75 : 0.90) + (single ? 0.25 : 0.10) * CGFloat(max(0, since) / 0.12) }
        }
        let key = "c|\(words.joined(separator: " "))|\(active)" as NSString
        func popped(_ image: CIImage) -> CIImage {
            guard pop < 0.999 else { return image }
            let center = CGPoint(x: size.width / 2, y: centerY)
            return image.transformed(by: CGAffineTransform(translationX: -center.x, y: -center.y).concatenating(CGAffineTransform(scaleX: pop, y: pop)).concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        }
        if let cached = textCache.object(forKey: key) { return popped(cached) }
        let string = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineSpacing = base * 0.10
        var activeRange: NSRange?
        for (i, word) in words.enumerated() {
            var font = look.font
            if i == active && settings.captionStyle == "Hormozi" && !single { font = NSFont.systemFont(ofSize: base * 1.18, weight: .black) }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: i == active ? look.highlight : look.color, .paragraphStyle: paragraph]
            if i > 0 { string.append(NSAttributedString(string: " ", attributes: attributes)) }
            if i == active { activeRange = NSRange(location: string.length, length: (word as NSString).length) }
            string.append(NSAttributedString(string: upper ? word.uppercased() : word, attributes: attributes))
        }
        var outline: NSAttributedString?
        if look.stroke {
            let copy = NSMutableAttributedString(attributedString: string)
            copy.addAttributes([.strokeColor: NSColor.black, .strokeWidth: 14, .foregroundColor: NSColor.clear], range: NSRange(location: 0, length: copy.length))
            // No estilo Caixa, a palavra falada fica sobre a caixa dourada (sem contorno).
            if settings.captionStyle == "Caixa", let activeRange { copy.addAttribute(.strokeColor, value: NSColor.clear, range: activeRange) }
            outline = copy
        }
        let box = settings.captionStyle == "Caixa" ? activeRange.map { (range: $0, color: Self.gold.cgColor) } : nil
        let image = drawText(string, width: size.width * 0.84, centerY: single ? size.height * (settings.vertical ? 0.36 : 0.32) : centerY, box: look.box, padding: base * 0.5, shadow: look.shadow,
                             accent: false, leftAligned: false, outline: outline, underline: false, wordBox: box).0
        textCache.setObject(image, forKey: key)
        return popped(image)
    }
    /// Símbolo ◀◀ no canto, como num videocassete.
    func rewindGlyph() -> CIImage {
        let key = "rw" as NSString
        if let cached = textCache.object(forKey: key) { return cached }
        let fontSize = size.width * (settings.vertical ? 0.075 : 0.045)
        let p = NSMutableParagraphStyle(); p.alignment = .left
        let string = NSAttributedString(string: "◀◀", attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .heavy), .foregroundColor: NSColor.white, .paragraphStyle: p])
        let image = drawText(string, width: size.width * 0.4, centerY: size.height * 0.86, box: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45), padding: fontSize * 0.35, shadow: false, leftAligned: true)
        textCache.setObject(image, forKey: key)
        return image
    }
    static let beige = CGColor(red: 0.925, green: 0.885, blue: 0.80, alpha: 0.94)
    /// Legenda "Bege": a frase falada (até ~7 palavras, quebrando na pontuação) em serifa escura sobre uma faixa bege.
    private func phraseCaption(_ cue: Caption, at time: Double, lowered: Bool) -> CIImage {
        let timed = cue.timedWords()
        guard !timed.isEmpty else { return CIImage.empty() }
        let limit = settings.vertical ? 7 : 11
        // Primeiro quebra nas pausas e pontuação; frases longas viram partes de tamanho parecido (sem palavra solta no fim).
        var phrases: [Range<Int>] = [], start = 0
        for i in timed.indices {
            let pause = i + 1 < timed.count && timed[i + 1].start - timed[i].end > 0.35
            let punct = timed[i].text.last.map { ",.;:?!…".contains($0) } ?? false
            if i == timed.count - 1 || ((punct || pause) && i - start + 1 >= 3) { phrases.append(start..<(i + 1)); start = i + 1 }
        }
        var groups: [Range<Int>] = []
        for phrase in phrases {
            let parts = Int((Double(phrase.count) / Double(limit)).rounded(.up))
            for p in 0..<parts { groups.append((phrase.lowerBound + phrase.count * p / parts)..<(phrase.lowerBound + phrase.count * (p + 1) / parts)) }
        }
        let index = timed.lastIndex(where: { $0.start <= time }) ?? 0
        let group = groups.first { $0.contains(index) } ?? groups[0]
        let text = timed[group].map(\.text).joined(separator: " ")
        let base = size.width * (settings.vertical ? 0.064 : 0.036) * CGFloat(settings.captionScale)
        let centerY = settings.captionPosition == "Centro" ? size.height * (settings.vertical ? 0.36 : 0.30) : size.height * (settings.vertical ? (lowered ? 0.205 : 0.27) : 0.12)
        let since = time - timed[group.lowerBound].start
        let key = "b|\(lowered)|\(text)" as NSString
        var image: CIImage
        if let cached = textCache.object(forKey: key) { image = cached } else {
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineSpacing = 0; paragraph.lineHeightMultiple = 0.92
            let look = captionLook(size: base)
            let string = NSAttributedString(string: text, attributes: [.font: look.font, .foregroundColor: look.color, .paragraphStyle: paragraph])
            image = drawText(string, width: size.width * (settings.vertical ? 0.86 : 0.70), centerY: centerY, box: look.box, padding: base * 0.42, shadow: false)
            textCache.setObject(image, forKey: key)
        }
        // Entrada curta: a faixa surge e sobe levemente.
        let k = max(0, min(1, since / 0.14))
        return faded(image.transformed(by: CGAffineTransform(translationX: 0, y: -CGFloat(1 - k) * base * 0.25)), 0.35 + 0.65 * k)
    }
    private func questionImage(_ text: String) -> CIImage {
        let key = "q|\(text)" as NSString
        if let cached = textCache.object(forKey: key) { return cached }
        let fontSize = size.width * (settings.vertical ? 0.050 : 0.030)
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let string = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Georgia-Bold", size: fontSize) ?? .boldSystemFont(ofSize: fontSize), .foregroundColor: Self.ink, .paragraphStyle: paragraph])
        let image = drawText(string, width: size.width * 0.80, centerY: size.height * (settings.vertical ? 0.85 : 0.78), box: Self.cream.withAlphaComponent(0.96).cgColor, padding: fontSize * 0.7, shadow: true, accent: true)
        textCache.setObject(image, forKey: key)
        return image
    }
    private func drawText(_ string: NSAttributedString, width: CGFloat, centerY: CGFloat, box: CGColor?, padding: CGFloat, shadow: Bool, accent: Bool = false, leftAligned: Bool = false, outline: NSAttributedString? = nil) -> CIImage {
        drawText(string, width: width, centerY: centerY, box: box, padding: padding, shadow: shadow, accent: accent, leftAligned: leftAligned, outline: outline, underline: false).0
    }
    func drawText(_ string: NSAttributedString, width: CGFloat, centerY: CGFloat, box: CGColor?, padding: CGFloat, shadow: Bool, accent: Bool = false, leftAligned: Bool = false, outline: NSAttributedString? = nil, underline: Bool,
                  wordBox: (range: NSRange, color: CGColor)? = nil) -> (CIImage, CGRect) {
        let w = Int(size.width), h = Int(size.height)
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (CIImage.empty(), .zero) }
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: 0), nil, CGSize(width: width - padding * 2, height: size.height * 0.5), nil)
        let boxWidth = box == nil ? width : min(width, ceil(measured.width) + padding * 2.2)
        let height = min(size.height * 0.5, ceil(measured.height) + padding * 2)
        let x = leftAligned ? size.width * 0.06 : (size.width - boxWidth) / 2
        let rect = CGRect(x: x, y: centerY - height / 2, width: boxWidth, height: height)
        if let box {
            if shadow { cg.setShadow(offset: CGSize(width: 0, height: -padding * 0.15), blur: padding * 0.8, color: CGColor(gray: 0, alpha: 0.35)) }
            cg.setFillColor(box)
            cg.addPath(CGPath(roundedRect: rect, cornerWidth: padding * 0.35, cornerHeight: padding * 0.35, transform: nil)); cg.fillPath()
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            if accent {
                cg.setFillColor(Self.gold.cgColor)
                if leftAligned { cg.fill(CGRect(x: rect.minX, y: rect.minY, width: max(3, padding * 0.25), height: rect.height)) }
                else { cg.fill(CGRect(x: rect.midX - padding * 1.2, y: rect.minY + padding * 0.45, width: padding * 2.4, height: max(2, padding * 0.09))) }
            }
        } else if shadow {
            cg.setShadow(offset: CGSize(width: 0, height: -padding * 0.12), blur: padding * 0.5, color: CGColor(gray: 0, alpha: 0.85))
        }
        let path = CGPath(rect: rect.insetBy(dx: padding, dy: padding * 0.9), transform: nil)
        // Caixa colorida atrás de uma palavra (legenda estilo "Caixa").
        if let wordBox {
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
            let pathBox = path.boundingBox
            for (n, line) in lines.enumerated() {
                let r = CTLineGetStringRange(line)
                let a = max(wordBox.range.location, r.location), b = min(wordBox.range.location + wordBox.range.length, r.location + r.length)
                guard b > a else { continue }
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let x0 = CTLineGetOffsetForStringIndex(line, a, nil), x1 = CTLineGetOffsetForStringIndex(line, b, nil)
                let o = origins[n]
                let pad = padding * 0.35
                let boxRect = CGRect(x: pathBox.minX + o.x + x0 - pad, y: pathBox.minY + o.y - descent - pad * 0.6, width: x1 - x0 + pad * 2, height: ascent + descent + pad * 1.2)
                cg.setShadow(offset: .zero, blur: 0, color: nil)
                cg.setFillColor(wordBox.color)
                cg.addPath(CGPath(roundedRect: boxRect, cornerWidth: pad, cornerHeight: pad, transform: nil)); cg.fillPath()
            }
            if shadow { cg.setShadow(offset: CGSize(width: 0, height: -padding * 0.12), blur: padding * 0.5, color: CGColor(gray: 0, alpha: 0.85)) }
        }
        if let outline {
            cg.setLineJoin(.round)
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(outline), CFRange(location: 0, length: 0), path, nil), cg)
            cg.setShadow(offset: .zero, blur: 0, color: nil)
        }
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), cg)
        if underline {
            cg.setShadow(offset: .zero, blur: 0, color: nil)
            cg.setFillColor(Self.gold.cgColor)
            let lineWidth = min(rect.width * 0.5, ceil(measured.width))
            cg.fill(CGRect(x: rect.midX - lineWidth / 2, y: rect.minY + padding * 0.35, width: lineWidth, height: max(2, padding * 0.12)))
        }
        guard let bitmap = cg.makeImage() else { return (CIImage.empty(), .zero) }
        return (CIImage(cgImage: bitmap), rect)
    }
}


extension CIImage {
    /// Máscara circular de borda suave (branco dentro).
    static func radialMask(center: CGPoint, radius: CGFloat) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(cgPoint: center), "inputRadius0": radius - 1.5, "inputRadius1": radius,
                                                         "inputColor0": CIColor.white, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])!.outputImage!
    }
    /// Brilho radial colorido que some nas bordas.
    static func radialGlow(center: CGPoint, radius: CGFloat, color: CIColor) -> CIImage {
        CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(cgPoint: center), "inputRadius0": 0, "inputRadius1": radius,
                                                         "inputColor0": color, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])!.outputImage!
    }
}
