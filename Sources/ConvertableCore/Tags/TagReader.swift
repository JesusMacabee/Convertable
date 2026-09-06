import Foundation
import CTagLib

/// Tags and stream properties read via TagLib. Works for FLAC, ALAC/MP4, WAV, AIFF, MP3, Ogg.
public struct AudioFileInfo: Equatable, Sendable {
    public var properties: [String: [String]]   // TagLib's normalized property map (TITLE, ARTIST, MUSICBRAINZ_ALBUMID, …)
    public var sampleRate: Int
    public var channels: Int
    public var bitrateKbps: Int
    public var lengthMs: Int
    public var pictures: [Picture]

    public struct Picture: Equatable, Sendable {
        public var mimeType: String
        public var description: String
        public var pictureType: String   // "Front Cover", …
        public var data: Data
    }

    public func first(_ key: String) -> String? { properties[key]?.first }
    public var title: String? { first("TITLE") }
    public var artist: String? { first("ARTIST") }
    public var albumArtist: String? { first("ALBUMARTIST") }
    public var album: String? { first("ALBUM") }
}

public enum TagReader {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        public var description: String {
            switch self { case let .unreadable(p): return "TagLib could not read \(p)" }
        }
    }

    public static func read(_ path: String) throws -> AudioFileInfo {
        // Manage string lifetimes ourselves: copy into Swift immediately, then free.
        taglib_set_string_management_enabled(0)
        guard let file = taglib_file_new(path), taglib_file_is_valid(file) != 0 else {
            throw Failure.unreadable(path)
        }
        defer { taglib_file_free(file) }

        var props: [String: [String]] = [:]
        if let keys = taglib_property_keys(file) {
            var i = 0
            while let k = keys[i] {
                let key = String(cString: k)
                if let vals = taglib_property_get(file, k) {
                    var j = 0
                    var list: [String] = []
                    while let v = vals[j] { list.append(String(cString: v)); j += 1 }
                    props[key] = list
                    taglib_property_free(vals)
                }
                i += 1
            }
            taglib_property_free(keys)
        }

        var sr = 0, ch = 0, br = 0, ms = 0
        if let ap = taglib_file_audioproperties(file) {
            sr = Int(taglib_audioproperties_samplerate(ap))
            ch = Int(taglib_audioproperties_channels(ap))
            br = Int(taglib_audioproperties_bitrate(ap))
            ms = Int(taglib_audioproperties_length(ap)) * 1000
        }

        // TagLib's helper extracts the first picture (front cover by convention). Multiple-picture
        // traversal isn't needed: we embed exactly one downscaled cover.
        var pictures: [AudioFileInfo.Picture] = []
        if let complex = taglib_complex_property_get(file, "PICTURE") {
            var pic = TagLib_Complex_Property_Picture_Data()
            taglib_picture_from_complex_property(complex, &pic)
            if let data = pic.data, pic.size > 0 {
                pictures.append(.init(
                    mimeType: pic.mimeType.map { String(cString: $0) } ?? "",
                    description: pic.description.map { String(cString: $0) } ?? "",
                    pictureType: pic.pictureType.map { String(cString: $0) } ?? "",
                    data: Data(bytes: data, count: Int(pic.size))))
            }
            taglib_complex_property_free(complex)
        }

        return AudioFileInfo(properties: props, sampleRate: sr, channels: ch, bitrateKbps: br, lengthMs: ms, pictures: pictures)
    }
}
