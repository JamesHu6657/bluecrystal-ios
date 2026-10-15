import Foundation
import AVFoundation
import MediaToolbox
import os

/// 一个视频音轨的电平计：MTAudioProcessingTap 在实时音频线程上写，主线程每 0.3 秒取走一次。
/// 实时线程上不分配内存、不调 Swift 运行时以外的阻塞接口；两边只在 os_unfair_lock 里交换几个数。
/// 每个视频一个新的电平计：旧播放器的 tap 晚到的回调写不进新视频的窗口
final class AudioLevelMeter {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var accumulator = AudioWindowAccumulator()
    /// prepare 回调记下的处理格式；nil = 还没 prepare / 系统给的格式认不出（此时不分析、不输出）
    private var format: AudioSampleFormat?

    init() {
        lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
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
        os_unfair_lock_unlock(lock)
    }

    fileprivate func prepare(_ asbd: AudioStreamBasicDescription) {
        let f = AudioSampleFormat.resolve(formatID: UInt32(asbd.mFormatID), flags: UInt32(asbd.mFormatFlags),
                                          bitsPerChannel: UInt32(asbd.mBitsPerChannel))
        os_unfair_lock_lock(lock)
        format = f
        accumulator = AudioWindowAccumulator()
        os_unfair_lock_unlock(lock)
    }

    fileprivate func unprepare() {
        os_unfair_lock_lock(lock)
        format = nil
        os_unfair_lock_unlock(lock)
    }

    /// 实时线程：交错 / 非交错都按每个 AudioBuffer 自己的声道数走；多声道取最响的那个
    fileprivate func process(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        os_unfair_lock_lock(lock)
        let current = format
        os_unfair_lock_unlock(lock)
        guard let f = current, frames > 0 else { return }
        var chunkPeakToPeak = 0.0
        var chunkMeanSquare = 0.0
        var chunkFrames = 0
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let n = min(frames, Int(buffer.mDataByteSize) / (f.bytesPerSample * channels))
            guard n > 0 else { continue }
            for ch in 0..<channels {
                let stats = Self.channelStats(data, format: f, frames: n, channels: channels, channel: ch)
                chunkPeakToPeak = max(chunkPeakToPeak, stats.peakToPeak)
                chunkMeanSquare = max(chunkMeanSquare, stats.meanSquare)
            }
            chunkFrames = max(chunkFrames, n)
        }
        guard chunkFrames > 0 else { return }
        os_unfair_lock_lock(lock)
        accumulator.add(peakToPeak: chunkPeakToPeak, meanSquare: chunkMeanSquare, frames: chunkFrames)
        os_unfair_lock_unlock(lock)
    }

    private static func channelStats(_ data: UnsafeMutableRawPointer, format f: AudioSampleFormat,
                                     frames n: Int, channels: Int, channel ch: Int) -> AudioChannelStats {
        var s = AudioChannelStats()
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
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut,
                                                                flagsOut, nil, numberFramesOut)
                guard status == noErr else {
                    numberFramesOut.pointee = 0
                    return
                }
                Unmanaged<AudioLevelMeter>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().process(bufferListInOut, frames: Int(numberFramesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                                                MTAudioProcessingTapCreationFlags(kMTAudioProcessingTapCreationFlag_PreEffects),
                                                &tap)
        // 创建失败时 init 是否已经跑过无法确定：宁可漏掉这一个小对象，也不冒重复 release 的险
        guard status == noErr, let created = tap else { return nil }
        return created
    }
}
