import Foundation

/// PCM 音频的纯函数工具（脱机可测，不碰 IO / 不碰模型）。
///
/// 存在的理由：**送音频出去的形态由领域决定，不由某个 Adapter 决定**。
/// 之前只有 `WhisperASRAdapter` 自己会封 WAV，第二个需要发音频的适配器
/// （云端发音评测）就只能复制一遍——两份实现在「位深 / 字节序 / 头长度」
/// 上任何一处走偏，都会表现成「服务端说音频格式不对」，而错误信息完全指不到根因。
public enum AudioPCM {

    /// 单声道 16bit PCM WAV 封装。
    ///
    /// - Parameters:
    ///   - samples: 归一化到 −1...1 的浮点采样（超出范围的会被夹紧）。
    ///   - sampleRate: 采样率（Hz）。麦克风链路固定 16k，云端发音评测也认这个值。
    public static func wav16(samples: [Float], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(contentsOf: littleEndian(UInt32(36 + dataSize)))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.append(contentsOf: littleEndian(UInt32(16)))            // fmt chunk size
        data.append(contentsOf: littleEndian(UInt16(1)))             // PCM
        data.append(contentsOf: littleEndian(UInt16(1)))             // 单声道
        data.append(contentsOf: littleEndian(UInt32(sampleRate)))
        data.append(contentsOf: littleEndian(UInt32(sampleRate * bytesPerSample)))  // byte rate
        data.append(contentsOf: littleEndian(UInt16(bytesPerSample)))               // block align
        data.append(contentsOf: littleEndian(UInt16(16)))            // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(contentsOf: littleEndian(UInt32(dataSize)))
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            data.append(contentsOf: littleEndian(Int16(clamped * 32767)))
        }
        return data
    }

    /// 一段静音（用于连通性探测：只为让服务端确认「认证 + 端点 + 音频格式」都对）。
    public static func silence(seconds: Double, sampleRate: Int) -> [Float] {
        Array(repeating: 0, count: max(Int(seconds * Double(sampleRate)), 0))
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
        var v = value.littleEndian
        return withUnsafeBytes(of: &v) { Array($0) }
    }
}
