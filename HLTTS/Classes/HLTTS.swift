//
//  HLTTS.swift
//  HLTTS
//
//  Created by RHL on 2025/9/9.
//

import Foundation
import AVFoundation

/// 播放状态
public enum HLTTSPlayState {
    case start(text: String)
    case finish(text: String)
    case pause(text: String)
    case `continue`(text: String)
    case cancel(text: String)
    case progress(text: String, progress: Float)
    case fail(text: String, error: Error)
}

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
    /// 统一的播放状态更新回调
    func didUpdateState(_ state: HLTTSPlayState)
}

/// 可用语音结构体
public struct HLTTSAvailableVoice {
    public let name: String
    public let language: String
    public let identifier: String
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
    
    /// 外界可设置的状态回调
    public var stateCallback: ((HLTTSPlayState) -> Void)?

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
    
    /// 语音类型
    public var voiceType: HLTTSVoiceType = .custom(identifier: "",displayName: "")

    private let synthesizer = AVSpeechSynthesizer()
    private var currentText: String = ""
    private var utteranceQueue: [AVSpeechUtterance] = []
    private var completionHandler: SpeakCompletion?
    
    // 💡 新增：专门处理 TTS 耗时任务的串行队列，避免阻塞主线程
    private let ttsWorkQueue = DispatchQueue(label: "com.hltts.workQueue", qos: .userInitiated)

