import SpektraEngine
import SwiftUI

/// The Crop tab: turning the photo, straightening it, and the crop's shape. The crop itself is
/// dragged on the canvas (``CropOverlay``).
struct CropPanel: View {
    @Environment(PhotoModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Rotate").font(.system(size: 14))
                    HStack {
                        Button("Left", systemImage: "rotate.left") { model.rotate(clockwise: false) }
                            .help("Turn the photo a quarter anticlockwise (⌘[)")
                        Button("Right", systemImage: "rotate.right") { model.rotate(clockwise: true) }
                            .help("Turn the photo a quarter clockwise (⌘])")
                    }
                    .controlSize(.large)
                    ValueSlider("Straighten", value: Binding { model.framing.straighten } set: { model.controls.straighten = $0 },
                                in: -45...45, step: 0.1, neutral: 0, format: .number.precision(.fractionLength(1)), unit: "°")
                        .help("Turns the photo by up to 45° to level a horizon. It's enlarged so no corner shows.")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Crop").font(.system(size: 14))
                    HStack {
                        Picker("Aspect", selection: Binding { model.cropAspect } set: { model.chooseCropAspect($0) }) {
                            ForEach(CropAspect.allCases) { aspect in
                                Text(aspect.rawValue).tag(aspect)
                                if aspect == .original { Divider() }
                            }
                        }
                        .labelsHidden()
                        Button("Swap", systemImage: model.cropIsPortrait ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
                            model.toggleCropOrientation()
                        }
                        .labelStyle(.iconOnly)
                        .help("Swap the crop between wide and tall")
                        .disabled(model.cropAspect == .free || model.cropAspect == .square)
                    }
                    Text(sizeText)
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text("Drag the corners or edges of the photo to crop it, and inside the crop to move it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Reset Crop & Rotation") { model.resetFraming() }
                    .disabled(model.framing.isIdentity)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(model.photo == nil)
    }

    /// The finished photo's size in pixels.
    private var sizeText: String {
        let size = model.framing.croppedSize(of: model.photoSize)
        guard size.width > 0 else { return " " }
        return "\(Int(size.width.rounded()).formatted()) × \(Int(size.height.rounded()).formatted()) px"
    }
}

/// The crop over the whole turned photo on the canvas, `size` points: the rest dimmed, the crop's
/// thirds, and handles on its corners and edges to drag, held to the panel's shape if it has one.
struct CropOverlay: View {
    @Environment(PhotoModel.self) private var model
    let size: CGSize
    /// The crop when the drag began.
    @State private var dragStart: CGRect?

