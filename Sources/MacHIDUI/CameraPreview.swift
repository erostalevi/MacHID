import AVFoundation
import AppKit
import SwiftUI

/// Live camera preview for a UVC camera (matched by name and USB VID:PID, e.g. "046d:094c").
/// Starts only while on screen; nothing is recorded.
public struct CameraPreviewView: View {
    private let deviceName: String
    private let usbID: String
    @StateObject private var model = CameraPreviewModel()
    @AppStorage("cameraPreviewMirrored") private var mirrored = true

    public init(deviceName: String, usbID: String) {
        self.deviceName = deviceName
        self.usbID = usbID
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            if model.state == .live || model.state == .starting {
                PreviewLayerView(session: model.controller.session, mirrored: mirrored)
                    .accessibilityHidden(true)
            }
            overlay
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .topLeading) { if model.state == .live { livePill.padding(10) } }
        .overlay(alignment: .topTrailing) {
            if model.state == .live {
                Toggle("Mirrored", isOn: $mirrored)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .flatSurface(cornerRadius: 12)
                    .padding(10)
                    .accessibilityLabel(Text("Mirror preview"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Camera preview"))
        .onAppear { model.appear(deviceName: deviceName, usbID: usbID) }
        .onDisappear { model.disappear() }
    }

    private var livePill: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Text("LIVE").font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .flatSurface(cornerRadius: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Live preview"))
    }

    @ViewBuilder private var overlay: some View {
        switch model.state {
        case .live: EmptyView()
        case .starting: ProgressView().controlSize(.small)
        case .needsPermission:
            message("Camera preview needs your permission.", button: "Allow camera preview", action: model.requestAccess)
        case .denied:
            message("Camera access is turned off for MacHID.", button: "Open Privacy Settings", action: model.openPrivacySettings)
        case .notFound:
            message("Camera not found. Check that it is plugged in.", button: "Try again", action: model.retry)
        case .busy:
            message("The camera is busy or unavailable. Close other apps using it.", button: "Try again", action: model.retry)
        }
    }

    private func message(_ text: LocalizedStringKey, button: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "video.slash").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(text).font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(action: action) { Text(button).padding(.horizontal, 6) }
                .buttonStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .flatSurface(cornerRadius: 14, tint: .accentColor)
        }
        .padding(16)
    }
}

/// Layer-backed host for AVCaptureVideoPreviewLayer; mirroring flips the layer, no per-frame SwiftUI work.
private struct PreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.setMirrored(mirrored)
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) { view.setMirrored(mirrored) }
}

private final class PreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    func setMirrored(_ on: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        previewLayer.transform = on ? CATransform3DMakeScale(-1, 1, 1) : CATransform3DIdentity
        CATransaction.commit()
    }
}
