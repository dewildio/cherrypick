import Foundation
import AppKit

struct ImageItem: Identifiable {
    let id = UUID()
    let url: URL
    let thumbnail: NSImage?
    let metadata: [String: Any]
} 