import Foundation

/// Sanitizes peer-provided filenames for both Share and clipboard payloads.
enum FileTransferFilename {
	static func sanitize(_ name: String, fallback: String) -> String {
		var sanitized = name.precomposedStringWithCanonicalMapping
		sanitized = sanitized.replacingOccurrences(of: "..", with: "_")
		sanitized = sanitized.replacingOccurrences(of: "/", with: "_")
		sanitized = sanitized.replacingOccurrences(of: "\\", with: "_")
		sanitized = sanitized.replacingOccurrences(of: ":", with: "_")
		sanitized = sanitized.replacingOccurrences(of: "\0", with: "")
		sanitized = String(sanitized.drop(while: { $0 == "." }))
		if sanitized.isEmpty {
			return fallback
		}

		guard sanitized.utf8.count > 250 else {
			return sanitized
		}

		let ext = prefix((sanitized as NSString).pathExtension, maxBytes: 200)
		let suffix = if ext.isEmpty { "" } else { ".\(ext)" }
		let stem = prefix((sanitized as NSString).deletingPathExtension, maxBytes: 250 - suffix.utf8.count)
		return stem + suffix
	}

	private static func prefix(_ value: String, maxBytes: Int) -> String {
		var byteCount = 0
		return String(value.prefix { character in
			let size = character.utf8.count
			guard byteCount + size <= maxBytes else {
				return false
			}

			byteCount += size
			return true
		})
	}
}
