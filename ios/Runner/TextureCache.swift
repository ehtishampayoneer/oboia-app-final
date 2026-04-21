//
//  TextureCache.swift
//  OBOIA
//
//  Two-tier (RAM + disk) cache for PBR texture maps downloaded from Firebase Storage.
//  Memory tier uses NSCache with cost tracking; disk tier trims to a 200 MB ceiling.
//

import UIKit
import CryptoKit

final class TextureCache {

    static let shared = TextureCache()

    private let memoryCache: NSCache<NSString, UIImage>
    private let diskCacheURL: URL
    private let session: URLSession
    private let diskQueue = DispatchQueue(label: "com.oboia.texturecache.disk", qos: .utility)
    private let inflightQueue = DispatchQueue(label: "com.oboia.texturecache.inflight", attributes: .concurrent)
    private var inflight: [String: [(UIImage?) -> Void]] = [:]

    private let maxDiskBytes: UInt64 = 200 * 1024 * 1024 // 200 MB

    private init() {
        memoryCache = NSCache<NSString, UIImage>()
        memoryCache.totalCostLimit = 128 * 1024 * 1024 // 128 MB in RAM

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        diskCacheURL = caches.appendingPathComponent("oboia_pbr_textures", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        cfg.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: cfg)

        // Trim asynchronously on startup
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.trimCache()
        }
    }

    // MARK: - Public API

    func loadImage(from urlString: String, completion: @escaping (UIImage?) -> Void) {
        guard !urlString.isEmpty else { completion(nil); return }

        let key = cacheKey(for: urlString)

        // 1. Memory
        if let img = memoryCache.object(forKey: key as NSString) {
            completion(img); return
        }

        // 2. Disk
        let diskURL = diskCacheURL.appendingPathComponent(key)
        diskQueue.async { [weak self] in
            guard let self = self else { completion(nil); return }
            if FileManager.default.fileExists(atPath: diskURL.path),
               let data = try? Data(contentsOf: diskURL),
               let img = UIImage(data: data) {
                let cost = data.count
                self.memoryCache.setObject(img, forKey: key as NSString, cost: cost)
                // Touch file for LRU
                try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                       ofItemAtPath: diskURL.path)
                DispatchQueue.main.async { completion(img) }
                return
            }

            // 3. Network — coalesce duplicate requests
            self.inflightQueue.async(flags: .barrier) {
                if var waiters = self.inflight[key] {
                    waiters.append(completion)
                    self.inflight[key] = waiters
                    return
                }
                self.inflight[key] = [completion]
                self.download(urlString: urlString, key: key, diskURL: diskURL)
            }
        }
    }

    func preloadTextures(urls: [String],
                        progress: @escaping (Float) -> Void,
                        completion: @escaping () -> Void) {
        let unique = Array(Set(urls.filter { !$0.isEmpty }))
        guard !unique.isEmpty else { completion(); return }

        var done = 0
        let total = unique.count
        let lock = NSLock()

        for url in unique {
            loadImage(from: url) { _ in
                lock.lock()
                done += 1
                let p = Float(done) / Float(total)
                lock.unlock()
                DispatchQueue.main.async {
                    progress(p)
                    if done == total { completion() }
                }
            }
        }
    }

    func localPath(for urlString: String) -> String? {
        let key = cacheKey(for: urlString)
        let diskURL = diskCacheURL.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: diskURL.path) ? diskURL.path : nil
    }

    func isCached(_ urlString: String) -> Bool {
        let key = cacheKey(for: urlString)
        if memoryCache.object(forKey: key as NSString) != nil { return true }
        let diskURL = diskCacheURL.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: diskURL.path)
    }

    func clearAll() {
        memoryCache.removeAllObjects()
        diskQueue.async {
            try? FileManager.default.removeItem(at: self.diskCacheURL)
            try? FileManager.default.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
        }
    }

    // MARK: - Internal

    private func download(urlString: String, key: String, diskURL: URL) {
        guard let url = URL(string: urlString) else {
            resolveInflight(key: key, image: nil)
            return
        }
        let task = session.dataTask(with: url) { [weak self] data, response, error in
            guard let self = self else { return }
            guard error == nil,
                  let data = data,
                  let img = UIImage(data: data) else {
                self.resolveInflight(key: key, image: nil)
                return
            }
            // Store on disk
            self.diskQueue.async {
                try? data.write(to: diskURL, options: .atomic)
                self.maybeTrim()
            }
            // Store in RAM
            self.memoryCache.setObject(img, forKey: key as NSString, cost: data.count)
            self.resolveInflight(key: key, image: img)
        }
        task.resume()
    }

    private func resolveInflight(key: String, image: UIImage?) {
        var waiters: [(UIImage?) -> Void] = []
        inflightQueue.sync(flags: .barrier) {
            waiters = inflight[key] ?? []
            inflight[key] = nil
        }
        DispatchQueue.main.async {
            for w in waiters { w(image) }
        }
    }

    private func cacheKey(for url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var lastTrim: Date = .distantPast
    private func maybeTrim() {
        let now = Date()
        if now.timeIntervalSince(lastTrim) < 30 { return }
        lastTrim = now
        trimCache()
    }

    func trimCache() {
        diskQueue.async {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: self.diskCacheURL,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { return }

            let entries: [(url: URL, size: UInt64, date: Date)] = files.compactMap { url in
                guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = vals.fileSize,
                      let date = vals.contentModificationDate else { return nil }
                return (url, UInt64(size), date)
            }

            let total = entries.reduce(UInt64(0)) { $0 + $1.size }
            if total <= self.maxDiskBytes { return }

            // Delete oldest first until under limit
            let sorted = entries.sorted { $0.date < $1.date }
            var running = total
            for e in sorted {
                if running <= self.maxDiskBytes { break }
                try? FileManager.default.removeItem(at: e.url)
                running -= e.size
            }
        }
    }
}
