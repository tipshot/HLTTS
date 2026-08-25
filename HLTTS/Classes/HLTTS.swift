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

    /// 一条播报结束后，延迟多久才停用音频会话。
    /// 连续播报（倒计时 1 秒一条、公里+心率连播）落在这个窗口内就不会反复停用/激活，
    /// 从而避免每条重新激活的几百毫秒开销和开头被吞。
    /// ⚠️ 不能低于约 1.2s，否则倒计时会退化回“一条一激活”。
    public static var deactivateDelay: TimeInterval = 3.0

    /// 强制指定看门狗阈值，仅用于验证自愈路径。
    /// 自愈逻辑只在异常时才执行，而异常偶发、无法在本地复现，所以留这个口子：
    /// 设成 2.0 后较长的播报每条都会触发一次重建，可以验证新合成器 delegate 接得上、
    /// 排队中的播报能被搬走续播、TTS_Fail 能写进 operations、音频会话能释放。
    /// ⚠️ 平时必须保持 nil。
    public static var debugWatchdogTimeout: TimeInterval? = nil

    /// 诊断日志总开关。默认关闭 —— 一条播报会打 6~10 行，运动中每公里播报都会触发。
    /// 排查时在宿主 App 启动早期置 true 即可。见 `hlttsProbe`
    public static var isProbeEnabled = false

    /// 只用于防止系统离线合成异常时永久卡住运动入口。
    ///
    /// ⚠️ 这是"放行"的兜底，不是"等待"的预算：超时即意味着用户点了开始运动却看不到运动页。
    /// 预热本来就只是优化，绝不能有能力把主流程挡住好几秒 —— 宁可放行、让第一声慢半拍。
    /// 正常首次合成实测约 1.1~3.5s，4s 覆盖正常情况又不至于让用户面对无反馈的界面干等。
    private static let preloadFailOpenDelay: TimeInterval = 4.0

    /// ⚠️ 必须是 var：合成器卡死后唯一可靠的救回方式是整个换掉（见 rebuildSynthesizer）
    private var synthesizer = AVSpeechSynthesizer()
    private var currentText: String = ""
    private var completionHandler: SpeakCompletion?

    // MARK: 播报看门狗
    // AVSpeechSynthesizer 是黑盒，didFinish 是唯一的"播完了"信号。真机线上出现过
    // 一条 utterance didStart 之后 didFinish 永不到来（2026-08-11 运动记录实锤），
    // 后果是：后续播报全堵在它内部队列里、音频会话永不释放（音乐一直被压低），
    // 且没有任何办法救回来，只能重启 App。
    // 这里用"已开始播且超过合理时长仍未结束"这个纯客观事实判定卡死，然后换掉合成器。
    // 下面这几个状态只在主线程读写（delegate 回调实测都在主线程），故不加锁。

    /// 当前已 didStart、尚未 didFinish/didCancel 的 utterance
    private var speakingUtterance: AVSpeechUtterance?
    /// 上面那条 didStart 的时刻。⚠️ 锚点是 didStart 而非 speak，排队等待不计入
    private var speakingStartedAt: CFAbsoluteTime = 0
    private var watchdogItem: DispatchWorkItem?
    /// 外部主动 pause() 期间挂起看门狗，避免把人为暂停误判成卡死
    private var isPausedByCaller = false

    /// 已交给合成器、但还没 didFinish/didCancel 的 utterance 账本。
    ///
    /// ⚠️ 它**只是账本，绝不参与正常调度**。AVSpeechSynthesizer 不暴露内部队列，
    /// 重建时无法得知还有哪些没播，只能自己记一份，否则排在卡死那条后面的播报
    /// 会跟着旧合成器一起被丢掉（真机实测：公里点上"指导员+第一公里"连发，
    /// 重建后"第一公里"整条消失）。
    ///
    /// ⚠️ 千万不要拿它去做"didFinish 里取下一条 speak"——那正是 utterance 被
    /// 重复播放 2~3 次的根因。正常播放一律由合成器自带的 FIFO 内部队列负责。
    private var pendingUtterances: [AVSpeechUtterance] = []

    private enum EnginePreloadState: String {
        case idle
        case warming
        case ready
    }

    /// `write` 收到零帧结束缓冲或合成器发出 didFinish 后才算真正预热完成。
    private var enginePreloadState: EnginePreloadState = .idle
    private var preloadCompletions: [() -> Void] = []
    private var preloadStartedAt: TimeInterval = 0
    private var didReceiveWarmUpBuffer = false
    /// 预热开始前，宿主 App 共享音频会话里"别人是否在放音频"。
    /// 用来在预热结束时自检：预热绝不该动到它。见 `verifyPreloadLeftOtherAudioAlone`
    private var otherAudioWasPlayingBeforePreload = false
    private var activeWarmUpSynthesizer: AVSpeechSynthesizer?
    private let preloadLock = NSLock()

    /// 预热专用的合成器。只做离线合成（write），**不发声、不进播放队列**，
    /// 且明确使用独立音频会话，避免预热触碰宿主 App 的共享会话、打断后台音频。
    private lazy var warmUpSynthesizer: AVSpeechSynthesizer = {
        let synthesizer = AVSpeechSynthesizer()
        var applicationAudioSession = "unsupported"
        if #available(iOS 13.0, *) {
            synthesizer.usesApplicationAudioSession = false
            applicationAudioSession = "false"
        }
        synthesizer.delegate = self
        hlttsProbe("preload.synthesizer.created usesApplicationAudioSession=\(applicationAudioSession)")
        return synthesizer
    }()

    /// 延迟停用的调度状态。speak 可能来自任意线程，故用锁保护
    private let deactivateLock = NSLock()
    private var deactivateGeneration: UInt64 = 0
    private var deactivateWorkItem: DispatchWorkItem?

    // 💡 新增：专门处理 TTS 耗时任务的串行队列，避免阻塞主线程
    private let ttsWorkQueue = DispatchQueue(label: "com.hltts.workQueue", qos: .userInitiated)
    /// 音色枚举等一次性初始化工作单独一条队列，避免排在 ttsWorkQueue 上拖慢第一条播报
    private let setupQueue = DispatchQueue(label: "com.hltts.setupQueue", qos: .utility)
    /// 首次安装需要先确定默认音色；预热必须等到该音色真正写入后再合成。
    private let voiceSetupGroup = DispatchGroup()
    /// 预热单独一条队列。**绝不能和 ttsWorkQueue 共用** ——
    /// 预热里的音色首次加载可能是秒级的，共用串行队列会把紧随其后的倒计时播报全部堵住
    private let warmUpQueue = DispatchQueue(label: "com.hltts.warmUpQueue", qos: .userInitiated)
    /// 必须独立于 warmUpQueue；即使系统的 makeVoice/write 自身卡住，也要能按时放行运动入口。
    private let preloadWatchdogQueue = DispatchQueue(label: "com.hltts.preloadWatchdog", qos: .utility)

    override private init() {
        super.init()
        synthesizer.delegate = self
        registerAudioSessionObservers()
        voiceSetupGroup.enter()
        normalSet()
        hlttsProbe("instance.init preload=deferred")
    }

    /// 预热 TTS 引擎与音色资源：纯离线合成、不发声，并使用独立于宿主 App 的音频会话。
    /// 系统仍可能自动 mix/duck 其它音频，因此只应在用户明确发起运动后调用，不能放回冷启动路径。
    ///
    /// 真机实测（2026-08-11，iPhone 14 Pro / iOS 18.5 / 婷婷优化音质）：
    /// 首次合成约 **3.5 秒**。不提前付掉，它就整个压在倒计时第一声上。
    ///
    /// ⚠️ 预热**不能**用 `synthesizer.speak()`——
    /// 一是它必须走主线程，而起跑瞬间主线程正被运动页创建卡住（实测 1.8~3.4s），预热因此毫无提前量；
    /// 二是它会占住播放队列，让紧随其后的倒计时全部排到预热后面。
    /// 用 `write()` 离线合成两个问题都没有。
    ///
    /// 一个进程内只做一次。并发调用会合并，所有 completion 都会在主线程、预热完成或明确 fail-open 后回调。
    public func preloadEngine(completion: (() -> Void)? = nil) {
        var action = "join"
        var shouldStart = false
        var shouldCompleteImmediately = false
        var waiterCount = 0

        preloadLock.lock()
        switch enginePreloadState {
        case .idle:
            enginePreloadState = .warming
            preloadStartedAt = ProcessInfo.processInfo.systemUptime
            didReceiveWarmUpBuffer = false
            otherAudioWasPlayingBeforePreload = AVAudioSession.sharedInstance().isOtherAudioPlaying
            if let completion = completion {
                preloadCompletions.append(completion)
            }
            waiterCount = preloadCompletions.count
            action = "start"
            shouldStart = true
        case .warming:
            if let completion = completion {
                preloadCompletions.append(completion)
            }
            waiterCount = preloadCompletions.count
        case .ready:
            action = "completeImmediately"
            shouldCompleteImmediately = true
        }
        preloadLock.unlock()

        hlttsProbe("preload.request action=\(action) waiters=\(waiterCount)")

        if shouldCompleteImmediately {
            guard let completion = completion else { return }
            DispatchQueue.main.async(execute: completion)
            return
        }

        if shouldStart {
            startEnginePreload()
        }
    }

    private func startEnginePreload() {
        hlttsProbe("preload.appSession.before \(hlttsAudioSessionSnapshot(AVAudioSession.sharedInstance()))")
        hlttsProbe("preload.failOpen.schedule delay=\(HLTTS.preloadFailOpenDelay)")
        preloadWatchdogQueue.asyncAfter(deadline: .now() + HLTTS.preloadFailOpenDelay) { [weak self] in
            self?.failOpenEnginePreload(reason: "timeoutFailOpen")
        }

        warmUpQueue.async { [weak self] in
            guard let self = self else { return }
            guard #available(iOS 13.0, *) else {
                self.finishEnginePreload(reason: "writeUnavailable")
                return
            }

            hlttsProbe("preload.voiceSetup.wait.begin")
            self.voiceSetupGroup.wait()
            hlttsProbe("preload.voiceSetup.wait.end")
            self.preloadLock.lock()
            let shouldContinue = self.enginePreloadState == .warming
            self.preloadLock.unlock()
            guard shouldContinue else {
                hlttsProbe("preload.write.skip reason=stateChangedAfterVoiceSetup")
                return
            }

            hlttsProbe("preload.write.begin")
            let utterance = AVSpeechUtterance(string: "哈")
            utterance.voice = self.makeVoice(language: "zh-CN")
            let warmUpSynthesizer = self.warmUpSynthesizer
            self.preloadLock.lock()
            guard self.enginePreloadState == .warming else {
                self.preloadLock.unlock()
                hlttsProbe("preload.write.skip reason=stateChanged")
                return
            }
            self.activeWarmUpSynthesizer = warmUpSynthesizer
            self.preloadLock.unlock()
            warmUpSynthesizer.write(utterance) { [weak self] buffer in
                guard let self = self else { return }
                guard let pcmBuffer = buffer as? AVAudioPCMBuffer else {
                    hlttsProbe("preload.write.unexpectedBuffer type=\(type(of: buffer))")
                    return
                }

                if pcmBuffer.frameLength == 0 {
                    self.finishEnginePreload(reason: "terminalBuffer")
                    return
                }

                self.preloadLock.lock()
                let isFirstBuffer = !self.didReceiveWarmUpBuffer
                self.didReceiveWarmUpBuffer = true
                self.preloadLock.unlock()
                if isFirstBuffer {
                    hlttsProbe("preload.write.firstBuffer frames=\(pcmBuffer.frameLength) sampleRate=\(pcmBuffer.format.sampleRate)")
                }
            }
        }
    }

    private func failOpenEnginePreload(reason: String) {
        preloadLock.lock()
        guard enginePreloadState == .warming else {
            preloadLock.unlock()
            return
        }
        let synthesizerToStop = activeWarmUpSynthesizer
        preloadLock.unlock()

        if let synthesizerToStop = synthesizerToStop {
            // stop 先进入主队列，finish 派发的业务 completion 随后进入，确保真实倒计时不会与旧预热并跑。
            DispatchQueue.main.async {
                synthesizerToStop.delegate = nil
                synthesizerToStop.stopSpeaking(at: .immediate)
                hlttsProbe("preload.failOpen.stoppedWarmUpSynthesizer")
            }
        }
        finishEnginePreload(reason: reason)
    }

    private func finishEnginePreload(reason: String) {
        preloadLock.lock()
        guard enginePreloadState == .warming else {
            preloadLock.unlock()
            return
        }
        enginePreloadState = .ready
        activeWarmUpSynthesizer = nil
        let completions = preloadCompletions
        preloadCompletions.removeAll()
        let elapsed = ProcessInfo.processInfo.systemUptime - preloadStartedAt
        let otherAudioWasPlaying = otherAudioWasPlayingBeforePreload
        preloadLock.unlock()

        hlttsProbe(String(format: "preload.gate.open reason=%@ elapsed=%.3f callbacks=%d", reason, elapsed, completions.count))
        // ⚠️ 顺序要紧：自检必须先跑完（它检查的正是"预热有没有碰共享会话"），
        // 再让收尾去动 category / 预热播放通路，否则自检会把收尾自己的动作算进去
        verifyPreloadLeftOtherAudioAlone(otherAudioWasPlaying: otherAudioWasPlaying)
        prepareAudioSessionForFirstSpeak()
        guard !completions.isEmpty else { return }
        DispatchQueue.main.async {
            hlttsProbe("preload.callbacks.begin count=\(completions.count)")
            completions.forEach { $0() }
        }
    }

    /// 预热结束自检：确认预热没有动到宿主 App 的共享音频会话、没有打断用户正在听的音频。
    ///
    /// 预热链路上我们一行会话代码都没有（不设 category、不 setActive），`warmUpSynthesizer`
    /// 也用 `usesApplicationAudioSession = false` 挂在独立会话上。但"系统在合成时隐式激活
    /// 共享会话"这件事真机上确凿发生过（2026-08-25：冷启动预热把用户的音乐打断且永不恢复，
    /// 因为当时 category 还是默认的 `.soloAmbient` 独占语义，也没人发 notifyOthersOnDeactivation）。
    /// 那次的教训是：这条路径不能只靠"理论上不会"，得有自检兜住。
    ///
    /// 发现别人的音频在预热期间停了，就补发一次带 `.notifyOthersOnDeactivation` 的停用，
    /// 把播放权还回去 —— 打断已经发生，至少不能让它永远回不来。
    private func verifyPreloadLeftOtherAudioAlone(otherAudioWasPlaying: Bool) {
        let session = AVAudioSession.sharedInstance()
        hlttsProbe("preload.appSession.after \(hlttsAudioSessionSnapshot(session))")
        guard otherAudioWasPlaying, !session.isOtherAudioPlaying else { return }
        // 我们自己正在播报时，会话归播报管，这里不能插手
        guard !synthesizer.isSpeaking else {
            hlttsProbe("preload.appSession.otherAudioStopped action=skip reason=selfSpeaking")
            return
        }
        hlttsProbe("preload.appSession.otherAudioStopped action=notifyOthersOnDeactivation ⚠️ 预热不该做到这件事，需排查")
        stopDuckOthers()
    }

    /// 预热收尾：把首条播报要付的两笔开销尽量提前付掉。
    ///
    /// ① **category 只设不激活**。真机实测：首条 speak 的 `setActive` 花了 349ms，因为要把
    ///    category 从 `.soloAmbient` 跨类切到 `.playback`（`categoryNeedsUpdate=true`），
    ///    后续几条只要 5~7ms。这笔跨类切换在蓝牙 A2DP 下耗时 25~883ms 随机，慢的那次还会
    ///    **打断**用户正在听的音频 —— 让它发生在起跑那一刻是最差的安排。
    ///    这里做是安全的：预热合成器挂独立会话，共享会话此刻是 inactive，
    ///    而"inactive 时切 category 不打断别人、active 时才会"是实测结论。
    ///    设完之后起跑时 `startDuckOthers` 走幂等分支，只剩一个 setActive。
    ///
    /// ⚠️ 曾经在这里做过"静音 speak 预热播放通路"（2026-08-25 实测撤掉）：真机 A/B 对照下
    ///    首条播放时长 714ms(做) vs 736ms(不做) vs 741ms(功能上线前)，**毫无收益**。
    ///    原因是静音播完后延迟停用会把会话放掉，音频通路随之被系统回收，起跑时还得重新拉起
    ///    —— 预热的东西在停用会话那一刻就还回去了。别再试第二次。
    private func prepareAudioSessionForFirstSpeak() {
        let session = AVAudioSession.sharedInstance()

        if session.category != .playback || session.categoryOptions != hlttsCategoryOptions {
            do {
                try session.setCategory(.playback, options: hlttsCategoryOptions)
                hlttsProbe("preload.category.prepared \(hlttsAudioSessionSnapshot(session))")
            } catch {
                hlttsProbe("preload.category.error domain=\((error as NSError).domain) code=\((error as NSError).code)")
            }
        }
    }

    private func isWarmUpSynthesizer(_ candidate: AVSpeechSynthesizer) -> Bool {
        preloadLock.lock()
        let isWarmUp = enginePreloadState == .warming && candidate === activeWarmUpSynthesizer
        preloadLock.unlock()
        return isWarmUp
    }

    /// 起跑链路调用：等待引擎和最终音色真正准备完成，再继续创建运动页；同时把音频会话
    /// 的激活也提前发起，让它和建页并行跑完。
    ///
    /// ⚠️ 会话激活**不是**恒定几毫秒：有其它音频在放时，`setActive` 要和蓝牙路由协商 duck，
    /// 真机实测约 **300ms**（没有音乐在放时约 110ms）。把它推迟到首条 `speak` 的话，这 300ms
    /// 就整个压在倒计时第一声上（实测「3」出声延迟 402ms）。
    /// 放在这里则与 `SPRunningVC()` 构造（约 160ms）和 present 转场（约 550ms）并行，
    /// 等第一声触发时会话早已就绪。代价只是音乐被压低的时刻提前约 0.3 秒 —— 用户此刻
    /// 已经点了「开始运动」，这个提前量可以接受。
    ///
    /// 用 `ttsWorkQueue` 而不是别的队列：紧随其后的首条 `speak` 会自然排在它后面，
    /// 那时 `startDuckOthers` 走幂等分支，几乎零成本。
    public func prewarm(completion: @escaping () -> Void = {}) {
        hlttsProbe("prewarm.request")

        cancelPendingDeactivate()
        ttsWorkQueue.async { [weak self] in
            startDuckOthers()
            hlttsProbe("prewarm.audioSession.ready")
            // 用户可能点完就退出、或倒计时被跳过，别把会话一直 active 着。
            // 真播报进来会取消这次调度
            self?.scheduleDeactivateSession()
        }

        preloadEngine {
            hlttsProbe("prewarm.engineGateOpened")
            completion()
        }
    }

    /// 按当前 voiceType 取音色，取不到时回退到语言默认音色
    private func makeVoice(language: String) -> AVSpeechSynthesisVoice? {
        switch voiceType {
        case .custom(let identifier, _), .dynamic(let identifier, _):
            return AVSpeechSynthesisVoice(identifier: identifier) ?? AVSpeechSynthesisVoice(language: language)
        }
    }

    private func probeMetadata(for text: String) -> String {
        return "textLength=\(text.count)"
    }

    private func probeIdentifier(for utterance: AVSpeechUtterance) -> String {
        return String(describing: ObjectIdentifier(utterance))
    }

    // MARK: - 卡死检测与自愈

    /// 这条播报最长允许播多久。超过即判定合成器卡死。
    /// 不写死是因为播报文案后台可配，将来配了长文案不能被误杀；
    /// 我们要抓的是"永远不结束"，不是"比预期慢一点"，余量给大些无害。
    /// 实测最长的一条（45 字）真实耗时 10.2s，这里给到 42s。
    private func watchdogTimeout(for text: String) -> TimeInterval {
        if let forced = HLTTS.debugWatchdogTimeout { return forced }
        return 15.0 + Double(text.count) * 0.6
    }

    /// 回调是否来自当前合成器。被换掉的旧实例若诈尸回调，一律忽略
    private func isCurrent(_ candidate: AVSpeechSynthesizer) -> Bool {
        return candidate === synthesizer
    }

    private func startWatchdog(for utterance: AVSpeechUtterance) {
        cancelWatchdog()
        speakingUtterance = utterance
        speakingStartedAt = CFAbsoluteTimeGetCurrent()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            guard !self.isPausedByCaller, self.speakingUtterance === utterance else { return }
            self.rebuildSynthesizer(reason: "播报超时未结束")
        }
        watchdogItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + watchdogTimeout(for: utterance.speechString), execute: item)
    }

    private func cancelWatchdog() {
        watchdogItem?.cancel()
        watchdogItem = nil
        speakingUtterance = nil
    }

    /// 每次 speak 前顺手查一次，作为定时任务之外的双保险
    private func healIfStuck() {
        guard !isPausedByCaller, let stuck = speakingUtterance else { return }
        let elapsed = CFAbsoluteTimeGetCurrent() - speakingStartedAt
        guard elapsed > watchdogTimeout(for: stuck.speechString) else { return }
        rebuildSynthesizer(reason: "播报超时未结束（已卡 \(Int(elapsed)) 秒）")
    }

    /// 换掉整个合成器。
    /// 为什么不是 stopSpeaking()：那是"向卡死的对象发请求"，它的状态机若已经僵住、
    /// 或媒体服务重启后音频单元已失效，这个请求可能被忽略甚至自己也不返回。
    /// 新建实例是无条件成功的。
    private func rebuildSynthesizer(reason: String) {
        let stuck = speakingUtterance
        let lostText = stuck?.speechString ?? currentText
        hlttsProbe("synthesizer.rebuild reason=\(reason) lostTextLength=\(lostText.count) pending=\(pendingUtterances.count)")
        // 排在卡死那条后面、还没轮到播的，要跟着搬到新合成器上，否则会一起被丢掉
        let survivors = pendingUtterances.filter { $0 !== stuck }
        pendingUtterances.removeAll()

        let old = synthesizer
        old.delegate = nil
        old.stopSpeaking(at: .immediate)

        let fresh = AVSpeechSynthesizer()
        fresh.delegate = self
        synthesizer = fresh

        cancelWatchdog()

        // 把卡死那条报出去。stateCallback 会写进运动记录的 operations，
        // 线上再遇到这个问题时能留下证据，而不是像 2026-08-11 那次只剩一片空白
        let error = NSError(domain: "HLTTS", code: -4,
                            userInfo: [NSLocalizedDescriptionKey: "合成器已重建：\(reason)"])
        delegate?.didFail(text: lostText, error: error)
        delegate?.didUpdateState(.fail(text: lostText, error: error))
        stateCallback?(.fail(text: lostText, error: error))
        completionHandler?(.failure(error))
        completionHandler = nil

        // 把还没播的搬到新合成器上继续。
        // 复制一份而不是复用原对象——它们已经被旧合成器认领过，Apple 不建议重用 utterance
        for survivor in survivors {
            let copy = copyUtterance(survivor)
            pendingUtterances.append(copy)
            fresh.speak(copy)
        }

        if survivors.isEmpty {
            // 卡死期间 scheduleDeactivateSession 的 isSpeaking 守卫恒真，会话一直没释放，
            // 用户的音乐会被一直压低。这里补一次释放。
            // 有内容要继续播时不用管，它们播完自然会走 didFinish 的正常释放流程
            scheduleDeactivateSession()
        }
    }

    private func copyUtterance(_ source: AVSpeechUtterance) -> AVSpeechUtterance {
        let copy = AVSpeechUtterance(string: source.speechString)
        copy.voice = source.voice
        copy.rate = source.rate
        copy.pitchMultiplier = source.pitchMultiplier
        copy.volume = source.volume
        copy.preUtteranceDelay = source.preUtteranceDelay
        copy.postUtteranceDelay = source.postUtteranceDelay
        return copy
    }

    // MARK: - 音频会话通知

    private func registerAudioSessionObservers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    /// 系统媒体服务重启：Apple 文档明确要求重建所有音频对象
    @objc private func handleMediaServicesReset() {
        hlttsProbe("audioSession.mediaServicesReset")
        failOpenEnginePreload(reason: "mediaServicesResetFailOpen")
        DispatchQueue.main.async { [weak self] in
            self?.rebuildSynthesizer(reason: "系统媒体服务重启")
        }
    }

    /// 音频被系统抢走（来电、闹钟、Siri）。中断期间合成器会停在暂停态、didFinish 不来，
    /// 正是卡死的形态。这里尝试恢复；恢复不了也没关系，看门狗会兜底重建。
    /// `.began` 不做处理 —— 中断持续超过阈值时，重建掉那条陈旧播报才是对的。
    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        let optionRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionRaw).contains(.shouldResume)
        hlttsProbe("audioSession.interruption type=\(type.rawValue) shouldResume=\(shouldResume)")
        guard type == .ended else { return }
        if let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
            guard AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) else { return }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 没有播报卡在暂停态就什么都不做。
            // 否则会白白激活音频会话、把用户的音乐一直压低（此时也没有 didFinish 来触发延迟停用）
            guard self.speakingUtterance != nil else { return }
            self.ttsWorkQueue.async {
                startDuckOthers()   // 中断期间会话被系统停用了，先激活回来
                DispatchQueue.main.async {
                    guard self.speakingUtterance != nil else {
                        self.scheduleDeactivateSession()
                        return
                    }
                    self.synthesizer.continueSpeaking()
                }
            }
        }
    }

    /// 有新的播报到来：作废尚未执行的延迟停用
    private func cancelPendingDeactivate() {
        deactivateLock.lock()
        deactivateGeneration &+= 1
        let generation = deactivateGeneration
        let hadPendingItem = deactivateWorkItem != nil
        deactivateWorkItem?.cancel()
        deactivateWorkItem = nil
        deactivateLock.unlock()
        hlttsProbe("deactivate.cancel generation=\(generation) hadPending=\(hadPendingItem)")
    }

    /// 一条播报结束：延迟停用音频会话，期间来了新播报就作废本次调度
    private func scheduleDeactivateSession() {
        deactivateLock.lock()
        deactivateGeneration &+= 1
        let generation = deactivateGeneration
        deactivateWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.deactivateLock.lock()
            let isCurrent = (generation == self.deactivateGeneration)
            self.deactivateLock.unlock()
            // 代次变了说明期间有新播报；再兜一层合成器状态，避免长句播到一半被停掉。
            // 此处已距上次 didFinish 数秒，isSpeaking 是可信的
            let isSpeaking = self.synthesizer.isSpeaking
            guard isCurrent, !isSpeaking else {
                hlttsProbe("deactivate.skip generation=\(generation) isCurrent=\(isCurrent) isSpeaking=\(isSpeaking)")
                return
            }
            hlttsProbe("deactivate.execute generation=\(generation)")
            stopDuckOthers()
        }
        deactivateWorkItem = item
        deactivateLock.unlock()
        hlttsProbe("deactivate.schedule generation=\(generation) delay=\(HLTTS.deactivateDelay)")
        ttsWorkQueue.asyncAfter(deadline: .now() + HLTTS.deactivateDelay, execute: item)
    }

    /// 播放文本
    /// - Parameters:
    ///   - text: 要朗读的文本
    ///   - language: 语言（如"zh-CN", "en-US"），默认中文
    ///   - interrupt: 是否打断当前播放，默认true
    ///   - enqueue: 是否追加到队列，默认false
    ///   - completion: 播放完成或失败的回调
    public func speak(text: String, language: String = "zh-CN", interrupt: Bool = false, enqueue: Bool = true, completion: SpeakCompletion? = nil) {

        hlttsProbe("speak.request \(probeMetadata(for: text)) interrupt=\(interrupt) enqueue=\(enqueue)")

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

        // 立刻作废待执行的延迟停用（同步，不能等到派发之后，否则会话可能刚被停掉）
        cancelPendingDeactivate()

        // 💡 核心优化：将耗时操作派发到后台队列
        ttsWorkQueue.async { [weak self] in
            guard let self = self else { return }
            hlttsProbe("speak.work.begin \(self.probeMetadata(for: text))")

            // 耗时操作 1: 切换音频会话状态 (Duck)
            startDuckOthers()

            // 耗时操作 2: 创建 Utterance 并查询 Voice
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = self.makeVoice(language: language)

            utterance.rate = self.rate
            utterance.pitchMultiplier = self.pitch
            utterance.volume = self.volume
            let utteranceID = self.probeIdentifier(for: utterance)
            hlttsProbe("speak.work.ready utterance=\(utteranceID) \(self.probeMetadata(for: text))")
            // 💡 切回主线程：操作合成器 (synthesizer) 和处理队列，保障 UI 逻辑的线程安全
            DispatchQueue.main.async {
                // 上一条若已卡死，先把合成器换掉，否则这条会排在它后面永远播不出来
                self.healIfStuck()
                self.completionHandler = currentCompletion
                hlttsProbe("speak.submit utterance=\(utteranceID) isSpeakingBefore=\(self.synthesizer.isSpeaking) pendingBefore=\(self.pendingUtterances.count)")

                if interrupt {
                    // 只有在上一个还在播放时，才调用失败回调
                    if self.synthesizer.isSpeaking, let oldHandler = self.completionHandler {
                        let error = NSError(domain: "HLTTS", code: -3, userInfo: [NSLocalizedDescriptionKey: "播放被新任务打断"])
                        oldHandler(.failure(error))
                        self.delegate?.didUpdateState(.fail(text: self.currentText, error: error))
                        self.stateCallback?(.fail(text: self.currentText, error: error))
                        self.completionHandler = nil
                    }

                    self.pendingUtterances.removeAll()
                    self.stop()
                    self.currentText = text
                    self.pendingUtterances.append(utterance)
                    self.synthesizer.speak(utterance)
                } else if !enqueue && self.synthesizer.isSpeaking {
                    // enqueue == false 的语义是"正在播就丢弃"（当前无调用方使用）
                    hlttsProbe("speak.drop utterance=\(utteranceID) reason=busyAndEnqueueDisabled")
                } else {
                    // 直接交给合成器。AVSpeechSynthesizer 自带 FIFO 内部队列，
                    // 连续 speak 多次它会自己按序播完。
                    //
                    // ⚠️ 不要再在 HLTTS 里维护第二个队列、并在 didFinish 回调里 speak 下一条。
                    // 真机实测（2026-08-11）：didFinish 里对一个内部队列尚未排空的合成器再调
                    // speak()，会让已经播完的 utterance 被重新播放，同一个对象重复 2~3 次
                    // （日志里 obj 地址完全相同）。这正是"公里播报/暂停继续念好几遍"的根因。
                    self.currentText = text
                    self.pendingUtterances.append(utterance)
                    self.synthesizer.speak(utterance)
                }
            }
        }
    }

    /// 暂停
    public func pause() {
        DispatchQueue.main.async {
            self.isPausedByCaller = true   // 挂起看门狗，别把人为暂停当成卡死
            self.synthesizer.pauseSpeaking(at: .immediate)
        }
    }

    /// 继续
    public func resume() {
        DispatchQueue.main.async {
            self.isPausedByCaller = false
            self.synthesizer.continueSpeaking()
            if let resumed = self.speakingUtterance {
                self.startWatchdog(for: resumed)   // 重新计时
            }
        }
    }

    /// 停止
    public func stop() {
        pendingUtterances.removeAll()
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
        guard isCurrent(synthesizer) else { return }
        hlttsProbe("delegate.didStart utterance=\(probeIdentifier(for: utterance)) \(probeMetadata(for: utterance.speechString))")
        startWatchdog(for: utterance)
        delegate?.didStart(text: utterance.speechString)
        delegate?.didUpdateState(.start(text: utterance.speechString))
        stateCallback?(.start(text: utterance.speechString))
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        if isWarmUpSynthesizer(synthesizer) {
            hlttsProbe("preload.delegate.didFinish")
            finishEnginePreload(reason: "delegateDidFinish")
            return
        }
        guard isCurrent(synthesizer) else { return }
        hlttsProbe("delegate.didFinish utterance=\(probeIdentifier(for: utterance)) \(probeMetadata(for: utterance.speechString))")
        cancelWatchdog()
        pendingUtterances.removeAll { $0 === utterance }
        delegate?.didFinish(text: utterance.speechString)
        delegate?.didUpdateState(.finish(text: utterance.speechString))
        stateCallback?(.finish(text: utterance.speechString))
        completionHandler?(.success(utterance.speechString))
        completionHandler = nil
        scheduleDeactivateSession()
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        guard isCurrent(synthesizer) else { return }
        hlttsProbe("delegate.didPause utterance=\(probeIdentifier(for: utterance)) \(probeMetadata(for: utterance.speechString))")
        delegate?.didPause(text: utterance.speechString)
        delegate?.didUpdateState(.pause(text: utterance.speechString))
        stateCallback?(.pause(text: utterance.speechString))
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        guard isCurrent(synthesizer) else { return }
        hlttsProbe("delegate.didContinue utterance=\(probeIdentifier(for: utterance)) \(probeMetadata(for: utterance.speechString))")
        // 播放重新开始，给它一份新的时间预算。
        // 否则中断持续得久一点，刚恢复就会被看门狗按超时判掉
        startWatchdog(for: utterance)
        delegate?.didContinue(text: utterance.speechString)
        delegate?.didUpdateState(.continue(text: utterance.speechString))
        stateCallback?(.continue(text: utterance.speechString))
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        if isWarmUpSynthesizer(synthesizer) {
            hlttsProbe("preload.delegate.didCancel action=failOpen")
            finishEnginePreload(reason: "delegateDidCancelFailOpen")
            return
        }
        guard isCurrent(synthesizer) else { return }
        hlttsProbe("delegate.didCancel utterance=\(probeIdentifier(for: utterance)) \(probeMetadata(for: utterance.speechString))")
        cancelWatchdog()
        pendingUtterances.removeAll { $0 === utterance }
        delegate?.didCancel(text: utterance.speechString)
        let error = NSError(domain: "HLTTS", code: -2, userInfo: [NSLocalizedDescriptionKey: "播放被取消"])
        delegate?.didUpdateState(.cancel(text: utterance.speechString))
        stateCallback?(.cancel(text: utterance.speechString))
        delegate?.didUpdateState(.fail(text: utterance.speechString, error: error))
        stateCallback?(.fail(text: utterance.speechString, error: error))
        completionHandler?(.failure(error))
        completionHandler = nil
        scheduleDeactivateSession()
    }
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard isCurrent(synthesizer) else { return }
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
        // 已经存过音色：同步取用即可。
        // 原实现无论如何都要先枚举一遍全部音色，而枚举与第一条 speak 共用同一条串行队列，
        // 第一条播报因此被排在它后面；且枚举完成前 voiceType 是空 identifier，
        // 会导致首条播报用兜底音色、后续才换成用户音色
        if let saved = UserDefaults.standard.value(forKey: "HLTTSVoiceType") as? String, !saved.isEmpty {
            voiceType = .dynamic(identifier: saved, displayName: "")
            voiceSetupGroup.leave()
            return
        }
        // 从没存过（首次安装）：后台枚举一次并落库
        setupQueue.async {
            let voiceTypes = self.availableVoiceTypes(language: .chinese)
            let identifier: String?
            if let firstVoice = voiceTypes.first {
                switch firstVoice {
                case .dynamic(let id, _), .custom(let id, _):
                    identifier = id
                }
            } else {
                identifier = nil
            }
            DispatchQueue.main.async {
                if let identifier = identifier {
                    UserDefaults.standard.setValue(identifier, forKey: "HLTTSVoiceType")
                    self.voiceType = .dynamic(identifier: identifier, displayName: "")
                }
                self.voiceSetupGroup.leave()
            }
        }
    }
}
