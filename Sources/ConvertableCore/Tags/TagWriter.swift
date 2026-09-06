import Foundation
import CTagLib

/// Writes a normalised tag set plus one cover picture onto an output file (MP4, MP3, FLAC, WAV, AIFF, Ogg).
///
/// TagLib's property map does the container mapping (TITLE → ©nam / TIT2 / TITLE, MUSICBRAINZ_ALBUMID →
/// the Picard freeform atom, …). Encoder-written loudness/gapless atoms (`iTunSMPB`, `iTunNORM`) are
/// never touched.
public enum TagWriter {
    public enum Failure: Error, CustomStringConvertible {
        case unreadable(String), saveFailed(String)
        public var description: String {
            switch self {
            case let .unreadable(p): return "TagLib could not open \(p) for writing"
            case let .saveFailed(p): return "TagLib could not save \(p)"
            }
        }
    }

    /// Keys that belong to the encoder, not the source. Kept whatever the source said.
    static func isProtected(_ key: String) -> Bool {
        let k = key.uppercased()
        return k.hasPrefix("ITUNSMPB") || k.hasPrefix("ITUNNORM") || k.contains(":ITUNSMPB") || k.contains(":ITUNNORM")
    }

    public static func write(path: String, properties: [String: [String]], picture: Data?, encoderStamp: String?) throws {
        taglib_set_string_management_enabled(0)
        // ID3v2 text as UTF-16 keeps older MP3 players (iPod included) happy with non-ASCII tags.
        taglib_id3v2_set_default_text_encoding(TagLib_ID3v2_UTF16)
        guard let file = taglib_file_new(path), taglib_file_is_valid(file) != 0 else { throw Failure.unreadable(path) }
        defer { taglib_file_free(file) }

        // Remove everything we are not about to set, except the encoder's own atoms.
        if let keys = taglib_property_keys(file) {
            var i = 0
            while let k = keys[i] {
                let key = String(cString: k)
                if properties[key] == nil, !isProtected(key), key.uppercased() != "ENCODEDBY" || encoderStamp == nil {
                    taglib_property_set(file, k, nil)
                }
                i += 1
            }
            taglib_property_free(keys)
        }
        for (key, values) in properties.sorted(by: { $0.key < $1.key }) where !isProtected(key) {
            guard let first = values.first else { taglib_property_set(file, key, nil); continue }
            taglib_property_set(file, key, first)
            for v in values.dropFirst() { taglib_property_set_append(file, key, v) }
        }
        if let stamp = encoderStamp { taglib_property_set(file, "ENCODEDBY", stamp) }

        if let picture {
            try setPicture(file, picture)
        } else {
            _ = taglib_complex_property_set(file, "PICTURE", nil)
        }

        guard taglib_file_save(file) != 0 else { throw Failure.saveFailed(path) }
    }

    /// Builds the NULL-terminated attribute list TagLib expects for one front-cover picture.
    private static func setPicture(_ file: UnsafeMutablePointer<TagLib_File>, _ data: Data) throws {
        let mime = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
        // Attribute storage: 4 attributes + terminator, all C-allocated and freed below.
        let count = 4
        let attrs = UnsafeMutablePointer<TagLib_Complex_Property_Attribute>.allocate(capacity: count)
        let bytes = UnsafeMutablePointer<CChar>.allocate(capacity: data.count)
        data.withUnsafeBytes { raw in _ = memcpy(bytes, raw.baseAddress!, data.count) }
        let keys: [UnsafeMutablePointer<CChar>] = ["data", "mimeType", "description", "pictureType"].map { (s: String) in strdup(s)! }
        let strs: [UnsafeMutablePointer<CChar>] = [mime, "Cover", "Front Cover"].map { (s: String) in strdup(s)! }
        defer {
            attrs.deallocate(); bytes.deallocate()
            keys.forEach { free($0) }; strs.forEach { free($0) }
        }
        var v0 = TagLib_Variant(); v0.type = TagLib_Variant_ByteVector; v0.size = UInt32(data.count); v0.value.byteVectorValue = bytes
        var v1 = TagLib_Variant(); v1.type = TagLib_Variant_String; v1.value.stringValue = strs[0]
        var v2 = TagLib_Variant(); v2.type = TagLib_Variant_String; v2.value.stringValue = strs[1]
        var v3 = TagLib_Variant(); v3.type = TagLib_Variant_String; v3.value.stringValue = strs[2]
        attrs[0] = TagLib_Complex_Property_Attribute(key: keys[0], value: v0)
        attrs[1] = TagLib_Complex_Property_Attribute(key: keys[1], value: v1)
        attrs[2] = TagLib_Complex_Property_Attribute(key: keys[2], value: v2)
        attrs[3] = TagLib_Complex_Property_Attribute(key: keys[3], value: v3)

        let list = UnsafeMutablePointer<UnsafePointer<TagLib_Complex_Property_Attribute>?>.allocate(capacity: count + 1)
        defer { list.deallocate() }
        for i in 0..<count { list[i] = UnsafePointer(attrs + i) }
        list[count] = nil
        guard taglib_complex_property_set(file, "PICTURE", list) != 0 else { throw Failure.saveFailed("picture") }
    }
}
