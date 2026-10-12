import Foundation
import OpenDictationCore

let endpoint = URL(string: "http://127.0.0.1:8080/v1/audio/transcriptions")!
let configuration = ProviderConfig(endpointURL: endpoint, model: "", bearerToken: "")
precondition(configuration.model == nil && configuration.bearerToken == nil)
let provider: any TranscriptionProvider = HTTPTranscriptionAdapter()
_ = provider
let result = try TranscriptResponseParser.parse(data: Data(#"{"text":"Synthetic fixture"}"#.utf8))
precondition(result.text == "Synthetic fixture")
do {
    _ = try TranscriptResponseParser.parse(data: Data(#"{"text":" "}"#.utf8))
    fatalError("Empty transcripts must be rejected")
} catch ProviderError.emptyTranscript {
    // Expected public error contract.
}
let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("OpenDictationConsumer-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
let audioURL = temporaryDirectory.appendingPathComponent("synthetic.wav")
let samples = WAVFile.sineSamples(sampleRate: 16000, seconds: 0.05)
try WAVFile.writePCM16Mono(to: audioURL, samples: samples, sampleRate: 16000)
let info = try WAVFile.readInfo(from: audioURL)
precondition(info.sampleRate == 16000 && info.channels == 1 && info.bitsPerSample == 16)
precondition(info.frames == samples.count)
print("Independent OpenDictationCore consumer passed")
