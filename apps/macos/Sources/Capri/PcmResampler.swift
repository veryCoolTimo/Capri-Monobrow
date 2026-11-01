import AVFoundation

/// Любой формат микрофона (24/44.1/48 кГц, моно/стерео, Float32/Int16, interleaved или нет) → 16 кГц mono Float32
/// для `capri-asr`. Один экземпляр на поток (держит хвост фильтра между кусками); формат сменился посреди фразы
/// (AirPods перешли в гарнитуру) — конвертер пересоздаётся, а не ломается. Только на одной очереди.
final class PcmResampler {
    static let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    /// Сколько кадров пришло и ушло (для журнала: «48000 Гц 1 кан → 3.1 с»).
    private(set) var inFrames = 0
    private(set) var outFrames = 0
    private(set) var formatChanges = 0
    var sourceFormat: AVAudioFormat? { source }

    /// Кусок звука → 16 кГц. Пусто — нечего отдать (или формат не годится).
    func convert(_ buf: AVAudioPCMBuffer) -> [Float] {
        guard buf.frameLength > 0, buf.format.sampleRate > 0, buf.format.channelCount > 0 else { return [] }
        var tail: [Float] = []
        if source.map({ !$0.isEqual(buf.format) }) ?? true {
            // Формат сменился посреди фразы: сначала дослать хвост фильтра старого конвертера.
            if source != nil { formatChanges += 1; tail = flush() }
            source = buf.format
            converter = AVAudioConverter(from: buf.format, to: Self.target)
            // Стерео и больше — среднее каналов (по умолчанию конвертер взял бы только первый).
            converter?.downmix = true
            converter?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let conv = converter else { return tail }
        inFrames += Int(buf.frameLength)
        return tail + run(conv, input: buf, final: false)
    }

    /// Конец фразы: дослать хвост фильтра (несколько мс) и начать заново.
    func flush() -> [Float] {
        guard let conv = converter else { return [] }
        let out = run(conv, input: nil, final: true)
        conv.reset()
        return out
    }

    private func run(_ conv: AVAudioConverter, input: AVAudioPCMBuffer?, final: Bool) -> [Float] {
        let ratio = Self.target.sampleRate / conv.inputFormat.sampleRate
        let frames = Double(input?.frameLength ?? 0) * ratio
        var out: [Float] = []
        var fed = false
        // Хвост фильтра может не влезть в один буфер — крутим, пока конвертер отдаёт.
        for _ in 0..<8 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: Self.target, frameCapacity: AVAudioFrameCount(frames) + 512) else { break }
            var err: NSError?
            let status = conv.convert(to: buf, error: &err) { _, st in
                if let input, !fed {
                    fed = true
                    st.pointee = .haveData
                    return input
                }
                st.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            if err != nil || status == .error { break }
            if let ch = buf.floatChannelData, buf.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: Int(buf.frameLength)))
            }
            // Отдал меньше, чем помещалось, или больше нечего — всё.
            if status != .haveData || buf.frameLength < buf.frameCapacity { break }
        }
        outFrames += out.count
        return out
    }
}
