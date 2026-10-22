import Foundation
import TsuzuriCore

// tsuzuri-cli — offline transcription and benchmarking for Tsuzuri.
//
//   tsuzuri-cli [--model Qwen3-ASR-1.7B-4bit | --model-dir DIR] [--language Chinese]
//               [--context "hot words"] [--no-vad] [--polish] [--app NAME] [--jsonl] [--repeat N] FILE...
//   tsuzuri-cli --polish-text [--app NAME] [--jsonl] TEXTFILE...   # polish only, no ASR
//   tsuzuri-cli --guard-only RESULTS.jsonl...                      # re-run PolishGuard on {"in","out"} lines

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
    var polishDir: URL?
    var app: String?
    var timeout = 1.0
    var files: [URL] = []
}

func usage() -> Never {
    let models = ASRModel.allCases.map(\.rawValue).joined(separator: ", ")
    FileHandle.standardError.write(Data("""
    usage: tsuzuri-cli [--model NAME | --model-dir DIR] [--language NAME] [--context TEXT]
                       [--no-vad] [--polish] [--app NAME] [--jsonl] [--repeat N] AUDIO...
           tsuzuri-cli --polish-text [--app NAME] [--jsonl] TEXTFILE...
           tsuzuri-cli --guard-only RESULTS.jsonl...
      --polish        clean up the transcript with \(PolishModel.directoryName) (falls back to raw on guard failure;
                      skipped unless the detected language is one of \(PolishLanguages.supported.joined(separator: ", ")))
      --polish-text   polish each line of TEXTFILE; JSONL lines use "in" (and pass id/cat/ref through)
      --guard-only    apply the polish guard to existing {"in","out"} records, no model
      --polish-dir    polish model directory (default: models dir/\(PolishModel.directoryName))
      --timeout S     polish timeout in seconds (default 1.0)
      models: \(models)
      models dir: \(ModelStore.root.path)

    """.utf8))
    exit(2)
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
        case "-h", "--help": usage()
        default:
            if arg.hasPrefix("-") { usage() }
            o.files.append(URL(fileURLWithPath: arg))
        }
    }
    if o.files.isEmpty { usage() }
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
let transcriber = Transcriber()

if options.guardOnly {
    // No model: re-check saved outputs, e.g. to tune PolishGuard against other models' results.
    for file in options.files {
        for r in try records(file) where r["event"] as? String ?? "result" == "result" {
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
    exit(0)
}

func loadPolisher() async throws {
    await transcriber.resetPeakMemory()
    let seconds = try await transcriber.loadPolisher(directory: options.polishDir)
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
        for file in options.files {
            for r in try records(file) {
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
    exit(0)
}

do {
    let loadSeconds = try await transcriber.load(options.model, directory: options.modelDir)
    let afterLoad = await transcriber.memoryStats()
    if options.jsonl {
        emit(["event": "load", "model": options.model.rawValue, "load_s": loadSeconds,
              "mlx_active_gb": afterLoad.activeGB, "footprint_gb": afterLoad.residentGB])
    } else {
        stderr(String(format: "loaded %@ in %.2fs (MLX active %.2f GB, footprint %.2f GB)",
                      options.model.rawValue, loadSeconds, afterLoad.activeGB, afterLoad.residentGB))
    }
    if options.polish { try await loadPolisher() }

    for file in options.files {
        let samples = try AudioFile.load16k(file)
        for run in 0..<options.repeatCount {
            let t = try await transcriber.transcribe(samples, language: options.language,
                                                     context: options.context, trimSilence: options.vad)
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
