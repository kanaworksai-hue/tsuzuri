import Foundation
import TsuzuriCore

// tsuzuri-cli — offline transcription and benchmarking for Tsuzuri.
//
//   tsuzuri-cli [--model Qwen3-ASR-1.7B-4bit | --model-dir DIR] [--language Chinese]
//               [--context "hot words"] [--no-vad] [--polish] [--app NAME] [--jsonl] [--repeat N] FILE...
//   tsuzuri-cli --polish-text [--app NAME] [--jsonl] TEXTFILE...   # polish only, no ASR
//   tsuzuri-cli --guard-only RESULTS.jsonl...                      # re-run PolishGuard on {"in","out"} lines
//   tsuzuri-cli --download [--model NAME | --polish]               # download a speech model (and Silero VAD) or the polish model

struct Options {
    var model: ASRModel = .default
    var modelDir: URL?
    var language: String?
    var context = ""
    var vad = true
    var jsonl = false
    var repeatCount = 1
    var polish = false
    var polishText = false
    var guardOnly = false
    var download = false
    var polishDir: URL?
    var app: String?
    var timeout = 1.0
    var files: [URL] = []
}

func usage(exitCode: Int32 = 2) -> Never {
    let models = ASRModel.allCases.map(\.rawValue).joined(separator: ", ")
    let text = """
    usage: tsuzuri-cli [--model NAME | --model-dir DIR] [--language NAME] [--context TEXT]
                       [--no-vad] [--polish] [--app NAME] [--jsonl] [--repeat N] AUDIO...
           tsuzuri-cli --polish-text [--app NAME] [--jsonl] TEXTFILE...
           tsuzuri-cli --guard-only RESULTS.jsonl...
           tsuzuri-cli --download [--model NAME | --polish]
      --model NAME    speech model (default \(ASRModel.default.rawValue))
      --model-dir DIR load the speech model from DIR instead of the models dir
      --language NAME spoken language, e.g. English, Japanese, German (default: auto-detect)
      --context TEXT  context / hot words passed to the model
      --no-vad        do not trim silence with Silero VAD
      --jsonl         one JSON line per file, with timings and memory use
      --repeat N      transcribe each file N times (benchmarking)
      --polish        clean up the transcript with \(PolishModel.directoryName) (falls back to raw on guard failure;
                      skipped unless the detected language is one of \(PolishLanguages.supported.joined(separator: ", ")))
      --app NAME      app name passed to the polish model
      --polish-text   polish each line of TEXTFILE; JSONL lines use "in" (and pass id/cat/ref through)
      --guard-only    apply the polish guard to existing {"in","out"} records, no model
      --download      download the speech model (and Silero VAD) from Hugging Face into the models dir;
                      resumes an interrupted download. HF_ENDPOINT selects a mirror. With --polish:
                      the polish model (spokenly/cleanup-1, quantized to 4-bit after download)
      --polish-dir    polish model directory (default: models dir/\(PolishModel.directoryName))
      --timeout S     polish timeout in seconds (default 1.0)
      models: \(models)
      models dir: \(ModelStore.root.path) (set TSUZURI_MODELS_DIR to change)

    """
    (exitCode == 0 ? FileHandle.standardOutput : FileHandle.standardError).write(Data(text.utf8))
    exit(exitCode)
}

func parse() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--model":
            guard let v = it.next(), let m = ASRModel(rawValue: v) else { usage() }
            o.model = m
        case "--model-dir":
            guard let v = it.next() else { usage() }
            o.modelDir = URL(fileURLWithPath: v)
        case "--language":
            guard let v = it.next() else { usage() }
            o.language = v.lowercased() == "auto" ? nil : v
        case "--context":
            guard let v = it.next() else { usage() }
            o.context = v
        case "--polish": o.polish = true
        case "--polish-text": o.polishText = true
        case "--guard-only": o.guardOnly = true
        case "--download": o.download = true
        case "--polish-dir":
            guard let v = it.next() else { usage() }
            o.polishDir = URL(fileURLWithPath: v)
        case "--app":
            guard let v = it.next() else { usage() }
            o.app = v
        case "--timeout":
            guard let v = it.next(), let t = Double(v), t > 0 else { usage() }
            o.timeout = t
        case "--no-vad": o.vad = false
        case "--jsonl": o.jsonl = true
        case "--repeat":
            guard let v = it.next(), let n = Int(v), n > 0 else { usage() }
            o.repeatCount = n
        case "-h", "--help": usage(exitCode: 0)
        default:
            if arg.hasPrefix("-") { usage() }
            o.files.append(URL(fileURLWithPath: arg))
        }
    }
    if o.files.isEmpty, !o.download { usage() }
    return o
}

