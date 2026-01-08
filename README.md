# 👗 Fashionista — AI Wardrobe Companion

Fashionista is a SwiftUI iOS app that digitizes your wardrobe using on-device AI.  
Scan clothing, organize items, and get outfit suggestions based on the occasion.

---

## ✨ Features

### 🔍 Smart Scanning
- CoreML clothing classification (T-shirts, jeans, dresses)
- Dominant color extraction using HSB analysis
- Text and logo recognition using Vision OCR

```swift
// CoreML classification (example)
let model = try ClothingClassifier(configuration: .init())
let prediction = try model.prediction(image: pixelBuffer)
📂 Digital Wardrobe
Local persistence using JSON + UserDefaults
Manual editing of category, name, and detected text
Grid-based wardrobe view
// Saving items locally
let data = try JSONEncoder().encode(items)
UserDefaults.standard.set(data, forKey: "wardrobe")
🤖 AI Stylist
Occasion-based outfit suggestions
Uses existing wardrobe data only
func suggestOutfit(for event: String) -> [ClothingItem] {
    wardrobe.filter { $0.matches(event) }
}
📸 App Showcase
🎥 Demo Video
Record a screen capture showing scanning, wardrobe grid, and outfit suggestions.
[![Fashionista Demo](assets/video-thumb.png)](assets/demo.mp4)
🖼️ Screenshots
Splash Screen    Wardrobe Grid    AI Stylist
🛠️ Technical Stack
Component    Technology
UI    SwiftUI
ML    CoreML
Vision    OCR + Image Analysis
Camera    AVFoundation
Gallery    PhotosUI
Storage    UserDefaults + JSON
🚀 Getting Started
Requirements
Xcode 15+
iOS 17.0+
Physical iPhone (camera required)
Installation
git clone https://github.com/yourusername/Fashionista.git
Open in Xcode
Add ClothingClassifier.mlmodel
Select a real device
Build and run (Cmd + R)
🛡️ Privacy
All image processing runs on-device
No cloud uploads
No tracking
Terms acceptance required before AI features
📁 Repository Structure
Fashionista/
├── assets/
│   ├── splash.png
│   ├── wardrobe.png
│   ├── stylist.png
│   └── demo.mp4
├── ClothingClassifier.mlmodel
├── Fashionista.xcodeproj
└── README.md
Copyright (c) 2026 Yousef Abdelsalam
