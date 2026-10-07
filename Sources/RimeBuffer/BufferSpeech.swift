import AVFoundation
import Foundation

// Read-aloud for translated Buffer blocks. Only AVFoundation and Foundation
// are used so the iOS keyboard can adopt the same resolver, switch and reader
// unchanged. Speech is synthesized on the device; text never leaves the
// machine and is never logged.

extension Notification.Name {
    static let bufferSpeechDidChange = Notification.Name("RimeBuffer.bufferSpeechDidChange")
}

/// Maps a translation language ID ("zh-Hans", "en", "ja") onto the language of
/// an installed system voice ("zh-CN", "en-US", "ja-JP").
enum BufferSpeechVoiceResolver {
    /// Region preferences for IDs that carry no region. Chinese scripts pick
    /// the regions whose voices actually read that script.
    private static let preferredRegions: [String: [String]] = [
        "zh-Hans": ["CN", "SG"],
        "zh-Hant": ["TW", "HK", "MO"],
        "zh": ["CN", "TW", "HK"],
        "en": ["US", "GB", "AU", "IE", "ZA", "IN"],
        "es": ["ES", "MX"],
        "fr": ["FR", "CA"],
        "de": ["DE"],
        "pt": ["BR", "PT"],
        "ja": ["JP"],
        "ko": ["KR"],
    ]

    static func voiceLanguage(for languageID: String,
                              installed: [String],
                              userRegion: String? = nil) -> String? {
        // `Locale.Region` is macOS 13+; fall back to `regionCode` on 12.3.
        var userRegion = userRegion
        if userRegion == nil {
            if #available(macOS 13, *) {
                userRegion = Locale.current.region?.identifier
            } else {
                userRegion = Locale.current.regionCode
            }
        }
        let installed = installed.map(normalized)
        let wanted = normalized(languageID)
        guard !wanted.isEmpty, wanted != "auto" else { return nil }
        if let exact = installed.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame }) {
            return exact
        }

        let parts = wanted.split(separator: "-").map(String.init)
        let language = parts[0].lowercased()
        let script = parts.dropFirst().first { $0.count == 4 }?.capitalized
        let explicitRegion = parts.dropFirst().first { $0.count == 2 || $0.count == 3 }?.uppercased()
        let sameLanguage = installed.filter {
            $0.split(separator: "-").first.map { String($0).lowercased() } == language
        }
        guard !sameLanguage.isEmpty else { return nil }

        let scriptKey = script.map { "\(language)-\($0)" }
        let scriptRegions = scriptKey.flatMap { preferredRegions[$0] }
        var regions: [String] = []
        if let explicitRegion { regions.append(explicitRegion) }
        // The user's own region wins only when it fits the requested script.
        if let userRegion, scriptRegions == nil || scriptRegions!.contains(userRegion) {
            regions.append(userRegion)
        }
        regions += scriptRegions ?? preferredRegions[language] ?? []
        for region in regions {
            if let match = sameLanguage.first(where: { regionOf($0) == region }) {
                return match
            }
        }
        // A script-specific request never falls back to the other script.
        if let scriptRegions {
            return sameLanguage.first { regionOf($0).map(scriptRegions.contains) ?? false }
        }
        return sameLanguage.first
    }

    private static func normalized(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func regionOf(_ identifier: String) -> String? {
        identifier.split(separator: "-").dropFirst()
            .last { $0.count == 2 || $0.count == 3 }
            .map { String($0).uppercased() }
    }
}

/// The read-aloud switch. Off by default; while on, the translation rail
/// reads a block when it is clicked or sent, and nothing else.
final class BufferSpeechPreferences {
    static let shared = BufferSpeechPreferences()
    static let enabledKey = "\(RimesIdentity.preferenceKeyPrefix)BufferSpeech.enabled"

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    init(defaults: UserDefaults = .standard,
         notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            guard newValue != isEnabled else { return }
            defaults.set(newValue, forKey: Self.enabledKey)
            notificationCenter.post(name: .bufferSpeechDidChange, object: self)
        }
    }
}

final class BufferSpeechReader: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = BufferSpeechReader()

    enum Outcome: Equatable {
        case started
        case empty
        case noVoice
    }

    private let synthesizer = AVSpeechSynthesizer()
    /// Delegate callbacks for an utterance replaced by a newer one must not
    /// clear the newer utterance's speaking state.
    private var currentUtterance: AVSpeechUtterance?
    /// UI refreshes ask often; the installed voice list changes rarely.
    private var resolvedVoiceLanguages: [String: String?] = [:]
    private var voicesObserver: NSObjectProtocol?

    var isSpeaking: Bool { currentUtterance != nil }

    override init() {
        super.init()
        synthesizer.delegate = self
        if #available(macOS 14.0, iOS 17.0, *) {
            voicesObserver = NotificationCenter.default.addObserver(
                forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.resolvedVoiceLanguages.removeAll()
                self?.notifyChange()
            }
        }
    }

    /// The installed voice language that would read `languageID`, if any.
    func voiceLanguage(for languageID: String) -> String? {
        dispatchPrecondition(condition: .onQueue(.main))
        if let cached = resolvedVoiceLanguages[languageID] { return cached }
        let resolved = BufferSpeechVoiceResolver.voiceLanguage(
            for: languageID,
            installed: AVSpeechSynthesisVoice.speechVoices().map(\.language)
        )
        resolvedVoiceLanguages[languageID] = resolved
        return resolved
    }

    @discardableResult
    func speak(_ text: String, languageID: String) -> Outcome {
        dispatchPrecondition(condition: .onQueue(.main))
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }
        resolvedVoiceLanguages.removeValue(forKey: languageID)
        guard let voiceLanguage = voiceLanguage(for: languageID),
              let voice = AVSpeechSynthesisVoice(language: voiceLanguage) else {
            return .noVoice
        }
        stopWithoutNotifying()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        currentUtterance = utterance
        synthesizer.speak(utterance)
        IMELog.write("buffer speech started chars=\(text.count)")
        notifyChange()
        return .started
    }

    /// A caller that is itself refreshing UI passes `notify: false` so the
    /// change notification cannot re-enter that refresh.
    func stop(notify: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard currentUtterance != nil else { return }
        stopWithoutNotifying()
        if notify { notifyChange() }
    }

    private func stopWithoutNotifying() {
        currentUtterance = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        let settle = { [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.currentUtterance = nil
            self.notifyChange()
        }
        if Thread.isMainThread { settle() } else { DispatchQueue.main.async(execute: settle) }
    }

    private func notifyChange() {
        NotificationCenter.default.post(name: .bufferSpeechDidChange, object: self)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        finished(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        finished(utterance)
    }
}
