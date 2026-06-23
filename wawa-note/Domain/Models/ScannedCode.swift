import Foundation
import SwiftData
// Related JIRA: KAN-135


// MARK: - Scanned Code Model

/// Represents a single barcode/QR code scan with full metadata.
struct ScannedCode: Identifiable, Codable, Sendable {
    let id: UUID
    let value: String           // The decoded string value
    let type: CodeType           // QR, barcode, etc.
    let symbology: String        // Raw AVFoundation symbology string (e.g. "org.iso.QRCode")
    let scannedAt: Date          // Timestamp of scan
    let index: Int               // Ordinal position in the session

    init(value: String, type: CodeType, symbology: String, index: Int) {
        self.id = UUID()
        self.value = value
        self.type = type
        self.symbology = symbology
        self.scannedAt = Date()
        self.index = index
    }

    // MARK: - Human-readable symbology

    /// Parses the raw AVFoundation symbology into a user-friendly name.
    var symbologyName: String {
        let raw = symbology
        if raw == "org.iso.QRCode"           { return "QR Code" }
        if raw == "org.iso.Aztec"            { return "Aztec" }
        if raw == "org.iso.PDF417"           { return "PDF417" }
        if raw == "org.iso.DataMatrix"       { return "Data Matrix" }
        if raw == "org.gs1.EAN-13"           { return "EAN-13" }
        if raw == "org.gs1.EAN-8"            { return "EAN-8" }
        if raw == "org.iso.Code128"          { return "Code 128" }
        if raw == "org.iso.Code39"           { return "Code 39" }
        if raw == "org.iso.Code39Mod43"      { return "Code 39 mod 43" }
        if raw == "org.iso.Code93"           { return "Code 93" }
        if raw == "org.gs1.ITF14"            { return "ITF-14" }
        if raw == "org.iso.UPC-E"            { return "UPC-E" }
        if raw.hasPrefix("org.iso") {
            return raw.replacingOccurrences(of: "org.iso.", with: "").replacingOccurrences(of: "org.gs1.", with: "")
        }
        return raw
    }

    // MARK: - Code Type Classification

    enum CodeType: String, Codable, Sendable {
        case qr
        case barcode
        case other

        var displayName: String {
            switch self {
            case .qr: "QR Code"
            case .barcode: "Barcode"
            case .other: "Code"
            }
        }

        var icon: String {
            switch self {
            case .qr: "qrcode"
            case .barcode: "barcode"
            case .other: "barcode.viewfinder"
            }
        }
    }

    /// Detect URL, email, phone, etc. from the decoded value.
    var detectedDataType: DetectedDataType {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: v), url.scheme != nil {
            if url.scheme == "http" || url.scheme == "https" { return .url }
            if url.scheme == "mailto" { return .email }
            if url.scheme == "tel" { return .phone }
            if url.scheme == "sms" { return .sms }
            return .uri
        }
        if v.contains("@") && v.contains(".") && !v.contains(" ") { return .email }
        if v.range(of: #"^\+?[\d\s\-\(\)]{7,}$"#, options: .regularExpression) != nil { return .phone }
        if v.range(of: #"^[A-Z0-9]+$"#, options: .regularExpression) != nil && v.count > 4 { return .code }
        return .text
    }

    enum DetectedDataType: String, Codable {
        case url, uri, email, phone, sms, code, text

        var label: String {
            switch self {
            case .url: "URL"
            case .uri: "URI"
            case .email: "Email"
            case .phone: "Phone"
            case .sms: "SMS"
            case .code: "Code"
            case .text: "Text"
            }
        }
    }
}

// MARK: - Scan Session

/// Holds all codes scanned in a single session. Serializable for storage.
struct ScanSession: Codable, Sendable {
    let sessionID: UUID
    let startedAt: Date
    var endedAt: Date?
    var codes: [ScannedCode] = []

    init() {
        self.sessionID = UUID()
        self.startedAt = Date()
    }

    mutating func add(_ code: ScannedCode) {
        var c = code
        // Re-index
        var updated = ScannedCode(
            value: c.value,
            type: c.type,
            symbology: c.symbology,
            index: codes.count + 1
        )
        codes.append(updated)
    }

    mutating func finish() {
        endedAt = Date()
    }

    // MARK: - Output Formats

    /// Plain text document: one line per code with type prefix.
    func toTextDocument() -> String {
        var lines: [String] = []
        lines.append("# Scan Session — \(startedAt.formatted(date: .complete, time: .standard))")
        lines.append("")
        for code in codes {
            let typeLabel = code.type.displayName
            let dataLabel = code.detectedDataType.label
            lines.append("### [\(code.index)] \(typeLabel) — \(dataLabel)")
            lines.append(code.value)
            lines.append("")
        }
        if let ended = endedAt {
            lines.append("---")
            lines.append("Scanned \(codes.count) code(s) in \(formatDuration(ended.timeIntervalSince(startedAt)))")
        }
        return lines.joined(separator: "\n")
    }

    /// JSON metadata for all scanned codes.
    func toJSON() -> String {
        var dict: [String: Any] = [
            "sessionID": sessionID.uuidString,
            "startedAt": startedAt.ISO8601Format(),
            "codeCount": codes.count
        ]
        if let endedAt = endedAt {
            dict["endedAt"] = endedAt.ISO8601Format()
            dict["durationSeconds"] = Int(endedAt.timeIntervalSince(startedAt))
        }
        dict["codes"] = codes.map { code -> [String: Any] in
            [
                "index": code.index,
                "value": code.value,
                "type": code.type.rawValue,
                "symbology": code.symbology,
                "detectedDataType": code.detectedDataType.rawValue,
                "scannedAt": code.scannedAt.ISO8601Format()
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let min = Int(interval) / 60
        let sec = Int(interval) % 60
        if min > 0 { return "\(min)m \(sec)s" }
        return "\(sec)s"
    }
}
