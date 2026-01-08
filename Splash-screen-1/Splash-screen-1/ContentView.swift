    import SwiftUI
    import CoreML
    import Vision
    import AVFoundation
    import UIKit
    import PhotosUI
    import UniformTypeIdentifiers
    import Combine // FIX: Ensure Combine is imported

    // MARK: - Color Extension for Codable Support
    extension Color {
        func toHex() -> String? {
            let uiColor = UIColor(self)
            guard let components = uiColor.cgColor.components, components.count >= 3 else { return nil }
            let r = Float(components[0])
            let g = Float(components[1])
            let b = Float(components[2])
            return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
        }
        init?(hex: String) {
            let r, g, b: CGFloat
            let start = hex.index(hex.startIndex, offsetBy: hex.hasPrefix("#") ? 1 : 0)
            let hexColor = String(hex[start...])
            guard hexColor.count == 6 else { return nil }
            let scanner = Scanner(string: hexColor)
            var hexNumber: UInt64 = 0
            guard scanner.scanHexInt64(&hexNumber) else { return nil }
            r = CGFloat((hexNumber & 0xff0000) >> 16) / 255
            g = CGFloat((hexNumber & 0x00ff00) >> 8) / 255
            b = CGFloat(hexNumber & 0x0000ff) / 255
            self.init(red: r, green: g, blue: b)
        }
    }

    // MARK: - 0. UIImage Color & Text Extension Utility (Color Logic Fixed)
    extension UUID: Codable {}

    extension UIImage {
        
        // 1. DOMINANT COLOR EXTRACTION (Unchanged)
        var dominantColor: Color? {
            guard let cgImage = self.cgImage else { return nil }
            
            let size = CGSize(width: 10, height: 10)
            let smallImage = UIGraphicsImageRenderer(size: size).image { context in
                self.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let smallCGImage = smallImage.cgImage else { return nil }

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
            
            var pixelData = [UInt8](repeating: 0, count: 4 * Int(size.width * size.height))
            
            guard let context = CGContext(data: &pixelData,
                                          width: Int(size.width),
                                          height: Int(size.height),
                                          bitsPerComponent: 8,
                                          bytesPerRow: 4 * Int(size.width),
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo.rawValue)
            else { return nil }
            
            context.draw(smallCGImage, in: CGRect(origin: .zero, size: size))

            var colorCounts: [String: Int] = [:]

            for i in 0..<(Int(size.width * size.height)) {
                let offset = i * 4
                let red = pixelData[offset]
                let green = pixelData[offset + 1]
                let blue = pixelData[offset + 2]
                
                let r = (red / 16) * 16
                let g = (green / 16) * 16
                let b = (blue / 16) * 16
                
                let key = "\(r)-\(g)-\(b)"
                colorCounts[key, default: 0] += 1
            }
            
            guard let dominantKey = colorCounts.max(by: { $0.value < $1.value })?.key else { return nil }
            
            let components = dominantKey.split(separator: "-").compactMap { UInt8($0) }
            guard components.count == 3 else { return nil }
            
            let red = Double(components[0]) / 255.0
            let green = Double(components[1]) / 255.0
            let blue = Double(components[2]) / 255.0
            
            return Color(red: red, green: green, blue: blue)
        }

        /// Converts the SwiftUI Color into a human-readable string using HSB analysis (Fixed).
        func toColorName(color: Color) -> String {
            let uiColor = UIColor(color)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0

            uiColor.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            
            let b = brightness // Brightness (Value)
            let s = saturation // Saturation (Chroma)
            let h = hue * 360 // Hue (Angle)

            // 1. Check for Black (Must be very dark AND desaturated)
            if b < 0.15 && s < 0.3 {
                return "Black"
            }
            
            // 2. Check for White (Very High Brightness and Low Saturation)
            if b > 0.85 && s < 0.2 {
                return "White"
            }
            
            // 3. Check for Gray (Low Saturation)
            if s < 0.15 {
                if b > 0.7 { return "Light Gray" }
                return "Gray"
            }

            // 4. Identify Chromatic Colors using Hue (H)
            
            // Red (0 to 15, and 345 to 360)
            if h < 15 || h >= 345 {
                return "Red"
            }
            // Orange/Brown (15 to 45)
            if h >= 15 && h < 45 {
                 // Darker saturated colors in this range are often seen as Brown
                if b < 0.6 && s > 0.5 {
                    return "Brown"
                }
                return "Orange"
            }
            // Yellow (45 to 75)
            if h >= 45 && h < 75 {
                return "Yellow"
            }
            // Green (75 to 165)
            if h >= 75 && h < 165 {
                return "Green"
            }
            // Cyan/Teal (165 to 195)
            if h >= 165 && h < 195 {
                return "Teal"
            }
            // Blue (195 to 255)
            if h >= 195 && h < 255 {
                return "Blue"
            }
            // Purple/Magenta (255 to 345)
            if h >= 255 && h < 345 {
                return "Purple"
            }
            
            return "Colored"
        }
        
        // 2. TEXT RECOGNITION FUNCTION (Unchanged)
        func recognizeText(completion: @escaping (String?) -> Void) {
            guard let cgImage = self.cgImage else {
                completion(nil)
                return
            }

            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    completion(nil)
                    return
                }
                
                let recognizedText = observations.compactMap { observation in
                    return observation.topCandidates(1).first?.string
                }.joined(separator: " ")
                
                completion(recognizedText.isEmpty ? nil : recognizedText)
            }
            
            request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    print("Text Recognition failed: \(error.localizedDescription)")
                    completion(nil)
                }
            }
        }
    }

    // MARK: - 1. Data Model (Unchanged)
    struct ClothingItem: Identifiable, Codable {
        let id: UUID
        let dateAdded: Date
        private let imageData: Data
        private let colorHex: String
        var category: String
        var text: String?
        let colorName: String
        let confidence: Int
        
        var image: UIImage {
            return UIImage(data: imageData) ?? UIImage(systemName: "questionmark.square.dashed")!
        }
        var colorValue: Color {
            return Color(hex: colorHex) ?? .gray
        }
        
        init(image: UIImage, category: String, colorName: String, colorValue: Color, text: String?, confidence: Int) {
            self.id = UUID()
            self.dateAdded = Date()
            self.imageData = image.jpegData(compressionQuality: 0.7) ?? Data()
            self.colorHex = colorValue.toHex() ?? "#808080"
            self.category = category
            self.text = text
            self.colorName = colorName
            self.confidence = confidence
        }
    }

    // MARK: - 2. Wardrobe Manager (Unchanged)
    class WardrobeManager: ObservableObject {
        @Published var items: [ClothingItem] = []
        private let storageKey = "WardrobeItems"
        
        init() {
            loadItems()
            if items.isEmpty {
                if let placeholderImage = UIImage(named: "placeholderShirt") {
                    let colorUtility = UIImage()
                    if let color = placeholderImage.dominantColor {
                        let colorName = colorUtility.toColorName(color: color)
                        self.items.append(ClothingItem(image: placeholderImage, category: "Sample Shirt", colorName: colorName, colorValue: color, text: "Fashionista Brand", confidence: 90))
                    }
                }
                saveItems()
            }
        }

        func saveItems() {
            do {
                let data = try JSONEncoder().encode(items)
                UserDefaults.standard.set(data, forKey: storageKey)
                print("💾 Wardrobe saved successfully. Data Size: \((data.count / 1024).formatted(.number)) KB")
            } catch {
                print("❌ Failed to encode wardrobe items: \(error.localizedDescription)")
            }
        }
        
        func loadItems() {
            if let data = UserDefaults.standard.data(forKey: storageKey) {
                do {
                    self.items = try JSONDecoder().decode([ClothingItem].self, from: data)
                    print("✅ Wardrobe loaded successfully (\(items.count) items).")
                } catch {
                    print("❌ Failed to decode wardrobe items: \(error.localizedDescription)")
                }
            }
        }

        func addItem(image: UIImage, category: String, colorName: String, colorValue: Color, text: String?, confidence: Int) {
            let newItem = ClothingItem(image: image, category: category, colorName: colorName, colorValue: colorValue, text: text, confidence: confidence)
            items.append(newItem)
            saveItems()
            print("✅ Added \(colorName) \(category) to wardrobe. Text: \(text ?? "None").")
        }
        
        func deleteItem(id: UUID) {
            items.removeAll { $0.id == id }
            saveItems()
            print("🗑️ Item with ID \(id) deleted from wardrobe.")
        }
        
        func updateDescription(id: UUID, newCategory: String, newText: String?) {
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].category = newCategory
                items[index].text = newText
                saveItems()
                print("✏️ Item \(id) updated. Category: \(newCategory), Text: \(newText ?? "None").")
            }
        }
    }

    // MARK: - 3. Camera Tab View
    struct ImagePicker: UIViewControllerRepresentable {
        @Binding var isPresented: Bool
        @Binding var selectedImage: UIImage?
        
        class Coordinator: NSObject, PHPickerViewControllerDelegate {
            var parent: ImagePicker
            init(_ parent: ImagePicker) { self.parent = parent }
            func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
                if let result = results.first {
                    result.itemProvider.loadObject(ofClass: UIImage.self) { (image, error) in
                        if let uiImage = image as? UIImage {
                            DispatchQueue.main.async { self.parent.selectedImage = uiImage }
                        } else if let error = error {
                            print("Error loading image from Photo Library: \(error.localizedDescription)")
                        }
                    }
                }
                parent.isPresented = false
            }
        }
        func makeCoordinator() -> Coordinator { Coordinator(self) }
        func makeUIViewController(context: Context) -> PHPickerViewController {
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 1
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = context.coordinator
            return picker
        }
        func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    }

    struct DocumentPicker: UIViewControllerRepresentable {
        @Binding var isPresented: Bool
        @Binding var selectedImage: UIImage?
        
        class Coordinator: NSObject, UIDocumentPickerDelegate {
            var parent: DocumentPicker
            init(_ parent: DocumentPicker) { self.parent = parent }
            
            func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
                if let url = urls.first {
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            let imageData = try Data(contentsOf: url)
                            if let uiImage = UIImage(data: imageData) {
                                DispatchQueue.main.async { self.parent.selectedImage = uiImage }
                            }
                        } catch {
                            print("Error loading image from file: \(error.localizedDescription)")
                        }
                    }
                }
                parent.isPresented = false
            }
            func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.isPresented = false }
        }
        func makeCoordinator() -> Coordinator { Coordinator(self) }
        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
            documentPicker.delegate = context.coordinator
            return documentPicker
        }
        func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    }

    struct ImageSourceMenu: View {
        @Environment(\.dismiss) var dismiss
        @Binding var showingPhotoPicker: Bool
        @Binding var showingDocumentPicker: Bool
        
        var body: some View {
            VStack(spacing: 15) {
                Text("Select Image Source").font(.headline).padding(.bottom, 10)
                
                Button { dismiss(); showingPhotoPicker = true } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle.angled").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.blue)
                
                Button { dismiss(); showingDocumentPicker = true } label: {
                    Label("Files App", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.indigo)
                
                Button("Cancel", role: .cancel) { dismiss() }.padding(.top, 10)
            }
            .padding(30).presentationDetents([.fraction(0.35)])
        }
    }

    struct CameraTabView: View {
        @EnvironmentObject var wardrobeManager: WardrobeManager
        
        @State private var showingLiveCamera = false
        @State private var showingSelectImageMenu = false
        @State private var showingPhotoPicker = false
        @State private var showingDocumentPicker = false
        
        @State private var selectedImage: UIImage? = nil
        @State private var classificationResult: String? = nil
        
        @State private var classifiedCategory: String? = nil
        @State private var classifiedConfidence: Int? = nil
        @State private var classifiedColorName: String? = nil
        @State private var classifiedColorValue: Color? = nil
        @State private var recognizedText: String? = nil

        var body: some View {
            VStack(spacing: 30) {
                Spacer().frame(height: 50)
                
                Text("Scan your clothes")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.horizontal)
                
                Spacer().frame(height: 30)
                
                if let displayImage = selectedImage {
                    VStack {
                        Image(uiImage: displayImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 200, height: 200)
                            .cornerRadius(15)
                            .shadow(radius: 5)
                            .padding(.vertical, 10)
                            
                        if let result = classificationResult {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("**Classification:** \(result)")
                                    .font(.headline)
                                    .foregroundColor(.purple)
                                
                                if let text = recognizedText, !text.isEmpty {
                                    Text("**Text/Logo:** \(text)")
                                        .font(.subheadline)
                                        .foregroundColor(.indigo)
                                }
                            }
                            .padding(.top, 5)
                        }
                        
                        HStack(spacing: 20) {
                            Button {
                                selectedImage = nil
                                classificationResult = nil
                                classifiedCategory = nil
                                classifiedConfidence = nil
                                classifiedColorName = nil
                                classifiedColorValue = nil
                                recognizedText = nil
                            } label: {
                                Label("Remove", systemImage: "xmark")
                            }
                            .buttonStyle(.borderedProminent).tint(.red)
                            
                            if let category = classifiedCategory,
                               let colorName = classifiedColorName,
                               let colorValue = classifiedColorValue {
                                Button {
                                    if let image = selectedImage, let confidence = classifiedConfidence {
                                        wardrobeManager.addItem(
                                            image: image,
                                            category: category,
                                            colorName: colorName,
                                            colorValue: colorValue,
                                            text: recognizedText,
                                            confidence: confidence
                                        )
                                        selectedImage = nil
                                        classificationResult = nil
                                        classifiedCategory = nil
                                        classifiedConfidence = nil
                                        classifiedColorName = nil
                                        classifiedColorValue = nil
                                        recognizedText = nil
                                    }
                                } label: {
                                    Label("Save", systemImage: "square.and.arrow.down.fill")
                                }
                                .buttonStyle(.borderedProminent).tint(.blue)
                            } else {
                                Button {
                                    classificationResult = "Processing..."
                                    classifyClothing(image: displayImage)
                                } label: {
                                    Label("Process", systemImage: "checkmark")
                                }
                                .buttonStyle(.borderedProminent).tint(.green)
                            }
                        }
                        .padding(.top, 10).padding(.bottom, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Color.white)
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                    )
                    .padding(.horizontal)
                    .transition(.opacity.combined(with: .scale))
                } else {
                    VStack(spacing: 20) {
                        Button("Allow camera") { /* Action to request camera permissions */ }
                        .font(.headline).padding(.vertical, 12).padding(.horizontal, 30)
                        .background(Capsule().stroke(Color.gray, lineWidth: 1)).foregroundColor(.black)

                        HStack() {
                            Button("Scan") { showingLiveCamera = true }.buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
                            Button("+"){ showingSelectImageMenu = true }.buttonStyle(.borderedProminent).controlSize(.large).tint(.blue)
                        }.padding(.horizontal)
                    }.transition(.opacity)
                }
                
                Spacer()
            }
            .sheet(isPresented: $showingLiveCamera) { LiveCameraScreen(selectedImage: $selectedImage) }
            .sheet(isPresented: $showingSelectImageMenu) {
                ImageSourceMenu(showingPhotoPicker: $showingPhotoPicker, showingDocumentPicker: $showingDocumentPicker)
            }
            .sheet(isPresented: $showingPhotoPicker) {
                 ImagePicker(isPresented: $showingPhotoPicker, selectedImage: $selectedImage)
            }
            .fullScreenCover(isPresented: $showingDocumentPicker) {
                 DocumentPicker(isPresented: $showingDocumentPicker, selectedImage: $selectedImage)
            }
            .onChange(of: selectedImage) { _ in
                classificationResult = nil
                classifiedCategory = nil
                classifiedConfidence = nil
                classifiedColorName = nil
                classifiedColorValue = nil
                recognizedText = nil
            }
            .animation(.default, value: selectedImage)
        }
        
        func classifyClothing(image: UIImage) {
            self.classificationResult = "Processing..."
            
            let colorUtility = UIImage()
            let extractedColorValue = image.dominantColor
            let extractedColorName = extractedColorValue.map { colorUtility.toColorName(color: $0) } ?? "Unknown Color"
            
            let dispatchGroup = DispatchGroup()
            var tempCategory: String? = nil
            var tempConfidence: Int? = nil
            var tempText: String? = nil
            
            // --- RESTORED COREML CLASSIFICATION LOGIC ---
            // NOTE: This requires the 'ClothesClassifier.mlmodel' file to be in your project.
            dispatchGroup.enter()
            guard let model = try? VNCoreMLModel(for: ClothingClassifier().model) else {
                // This error will happen if the model file is not in your project.
                DispatchQueue.main.async { self.classificationResult = "Error: Failed to load ML model (Is 'ClothesClassifier.mlmodel' in the project?)." }
                dispatchGroup.leave()
                return
            }

            let mlRequest = VNCoreMLRequest(model: model) { request, error in
                if let results = request.results as? [VNClassificationObservation], let topResult = results.first {
                    tempCategory = topResult.identifier
                    tempConfidence = Int(topResult.confidence * 100)
                }
                dispatchGroup.leave()
            }
            
            guard let ciImage = CIImage(image: image) else {
                dispatchGroup.leave() // Ensure we leave the group even on CIImage fail
                return
            }
            let handler = VNImageRequestHandler(ciImage: ciImage)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([mlRequest])
                } catch {
                    print("CoreML request failed: \(error.localizedDescription)")
                }
            }
            // ------------------------------------------
            
            dispatchGroup.enter()
            image.recognizeText { recognized in
                tempText = recognized
                dispatchGroup.leave()
            }
            
            dispatchGroup.notify(queue: .main) {
                self.classifiedCategory = tempCategory
                self.classifiedConfidence = tempConfidence
                self.classifiedColorName = extractedColorName
                self.classifiedColorValue = extractedColorValue
                self.recognizedText = tempText
                
                if let category = tempCategory, let confidence = tempConfidence {
                    self.classificationResult = "\(category) (\(confidence)%) - \(extractedColorName)"
                } else {
                    self.classificationResult = "Classification Failed."
                }
                
                if self.selectedImage == nil {
                    self.classificationResult = nil
                }
            }
        }
    }

    // MARK: - 4. Wardrobe Tab View (Unchanged)
    struct WardrobeTabView: View {
        @EnvironmentObject var wardrobeManager: WardrobeManager
        let columns = [ GridItem(.flexible()), GridItem(.flexible()) ]

        @State private var showingEditSheet = false
        @State private var itemToEdit: ClothingItem?
        
        var body: some View {
            VStack(spacing: 0) {
                
                HStack {
                    HStack(spacing: 1) {
                        Button(action: { /* Minus action */ }) { Image(systemName: "minus").frame(width: 30, height: 30).background(Color.gray.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
                        Text("\(wardrobeManager.items.count) Items").padding(.horizontal, 10).font(.callout)
                        Button(action: { /* Plus action */ }) { Image(systemName: "plus").frame(width: 30, height: 30).background(Color.gray.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
                    }
                    .padding(4).background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.gray.opacity(0.5), lineWidth: 1))
                    Spacer()
                    Image(systemName: "sparkles.square.filled.on.square").foregroundColor(.purple)
                }
                .padding([.horizontal, .top]).padding(.bottom, 20)
                
                ScrollView {
                    if wardrobeManager.items.isEmpty {
                        Text("Your wardrobe is empty! Scan an item in the Camera tab to get started.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 50)
                    } else {
                        LazyVGrid(columns: columns, spacing: 15) {
                            ForEach(wardrobeManager.items) { item in
                                VStack(alignment: .leading) {
                                    Image(uiImage: item.image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(minWidth: 0, maxWidth: .infinity)
                                        .frame(height: 150)
                                        .clipped()
                                        .cornerRadius(10)
                                        .shadow(radius: 3)

                                    HStack {
                                        Circle()
                                            .fill(item.colorValue)
                                            .frame(width: 15, height: 15)
                                            .overlay(Circle().stroke(Color.gray, lineWidth: 0.5))
                                        
                                        Text("\(item.colorName) \(item.category)")
                                            .font(.headline)
                                            .lineLimit(1)
                                    }
                                    .padding(.top, 2)
                                    
                                    if let text = item.text, !text.isEmpty {
                                        Text("(\(text))")
                                            .font(.caption)
                                            .foregroundColor(.indigo)
                                            .lineLimit(1)
                                    }

                                    Text("Added: \(item.dateAdded.formatted(date: .numeric, time: .omitted))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(8)
                                .background(Color(.systemBackground))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                                )
                                .contextMenu {
                                    Button(role: .destructive) {
                                        wardrobeManager.deleteItem(id: item.id)
                                    } label: {
                                        Label("Delete Item", systemImage: "trash")
                                    }
                                    
                                    Button {
                                        itemToEdit = item
                                        showingEditSheet = true
                                    } label: {
                                        Label("Change Description", systemImage: "pencil.circle")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 10)
                    }
                }
                Spacer()
            }
            .sheet(item: $itemToEdit) { item in
                EditClothingDescriptionView(item: item)
                    .environmentObject(wardrobeManager)
            }
        }
    }

    // Edit View (Unchanged)
    struct EditClothingDescriptionView: View {
        @EnvironmentObject var wardrobeManager: WardrobeManager
        @Environment(\.dismiss) var dismiss
        
        let itemID: UUID
        @State private var newCategory: String
        @State private var newText: String
        
        init(item: ClothingItem) {
            self.itemID = item.id
            _newCategory = State(initialValue: item.category)
            _newText = State(initialValue: item.text ?? "")
        }

        var body: some View {
            NavigationView {
                VStack(alignment: .leading, spacing: 20) {
                    if let item = wardrobeManager.items.first(where: { $0.id == itemID }) {
                        Image(uiImage: item.image)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                            .cornerRadius(10)
                    }
                    
                    Text("Category / Item Type").font(.headline)
                    TextField("e.g., T-shirt, Jeans, Dress", text: $newCategory)
                        .textFieldStyle(.roundedBorder)
                    
                    Text("Text / Logo").font(.headline)
                    TextField("e.g., Nike, Supreme, Band Name", text: $newText)
                        .textFieldStyle(.roundedBorder)

                    Spacer()
                }
                .padding()
                .navigationTitle("Edit Item")
                .navigationBarItems(
                    leading: Button("Cancel") { dismiss() },
                    trailing: Button("Save") {
                        wardrobeManager.updateDescription(
                            id: itemID,
                            newCategory: newCategory,
                            newText: newText.isEmpty ? nil : newText
                        )
                        dismiss()
                    }
                    .disabled(newCategory.isEmpty)
                )
            }
        }
    }

    // MARK: - 5. Other Views and App Structure (Unchanged)

    struct AITabView: View {
        @State private var occasion: String = ""
        var body: some View {
            VStack(alignment: .leading, spacing: 30) {
                Spacer().frame(height: 50)
                Text("Let AI choose an outfit from your wardrobe").font(.largeTitle).fontWeight(.bold).padding(.horizontal)
                VStack(alignment: .leading) {
                    Text("What is the occasion?").font(.headline)
                    TextField("Type here", text: $occasion).textFieldStyle(.plain).padding(.vertical, 8)
                        .overlay(VStack{ Spacer(); Rectangle().frame(height: 1).foregroundColor(.gray) })
                }
                .padding(.horizontal)
                Spacer()
                Button(action: { print("Submitted occasion: \(occasion)") }) {
                    HStack {
                        Text("Submit").font(.title3).fontWeight(.semibold)
                        Image(systemName: "checkmark")
                    }
                    .foregroundColor(.white).padding(.vertical, 12).padding(.horizontal, 60).background(Capsule().fill(Color.blue))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }

    struct LiveCameraScreen: View {
        @Environment(\.dismiss) var dismiss
        @Binding var selectedImage: UIImage?

        var body: some View {
            ZStack {
                LiveCameraFeed()
                
                VStack {
                    HStack {
                        Spacer()
                        Button("Cancel") { dismiss() }.foregroundColor(.white).padding()
                    }
                    Spacer()
                    
                    Button(action: {
                        if let placeholder = UIImage(named: "placeholderShirt") {
                            self.selectedImage = placeholder
                        } else {
                            self.selectedImage = UIImage(systemName: "photo")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                        }
                        dismiss()
                    }) {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 80)).foregroundColor(.white).overlay(
                                Image(systemName: "circle").font(.system(size: 90)).foregroundColor(.white.opacity(0.8))
                            )
                    }
                    .padding(.bottom, 50)
                }
            }
        }
    }
    struct CameraViewRepresentable: UIViewRepresentable {
        func makeUIView(context: Context) -> UIView {
            let view = UIView(frame: UIScreen.main.bounds); view.backgroundColor = .black; setupCamera(for: view); return view
        }
        func updateUIView(_ uiView: UIView, context: Context) {}
        private func setupCamera(for view: UIView) {
            let session = AVCaptureSession()
            guard let camera = AVCaptureDevice.default(for: .video) else { return }
            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if session.canAddInput(input) { session.addInput(input) }
                let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                previewLayer.frame = view.bounds; previewLayer.videoGravity = .resizeAspectFill
                view.layer.addSublayer(previewLayer)
                DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
            } catch { print("Error setting up camera: \(error.localizedDescription)") }
        }
    }
    struct LiveCameraFeed: View {
        var body: some View { CameraViewRepresentable().edgesIgnoringSafeArea(.all) }
    }

    struct AppTabView: View {
        @StateObject var wardrobeManager = WardrobeManager()

        var body: some View {
            TabView {
                AITabView()
                    .tabItem { Label("AI", systemImage: "sparkles.square.filled.on.square") }
                
                WardrobeTabView()
                    .tabItem { Label("Wardrobe", systemImage: "tshirt.fill") }
                    .environmentObject(wardrobeManager)
                
                CameraTabView()
                    .tabItem { Label("Camera", systemImage: "camera.fill") }
                    .environmentObject(wardrobeManager)
            }
            .tint(.pink)
        }
    }

    struct SplashScreenView: View {
        @State private var showLogoOnly = true
        @State private var animateLogo = false
        @State private var showFullSplashScreenContent = false
        @State private var showMainView = false
        @State private var showTermsSheet = false
        @Namespace var splashNamespace
        var body: some View {
            ZStack {
                if showMainView {
                    AppTabView().transition(.opacity)
                } else {
                    ZStack {
                        LinearGradient(colors: [Color("BackgroundTop"), Color("BackgroundBottom")], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                        if showLogoOnly {
                            Image("Logo").resizable().scaledToFit().frame(width: 160, height: 160).cornerRadius(32).matchedGeometryEffect(id: "splashLogo", in: splashNamespace).shadow(radius: 10).opacity(animateLogo ? 1 : 0).scaleEffect(animateLogo ? 1 : 1.5).onAppear {
                                withAnimation(.easeOut(duration: 1)) { animateLogo = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) { showLogoOnly = false; showFullSplashScreenContent = true }
                                }
                            }
                        } else {
                            VStack(spacing: 25) {
                                Image("Logo").resizable().scaledToFit().frame(width: 120, height: 120).cornerRadius(28).matchedGeometryEffect(id: "splashLogo", in: splashNamespace).shadow(radius: 10).opacity(showFullSplashScreenContent ? 1 : 0)
                                Text("Fashionista").font(.system(size: 38, weight: .bold)).opacity(showFullSplashScreenContent ? 1 : 0).animation(.easeIn(duration: 1).delay(0.1), value: showFullSplashScreenContent)
                                Text("Your fashion companion.").font(.system(size: 18, weight: .medium)).foregroundColor(.gray).opacity(showFullSplashScreenContent ? 1 : 0).animation(.easeIn(duration: 1).delay(0.2), value: showFullSplashScreenContent)
                                Spacer().frame(height: 40)
                                Button(action: { withAnimation(.easeInOut(duration: 0.3)) { showTermsSheet = true } }) {
                                    Text("Get Started").font(.system(size: 18, weight: .semibold)).foregroundColor(.primary).padding(.horizontal, 50).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial).shadow(color: .black.opacity(0.15), radius: 8, y: 4))
                                }
                                .opacity(showFullSplashScreenContent ? 1 : 0).animation(.easeIn(duration: 1).delay(0.3), value: showFullSplashScreenContent)
                            }
                            .padding().opacity(showFullSplashScreenContent ? 1 : 0)
                        }
                    }
                    .transition(.opacity).id("SplashScreen")
                }
            }
            .animation(.default, value: showMainView)
            .sheet(isPresented: $showTermsSheet) {
                TermsAndConditionsView(
                    onAgree: { withAnimation(.easeInOut(duration: 0.6)) { showTermsSheet = false; showMainView = true } },
                    onDisagree: { withAnimation(.easeInOut(duration: 0.3)) { showTermsSheet = false } }
                )
                .presentationDetents([.large]).ignoresSafeArea(edges: .bottom)
            }
        }
    }

    struct TermsAndConditionsView: View {
        var onAgree: () -> Void
        var onDisagree: () -> Void
        @Environment(\.colorScheme) var colorScheme
        private var abstractBackground: some View { LinearGradient(colors: [Color.purple.opacity(0.5), Color.blue.opacity(0.4), Color.pink.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea() }
        var body: some View {
            ZStack {
                abstractBackground
                Rectangle().fill(.regularMaterial).ignoresSafeArea()
                VStack(spacing: 0) {
                    Spacer(minLength: 20)
                    HStack { Text("Terms and Conditions").font(.largeTitle).fontWeight(.heavy).foregroundColor(.primary); Spacer() }.padding(.horizontal, 25).padding(.top, 10).padding(.bottom, 20)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 25) {
                            Group {
                                VStack(alignment: .leading, spacing: 5) { Text("1. Acceptance of Terms").font(.title2).fontWeight(.bold).foregroundColor(.primary); Text("By clicking 'Agree', you acknowledge and accept all terms and conditions of service. This agreement is legally binding. (Placeholder text only.)").foregroundColor(.secondary) }
                                VStack(alignment: .leading, spacing: 5) { Text("2. User Obligations").font(.title2).fontWeight(.bold).foregroundColor(.primary); Text("Users must maintain the confidentiality of their accounts and are responsible for all activities that occur under their account. (Placeholder text only.)").foregroundColor(.secondary) }
                                VStack(alignment: .leading, spacing: 5) { Text("3. Privacy Policy").font(.title2).fontWeight(.bold).foregroundColor(.primary); Text("Your privacy is important to us. Data collected will be used only to improve your experience. See our full policy for details. (Placeholder text only.)").foregroundColor(.secondary) }
                                VStack(alignment: .leading, spacing: 5) { Text("4. Termination").font(.title2).fontWeight(.bold).foregroundColor(.primary); Text("We reserve the right to terminate access to the service at our sole discretion. (Placeholder text only.)").foregroundColor(.secondary) }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 25).padding(.bottom, 20)
                    }.scrollIndicators(.hidden)
                    HStack(spacing: 20) {
                        Button(action: onDisagree) { Text("Disagree").font(.headline).foregroundColor(.red).frame(maxWidth: .infinity).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 30).fill(.thinMaterial).shadow(color: .black.opacity(0.1), radius: 5, y: 2)) }
                        Button(action: onAgree) { Text("Agree").font(.headline).foregroundColor(.green).frame(maxWidth: .infinity).padding(.vertical, 16).background(RoundedRectangle(cornerRadius: 30).fill(.thinMaterial).shadow(color: .black.opacity(0.1), radius: 5, y: 2)) }
                    }
                    .padding(.horizontal, 25).padding(.bottom, 32).shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.15), radius: 12, y: 6)
                }
            }.ignoresSafeArea(edges: .bottom).cornerRadius(20)
        }
    }

    // MARK: - Preview
    #Preview {
        SplashScreenView()
    }
