import Foundation
import CoreImage
import Vision

/// Correção de olhar (experimental): localiza olhos e pupilas com o Vision em cada quadro e desloca suavemente a íris
/// em direção ao centro da abertura do olho, como quem olha para a lente. As pálpebras ficam no lugar
/// (a deformação cai a zero na borda do olho), piscadas não são alteradas e o movimento é suavizado entre quadros.
final class GazeCorrector: @unchecked Sendable {
    struct Eye { var center: CGPoint; var pupil: CGPoint; var radius: CGSize; var open: Double }
    let strength: Double
    private let lock = NSLock()
    private var last: (time: Double, eyes: [Eye])?
    private static let kernel: CIWarpKernel? = CIWarpKernel(source: """
    kernel vec2 gaze(vec2 c1, vec2 d1, vec2 r1, vec2 c2, vec2 d2, vec2 r2) {
        vec2 p = destCoord();
        float f1 = 1.0 - smoothstep(0.35, 1.0, length((p - c1) / r1));
        float f2 = 1.0 - smoothstep(0.35, 1.0, length((p - c2) / r2));
        return p - d1 * f1 - d2 * f2;
    }
    """)

    init(strength: Double) { self.strength = max(0, min(1, strength)) }

    /// Olhos detectados no quadro, em coordenadas da imagem (origem embaixo à esquerda, como no Core Image).
    static func detect(_ image: CIImage) -> [Eye] {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(ciImage: image, options: [:]).perform([request])
        guard let face = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }), let marks = face.landmarks else { return [] }
        let size = image.extent.size
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x + image.extent.minX, y: $0.y + image.extent.minY) }
        }
        var eyes: [Eye] = []
        for (contour, pupil) in [(points(marks.leftEye), points(marks.leftPupil)), (points(marks.rightEye), points(marks.rightPupil))] {
            guard contour.count >= 6, let p = pupil.first else { continue }
            let xs = contour.map(\.x), ys = contour.map(\.y)
            let w = xs.max()! - xs.min()!, h = ys.max()! - ys.min()!
            guard w > 6 else { continue }
            eyes.append(Eye(center: CGPoint(x: (xs.max()! + xs.min()!) / 2, y: (ys.max()! + ys.min()!) / 2), pupil: p,
                            radius: CGSize(width: w * 0.55, height: max(h * 0.75, w * 0.22)), open: Double(h / w)))
        }
        return eyes.count == 2 ? eyes : []
    }

    func apply(_ image: CIImage, at time: Double) -> CIImage {
        guard strength > 0.01, let kernel = Self.kernel else { return image }
        var eyes = Self.detect(image)
        lock.lock()
        // Suavização temporal: evita tremor das pupilas detectadas.
        if let previous = last, abs(previous.time - time) < 0.25, previous.eyes.count == eyes.count, !eyes.isEmpty {
            for i in eyes.indices {
                let a = 0.45
                eyes[i].pupil.x = previous.eyes[i].pupil.x + (eyes[i].pupil.x - previous.eyes[i].pupil.x) * a
                eyes[i].pupil.y = previous.eyes[i].pupil.y + (eyes[i].pupil.y - previous.eyes[i].pupil.y) * a
                eyes[i].center.x = previous.eyes[i].center.x + (eyes[i].center.x - previous.eyes[i].center.x) * a
                eyes[i].center.y = previous.eyes[i].center.y + (eyes[i].center.y - previous.eyes[i].center.y) * a
            }
        }
        last = eyes.isEmpty ? nil : (time, eyes)
        lock.unlock()
        guard eyes.count == 2 else { return image }
        var args: [Any] = []
        var reach: CGFloat = 0
        for eye in eyes {
            // Olho quase fechado (piscada): não mexe.
            let openness = max(0, min(1, (eye.open - 0.16) / 0.10))
            let w = eye.radius.width / 0.55, h = eye.radius.height / 0.75
            var dx = (eye.center.x - eye.pupil.x), dy = (eye.center.y + h * 0.04 - eye.pupil.y)
            dx = max(-w * 0.12, min(w * 0.12, dx)); dy = max(-h * 0.30, min(h * 0.30, dy))
            let k = CGFloat(strength * openness)
            args += [CIVector(cgPoint: eye.center), CIVector(x: dx * k, y: dy * k), CIVector(x: eye.radius.width, y: eye.radius.height)]
            reach = max(reach, abs(dx * k), abs(dy * k))
        }
        return kernel.apply(extent: image.extent, roiCallback: { _, rect in rect.insetBy(dx: -reach - 2, dy: -reach - 2) }, image: image, arguments: args) ?? image
    }
}

