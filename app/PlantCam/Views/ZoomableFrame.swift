import SwiftUI

/// Remembers how far a picture is zoomed and where. Share one between pictures to zoom them together.
@MainActor
final class ZoomState: ObservableObject {
    @Published var scale: CGFloat = 1
    @Published var offset: CGSize = .zero
    var baseScale: CGFloat = 1
    var baseOffset: CGSize = .zero

    var isZoomed: Bool { scale > 1.02 }

    func reset(animated: Bool = true) {
        let apply = {
            self.scale = 1
            self.offset = .zero
        }
        if animated {
            withAnimation(.easeOut(duration: 0.2), apply)
        } else {
            apply()
        }
        baseScale = 1
        baseOffset = .zero
    }
}

/// Pinch to zoom, drag to move when zoomed, double-tap to zoom in or back out.
struct ZoomableFrame<Content: View>: View {
    @ObservedObject var zoom: ZoomState
    let maxScale: CGFloat
    let content: Content

    init(zoom: ZoomState, maxScale: CGFloat = 8, @ViewBuilder content: () -> Content) {
        _zoom = ObservedObject(wrappedValue: zoom)
        self.maxScale = maxScale
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                content
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(zoom.scale)
                    .offset(zoom.offset)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .clipped()
            // Dragging only takes over once zoomed, so an unzoomed swipe still scrolls the page.
            .gesture(pan(size), including: zoom.isZoomed ? .all : .subviews)
            .simultaneousGesture(pinch(size))
            .simultaneousGesture(doubleTap(size))
        }
    }

    private func pinch(_ size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let target = min(maxScale, max(1, zoom.baseScale * value.magnification))
                let ratio = target / max(0.01, zoom.baseScale)
                // Keep the spot under your fingers where it is while the picture grows.
                let ax = value.startLocation.x - size.width / 2
                let ay = value.startLocation.y - size.height / 2
                let moved = CGSize(
                    width: zoom.baseOffset.width + (1 - ratio) * (ax - zoom.baseOffset.width),
                    height: zoom.baseOffset.height + (1 - ratio) * (ay - zoom.baseOffset.height)
                )
                zoom.scale = target
                zoom.offset = clamp(moved, scale: target, size: size)
            }
            .onEnded { _ in
                if zoom.scale < 1.05 {
                    zoom.reset()
                } else {
                    zoom.baseScale = zoom.scale
                    zoom.baseOffset = zoom.offset
                }
            }
    }

    private func pan(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let moved = CGSize(
                    width: zoom.baseOffset.width + value.translation.width,
                    height: zoom.baseOffset.height + value.translation.height
                )
                zoom.offset = clamp(moved, scale: zoom.scale, size: size)
            }
            .onEnded { _ in
                zoom.baseOffset = zoom.offset
            }
    }

    private func doubleTap(_ size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                if zoom.isZoomed {
                    zoom.reset()
                    return
                }
                let target: CGFloat = 2.5
                let ax = value.location.x - size.width / 2
                let ay = value.location.y - size.height / 2
                let moved = clamp(
                    CGSize(width: (1 - target) * ax, height: (1 - target) * ay),
                    scale: target,
                    size: size
                )
                withAnimation(.easeOut(duration: 0.2)) {
                    zoom.scale = target
                    zoom.offset = moved
                }
                zoom.baseScale = target
                zoom.baseOffset = moved
            }
    }

    private func clamp(_ offset: CGSize, scale: CGFloat, size: CGSize) -> CGSize {
        let limitX = size.width * (scale - 1) / 2
        let limitY = size.height * (scale - 1) / 2
        return CGSize(
            width: min(limitX, max(-limitX, offset.width)),
            height: min(limitY, max(-limitY, offset.height))
        )
    }
}

/// A small pill that shows the zoom and puts it back to normal.
struct ZoomResetButton: View {
    @ObservedObject var zoom: ZoomState

    var body: some View {
        if zoom.isZoomed {
            Button {
                zoom.reset()
            } label: {
                Label(String(format: "%.1f\u{00D7}", Double(zoom.scale)), systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(10)
            .accessibilityLabel("Reset zoom")
        }
    }
}