    /// A corner or edge of the crop, by which of its sides it moves (−1 the minimum, 1 the maximum).
    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var x: Int {
            switch self {
            case .topLeft, .left, .bottomLeft: -1
            case .top, .bottom: 0
            case .topRight, .right, .bottomRight: 1
            }
        }
        var y: Int {
            switch self {
            case .topLeft, .top, .topRight: -1
            case .left, .right: 0
            case .bottomLeft, .bottom, .bottomRight: 1
            }
        }
        var position: FrameResizePosition {
            switch self {
            case .topLeft: .topLeading
            case .top: .top
            case .topRight: .topTrailing
            case .right: .trailing
            case .bottomRight: .bottomTrailing
            case .bottom: .bottom
            case .bottomLeft: .bottomLeading
            case .left: .leading
            }
        }
    }

    var body: some View {
        let crop = model.framing.crop
        let rect = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                          width: crop.width * size.width, height: crop.height * size.height)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                path.addRect(rect)
            }
            .fill(.black.opacity(dragStart == nil ? 0.6 : 0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Path { path in
                for third in [1.0 / 3, 2.0 / 3] {
                    path.move(to: CGPoint(x: rect.minX + rect.width * third, y: rect.minY))
                    path.addLine(to: CGPoint(x: rect.minX + rect.width * third, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * third))
                    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * third))
                }
            }
            .stroke(.white.opacity(dragStart == nil ? 0.35 : 0.7), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(.white, lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            // Inside the crop: moves it.
            Color.clear
                .contentShape(.rect)
                .frame(width: max(0, rect.width - 24), height: max(0, rect.height - 24))
                .offset(x: rect.minX + 12, y: rect.minY + 12)
                .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
                .gesture(drag(nil))
            ForEach(Handle.allCases, id: \.self) { handle in
                handleMark(handle)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
                    .pointerStyle(.frameResize(position: handle.position))
                    .gesture(drag(handle))
                    .position(x: rect.midX + CGFloat(handle.x) * rect.width / 2,
                              y: rect.midY + CGFloat(handle.y) * rect.height / 2)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// A corner's L, or an edge's bar, on the crop's border.
    @ViewBuilder private func handleMark(_ handle: Handle) -> some View {
        let length: CGFloat = 18, thickness: CGFloat = 4
        if handle.x != 0 && handle.y != 0 {
            Path { path in
                // From the corner along both sides, inside the crop.
                let corner = CGPoint(x: 14 - CGFloat(handle.x) * thickness / 2, y: 14 - CGFloat(handle.y) * thickness / 2)
                path.move(to: CGPoint(x: corner.x - CGFloat(handle.x) * length, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y - CGFloat(handle.y) * length))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: thickness, lineCap: .square))
        } else {
            Capsule()
                .fill(.white)
                .frame(width: handle.x == 0 ? length + 4 : thickness, height: handle.y == 0 ? length + 4 : thickness)
                .offset(x: -CGFloat(handle.x) * thickness / 2, y: -CGFloat(handle.y) * thickness / 2)
        }
    }

    /// Moves the crop (`handle` nil) or one of its corners or edges, as one undo step.
    private func drag(_ handle: Handle?) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .local)
            .onChanged { drag in
                if dragStart == nil {
                    model.beginChange()
                    dragStart = model.framing.crop
                }
                guard let start = dragStart, size.width > 0, size.height > 0 else { return }
                let delta = CGSize(width: drag.translation.width / size.width, height: drag.translation.height / size.height)
                let crop = handle.map { resized(start, by: $0, delta: delta, ratio: model.cropFractionRatio) }
                    ?? moved(start, by: delta)
                if crop != model.framing.crop {
                    model.controls.framing.crop = crop
                }
            }
            .onEnded { _ in
                dragStart = nil
                model.endChange()
            }
    }

    private static let smallest: CGFloat = 0.05

    private func moved(_ crop: CGRect, by delta: CGSize) -> CGRect {
        CGRect(x: min(max(crop.minX + delta.width, 0), 1 - crop.width),
               y: min(max(crop.minY + delta.height, 0), 1 - crop.height),
               width: crop.width, height: crop.height)
    }

    /// `crop` with `handle`'s sides moved by `delta`, within the photo; held to `ratio` (width over
    /// height, as fractions of the photo) if given, from the opposite corner or edge.
    private func resized(_ crop: CGRect, by handle: Handle, delta: CGSize, ratio: CGFloat?) -> CGRect {
        var minX = crop.minX, maxX = crop.maxX, minY = crop.minY, maxY = crop.maxY
        if handle.x < 0 { minX = min(max(crop.minX + delta.width, 0), crop.maxX - Self.smallest) }
        if handle.x > 0 { maxX = max(min(crop.maxX + delta.width, 1), crop.minX + Self.smallest) }
        if handle.y < 0 { minY = min(max(crop.minY + delta.height, 0), crop.maxY - Self.smallest) }
        if handle.y > 0 { maxY = max(min(crop.maxY + delta.height, 1), crop.minY + Self.smallest) }
        guard let ratio else { return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) }

        // The width, from whichever side moved further, limited by the room from the anchor.
        var width = maxX - minX, height = maxY - minY
        if handle.x != 0 && handle.y != 0 {
            width = max(width, height * ratio)
        } else if handle.y != 0 {
            width = height * ratio
        }
        let roomX: CGFloat = switch handle.x {
        case -1: crop.maxX
        case 1: 1 - crop.minX
        default: 1
        }
        let roomY: CGFloat = switch handle.y {
        case -1: crop.maxY
        case 1: 1 - crop.minY
        default: 1
        }
        width = min(width, roomX, roomY * ratio)
        width = max(width, Self.smallest, Self.smallest * ratio)
        height = width / ratio
        // From the anchor: the opposite side, or the centre across an edge.
        let x: CGFloat = switch handle.x {
        case -1: crop.maxX - width
        case 1: crop.minX
        default: min(max(crop.midX - width / 2, 0), 1 - width)
        }
        let y: CGFloat = switch handle.y {
        case -1: crop.maxY - height
        case 1: crop.minY
        default: min(max(crop.midY - height / 2, 0), 1 - height)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
