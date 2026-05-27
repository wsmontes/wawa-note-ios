import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers
import OSLog

struct ImportMetadata {
    let duration: TimeInterval
    let format: String
    let suggestedTitle: String
    let fileSize: Int64
    let creationDate: Date?
}

final class AudioImportService: @unchecked Sendable {

    // MARK: - Format support

    static let supportedUTTypes: [UTType] = [
        .mpeg4Audio, .mp3, .wav, .aiff
    ]

    func canRead(url: URL) -> Bool {
        if let _ = try? AVAudioPlayer(contentsOf: url) {
            return true
        }
        let asset = AVAsset(url: url)
        if asset.isReadable {
            return asset.tracks(withMediaType: .audio).first != nil
        }
        return false
    }

    func isNativeM4ACompatible(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard ext == "m4a" || ext == "aac" || ext == "mp4" else { return false }
        return (try? AVAudioPlayer(contentsOf: url)) != nil
    }

    // MARK: - Metadata extraction

    func extractMetadata(url: URL) async throws -> ImportMetadata {
        let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])

        let format = url.pathExtension.uppercased()
        let filename = url.deletingPathExtension().lastPathComponent
        let sanitized = filename
            .replacingOccurrences(of: "PTT-\\d{8}-", with: "", options: .regularExpression)
            .replacingOccurrences(of: "WA\\d+", with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_- "))
        let title = sanitized.isEmpty ? filename : sanitized

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.conversionFailed(NSError(domain: "import", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "File not found at path"]))
        }

        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            throw ImportError.conversionFailed(NSError(domain: "import", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot open audio: \(error.localizedDescription)"]))
        }

        let asset = AVAsset(url: url)
        let assetDuration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let effectiveDuration = max(player.duration, assetDuration)

        return ImportMetadata(
            duration: effectiveDuration,
            format: format.isEmpty ? "AUDIO" : format,
            suggestedTitle: title,
            fileSize: Int64(resourceValues?.fileSize ?? 0),
            creationDate: resourceValues?.creationDate ?? resourceValues?.contentModificationDate
        )
    }

    // MARK: - AAC conversion

    func convertToAAC(inputURL: URL, outputURL: URL) async throws {
        let outputDir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw ImportError.conversionFailed(NSError(domain: "import", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Source file not found"]))
        }

        var inputFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(inputURL as CFURL, &inputFile)
        guard status == noErr, let inputFile else {
            throw ImportError.conversionFailed(NSError(domain: "import", code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Cannot open file (OSStatus \(status))"]))
        }
        defer { ExtAudioFileDispose(inputFile) }

        var sourceFormat = AudioStreamBasicDescription()
        var propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(inputFile, kExtAudioFileProperty_FileDataFormat, &propSize, &sourceFormat)
        guard status == noErr else {
            throw ImportError.conversionFailed(NSError(domain: "import", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Cannot read source format"]))
        }

        let channels = sourceFormat.mChannelsPerFrame
        let sampleRate = sourceFormat.mSampleRate

        var clientFormat = AudioStreamBasicDescription()
        clientFormat.mFormatID = kAudioFormatLinearPCM
        clientFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian
        clientFormat.mSampleRate = sampleRate
        clientFormat.mChannelsPerFrame = channels
        clientFormat.mBitsPerChannel = 32
        clientFormat.mBytesPerFrame = 4 * channels
        clientFormat.mBytesPerPacket = 4 * channels
        clientFormat.mFramesPerPacket = 1

        propSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileSetProperty(inputFile, kExtAudioFileProperty_ClientDataFormat, propSize, &clientFormat)
        guard status == noErr else {
            throw ImportError.conversionFailed(NSError(domain: "import", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot set input client format (OSStatus \(status))"]))
        }

        var outputFormat = AudioStreamBasicDescription()
        outputFormat.mFormatID = kAudioFormatMPEG4AAC
        outputFormat.mSampleRate = sampleRate
        outputFormat.mChannelsPerFrame = channels
        outputFormat.mFramesPerPacket = 1024

        var outputFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(outputURL as CFURL, kAudioFileM4AType, &outputFormat, nil, AudioFileFlags.eraseFile.rawValue, &outputFile)
        guard status == noErr, let outputFile else {
            throw ImportError.conversionFailed(NSError(domain: "import", code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Cannot create output file (OSStatus \(status))"]))
        }
        defer { ExtAudioFileDispose(outputFile) }

        status = ExtAudioFileSetProperty(outputFile, kExtAudioFileProperty_ClientDataFormat, propSize, &clientFormat)
        guard status == noErr else {
            throw ImportError.conversionFailed(NSError(domain: "import", code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Cannot set output client format (OSStatus \(status))"]))
        }

        let framesPerRead: UInt32 = 4096
        let bytesPerFrame = clientFormat.mBytesPerFrame
        let bufferByteSize = framesPerRead * bytesPerFrame
        var buffer = [UInt8](repeating: 0, count: Int(bufferByteSize))

        while true {
            var readFrameCount: UInt32 = 0
            var writeErr: OSStatus = noErr

            buffer.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var fillBufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: channels,
                        mDataByteSize: bufferByteSize,
                        mData: baseAddress
                    )
                )
                var frameCount = framesPerRead
                let status = ExtAudioFileRead(inputFile, &frameCount, &fillBufferList)
                if status != noErr || frameCount == 0 { return }
                readFrameCount = frameCount
                writeErr = ExtAudioFileWrite(outputFile, frameCount, &fillBufferList)
            }

            if readFrameCount == 0 { break }
            if writeErr != noErr {
                throw ImportError.conversionFailed(NSError(domain: "import", code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "Write error (OSStatus \(writeErr))"]))
            }
        }

        AppLog.audio.info("Converted via ExtAudioFile: \(outputURL.path)")
    }

    // MARK: - Preview player

    func previewPlayer(for url: URL) -> AVAudioPlayer? {
        try? AVAudioPlayer(contentsOf: url)
    }
}

// MARK: - FormatImporter conformance

extension AudioImportService: FormatImporter {
    var formatIdentifier: String { "audio" }
    var displayName: String { "Audio File" }
    var supportedUTTypes: [UTType] { Self.supportedUTTypes }

    func importFromURL(_ url: URL) async throws -> ImportResult {
        let metadata = try await extractMetadata(url: url)

        let item = KnowledgeItem(
            type: .meeting,
            title: metadata.suggestedTitle,
            createdAt: metadata.creationDate ?? Date(),
            status: .recorded,
            durationSeconds: metadata.duration,
            languageCode: nil
        )
        item.isImported = true
        item.importSourceURL = url.absoluteString

        var warnings: [String] = []
        if metadata.duration <= 0 { warnings.append("Could not determine audio duration") }

        return ImportResult(knowledgeItem: item, artifacts: ["source": url], warnings: warnings)
    }

    // canRead(url:) already exists
    func canRead(data: Data) -> Bool { false }
}

// MARK: - Errors

enum ImportError: LocalizedError {
    case unreadableFormat
    case noAudioTrack
    case readerCreationFailed
    case writerCreationFailed
    case conversionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unreadableFormat:
            return "This audio format is not supported. Try converting to MP3 or M4A first."
        case .noAudioTrack:
            return "No audio track found in this file."
        case .readerCreationFailed, .writerCreationFailed:
            return "Could not process this file."
        case .conversionFailed(let error):
            return "Conversion failed: \(error.localizedDescription)"
        }
    }
}
