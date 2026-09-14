import Foundation

/// 朗读文本的字符级清洗（纯函数）。
///
/// 存在的理由：老师的话里常带 emoji 与装饰符号（🌿 ✅ 😄 1️⃣ …），它们在**文字气泡里是有意义的**
/// （语气、表情、打勾），但送去合成时会被念成奇怪的词或吐出莫名音效。
/// 所以处理方式是「只在朗读这一侧去掉」，正文一个字不动 —— 而不是让模型别写 emoji
/// （那会把界面上该有的语气标记一起删掉，属于拿视觉换听觉）。
///
/// 与 `VoiceService.cleanForSpeech` 的分工：那边管**结构**（校正块、markdown 记号、长度上限），
/// 这边只管**字符**（哪些码位根本不该被念出来）。
public enum SpeechTextSanitizer {

    /// 去掉朗读不该发出的字符，并把因此产生的多余空格收成一格。
    public static func strip(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        kept.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars where isSpeakable(scalar) {
            kept.append(scalar)
        }
        return collapseSpaces(String(kept))
    }

    /// 这个码位该不该被念出来。
    ///
    /// 判据是 Unicode 自己的属性，不手写 emoji 码表（码表会过期，属性不会）：
    /// - `isEmojiPresentation`：默认就画成彩色的那些（🌿 ✅ 😄）→ 不去念；
    /// - `isEmoji && !isASCII`：能变 emoji 写法的非 ASCII 符号（© ® ™ ‼ ▶）→ 也去掉，
    ///   它们语音上都没有内容。**ASCII 必须放过** —— 数字 0-9 的 `isEmoji` 也是 true，
    ///   一刀切会把「I have 2 cats」念成「I have cats」。
    /// - 另外几类是 emoji 的**组成部分**，单独的属性判断抓不到：零宽连接符（家庭 emoji 靠它粘合）、
    ///   变体选择符（`❤️` 的彩色尾巴）、键帽组合符（`1️⃣` 的头）、肤色修饰符、国旗用的区域指示符。
    public static func isSpeakable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isEmojiPresentation { return false }
        if scalar.properties.isEmoji && !scalar.isASCII { return false }
        return !isEmojiDecoration(scalar)
    }

    /// emoji 的「零件」：单独看不像 emoji，但留着会让合成器读出碎音。
    private static func isEmojiDecoration(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200D:             // 零宽连接符
            return true
        case 0xFE0E, 0xFE0F:     // 文本 / emoji 变体选择符
            return true
        case 0x20E3:             // 键帽组合符（1️⃣ 的尾巴）
            return true
        case 0x1F3FB...0x1F3FF:  // 肤色修饰符
            return true
        case 0x1F1E6...0x1F1FF:  // 区域指示符（国旗由两个拼成）
            return true
        default:
            return false
        }
    }

    /// 把连续空格/制表收成一格，并去掉首尾空白。
    ///
    /// 去掉一个 emoji 会在原位置留下两个空格（`Hello 🌿 world`），不收掉的话
    /// 某些合成器会在这类空隙处停顿，听起来像断了一拍。
    public static func collapseSpaces(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        result.reserveCapacity(text.count)
        for character in text {
            guard character == " " || character == "\t" else {
                if pendingSpace, !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.append(character)
                continue
            }
            if !result.isEmpty { pendingSpace = true }
        }
        return result
    }
}
