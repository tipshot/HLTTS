//
//  HLTTS.swift
//  HLTTS
//
//  Created by RHL on 2025/9/9.
//

import Foundation
import AVFoundation

/// TTS回调协议
public protocol HLTTSDelegate: AnyObject {
    /// 开始播放
    func didStart(text: String)
    /// 播放完成
    func didFinish(text: String)
    /// 暂停
    func didPause(text: String)
    /// 继续
    func didContinue(text: String)
    /// 取消
    func didCancel(text: String)
    /// 进度更新
    func didUpdateProgress(text: String, progress: Float)
    /// 播放失败
    func didFail(text: String, error: Error)
}

/// 可用语音结构体
public struct HLTTSAvailableVoice {
    public let name: String
    public let language: String
    public let identifier: String
    
    public static func allVoices() -> [HLTTSAvailableVoice] {
        return AVSpeechSynthesisVoice.speechVoices().map {
            HLTTSAvailableVoice(name: $0.name, language: $0.language, identifier: $0.identifier)
        }
    }
    
    public static func chineseVoices() -> [HLTTSAvailableVoice] {
        return allVoices().filter { $0.language.hasPrefix("zh") }
    }
    
    public static func maleChineseVoices() -> [HLTTSAvailableVoice] {
        return chineseVoices().filter {
            let lowerName = $0.name.lowercased()
            return lowerName.contains("li-mu") || lowerName.contains("eddy")
        }
    }
    
    public static func femaleChineseVoices() -> [HLTTSAvailableVoice] {
        return chineseVoices().filter {
            let lowerName = $0.name.lowercased()
            return lowerName.contains("ting-ting") || lowerName.contains("ting ting") || lowerName.contains("tingting")
        }
    }
}

/// 语音类型枚举，推荐使用 dynamic 动态获取音色或 custom 自定义 identifier
public enum HLTTSVoiceType {
    case custom(identifier: String, displayName: String)
    case dynamic(identifier: String, displayName: String)
}

/// 支持的语音语言类型，用于筛选 availableVoiceTypes
public enum HLTTSLanguage: String {
    /// 中文
    case chinese = "zh"
    /// 英文
    case english = "en"
    /// 日语
    case japanese = "ja"
    /// 韩语
    case korean = "ko"
    /// 法语
    case french = "fr"
    /// 德语
    case german = "de"
    /// 西班牙语
    case spanish = "es"
    /// 意大利语
    case italian = "it"
    /// 俄语
    case russian = "ru"
    /// 全部语言
    case all = ""
}

/// 系统TTS封装
public class HLTTS: NSObject {
    public static let shared = HLTTS()

    public typealias SpeakCompletion = (Result<String, Error>) -> Void

    public weak var delegate: HLTTSDelegate?

    /// 语速，默认0.5（0.0~1.0）
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate {
        didSet {
            if rate < 0.0 { rate = 0.0 }
            if rate > 1.0 { rate = 1.0 }
        }
    }
    /// 音调，默认1.0（0.5~2.0）
    public var pitch: Float = 1.0 {
        didSet {
            if pitch < 0.5 { pitch = 0.5 }
            if pitch > 2.0 { pitch = 2.0 }
        }
    }
    /// 音量，默认1.0（0.0~1.0）
    public var volume: Float = 1.0 {
        didSet {
            if volume < 0.0 { volume = 0.0 }
            if volume > 1.0 { volume = 1.0 }
        }
    }
    
    /// 语音类型，默认Ting-Ting女声
    public var voiceType: HLTTSVoiceType = .custom(identifier: "com.apple.ttsbundle.Ting-Ting-compact",displayName: "田田")

    private let synthesizer = AVSpeechSynthesizer()
    private var currentText: String = ""
    private var utteranceQueue: [AVSpeechUtterance] = []
    private var completionHandler: SpeakCompletion?