    override private init() {
        super.init()
        configureAudioSession()
        synthesizer.delegate = self
        normalSet()
        prewarm() // 💡 触发预热机制
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
    
    /// 💡 新增：预热语音引擎
    private func prewarm() {
        ttsWorkQueue.async {
            // 随便初始化一个 voice，强制系统加载底层语音资源，避免首次 speak 时卡顿
            _ = AVSpeechSynthesisVoice(language: "zh-CN")
        }
    }

    /// 播放文本
    /// - Parameters:
    ///   - text: 要朗读的文本
    ///   - language: 语言（如"zh-CN", "en-US"），默认中文
    ///   - interrupt: 是否打断当前播放，默认true
    ///   - enqueue: 是否追加到队列，默认false
    ///   - completion: 播放完成或失败的回调
    public func speak(text: String, language: String = "zh-CN", interrupt: Bool = false, enqueue: Bool = true, completion: SpeakCompletion? = nil) {

        if text.isEmpty {
            let error = NSError(domain: "HLTTS", code: -1, userInfo: [NSLocalizedDescriptionKey: "文本为空"])
            delegate?.didFail(text: text, error: error)
            delegate?.didUpdateState(.fail(text: text, error: error))
            stateCallback?(.fail(text: text, error: error))
            completion?(.failure(error))
            return
        }
        
        // 保存 completionHandler，稍后在主线程赋值，避免多线程数据竞争
        let currentCompletion = completion
        
        // 💡 核心优化：将耗时操作派发到后台队列
        ttsWorkQueue.async { [weak self] in
            guard let self = self else { return }
            
            // 耗时操作 1: 切换音频会话状态 (Duck)
            startDuckOthers()
            
            // 耗时操作 2: 创建 Utterance 并查询 Voice
            let utterance = AVSpeechUtterance(string: text)
            
            switch self.voiceType {
            case .custom(let identifier, _), .dynamic(let identifier, _):
                if let voice = AVSpeechSynthesisVoice(identifier: identifier) {
                    utterance.voice = voice
                } else {
                    utterance.voice = AVSpeechSynthesisVoice(language: language)
                }
            }
            
            utterance.rate = self.rate
            utterance.pitchMultiplier = self.pitch
            utterance.volume = self.volume
            // 💡 切回主线程：操作合成器 (synthesizer) 和处理队列，保障 UI 逻辑的线程安全
            DispatchQueue.main.async {
                self.completionHandler = currentCompletion
                
                if interrupt {
                    // 只有在上一个还在播放时，才调用失败回调
                    if self.synthesizer.isSpeaking, let oldHandler = self.completionHandler {
                        let error = NSError(domain: "HLTTS", code: -3, userInfo: [NSLocalizedDescriptionKey: "播放被新任务打断"])
                        oldHandler(.failure(error))
                        self.delegate?.didUpdateState(.fail(text: self.currentText, error: error))
                        self.stateCallback?(.fail(text: self.currentText, error: error))
                        self.completionHandler = nil
                    }
                    
                    self.utteranceQueue.removeAll()
                    self.stop()
                    self.currentText = text
                    self.synthesizer.speak(utterance)
                } else {
                    if self.synthesizer.isSpeaking {
                        if enqueue {
                            self.utteranceQueue.append(utterance)
                        }
                    } else {
                        self.currentText = text
                        self.synthesizer.speak(utterance)
                    }
                }
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
                let banned = ["eloquence"]
                return !banned.contains(where: { voice.identifier.lowercased().contains($0) })
            }
            .map { voice in
                print("\(voice.identifier) | \(voice.name) | \(voice.language)")
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
            "com.apple.ttsbundle.siri_Li-mu_zh-CN_compact": "李牧",
            "com.apple.ttsbundle.siri_limu_zh-CN_compact": "李牧",
            "com.apple.ttsbundle.Mei-Jia-premium": "美嘉（增强版）",
            "com.apple.voice.premium.zh-CN.Yue": "月（高音质）",
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
    
}

// MARK: - AVSpeechSynthesizerDelegate
extension HLTTS: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        delegate?.didStart(text: utterance.speechString)
        delegate?.didUpdateState(.start(text: utterance.speechString))
        stateCallback?(.start(text: utterance.speechString))
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        delegate?.didFinish(text: utterance.speechString)
        delegate?.didUpdateState(.finish(text: utterance.speechString))
        stateCallback?(.finish(text: utterance.speechString))
        completionHandler?(.success(utterance.speechString))
        completionHandler = nil
        if !utteranceQueue.isEmpty {
            let nextUtterance = utteranceQueue.removeFirst()
            currentText = nextUtterance.speechString
            synthesizer.speak(nextUtterance)
        } else {
            // 💡 异步恢复音频会话，避免此处短时卡顿
            ttsWorkQueue.async { stopDuckOthers() }
        }
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        delegate?.didPause(text: utterance.speechString)
        delegate?.didUpdateState(.pause(text: utterance.speechString))
        stateCallback?(.pause(text: utterance.speechString))
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        delegate?.didContinue(text: utterance.speechString)
        delegate?.didUpdateState(.continue(text: utterance.speechString))
        stateCallback?(.continue(text: utterance.speechString))
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        delegate?.didCancel(text: utterance.speechString)
        let error = NSError(domain: "HLTTS", code: -2, userInfo: [NSLocalizedDescriptionKey: "播放被取消"])
        delegate?.didUpdateState(.cancel(text: utterance.speechString))
        stateCallback?(.cancel(text: utterance.speechString))
        delegate?.didUpdateState(.fail(text: utterance.speechString, error: error))
        stateCallback?(.fail(text: utterance.speechString, error: error))
        completionHandler?(.failure(error))
        completionHandler = nil
        if !utteranceQueue.isEmpty {
            let nextUtterance = utteranceQueue.removeFirst()
            currentText = nextUtterance.speechString
            synthesizer.speak(nextUtterance)
        } else {
            // 💡 异步恢复音频会话
            ttsWorkQueue.async { stopDuckOthers() }
        }
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let length = utterance.speechString.count
        guard length > 0 else { return }
        let progress = Float(characterRange.location + characterRange.length) / Float(length)
        delegate?.didUpdateProgress(text: utterance.speechString, progress: progress)
        delegate?.didUpdateState(.progress(text: utterance.speechString, progress: progress))
        stateCallback?(.progress(text: utterance.speechString, progress: progress))
    }
}

extension HLTTS {
    
    // 设置默认语音
    private func normalSet(){
        // 💡 核心优化：将首次读取 availableVoiceTypes 这种极其耗时的操作放入后台
        ttsWorkQueue.async { [weak self] in
            guard let self = self else { return }
            let voiceTypes = self.availableVoiceTypes(language: .chinese)
            var voiceTypeIdentifier = UserDefaults.standard.value(forKey: "HLTTSVoiceType") as? String
                // 如果没有存储，取 voiceTypes 第一个 case 的 identifier
            if voiceTypeIdentifier == nil, let firstVoice = voiceTypes.first {
                switch firstVoice {
                case .dynamic(let id, _):
                    voiceTypeIdentifier = id
                case .custom(let id, _):
                    voiceTypeIdentifier = id
                }
                UserDefaults.standard.setValue(voiceTypeIdentifier, forKey: "HLTTSVoiceType")
            }
            // 💡 切回主线程设置 voiceType
            DispatchQueue.main.async {
                if let id = voiceTypeIdentifier {
                    self.voiceType = .dynamic(identifier: id, displayName: "")
                }
            }
        }
    }
}
