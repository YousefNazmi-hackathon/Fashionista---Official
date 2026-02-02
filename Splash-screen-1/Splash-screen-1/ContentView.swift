import SwiftUI
import CoreML
import Vision
import AVFoundation
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import Combine
import Foundation

// Small helper to detect SwiftUI Previews environment
private let isRunningInPreviews: Bool = {
    ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}()

// MARK: - Color Extension for Codable Support
extension Color {
    func toHex() -> String? {
        let uiColor = UIColor(self)
        guard let components = uiColor.cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil)?.components,
              components.count >= 3 else { return nil }
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

// MARK: - 0. UIImage Color & Text Extension Utility (Improved)
extension UIImage {
    var dominantColor: Color? {
        guard let cgImage = self.cgImage else { return nil }
        let targetSize = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let small = renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let smallCG = small.cgImage else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let width = smallCG.width
        let height = smallCG.height
        var pixels = [UInt8](repeating: 0, count: 4 * width * height)
        guard let ctx = CGContext(data: &pixels,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 4 * width,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo.rawValue) else { return nil }
        ctx.draw(smallCG, in: CGRect(x: 0, y: 0, width: width, height: height))
        var buckets: [String: Double] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = pixels[i], g = pixels[i+1], b = pixels[i+2], a = pixels[i+3]
            if a < 16 { continue }
            let luminance = 0.299 * Double(r) + 0.587 * Double(g) + 0.114 * Double(b)
            if luminance < 8 { continue }
            let rq = Int(r) / 42
            let gq = Int(g) / 64
            let bq = Int(b) / 85
            let key = "\(rq)-\(gq)-\(bq)"
            let rf = Double(r)/255.0, gf = Double(g)/255.0, bf = Double(b)/255.0
            let maxc = max(rf, max(gf, bf)), minc = min(rf, min(gf, bf))
            let sat = max(0.001, maxc == 0 ? 0 : (maxc - minc)/maxc)
            let weight = pow(luminance/255.0, 1.0) * pow(sat, 0.7)
            buckets[key, default: 0] += weight
        }
        guard let best = buckets.max(by: { $0.value < $1.value })?.key else { return nil }
        let comps = best.split(separator: "-").compactMap { Int($0) }
        guard comps.count == 3 else { return nil }
        let r = min(255, comps[0] * 42 + 21)
        let g = min(255, comps[1] * 64 + 32)
        let b = min(255, comps[2] * 85 + 42)
        return Color(red: Double(r)/255.0, green: Double(g)/255.0, blue: Double(b)/255.0)
    }

    func toColorName(color: Color) -> String {
        let uiColor = UIColor(color)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        uiColor.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        let hue = h * 360, sat = s, bri = v
        if sat < 0.10 {
            if bri < 0.15 { return "Black" }
            if bri > 0.90 { return "White" }
            if bri > 0.70 { return "Light Gray" }
            if bri < 0.30 { return "Dark Gray" }
            return "Gray"
        }
        if bri < 0.45 && sat > 0.35 && hue >= 15 && hue < 50 { return "Brown" }
        if hue >= 50 && hue < 95 && sat < 0.5 && bri < 0.7 { return "Olive" }
        if hue >= 165 && hue < 195 && sat >= 0.25 { return "Teal" }
        switch hue {
        case 0..<15, 345...360: return "Red"
        case 15..<45: return bri < 0.6 ? "Brown" : "Orange"
        case 45..<75: return "Yellow"
        case 75..<165: return "Green"
        case 165..<195: return "Teal"
        case 195..<255: return "Blue"
        case 255..<300: return "Purple"
        case 300..<345: return "Magenta"
        default: return "Colored"
        }
    }
    
