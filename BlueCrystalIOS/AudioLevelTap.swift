import Foundation
import AVFoundation
import CoreMedia
import MediaToolbox
import QuartzCore
import os

/// 一个视频音轨的电平计：MTAudioProcessingTap 在实时音频线程上写，主线程每 0.3 秒取走一次。
/// 实时线程上不分配内存、不调 Swift 运行时以外的阻塞接口；两边只在 os_unfair_lock 里交换几个数。
/// 每个视频一个新的电平计：旧播放器的 tap 晚到的回调写不进新视频的窗口
final class AudioLevelMeter {
    /// 跨回调延续分块状态的声道数上限（超出的声道每次回调单独分块、段末收尾，和以前一样）
    static let maxCarryChannels = 8

    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var accumulator = AudioWindowAccumulator()
    /// prepare 回调记下的处理格式；nil = 还没 prepare / 系统给的格式认不出（此时不分析、不输出）
    private var format: AudioSampleFormat?
    /// 每个声道的分块延续状态。只在实时线程（process）上读写；init 时一次分配好，回调里不分配。
    /// 别的线程要清它只在锁里置 carryResetPending，由下一次 process 自己清
    private let carries: UnsafeMutablePointer<AudioBlockCarry>
    private var carryResetPending = false

    /// rhythm-context P3（撞击声相位校正，默认关）：三频带 10 毫秒能量块。关着时实时线程一个样本都不多看。
    /// bands 环形缓冲（锁里读写）由实时线程写、主线程 drainBands 取走；splitter / pendingBands 只在实时线程上用，
    /// 别的线程要清它们只在锁里置 splitterResetPending。全部 init 时一次分配好，回调里不分配
    static let bandCapacity = 1024
    static let pendingCapacity = 128
    private let bands: UnsafeMutablePointer<AudioBandFrame>
    private var bandHead = 0
    private var bandCount = 0
    private var bandsEnabled = false
    private var bandSampleRate: Double = 0
    private var splitterResetPending = true
    private var splitter = AudioBandSplitter()
    private let pendingBands: UnsafeMutablePointer<AudioBandFrame>

    /// av-fusion F0（观测与标定）：每次回调的 host 时间 / 视频时间范围，只在调试记录开着时写（锁里读写；关着时实时线程只多看一个布尔）
    private let timings = AudioTapTimingRing()

