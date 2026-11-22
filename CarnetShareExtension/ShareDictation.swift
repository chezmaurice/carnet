import AVFoundation
import Foundation

/// Dictation in the share sheet: the clip is recorded here and sent whole to
/// the household's server (`/api/dictation`, Whisper), which writes it down.
/// The app's composer has more engines (Services/Dictation.swift); a share
/// extension has little memory and seconds to live, so it keeps only the one
/// that gives the best text, and the mic is not shown where the household does
/// not transcribe.
@Observable @MainActor
final class ShareDictation {
    enum State { case idle, listening, transcribing }

    private(set) var state: State = .idle
    /// The household transcribes; asked once when the sheet opens.
    private(set) var available = false
    /// What went wrong last, said under the note.
    var message: String?

    private var recorder: AVAudioRecorder?

    private var household: HouseholdTranscription? {
        guard !CarnetAPI.baseURL.isEmpty, let token = CarnetAPI.authToken else { return nil }
        return HouseholdTranscription(baseURL: CarnetAPI.baseURL, token: token, preferred: true)
    }

    func probe() async {
        available = await household?.capability()?.available ?? false
    }

    func start() async {
        message = nil
        guard await AVAudioApplication.requestRecordPermission() else {
            message = L("share.mic_refused")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("share-dictation.m4a")
        try? FileManager.default.removeItem(at: url)
        // AAC, mono, 16 kHz: what Whisper hears at, and a few kilobytes a second.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            guard recorder.record() else { throw CocoaError(.fileWriteUnknown) }
            self.recorder = recorder
            state = .listening
        } catch {
            message = L("share.dictation_failed")
        }
    }

    /// Stop and transcribe; the text heard, or nil (and a message) when the
    /// server could not write it down.
    func stop() async -> String? {
        guard let recorder else { return nil }
        let seconds = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        state = .transcribing
        let text = await household?.transcribe(recorder.url, seconds: seconds)
        try? FileManager.default.removeItem(at: recorder.url)
        state = .idle
        let heard = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if heard == nil { message = L("share.dictation_failed") }
        return heard?.isEmpty == false ? heard : nil
    }

    /// The sheet is closing: drop what is being recorded.
    func cancel() {
        recorder?.stop()
        if let url = recorder?.url { try? FileManager.default.removeItem(at: url) }
        recorder = nil
        state = .idle
    }
}