    func recognizeText(completion: @escaping (String?) -> Void) {
        guard let cgImage = self.cgImage else {
            completion(nil)
            return
        }
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                completion(nil); return
            }
            let recognizedText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            completion(recognizedText.isEmpty ? nil : recognizedText)
        }
        request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        DispatchQueue.global(qos: .userInitiated).async {
            do { try handler.perform([request]) }
            catch {
                print("Text Recognition failed: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }
}

// MARK: - 1. Data Model (with in-place color update)
struct ClothingItem: Identifiable, Codable {
    let id: UUID
    let dateAdded: Date
    private let imageData: Data
    private var colorHex: String
    var category: String
    var text: String?
    var colorName: String
    let confidence: Int
    var embedding: [Float]?
    var normalizedEmbedding: [Float]?
    
    var image: UIImage {
        return UIImage(data: imageData) ?? UIImage(systemName: "questionmark.square.dashed")!
    }
    var colorValue: Color { Color(hex: colorHex) ?? .gray }
    
    init(image: UIImage, category: String, colorName: String, colorValue: Color, text: String?, confidence: Int, embedding: [Float]? = nil) {
        self.id = UUID()
        self.dateAdded = Date()
        self.imageData = image.jpegData(compressionQuality: 0.7) ?? Data()
        self.colorHex = colorValue.toHex() ?? "#808080"
        self.category = category
        self.text = text
        self.colorName = colorName
        self.confidence = confidence
        self.embedding = embedding
        if let emb = embedding {
            self.normalizedEmbedding = ClothingItem.normalize(emb)
        } else {
            self.normalizedEmbedding = nil
        }
    }
    static func normalize(_ v: [Float]) -> [Float]? {
        let mag = sqrt(v.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard mag > 0 else { return nil }
        return v.map { $0 / Float(mag) }
    }
}
extension ClothingItem {
    mutating func applyColor(_ color: Color, name: String) {
        if let hex = color.toHex() { self.colorHex = hex }
        self.colorName = name
    }
}

// MARK: - Outfit AI Additions
enum ClothingRole: String { case top, bottom, shoes, outerwear, unknown }
fileprivate enum RoleLexicon {
    static let tops: Set<String> = ["t-shirt","tee","shirt","blouse","top","sweater","hoodie","pullover","polo","tank","longsleeve","crewneck","jumper","knit"]
    static let bottoms: Set<String> = ["jeans","pants","trousers","shorts","skirt","chinos","leggings","sweatpants","cargo","joggers"]
    static let shoes: Set<String> = ["sneaker","sneakers","shoes","shoe","boot","boots","loafer","loafers","heel","heels","trainer","trainers"]
    static let outer: Set<String> = ["jacket","coat","blazer","cardigan","parka","windbreaker","overcoat","vest","hoodie","puffer","raincoat","trench"]
}
extension ClothingItem {
    var inferredRole: ClothingRole {
        let c = category.lowercased()
        for w in RoleLexicon.tops where c.contains(w) { return .top }
        for w in RoleLexicon.bottoms where c.contains(w) { return .bottom }
        for w in RoleLexicon.shoes where c.contains(w) { return .shoes }
        for w in RoleLexicon.outer where c.contains(w) { return .outerwear }
        return .unknown
    }
}
fileprivate func isNeutral(colorName: String) -> Bool {
    let n = colorName.lowercased()
    return n.contains("black") || n.contains("white") || n.contains("gray") || n.contains("grey") || n.contains("brown") || n.contains("beige") || n.contains("cream")
}
fileprivate func hue(of color: Color) -> CGFloat? {
    let ui = UIColor(color)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return h.isNaN ? nil : h
}
fileprivate struct OutfitIntent {
    enum Occasion: String { case casual, work, formal, sport, unknown }
    enum Temperature: String { case cold, cool, mild, warm, hot, unknown }
    struct Conditions: OptionSet {
        let rawValue: Int
        static let rainy  = Conditions(rawValue: 1 << 0)
        static let windy  = Conditions(rawValue: 1 << 1)
        static let snowy  = Conditions(rawValue: 1 << 2)
        static let humid  = Conditions(rawValue: 1 << 3)
        static let sunny  = Conditions(rawValue: 1 << 4)
    }
    var occasion: Occasion = .unknown
    var temperature: Temperature = .unknown
    var conditions: Conditions = []
    init(from text: String) {
        let t = text.lowercased()
        if t.contains("formal") || t.contains("wedding") { occasion = .formal }
        else if t.contains("work") || t.contains("office") || t.contains("business") { occasion = .work }
        else if t.contains("sport") || t.contains("gym") || t.contains("run") || t.contains("training") { occasion = .sport }
        else if t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty { occasion = .unknown }
        else { occasion = .casual }
        if t.contains("freezing") || t.contains("very cold") || t.contains("snow") || t.contains("snowy") {
            temperature = .cold; conditions.insert(.snowy)
        } else if t.contains("cold") || t.contains("chilly") || t.contains("cool") {
            temperature = t.contains("cool") ? .cool : .cold
        } else if t.contains("warm") { temperature = .warm }
        else if t.contains("hot") || t.contains("heat") { temperature = .hot }
        else if t.contains("mild") { temperature = .mild }
        if t.contains("rain") || t.contains("rainy") || t.contains("drizzle") { conditions.insert(.rainy) }
        if t.contains("wind") || t.contains("windy") || t.contains("breezy") { conditions.insert(.windy) }
        if t.contains("humid") || t.contains("sticky") { conditions.insert(.humid) }
        if t.contains("sunny") || t.contains("clear") { conditions.insert(.sunny) }
    }
}
fileprivate func colorHarmonyScore(_ a: ClothingItem?, _ b: ClothingItem?) -> Double {
    guard let a = a, let b = b else { return 0 }
    let aNeutral = isNeutral(colorName: a.colorName), bNeutral = isNeutral(colorName: b.colorName)
    if aNeutral && bNeutral { return 0.5 }
    if aNeutral || bNeutral { return 1.0 }
    if let ha = hue(of: a.colorValue), let hb = hue(of: b.colorValue) {
        let diff = abs(ha - hb), minDiff = min(diff, 1 - diff)
        if minDiff < 0.08 { return 0.9 }
        if abs(minDiff - 0.33) < 0.08 { return 0.7 }
        if abs(minDiff - 0.5) < 0.08 { return 0.6 }
        return 0.4
    }
    return 0.6
}
fileprivate func occasionScore(for item: ClothingItem, occasion: OutfitIntent.Occasion) -> Double {
    let c = item.category.lowercased()
    switch occasion {
    case .formal:
        if c.contains("blazer") || c.contains("coat") || c.contains("shirt") || c.contains("trousers") || c.contains("loafer") || c.contains("oxford") { return 1.0 }
        if c.contains("jeans") || c.contains("sneaker") || c.contains("hoodie") { return 0.2 }
        return 0.6
    case .work:
        if c.contains("shirt") || c.contains("chinos") || c.contains("trousers") || c.contains("blazer") || c.contains("loaf") { return 0.9 }
        if c.contains("hoodie") || c.contains("sweatpants") { return 0.2 }
        return 0.6
    case .sport:
        if c.contains("sweat") || c.contains("shorts") || c.contains("trainer") || c.contains("sneaker") || c.contains("legging") { return 1.0 }
        return 0.3
    case .casual:
        if c.contains("jeans") || c.contains("t-shirt") || c.contains("tee") || c.contains("sneaker") || c.contains("hoodie") { return 0.9 }
        return 0.6
    case .unknown:
        return 0.6
    }
}
fileprivate func weatherScore(for item: ClothingItem, intent: OutfitIntent) -> Double {
    let c = item.category.lowercased()
    var score: Double = 0
    switch intent.temperature {
    case .cold:
        if c.contains("coat") || c.contains("parka") || c.contains("puffer") || c.contains("jacket") || c.contains("overcoat") || c.contains("trench") { score += 1.2 }
        if c.contains("sweater") || c.contains("jumper") || c.contains("knit") || c.contains("hoodie") || c.contains("cardigan") { score += 0.9 }
        if c.contains("boots") || c.contains("boot") { score += 0.6 }
        if c.contains("t-shirt") || c.contains("tee") || c.contains("tank") { score -= 0.6 }
        if c.contains("shorts") || c.contains("skirt") { score -= 0.8 }
    case .cool:
        if c.contains("jacket") || c.contains("coat") || c.contains("cardigan") || c.contains("hoodie") { score += 0.8 }
        if c.contains("sweater") || c.contains("jumper") { score += 0.7 }
        if c.contains("tank") { score -= 0.5 }
        if c.contains("shorts") { score -= 0.4 }
    case .mild:
        score += 0.2
    case .warm:
        if c.contains("t-shirt") || c.contains("tee") || c.contains("polo") || c.contains("tank") { score += 0.5 }
        if c.contains("shorts") || c.contains("skirt") { score += 0.6 }
        if c.contains("sweater") || c.contains("coat") || c.contains("hoodie") { score -= 0.6 }
    case .hot:
        if c.contains("tank") || c.contains("tee") || c.contains("t-shirt") { score += 0.7 }
        if c.contains("shorts") || c.contains("skirt") { score += 0.8 }
        if c.contains("sweater") || c.contains("coat") || c.contains("jacket") || c.contains("hoodie") { score -= 1.0 }
        if c.contains("boots") { score -= 0.6 }
    case .unknown:
        break
    }
    if intent.conditions.contains(.rainy) {
        if c.contains("raincoat") || c.contains("parka") || c.contains("jacket") || c.contains("coat") { score += 0.6 }
        if c.contains("sneaker") || c.contains("trainer") { score += 0.2 }
        if c.contains("skirt") { score -= 0.2 }
    }
    if intent.conditions.contains(.windy) {
        if c.contains("windbreaker") || c.contains("jacket") || c.contains("coat") { score += 0.5 }
        if c.contains("tank") { score -= 0.3 }
    }
    if intent.conditions.contains(.snowy) {
        if c.contains("coat") || c.contains("parka") || c.contains("puffer") { score += 0.8 }
        if c.contains("boots") { score += 0.6 }
        if c.contains("shorts") || c.contains("skirt") { score -= 1.0 }
    }
    if intent.conditions.contains(.humid) && (intent.temperature == .warm || intent.temperature == .hot) {
        if c.contains("tank") || c.contains("tee") || c.contains("polo") { score += 0.3 }
        if c.contains("sweater") || c.contains("hoodie") { score -= 0.5 }
    }
    return score
}

// Outfit model
struct Outfit: Identifiable, Equatable {
    let id = UUID()
    let top: ClothingItem?
    let bottom: ClothingItem?
    let outerwear: ClothingItem?
    let shoes: ClothingItem?
    let reason: String
    static func == (lhs: Outfit, rhs: Outfit) -> Bool {
        return lhs.top?.id == rhs.top?.id &&
        lhs.bottom?.id == rhs.bottom?.id &&
        lhs.outerwear?.id == rhs.outerwear?.id &&
        lhs.shoes?.id == rhs.shoes?.id
    }
}

// MARK: Feedback Store
struct PairKey: Hashable, Codable {
    let a: UUID
    let b: UUID
    init(_ a: UUID, _ b: UUID) {
        if a.uuidString < b.uuidString { self.a = a; self.b = b } else { self.a = b; self.b = a }
    }
}
struct FeedbackStore: Codable {
    var likes: [PairKey: Int] = [:]
    var dislikes: [PairKey: Int] = [:]
    mutating func recordLike(_ a: UUID, _ b: UUID) { likes[PairKey(a,b), default: 0] += 1 }
    mutating func recordDislike(_ a: UUID, _ b: UUID) { dislikes[PairKey(a,b), default: 0] += 1 }
    func score(_ a: UUID, _ b: UUID) -> Double {
        let k = PairKey(a, b)
        let l = Double(likes[k] ?? 0), d = Double(dislikes[k] ?? 0)
        let total = l + d + 2.0
        let mean = (l + 1.0) / total
        return mean - 0.5
    }
}

// Suggestion history entry
struct SuggestionHistoryEntry: Identifiable, Codable {
    let id: UUID
    let date: Date
    let topID: UUID?
    let bottomID: UUID?
    let outerID: UUID?
    let shoesID: UUID?
    init(outfit: Outfit) {
        self.id = UUID()
        self.date = Date()
        self.topID = outfit.top?.id
        self.bottomID = outfit.bottom?.id
        self.outerID = outfit.outerwear?.id
        self.shoesID = outfit.shoes?.id
    }
}

// MARK: - Embedding helpers
fileprivate func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Double = 0
    for i in 0..<a.count { dot += Double(a[i] * b[i]) }
    return dot
}
fileprivate func similarityBetween(_ x: ClothingItem?, _ y: ClothingItem?) -> Double {
    guard let xe = x?.normalizedEmbedding, let ye = y?.normalizedEmbedding else { return 0 }
    let cos = cosineSimilarity(xe, ye)
    return (cos + 1.0) / 2.0
}

// Recommender
final class OutfitRecommender {
    private let stylistAI = LocalStylistAI()
    struct OutfitScore: Identifiable {
        let id = UUID()
        let outfit: Outfit
        let score: Double
    }
    func recommendCandidates(from items: [ClothingItem], occasionText: String, feedback: FeedbackStore?, topK: Int = 10, seed: Int? = nil) -> [OutfitScore] {
        let intent = OutfitIntent(from: occasionText)
        let tops = items.filter { $0.inferredRole == .top }
        let bottoms = items.filter { $0.inferredRole == .bottom }
        let outers = items.filter { $0.inferredRole == .outerwear }
        let shoes = items.filter { $0.inferredRole == .shoes }

        var rng = SeededRandomNumberGenerator(seed: UInt64(seed ?? Int(Date().timeIntervalSince1970)))
        var scores: [OutfitScore] = []

        for t in tops {
            for b in bottoms {
                let bestOuter = outers.max(by: {
                    comboScore(top: t, bottom: b, outer: $0, shoes: nil, intent: intent, feedback: feedback) <
                    comboScore(top: t, bottom: b, outer: $1, shoes: nil, intent: intent, feedback: feedback)
                })
                let bestShoes = shoes.max(by: {
                    comboScore(top: t, bottom: b, outer: bestOuter, shoes: $0, intent: intent, feedback: feedback) <
                    comboScore(top: t, bottom: b, outer: bestOuter, shoes: $1, intent: intent, feedback: feedback)
                })

                let s = comboScore(top: t, bottom: b, outer: bestOuter, shoes: bestShoes, intent: intent, feedback: feedback)
                let reason = "Balanced colors and suitable for \(intent.occasion.rawValue)."
                let outfit = Outfit(top: t, bottom: b, outerwear: bestOuter, shoes: bestShoes, reason: reason)
                scores.append(OutfitScore(outfit: outfit, score: s + Double.random(in: -0.01...0.01, using: &rng)))
            }
        }

        return scores.sorted(by: { $0.score > $1.score }).prefix(max(1, topK)).map { $0 }
    }
    func recommend(from items: [ClothingItem], occasionText: String, feedback: FeedbackStore?, seed: Int? = nil) -> Outfit? {
        // Try AI-first selection; fall back to local ranking
        if let aiPick = stylistAI.pickOutfitSync(items: items, occasion: occasionText) {
            return aiPick
        }
        let list = recommendCandidates(from: items, occasionText: occasionText, feedback: feedback, topK: 1, seed: seed)
        guard let best = list.first else { return nil }
        
        let aiReason = stylistAI.generateExplanation(
            top: best.outfit.top?.category ?? "top",
            bottom: best.outfit.bottom?.category ?? "bottom",
            occasion: occasionText.isEmpty ? "casual" : occasionText
        )

        return Outfit(
            top: best.outfit.top,
            bottom: best.outfit.bottom,
            outerwear: best.outfit.outerwear,
            shoes: best.outfit.shoes,
            reason: aiReason
        )
    }
    private func comboScore(top: ClothingItem, bottom: ClothingItem, outer: ClothingItem?, shoes: ClothingItem?, intent: OutfitIntent, feedback: FeedbackStore?) -> Double {
        var score: Double = 0
        score += colorHarmonyScore(top, bottom)
        if let o = outer { score += 0.4 * colorHarmonyScore(o, top) + 0.4 * colorHarmonyScore(o, bottom) }
        if let s = shoes { score += 0.3 * colorHarmonyScore(s, top) + 0.3 * colorHarmonyScore(s, bottom) }

        var simAccumulator: Double = 0
        var simCount: Double = 0
        let pairs: [(ClothingItem?, ClothingItem?)] = [
            (top, bottom), (outer, top), (outer, bottom), (shoes, top), (shoes, bottom)
        ]
        for (a, b) in pairs {
            let sim = similarityBetween(a, b)
            if sim > 0 {
                simAccumulator += sim
                simCount += 1
            }
        }
        let cohesion = simCount > 0 ? (simAccumulator / simCount) : 0
        score += 1.0 * cohesion

        score += occasionScore(for: top, occasion: intent.occasion)
        score += occasionScore(for: bottom, occasion: intent.occasion)
        if let o = outer { score += 0.6 * occasionScore(for: o, occasion: intent.occasion) }
        if let s = shoes { score += 0.5 * occasionScore(for: s, occasion: intent.occasion) }

        score += weatherScore(for: top, intent: intent)
        score += weatherScore(for: bottom, intent: intent)
        if let o = outer { score += 0.5 * weatherScore(for: o, intent: intent) }
        if let s = shoes { score += 0.4 * weatherScore(for: s, intent: intent) }

        if let fb = feedback {
            score += 0.8 * fb.score(top.id, bottom.id)
            if let o = outer {
                score += 0.4 * fb.score(top.id, o.id)
                score += 0.4 * fb.score(bottom.id, o.id)
            }
            if let s = shoes {
                score += 0.3 * fb.score(top.id, s.id)
                score += 0.3 * fb.score(bottom.id, s.id)
                if let o = outer {
                    score += 0.2 * fb.score(o.id, s.id)
                }
            }
        }
        return score
    }
}

// Simple seeded RNG for deterministic shuffling
fileprivate struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xdeadbeef : seed }
    mutating func next() -> UInt64 {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return state &* 2685821657736338717
    }
}

