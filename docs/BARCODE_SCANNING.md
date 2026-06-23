# Barcode & QR Scanning — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-195
**Source modules:** `UI/Home/BarcodeScannerView.swift`, `BarcodeScannerViewModel.swift`, `Domain/Models/ScannedCode.swift`

---

## Overview

Wawa Note includes an on-device barcode and QR code scanner using AVFoundation. It supports 13 symbology types and stores scan results as `KnowledgeItem` records with type `.scanEvent`.

---

## Supported Symbologies

| Symbology | Type | Example Use |
|---|---|---|
| QR | 2D matrix | URLs, contact cards, WiFi configs |
| EAN-8 | 1D linear | Small retail products |
| EAN-13 | 1D linear | Standard retail products |
| UPC-A | 1D linear | North American retail |
| UPC-E | 1D linear | Compact retail |
| Code 39 | 1D linear | Logistics, inventory |
| Code 93 | 1D linear | High-density Code 39 alternative |
| Code 128 | 1D linear | Shipping, supply chain |
| PDF417 | 2D stacked | Driver's licenses, boarding passes |
| Data Matrix | 2D matrix | Small electronics, medical devices |
| ITF14 | 1D linear | Carton/box labeling |
| Aztec | 2D matrix | Travel tickets, government docs |
| Interleaved 2 of 5 | 1D linear | Warehousing |

---

## Architecture

```
BarcodeScannerView (SwiftUI)
    │
    ▼
BarcodeScannerViewModel
    │  AVCaptureSession
    │  AVCaptureDeviceInput (video)
    │  AVCaptureMetadataOutput (barcode detection)
    │
    ▼
ScannedCode (model)
    │  payload: String (decoded content)
    │  symbologyRaw: String
    │  scannedAt: Date
    │
    ▼
KnowledgeItemService.createItem()
    │  type: .scanEvent
    │  bodyText: payload
    │  metadata: symbology, timestamp
```

---

## User Journey

1. Open app → Capture tab
2. Tap scan/barcode button
3. Camera viewfinder opens with barcode detection region
4. Point camera at barcode → automatic detection
5. On detection: haptic feedback + result popup
6. Result saved as `KnowledgeItem(type: .scanEvent)`
7. Item appears in Inbox → can be assigned to project

---

## Implementation Notes

- Uses `AVCaptureMetadataOutput` for on-device detection (no AI/cloud required)
- Detection region highlighted in viewfinder overlay
- Multiple symbologies detected simultaneously
- Results deduplicated by payload content within session
- Scanned payloads validated: URLs opened, text saved as note body
