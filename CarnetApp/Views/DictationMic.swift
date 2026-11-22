import SwiftUI

/// Speak instead of typing: a microphone beside any field Carnet writes in —
/// a note, the shared side, a question to Maurice. The engine is the Maurice
/// app's (`Services/Dictation.swift`, copied as is): Apple's SpeechAnalyzer on
/// the device where the system has it (iOS 26), the household's server
/// (Whisper) where it hasn't or where the member prefers it, and the old
/// recogniser last — through Apple's servers only after the member said yes
/// here, once.
///
/// What is heard is appended to the field — as it is spoken on the device, at
/// the end from the server — and stays editable: nothing is kept or sent on
/// the member's behalf.
struct DictationMic: View {
    @Binding var text: String
    /// The language being written — the entry's, not the phone's.
    var locale: Locale = .current
    var size: CGFloat = 34

    @Environment(CarnetSession.self) private var session
    @State private var holder = DictationHolder()
    /// What the field held when listening began; the transcript goes after it.
    @State private var base: String?
    /// What dictation last wrote in the field, to tell its words from the
    /// member's own.
    @State private var lastWritten: String?
    @State private var message: String?
    @State private var askConsent = false
    /// The member closed the download note; it stays closed for this wait.
    @State private var downloadNoteClosed = false
    @AppStorage("carnet.dictation.allowServer") private var allowServer = false
    @AppStorage(DictationPrefs.preferHouseholdKey) private var preferHousehold = DictationPrefs.preferHouseholdDefault

    private var dictation: Dictation { holder.dictation }
    private var language: String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    var body: some View {
        Button { toggle() } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : "mic")
                .font(.system(size: size * 0.44))
                // The text is on its way from the server, or the recogniser
                // coming up: progress, not a mic that seems to have done nothing.
                .opacity(dictation.isBusy ? 0 : 1)
                .overlay { if dictation.isBusy { ProgressView().controlSize(.small) } }
                .gridControlChrome(size: size, on: dictation.isListening)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dictation.isListening ? "Stop dictating" : "Dictate")
        // The first dictation in a language can wait minutes on Apple's
        // model; a spinner alone reads as broken, so say what is happening.
        .popover(isPresented: Binding(get: { dictation.modelDownloadProgress != nil && !downloadNoteClosed },
                                      set: { if !$0 { downloadNoteClosed = true } })) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Apple is downloading the dictation model")
                    .font(.subheadline.weight(.semibold))
                ProgressView(value: dictation.modelDownloadProgress ?? 0)
                Text("First time only. It carries on if you leave the app; tap the mic to stop waiting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 260)
            .presentationCompactAdaptation(.popover)
        }
        .onChange(of: dictation.modelDownloadProgress == nil) { _, done in
            if done { downloadNoteClosed = false }
        }
        .onChange(of: dictation.transcript) { _, partial in
            guard dictation.isListening, let base else { return }
            text = joined(base, partial)
            lastWritten = text
        }
        .onChange(of: dictation.state) { _, state in
            if case let .failed(failure) = state { report(failure) }
        }
        .onAppear {
            // Have Apple's model fetched before the first dictation needs it —
            // it listens on its own, or previews what the server will hear.
            Dictation.prefetchModel(for: locale)
            dictation.onFinish = { final, _ in
                if let base {
                    // The server writes nothing until the end, and the member
                    // may have typed meanwhile: their words stay, the
                    // dictation follows them.
                    if let lastWritten {
                        // Streamed: rewrite the tail, unless the member edited
                        // it while the last words were being finalised.
                        if text == lastWritten { text = joined(base, final) }
                    } else {
                        text = joined(text == base ? base : text, final)
                    }
                }
                base = nil
                lastWritten = nil
            }
        }
        .onDisappear {
            if dictation.isListening { dictation.stop() }
            dictation.onFinish = nil
        }
        .alert("Dictation", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
        .confirmationDialog("Dictate in \(language)?", isPresented: $askConsent, titleVisibility: .visible) {
            Button("Send audio to Apple") {
                allowServer = true
                start()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This device has no offline dictation model for \(language), so Carnet can only transcribe it by sending the audio to Apple. Nothing else leaves the device.")
        }
    }

    private func toggle() {
        if dictation.state == .transcribing {
            // The words are on their way; nothing to do but wait.
            return
        } else if dictation.state == .preparing {
            // Changed their mind while the recogniser came up.
            dictation.stop()
        } else if dictation.isListening {
            dictation.stop(userStopped: true)
        } else {
            start()
        }
    }

    private func start() {
        base = text
        lastWritten = nil
        let household = CarnetAPI.authToken.map {
            HouseholdTranscription(baseURL: CarnetAPI.baseURL, token: $0, preferred: preferHousehold)
        }
        let names = ["Maurice", "Carnet"] + session.deviceMembers.map(\.display_name)
        dictation.start(locale: locale, allowServer: allowServer,
                        household: household, vocabulary: Array(Set(names)).sorted())
    }

    /// The transcript after what was already written, on its own sentence.
    private func joined(_ base: String, _ heard: String) -> String {
        let said = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return base }
        guard !base.isEmpty else { return said }
        return base.hasSuffix(" ") || base.hasSuffix("\n") ? base + said : base + " " + said
    }

    private func report(_ failure: Dictation.Failure) {
        base = nil
        switch failure {
        case .needsServerConsent: askConsent = true
        case .speechDenied: message = "Speech recognition is off for Carnet. Turn it on in Settings › Privacy › Speech Recognition."
        case .micDenied: message = "Microphone access is off for Carnet. Turn it on in Settings › Privacy › Microphone."
        case .unavailable: message = "Dictation isn't available right now."
        case .noOnDeviceModel: message = "Dictation for \(language) needs a model that isn't on this device. Add it under Settings › General › Keyboard › Dictation Languages, then try again."
        case .audioSession: message = "Couldn't take over the microphone."
        case .audioEngine: message = "Couldn't start recording."
        case .interrupted: message = "Dictation stopped — something else took the microphone. What was heard is kept."
        case .transcriptionFailed: message = "Dictation stopped, and the recording could not be transcribed — neither by your household's server nor on this device."
        }
    }
}

/// Dictation preferences shared by the mic and Settings.
enum DictationPrefs {
    /// Send dictation to the household's server (Whisper) even where the
    /// device has a recogniser of its own. On by default since 16 October
    /// 2026: the device previews the words either way, and Whisper's text was
    /// clearly the better one in use.
    static let preferHouseholdKey = "carnet.dictation.preferHousehold"
    static let preferHouseholdDefault = true
}
