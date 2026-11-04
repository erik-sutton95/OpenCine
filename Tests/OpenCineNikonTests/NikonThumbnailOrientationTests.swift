#if canImport(ImageIO)
    import CoreGraphics
    import Foundation
    import ImageIO
    import Testing

    @testable import OpenCineNikon

    /// The camera's `GetThumb` JPEG is a small copy of the stored pixels and carries no orientation of
    /// its own; only the still itself records how the body was held. The Media grid draws the
    /// thumbnail the way the iOS cell loader does (ImageIO with the EXIF transform), so a portrait
    /// still must come out of the thumbnail reader already tagged.
    @Suite("Camera thumbnails of stills show upright")
    struct NikonThumbnailOrientationTests {
        /// A picture as the photographer framed it: the top-left quadrant red, the rest blue.
        private struct Scene {
            let width: Int
            let height: Int

            func isRed(x: Int, y: Int) -> Bool { x < width / 2 && y < height / 2 }
        }

        /// A camera object: the still's bytes and its `GetThumb` JPEG, with every read recorded.
        private final class CameraObject: @unchecked Sendable {
            let original: [UInt8]
            let thumbnail: Data
            var headReads: [UInt32] = []
            var failsHeadRead = false

            init(original: [UInt8], thumbnail: Data) {
                self.original = original
                self.thumbnail = thumbnail
            }

            func readThumbnail() -> Data? { thumbnail }

            func readHead(_ length: UInt32) throws -> Data {
                headReads.append(length)
                if failsHeadRead { throw CocoaError(.fileReadUnknown) }
                return Data(original.prefix(Int(length)))
            }
        }

        /// The scene a still with `orientation` shows upright: the body held vertically (5 to 8)
        /// frames a portrait.
        private static func scene(_ orientation: UInt16) -> Scene {
            orientation >= 5 ? Scene(width: 60, height: 80) : Scene(width: 80, height: 60)
        }

        /// The pixels the sensor recorded for `scene`: the scene turned back by the transform the
        /// EXIF orientation tells a viewer to apply (TIFF 6.0, tag 0x0112).
        private static func sensorImage(_ scene: Scene, orientation: UInt16) throws -> CGImage {
            let rotated = orientation == 6 || orientation == 8
            let width = rotated ? scene.height : scene.width
            let height = rotated ? scene.width : scene.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height {
                for x in 0..<width {
                    // Where stored pixel (x, y) lands once the viewer applies the orientation.
                    let (sx, sy): (Int, Int)
                    switch orientation {
                    case 3: (sx, sy) = (scene.width - 1 - x, scene.height - 1 - y)
                    case 6: (sx, sy) = (scene.width - 1 - y, x)
                    case 8: (sx, sy) = (y, scene.height - 1 - x)
                    default: (sx, sy) = (x, y)
                    }
                    let red = scene.isRed(x: sx, y: sy)
                    let index = (y * width + x) * 4
                    pixels[index] = red ? 255 : 0
                    pixels[index + 2] = red ? 0 : 255
                    pixels[index + 3] = 255
                }
            }
            let context = try #require(
                CGContext(
                    data: &pixels, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try #require(context.makeImage())
        }

        private static func jpeg(_ image: CGImage, properties: [CFString: Any] = [:]) throws -> Data
        {
            let data = NSMutableData()
            let destination = try #require(
                CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
            var options = properties
            options[kCGImageDestinationLossyCompressionQuality] = 0.95
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
            #expect(CGImageDestinationFinalize(destination))
            return data as Data
        }

        /// A still as the body writes it: the sensor pixels with the orientation in EXIF.
        private static func stillJPEG(_ scene: Scene, orientation: UInt16) throws -> [UInt8] {
            let image = try sensorImage(scene, orientation: orientation)
            return [UInt8](try jpeg(image, properties: [kCGImagePropertyOrientation: orientation]))
        }

        /// The body's `GetThumb` reply: the same sensor pixels, no EXIF (ImageIO adds an EXIF
        /// segment of its own, which is dropped here).
        private static func cameraThumbnail(
            _ scene: Scene, orientation: UInt16, keepingExif: Bool = false
        ) throws -> Data {
            let thumbnail = try jpeg(try sensorImage(scene, orientation: orientation))
            return keepingExif ? thumbnail : withoutExif(thumbnail)
        }

        /// `jpeg` without its APP1 `Exif` segments.
        private static func withoutExif(_ jpeg: Data) -> Data {
            let bytes = [UInt8](jpeg)
            var kept: [UInt8] = [0xFF, 0xD8]
            var offset = 2
            while offset + 4 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] != 0xDA {
                let end = offset + 2 + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
                let isExif =
                    bytes[offset + 1] == 0xE1
                    && Array(bytes[(offset + 4)..<(offset + 8)]) == Array("Exif".utf8)
                if !isExif { kept += bytes[offset..<end] }
                offset = end
            }
            kept += bytes[offset...]
            #expect(Data(kept).range(of: Data("Exif".utf8)) == nil)
            return Data(kept)
        }

        /// What a Media cell shows: the cell loader's bounded ImageIO decode with the EXIF transform.
        private static func shown(_ data: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let options =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 640,
                ] as [CFString: Any] as CFDictionary
            let image = try #require(CGImageSourceCreateThumbnailAtIndex(source, 0, options))
            var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let context = try #require(
                CGContext(
                    data: &rgba, width: image.width, height: image.height, bitsPerComponent: 8,
                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return (image.width, image.height, rgba)
        }

        /// The scene as framed: the same size, red only in the top-left quadrant.
        private static func expectUpright(_ data: Data, as scene: Scene) throws {
            let picture = try shown(data)
            #expect(picture.width == scene.width)
            #expect(picture.height == scene.height)
            guard picture.width == scene.width, picture.height == scene.height else { return }
            for (qx, qy) in [(1, 1), (3, 1), (1, 3), (3, 3)] {
                let x = scene.width * qx / 4
                let y = scene.height * qy / 4
                let index = (y * picture.width + x) * 4
                let isRed = picture.rgba[index] > 160 && picture.rgba[index + 2] < 96
                #expect(isRed == scene.isRed(x: x, y: y), "quadrant at \(x),\(y)")
            }
        }

        /// The Android facade's blocking read, as the JNI thumbnail call makes it.
        private static func blockingThumbnail(_ filename: String, _ camera: CameraObject) throws
            -> Data?
        {
            try NikonThumbnailOrientation.uprightThumbnail(
                filename: filename, readThumbnail: camera.readThumbnail, readHead: camera.readHead)
        }

        @Test(arguments: [UInt16(1), 3, 6, 8])
        func aJPEGStillsThumbnailShowsAsFramed(orientation: UInt16) async throws {
            let scene = Self.scene(orientation)
            let camera = CameraObject(
                original: try Self.stillJPEG(scene, orientation: orientation),
                thumbnail: try Self.cameraThumbnail(scene, orientation: orientation))

            let blocking = try #require(try Self.blockingThumbnail("_NZR2887.JPG", camera))
            let async = try #require(
                try await NikonThumbnailOrientation.uprightThumbnail(
                    filename: "_NZR2887.JPG", readThumbnail: { camera.readThumbnail() },
                    readHead: { try camera.readHead($0) }))

            try Self.expectUpright(blocking, as: scene)
            #expect(async == blocking)
            if orientation == 1 { #expect(blocking == camera.thumbnail) }
            // One small read of the still's head per thumbnail, never the whole file.
            #expect(
                camera.headReads == [
                    NikonThumbnailOrientation.headLength, NikonThumbnailOrientation.headLength,
                ])
            #expect(NikonThumbnailOrientation.headLength <= 16 * 1024)
        }

        @Test(arguments: [UInt16(3), 6, 8])
        func aRAWStillsThumbnailShowsAsFramed(orientation: UInt16) throws {
            let scene = Self.scene(orientation)
            let nef = NEFFixture.zStyleNEF(littleEndian: orientation != 8, orientation: orientation)
            let camera = CameraObject(
                original: nef.bytes,
                thumbnail: try Self.cameraThumbnail(scene, orientation: orientation))

            let thumbnail = try #require(
                try Self.blockingThumbnail("_NZR1697.NEF", camera))

            try Self.expectUpright(thumbnail, as: scene)
            #expect(camera.headReads == [NikonThumbnailOrientation.headLength])
        }

        /// The head of a real NIKON ZR NEF shot with the body held vertically (Orientation 8,
        /// little-endian IFD0 of 22 entries): header, IFD0 and its first values, cut before the
        /// XMP packet, with the date replaced. Its 160 x 120 IFD0 thumbnail, the picture `GetThumb`
        /// serves, is a bare JPEG (DQT, DHT, SOF0, SOS) with no EXIF and landscape pixels.
        private static let zrPortraitNEFHead = [UInt8](
            Data(
                base64Encoded:
                    "SUkqAAgAAAAWAP4ABAABAAAAAQAAAAMBAwABAAAABgAAAA8BAgASAAAAGAEAABABAgAJAAAALAEAABIBAwABAAAACAAAABoB"
                    + "BQABAAAAOAEAABsBBQABAAAAQAEAACgBAwABAAAAAgAAADEBAgANAAAASAEAADIBAgAUAAAAWAEAADsBAgAlAAAAbAEAAEoB"
                    + "BAAGAAAAlAEAAAECBAABAAAAlLQDAAICBAABAAAA+CUAABMCAwABAAAAAgAAABQCBQAGAAAArAEAALwCAQAAiAAA3AEAAJiC"
                    + "AgA3AAAA3IkAAGmHBAABAAAAKIoAACWIBAABAAAAgrQDAAOQAgAUAAAAFIoAABaSAQAEAAAAAQAAAAAAAAAAAE5JS09OIENP"
                    + "UlBPUkFUSU9OAAAATklLT04gWlIAAAAALAEAAAEAAAAsAQAAAQAAAFZlci4wMS4xMQAAAAAAAAAyMDI2OjAxOjAxIDAwOjAw"
                    + "OjAwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACM2gMABNsDAJDfAwAI4AMAyOADAIjhAwAAAAAA"
                    + "AQAAAP8AAAABAAAAAAAAAAEAAAD/AAAAAQAAAAAAAAABAAAA/wAAAAEAAAA=")!)

        @Test func aRealZRPortraitNEFsThumbnailShowsAsFramed() throws {
            let scene = Self.scene(8)
            let camera = CameraObject(
                original: Self.zrPortraitNEFHead,
                thumbnail: try Self.cameraThumbnail(scene, orientation: 8))

            let thumbnail = try #require(try Self.blockingThumbnail("_NZR2225.NEF", camera))

            try Self.expectUpright(thumbnail, as: scene)
        }

        @Test func aNikonStyleExifHeaderBeforeTheImageIsRead() throws {
            // Nikon writes APP1 first, big-endian, with Make and Model ahead of Orientation in IFD0.
            let scene = Self.scene(6)
            let tiff = NEFFixture.build(
                [
                    NEFFixture.Directory(entries: [
                        .init(tag: 0x010F, value: .long(0x200)),
                        .init(tag: 0x0110, value: .long(0x220)),
                        .init(tag: 0x0112, value: .short(6)),
                        .init(tag: 0x011A, value: .long(0x240)),
                        .init(tag: 0x8769, value: .long(0x260)),
                    ])
                ], littleEndian: false, size: 0x300)
            let pixels = try Self.jpeg(try Self.sensorImage(scene, orientation: 6))
            let segmentLength = 2 + 6 + tiff.count
            let still =
                [0xFF, 0xD8, 0xFF, 0xE1, UInt8(segmentLength >> 8), UInt8(segmentLength & 0xFF)]
                + Array("Exif\0\0".utf8) + tiff + [UInt8](pixels.dropFirst(2))
            let camera = CameraObject(
                original: still, thumbnail: try Self.cameraThumbnail(scene, orientation: 6))

            let thumbnail = try #require(
                try Self.blockingThumbnail("DSC_0001.JPG", camera))

            try Self.expectUpright(thumbnail, as: scene)
        }

        @Test func aThumbnailWithExifButNoOrientationShowsAsFramed() throws {
            let scene = Self.scene(8)
            let camera = CameraObject(
                original: try Self.stillJPEG(scene, orientation: 8),
                thumbnail: try Self.cameraThumbnail(scene, orientation: 8, keepingExif: true))

            let thumbnail = try #require(try Self.blockingThumbnail("_NZR2811.JPG", camera))

            try Self.expectUpright(thumbnail, as: scene)
        }

        @Test func aClipsThumbnailNeverReadsTheClip() throws {
            let scene = Self.scene(1)
            let camera = CameraObject(
                original: [UInt8](repeating: 0, count: 64),
                thumbnail: try Self.cameraThumbnail(scene, orientation: 6))

            let thumbnail = try Self.blockingThumbnail("_NZR0001.MOV", camera)

            #expect(thumbnail == camera.thumbnail)
            #expect(camera.headReads.isEmpty)
        }

        @Test func aThumbnailThatStatesItsOrientationIsKept() throws {
            let scene = Self.scene(8)
            let tagged = try Self.jpeg(
                try Self.sensorImage(scene, orientation: 8),
                properties: [kCGImagePropertyOrientation: 8])
            let camera = CameraObject(
                original: try Self.stillJPEG(scene, orientation: 8), thumbnail: tagged)

            let thumbnail = try #require(
                try Self.blockingThumbnail("_NZR2811.JPG", camera))

            try Self.expectUpright(thumbnail, as: scene)
            #expect(camera.headReads.isEmpty)
        }

        @Test func aFailedHeadReadStillShowsTheCamerasThumbnail() throws {
            let scene = Self.scene(6)
            let camera = CameraObject(
                original: try Self.stillJPEG(scene, orientation: 6),
                thumbnail: try Self.cameraThumbnail(scene, orientation: 6))
            camera.failsHeadRead = true

            let thumbnail = try Self.blockingThumbnail("_NZR2887.JPG", camera)

            #expect(thumbnail == camera.thumbnail)
        }

        /// A cancelled read is not an answer: the caller caches what it gets, and an untagged
        /// thumbnail cached here would stay sideways.
        @Test func aCancelledHeadReadIsNotReturnedAsTheThumbnail() async throws {
            let scene = Self.scene(6)
            let camera = CameraObject(
                original: try Self.stillJPEG(scene, orientation: 6),
                thumbnail: try Self.cameraThumbnail(scene, orientation: 6))

            await #expect(throws: CancellationError.self) {
                _ = try await NikonThumbnailOrientation.uprightThumbnail(
                    filename: "_NZR2887.JPG",
                    readThumbnail: { () async throws -> Data? in camera.readThumbnail() },
                    readHead: { _ async throws -> Data in throw CancellationError() })
            }
        }

        /// An APP1 segment too short to hold its own `Exif` identifier, followed by bytes that
        /// read `Exif\0\0`, in the still's head or in the camera's thumbnail.
        @Test func aTruncatedExifSegmentIsNotRead() throws {
            let scene = Self.scene(6)
            let truncated: [UInt8] =
                [0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x04] + Array("Exif\0\0".utf8)
                + [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08]
            let camera = CameraObject(
                original: truncated, thumbnail: try Self.cameraThumbnail(scene, orientation: 6))

            #expect(try Self.blockingThumbnail("_NZR2887.JPG", camera) == camera.thumbnail)

            let odd = CameraObject(
                original: try Self.stillJPEG(scene, orientation: 6), thumbnail: Data(truncated))
            // Its bytes still get the still's orientation; the short segment is not taken as one.
            #expect(try Self.blockingThumbnail("_NZR2887.JPG", odd) != nil)
        }
    }
#endif