// MARK: - Background Processing Queue
enum ProcessingStatus: String, Codable { case queued, processing, done, failed }
struct ProcessingJob: Identifiable, Codable, Equatable {
    let id: UUID
    let createdAt: Date
    var status: ProcessingStatus
    var errorMessage: String?
    private let thumbData: Data?
    var thumbnail: UIImage? { guard let thumbData else { return nil }; return UIImage(data: thumbData) }
    init(image: UIImage) {
        self.id = UUID()
               self.createdAt = Date()
        self.status = .queued
        self.errorMessage = nil
        self.thumbData = image.jpegData(compressionQuality: 0.4)
    }
}

// MARK: - Wardrobe Manager
class WardrobeManager: ObservableObject {
    @Published var items: [ClothingItem] = []
    @Published var processingJobs: [ProcessingJob] = []
    @Published private(set) var feedbackStore: FeedbackStore = FeedbackStore()
    @Published private(set) var suggestionHistory: [SuggestionHistoryEntry] = []
    private let storageKey = "WardrobeItems"
    private let jobsKey = "ProcessingJobs"
    private let feedbackKey = "OutfitFeedbackStore"
    private let historyKey = "OutfitSuggestionHistory"
    private var isWorkerRunning = false
    private let workerQueue = DispatchQueue(label: "WardrobeWorkerQueue", qos: .userInitiated)
    