    override private init() {
        super.init()
        configureAudioSession()
        synthesizer.delegate = self
    }
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            print("音频会话配置失败: \(error)")
        }
    }

    /// 播放文本
    /// - Parameters:
    ///   - text: 要朗读的文本
    ///   - language: 语言（如"zh-CN", "en-US"），默认中文
    ///   - interrupt: 是否打断当前播放，默认true
    ///   - enqueue: 是否追加到队列，默认false
    ///   - completion: 播放完成或失败的回调
    public func speak(text: String, language: String = "zh-CN", interrupt: Bool = true, enqueue: Bool = false, completion: SpeakCompletion? = nil) {

        if text.isEmpty {
            let error = NSError(domain: "HLTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "文本为空"])
            delegate?.didFail(text: text, error: error)
            completion?(.failure(error))
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        
        self.completionHandler = completion
        
        // 根据voiceType设置utterance.voice
        switch voiceType {
        case .custom(let identifier, _):
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                utterance.voice = voice
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            }
        case .dynamic(let identifier, _):
            if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                utterance.voice = voice
            } else {
                utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            }
        }
        
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        utterance.volume = volume

        if interrupt {
            utteranceQueue.removeAll()
            stop()
            currentText = text
            synthesizer.speak(utterance)
        } else {
            if synthesizer.isSpeaking {
                if enqueue {
                    utteranceQueue.append(utterance)
                }
                // 如果不enqueue且正在播放，则不做任何操作
            } else {
                currentText = text
                synthesizer.speak(utterance)
            }
        }
    }

    /// 暂停
    public func pause() {
        synthesizer.pauseSpeaking(at: .immediate)
    }

    /// 继续
    public func resume() {
        synthesizer.continueSpeaking()
    }

    /// 停止
    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// 是否正在朗读
    public func isSpeaking() -> Bool {
        return synthesizer.isSpeaking
    }
    
    public func availableVoiceTypes(language: HLTTSLanguage = .all) -> [HLTTSVoiceType] {
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                // 过滤语言
                if language != .all {
                    guard voice.language.lowercased().hasPrefix(language.rawValue.lowercased()) else { return false }
                }
                // 过滤掉 Eloquence 系列
                return !voice.identifier.lowercased().contains("eloquence")
            }
            .map { voice in
                let tempVoice = HLTTSVoiceType.dynamic(identifier: voice.identifier, displayName: voice.name)
                let friendly = friendlyName(for: tempVoice)
                return .dynamic(identifier: voice.identifier, displayName: friendly)
            }
    }
    
    /// 获取音色的用户友好显示名称
    /// - Parameter voice: HLTTSVoiceType 实例
    /// - Returns: 用户友好的名字
    public func friendlyName(for voice: HLTTSVoiceType) -> String {
        // 映射表，可根据需求扩展
        let voiceNameMap: [String: String] = [
            "com.apple.ttsbundle.Ting-Ting-compact": "田田",
            "com.apple.ttsbundle.siri_Li-mu_zh-CN_compact": "李牧",
            "com.apple.ttsbundle.siri_limu_zh-CN_compact": "李牧",
            "com.apple.ttsbundle.siri_Yu-shu_zh-CN_compact": "语舒",
            "com.apple.ttsbundle.Sin-Ji-compact": "小志",
            "com.apple.ttsbundle.Mei-Jia-compact": "美嘉（品质）",
            "com.apple.ttsbundle.Mei-Jia-premium": "美嘉（增强版）",
            
            "com.apple.voice.premium.zh-CN.Yue": "月（高音质）",
            "com.apple.voice.premium.zh-CN.Yun": "云（高音质）",
            "com.apple.voice.compact.zh-CN.Tingting": "婷婷",
            "com.apple.voice.compact.zh-CN-u-sd-cnsc.Fangfang": "盼盼",
            "com.apple.voice.compact.zh-HK.Sinji": "善怡",
            "com.apple.voice.compact.zh-TW.Meijia": "美嘉"
        ]

        switch voice {
        case .dynamic(let identifier, let displayName), .custom(let identifier, let displayName):
            // 优先使用映射表
            if let mappedName = voiceNameMap[identifier] {
                return mappedName
            }
            
            // fallback: dynamic 类型使用 displayName 去掉括号中的语言部分
            if case .dynamic(_, let display) = voice {
                if let parenIndex = display.firstIndex(of: "(") {
                    return String(display[..<parenIndex]).trimmingCharacters(in: .whitespaces)
                } else {
                    return display
                }
            }
            
            // fallback: custom 类型或 dynamic 没有 displayName，直接返回 identifier
            return identifier
        }
    }
    
    /// 获取系统默认的中文女声音色（Ting-Ting），如果不可用返回 nil
    public func defaultFemaleVoice() -> HLTTSVoiceType? {
        if let voice = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.Ting-Ting-compact") {
            return .custom(identifier: voice.identifier,displayName: "田田")
        }
        return nil
    }

    /// 获取系统默认的中文男声音色（Li-Mu），如果不可用返回 nil
    public func defaultMaleVoice() -> HLTTSVoiceType? {
        if let voice = AVSpeechSynthesisVoice(identifier: "com.apple.ttsbundle.siri_limu_zh-CN_compact") {
            return .custom(identifier: voice.identifier,displayName: "李牧")
        }
        return nil
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension HLTTS: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        delegate?.didStart(text: utterance.speechString)
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        delegate?.didFinish(text: utterance.speechString)
        completionHandler?(.success(utterance.speechString))
        completionHandler = nil
        if !utteranceQueue.isEmpty {
            let nextUtterance = utteranceQueue.removeFirst()
            currentText = nextUtterance.speechString
            synthesizer.speak(nextUtterance)
        }
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        delegate?.didPause(text: utterance.speechString)
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        delegate?.didContinue(text: utterance.speechString)
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        delegate?.didCancel(text: utterance.speechString)
        let error = NSError(domain: "HLTTS", code: -2, userInfo: [NSLocalizedDescriptionKey: "播放被取消"])
        completionHandler?(.failure(error))
        completionHandler = nil
        if !utteranceQueue.isEmpty {
            let nextUtterance = utteranceQueue.removeFirst()
            currentText = nextUtterance.speechString
            synthesizer.speak(nextUtterance)
        }
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let length = utterance.speechString.count
        guard length > 0 else { return }
        let progress = Float(characterRange.location + characterRange.length) / Float(length)
        delegate?.didUpdateProgress(text: utterance.speechString, progress: progress)
    }
}
