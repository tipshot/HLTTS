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
    /// 1. 检测文本中的四位年份数字（如 "2025"），并将其转换为中文数字读法（"二零二五"）。
    ///    - 正则规则：(?<![0-9.])\\d{4}(?![0-9.]|km|KM|Km|kM|公里|千米|米|分米|毫米|英里|小时|分|分钟|秒|毫秒)
    ///      - 前置条件：前面不能是数字或小数点，避免将 "2025.6" 的 "2025" 转换。
    ///      - 后置条件：后面不能是数字、小数点或常见单位（km、公里、小时等），避免将 "2025km"、"2025公里" 转换。
    /// 2. 将连续的 "-" 或 "——" 替换为中文顿号 "、"，用于更符合中文书写习惯。
    ///
    /// 示例：
    /// - "2025中国银行北京马拉松" → "二零二五中国银行北京马拉松"
    /// - "2025km 跑步" → "2025km 跑步"（不转换）
    /// - "2025.6km" → "2025.6km"（不转换）
    /// - "2025-2026" → "二零二五、二零二六"
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
        
        // 替换 - 和 —— 为 、
        result = result.replacingOccurrences(of: "——", with: "、")
        result = result.replacingOccurrences(of: "-", with: "、")
        
        return result
    }
}

/// 开启 Duck（压低其他 App 音量）
func startDuckOthers() {
    let session = AVAudioSession.sharedInstance()
    do {
        try session.setCategory(.playback,
                                options: [.duckOthers, .mixWithOthers])
        try session.setActive(true)
    } catch {
        print("❌ 设置 Duck 音频会话失败: \(error.localizedDescription)")
    }
}

/// 停止 Duck（恢复其他 App 音量）
func stopDuckOthers() {
    let session = AVAudioSession.sharedInstance()
    do {
        try session.setActive(false,
                              options: .notifyOthersOnDeactivation)
    } catch {
        print("❌ 停用 Duck 音频会话失败: \(error.localizedDescription)")
    }
}

