import Foundation
import AVFoundation

class AudioEngine {
    
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    private let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    
    init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: audioFormat)
        
        // Asynchronously start the engine for non-blocking initialization
        Task {
            do {
                try engine.start()
            } catch {
                print("Failed to start audio engine: \(error)")
            }
        }
    }
    
    func start() {
        // Ensure the player is playing to consume scheduled buffers
        if !playerNode.isPlaying {
            playerNode.play()
        }
    }
    
    func stop() {
        playerNode.pause()
    }
    
    func play(buffer: [Float]) {
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(buffer.count / 2)) else {
            return
        }
        
        pcmBuffer.frameLength = pcmBuffer.frameCapacity
        let leftChannel = pcmBuffer.floatChannelData![0]
        let rightChannel = pcmBuffer.floatChannelData![1]
        
        for i in 0..<Int(pcmBuffer.frameLength) {
            // Check array bounds during copying just in case
            guard i * 2 + 1 < buffer.count else { break }
            leftChannel[i] = buffer[i * 2]
            rightChannel[i] = buffer[i * 2 + 1]
        }
        
        // Schedule buffer for playback
        playerNode.scheduleBuffer(pcmBuffer)
    }
}
