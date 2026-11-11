import SwiftUI

// MARK: - Story Game Portrait Cropper
//
// Sheet that lets the user pick a square crop from an uploaded image and
// saves the cropped portrait into the project's `portraits/` folder as a
// 256x256 PNG.

struct StoryGamePortraitCropper: View {
    let imageURL: URL
    let projectURL: URL
    let characterID: String
    @Binding var isPresented: Bool
    let onSave: (URL) -> Void

    @State private var nsImage: NSImage?
    @State private var pixelSize: CGSize = .zero
    @State private var normalizedCrop: CGRect = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    @State private var dragStartCrop: CGRect?
    @State private var errorMessage: String?

    private let outputSize: CGFloat = 256

    var body: some View {
        VStack(spacing: 16) {
            Text("Crop Portrait")
                .font(.headline)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }

            GeometryReader { geometry in
                if let nsImage, pixelSize.width > 0, pixelSize.height > 0 {
                    cropStage(geometry: geometry, nsImage: nsImage)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320, minHeight: 320)

            HStack {
                Text("Zoom")
                Slider(
                    value: Binding(
                        get: { normalizedCrop.width },
                        set: { adjustZoom(to: $0) }
                    ),
                    in: 0.1...1.0
                )
                .frame(width: 160)
            }

            HStack(spacing: 16) {
                Button("Cancel", role: .cancel) { isPresented = false }
                Spacer()
                Button("Save Portrait") { saveCroppedImage() }
                    .buttonStyle(.borderedProminent)
                    .disabled(nsImage == nil)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 480)
        .onAppear(perform: loadImage)
    }

    // MARK: - Crop stage

    @ViewBuilder
    private func cropStage(geometry: GeometryProxy, nsImage: NSImage) -> some View {
        let container = geometry.size
        let imageFrame = aspectFitFrame(
            contentSize: pixelSize,
            containerSize: container
        )
        let cropFrame = displayCropFrame(in: imageFrame)

        ZStack {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)

            dimmingOverlay(container: container, cropFrame: cropFrame)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 2)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            handleDrag(value: value, imageFrame: imageFrame)
                        }
                        .onEnded { _ in
                            dragStartCrop = nil
                        }
                )
        }
    }

    private func dimmingOverlay(container: CGSize, cropFrame: CGRect) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: container))
            path.addRect(cropFrame)
        }
        .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    // MARK: - Coordinate math

    private func aspectFitFrame(contentSize: CGSize, containerSize: CGSize) -> CGRect {
        let contentAspect = contentSize.width / max(contentSize.height, 1)
        let containerAspect = containerSize.width / max(containerSize.height, 1)
        let fitSize: CGSize
        if contentAspect > containerAspect {
            fitSize = CGSize(width: containerSize.width,
                             height: containerSize.width / contentAspect)
        } else {
            fitSize = CGSize(width: containerSize.height * contentAspect,
                             height: containerSize.height)
        }
        return CGRect(
            x: (containerSize.width - fitSize.width) / 2,
            y: (containerSize.height - fitSize.height) / 2,
            width: fitSize.width,
            height: fitSize.height
        )
    }

    private func displayCropFrame(in imageFrame: CGRect) -> CGRect {
        let origin = CGPoint(
            x: imageFrame.origin.x + normalizedCrop.origin.x * imageFrame.width,
            y: imageFrame.origin.y + normalizedCrop.origin.y * imageFrame.height
        )
        let size = CGSize(
            width: normalizedCrop.width * imageFrame.width,
            height: normalizedCrop.height * imageFrame.height
        )
        return CGRect(origin: origin, size: size)
    }

    private func handleDrag(value: DragGesture.Value, imageFrame: CGRect) {
        if dragStartCrop == nil {
            dragStartCrop = normalizedCrop
        }
        guard let start = dragStartCrop else { return }

        let deltaX = value.translation.width / imageFrame.width
        let deltaY = value.translation.height / imageFrame.height

        var next = start.offsetBy(dx: deltaX, dy: deltaY)
        next.origin.x = max(0, min(1 - next.width, next.origin.x))
        next.origin.y = max(0, min(1 - next.height, next.origin.y))
        normalizedCrop = next
    }

    private func adjustZoom(to newWidth: CGFloat) {
        let centerX = normalizedCrop.midX
        let centerY = normalizedCrop.midY
        var next = normalizedCrop
        next.size.width = newWidth
        next.size.height = newWidth
        next.origin.x = centerX - next.width / 2
        next.origin.y = centerY - next.height / 2
        next.origin.x = max(0, min(1 - next.width, next.origin.x))
        next.origin.y = max(0, min(1 - next.height, next.origin.y))
        normalizedCrop = next
    }

    // MARK: - Image loading

    private func loadImage() {
        guard let image = NSImage(contentsOf: imageURL),
              let rep = bestBitmapRep(for: image) else {
            errorMessage = "Could not load image."
            return
        }
        nsImage = image
        pixelSize = CGSize(width: CGFloat(rep.pixelsWide),
                           height: CGFloat(rep.pixelsHigh))
        resetCropToCenter()
    }

    private func bestBitmapRep(for image: NSImage) -> NSBitmapImageRep? {
        image.representations.compactMap { $0 as? NSBitmapImageRep }.first
    }

    private func resetCropToCenter() {
        let side: CGFloat = 0.5
        normalizedCrop = CGRect(
            x: (1 - side) / 2,
            y: (1 - side) / 2,
            width: side,
            height: side
        )
    }

    // MARK: - Save

    private func saveCroppedImage() {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            errorMessage = "Could not read image data."
            return
        }

        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let cropPixelRect = CGRect(
            x: normalizedCrop.origin.x * width,
            y: normalizedCrop.origin.y * height,
            width: normalizedCrop.size.width * width,
            height: normalizedCrop.size.height * height
        )
        .integral

        guard let cropped = cgImage.cropping(to: cropPixelRect) else {
            errorMessage = "Could not crop image."
            return
        }

        let resized = cropped.resized(to: CGSize(width: outputSize, height: outputSize))
        guard let pngData = NSBitmapImageRep(cgImage: resized)
            .representation(using: .png, properties: [:]) else {
            errorMessage = "Could not encode PNG."
            return
        }

        do {
            let portraitsDir = projectURL.appendingPathComponent("portraits", isDirectory: true)
            try FileManager.default.createDirectory(
                at: portraitsDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let destination = portraitsDir
                .appendingPathComponent(characterID)
                .appendingPathExtension("png")
            try pngData.write(to: destination, options: .atomic)
            onSave(destination)
            isPresented = false
        } catch {
            errorMessage = "Failed to save portrait: \(error.localizedDescription)"
        }
    }
}

// MARK: - CGImage resize helper

extension CGImage {
    func resized(to newSize: CGSize) -> CGImage {
        let width = Int(newSize.width)
        let height = Int(newSize.height)
        let bitsPerComponent = 8
        let bytesPerRow = 4 * width
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return self
        }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(origin: .zero, size: newSize))
        return context.makeImage() ?? self
    }
}
