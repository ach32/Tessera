import Foundation

/// A named group of extensions with a colour, for the "file classes" style and `:class:` filters.
public struct FileClass: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Extensions without dots, separated by ";" when edited as text.
    public var extensions: [String]
    /// "#RRGGBB"
    public var color: String

    public init(id: UUID = UUID(), name: String, extensions: [String], color: String) {
        self.id = id
        self.name = name
        self.extensions = extensions.map { $0.lowercased() }
        self.color = color
    }

    public init(name: String, _ list: String, color: String) {
        self.init(name: name, extensions: FileClass.parseExtensions(list), color: color)
    }

    public var extensionsText: String { extensions.joined(separator: ";") }

    /// Accepts "jpg;png", "*.jpg; *.png", ".jpg,.png".
    public static func parseExtensions(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " })
            .map { s -> String in
                var e = s.trimmingCharacters(in: .whitespaces).lowercased()
                if e.hasPrefix("*") { e.removeFirst() }
                if e.hasPrefix(".") { e.removeFirst() }
                return e
            }
            .filter { !$0.isEmpty }
    }

    public static let defaults: [FileClass] = [
        FileClass(name: "Images", "jpg;jpeg;png;gif;heic;heif;webp;tif;tiff;bmp;raw;cr2;cr3;nef;arw;dng;psd;svg;ico;icns", color: "#E2B04A"),
        FileClass(name: "Video", "mov;mp4;m4v;avi;mkv;wmv;mpg;mpeg;webm;3gp;mts;m2ts;prores", color: "#D9644A"),
        FileClass(name: "Audio", "mp3;m4a;aac;wav;aif;aiff;flac;ogg;opus;wma;alac;caf;mid;midi", color: "#B565C9"),
        FileClass(name: "Archives", "zip;rar;7z;tar;gz;tgz;bz2;xz;zst;lz4;cab;sit;sitx", color: "#5FA8A0"),
        FileClass(name: "Disk images & installers", "dmg;iso;img;sparseimage;sparsebundle;pkg;mpkg;vmdk;vdi;qcow2;ipsw;xip", color: "#8C7AE6"),
        FileClass(name: "Documents", "pdf;doc;docx;xls;xlsx;ppt;pptx;pages;numbers;key;txt;rtf;md;odt;ods;odp;epub;csv", color: "#6FB0E0"),
        FileClass(name: "Code & data", "swift;c;h;m;mm;cpp;hpp;js;ts;tsx;py;rb;go;rs;java;kt;json;xml;yml;yaml;sql;sqlite;db;html;css", color: "#7DC383"),
        FileClass(name: "Logs & caches", "log;cache;tmp;temp;dSYM;crash;ips;diag", color: "#9AA3AD"),
    ]
}

/// Base colours for the flat style, "#RRGGBB".
public struct FlatColors: Codable, Equatable {
    public var volume = "#2E3440"
    public var folder = "#3F5F8A"
    public var file = "#B9D3EE"
    public var free = "#7CC6A0"
    public var unknown = "#A3A8B0"
    public init() {}
}
