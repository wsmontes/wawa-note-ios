# Live OCR — Wawa Note

**Last updated:** 2026-06-22
**Related JIRA:** KAN-196
**Source modules:** `UI/Home/LiveOCRView.swift`, `LiveOCRViewModel.swift`

---

## Overview

Live OCR provides real-time, on-device text recognition using Apple's Vision framework. The camera feed is continuously analyzed for text, and recognized text is displayed as an overlay. Core Motion integration ensures stable capture by detecting when the device is held steady.

---

## Architecture

```
LiveOCRView (SwiftUI)
    │  Camera preview layer
    │  Text overlay (bounding boxes)
    │
    ▼
LiveOCRViewModel
    │  AVCaptureSession (video)
    │  VNRecognizeTextRequest (Vision)
    │  CMMotionManager (Core Motion)
    │
    ▼
Recognized text → user taps "Capture"
    │
    ▼
KnowledgeItemService.createItem()
    │  type: .note (with image attachment)
    │  bodyText: recognized text
    │  imageFileRelativePath: snapshot
```

---

## Core Motion Stability

Core Motion accelerometer detects when the device is held steady:
- Accelerometer variance < threshold for 0.5s → "steady" state
- Text recognition only triggered in "steady" state (saves battery)
- Stability indicator shown in UI (green dot = steady)

---

## User Journey

1. Capture tab → tap "Live OCR"
2. Camera opens with real-time text overlay
3. Point at document/text → recognized text appears as bounding boxes
4. Hold steady → text locks (green indicator)
5. Tap capture → snapshot saved + text extracted
6. Item created as `KnowledgeItem` with text and image

---

## Implementation Notes

- `VNRecognizeTextRequest` with `.accurate` recognition level
- Recognition region: center 60% of frame (reduces edge noise)
- Core Motion sampling at 60Hz, stability threshold: variance < 0.001
- Text deduplication across frames using string similarity
- Battery optimization: reduces recognition frequency when device is moving
