import AVFoundation
import CoreImage

/// Instrução do compositor com vídeos de apoio (b-roll): leva o pintor e a faixa de cada vídeo.
final class BrollInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let painter: FramePainter
    let mainTrack: CMPersistentTrackID
    let mainTransform: CGAffineTransform
    let brollTracks: [UUID: CMPersistentTrackID]
    let brollTransforms: [UUID: CGAffineTransform]

    init(timeRange: CMTimeRange, painter: FramePainter, mainTrack: CMPersistentTrackID, mainTransform: CGAffineTransform,
         brollTracks: [UUID: CMPersistentTrackID], brollTransforms: [UUID: CGAffineTransform]) {
        self.timeRange = timeRange; self.painter = painter; self.mainTrack = mainTrack; self.mainTransform = mainTransform
        self.brollTracks = brollTracks; self.brollTransforms = brollTransforms
        requiredSourceTrackIDs = ([mainTrack] + Array(brollTracks.values)).map { NSNumber(value: $0) }
    }
}

/// Compositor que junta o vídeo principal e os vídeos de apoio e entrega tudo ao mesmo pintor da edição.
final class BrollCompositor: NSObject, AVVideoCompositing {
    let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    private var renderContext: AVVideoCompositionRenderContext?
    private let lock = NSLock()

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { lock.lock(); renderContext = newRenderContext; lock.unlock() }
    func cancelAllPendingVideoCompositionRequests() {}

    /// Aplica a orientação gravada na faixa (vídeos de celular girados) ao quadro.
    static func oriented(_ buffer: CVPixelBuffer, _ t: CGAffineTransform) -> CIImage {
        let image = CIImage(cvPixelBuffer: buffer)
        let orientation: CGImagePropertyOrientation
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): orientation = .right
        case (0, -1, 1, 0): orientation = .left
        case (-1, 0, 0, -1): orientation = .down
        default: orientation = .up
        }
        let out = image.oriented(orientation)
        return out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        lock.lock(); let context = renderContext; lock.unlock()
        guard let instruction = request.videoCompositionInstruction as? BrollInstruction, let context,
              let output = context.newPixelBuffer(), let main = request.sourceFrame(byTrackID: instruction.mainTrack) else {
            request.finish(with: NSError(domain: "CortaStudio", code: 1)); return
        }
        var videos: [UUID: CIImage] = [:]
        for (id, track) in instruction.brollTracks {
            if let frame = request.sourceFrame(byTrackID: track) { videos[id] = Self.oriented(frame, instruction.brollTransforms[id] ?? .identity) }
        }
        let image = instruction.painter.frame(Self.oriented(main, instruction.mainTransform), at: request.compositionTime.seconds, videos: videos)
        instruction.painter.context.render(image, to: output, bounds: CGRect(origin: .zero, size: context.size), colorSpace: CGColorSpaceCreateDeviceRGB())
        request.finish(withComposedVideoFrame: output)
    }
}
