import SwiftUI
import UniformTypeIdentifiers
import AppKit

class ThumbnailQueue {
    static let shared = ThumbnailQueue()
    private let queue: OperationQueue
    
    private init() {
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 6  // Reduced from 8 to prevent memory pressure
        queue.qualityOfService = .userInitiated
        queue.name = "com.cherrypick.thumbnailqueue"
    }
    
    func addToQueue(_ block: @escaping () -> Void) {
        let operation = BlockOperation(block: block)
        operation.qualityOfService = .userInitiated
        queue.addOperation(operation)
    }
    
    func cancelAll() {
        queue.cancelAllOperations()
    }
}

class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: NSImage] = [:]
    private var accessTimes: [String: Date] = [:]
    private let maxCacheSize = 500
    private let queue = DispatchQueue(label: "com.cherrypick.thumbnailcache", qos: .userInitiated)
    
    private init() {}
    
    func set(_ image: NSImage, forKey key: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // If we're at capacity, remove the least recently accessed item
            if self.cache.count >= self.maxCacheSize {
                if let oldestKey = self.accessTimes.min(by: { $0.value < $1.value })?.key {
                    self.cache.removeValue(forKey: oldestKey)
                    self.accessTimes.removeValue(forKey: oldestKey)
                }
            }
            
            // Store the image and update access time
            self.cache[key] = image
            self.accessTimes[key] = Date()
        }
    }
    
    func get(forKey key: String) -> NSImage? {
        var result: NSImage?
        queue.sync {
            if let image = self.cache[key] {
                // Update access time when retrieving
                self.accessTimes[key] = Date()
                result = image
            }
        }
        return result
    }
    
    func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cache.removeAll()
            self.accessTimes.removeAll()
        }
    }
    
    func remove(forKey key: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.cache.removeValue(forKey: key)
            self.accessTimes.removeValue(forKey: key)
        }
    }
}

class ImageLoader: ObservableObject {
    @Published var thumbnail: NSImage?
    private let url: URL
    private let baseSize: NSSize
    private var isLoading = false
    private var loadTask: Operation?
    private var isCancelled = false
    
    init(url: URL, baseSize: NSSize) {
        self.url = url
        self.baseSize = baseSize
        
        if let cached = ThumbnailCache.shared.get(forKey: url.path) {
            self.thumbnail = cached
        }
    }
    
    func load() {
        guard !isLoading, thumbnail == nil, !isCancelled else { return }
        isLoading = true
        
        loadTask?.cancel()
        
        let operation = BlockOperation { [weak self] in
            guard let self = self, !self.isCancelled else { return }
            
            autoreleasepool {
                if let imageSource = CGImageSourceCreateWithURL(self.url as CFURL, nil) {
                    let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
                    let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
                    let width = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? self.baseSize.width
                    let height = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? self.baseSize.height
                    
                    let imageAspectRatio = width / height
                    let containerAspectRatio = self.baseSize.width / self.baseSize.height
                    let thumbnailSize: NSSize
                    
                    // Calculate size based on original image dimensions
                    if imageAspectRatio > containerAspectRatio {
                        thumbnailSize = NSSize(
                            width: self.baseSize.width,
                            height: self.baseSize.width / imageAspectRatio
                        )
                    } else {
                        thumbnailSize = NSSize(
                            width: self.baseSize.height * imageAspectRatio,
                            height: self.baseSize.height
                        )
                    }
                    
                    let options: [CFString: Any] = [
                        kCGImageSourceThumbnailMaxPixelSize: max(thumbnailSize.width, thumbnailSize.height),
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceShouldCache: true,
                        kCGImageSourceShouldAllowFloat: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImagePropertyOrientation: orientation
                    ]
                    
                    if let thumbnailRef = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        let thumbnail = NSImage(cgImage: thumbnailRef, size: thumbnailSize)
                        thumbnail.cacheMode = .always
                        
                        if !self.isCancelled {
                            ThumbnailCache.shared.set(thumbnail, forKey: self.url.path)
                            
                            DispatchQueue.main.async { [weak self] in
                                guard let self = self, !self.isCancelled else { return }
                                self.thumbnail = thumbnail
                                self.isLoading = false
                            }
                        }
                    }
                }
            }
        }
        
        operation.qualityOfService = .userInitiated
        loadTask = operation
        ThumbnailQueue.shared.addToQueue {
            operation.start()
        }
    }
    
    func cancel() {
        isCancelled = true
        loadTask?.cancel()
        isLoading = false
    }
    
    deinit {
        cancel()
    }
}

