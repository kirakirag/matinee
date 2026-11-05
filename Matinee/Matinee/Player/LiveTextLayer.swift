import AppKit
import SwiftUI
import VisionKit

/// macOS Live Text on a paused frame: select and copy text, Look Up, translate, open links and codes,
/// as in QuickTime. The frame is read from mpv and analysed only while paused, never during playback.
struct LiveTextLayer: View {
    let player: PlaybackController
    @State private var analysis: ImageAnalysis?
    @State private var imageSize: CGSize = .zero

    private static let analyzer = ImageAnalyzer()

    var body: some View {
        OverlayHost(analysis: analysis, imageSize: imageSize)
            // A seek while paused shows a new frame: analyse that one.
            .task(id: player.position) {
                analysis = nil
                guard ImageAnalyzer.isSupported else { return }
                try? await Task.sleep(for: .milliseconds(200))   // let the seek land, and skip held arrow keys
                guard !Task.isCancelled else { return }
                guard let frame = await player.currentFrame(), !Task.isCancelled else { return }
                let configuration = ImageAnalyzer.Configuration([.text, .visualLookUp, .machineReadableCode])
                guard let result = try? await Self.analyzer.analyze(frame, orientation: .up, configuration: configuration),
                      !Task.isCancelled else { return }
                imageSize = CGSize(width: frame.width, height: frame.height)
                analysis = result
            }
    }

    /// The overlay currently shown, so ⌘C can copy its selection instead of the video's link.
    @MainActor static weak var current: ImageAnalysisOverlayView?
    @MainActor static var hasSelection: Bool { current?.hasActiveTextSelection == true }

    private struct OverlayHost: NSViewRepresentable {
        let analysis: ImageAnalysis?
        let imageSize: CGSize

        func makeNSView(context: Context) -> Container { Container() }

        func updateNSView(_ container: Container, context: Context) {
            container.imageSize = imageSize
            container.overlay.analysis = analysis
            container.needsLayout = true
            LiveTextLayer.current = analysis == nil ? nil : container.overlay
        }

        static func dismantleNSView(_ container: Container, coordinator: ()) {
            if LiveTextLayer.current === container.overlay { LiveTextLayer.current = nil }
        }

        /// Keeps the overlay on the video's letterboxed rect, where mpv draws the frame.
        final class Container: NSView {
            let overlay = ImageAnalysisOverlayView()
            var imageSize: CGSize = .zero

            override init(frame: NSRect) {
                super.init(frame: frame)
                overlay.preferredInteractionTypes = .automatic
                addSubview(overlay)
            }

            required init?(coder: NSCoder) { fatalError() }

            override func layout() {
                super.layout()
                guard imageSize.width > 0, imageSize.height > 0 else { overlay.frame = bounds; return }
                let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
                let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                overlay.frame = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                       width: size.width, height: size.height)
            }

            // Only the overlay's own text and items take the mouse; elsewhere clicks reach the player.
            override func hitTest(_ point: NSPoint) -> NSView? {
                let hit = super.hitTest(point)
                return hit === self ? nil : hit
            }
        }
    }
}
