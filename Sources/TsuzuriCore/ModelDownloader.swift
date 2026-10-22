import CryptoKit
import Foundation

/// One file of a model repo, pinned by content: LFS files by SHA-256, small files by their git blob SHA-1.
public struct ModelFile: Sendable {
    public var path: String
    public var size: Int64
    public var sha256: String?
    public var gitSHA1: String?
}

/// A Hugging Face repo pinned to a revision, with the exact files Tsuzuri needs.
/// Pinning keeps downloads verifiable and stops an upstream change from breaking the app.
public struct ModelPackage: Sendable {
    public var repo: String
    public var revision: String
    public var directoryName: String
    public var files: [ModelFile]
    /// Set when the download is converted after verification (the polish model is quantized
    /// on the Mac): the model directory the conversion produces.
    public var convertedName: String? = nil

    public var size: Int64 { files.reduce(0) { $0 + $1.size } }
    public var localDirectory: URL { ModelStore.root.appendingPathComponent(convertedName ?? directoryName) }

    /// Every file is there (README aside), so a copy missing its tokenizer files counts as not
    /// downloaded and the app offers the download. Sizes aren't compared: a copy downloaded by
    /// hand may come from a newer revision of the repo.
    public var isInstalled: Bool {
        if convertedName != nil { return ModelStore.isInstalled(localDirectory) }
        let fm = FileManager.default
        return ModelStore.isInstalled(localDirectory) && files.allSatisfy {
            $0.path == "README.md" || fm.fileExists(atPath: localDirectory.appendingPathComponent($0.path).path)
        }
    }
}

extension ModelPackage {
    /// The text files are identical across the Qwen3-ASR conversions except config.json,
    /// README.md and the weight index.
    private static func qwen(_ name: String, revision: String, config: (Int64, String), readme: String,
                             weights: (Int64, String), index: (Int64, String)) -> ModelPackage {
        ModelPackage(repo: "mlx-community/\(name)", revision: revision, directoryName: name, files: [
            ModelFile(path: "README.md", size: 1008, gitSHA1: readme),
            ModelFile(path: "chat_template.json", size: 1161, gitSHA1: "c44736493efd71ec96218cc626904698cdb13235"),
            ModelFile(path: "config.json", size: config.0, gitSHA1: config.1),
            ModelFile(path: "generation_config.json", size: 142, gitSHA1: "7382a4d347c0a865b76bb1b8277f66a5ac312854"),
            ModelFile(path: "merges.txt", size: 1_671_853, gitSHA1: "31349551d90c7606f325fe0f11bbb8bd5fa0d7c7"),
            ModelFile(path: "model.safetensors.index.json", size: index.0, gitSHA1: index.1),
            ModelFile(path: "preprocessor_config.json", size: 330, gitSHA1: "8f7f07346466d5d494ec0d4969d1c3d0190eed72"),
            ModelFile(path: "tokenizer_config.json", size: 12487, gitSHA1: "b93109843922a40c6654c5449d3bf95372267c66"),
            ModelFile(path: "vocab.json", size: 2_776_833, gitSHA1: "4783fe10ac3adce15ac8f358ef5462739852c569"),
            // Last, so a model directory never has weights without its config.
            ModelFile(path: "model.safetensors", size: weights.0, sha256: weights.1),
        ])
    }

    public static let vad = ModelPackage(
        repo: "mlx-community/silero-vad", revision: "7bc17f22d3c0451bd3a6cd71e759b009271ff49a",
        directoryName: "silero-vad", files: [
            ModelFile(path: "README.md", size: 602, gitSHA1: "2bfe53f1800809fddf9fc2b73eb0ae5f83d15e1d"),
            ModelFile(path: "config.json", size: 549, gitSHA1: "af83a8c743562a75af3edad522a6c94d1f885115"),
            ModelFile(path: "model.safetensors", size: 2_179_454,
                      sha256: "185e0bc3ee2c48ce425a37209fe917a1aca22ab6b85799430dd1b4894087a8b8"),
        ])

