import Foundation
import TsuzuriCore

/// The one model download the app runs at a time, shared by the menu, the status line and
/// the setup window. Only starts when the user clicks a download button: it is the only
/// time Tsuzuri goes online.
/// What can be downloaded: a speech model (with the silence detector if missing) or the polish model.
enum DownloadItem: Equatable {
    case speech(ASRModel)
    case polish

    var packages: [ModelPackage] {
        switch self {
        case .speech(let model): model.downloadPackages
        case .polish: [.polish]
        }
    }

    var size: Int64 { packages.reduce(0) { $0 + $1.size } }
    var isInstalled: Bool { packages.allSatisfy(\.isInstalled) }

    var logName: String {
        switch self {
        case .speech(let model): model.rawValue
        case .polish: PolishModel.directoryName
        }
    }

    var displayName: String {
        switch self {
        case .speech(let model): model.displayName
        case .polish: String(localized: "Polish")
        }
    }
}

@MainActor
final class ModelDownloads: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(done: Int64, total: Int64)
        /// All bytes are in; checking hashes before installing.
        case verifying
        case failed(String)
    }

    /// What is being downloaded, or what failed to download.
    @Published private(set) var item: DownloadItem?
    @Published private(set) var state: State = .idle
    /// The speech model being downloaded (or that failed); nil for the polish model.
    var model: ASRModel? {
        if case .speech(let model) = item { return model }
        return nil
    }
    /// Something finished downloading and is installed. The flag says whether the user kept the
    /// same chosen speech model during the download (so switching to the new one is what they want).
    var onFinished: ((DownloadItem, Bool) -> Void)?
    /// Converts a downloaded model that needs it (the polish model); runs on the Transcriber actor.
    var convert: (@Sendable (URL, URL) async throws -> Void)?
    private var chosenAtStart: ASRModel?
    /// Called on every state change (throttled for progress), for the menu and status line.
    var onChange: (() -> Void)?

    private var task: Task<Void, Never>?
    private let downloader = ModelDownloader()

    var isDownloading: Bool {
        switch state {
        case .downloading, .verifying: true
        case .idle, .failed: false
        }
    }

    func isDownloading(_ model: ASRModel) -> Bool { isDownloading && self.model == model }
    var isDownloadingPolish: Bool { isDownloading && item == .polish }

    /// "45%", for the menu and the status line.
    var percentText: String {
        guard case .downloading(let done, let total) = state, total > 0 else { return "" }
        return Self.percent.string(from: NSNumber(value: Double(done) / Double(total))) ?? ""
    }

    func failure(for model: ASRModel) -> String? {
        guard self.model == model, case .failed(let message) = state else { return nil }
        return message
    }

    func start(_ model: ASRModel) { start(.speech(model)) }

    func start(_ item: DownloadItem) {
        guard !isDownloading else { return }
        self.item = item
        chosenAtStart = Settings.model
        let packages = item.packages
        state = .downloading(done: packages.reduce(0) { $0 + downloader.stagedBytes($1) }, total: item.size)
        onChange?()
        Log.write("download \(item.logName) started")
        let convert = convert ?? { try PolishModelConverter.convert(from: $0, to: $1) }
        task = Task {
            do {
                try await downloader.download(packages, convert: convert) { done, total in
                    Task { @MainActor [weak self] in self?.progress(done, total) }
                }
                Log.write("download \(item.logName) finished")
                state = .idle
                self.item = nil
                onChange?()
                onFinished?(item, Settings.model == chosenAtStart)
            } catch {
                if error is CancellationError || error as? DownloadError == .cancelled {
                    Log.write("download \(item.logName) cancelled")
                    state = .idle
                    self.item = nil
                } else {
                    Log.write("download \(item.logName) failed: \(error)")
                    state = .failed(Self.message(for: error))
                }
                onChange?()
            }
        }
    }

    /// Stops the download. What arrived so far is kept and the next download resumes from it.
    func cancel() {
        task?.cancel()
    }

    private func progress(_ done: Int64, _ total: Int64) {
        guard isDownloading else { return }  // a late update after cancel or failure
        let previous = percentText
        state = done >= total ? .verifying : .downloading(done: done, total: total)
        if percentText != previous || state == .verifying { onChange?() }
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static let percent: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 0
        return f
    }()

    private static func message(for error: Error) -> String {
        switch error as? DownloadError {
        case .offline:
            return String(localized: "No internet connection. Connect and try again.")
        case .diskFull(let needed, _) where needed > 0:
            return String(localized: "Not enough disk space. Free up \(size(needed)) and try again.")
        case .diskFull:
            return String(localized: "The disk is full. Free up some space and try again.")
        case .corrupt:
            return String(localized: "The download was damaged. Try again.")
        case .server(let status, _):
            return String(localized: "Download failed (\(String(status))). Try again later.")
        case .network(let detail):
            return String(localized: "Download failed (\(detail)). Try again later.")
        case .cancelled, nil:
            return String(localized: "Download failed (\(error.localizedDescription)). Try again later.")
        }
    }
}