    init() {
        // Make preview init extremely light
        if isRunningInPreviews {
            self.items = []
            return
        }
        loadItems(); loadJobs(); loadFeedback(); loadHistory()
        if items.isEmpty {
            if let placeholderImage = UIImage(named: "placeholderShirt"),
               let color = placeholderImage.dominantColor {
                let colorName = UIImage().toColorName(color: color)
                self.items.append(ClothingItem(image: placeholderImage, category: "Sample Shirt", colorName: colorName, colorValue: color, text: "Fashionista Brand", confidence: 90))
            }
            saveItems()
        }
        // Skip starting the worker in SwiftUI Previews to avoid crashes/timeouts
        let isPreview = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
        if !isPreview {
            startWorkerIfNeeded()
        }
    }
    func saveItems() {
        do { let data = try JSONEncoder().encode(items); UserDefaults.standard.set(data, forKey: storageKey) }
        catch { print("❌ Failed to encode wardrobe items: \(error.localizedDescription)") }
    }
    private func saveJobs() {
        do { let data = try JSONEncoder().encode(processingJobs); UserDefaults.standard.set(data, forKey: jobsKey) }
        catch { print("❌ Failed to encode processing jobs: \(error.localizedDescription)") }
    }
    private func saveFeedback() {
        do { let data = try JSONEncoder().encode(feedbackStore); UserDefaults.standard.set(data, forKey: feedbackKey) }
        catch { print("❌ Failed to encode feedback: \(error.localizedDescription)") }
    }
    private func saveHistory() {
        do { let data = try JSONEncoder().encode(suggestionHistory); UserDefaults.standard.set(data, forKey: historyKey) }
        catch { print("❌ Failed to encode history: \(error.localizedDescription)") }
    }
    func loadItems() {
        if let data = UserDefaults.standard.data(forKey: storageKey) {
            do { self.items = try JSONDecoder().decode([ClothingItem].self, from: data) }
            catch { print("❌ Failed to decode wardrobe items: \(error.localizedDescription)") }
        }
    }
    private func loadJobs() {
        if let data = UserDefaults.standard.data(forKey: jobsKey) {
            do {
                var jobs = try JSONDecoder().decode([ProcessingJob].self, from: data)
                for i in jobs.indices where jobs[i].status == .processing { jobs[i].status = .queued }
                self.processingJobs = jobs
            } catch { print("❌ Failed to decode processing jobs: \(error.localizedDescription)") }
        }
    }
    private func loadFeedback() {
        if let data = UserDefaults.standard.data(forKey: feedbackKey) {
            do { self.feedbackStore = try JSONDecoder().decode(FeedbackStore.self, from: data) }
            catch { print("❌ Failed to decode feedback: \(error.localizedDescription)") }
        }
    }
    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: historyKey) {
            do { self.suggestionHistory = try JSONDecoder().decode([SuggestionHistoryEntry].self, from: data) }
            catch { print("❌ Failed to decode history: \(error.localizedDescription)") }
        }
    }
    func addItem(image: UIImage, category: String, colorName: String, colorValue: Color, text: String?, confidence: Int, embedding: [Float]? = nil) {
        let newItem = ClothingItem(image: image, category: category, colorName: colorName, colorValue: colorValue, text: text, confidence: confidence, embedding: embedding)
        items.append(newItem); saveItems()
    }
    func deleteItem(id: UUID) { items.removeAll { $0.id == id }; saveItems() }
    func updateDescription(id: UUID, newCategory: String, newText: String?, newColor: Color? = nil, newColorName: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].category = newCategory; items[index].text = newText
        if let color = newColor {
            let name = newColorName ?? UIImage().toColorName(color: color)
            items[index].applyColor(color, name: name)
        }
        saveItems()
    }
    func updateColor(id: UUID, newColor: Color, newColorName: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let name = newColorName ?? UIImage().toColorName(color: newColor)
        items[index].applyColor(newColor, name: name); saveItems()
    }
    func updateEmbedding(id: UUID, embedding: [Float]?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].embedding = embedding
        items[idx].normalizedEmbedding = embedding.flatMap(ClothingItem.normalize)
        saveItems()
    }
    func like(outfit: Outfit) {
        var fs = feedbackStore
        if let t = outfit.top, let b = outfit.bottom { fs.recordLike(t.id, b.id) }
        if let t = outfit.top, let o = outfit.outerwear { fs.recordLike(t.id, o.id) }
        if let b = outfit.bottom, let o = outfit.outerwear { fs.recordLike(b.id, o.id) }
        if let t = outfit.top, let s = outfit.shoes { fs.recordLike(t.id, s.id) }
        if let b = outfit.bottom, let s = outfit.shoes { fs.recordLike(b.id, s.id) }
        if let o = outfit.outerwear, let s = outfit.shoes { fs.recordLike(o.id, s.id) }
        feedbackStore = fs; saveFeedback()
    }
    func dislike(outfit: Outfit) {
        var fs = feedbackStore
        if let t = outfit.top, let b = outfit.bottom { fs.recordDislike(t.id, b.id) }
        if let t = outfit.top, let o = outfit.outerwear { fs.recordDislike(t.id, o.id) }
        if let b = outfit.bottom, let o = outfit.outerwear { fs.recordDislike(b.id, o.id) }
        if let t = outfit.top, let s = outfit.shoes { fs.recordDislike(t.id, s.id) }
        if let b = outfit.bottom, let s = outfit.shoes { fs.recordDislike(b.id, s.id) }
        if let o = outfit.outerwear, let s = outfit.shoes { fs.recordDislike(o.id, s.id) }
        feedbackStore = fs; saveFeedback()
    }
    func addToHistory(outfit: Outfit) {
        let entry = SuggestionHistoryEntry(outfit: outfit)
        suggestionHistory.insert(entry, at: 0)
        if suggestionHistory.count > 100 {
            suggestionHistory.removeLast(suggestionHistory.count - 100)
        }
        saveHistory()
    }
    func enqueue(image: UIImage) {
        let job = ProcessingJob(image: image)
        processingJobs.append(job); saveJobs(); startWorkerIfNeeded()
    }
    func cancel(jobID: UUID) {
        if let idx = processingJobs.firstIndex(where: { $0.id == jobID }) {
            processingJobs.remove(at: idx); saveJobs()
        }
    }
    func clearFinishedJobs() {
        processingJobs.removeAll { $0.status == .done || $0.status == .failed }; saveJobs()
    }
    private func startWorkerIfNeeded() {
        guard !isWorkerRunning else { return }
        isWorkerRunning = true
        workerQueue.async { [weak self] in self?.workerLoop() }
    }
    private func workerLoop() {
        while true {
            guard let nextIndex = processingJobs.firstIndex(where: { $0.status == .queued }) else {
                isWorkerRunning = false; return
            }
            DispatchQueue.main.async { [self] in
                self.processingJobs[nextIndex].status = .processing
                self.saveJobs()
            }
            let job = processingJobs[nextIndex]
            do {
                try process(job: job)
                DispatchQueue.main.async { [self] in
                    if let idx = self.processingJobs.firstIndex(where: { $0.id == job.id }) {
                        self.processingJobs[idx].status = .done
                        self.saveJobs()
                    }
                }
            } catch {
                DispatchQueue.main.async { [self] in
                    if let idx = self.processingJobs.firstIndex(where: { $0.id == job.id }) {
                        self.processingJobs[idx].status = .failed
                        self.processingJobs[idx].errorMessage = error.localizedDescription
                        self.saveJobs()
                    }
                }
            }
        }
    }
    private func process(job: ProcessingJob) throws {
        guard let uiImage = job.thumbnail else { return }
        let originalImage = uiImage
        let scaledImage = downscale(image: originalImage, maxDimension: 768)
        let (category, confidence) = classify(image: scaledImage)
        let color = originalImage.dominantColor ?? .gray
        let colorName = UIImage().toColorName(color: color)
        var newItemID: UUID?
        DispatchQueue.main.async { [self] in
            self.addItem(image: originalImage, category: category, colorName: colorName, colorValue: color, text: nil, confidence: confidence, embedding: nil)
            newItemID = self.items.last?.id
        }
        // Wait briefly to ensure item append occurred before updating embedding
        usleep(20_000)
        let embedding = generateEmbedding(image: scaledImage)
        if let id = newItemID {
            DispatchQueue.main.async { [self] in
                self.updateEmbedding(id: id, embedding: embedding)
            }
        }
    }
    private func classify(image: UIImage) -> (String, Int) {
        guard let cg = image.cgImage else { return ("Unknown", 0) }
        var outCategory = "Unknown", outConfidence = 0
        // Only attempt model init if you actually have a compiled model available.
        if let modelURL = Bundle.main.url(forResource: "ClothingClassifier", withExtension: "mlmodelc"),
           let compiledModel = try? MLModel(contentsOf: modelURL),
           let vnModel = try? VNCoreMLModel(for: compiledModel) {
            let request = VNCoreMLRequest(model: vnModel) { request, _ in
                if let results = request.results as? [VNClassificationObservation], let top = results.first {
                    outCategory = top.identifier; outConfidence = Int(top.confidence * 100)
                }
            }
            let handler = VNImageRequestHandler(cgImage: cg, orientation: cgOrientation(from: image.imageOrientation), options: [:])
            do { try handler.perform([request]) } catch { print("❌ Classification failed: \(error.localizedDescription)") }
        } else {
            // Safe fallback if the model class isn't present
            outCategory = "Clothing"
            outConfidence = 50
        }
        return (outCategory, outConfidence)
    }
    private func generateEmbedding(image: UIImage) -> [Float]? {
        guard let cg = image.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: cgOrientation(from: image.imageOrientation), options: [:])
        do {
            try handler.perform([request])
            guard let result = request.results?.first as? VNFeaturePrintObservation else { return nil }
            let data = result.data
            let byteCount = data.count
            let floatSize = MemoryLayout<Float>.size
            guard byteCount > 0, byteCount % floatSize == 0 else { return nil }
            let count = byteCount / floatSize
            var floats = Array<Float>(repeating: 0, count: count)
            _ = floats.withUnsafeMutableBytes { dst in
                data.copyBytes(to: dst)
            }
            return floats
        } catch {
            print("❌ Embedding failed: \(error.localizedDescription)")
            return nil
        }
    }
    private func downscale(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension, maxSide > 0 else { return image }
        let scale = maxDimension / maxSide
        let newSize = CGSize(width: max(1, size.width * scale), height: max(1, size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
    private func cgOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}

// MARK: - 3. Camera Tab View (multi-select)
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var selectedImages: [UIImage]
    var maxSelection: Int = 10
    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        var parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let limited = Array(results.prefix(parent.maxSelection))
            let group = DispatchGroup()
            var images: [UIImage] = []
            for result in limited {
                group.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { (obj, error) in
                    defer { group.leave() }
                    if let ui = obj as? UIImage { images.append(ui) }
                    else if let error = error { print("Error loading image from Photo Library: \(error.localizedDescription)") }
                }
            }
            group.notify(queue: .main) {
                self.parent.selectedImages = images
                self.parent.isPresented = false
            }
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = maxSelection
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
}

struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    @Binding var selectedImages: [UIImage]
    var maxSelection: Int = 10
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: DocumentPicker
        init(_ parent: DocumentPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            let limited = Array(urls.prefix(parent.maxSelection))
            var images: [UIImage] = []
            for url in limited {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    if let data = try? Data(contentsOf: url), let img = UIImage(data: data) { images.append(img) }
                }
            }
            DispatchQueue.main.async {
                self.parent.selectedImages = images
                self.parent.isPresented = false
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.isPresented = false }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
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

// MARK: - 4. Wardrobe Tab View
struct CameraTabView: View {
    @EnvironmentObject var wardrobeManager: WardrobeManager
    @State private var showingLiveCamera = false
    @State private var showingSelectImageMenu = false
    @State private var showingPhotoPicker = false
    @State private var showingDocumentPicker = false
    @State private var selectedImages: [UIImage] = []
    @State private var recognizedText: String? = nil
    var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 50)
            Text("Scan your clothes").font(.largeTitle).fontWeight(.bold).padding(.horizontal)
            Spacer().frame(height: 12)
            if !selectedImages.isEmpty {
                VStack {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(selectedImages.enumerated()), id: \.offset) { _, img in
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 120, height: 120).clipped().cornerRadius(10)
                            }
                        }.padding(.horizontal)
                    }.frame(height: 140)
                    HStack(spacing: 12) {
                        Button { selectedImages.removeAll() } label: { Label("Clear", systemImage: "xmark") }
                        .buttonStyle(.borderedProminent).tint(.red)
                        Button {
                            for img in selectedImages.prefix(10) { wardrobeManager.enqueue(image: img) }
                            selectedImages.removeAll()
                        } label: { Label("Add to Queue (\(min(selectedImages.count, 10)))", systemImage: "tray.and.arrow.down.fill") }
                        .buttonStyle(.borderedProminent).tint(.green).disabled(selectedImages.isEmpty)
                    }
                    .padding(.top, 8).padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 20).fill(Color.white).shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5))
                .padding(.horizontal)
                .transition(.opacity.combined(with: .scale))
            } else {
                VStack(spacing: 16) {
                    Button("Allow camera") { }
                        .font(.headline).padding(.vertical, 12).padding(.horizontal, 30)
                        .background(Capsule().stroke(Color.gray, lineWidth: 1)).foregroundColor(.black)
                    HStack {
                        Button("Scan") { showingLiveCamera = true }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
                        Button("+") { showingSelectImageMenu = true }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(.blue)
                    }.padding(.horizontal)
                }.transition(.opacity)
            }
            ProcessingQueueView().environmentObject(wardrobeManager).padding(.horizontal).padding(.top, 8)
            Spacer()
        }
        .sheet(isPresented: $showingLiveCamera) { LiveCameraScreen(selectedImage: .constant(nil)) }
        .sheet(isPresented: $showingSelectImageMenu) { ImageSourceMenu(showingPhotoPicker: $showingPhotoPicker, showingDocumentPicker: $showingDocumentPicker) }
        .sheet(isPresented: $showingPhotoPicker) { ImagePicker(isPresented: $showingPhotoPicker, selectedImages: $selectedImages, maxSelection: 10) }
        .fullScreenCover(isPresented: $showingDocumentPicker) { DocumentPicker(isPresented: $showingDocumentPicker, selectedImages: $selectedImages, maxSelection: 10) }
        .animation(.default, value: selectedImages)
    }
}
struct ProcessingQueueView: View {
    @EnvironmentObject var wardrobeManager: WardrobeManager
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Background Processing", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                Spacer()
                if wardrobeManager.processingJobs.contains(where: { $0.status == .done || $0.status == .failed }) {
                    Button("Clear finished") { wardrobeManager.clearFinishedJobs() }.font(.caption)
                }
            }
            if wardrobeManager.processingJobs.isEmpty {
                Text("No items in queue.").foregroundColor(.secondary).font(.caption)
            } else {
                ForEach(wardrobeManager.processingJobs) { job in
                    HStack(spacing: 10) {
                        if let thumb = job.thumbnail {
                            Image(uiImage: thumb).resizable().scaledToFill().frame(width: 44, height: 44).clipped().cornerRadius(6)
                        } else {
                            RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.2)).frame(width: 44, height: 44)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.createdAt, style: .time).font(.subheadline)
                            if let err = job.errorMessage, job.status == .failed {
                                Text(err).font(.caption2).foregroundColor(.red)
                            }
                        }
                        Spacer()
                        StatusBadge(status: job.status)
                        if job.status == .queued {
                            Button { wardrobeManager.cancel(jobID: job.id) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.systemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.15), lineWidth: 1))
                }
            }
        }
    }
}
struct StatusBadge: View {
    let status: ProcessingStatus
    var body: some View {
        switch status {
        case .queued:
            Label("Queued", systemImage: "clock").padding(6).background(Capsule().fill(Color.yellow.opacity(0.2)))
        case .processing:
            Label("Processing", systemImage: "arrow.triangle.2.circlepath").padding(6).background(Capsule().fill(Color.blue.opacity(0.2)))
        case .done:
            Label("Done", systemImage: "checkmark.circle").padding(6).background(Capsule().fill(Color.green.opacity(0.2)))
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle").padding(6).background(Capsule().fill(Color.red.opacity(0.2)))
        }
    }
}