func emit(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    print(String(data: data, encoding: .utf8)!)
    fflush(stdout)
}

func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Runs `body` with stdout pointed at stderr, so libraries that print while loading
/// (e.g. "Generated tokenizer.json") do not end up in the transcript or JSONL output.
func quietStdout<T>(_ body: () async throws -> T) async rethrows -> T {
    fflush(stdout)
    let saved = dup(STDOUT_FILENO)
    dup2(STDERR_FILENO, STDOUT_FILENO)
    defer {
        fflush(stdout)
        dup2(saved, STDOUT_FILENO)
        close(saved)
    }
    return try await body()
}

/// Input lines for --polish-text / --guard-only: JSON objects, or plain text as {"in": line}.
func records(_ file: URL) throws -> [[String: Any]] {
    try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{"),
           let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] {
            return object
        }
        return ["in": trimmed]
    }
}

func polishFields(_ p: Polish) -> [String: Any] {
    ["polished": p.text, "candidate": p.candidate, "rejection": p.rejection ?? NSNull(),
     "polish_s": p.elapsed, "prompt_tokens": p.promptTokens, "gen_tokens": p.generatedTokens]
}

let options = parse()

if options.download {
    let model = options.model
    // --download --polish: the polish model (downloaded, then quantized to 4-bit here).
    let packages = options.polish ? [ModelPackage.polish] : model.downloadPackages
    let name = options.polish ? PolishModel.directoryName : model.rawValue
    let target = options.polish ? PolishModel.localDirectory : model.localDirectory
    if packages.allSatisfy(\.isInstalled) {
        stderr("\(name) is already installed in \(ModelStore.root.path)")
        exit(0)
    }
    let start = Date()
    final class LastPercent: @unchecked Sendable { var value = -1; let lock = NSLock() }
    let last = LastPercent()
    do {
        try await ModelDownloader().download(packages) { done, total in
            let percent = total > 0 ? Int(done * 100 / total) : 100
            let changed = last.lock.withLock {
                defer { last.value = percent }
                return percent != last.value
            }
            if changed {
                stderr("\(percent)% \(done / 1_000_000) / \(total / 1_000_000) MB")
                if options.jsonl { emit(["event": "progress", "done": done, "total": total]) }
            }
        }
    } catch {
        stderr("error: download failed: \(error)")
        if options.jsonl { emit(["event": "error", "error": "\(error)"]) }
        exit(1)
    }
    let seconds = Date().timeIntervalSince(start)
    stderr(String(format: "downloaded %@ to %@ in %.1fs", name, target.path, seconds))
    if options.jsonl { emit(["event": "done", "model": name, "seconds": seconds]) }
    exit(0)
}
let transcriber = Transcriber()
var failed = 0

/// Reports a file that can't be used and carries on with the others; the exit code is 1 at the end.
func fileError(_ file: URL, _ reason: String) {
    failed += 1
    stderr("error: \(file.path): \(reason)")
    if options.jsonl { emit(["event": "error", "file": file.lastPathComponent, "error": reason]) }
}

// Missing files are reported up front, before spending seconds on loading a model.
let missing = options.files.filter { !FileManager.default.fileExists(atPath: $0.path) }
missing.forEach { fileError($0, "file not found") }
let inputFiles = options.files.filter { FileManager.default.fileExists(atPath: $0.path) }
if inputFiles.isEmpty { exit(1) }

if options.guardOnly {
    // No model: re-check saved outputs, e.g. to tune PolishGuard against other models' results.
    for file in inputFiles {
        guard let lines = try? records(file) else { fileError(file, "not a UTF-8 text file"); continue }
        for r in lines where r["event"] as? String ?? "result" == "result" {
            guard let raw = r["in"] as? String, let out = r["out"] as? String else { continue }
            let reason = PolishGuard.rejection(raw: raw, output: out)
            if options.jsonl {
                emit(["file": file.lastPathComponent, "id": r["id"] ?? "", "in": raw, "out": out,
                      "rejection": reason ?? NSNull()])
            } else {
                print("\(reason == nil ? "ok " : "REJ") \(r["id"] ?? "")\t\(reason ?? "")\t\(out)")
            }
        }
    }
    exit(failed == 0 ? 0 : 1)
}

