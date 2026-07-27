import Foundation

enum SimilarityVectorMath {
    static func l2Distance(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var sum = 0.0
        for index in a.indices {
            let delta = Double(a[index] - b[index])
            sum += delta * delta
        }
        return sqrt(sum)
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for index in a.indices {
            let left = Double(a[index])
            let right = Double(b[index])
            guard left.isFinite, right.isFinite else { return nil }
            dot += left * right
            normA += left * left
            normB += right * right
        }
        guard normA > 0, normB > 0 else { return nil }
        return dot / (sqrt(normA) * sqrt(normB))
    }
}