// MARK: - Wardrobe Tab
struct WardrobeTabView: View {
    @EnvironmentObject var wardrobeManager: WardrobeManager
    let columns = [ GridItem(.flexible()), GridItem(.flexible()) ]
    @State private var showingEditSheet = false
    @State private var itemToEdit: ClothingItem?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 1) {
                    Button(action: { }) { Image(systemName: "minus").frame(width: 30, height: 30).background(Color.gray.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
                    Text("\(wardrobeManager.items.count) Items").padding(.horizontal, 10).font(.callout)
                    Button(action: { }) { Image(systemName: "plus").frame(width: 30, height: 30).background(Color.gray.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
                }
                .padding(4).background(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.gray.opacity(0.5), lineWidth: 1))
                Spacer()
                Image(systemName: "sparkles.square.filled.on.square").foregroundColor(.purple)
            }
            .padding([.horizontal, .top]).padding(.bottom, 20)
            ScrollView {
                if wardrobeManager.items.isEmpty {
                    Text("Your wardrobe is empty! Scan an item in the Camera tab to get started.")
                        .foregroundColor(.secondary).multilineTextAlignment(.center).padding(.top, 50)
                } else {
                    LazyVGrid(columns: columns, spacing: 15) {
                        ForEach(wardrobeManager.items) { item in
                            VStack(alignment: .leading) {
                                Image(uiImage: item.image).resizable().scaledToFill().frame(minWidth: 0, maxWidth: .infinity).frame(height: 150).clipped().cornerRadius(10).shadow(radius: 3)
                                HStack {
                                    Circle().fill(item.colorValue).frame(width: 15, height: 15).overlay(Circle().stroke(Color.gray, lineWidth: 0.5))
                                    Text("\(item.colorName) \(item.category)").font(.headline).lineLimit(1)
                                }.padding(.top, 2)
                                if let text = item.text, !text.isEmpty { Text("(\(text))").font(.caption).foregroundColor(.indigo).lineLimit(1) }
                                Text("Added: \(item.dateAdded.formatted(date: .numeric, time: .omitted))").font(.caption).foregroundColor(.secondary)
                            }
                            .padding(8)
                            .background(Color(.systemBackground))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
                            .contextMenu {
                                Button(role: .destructive) { wardrobeManager.deleteItem(id: item.id) } label: { Label("Delete Item", systemImage: "trash") }
                                Button { itemToEdit = item } label: { Label("Change Description", systemImage: "pencil.circle") }
                            }
                        }
                    }
                    .padding(.horizontal).padding(.top, 10)
                }
            }
            Spacer()
        }
        .sheet(item: $itemToEdit) { item in
            EditClothingDescriptionView(item: item).environmentObject(wardrobeManager)
        }
    }
}
struct EditClothingDescriptionView: View {
    @EnvironmentObject var wardrobeManager: WardrobeManager
    @Environment(\.dismiss) var dismiss
    let itemID: UUID
    @State private var newCategory: String
    @State private var newText: String
    @State private var pickedColor: Color
    @State private var pickedColorName: String
    init(item: ClothingItem) {
        self.itemID = item.id
        _newCategory = State(initialValue: item.category)
        _newText = State(initialValue: item.text ?? "")
        _pickedColor = State(initialValue: item.colorValue)
        _pickedColorName = State(initialValue: item.colorName)
    }
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 20) {
                if let item = wardrobeManager.items.first(where: { $0.id == itemID }) {
                    Image(uiImage: item.image).resizable().scaledToFit().frame(height: 150).frame(maxWidth: .infinity).cornerRadius(10)
                }
                Text("Category / Item Type").font(.headline)
                TextField("e.g., T-shirt, Jeans, Dress", text: $newCategory).textFieldStyle(.roundedBorder)
                Text("Text / Logo").font(.headline)
                TextField("e.g., Nike, Supreme, Band Name", text: $newText).textFieldStyle(.roundedBorder)
                Divider().padding(.vertical, 6)
                Text("Color").font(.headline)
                HStack(spacing: 12) {
                    ColorPicker("Pick Color", selection: $pickedColor, supportsOpacity: false)
                    Circle().fill(pickedColor).frame(width: 24, height: 24).overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
                    Spacer()
                }.labelsHidden()
                TextField("Color name (optional)", text: $pickedColorName).textFieldStyle(.roundedBorder)
                    .onChange(of: pickedColor) { _, newValue in pickedColorName = UIImage().toColorName(color: newValue) }
                Button {
                    if let item = wardrobeManager.items.first(where: { $0.id == itemID }),
                       let auto = item.image.dominantColor {
                        pickedColor = auto; pickedColorName = UIImage().toColorName(color: auto)
                    }
                } label: { Label("Auto-detect color from image", systemImage: "eyedropper.halffull") }
                .buttonStyle(.bordered)
                Spacer()
            }
            .padding()
            .navigationTitle("Edit Item")
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Save") {
                    wardrobeManager.updateDescription(id: itemID, newCategory: newCategory, newText: newText.isEmpty ? nil : newText)
                    wardrobeManager.updateColor(id: itemID, newColor: pickedColor, newColorName: pickedColorName.isEmpty ? UIImage().toColorName(color: pickedColor) : pickedColorName)
                    dismiss()
                }.disabled(newCategory.isEmpty)
            )
        }
    }
}

