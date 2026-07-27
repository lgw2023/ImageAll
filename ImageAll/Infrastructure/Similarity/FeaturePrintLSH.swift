import CryptoKit
import Foundation

/// Deterministic Feature Print LSH: random hyperplane sign buckets + Hamming-radius neighbor
/// expansion. Hyperplanes are reproducible from a seed string alone (no persisted RNG state),
/// so a build job resumed later or replayed in tests reproduces identical bucket keys.
enum FeaturePrintLSH {
    /// Generates `bitCount` hyperplanes of `dimension` length, stable across runs/processes.
    static func generatePlanes(seed: String, bitCount: Int, dimension: Int) -> [[Float]] {
        guard bitCount > 0, dimension > 0 else { return [] }
        var rng = SeededPRNG(seed: seed)
        var planes: [[Float]] = []
        planes.reserveCapacity(bitCount)
        for _ in 0..<bitCount {
            var plane = [Float]()
            plane.reserveCapacity(dimension)
            for _ in 0..<dimension {
                plane.append(rng.nextSignedUnitFloat())
            }
            planes.append(plane)
        }
        return planes
    }

    /// Sign-of-dot-product bucket key. Planes whose dimension does not match `vector` are
    /// skipped defensively (should not happen once a source's planes are fixed).
    static func bucketKey(vector: [Float], planes: [[Float]]) -> UInt64 {
        var key: UInt64 = 0
        for (index, plane) in planes.enumerated() where index < 64 {
            guard plane.count == vector.count else { continue }
            var dot = 0.0
            for i in 0..<vector.count {
                dot += Double(vector[i]) * Double(plane[i])
            }
            if dot >= 0 {
                key |= (1 << UInt64(index))
            }
        }
        return key
    }

    /// All keys within Hamming distance `maxHamming` of `key` (inclusive of `key` itself).
    static func neighborKeys(key: UInt64, bitCount: Int, maxHamming: Int = 1) -> [UInt64] {
        let clampedBitCount = max(0, min(bitCount, 64))
        let clampedHamming = max(0, min(maxHamming, clampedBitCount))
        var results: Set<UInt64> = [key]
        guard clampedHamming >= 1, clampedBitCount > 0 else {
            return Array(results).sorted()
        }

        func flipCombinations(start: Int, remaining: Int, chosen: [Int]) {
            if remaining == 0 {
                var flipped = key
                for bit in chosen {
                    flipped ^= (UInt64(1) << UInt64(bit))
                }
                results.insert(flipped)
                return
            }
            guard start < clampedBitCount else { return }
            for bit in start..<clampedBitCount {
                flipCombinations(start: bit + 1, remaining: remaining - 1, chosen: chosen + [bit])
            }
        }

        for distance in 1...clampedHamming {
            flipCombinations(start: 0, remaining: distance, chosen: [])
        }
        return Array(results).sorted()
    }

    /// SplitMix64-based PRNG seeded from a SHA-256 digest of a caller-supplied string, so the
    /// same seed always reproduces the same sequence regardless of process or platform.
    struct SeededPRNG {
        private var state: UInt64

        init(seed: String) {
            let digest = SHA256.hash(data: Data(seed.utf8))
            var value: UInt64 = 0
            for byte in digest.prefix(8) {
                value = (value << 8) | UInt64(byte)
            }
            state = value == 0 ? 0x9E3779B97F4A7C15 : value
        }

        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }

        /// Uniform float in `[-1, 1]`.
        mutating func nextSignedUnitFloat() -> Float {
            let value = nextUInt64()
            let fraction = Double(value >> 11) * (1.0 / 9_007_199_254_740_992.0) // 2^53
            return Float(fraction * 2.0 - 1.0)
        }
    }
}