struct AsyncImageItem: Identifiable {
    let id: UUID
    let url: URL
    let metadata: [String: Any]
    let creationDate: Date
    
    init(url: URL, metadata: [String: Any], creationDate: Date) {
        self.id = UUID()
        self.url = url
        self.metadata = metadata
        self.creationDate = creationDate
    }
}

struct ImageGridView: View {
    let folderPath: String
    @State private var selectedImages: Set<UUID> = []
    @State private var isLoading = false
    @State private var asyncImages: [AsyncImageItem] = []
    @State private var visibleRange: Range<Int>?
    @State private var scrollPosition: CGFloat = 0
    @State private var currentPage = 0
    private let pageSize = 20
    
    // Constants for thumbnail sizing and pagination
    private let baseWidth: CGFloat = 520
    private let baseHeight: CGFloat = 400
    private let gridColumns = [
        GridItem(.adaptive(minimum: 390, maximum: 520), spacing: 12)
    ]
    
    var body: some View {
        VStack(spacing: 0) {
            if isLoading && asyncImages.isEmpty {
                ProgressView("Loading images...")
            } else {
                ScrollView {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ScrollOffsetPreferenceKey.self,
                            value: geometry.frame(in: .named("scroll")).minY)
                    }
                    .frame(height: 0)
                    
                    LazyVGrid(columns: gridColumns, spacing: 12) {
                        ForEach(asyncImages) { imageItem in
                            AsyncThumbnailView(
                                url: imageItem.url,
                                baseSize: NSSize(width: baseWidth, height: baseHeight),
                                isSelected: selectedImages.contains(imageItem.id)
                            )
                            .onTapGesture {
                                if selectedImages.contains(imageItem.id) {
                                    selectedImages.remove(imageItem.id)
                                } else {
                                    selectedImages.insert(imageItem.id)
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    scrollPosition = value
                    checkAndLoadMore()
                }
            }
            
            if !selectedImages.isEmpty {
                HStack {
                    Button("Delete Selected") {
                        deleteSelectedImages()
                    }
                    .foregroundColor(.red)
                    
                    Spacer()
                    
                    Text("\(selectedImages.count) selected")
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
        .onAppear {
            loadImages()
        }
        .onChange(of: folderPath) { oldValue, newValue in
            ThumbnailCache.shared.clear()
            selectedImages.removeAll()
            loadImages()
        }
    }
    
    private func checkAndLoadMore() {
        let threshold: CGFloat = 1000
        let contentHeight = CGFloat(asyncImages.count) * (baseHeight + 12)
        let visibleHeight = NSScreen.main?.frame.height ?? 800
        let scrollThreshold = contentHeight - visibleHeight - threshold
        
        if scrollPosition < scrollThreshold && !isLoading {
            loadMoreImages()
        }
    }
    
    private func loadMoreImages() {
        isLoading = true
        let startIndex = currentPage * pageSize
        let endIndex = min(startIndex + pageSize, asyncImages.count)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Currently not loading more items, just updating the page
            DispatchQueue.main.async {
                self.currentPage += 1
                self.isLoading = false
            }
        }
    }
    
    private func loadImages() {
        isLoading = true
        asyncImages.removeAll()
        currentPage = 0
        
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let url = URL(fileURLWithPath: self.folderPath)
            
            do {
                let contents = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.typeIdentifierKey, .creationDateKey])
                let imageURLs = contents.filter { url in
                    do {
                        if let typeIdentifier = try url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier {
                            return UTType(typeIdentifier)?.conforms(to: .image) ?? false
                        }
                    } catch {
                        print("Error getting type identifier: \(error)")
                    }
                    return false
                }
                
                var itemsWithDate: [AsyncImageItem] = []
                var itemsWithoutDate: [AsyncImageItem] = []
                
                for url in imageURLs {
                    do {
                        if let creationDate = try url.resourceValues(forKeys: [.creationDateKey]).creationDate {
                            itemsWithDate.append(AsyncImageItem(url: url, metadata: [:], creationDate: creationDate))
                        } else {
                            itemsWithoutDate.append(AsyncImageItem(url: url, metadata: [:], creationDate: Date.distantPast))
                        }
                    } catch {
                        itemsWithoutDate.append(AsyncImageItem(url: url, metadata: [:], creationDate: Date.distantPast))
                    }
                }
                
                let sortedItemsWithDate = itemsWithDate.sorted { $0.creationDate < $1.creationDate }
                let allItems = sortedItemsWithDate + itemsWithoutDate
                
                DispatchQueue.main.async {
                    self.asyncImages = allItems
                    self.isLoading = false
                }
            } catch {
                print("Error loading images: \(error)")
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func deleteSelectedImages() {
        let imagesToDelete = asyncImages.filter { selectedImages.contains($0.id) }
        
        for image in imagesToDelete {
            let fileManager = FileManager.default
            let absoluteURL = image.url.absoluteURL
            
            print("Attempting to delete: \(absoluteURL.path)")
            
            // Ensure the file exists
            guard fileManager.fileExists(atPath: absoluteURL.path) else {
                print("File does not exist at path: \(absoluteURL.path)")
                continue
            }
            
            do {
                var resultingItemURL: NSURL?
                try fileManager.trashItem(at: absoluteURL, resultingItemURL: &resultingItemURL)
                print("Successfully moved to trash: \(absoluteURL.path)")
                
                // Remove from cache
                ThumbnailCache.shared.clear()
                
                // Remove from array
                if let index = asyncImages.firstIndex(where: { $0.id == image.id }) {
                    asyncImages.remove(at: index)
                }
            } catch {
                print("Failed to move file to trash: \(error.localizedDescription)")
                
                // Fallback to NSWorkspace
                NSWorkspace.shared.recycle([absoluteURL])
                print("Successfully moved to trash using NSWorkspace fallback")
                
                // Remove from cache
                ThumbnailCache.shared.clear()
                
                // Remove from array
                if let index = asyncImages.firstIndex(where: { $0.id == image.id }) {
                    asyncImages.remove(at: index)
                }
            }
        }
        
        selectedImages.removeAll()
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AsyncThumbnailView: View {
    let url: URL
    let baseSize: NSSize
    let isSelected: Bool
    @StateObject private var imageLoader: ImageLoader
    
    init(url: URL, baseSize: NSSize, isSelected: Bool) {
        self.url = url
        self.baseSize = baseSize
        self.isSelected = isSelected
        _imageLoader = StateObject(wrappedValue: ImageLoader(url: url, baseSize: baseSize))
    }
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let thumbnail = imageLoader.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .background(Color.gray.opacity(0.1))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(baseSize.width / baseSize.height, contentMode: .fit)
                    .overlay(
                        VStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    )
            }
            
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.blue)
                    .background(Circle().fill(Color.white))
                    .padding(8)
            }
        }
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
        )
        .onAppear {
            imageLoader.load()
        }
        .onDisappear {
            imageLoader.cancel()
        }
    }
}

