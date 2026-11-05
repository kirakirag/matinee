import AppKit
import CMpv
import OpenGL.GL3

/// libmpv rendered into an NSOpenGLView through mpv's render API. The owner creates and initialises the mpv
/// handle, calls `fileLoaded()` on MPV_EVENT_FILE_LOADED, and calls `teardown()` before `mpv_terminate_destroy`.
final class MPVGLView: NSOpenGLView {
    private let mpv: OpaquePointer
    private var renderContext: OpaquePointer?
    /// Context handed to mpv's update callback: it weakly references the view, so a hop to main that is still
    /// queued after the view is gone does nothing. Released in `teardown()`.
    private var callbackBox: Unmanaged<CallbackBox>?
    /// Called on the main thread once per file, for the first draw that carries a video frame after `fileLoaded()`.
    var firstFrame: (() -> Void)?
    private var waitingForFrame = false
    private var pendingFrame = false

    init(frame: NSRect, mpv: OpaquePointer) {
        self.mpv = mpv
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFADoubleBuffer), UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core), 0,
        ]
        super.init(frame: frame, pixelFormat: NSOpenGLPixelFormat(attributes: attributes))!
        wantsBestResolutionOpenGLSurface = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The next frame drawn after this is the file's first.
    func fileLoaded() {
        waitingForFrame = true
        pendingFrame = false   // only a render update after file-loaded counts as the first frame
    }

    /// Frees the render context. Must run before the mpv handle is destroyed. It is not called from `deinit`:
    /// deinit cannot touch main-actor state, and the owner alone knows the mpv handle is still alive.
    func teardown() {
        guard let renderContext else { return }
        openGLContext?.makeCurrentContext()
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)   // waits for a running callback to finish
        self.renderContext = nil
        callbackBox?.release()
        callbackBox = nil
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard renderContext == nil else { return }
        openGLContext!.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext!.setValues(&swapInterval, for: .swapInterval)

        var initParams = mpv_opengl_init_params(get_proc_address: Self.procAddress, get_proc_address_ctx: nil)
        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)!
        defer { free(apiType) }
        withUnsafeMutablePointer(to: &initParams) { initPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                mpv_render_param(),
            ]
            let rc = mpv_render_context_create(&renderContext, mpv, &params)
            precondition(rc >= 0, "mpv_render_context_create failed: \(rc)")
        }
        let box = Unmanaged.passRetained(CallbackBox(view: self))
        callbackBox = box
        mpv_render_context_set_update_callback(renderContext, Self.updateCallback, box.toOpaque())
    }

    // The two C callbacks run on mpv's threads, so they are nonisolated and hop to main for anything else.
    private nonisolated static let procAddress: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _, name in
        guard let name else { return nil }
        let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
        return CFBundleGetFunctionPointerForName(bundle, CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.ASCII.rawValue))
    }

    private nonisolated static let updateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
        // The box outlives this call (it is released after mpv_render_context_free), and the block retains it.
        let box = Unmanaged<CallbackBox>.fromOpaque(ctx!).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { box.view?.renderUpdate() }
        }
    }

    private func renderUpdate() {
        guard let renderContext else { return }
        let flags = mpv_render_context_update(renderContext)
        if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
            pendingFrame = true
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let renderContext else { return }
        openGLContext!.makeCurrentContext()
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &fbo)
        let size = convertToBacking(bounds.size)
        render(renderContext, fbo: fbo, width: Int32(size.width), height: Int32(size.height), flip: 1)
        openGLContext!.flushBuffer()
        mpv_render_context_report_swap(renderContext)
        if pendingFrame && waitingForFrame {
            waitingForFrame = false
            firstFrame?()
        }
        pendingFrame = false
    }
}

extension MPVGLView {
    private func render(_ renderContext: OpaquePointer, fbo: GLint, width: Int32, height: Int32, flip: Int32) {
        var fboParam = mpv_opengl_fbo(fbo: Int32(fbo), w: width, h: height, internal_format: 0)
        var flip = flip
        withUnsafeMutablePointer(to: &fboParam) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(),
                ]
                mpv_render_context_render(renderContext, &params)
            }
        }
    }

    /// The current frame as shown, at the view's pixel size (for Live Text): rendered again into an offscreen
    /// texture and read back. mpv's own screenshot can't read hardware-decoded frames through the render API.
    func snapshot() -> CGImage? {
        guard let renderContext, let context = openGLContext else { return nil }
        context.makeCurrentContext()
        let size = convertToBacking(bounds.size)
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        var previous: GLint = 0, texture: GLuint = 0, fbo: GLuint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &previous)
        glGenTextures(1, &texture)
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA8, GLsizei(width), GLsizei(height), 0, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), nil)
        glGenFramebuffers(1, &fbo)
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), fbo)
        glFramebufferTexture2D(GLenum(GL_FRAMEBUFFER), GLenum(GL_COLOR_ATTACHMENT0), GLenum(GL_TEXTURE_2D), texture, 0)
        defer {
            glBindFramebuffer(GLenum(GL_FRAMEBUFFER), GLuint(previous))
            glDeleteFramebuffers(1, &fbo)
            glDeleteTextures(1, &texture)
        }
        render(renderContext, fbo: GLint(fbo), width: Int32(width), height: Int32(height), flip: 1)
        let rowBytes = width * 4
        var raw = [UInt8](repeating: 0, count: rowBytes * height)
        glReadPixels(0, 0, GLsizei(width), GLsizei(height), GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &raw)
        // glReadPixels returns the bottom row first; CGImage wants the top row first.
        var pixels = Data(count: raw.count)
        pixels.withUnsafeMutableBytes { out in
            raw.withUnsafeBytes { src in
                for row in 0..<height {
                    out.baseAddress!.advanced(by: row * rowBytes)
                        .copyMemory(from: src.baseAddress!.advanced(by: (height - 1 - row) * rowBytes), byteCount: rowBytes)
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

private final class CallbackBox: @unchecked Sendable {
    /// Only read on the main thread.
    weak var view: MPVGLView?
    init(view: MPVGLView) { self.view = view }
}