    /// spokenly/cleanup-1 as published (bfloat16, Apache-2.0); converted to 4-bit MLX after download.
    public static let polish = ModelPackage(
        repo: PolishModel.sourceRepo, revision: "a83ba762e3c4ab6a3a20814ec68050f381d92cf8",
        directoryName: "cleanup-1", files: [
            ModelFile(path: "LICENSE", size: 11358, gitSHA1: "d645695673349e3947e8e5ae42332d0ac3164cd7"),
            ModelFile(path: "NOTICE", size: 504, gitSHA1: "255f586d5f5adf9cab3a516971dc53f9e5473cc7"),
            ModelFile(path: "README.md", size: 7574, gitSHA1: "932844f5b2275688fd932c01e605b745c41e1f08"),
            ModelFile(path: "chat_template.jinja", size: 186, gitSHA1: "02c9544137743178f8120e078ea0e1e18f9fa2eb"),
            ModelFile(path: "config.json", size: 784, gitSHA1: "fb30c6ce97414c181e345e9da55a99199876edb6"),
            ModelFile(path: "generation_config.json", size: 138, gitSHA1: "cbbb3133034e192527e5321b4c679154e4819ab8"),
            ModelFile(path: "tokenizer_config.json", size: 696, gitSHA1: "1127e125def6d7caf411d32f791f9d3d20ccd991"),
            ModelFile(path: "tokenizer.json", size: 11_422_650,
                      sha256: "be75606093db2094d7cd20f3c2f385c212750648bd6ea4fb2bf507a6a4c55506"),
            ModelFile(path: "model.safetensors", size: 1_192_134_935,
                      sha256: "dcf73ee83277b6dc4a40e8d9630f4e725f2499ed009be4ae0dd8b35d3ae38400"),
        ], convertedName: PolishModel.directoryName)

    public static func asr(_ model: ASRModel) -> ModelPackage {
        switch model {
        case .qwen3_1_7b_4bit:
            qwen(model.rawValue, revision: "78a389c776a5483b2d0d4ea5494e11012e0d6159",
                 config: (7188, "4299bbdf5835cd26e6e22ba4e731e83ac073d192"),
                 readme: "35a62ed247943efda5dc23b8a5552bd0695d6da1",
                 weights: (1_603_081_617, "9848eaf7a5c1589c671b35035ac27b72e248dd0c604eacae547e7e403d29db45"),
                 index: (78968, "b3d7c7b45a07ba7fdb4565b464ac3b3a55ad36f7"))
        case .qwen3_1_7b_8bit:
            qwen(model.rawValue, revision: "a8379a2e2f9e313c9292cdf1af4055ab56d50d55",
                 config: (7188, "888cc7fae19ea9ede543b1ae82e9c78aa06104ca"),
                 readme: "b835cd3f6d4f5a2dd6b7f3ad83138166bdf5f1b5",
                 weights: (2_463_307_541, "bf304b009cc7eca79283056f787b44c952d24ac22cec787b39732bba3c23c13c"),
                 index: (78968, "f0191caac2794d5b6fba0ab3eeb70f8eff90319e"))
        case .qwen3_0_6b_8bit:
            qwen(model.rawValue, revision: "89e96d92ba34aca20b3e29fb10cc284097d1219f",
                 config: (7187, "845f0d3848c5240a7eee9e1676cbe241c1b92585"),
                 readme: "92490384a935261232f63611e2e948d63518fc6f",
                 weights: (1_006_229_426, "b5bfe4abc1b4c6e58b633096682ec2b6297298add1527119936107d211adf0e8"),
                 index: (71815, "19ddb6277777ec48662d9942f1191d8795308bfd"))
        case .qwen3_0_6b_4bit:
            qwen(model.rawValue, revision: "313d850181767edf09f00a9c289becca70e58cd0",
                 config: (7187, "049989ad1e19719b99c2f374eb7067040aa4c830"),
                 readme: "ab0d6d2e72d8587f2f599536e8b7463bba412a61",
                 weights: (708_236_945, "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf"),
                 index: (71814, "b507ef4ee5b57e6147c4bda5d9db05992477030d"))
        }
    }
}

extension ASRModel {
    public var package: ModelPackage { .asr(self) }

    /// What downloading this model fetches: the model, plus the silence detector if it is missing.
    public var downloadPackages: [ModelPackage] {
        ModelPackage.vad.isInstalled ? [package] : [.vad, package]
    }

    public var downloadSize: Int64 { downloadPackages.reduce(0) { $0 + $1.size } }
}

public enum DownloadError: Error, CustomStringConvertible, Equatable {
    case offline
    case network(String)
    case server(Int, String)
    case diskFull(needed: Int64, available: Int64)
    case corrupt(String)
    case cancelled

    public var description: String {
        switch self {
        case .offline: "not connected to the internet"
        case .network(let message): "network error: \(message)"
        case .server(let status, let file): "HTTP \(status) for \(file)"
        case .diskFull(let needed, let available): "not enough disk space: need \(needed) bytes, \(available) available"
        case .corrupt(let file): "checksum mismatch for \(file)"
        case .cancelled: "cancelled"
        }
    }
}