// MARK: - 5. AI Tab + History
struct AITabView: View {
    @EnvironmentObject private var wardrobeManager: WardrobeManager
    @State private var occasion: String = ""
    @State private var candidates: [OutfitRecommender.OutfitScore] = []
    @State private var currentIndex: Int = 0
    @State private var animateCard: Bool = false
    private let recommender = OutfitRecommender()
    @State private var hideDislike: Bool = false
    
    private var currentOutfit: Outfit? {
        guard candidates.indices.contains(currentIndex) else { return nil }
        let os = candidates[currentIndex]
        let intent = OutfitIntent(from: occasion)
        if let top = os.outfit.top, let bottom = os.outfit.bottom {
            let harmonyTB = colorHarmonyScore(top, bottom)
            let reason = buildReason(top: top, bottom: bottom, outer: os.outfit.outerwear, shoes: os.outfit.shoes, intent: intent, vibeTB: 0.5, harmonyTB: harmonyTB)
            return Outfit(top: top, bottom: bottom, outerwear: os.outfit.outerwear, shoes: os.outfit.shoes, reason: reason)
        }
        return nil
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Spacer().frame(height: 50)
                Text("Let AI choose an outfit from your wardrobe").font(.largeTitle).fontWeight(.bold).padding(.horizontal)
                VStack(alignment: .leading, spacing: 12) {
                    Text("What is the occasion?").font(.headline)
                    TextField("e.g., it's cold and rainy, casual lunch, work meeting", text: $occasion)
                        .textFieldStyle(.plain).padding(.vertical, 8)
                        .overlay(VStack { Spacer(); Rectangle().frame(height: 1).foregroundColor(.gray) })
                    HStack(spacing: 12) {
                        Button {
                            Task { await pickOutfitsAI() }
                        } label: { Label("Pick Outfit", systemImage: "sparkles") }
                            .buttonStyle(.borderedProminent).tint(.blue)
                        if !candidates.isEmpty {
                            Button { animateToNext() } label: { Label("Try another", systemImage: "arrow.triangle.2.circlepath") }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(.horizontal)
                if wardrobeManager.items.isEmpty {
                    Text("Your wardrobe is empty. Add items in the Camera tab.").foregroundColor(.secondary).padding(.horizontal).padding(.top, 20)
                }
                if let outfit = currentOutfit {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Text("Recommended Outfit").font(.title2).fontWeight(.semibold)
                            Spacer()
                            Text("Option \(currentIndex + 1) of \(candidates.count)")
                                .font(.caption).foregroundColor(.secondary)
                            FeedbackButtons(hideDislike: hideDislike) {
                                if let current = currentOutfit { wardrobeManager.like(outfit: current) }
                                let generator = UINotificationFeedbackGenerator()
                                generator.notificationOccurred(.success)
                                withAnimation(.easeInOut(duration: 0.25)) { hideDislike = true }
                            } onDislike: {
                                if let current = currentOutfit { wardrobeManager.dislike(outfit: current) }
                                let generator = UINotificationFeedbackGenerator()
                                generator.notificationOccurred(.warning)
                                animateToNext()
                            }
                        }
                        ZStack(alignment: .bottomTrailing) {
                            OutfitView(outfit: outfit)
                                .padding(.bottom, 36)
                                .transition(.asymmetric(insertion: .scale.combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
                                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: animateCard)
                        }
                        Text(outfit.reason).font(.subheadline).foregroundColor(.secondary)
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)).shadow(color: .black.opacity(0.08), radius: 8, y: 4))
                    .padding(.horizontal)
                }
                
                if !wardrobeManager.suggestionHistory.isEmpty {
                    Text("History").font(.headline).padding(.horizontal)
                    VStack(spacing: 10) {
                        ForEach(wardrobeManager.suggestionHistory) { entry in
                            HistoryRow(entry: entry)
                                .environmentObject(wardrobeManager)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 20)
                }
                Spacer().frame(height: 40)
            }
        }
    }
    private func buildReason(top: ClothingItem, bottom: ClothingItem, outer: ClothingItem?, shoes: ClothingItem?, intent: OutfitIntent, vibeTB: Double, harmonyTB: Double) -> String {
        var parts: [String] = []
        switch intent.occasion {
        case .formal: parts.append("fits a formal setting")
        case .work: parts.append("works for the office")
        case .sport: parts.append("is sport-friendly")
        case .casual: parts.append("is casual and relaxed")
        case .unknown: break
        }
        switch intent.temperature {
        case .cold: parts.append("keeps you warm")
        case .cool: parts.append("is good for cooler weather")
        case .warm: parts.append("is comfortable in warm weather")
        case .hot: parts.append("stays cool in hot weather")
        case .mild, .unknown: break
        }
        if intent.conditions.contains(.rainy) { parts.append("handles rainy conditions") }
        if intent.conditions.contains(.windy) { parts.append("handles wind") }
        if intent.conditions.contains(.snowy) { parts.append("handles snow") }
        if intent.conditions.contains(.humid) { parts.append("is breathable for humidity") }
        if harmonyTB >= 0.8 { parts.append("colors are very harmonious") }
        else if harmonyTB >= 0.6 { parts.append("colors complement each other") }
        if let outer = outer {
            parts.append("outerwear adds practicality")
            if isNeutral(colorName: outer.colorName) { parts.append("and keeps the palette balanced") }
        }
        if shoes != nil { parts.append("and shoes complete the look") }
        return parts.isEmpty ? "This combination balances style and practicality." : parts.prefix(4).joined(separator: ", ") + "."
    }
    private func pickOutfits() {
        let list = recommender.recommendCandidates(from: wardrobeManager.items, occasionText: occasion, feedback: wardrobeManager.feedbackStore, topK: 10)
        candidates = list; currentIndex = 0; hideDislike = false
        if let outfit = currentOutfit { wardrobeManager.addToHistory(outfit: outfit) }
        withAnimation { animateCard.toggle() }
    }
    private func pickOutfitsAI() async {
        // Local stylist only; no network
        if let ai = OutfitRecommender().recommend(from: wardrobeManager.items, occasionText: occasion, feedback: wardrobeManager.feedbackStore) {
            let scored = OutfitRecommender.OutfitScore(outfit: ai, score: 1.0)
            candidates = [scored]
            currentIndex = 0
            hideDislike = false
            wardrobeManager.addToHistory(outfit: ai)
            withAnimation { animateCard.toggle() }
        } else {
            pickOutfits()
        }
    }
    private func animateToNext() {
        guard !candidates.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.25)) { animateCard.toggle() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            currentIndex = (currentIndex + 1) % candidates.count
            if let outfit = currentOutfit { wardrobeManager.addToHistory(outfit: outfit) }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { animateCard.toggle() }
            hideDislike = false
        }
    }
}

