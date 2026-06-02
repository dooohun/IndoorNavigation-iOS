import Foundation
import AVFoundation

/// 내비게이션 음성 안내(TTS) 매니저.
/// iOS 네이티브 `AVSpeechSynthesizer` 로 한국어 턴-바이-턴 안내를 읽어준다.
/// Mock fixture 기반 영상 녹화에서도 동일하게 동작하도록, UI 갱신 콜백(`updateNavigationStep`,
/// `showFloorTransition`, `showArrivalNotification`)에 훅으로 연결한다.
///
/// 핵심 설계:
/// - `updateNavigationStep` 은 1Hz 로 계속 호출되므로, 같은 액션을 매초 반복해서 읽지 않도록
///   "액션이 바뀔 때 1회" + "회전류는 임박 시(가까워졌을 때) 1회" 만 발화한다.
final class NavigationTTSManager: NSObject {

    static let shared = NavigationTTSManager()

    /// 전역 on/off. 영상 녹화 시 true 유지.
    var isEnabled: Bool = true

    private let synthesizer = AVSpeechSynthesizer()
    private var audioSessionConfigured = false

    /// 직전에 발화한 다음 액션. 액션이 바뀔 때만 새로 안내한다.
    private var lastAnnouncedAction: NavigationActionKind?
    /// 회전류 "곧 ~" 임박 안내를 이미 했는지 추적(액션당 1회).
    private var imminentAnnouncedAction: NavigationActionKind?

    /// 임박 안내 기준 거리(m). 이 거리 이내로 들어오면 "곧 좌회전입니다" 류를 1회 안내.
    private let imminentThresholdMeters: Double = 4.0

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// 새 내비게이션(또는 층 전환 후 새 구간) 시작 시 호출 — 안내 중복 제거 상태를 초기화한다.
    func reset() {
        lastAnnouncedAction = nil
        imminentAnnouncedAction = nil
    }

    /// 진행 중인 발화를 즉시 중단.
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 매 스텝 갱신(1Hz)에서 호출. 액션 변경/임박 시에만 실제 발화.
    func announceStep(action: NavigationActionKind, distanceMeters: Double) {
        guard isEnabled else { return }

        // 1) 액션이 바뀌면 새 구간 안내(거리 포함).
        if action != lastAnnouncedAction {
            lastAnnouncedAction = action
            imminentAnnouncedAction = nil
            if let phrase = phrase(for: action, distanceMeters: distanceMeters) {
                speak(phrase)
            }
            return
        }

        // 2) 같은 회전 액션에 가까워지면 "곧 ~" 임박 안내 1회.
        if distanceMeters <= imminentThresholdMeters,
           imminentAnnouncedAction != action,
           let phrase = imminentPhrase(for: action) {
            imminentAnnouncedAction = action
            speak(phrase)
        }
    }

    /// 층 전환(계단/엘리베이터) 모달 표시 시 호출.
    func announceFloorTransition(transitionType: String, targetFloor: Int?) {
        guard isEnabled else { return }
        // 다음 구간(전환 후 새 층)을 위해 스텝 중복 제거 상태 초기화.
        reset()

        let type = transitionType.uppercased()
        let isElevator = type.contains("ELEVATOR") || type.contains("EV")
        let means = isElevator ? "엘리베이터를 이용해" : "계단을 이용해"

        if let floor = targetFloor {
            speak("\(means) \(floorPhrase(floor))으로 이동하세요")
        } else {
            speak(isElevator ? "엘리베이터를 이용해 이동하세요" : "계단을 이용해 이동하세요")
        }
    }

    /// 목적지 도착 시 호출.
    func announceArrival() {
        guard isEnabled else { return }
        reset()
        speak("목적지에 도착했습니다")
    }

    // MARK: - Phrase generation

    private func phrase(for action: NavigationActionKind, distanceMeters: Double) -> String? {
        let d = roundedDistance(distanceMeters)
        switch action {
        case .straight:
            return d >= 1 ? "\(d)미터 직진하세요" : "직진하세요"
        case .turnLeft:
            return d >= 1 ? "\(d)미터 앞에서 좌회전하세요" : "좌회전하세요"
        case .turnRight:
            return d >= 1 ? "\(d)미터 앞에서 우회전하세요" : "우회전하세요"
        case .turnSlightLeft:
            return d >= 1 ? "\(d)미터 앞에서 왼쪽 방향으로 이동하세요" : "왼쪽 방향으로 이동하세요"
        case .turnSlightRight:
            return d >= 1 ? "\(d)미터 앞에서 오른쪽 방향으로 이동하세요" : "오른쪽 방향으로 이동하세요"
        case .uturn:
            return "유턴하세요"
        case .stairsUp:
            return "계단을 이용해 위층으로 이동하세요"
        case .stairsDown:
            return "계단을 이용해 아래층으로 이동하세요"
        case .elevator:
            return "엘리베이터를 이용하세요"
        case .arrive:
            return "잠시 후 목적지에 도착합니다"
        case .unknown:
            return nil
        }
    }

    private func imminentPhrase(for action: NavigationActionKind) -> String? {
        switch action {
        case .turnLeft: return "곧 좌회전입니다"
        case .turnRight: return "곧 우회전입니다"
        case .turnSlightLeft: return "곧 왼쪽 방향입니다"
        case .turnSlightRight: return "곧 오른쪽 방향입니다"
        case .uturn: return "곧 유턴입니다"
        case .arrive: return "목적지가 곧 도착합니다"
        default: return nil
        }
    }

    /// 층 번호 → 음성 표기. 음수면 "지하 N층", 양수면 "N층".
    private func floorPhrase(_ level: Int) -> String {
        if level < 0 { return "지하 \(abs(level))층" }
        return "\(level)층"
    }

    /// 거리를 자연스럽게 반올림. 10m 이상은 5m 단위, 미만은 1m 단위.
    private func roundedDistance(_ meters: Double) -> Int {
        let m = max(0, meters)
        if m >= 10 {
            return Int((m / 5).rounded()) * 5
        }
        return Int(m.rounded())
    }

    // MARK: - Speech

    private func speak(_ text: String) {
        configureAudioSessionIfNeeded()

        // 새 안내가 들어오면 이전 안내는 끊고 최신만 읽는다(밀림 방지).
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
    }

    private func configureAudioSessionIfNeeded() {
        guard !audioSessionConfigured else { return }
        audioSessionConfigured = true
        let session = AVAudioSession.sharedInstance()
        do {
            // AR 카메라/타 오디오와 공존하도록 mix + duck. 무음 스위치 무시(playback).
            try session.setCategory(.playback, mode: .voicePrompt,
                                    options: [.mixWithOthers, .duckOthers])
            try session.setActive(true)
        } catch {
            // 오디오 세션 설정 실패해도 TTS 자체는 시도(치명적 아님).
        }
    }
}