/// Downloads model repos from Hugging Face with plain URLSession. Files go to a staging
/// directory (`Models/.downloads/<name>`) and are resumed from there after a cancel, a
/// lost connection or a quit; a model directory only appears, by one rename, once every
/// file has been verified. This is the only thing in Tsuzuri that uses the network.
public final class ModelDownloader: @unchecked Sendable {
    /// `HF_ENDPOINT` (as in huggingface_hub), or `defaults write com.kanaworks.tsuzuri hfEndpoint …`,
    /// points downloads at a mirror.
    public static var endpoint: URL {
        let configured = ProcessInfo.processInfo.environment["HF_ENDPOINT"]
            ?? UserDefaults.standard.string(forKey: "hfEndpoint")
        if let configured, let url = URL(string: configured), url.scheme?.hasPrefix("http") == true { return url }
        return URL(string: "https://huggingface.co")!
    }

    public static var stagingRoot: URL { ModelStore.root.appendingPathComponent(".downloads") }

    public init() {}

    /// Downloads `packages` in order. `progress` gets (bytes done, bytes total) across all of them,
    /// counting bytes already on disk from an earlier attempt.
    /// - Parameter convert: turns a verified download that needs it (`convertedName`) into the
    ///   model directory. The app passes one that runs on the `Transcriber` actor, so MLX is
    ///   never driven from two threads.
    public func download(_ packages: [ModelPackage],
                         convert: @Sendable (URL, URL) async throws -> Void = { try PolishModelConverter.convert(from: $0, to: $1) },
                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let todo = packages.filter { !$0.isInstalled }
        let total = todo.reduce(0) { $0 + $1.size }
        let fm = FileManager.default
        try fm.createDirectory(at: Self.stagingRoot, withIntermediateDirectories: true)
        Self.removeStaleStaging()

        // Check the space up front: running out halfway wastes the user's time and bandwidth.
        let onDisk = todo.reduce(0) { $0 + stagedBytes($1) }
        // A converted model also needs room for the result (the 4-bit polish model is ~0.3× the original).
        let needed = total - onDisk + todo.filter { $0.convertedName != nil }.reduce(0) { $0 + $1.size / 3 }
        if let available = Self.availableSpace(Self.stagingRoot), available < needed + 200_000_000 {
            throw DownloadError.diskFull(needed: needed, available: available)
        }

        progress(onDisk, total)
        for package in todo {
            let staging = Self.stagingRoot.appendingPathComponent(package.directoryName)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            for file in package.files {
                try Task.checkCancellation()
                // Everything else on disk (finished packages, other files of this one, earlier
                // partial downloads) plus this file's bytes, so the bar never jumps back on resume.
                let others = todo.reduce(0) { $0 + stagedBytes($1) } + installedBytes(todo)
                    - min(fileSize(staging.appendingPathComponent(file.path)) ?? 0, file.size)
                try await fetch(file, of: package, into: staging) { progress(others + $0, total) }
            }
            try await install(staging, as: package, convert: convert)
        }
        progress(total, total)
    }

