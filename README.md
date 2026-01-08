# 👗 Fashionista — AI Wardrobe Companion

Fashionista is a SwiftUI iOS app that digitizes your wardrobe using on-device AI.
Scan clothing, organize items, and get outfit suggestions based on the occasion.

---

## ✨ Features

### 🔍 Smart Scanning

* CoreML clothing classification (T-shirts, jeans, dresses)
* Dominant color extraction using HSB analysis
* Text and logo recognition using Vision OCR

```swift
// CoreML classification (example)
let model = try ClothingClassifier(configuration: .init())
let prediction = try model.prediction(image: pixelBuffer)
```

---

### 📂 Digital Wardrobe

* Local persistence using JSON + UserDefaults
* Manual editing of category, name, and detected text
* Grid-based wardrobe view

```swift
// Saving items locally
let data = try JSONEncoder().encode(items)
UserDefaults.standard.set(data, forKey: "wardrobe")
```

---

### 🤖 AI Stylist

* Occasion-based outfit suggestions
* Uses existing wardrobe data only

```swift
func suggestOutfit(for event: String) -> [ClothingItem] {
    wardrobe.filter { $0.matches(event) }
}
```

---

## 📸 App Showcase

<p align="center">
  <img src="assets/Fashionista.png" width="180">
</p>

### 🎥 Demo Video

*Record a screen capture showing scanning, wardrobe grid, and outfit suggestions.*
[![Fashionista Demo](assets/video-thumb.png)](assets/demo.mp4)

---

## 🛠️ Technical Stack

| Component | Technology           |
| --------- | -------------------- |
| UI        | SwiftUI              |
| ML        | CoreML               |
| Vision    | OCR + Image Analysis |
| Camera    | AVFoundation         |
| Gallery   | PhotosUI             |
| Storage   | UserDefaults + JSON  |

---

## 🚀 Getting Started

### Requirements

| Requirement | Minimum                           |
| ----------- | --------------------------------- |
| Xcode       | 15+                               |
| iOS         | 17.0+                             |
| Device      | Physical iPhone (camera required) |

### Installation

```bash
git clone https://github.com/yourusername/Fashionista.git
```

1. Open the project in Xcode
2. Add `ClothingClassifier.mlmodel` to the project
3. Select a real iPhone as the target
4. Build and run (`Cmd + R`)

---

## 🛡️ Privacy

| Policy               | Status |
| -------------------- | ------ |
| On-device processing | Yes    |
| Cloud uploads        | No     |
| Tracking             | No     |
| Terms required       | Yes    |

---

## 📁 Repository Structure

```text
Fashionista/
├── assets/
│   ├── splash.png
│   ├── wardrobe.png
│   ├── stylist.png
│   └── demo.mp4
├── ClothingClassifier.mlmodel
├── Fashionista.xcodeproj
└── README.md
```

---

## © License

Copyright (c) 2026 Yousef Abdelsalam
MIT License