func loadPolisher() async throws {
    await transcriber.resetPeakMemory()
    let seconds = try await quietStdout { try await transcriber.loadPolisher(directory: options.polishDir) }
    let mem = await transcriber.memoryStats()
    if options.jsonl {
        emit(["event": "load", "model": options.polishDir?.lastPathComponent ?? PolishModel.directoryName,
              "load_s": seconds, "weights_gb": mem.activeGB, "footprint_gb": mem.residentGB])
    } else {
        stderr(String(format: "loaded %@ in %.2fs (MLX active %.2f GB, footprint %.2f GB)",
                      PolishModel.directoryName, seconds, mem.activeGB, mem.residentGB))
    }
}

if options.polishText {
    do {
        try await loadPolisher()
        for file in inputFiles {
            guard let lines = try? records(file) else { fileError(file, "not a UTF-8 text file"); continue }
            for r in lines {
                guard let text = r["in"] as? String else { continue }
                for run in 0..<options.repeatCount {
                    let p = await transcriber.polish(text, app: options.app, timeout: options.timeout)
                    let mem = await transcriber.memoryStats()
                    if options.jsonl {
                        // Fields: id / cat / ref are passed through from the input record;
                        // "out" is the raw model output, "polished" what the app would insert.
                        var rec: [String: Any] = ["event": "result", "id": r["id"] ?? "", "cat": r["cat"] ?? "",
                                                  "in": text, "ref": r["ref"] ?? "", "out": p.candidate,
                                                  "total_s": p.elapsed, "peak_gb": mem.peakGB,
                                                  "footprint_gb": mem.residentGB, "run": run]
                        rec.merge(polishFields(p)) { a, _ in a }
                        emit(rec)
                    } else {
                        print(p.text)
                        stderr(String(format: "  %.0f ms%@", p.elapsed * 1000,
                                      p.rejection.map { " — kept raw: \($0) [\(p.candidate)]" } ?? ""))
                    }
                }
            }
        }
    } catch {
        stderr("error: \(error)")
        exit(1)
    }
    exit(failed == 0 ? 0 : 1)
}

do {
    let loadSeconds = try await quietStdout { try await transcriber.load(options.model, directory: options.modelDir) }
    let afterLoad = await transcriber.memoryStats()
    if options.jsonl {
        emit(["event": "load", "model": options.model.rawValue, "load_s": loadSeconds,
              "mlx_active_gb": afterLoad.activeGB, "footprint_gb": afterLoad.residentGB])
    } else {
        stderr(String(format: "loaded %@ in %.2fs (MLX active %.2f GB, footprint %.2f GB)",
                      options.model.rawValue, loadSeconds, afterLoad.activeGB, afterLoad.residentGB))
    }
    if options.polish { try await loadPolisher() }

    for file in inputFiles {
        let samples: [Float]
        do {
            samples = try AudioFile.load16k(file)
        } catch {
            fileError(file, "not a readable audio file")
            continue
        }
        for run in 0..<options.repeatCount {
            let t: Transcription
            do {
                t = try await transcriber.transcribe(samples, language: options.language,
                                                     context: options.context, trimSilence: options.vad)
            } catch {
                fileError(file, "recognition failed: \(error)")
                break
            }
            // Same rule as the app: only polish languages cleanup-1 was trained on.
            var p: Polish?
            if options.polish {
                if let reason = PolishLanguages.skipReason(for: t.language) {
                    p = .skipped(t.text, reason: reason)
                } else {
                    p = await transcriber.polish(t.text, app: options.app, timeout: options.timeout)
                }
            }
            let mem = await transcriber.memoryStats()
            if options.jsonl {
                var rec: [String: Any] = ["event": "result", "file": file.lastPathComponent, "run": run,
                                          "text": t.text, "language": t.language ?? "", "input_s": t.inputSeconds,
                                          "audio_s": t.audioSeconds, "elapsed_s": t.elapsed, "rtf": t.rtf,
                                          "mlx_peak_gb": mem.peakGB, "footprint_gb": mem.residentGB]
                if let p { rec.merge(polishFields(p)) { a, _ in a } }
                emit(rec)
            } else {
                print(p?.text ?? t.text)
                stderr(String(format: "  [%@] %.2fs audio, %.3fs, RTF %.3f, lang %@",
                              file.lastPathComponent, t.audioSeconds, t.elapsed, t.rtf, t.language ?? "?"))
                if let p {
                    stderr(String(format: "  polish %.0f ms%@ — raw: %@", p.elapsed * 1000,
                                  p.rejection.map { ", kept raw (\($0))" } ?? "", t.text))
                }
            }
        }
    }
} catch {
    stderr("error: \(error)")
    exit(1)
}
exit(failed == 0 ? 0 : 1)