import AVFoundation
import AppKit

enum GazeLab {
    /// `--gaze-test vídeo pasta`: salva recortes dos olhos antes/depois em várias intensidades, para avaliação visual.
    static func run(video: URL, folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        for t in [1.0, 4.0, 8.0, 12.0, 16.0] {
            let frame = CIImage(cgImage: try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
            let eyes = GazeCorrector.detect(frame)
            guard eyes.count == 2 else { print("t=\(t): olhos não detectados"); continue }
            let box = CGRect(x: min(eyes[0].center.x, eyes[1].center.x) - eyes[0].radius.width * 2.2, y: eyes[0].center.y - eyes[0].radius.width * 1.3,
                             width: abs(eyes[0].center.x - eyes[1].center.x) + eyes[0].radius.width * 4.4, height: eyes[0].radius.width * 2.6)
            var tiles: [CGImage] = []
            for s in [0.0, 0.5, 1.0] {
                let out = GazeCorrector(strength: s).apply(frame, at: t)
                if let cg = context.createCGImage(out, from: box) { tiles.append(cg) }
            }
            let w = Int(box.width), h = Int(box.height)
            let sheet = CGContext(data: nil, width: w, height: h * tiles.count, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (i, tile) in tiles.enumerated() { sheet.draw(tile, in: CGRect(x: 0, y: h * (tiles.count - 1 - i), width: w, height: h)) }
            try NSBitmapImageRep(cgImage: sheet.makeImage()!).representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("olhar-\(Int(t)).png"))
            print("t=\(t): pupila→centro dx=\(Int(eyes[0].center.x - eyes[0].pupil.x)) dy=\(Int(eyes[0].center.y - eyes[0].pupil.y)) abertura=\(String(format: "%.2f", eyes[0].open))")
        }
    }
}

// MARK: Análise de olhar ao longo do vídeo (para o modo roteiro)

struct GazeSample: Codable { var t: Double; var open: Double; var yaw: Double; var face: Bool }

/// Onde você olha para a câmera e onde desvia (lendo o roteiro abaixo ou olhando para o lado).
struct GazeReport: Codable, Equatable {
    var away: [Cut]          // trechos (tempo do original) olhando para fora da câmera
    var down: Double         // fração do vídeo olhando para baixo
    var side: Double         // fração olhando para o lado
    var duration: Double