extension NSImage {
    func thumbnail(size: NSSize) -> NSImage {
        let thumbnailSize = size
        let newImage = NSImage(size: thumbnailSize)
        
        newImage.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: thumbnailSize),
             from: NSRect(origin: .zero, size: self.size),
             operation: .copy,
             fraction: 1.0)
        newImage.unlockFocus()
        
        return newImage
    }
    
    func flipHorizontal() {
        let flippedImage = NSImage(size: size)
        flippedImage.lockFocus()
        let transform = NSAffineTransform()
        transform.scaleX(by: -1, yBy: 1)
        transform.translateX(by: -size.width, yBy: 0)
        transform.concat()
        draw(in: NSRect(origin: .zero, size: size))
        flippedImage.unlockFocus()
        self.lockFocus()
        flippedImage.draw(in: NSRect(origin: .zero, size: size))
        self.unlockFocus()
    }
    
    func flipVertical() {
        let flippedImage = NSImage(size: size)
        flippedImage.lockFocus()
        let transform = NSAffineTransform()
        transform.scaleX(by: 1, yBy: -1)
        transform.translateX(by: 0, yBy: -size.height)
        transform.concat()
        draw(in: NSRect(origin: .zero, size: size))
        flippedImage.unlockFocus()
        self.lockFocus()
        flippedImage.draw(in: NSRect(origin: .zero, size: size))
        self.unlockFocus()
    }
    
    func rotate(_ degrees: CGFloat) {
        let rotatedImage = NSImage(size: size)
        rotatedImage.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width/2, yBy: size.height/2)
        transform.rotate(byDegrees: degrees)
        transform.translateX(by: -size.width/2, yBy: -size.height/2)
        transform.concat()
        draw(in: NSRect(origin: .zero, size: size))
        rotatedImage.unlockFocus()
        self.lockFocus()
        rotatedImage.draw(in: NSRect(origin: .zero, size: size))
        self.unlockFocus()
    }
} 
