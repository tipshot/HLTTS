//
//  HLTTSTool.swift
//  HLTTS
//
//  Created by RHL on 2025/9/10.
//

import Foundation
import AVFoundation

public extension String {
    /// 将字符串中的特定内容转换为更易读的中文形式：
    /// 1. 四位年份数字（如 "2025"）→ 逐位中文读法（"二零二五"）。
    ///    - 正则规则：(?<![0-9.])\\d{4}(?![0-9.]|km|KM|Km|kM|公里|千米|米|分米|毫米|英里|小时|分|分钟|秒|毫秒)
    ///      - 前置条件：前面不能是数字或小数点，避免将 "2025.6" 的 "2025" 转换。
    ///      - 后置条件：后面不能是数字、小数点或常见单位（km、公里、小时等），避免将 "2025km"、"2025公里" 转换。
    /// 2. 一到三位整数（如 "72"）→ **数量**中文读法（"七十二"）。见 `amountPattern`。
    /// 3. 将连续的 "-" 或 "——" 替换为中文顿号 "、"，用于更符合中文书写习惯。
    ///
    /// 示例：
    /// - "2025中国银行北京马拉松" → "二零二五中国银行北京马拉松"
    /// - "2025km 跑步" → "2025km 跑步"（不转换）
    /// - "2025.6km" → "2025.6km"（不转换）
    /// - "2025-2026" → "二零二五、二零二六"
    /// - "当前心率72" → "当前心率七十二"
    /// - "500米" → "五百米"
    /// - "5.20公里" → "5.20公里"（不转换，见下）
    ///
    /// - Returns: 转换后的中文可读字符串
    func toChineseReadable_HLTTS() -> String {
        // 数字到中文映射
        let numMap: [Character: String] = [
            "0": "零", "1": "一", "2": "二", "3": "三", "4": "四",
            "5": "五", "6": "六", "7": "七", "8": "八", "9": "九"
        ]

        var result = self

        // 匹配四位年份数字并逐位替换
        let yearPattern = "(?<![0-9.])\\d{4}(?![0-9.]|km|KM|Km|kM|公里|千米|米|分米|毫米|英里|小时|分|分钟|秒|毫秒)"
        if let regex = try? NSRegularExpression(pattern: yearPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range, in: result) {
                    let yearStr = String(result[range])
                    let chineseYear = yearStr.compactMap { numMap[$0] }.joined()
                    result.replaceSubrange(range, with: chineseYear)
                }
            }
        }

        // 一到三位整数 → 数量读法。
        //
        // 为什么需要：中文 TTS 判断数字该按「数量」还是「编号」读，靠的是上下文启发式——
        // 后面跟量词才按数量读。「当前心率72」后面光秃秃没有单位，被判成编号式逐位读出
        // 「七二」（2026-08-13 实测）。交给引擎猜不可靠，这里显式转掉。
        //
        // 边界与年份规则用的是同一套 (?<![0-9.]) / (?![0-9.])，两条都不碰小数：
        // 运动播报里的距离是 "5.20公里" 这种形式，一旦被拆就会读成「五点二零公里」，
        // 把本来正常的播报搞坏——这是本规则唯一的回归风险点，务必保留前后两个断言。
        //
        // 只做一到三位：四位及以上交给上面的年份规则（已先执行），四位数字此时要么已被
        // 换成中文、要么是被单位排除掉的（如 "2025公里"），其内部任何子串都不满足边界断言，
        // 不会被本规则误伤。
        let amountPattern = "(?<![0-9.])\\d{1,3}(?![0-9.])"
        if let regex = try? NSRegularExpression(pattern: amountPattern) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                if let range = Range(match.range, in: result),
                   let value = Int(result[range]) {
                    result.replaceSubrange(range, with: Self.chineseAmount_HLTTS(value))
                }
            }
        }

        // 替换 - 和 —— 为 、
        result = result.replacingOccurrences(of: "——", with: "、")
        result = result.replacingOccurrences(of: "-", with: "、")

        return result
    }

    /// 0~999 的中文数量读法。
    ///
    /// 与逐位读法的区别：72 读「七十二」而不是「七二」，105 读「一百零五」而不是「一零五」。
    /// 按中文习惯，10~19 读「十X」而非「一十X」（12 → 十二）。
    private static func chineseAmount_HLTTS(_ n: Int) -> String {
        let d = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]
        guard n >= 0, n <= 999 else { return "\(n)" }

        if n < 10 { return d[n] }
        // 10~19：十、十一 …… 十九（不读「一十二」）
        if n < 20 { return n == 10 ? "十" : "十" + d[n % 10] }
        if n < 100 {
            let tens = n / 10, ones = n % 10
            return d[tens] + "十" + (ones == 0 ? "" : d[ones])
        }
        // 100~999
        let hundreds = n / 100, rest = n % 100
        if rest == 0 { return d[hundreds] + "百" }
        // 个位不为零而十位为零时要补「零」：105 → 一百零五
        if rest < 10 { return d[hundreds] + "百零" + d[rest] }
        let tens = rest / 10, ones = rest % 10
        return d[hundreds] + "百" + d[tens] + "十" + (ones == 0 ? "" : d[ones])
    }
}

/// 播报期间使用的音频会话选项
let hlttsCategoryOptions: AVAudioSession.CategoryOptions = [.duckOthers, .mixWithOthers]

/// 开启 Duck（压低其他 App 音量）
func startDuckOthers() {
    let session = AVAudioSession.sharedInstance()
    do {
        // 幂等：category / options 已经是目标值就不再重设。
        // 重设会触发音频路由重新配置，是播报出声前那几百毫秒延迟的来源之一
        if session.category != .playback || session.categoryOptions != hlttsCategoryOptions {
            try session.setCategory(.playback, options: hlttsCategoryOptions)
        }
        try session.setActive(true)
    } catch {
        print("❌ 设置 Duck 音频会话失败: \(error.localizedDescription)")
    }
}

/// 停止 Duck（恢复其他 App 音量）
/// ⚠️ 这是裸的停用原语，会立刻切断音频通路。
/// 不要在播报结束时直接调用它 —— 走 `HLTTS.scheduleDeactivateSession()` 的延迟停用，
/// 否则连续播报之间会反复停用/激活，下一条的开头会被吞掉。
func stopDuckOthers() {
    let session = AVAudioSession.sharedInstance()
    do {
        try session.setActive(false,
                              options: .notifyOthersOnDeactivation)
    } catch {
        print("❌ 停用 Duck 音频会话失败: \(error.localizedDescription)")
    }
}

