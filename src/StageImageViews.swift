import SwiftUI
import ImageIO

// A Read of a picture shows the picture: drawn from the file on disk (the transcript keeps only
// a copy sized for the model), decoded off the main thread at a size the stage can use.

final class ImageFileLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    @Published private(set) var pixelSize: CGSize?
    @Published private(set) var bytes: Int?
    @Published private(set) var loaded = false
    /// Pictures for `--snapshot` renders, used instead of the disk.
    static var previewImages: [String: NSImage] = [:]
    /// Enough pixels for the large stage on a Retina screen.
    private static let maxPixels = 1_600

    func load(_ path: String) {
        guard !loaded else { return }
        if let image = Self.previewImages[path] {
            self.image = image
            pixelSize = image.size
            loaded = true
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: path)
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
            var image: NSImage?
            var size: CGSize?
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                if let w = props?[kCGImagePropertyPixelWidth] as? Int, let h = props?[kCGImagePropertyPixelHeight] as? Int {
                    size = CGSize(width: w, height: h)
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels,
                ]
                if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    image = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
                }
            }
            DispatchQueue.main.async {
                self.image = image
                self.pixelSize = size
                self.bytes = bytes
                self.loaded = true
            }
        }
    }
}

struct ImageReadStage: View {
    let call: ToolCall
    let large: Bool
    @StateObject private var loader = ImageFileLoader()

    private var path: String { call.fields["file_path"] ?? call.summary }
    private var running: Bool { call.finishedAt == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StageFileHeader(path: path, symbol: "photo", subtitle: subtitle, running: running)
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.cardBorder))
        }
        .onAppear { loader.load(path) }
        .id(call.id)
    }

    @ViewBuilder private var picture: some View {
        if let image = loader.image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 8, y: 3)
                .padding(10)
        } else if !loader.loaded {
            ProgressView().controlSize(.small)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 26))
                    .foregroundColor(Theme.tertiaryText)
                Text(L("The picture is no longer on disk", "디스크에서 이미지를 찾지 못했어요"))
                    .font(.system(size: 12))
                    .foregroundColor(Theme.secondaryText)
            }
        }
    }

    /// `PNG · 2560×1440 · 240 KB`, from the Read's result or, while it runs, the file itself.
    private var subtitle: String {
        let format = call.image?.format ?? (path as NSString).pathExtension.uppercased()
        let width = call.image?.width ?? loader.pixelSize.map { Int($0.width) }
        let height = call.image?.height ?? loader.pixelSize.map { Int($0.height) }
        var parts = [(running ? L("Reading ", "읽는 중 · ") : "") + format]
        if let width = width, let height = height { parts.append("\(width)×\(height)") }
        if let bytes = call.image?.bytes ?? loader.bytes { parts.append(Self.size(bytes)) }
        return parts.joined(separator: " · ")
    }

    private static func size(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B"
            : bytes < 1_048_576 ? String(format: "%.0f KB", Double(bytes) / 1024)
            : String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