    /// Percentual do intervalo dado em que você olha para a câmera.
    func cameraShare(_ start: Double, _ end: Double) -> Int {
        guard end > start else { return 100 }
        let away = self.away.reduce(0.0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
        return Int(((1 - away / (end - start)) * 100).rounded())
    }

    static func build(_ samples: [GazeSample], step: Double, duration: Double) -> GazeReport {
        let faces = samples.filter(\.face)
        guard faces.count > 10 else { return GazeReport(away: [], down: 0, side: 0, duration: duration) }
        func quantile(_ values: [Double], _ q: Double) -> Double { let s = values.sorted(); return s[min(s.count - 1, Int(Double(s.count) * q))] }
        let yawCenter = quantile(faces.map(\.yaw), 0.5)
        let frontal = faces.filter { abs($0.yaw - yawCenter) < 0.2 }
        let base = quantile((frontal.isEmpty ? faces : frontal).map(\.open), 0.6)
        // Classificação por amostra: baixo (pálpebras baixas), lado (cabeça virada), sem rosto conta como fora.
        var kind = samples.map { s -> Int in
            if !s.face { return 2 }
            if s.open < base * 0.74 { return 1 }
            if abs(s.yaw - yawCenter) > 0.32 { return 2 }
            return 0
        }
        // Precisa durar ~1 s (2 amostras seguidas): piscadas e olhadas rápidas não contam.
        for i in kind.indices where kind[i] != 0 {
            let prev = i > 0 ? kind[i - 1] : 0, next = i + 1 < kind.count ? kind[i + 1] : 0
            if prev == 0 && next == 0 { kind[i] = 0 }
        }
        var away: [Cut] = []
        for (i, k) in kind.enumerated() where k != 0 {
            let a = max(0, samples[i].t - step / 2), b = min(duration, samples[i].t + step / 2)
            if let last = away.last, a <= last.end + 0.01 { away[away.count - 1].end = b } else { away.append(Cut(start: a, end: b)) }
        }
        let total = Double(max(1, kind.count))
        return GazeReport(away: away, down: Double(kind.filter { $0 == 1 }.count) / total, side: Double(kind.filter { $0 == 2 }.count) / total, duration: duration)
    }
}

extension MediaEngine {
    /// Analisa o olhar a cada 0,5 s (rápido: cerca de 3 s por minuto de vídeo num M1). Resultado guardado em cache.
    static func analyzeGaze(_ url: URL, duration: Double, cache: URL, status: @escaping @Sendable (String) -> Void) async throws -> GazeReport {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate?.timeIntervalSince1970) ?? 0
        let key = SHA256Hex.of("\(url.path)|\(modified)|gaze-v1")
        let file = cache.appendingPathComponent("olhar-\(key).json")
        if let data = try? Data(contentsOf: file), let report = try? JSONDecoder().decode(GazeReport.self, from: data) { return report }
        let step = 0.5
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let times = stride(from: 0.0, to: duration, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }
        var samples: [GazeSample] = []
        samples.reserveCapacity(times.count)
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            let t = result.requestedTime.seconds
            if samples.count % 40 == 0 { status("Analisando o olhar: \(Int(t / max(1, duration) * 100))%") }
            guard let image = try? result.image else { samples.append(GazeSample(t: t, open: 0, yaw: 0, face: false)); continue }
            let rect = VNDetectFaceRectanglesRequest(); rect.revision = VNDetectFaceRectanglesRequestRevision3
            let marks = VNDetectFaceLandmarksRequest()
            try? VNImageRequestHandler(cgImage: image).perform([rect, marks])
            guard let face = marks.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }), let lm = face.landmarks else {
                samples.append(GazeSample(t: t, open: 0, yaw: 0, face: false)); continue
            }
            let size = CGSize(width: image.width, height: image.height)
            var opens: [Double] = []
            for eye in [lm.leftEye, lm.rightEye] {
                let p = eye?.pointsInImage(imageSize: size) ?? []
                guard p.count > 5 else { continue }
                let ys = p.map(\.y), xs = p.map(\.x)
                opens.append(Double((ys.max()! - ys.min()!) / max(1, xs.max()! - xs.min()!)))
            }
            let yaw = rect.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.yaw?.doubleValue ?? 0
            samples.append(GazeSample(t: t, open: opens.isEmpty ? 0 : opens.reduce(0, +) / Double(opens.count), yaw: yaw, face: !opens.isEmpty))
        }
        let report = GazeReport.build(samples.sorted { $0.t < $1.t }, step: step, duration: duration)
        try? JSONEncoder().encode(report).write(to: file)
        return report
    }
}

import CryptoKit
enum SHA256Hex { static func of(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() } }
