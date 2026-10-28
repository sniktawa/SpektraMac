import CoreGraphics
import CoreImage
import SpektraEngine

/// How a photo is framed (``Controls/rotation`` and the rest): turned, straightened and cropped.
/// Applied to the render, never in it, so changing it renders nothing again: the canvas turns and
/// crops the render it shows, and saving and exporting the finished image (``apply(to:)``).
nonisolated struct Framing: Hashable, Sendable {
    /// Quarter turns clockwise, 0–3.
    var rotation = 0
    /// Degrees clockwise, −45…45.
    var straighten = 0.0
    /// Fractions of the turned photo's width and height, from its top left.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    var isIdentity: Bool { quarterTurns == 0 && straighten == 0 && crop == Self.whole }
    var isCropped: Bool { crop != Self.whole }
    var quarterTurns: Int { ((rotation % 4) + 4) % 4 }

    /// A photo of `size` after the quarter turns.
    func turnedSize(of size: CGSize) -> CGSize {
        quarterTurns.isMultiple(of: 2) ? size : CGSize(width: size.height, height: size.width)
    }

    /// The finished photo's size, for a photo of `size`.
    func croppedSize(of size: CGSize) -> CGSize {
        let turned = turnedSize(of: size)
        return CGSize(width: turned.width * crop.width, height: turned.height * crop.height)
    }

    /// How much the straightened photo is enlarged so it still covers its turned frame, of `turned`
    /// size, with no corner showing.
    func straightenScale(for turned: CGSize) -> CGFloat {
        guard straighten != 0, turned.width > 0, turned.height > 0 else { return 1 }
        let angle = abs(straighten) * .pi / 180
        let ratio = max(turned.width / turned.height, turned.height / turned.width)
        return cos(angle) + ratio * sin(angle)
    }

    /// The crop brought within the photo, at least 5 % of it a side.
    var checked: Framing {
        var framing = self
        framing.rotation = quarterTurns
        framing.straighten = min(max(straighten, -45), 45)
        let width = min(max(crop.width, 0.05), 1), height = min(max(crop.height, 0.05), 1)
        framing.crop = CGRect(x: min(max(crop.minX, 0), 1 - width), y: min(max(crop.minY, 0), 1 - height),
                              width: width, height: height)
        return framing
    }

    /// Turned a quarter clockwise (or anticlockwise), the crop with it.
    func turned(clockwise: Bool) -> Framing {
        var framing = self
        framing.rotation = quarterTurns + (clockwise ? 1 : 3)
        framing.rotation %= 4
        framing.crop = clockwise
            ? CGRect(x: 1 - crop.maxY, y: crop.minX, width: crop.height, height: crop.width)
            : CGRect(x: crop.minY, y: 1 - crop.maxX, width: crop.height, height: crop.width)
        return framing
    }

    /// `image` turned, straightened and cropped. Core Image's origin is at the bottom left.
    func apply(to image: CIImage) -> CIImage {
        let size = image.extent.size
        let turned = turnedSize(of: size)
        let angle = -(Double(quarterTurns) * 90 + straighten) * .pi / 180
        let scale = straightenScale(for: turned)
        let transform = CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: turned.width / 2, y: turned.height / 2))
        // Rounded to whole pixels, so the file has no half-covered edge.
        let region = CGRect(x: crop.minX * turned.width, y: (1 - crop.maxY) * turned.height,
                            width: crop.width * turned.width, height: crop.height * turned.height).integral
            .intersection(CGRect(origin: .zero, size: turned))
        // Clamped first, so the edges it samples past are the photo's, not transparent.
        return image.clampedToExtent().transformed(by: transform)
            .cropped(to: region)
            .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
    }

    /// The context framing renders with: in floating point, so 16-bit exports keep their depth.
    static let context = CIContext(options: [.workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

    /// `image` framed, in its own colour space and depth; itself if the framing changes nothing.
    func apply(to image: CGImage) -> CGImage {
        guard !isIdentity else { return image }
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        let framed = apply(to: CIImage(cgImage: image, options: [.colorSpace: colorSpace]))
        let format: CIFormat = image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8
        return Self.context.createCGImage(framed, from: framed.extent, format: format, colorSpace: colorSpace) ?? image
    }
}

nonisolated extension Controls {
    /// The photo's framing (``Framing``).
    var framing: Framing {
        get {
            Framing(rotation: rotation, straighten: straighten,
                    crop: CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight))
        }
        set {
            rotation = newValue.rotation
            straighten = newValue.straighten
            (cropX, cropY, cropWidth, cropHeight) = (newValue.crop.minX, newValue.crop.minY,
                                                     newValue.crop.width, newValue.crop.height)
        }
    }

    /// The controls the engine renders: with the framing at its default, so renders and kept
    /// renders are the same whatever the crop.
    var unframed: Controls {
        var controls = self
        controls.framing = Framing()
        return controls
    }
}

/// The shapes the crop can be held to, as width over height of the finished photo.
enum CropAspect: String, CaseIterable, Identifiable {
    case free = "Freeform", original = "Original", square = "Square", fourByFive = "4 : 5", fiveBySeven = "5 : 7",
         twoByThree = "2 : 3", threeByFour = "3 : 4", nineBySixteen = "9 : 16"

    var id: Self { self }

    /// The ratio, the long side over the short one: nil for a free one. `original` is the photo's.
    func ratio(photo size: CGSize) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: size.width > 0 && size.height > 0 ? max(size.width, size.height) / min(size.width, size.height) : nil
        case .square: 1
        case .fourByFive: 5 / 4
        case .fiveBySeven: 7 / 5
        case .twoByThree: 3 / 2
        case .threeByFour: 4 / 3
        case .nineBySixteen: 16 / 9
        }
    }
}