// Expandable History Row
struct HistoryRow: View {
    @EnvironmentObject var wardrobeManager: WardrobeManager
    let entry: SuggestionHistoryEntry
    @State private var isExpanded: Bool = false
    
    private func item(for id: UUID?) -> ClothingItem? {
        guard let id else { return nil }
        return wardrobeManager.items.first(where: { $0.id == id })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(entry.date, style: .date).font(.caption).foregroundColor(.secondary)
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .font(.caption)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isExpanded.toggle()
                }
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if let top = item(for: entry.topID) { MiniItemView(item: top) }
                        if let bottom = item(for: entry.bottomID) { MiniItemView(item: bottom) }
                        if let outer = item(for: entry.outerID) { MiniItemView(item: outer) }
                        if let shoes = item(for: entry.shoesID) { MiniItemView(item: shoes) }
                        if item(for: entry.topID) == nil && item(for: entry.bottomID) == nil && item(for: entry.outerID) == nil && item(for: entry.shoesID) == nil {
                            Text("Items no longer available").font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.15), lineWidth: 1))
    }
}

struct MiniItemView: View {
    let item: ClothingItem
    var body: some View {
        VStack(spacing: 4) {
            Image(uiImage: item.image).resizable().scaledToFill().frame(width: 56, height: 56).clipped().cornerRadius(6)
            Text(item.category).font(.caption2).lineLimit(1)
        }.frame(width: 60)
    }
}

struct OutfitView: View {
    let outfit: Outfit
    var body: some View {
        VStack(spacing: 12) {
            if let top = outfit.top { ItemRow(title: "Top", item: top) }
            if let bottom = outfit.bottom { ItemRow(title: "Bottom", item: bottom) }
            if let outer = outfit.outerwear { ItemRow(title: "Outerwear", item: outer) }
            if let shoes = outfit.shoes { ItemRow(title: "Shoes", item: shoes) }
            if outfit.top == nil && outfit.bottom == nil && outfit.outerwear == nil && outfit.shoes == nil {
                Text("No suitable combination found.").foregroundColor(.secondary)
            }
        }
    }
}
struct ItemRow: View {
    let title: String
    let item: ClothingItem
    var body: some View {
        HStack(spacing: 12) {
            Image(uiImage: item.image).resizable().scaledToFill().frame(width: 70, height: 70).clipped().cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.2), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundColor(.secondary)
                Text("\(item.colorName) \(item.category)").font(.headline).lineLimit(1)
                if let text = item.text, !text.isEmpty { Text(text).font(.caption).foregroundColor(.indigo).lineLimit(1) }
            }
            Spacer()
            Circle().fill(item.colorValue).frame(width: 16, height: 16).overlay(Circle().stroke(Color.gray.opacity(0.4), lineWidth: 0.5))
        }
    }
}

struct FeedbackButtons: View {
    var hideDislike: Bool = false
    var onLike: () -> Void
    var onDislike: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Button(action: onLike) {
                Image(systemName: "hand.thumbsup.fill").foregroundColor(.green)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green.opacity(0.15))
            if !hideDislike {
                Button(action: onDislike) {
                    Image(systemName: "hand.thumbsdown.fill").foregroundColor(.red)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red.opacity(0.15))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
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
                HStack { Spacer(); Button("Cancel") { dismiss() }.foregroundColor(.white).padding() }
                Spacer()
                Button(action: {
                    if let placeholder = UIImage(named: "placeholderShirt") { self.selectedImage = placeholder }
                    else { self.selectedImage = UIImage(systemName: "photo")?.withTintColor(.white, renderingMode: .alwaysOriginal) }
                    dismiss()
                }) {
                    Image(systemName: "circle.fill").font(.system(size: 80)).foregroundColor(.white)
                        .overlay(Image(systemName: "circle").font(.system(size: 90)).foregroundColor(.white.opacity(0.8)))
                }
                .padding(.bottom, 50)
            }
        }
    }
}
struct CameraViewRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero); view.backgroundColor = .black
        // Avoid starting camera in Previews to prevent crashes
        if !isRunningInPreviews {
            setupCamera(for: view)
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if let preview = uiView.layer.sublayers?.compactMap({ $0 as? AVCaptureVideoPreviewLayer }).first {
            preview.frame = uiView.bounds
        }
    }
    private func setupCamera(for view: UIView) {
        let session = AVCaptureSession()
        guard let camera = AVCaptureDevice.default(for: .video) else { return }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if session.canAddInput(input) { session.addInput(input) }
            let previewLayer = AVCaptureVideoPreviewLayer(session: session)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds
            view.layer.addSublayer(previewLayer)
            // Avoid starting camera on main thread; also ensure not in previews
            DispatchQueue.global(qos: .userInitiated).async {
                if !isRunningInPreviews {
                    session.startRunning()
                }
            }
        } catch { print("Error setting up camera: \(error.localizedDescription)") }
    }
}
struct LiveCameraFeed: View { var body: some View { CameraViewRepresentable().edgesIgnoringSafeArea(.all) } }

