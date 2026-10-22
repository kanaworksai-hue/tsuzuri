import Foundation
import TsuzuriCore

/// The one model download the app runs at a time, shared by the menu, the status line and
/// the setup window. Only starts when the user clicks a download button: it is the only
/// time Tsuzuri goes online.
@MainActor
final class ModelDownloads: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(done: Int64, total: Int64)
        /// All bytes are in; checking hashes before installing.
        case verifying
        case failed(String)
    }

    /// The model being downloaded, or the one whose download failed.
    @Published private(set) var model: ASRModel?
    @Published private(set) var state: State = .idle
    /// A model finished downloading and is installed. The flag says whether the user kept the
    /// same chosen model during the download (so switching to the new one is what they want).
    var onFinished: ((ASRModel, Bool) -> Void)?
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

    /// "45%", for the menu and the status line.
    var percentText: String {
        guard case .downloading(let done, let total) = state, total > 0 else { return "" }
        return Self.percent.string(from: NSNumber(value: Double(done) / Double(total))) ?? ""
    }

    func failure(for model: ASRModel) -> String? {
        guard self.model == model, case .failed(let message) = state else { return nil }
        return message
    }

    func start(_ model: ASRModel) {
        guard !isDownloading else { return }
        self.model = model
        chosenAtStart = Settings.model
        let total = model.downloadSize
        state = .downloading(done: model.downloadPackages.reduce(0) { $0 + downloader.stagedBytes($1) }, total: total)
        onChange?()
        Log.write("download \(model.rawValue) started")
        let packages = model.downloadPackages
        task = Task {
            do {
                try await downloader.download(packages) { done, total in
                    Task { @MainActor [weak self] in self?.progress(done, total) }
                }
                Log.write("download \(model.rawValue) finished")
                state = .idle
                self.model = nil
                onChange?()
                onFinished?(model, Settings.model == chosenAtStart)
            } catch {
                if error is CancellationError || error as? DownloadError == .cancelled {
                    Log.write("download \(model.rawValue) cancelled")
                    state = .idle
                    self.model = nil
                } else {
                    Log.write("download \(model.rawValue) failed: \(error)")
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