    /// Free space including purgeable files; some volumes (disk images) report 0 for that, so
    /// fall back to the plain free space.
    private static func availableSpace(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Bytes of packages in `packages` that already finished and moved out of staging.
    private func installedBytes(_ packages: [ModelPackage]) -> Int64 {
        packages.filter(\.isInstalled).reduce(0) { $0 + $1.size }
    }

    /// Partial downloads of models that are installed by now (e.g. by hand) only take up space.
    public static func removeStaleStaging() {
        let known = ASRModel.allCases.map(\.package) + [ModelPackage.vad, ModelPackage.polish]
        for package in known where package.isInstalled {
            try? FileManager.default.removeItem(at: stagingRoot.appendingPathComponent(package.directoryName))
        }
    }

    /// Bytes of `package` already downloaded (complete and partial files in its staging directory).
    public func stagedBytes(_ package: ModelPackage) -> Int64 {
        let staging = Self.stagingRoot.appendingPathComponent(package.directoryName)
        return package.files.reduce(0) { sum, file in
            sum + min(fileSize(staging.appendingPathComponent(file.path)) ?? 0, file.size)
        }
    }

    private func install(_ staging: URL, as package: ModelPackage,
                         convert: @Sendable (URL, URL) async throws -> Void) async throws {
        let fm = FileManager.default
        let target = package.localDirectory
        var source = staging
        if let convertedName = package.convertedName {
            // Convert next to the staging folder, so a failed or interrupted conversion never
            // leaves a half-written model in the models folder.
            source = Self.stagingRoot.appendingPathComponent(convertedName + ".converting")
            try? fm.removeItem(at: source)
            do {
                try await convert(staging, source)
                try Task.checkCancellation()  // cancelled while converting: don't install
            } catch {
                try? fm.removeItem(at: source)
                throw error
            }
        }
        // An incomplete copy from a manual download is in the way: replace it.
        if fm.fileExists(atPath: target.path) {
            try fm.removeItem(at: target)
        }
        try fm.moveItem(at: source, to: target)
        if source != staging { try? fm.removeItem(at: staging) }
    }

    private func fetch(_ file: ModelFile, of package: ModelPackage, into staging: URL,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        let destination = staging.appendingPathComponent(file.path)
        let fm = FileManager.default
        var existing = fileSize(destination) ?? 0
        if existing > file.size {
            try? fm.removeItem(at: destination)
            existing = 0
        }
        if existing < file.size {
            let url = Self.endpoint.appendingPathComponent(package.repo)
                .appendingPathComponent("resolve").appendingPathComponent(package.revision)
                .appendingPathComponent(file.path)
            try await FileFetch(url: url, destination: destination, offset: existing,
                                name: file.path, progress: progress).run()
        }
        progress(file.size)
        guard try verify(destination, file) else {
            try? fm.removeItem(at: destination)
            throw DownloadError.corrupt("\(package.directoryName)/\(file.path)")
        }
    }

    /// Checks size and hash. Hashing reads the file in chunks (a 1.6 GB model takes a few seconds).
    private func verify(_ url: URL, _ file: ModelFile) throws -> Bool {
        guard fileSize(url) == file.size else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if let expected = file.sha256 {
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize()) == expected
        }
        if let expected = file.gitSHA1 {
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(file.size)\0".utf8))
            while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hex(hasher.finalize()) == expected
        }
        return true
    }

    /// From the file system every time: URL.resourceValues caches the size it read first,
    /// which is stale after a resumed download.
    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// One HTTP download appended to `destination`, resuming at `offset` with a Range request.
private final class FileFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let name: String
    private let progress: @Sendable (Int64) -> Void
    private var offset: Int64
    private var handle: FileHandle?
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    /// The outcome, kept if the task completes before the continuation exists.
    private var finished: Result<Void, Error>?
    private var lastReport = Date.distantPast
    private let lock = NSLock()

    init(url: URL, destination: URL, offset: Int64, name: String, progress: @escaping @Sendable (Int64) -> Void) {
        self.url = url
        self.destination = destination
        self.offset = offset
        self.name = name
        self.progress = progress
    }

    func run() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60  // no data for a minute: give up, the user can resume
        config.waitsForConnectivity = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        request.setValue("Tsuzuri (macOS)", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                // A cancel can complete the task before we get here: then the result is waiting.
                let done = lock.withLock { () -> Result<Void, Error>? in
                    if finished == nil { continuation = c }
                    return finished
                }
                if let done {
                    c.resume(with: done)
                } else if Task.isCancelled {
                    task.cancel()
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206:
                break
            case 200:
                offset = 0  // the server ignored the Range header: start over
            default:
                throw DownloadError.server(status, name)
            }
            let fm = FileManager.default
            if !fm.fileExists(atPath: destination.path) || offset == 0 {
                guard fm.createFile(atPath: destination.path, contents: nil) else {
                    throw DownloadError.network("can't write \(destination.path)")
                }
            }
            let handle = try FileHandle(forWritingTo: destination)
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seekToEnd()
            self.handle = handle
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
            offset += Int64(data.count)
            let now = Date()
            if now.timeIntervalSince(lastReport) > 0.1 {
                lastReport = now
                progress(offset)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        let error: Error? = failure.map(Self.classify) ?? error.map(Self.classify)
        let result: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            if continuation == nil { finished = result }
            return continuation
        }
        c?.resume(with: result)
    }

    private static func classify(_ error: Error) -> Error {
        if error is DownloadError { return error }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return DownloadError.diskFull(needed: 0, available: 0) }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return DownloadError.diskFull(needed: 0, available: 0) }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) {
            return DownloadError.diskFull(needed: 0, available: 0)
        }
        guard let urlError = error as? URLError else { return DownloadError.network(error.localizedDescription) }
        switch urlError.code {
        case .cancelled: return DownloadError.cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return DownloadError.offline
        // Server down, blocked or a mirror unreachable: the system's (localized) description says which.
        default: return DownloadError.network(urlError.localizedDescription)
        }
    }
}
