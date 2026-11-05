// Throwaway prototype. libmpv rendered into an NSOpenGLView through mpv's render API.
import AppKit
import CMpv
import OpenGL.GL3

final class MPVGLView: NSOpenGLView {
    private let mpv: OpaquePointer
    private var renderContext: OpaquePointer?
    /// Called on the main thread for the first draw that carries a real video frame after `armFirstFrame()`.
    var onFirstFrame: (() -> Void)?
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

    func armFirstFrame() { waitingForFrame = true }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        openGLContext!.makeCurrentContext()
        var swapInterval: GLint = 1
        openGLContext!.setValues(&swapInterval, for: .swapInterval)

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                return CFBundleGetFunctionPointerForName(bundle, CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.ASCII.rawValue))
            },
            get_proc_address_ctx: nil)
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
        mpv_render_context_set_update_callback(renderContext, { ctx in
            let view = Unmanaged<MPVGLView>.fromOpaque(ctx!).takeUnretainedValue()
            DispatchQueue.main.async { view.renderUpdate() }
        }, Unmanaged.passUnretained(self).toOpaque())
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
        var fboParam = mpv_opengl_fbo(fbo: Int32(fbo), w: Int32(size.width), h: Int32(size.height), internal_format: 0)
        var flip: Int32 = 1
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
        openGLContext!.flushBuffer()
        mpv_render_context_report_swap(renderContext)
        if pendingFrame && waitingForFrame {
            waitingForFrame = false
            onFirstFrame?()
        }
        pendingFrame = false
    }
}