    /// av-fusion F1（声音特征，默认关）：6 段 10 毫秒能量 / 1 毫秒峰值帧 + 约 8 kHz 的 PCM，只在「声画融合」开着时算
    /// （关着时实时线程只多看一个布尔）。环形缓冲（锁里读写，满了丢最旧的）由实时线程写、主线程 drainFeatures 取走；
    /// featureSplitter / pending* 只在实时线程上用，别的线程要清它们只在锁里置 featureResetPending。全部 init 时一次分配好
    static let featureCapacity = 512
    static let pcmCapacity = 16384
    static let pendingFeatureCapacity = 32
    static let pendingPCMCapacity = 512
    private let features: UnsafeMutablePointer<AudioFeatureFrame>
    private var featureHead = 0
    private var featureCount = 0
    private let pcm: UnsafeMutablePointer<Float>
    private var pcmHead = 0
    private var pcmCount = 0
    private var featuresEnabled = false
    private var featureResetPending = true
    /// 融合开着时时间范围拿不到（NaN）的回调数，drainFeatures 清零
    private var featureInvalid = 0
    private var featureSplitter = AudioFeatureSplitter()
    private let pendingFeatures: UnsafeMutablePointer<AudioFeatureFrame>
    private let pendingPCM: UnsafeMutablePointer<Float>

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        carries = UnsafeMutablePointer<AudioBlockCarry>.allocate(capacity: Self.maxCarryChannels)
        carries.initialize(repeating: AudioBlockCarry(), count: Self.maxCarryChannels)
        bands = UnsafeMutablePointer<AudioBandFrame>.allocate(capacity: Self.bandCapacity)
        bands.initialize(repeating: AudioBandFrame(), count: Self.bandCapacity)
        pendingBands = UnsafeMutablePointer<AudioBandFrame>.allocate(capacity: Self.pendingCapacity)
        pendingBands.initialize(repeating: AudioBandFrame(), count: Self.pendingCapacity)
        features = UnsafeMutablePointer<AudioFeatureFrame>.allocate(capacity: Self.featureCapacity)
        features.initialize(repeating: AudioFeatureFrame(), count: Self.featureCapacity)
        pcm = UnsafeMutablePointer<Float>.allocate(capacity: Self.pcmCapacity)
        pcm.initialize(repeating: 0, count: Self.pcmCapacity)
        pendingFeatures = UnsafeMutablePointer<AudioFeatureFrame>.allocate(capacity: Self.pendingFeatureCapacity)
        pendingFeatures.initialize(repeating: AudioFeatureFrame(), count: Self.pendingFeatureCapacity)
        pendingPCM = UnsafeMutablePointer<Float>.allocate(capacity: Self.pendingPCMCapacity)
        pendingPCM.initialize(repeating: 0, count: Self.pendingPCMCapacity)
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
        carries.deinitialize(count: Self.maxCarryChannels)
        carries.deallocate()
        bands.deinitialize(count: Self.bandCapacity)
        bands.deallocate()
        pendingBands.deinitialize(count: Self.pendingCapacity)
        pendingBands.deallocate()
        features.deinitialize(count: Self.featureCapacity)
        features.deallocate()
        pcm.deinitialize(count: Self.pcmCapacity)
        pcm.deallocate()
        pendingFeatures.deinitialize(count: Self.pendingFeatureCapacity)
        pendingFeatures.deallocate()
        pendingPCM.deinitialize(count: Self.pendingPCMCapacity)
        pendingPCM.deallocate()
    }

    /// 主线程（rhythm-context P3）：「撞击声相位校正」开着时才分频带。关掉时丢掉没取走的块
    func setBandsEnabled(_ on: Bool) {
        os_unfair_lock_lock(lock)
        if bandsEnabled != on {
            bandsEnabled = on
            bandHead = 0
            bandCount = 0
            splitterResetPending = true
        }
        os_unfair_lock_unlock(lock)
    }

    /// 主线程（av-fusion F1）：频带已经开着、撞击声校正这时才打开（之前是融合在取）——照「从关到开」那样
    /// 丢掉没取走的块、splitter 从头来，校正拿到的块和融合关着时逐位相同。频带关着时什么都不做
    func restartBands() {
        os_unfair_lock_lock(lock)
        if bandsEnabled {
            bandHead = 0
            bandCount = 0
            splitterResetPending = true
        }
        os_unfair_lock_unlock(lock)
    }

    /// 主线程（av-fusion F1）：「声画融合」开着时才算声音特征。切换时丢掉没取走的特征、splitter 从头来
    func setFeaturesEnabled(_ on: Bool) {
        os_unfair_lock_lock(lock)
        if featuresEnabled != on {
            featuresEnabled = on
            clearFeaturesLocked()
        }
        os_unfair_lock_unlock(lock)
    }

    /// 主线程（av-fusion F1）：取走上次以来的特征帧 / PCM（旧 → 新）和时间范围拿不到的回调数
    func drainFeatures() -> AudioFeatureDrain {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        var out = AudioFeatureDrain()
        out.pcmRate = AudioFeatureSplitter.pcmRate(forSampleRate: bandSampleRate)
        out.invalidChunks = featureInvalid
        featureInvalid = 0
        if featureCount > 0 {
            out.frames.reserveCapacity(featureCount)
            let start = (featureHead + Self.featureCapacity - featureCount) % Self.featureCapacity
            for k in 0..<featureCount { out.frames.append(features[(start + k) % Self.featureCapacity]) }
            featureCount = 0
        }
        if pcmCount > 0 {
            out.pcm.reserveCapacity(pcmCount)
            let start = (pcmHead + Self.pcmCapacity - pcmCount) % Self.pcmCapacity
            for k in 0..<pcmCount { out.pcm.append(pcm[(start + k) % Self.pcmCapacity]) }
            pcmCount = 0
        }
        return out
    }

    /// 锁里调：丢掉没取走的特征，splitter 下一次回调从头来
    private func clearFeaturesLocked() {
        featureHead = 0
        featureCount = 0
        pcmHead = 0
        pcmCount = 0
        featureInvalid = 0
        featureResetPending = true
    }

    /// 主线程（av-fusion F0）：调试记录开着时才记回调时间。关掉时丢掉没取走的记录
    func setTimingEnabled(_ on: Bool) {
        os_unfair_lock_lock(lock)
        timings.setEnabled(on)
        os_unfair_lock_unlock(lock)
    }

    /// 主线程（av-fusion F0）：取走上次以来的回调时间记录（旧 → 新）和时间范围有效 / 无效的回调数
    func drainTapTimings() -> (timings: [AudioTapTiming], valid: Int, invalid: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return timings.drain()
    }

    /// 主线程：取走上次以来的频带能量块（时间 = 视频时间，秒），按时间先后
    func drainBands() -> [AudioBandFrame] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard bandCount > 0 else { return [] }
        var out: [AudioBandFrame] = []
        out.reserveCapacity(bandCount)
        let start = (bandHead + Self.bandCapacity - bandCount) % Self.bandCapacity
        for k in 0..<bandCount { out.append(bands[(start + k) % Self.bandCapacity]) }
        bandCount = 0
        return out
    }

    /// 取走上次以来的窗口并清零（主线程）
    func drain() -> AudioWindow {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return accumulator.drain()
    }

    /// 丢掉还没取走的数据（开始播放 / seek 时：不让旧位置的声音算进新窗口）
    func reset() {
        os_unfair_lock_lock(lock)
        accumulator = AudioWindowAccumulator()
        // 跳转前没满的块 / 上一块电平不带到新位置
        carryResetPending = true
        bandHead = 0
        bandCount = 0
        splitterResetPending = true
        clearFeaturesLocked()
        timings.clear()
        os_unfair_lock_unlock(lock)
    }

    fileprivate func prepare(_ asbd: AudioStreamBasicDescription) {
        let f = AudioSampleFormat.resolve(formatID: UInt32(asbd.mFormatID), flags: UInt32(asbd.mFormatFlags),
                                          bitsPerChannel: UInt32(asbd.mBitsPerChannel))
        os_unfair_lock_lock(lock)
        format = f
        accumulator = AudioWindowAccumulator()
        carryResetPending = true
        bandSampleRate = Double(asbd.mSampleRate)
        bandHead = 0
        bandCount = 0
        splitterResetPending = true
        clearFeaturesLocked()
        timings.clear()
        os_unfair_lock_unlock(lock)
    }

    fileprivate func unprepare() {
        os_unfair_lock_lock(lock)
        format = nil
        os_unfair_lock_unlock(lock)
    }

    /// 实时线程：交错 / 非交错都按每个 AudioBuffer 自己的声道数走；多声道取最响的那个
    /// start：这段第一个样本的视频时间（秒；拿不到是 NaN，此时不出频带块）
    fileprivate func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double = .nan) {
        os_unfair_lock_lock(lock)
        let current = format
        let resetCarries = carryResetPending
        carryResetPending = false
        let bandsOn = bandsEnabled
        let resetSplitter = splitterResetPending
        splitterResetPending = false
        let rate = bandSampleRate
        let featuresOn = featuresEnabled
        let resetFeatures = featureResetPending
        featureResetPending = false
        if featuresOn, !start.isFinite { featureInvalid += 1 }
        // av-fusion F0：调试记录开着才记（固定容量环形缓冲，不分配；CACurrentMediaTime 不阻塞）
        if timings.enabled { timings.record(AudioTapTiming(host: CACurrentMediaTime(), itemStart: start, frames: frames)) }
        os_unfair_lock_unlock(lock)
        if resetCarries {
            for i in 0..<Self.maxCarryChannels { carries[i] = AudioBlockCarry() }
        }
        if resetSplitter { splitter.configure(sampleRate: rate) }
        if resetFeatures { featureSplitter.configure(sampleRate: rate) }
        guard let f = current, frames > 0 else { return }
        if bandsOn { splitBands(list, frames: frames, format: f, start: start) }
        if featuresOn { splitFeatures(list, frames: frames, format: f, start: start) }
        var chunkPeakToPeak = 0.0
        var chunkMeanSquare = 0.0
        var chunkFrames = 0
        var chunkBlocks = AudioBlockStats()
        // 声道序号跨 AudioBuffer 连续编号（非交错时一个 buffer 一个声道），用来找这个声道的分块延续状态
        var channelBase = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            let channels = max(1, Int(buffer.mNumberChannels))
            defer { channelBase += channels }
            guard let data = buffer.mData else { continue }
            let n = min(frames, Int(buffer.mDataByteSize) / (f.bytesPerSample * channels))
            guard n > 0 else { continue }
            for ch in 0..<channels {
                let slot = channelBase + ch
                let carried = slot < Self.maxCarryChannels
                let stats = Self.channelStats(data, format: f, frames: n, channels: channels, channel: ch,
                                              carry: carried ? carries[slot] : nil)
                if carried { carries[slot] = stats.carry }
                chunkPeakToPeak = max(chunkPeakToPeak, stats.peakToPeak)
                // 块电平取最响那个声道的（同 meanSquare 的选法）
                if stats.meanSquare >= chunkMeanSquare { chunkBlocks = stats.blocks }
                chunkMeanSquare = max(chunkMeanSquare, stats.meanSquare)
            }
            chunkFrames = max(chunkFrames, n)
        }
        guard chunkFrames > 0 else { return }
        os_unfair_lock_lock(lock)
        accumulator.add(peakToPeak: chunkPeakToPeak, meanSquare: chunkMeanSquare, frames: chunkFrames, blocks: chunkBlocks)
        os_unfair_lock_unlock(lock)
    }

    /// 实时线程（rhythm-context P3）：第一个 AudioBuffer 的第 0 声道 → 三频带 10 毫秒块 → 环形缓冲
    private func splitBands(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, format f: AudioSampleFormat,
                            start: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count > 0 else { return }
        let buffer = buffers[0]
        let channels = max(1, Int(buffer.mNumberChannels))
        guard let data = buffer.mData else { return }
        let n = min(frames, Int(buffer.mDataByteSize) / (f.bytesPerSample * channels))
        guard n > 0 else { return }
        var local = splitter
        let sr = local.sampleRate
        guard sr > 0 else { return }
        local.begin(start: start, frames: n)
        let scale = f.scale
        var pending = 0
        for i in 0..<n {
            let x: Double
            switch f {
            case .float32: x = Double(data.assumingMemoryBound(to: Float32.self)[i * channels])
            case .float64: x = data.assumingMemoryBound(to: Float64.self)[i * channels]
            case .int16: x = Double(data.assumingMemoryBound(to: Int16.self)[i * channels]) * scale
            case .int32: x = Double(data.assumingMemoryBound(to: Int32.self)[i * channels]) * scale
            }
            if let block = local.add(x, at: start + Double(i) / sr) {
                pendingBands[pending] = block
                pending += 1
                if pending == Self.pendingCapacity {
                    pushBands(pending)
                    pending = 0
                }
            }
        }
        splitter = local
        if pending > 0 { pushBands(pending) }
    }

    /// 实时线程：pendingBands 前 count 个写进环形缓冲（满了丢最旧的）
    private func pushBands(_ count: Int) {
        os_unfair_lock_lock(lock)
        if bandsEnabled {
            for k in 0..<count {
                bands[bandHead] = pendingBands[k]
                bandHead = (bandHead + 1) % Self.bandCapacity
                bandCount = min(Self.bandCapacity, bandCount + 1)
            }
        }
        os_unfair_lock_unlock(lock)
    }

    /// 实时线程（av-fusion F1）：第一个 AudioBuffer 的第 0 声道 → 6 段特征帧 + 降采样 PCM → 环形缓冲（和 splitBands 同一个声道）
    private func splitFeatures(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, format f: AudioSampleFormat,
                               start: Double) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        guard buffers.count > 0 else { return }
        let buffer = buffers[0]
        let channels = max(1, Int(buffer.mNumberChannels))
        guard let data = buffer.mData else { return }
        let n = min(frames, Int(buffer.mDataByteSize) / (f.bytesPerSample * channels))
        guard n > 0 else { return }
        var local = featureSplitter
        guard local.sampleRate > 0 else { return }
        local.begin(start: start, frames: n)
        let scale = f.scale
        var pendingFrames = 0
        var pendingSamples = 0
        var frame = AudioFeatureFrame()
        var sample: Float = 0
        for i in 0..<n {
            let x: Double
            switch f {
            case .float32: x = Double(data.assumingMemoryBound(to: Float32.self)[i * channels])
            case .float64: x = data.assumingMemoryBound(to: Float64.self)[i * channels]
            case .int16: x = Double(data.assumingMemoryBound(to: Int16.self)[i * channels]) * scale
            case .int32: x = Double(data.assumingMemoryBound(to: Int32.self)[i * channels]) * scale
            }
            let flags = local.add(x, frame: &frame, pcm: &sample)
            if flags & AudioFeatureSplitter.frameReady != 0 {
                pendingFeatures[pendingFrames] = frame
                pendingFrames += 1
            }
            if flags & AudioFeatureSplitter.pcmReady != 0 {
                pendingPCM[pendingSamples] = sample
                pendingSamples += 1
            }
            if pendingFrames == Self.pendingFeatureCapacity || pendingSamples == Self.pendingPCMCapacity {
                pushFeatures(frames: pendingFrames, samples: pendingSamples)
                pendingFrames = 0
                pendingSamples = 0
            }
        }
        featureSplitter = local
        if pendingFrames > 0 || pendingSamples > 0 { pushFeatures(frames: pendingFrames, samples: pendingSamples) }
    }

    /// 实时线程（av-fusion F1）：pending 的特征帧 / PCM 写进环形缓冲（满了丢最旧的；融合这时已经关了就不写）
    private func pushFeatures(frames: Int, samples: Int) {
        os_unfair_lock_lock(lock)
        if featuresEnabled {
            for k in 0..<frames {
                features[featureHead] = pendingFeatures[k]
                featureHead = (featureHead + 1) % Self.featureCapacity
                featureCount = min(Self.featureCapacity, featureCount + 1)
            }
            for k in 0..<samples {
                pcm[pcmHead] = pendingPCM[k]
                pcmHead = (pcmHead + 1) % Self.pcmCapacity
                pcmCount = min(Self.pcmCapacity, pcmCount + 1)
            }
        }
        os_unfair_lock_unlock(lock)
    }

    /// carry 不为 nil：接着这个声道上一次回调的分块往下分，没满的块留给下一次（不收尾）；
    /// nil（声道太多）：这一段单独分块、段末收尾
    private static func channelStats(_ data: UnsafeMutableRawPointer, format f: AudioSampleFormat,
                                     frames n: Int, channels: Int, channel ch: Int,
                                     carry: AudioBlockCarry?) -> AudioChannelStats {
        var s: AudioChannelStats
        if let c = carry {
            s = AudioChannelStats(carry: c)
        } else {
            s = AudioChannelStats()
        }
        let scale = f.scale
        switch f {
        case .float32:
            let p = data.assumingMemoryBound(to: Float32.self)
            for i in 0..<n { s.add(Double(p[i * channels + ch])) }
        case .float64:
            let p = data.assumingMemoryBound(to: Float64.self)
            for i in 0..<n { s.add(p[i * channels + ch]) }
        case .int16:
            let p = data.assumingMemoryBound(to: Int16.self)
            for i in 0..<n { s.add(Double(p[i * channels + ch]) * scale) }
        case .int32:
            let p = data.assumingMemoryBound(to: Int32.self)
            for i in 0..<n { s.add(Double(p[i * channels + ch]) * scale) }
        }
        if carry == nil { s.finish() }
        return s
    }
}

