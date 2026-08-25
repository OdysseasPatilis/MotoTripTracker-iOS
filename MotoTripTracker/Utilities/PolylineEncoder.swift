import Foundation

/// Google Encoded Polyline Algorithm Format.
enum PolylineEncoder {
    static func encode(_ coordinates: [(lat: Double, lng: Double)]) -> String {
        var lastLat = 0
        var lastLng = 0
        var result = ""

        for coordinate in coordinates {
            let lat = Int(round(coordinate.lat * 1e5))
            let lng = Int(round(coordinate.lng * 1e5))
            result += encodeValue(lat - lastLat)
            result += encodeValue(lng - lastLng)
            lastLat = lat
            lastLng = lng
        }
        return result
    }

    static func decode(_ encoded: String) -> [(lat: Double, lng: Double)] {
        var coordinates: [(lat: Double, lng: Double)] = []
        var index = encoded.startIndex
        var lat = 0
        var lng = 0

        while index < encoded.endIndex {
            let (dLat, nextLat) = decodeValue(encoded, from: index)
            index = nextLat
            lat += dLat
            let (dLng, nextLng) = decodeValue(encoded, from: index)
            index = nextLng
            lng += dLng
            coordinates.append((Double(lat) / 1e5, Double(lng) / 1e5))
        }
        return coordinates
    }

    private static func encodeValue(_ value: Int) -> String {
        var num = value < 0 ? ~(value << 1) : (value << 1)
        var output = ""
        while num >= 0x20 {
            let next = (0x20 | (num & 0x1f)) + 63
            output.append(Character(UnicodeScalar(next)!))
            num >>= 5
        }
        output.append(Character(UnicodeScalar(num + 63)!))
        return output
    }

    private static func decodeValue(_ encoded: String, from start: String.Index) -> (Int, String.Index) {
        var result = 0
        var shift = 0
        var index = start
        var byte: Int

        repeat {
            byte = Int(encoded[index].asciiValue!) - 63
            index = encoded.index(after: index)
            result |= (byte & 0x1f) << shift
            shift += 5
        } while byte >= 0x20

        let delta = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        return (delta, index)
    }
}
