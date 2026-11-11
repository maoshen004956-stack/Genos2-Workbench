import Foundation
import AVFoundation
import AudioToolbox

/// Realtime GM SoundFont playback. Every state-changing operation shares the render lock.
/// `duration` includes four seconds of release; `musicDuration` is the editable musical timeline.
final class FluidAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    private var deviceObserver: NSObjectProtocol?
    private let state: FluidPlaybackState
    private let lock = NSLock()
    private var source: AVAudioSourceNode?
    private var playing = false
    private var stopped = false
    private var failure: String?

    init(arrangement: ArrangementResult, soundFont: URL, library: URL,
         mix: [AccompanimentPart: PartMix] = [:], masterGain: Double = 0.8) throws {
        state = try FluidPlaybackState(arrangement: arrangement, soundFont: soundFont, library: library,
                                      mix: mix, masterGain: masterGain)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let source = AVAudioSourceNode(format: format) { [weak self] silence, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let self else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return noErr
            }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.playing, !self.stopped, buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return noErr
            }
            do {
                try self.state.render(left: left, right: right, frames: Int(frameCount))
                silence.pointee = false
                if self.state.cursor >= self.state.totalFrames { self.playing = false }
                return noErr
            } catch {
                self.failure = error.localizedDescription
                self.playing = false
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                silence.pointee = true
                return noErr
            }
        }
        self.source = source
        engine.attach(source)
        engine.attach(limiter)
        engine.connect(source, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.05, 0)
        AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
        engine.prepare()
        deviceObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock {
                if !self.stopped {
                    self.playing = false
                    self.failure = "音频输出设备已改变，请重新开始试听。"
                }
            }
        }
    }

    deinit {
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        engine.stop()
    }

    var position: Double { lock.withLock { Double(state.cursor) / 48_000 } }
    var duration: Double { Double(state.totalFrames) / 48_000 }
    var musicDuration: Double { Double(state.musicFrames) / 48_000 }
    var isPlaying: Bool { lock.withLock { playing } }
    var errorMessage: String? { lock.withLock { failure } }

    func play() throws {
        try lock.withLock {
            guard failure == nil else { throw invalid(failure!) }
            if stopped || state.cursor >= state.totalFrames { try state.seek(to: 0) }
            stopped = false
            playing = true
        }
        do { if !engine.isRunning { try engine.start() } }
        catch {
            lock.withLock { playing = false }
            throw error
        }
    }

    func pause() { lock.withLock { playing = false } }

    func stop() {
        lock.withLock { playing = false; stopped = true }
        engine.stop()
    }

    func seek(to seconds: Double) {
        lock.withLock {
            do { try state.seek(to: seconds); stopped = false }
            catch { failure = error.localizedDescription; playing = false }
        }
    }

    func setMix(_ mix: PartMix, for part: AccompanimentPart) {
        lock.withLock {
            do { try state.session.setMix(mix, for: part) }
            catch { failure = error.localizedDescription; playing = false }
        }
    }

    func setMutedParts(_ parts: Set<AccompanimentPart>) { lock.withLock { state.session.setMutedParts(parts) } }

    func setMasterGain(_ gain: Double) {
        guard gain.isFinite else { return }
        lock.withLock { state.session.api.setGain(state.session.synth, Float(2 * max(0, min(1, gain)))) }
    }
}