/// 给 AVPlayerItem 的第一条音轨挂一个只读的 MTAudioProcessingTap（本地文件可靠；不改声音，只看样本）
enum AudioLevelTap {
    enum Status: Equatable {
        case none
        case loading
        case ready
        case noAudio
        case failed(String)
    }

    /// completion 在主线程回调。调用方负责核对 item 还是不是当前播放的那个
    static func install(on item: AVPlayerItem, asset: AVAsset, meter: AudioLevelMeter,
                        completion: @escaping (Status) -> Void) {
        asset.loadTracks(withMediaType: .audio) { [weak item] tracks, error in
            let track = tracks?.first
            let reason = error?.localizedDescription
            DispatchQueue.main.async { [weak item] in
                guard let item = item else { return }
                guard let track = track else {
                    completion(reason.map { Status.failed($0) } ?? Status.noAudio)
                    return
                }
                guard let tap = AudioLevelTap.makeTap(meter: meter) else {
                    completion(.failed("无法创建音频分析"))
                    return
                }
                let params = AVMutableAudioMixInputParameters(track: track)
                params.audioTapProcessor = tap
                let mix = AVMutableAudioMix()
                mix.inputParameters = [params]
                item.audioMix = mix
                completion(.ready)
            }
        }
    }

    /// tap 的 storage 持有电平计一次（init 时 passRetained，finalize 时 release，系统保证两者成对）
    private static func makeTap(meter: AudioLevelMeter) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(meter).toOpaque(),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, processingFormat in
                Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(processingFormat.pointee)
            },
            unprepare: { tap in
                Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().unprepare()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                // rhythm-context P3：顺便要这段声音的视频时间范围（撞击声对时间用；拿不到就是 NaN，不出频带块）
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                                flagsOut, &range, numberFramesOut)
                guard status == noErr else {
                    numberFramesOut.pointee = 0
                    return
                }
                let start = range.start.isValid && range.start.isNumeric ? CMTimeGetSeconds(range.start) : Double.nan
                Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().process(bufferListInOut, frames: Int(numberFramesOut.pointee), start: start)
            })
        // Xcode 16 SDK 里输出参数是 Unmanaged（+1 引用）：成功后 takeRetainedValue 交给 ARC
        var tap: Unmanaged<MTAudioProcessingTap>?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                kMTAudioProcessingTapCreationFlag_PreEffects,
                                                &tap)
        // 创建失败时 init 是否已经跑过无法确定：宁可漏掉这一个小对象，也不冒重复 release 的险
        guard status == noErr, let created = tap else { return nil }
        return created.takeRetainedValue()
    }
}
