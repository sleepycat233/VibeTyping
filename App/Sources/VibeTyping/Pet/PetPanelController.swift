import AppKit
import Combine
import SwiftUI

@MainActor
final class PetPanelController {
    private let panel: NSPanel
    private let animator: PetAnimator
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var accessibilityObserver: NSObjectProtocol?
    private var frameObservation: AnyCancellable?
    private var alphaMask: AlphaMask?
    private let positionXKey = "pet.position.x"
    private let positionYKey = "pet.position.y"
    private let onToggle: () -> Void

    init(atlas: PetAtlas, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        animator = PetAnimator(
            atlas: atlas,
            reducedMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: atlas.grid.cellWidth, height: atlas.grid.cellHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        let root = PetSpriteView(
            animator: animator,
            onTap: onToggle,
            onDrag: { [weak panel] in
                guard let panel else { return }
                let mouse = NSEvent.mouseLocation
                panel.setFrameOrigin(NSPoint(
                    x: mouse.x - panel.frame.width / 2,
                    y: mouse.y - panel.frame.height / 2
                ))
            },
            onDragEnded: { [weak self] in self?.persistPosition() }
        )
        panel.contentView = NSHostingView(rootView: root)
        restorePosition()
        installMouseMonitors()
        frameObservation = animator.$currentFrame.sink { [weak self] image in
            self?.alphaMask = AlphaMask(image)
        }
        accessibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.animator.setReducedMotion(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                )
            }
        }
    }

    deinit {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let accessibilityObserver { NotificationCenter.default.removeObserver(accessibilityObserver) }
    }

    func show() {
        constrainToVisibleScreens()
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    func setState(_ state: PetState) { animator.play(state) }

    func resetPosition() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - panel.frame.width - 24,
            y: visible.minY + 24
        ))
        persistPosition()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
    }

    private func installMouseMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] event in
            self?.updateHitTesting(mouseLocation: NSEvent.mouseLocation)
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) {
            [weak self] _ in
            Task { @MainActor in self?.updateHitTesting(mouseLocation: NSEvent.mouseLocation) }
        }
    }

    private func updateHitTesting(mouseLocation: NSPoint) {
        guard panel.isVisible else { return }
        let local = NSPoint(
            x: mouseLocation.x - panel.frame.minX,
            y: mouseLocation.y - panel.frame.minY
        )
        let hitsBody = alphaMask?.contains(local, viewSize: panel.frame.size) ?? false
        panel.ignoresMouseEvents = !hitsBody
    }

    private func persistPosition() {
        UserDefaults.standard.set(panel.frame.minX, forKey: positionXKey)
        UserDefaults.standard.set(panel.frame.minY, forKey: positionYKey)
    }

    private func restorePosition() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: positionXKey) != nil,
              defaults.object(forKey: positionYKey) != nil else {
            resetPosition()
            return
        }
        panel.setFrameOrigin(NSPoint(
            x: defaults.double(forKey: positionXKey),
            y: defaults.double(forKey: positionYKey)
        ))
        constrainToVisibleScreens()
    }

    private func constrainToVisibleScreens() {
        guard let visible = NSScreen.screens
            .map(\.visibleFrame)
            .max(by: { intersectionArea($0, panel.frame) < intersectionArea($1, panel.frame) })
            ?? NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: min(max(panel.frame.minX, visible.minX), visible.maxX - panel.frame.width),
            y: min(max(panel.frame.minY, visible.minY), visible.maxY - panel.frame.height)
        ))
        persistPosition()
    }

    private func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}

private struct PetSpriteView: View {
    @ObservedObject var animator: PetAnimator
    let onTap: () -> Void
    let onDrag: () -> Void
    let onDragEnded: () -> Void

    var body: some View {
        Image(decorative: animator.currentFrame, scale: 1)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
        .frame(width: 192, height: 208)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .simultaneousGesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in onDrag() }
                .onEnded { _ in onDragEnded() }
        )
    }
}

private struct AlphaMask {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] }
    }

    func contains(_ point: NSPoint, viewSize: NSSize) -> Bool {
        guard point.x >= 0, point.y >= 0, point.x < viewSize.width, point.y < viewSize.height else {
            return false
        }
        let x = min(width - 1, max(0, Int(point.x / viewSize.width * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y / viewSize.height * CGFloat(height))))
        return bytes[y * width + x] > 20
    }
}