struct AppTabView: View {
    @StateObject var wardrobeManager = WardrobeManager()
    var body: some View {
        TabView {
            AITabView().tabItem { Label("AI", systemImage: "sparkles.square.filled.on.square") }.environmentObject(wardrobeManager)
            WardrobeTabView().tabItem { Label("Wardrobe", systemImage: "tshirt.fill") }.environmentObject(wardrobeManager)
            CameraTabView().tabItem { Label("Camera", systemImage: "camera.fill") }.environmentObject(wardrobeManager)
        }.tint(.pink)
    }
}

struct SplashScreenView: View {
    @State private var showLogoOnly = true
    @State private var animateLogo = false
    @State private var showFullSplashScreenContent = false
    @State private var showMainView = false
    @State private var showTermsSheet = false
    @Namespace var splashNamespace
    private var bgTop: Color { Color.purple.opacity(0.4) }
    private var bgBottom: Color { Color.pink.opacity(0.4) }
    private var logoImage: Image {
        if let ui = UIImage(named: "Logo") {
            return Image(uiImage: ui)
        } else {
            return Image(systemName: "tshirt")
        }
    }
    var body: some View {
        ZStack {
            if showMainView {
                AppTabView().transition(.opacity)
            } else {
                ZStack {
                    LinearGradient(colors: [bgTop, bgBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                    if showLogoOnly {
                        logoImage.resizable().scaledToFit().frame(width: 160, height: 160).cornerRadius(32)
                            .matchedGeometryEffect(id: "splashLogo", in: splashNamespace).shadow(radius: 10)
                            .opacity(animateLogo ? 1 : 0).scaleEffect(animateLogo ? 1 : 1.5)
                            .onAppear {
                                withAnimation(.easeOut(duration: 1)) { animateLogo = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                                    withAnimation(.spring(response: 0.8, dampingFraction: 0.7)) {
                                        showLogoOnly = false; showFullSplashScreenContent = true
                                    }
                                }
                            }
                    } else {
                        VStack(spacing: 25) {
                            logoImage.resizable().scaledToFit().frame(width: 120, height: 120).cornerRadius(28)
                                .matchedGeometryEffect(id: "splashLogo", in: splashNamespace).shadow(radius: 10)
                                .opacity(showFullSplashScreenContent ? 1 : 0)
                            Text("Fashionista").font(.system(size: 38, weight: .bold))
                                .opacity(showFullSplashScreenContent ? 1 : 0)
                                .animation(.easeIn(duration: 1).delay(0.1), value: showFullSplashScreenContent)
                            Text("Your fashion companion.").font(.system(size: 18, weight: .medium)).foregroundColor(.gray)
                                .opacity(showFullSplashScreenContent ? 1 : 0)
                                .animation(.easeIn(duration: 1).delay(0.2), value: showFullSplashScreenContent)
                            Spacer().frame(height: 40)
                            Button(action: { withAnimation(.easeInOut(duration: 0.3)) { showTermsSheet = true } }) {
                                Text("Get Started").font(.system(size: 18, weight: .semibold)).foregroundColor(.primary)
                                    .padding(.horizontal, 50).padding(.vertical, 16)
                                    .background(RoundedRectangle(cornerRadius: 20).fill(.ultraThinMaterial).shadow(color: .black.opacity(0.15), radius: 8, y: 4))
                            }
                            .opacity(showFullSplashScreenContent ? 1 : 0)
                            .animation(.easeIn(duration: 1).delay(0.3), value: showFullSplashScreenContent)
                        }
                        .padding().opacity(showFullSplashScreenContent ? 1 : 0)
                    }
                }.transition(.opacity).id("SplashScreen")
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
    private var abstractBackground: some View {
        LinearGradient(colors: [Color.purple.opacity(0.5), Color.blue.opacity(0.4), Color.pink.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
    }
    var body: some View {
        ZStack {
            abstractBackground
            Rectangle().fill(.regularMaterial).ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                HStack { Text("Terms and Conditions").font(.largeTitle).fontWeight(.heavy).foregroundColor(.primary); Spacer() }
                    .padding(.horizontal, 25).padding(.top, 10).padding(.bottom, 20)
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
                .padding(.horizontal, 25).padding(.bottom, 32)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.25 : 0.15), radius: 12, y: 6)
            }
        }.ignoresSafeArea(edges: .bottom).cornerRadius(20)
    }
}

// MARK: - Local AI Stylist Logic (LOCAL ONLY)
private class LlmInferenceOptions {
    var modelPath: String = ""
    var maxTokens: Int = 128
    var temperature: Double = 0.7
    init() {}
}
private class LlmInference {
    init(options: LlmInferenceOptions) throws { /* replace with real local inference init */ }
    func generateResponse(inputText: String) throws -> String {
        // replace with real generation
        return ""
    }
}

class LocalStylistAI {
    private var llm: LlmInference?

    init() {
        // Never initialize heavy AI in previews
        if isRunningInPreviews { return }
        if let modelPath = Bundle.main.path(forResource: "gemma", ofType: "bin") {
            let options = LlmInferenceOptions()
            options.modelPath = modelPath
            options.maxTokens = 150
            options.temperature = 0.8
            do {
                self.llm = try LlmInference(options: options)
            } catch {
                print("AI Engine Error: \(error)")
                self.llm = nil
            }
        } else {
            // gemma.bin not found; will use fallback strings
        }
    }

    func generateExplanation(top: String, bottom: String, occasion: String) -> String {
        guard !isRunningInPreviews else {
            return "This \(top) with \(bottom) is a sharp pick for a \(occasion) vibe."
        }
        if let llm {
            let prompt = "Explain in one punchy sentence why pairing a \(top) with \(bottom) works for a \(occasion) occasion, using trendy designer terminology."
            if let text = try? llm.generateResponse(inputText: prompt), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "A perfectly balanced silhouette for your \(occasion)."
    }
    
    func pickOutfitSync(items: [ClothingItem], occasion: String) -> Outfit? {
        guard !isRunningInPreviews else { return nil }
        if let llm {
            // Compact inventory description
            let pieces = items.map { "\($0.id.uuidString.prefix(8))|\($0.inferredRole.rawValue)|\($0.category)|\($0.colorName)" }.joined(separator: "; ")
            let prompt = """
            Choose an outfit from the inventory entries: [\(pieces)] for occasion: "\(occasion)".
            Return a compact JSON: {"top":"<id-prefix>", "bottom":"<id-prefix>", "outerwear":"<id-prefix or null>", "shoes":"<id-prefix or null>"}.
            """
            if let text = try? llm.generateResponse(inputText: prompt),
               let jsonStart = text.firstIndex(of: "{"),
               let jsonEnd = text.lastIndex(of: "}") {
                let json = String(text[jsonStart...jsonEnd])
                struct Resp: Decodable { let top: String?; let bottom: String?; let outerwear: String?; let shoes: String? }
                if let data = json.data(using: .utf8), let r = try? JSONDecoder().decode(Resp.self, from: data) {
                    func findItem(byPrefix p: String?) -> ClothingItem? {
                        guard let p, !p.isEmpty else { return nil }
                        return items.first { $0.id.uuidString.lowercased().hasPrefix(p.lowercased()) }
                    }
                    let top = findItem(byPrefix: r.top)
                    let bottom = findItem(byPrefix: r.bottom)
                    let outer = findItem(byPrefix: r.outerwear)
                    let shoes = findItem(byPrefix: r.shoes)
                    if top != nil || bottom != nil || outer != nil || shoes != nil {
                        let reason = generateExplanation(top: top?.category ?? "top", bottom: bottom?.category ?? "bottom", occasion: occasion.isEmpty ? "casual" : occasion)
                        return Outfit(top: top, bottom: bottom, outerwear: outer, shoes: shoes, reason: reason)
                    }
                }
            }
        }
        return nil
    }
}

// MARK: - ClothingClassifier STUB (only used if real model is missing)
private class ClothingClassifierStub {
    var model: MLModel {
        fatalError("ClothingClassifier stub should not be executed. Add a real .mlmodel or keep fallback path.")
    }
}

// MARK: - Preview
#Preview {
    SplashScreenView()
}
