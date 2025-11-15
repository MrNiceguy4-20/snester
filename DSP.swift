import Foundation

class DSP {
    
    var channels: [VoiceChannel] = Array(repeating: VoiceChannel(), count: 8)
    
    var masterVolumeLeft: UInt8 = 0
    var masterVolumeRight: UInt8 = 0
    var echoVolumeLeft: UInt8 = 0
    var echoVolumeRight: UInt8 = 0
    
    private var dspOutput: (left: Float, right: Float) = (0.0, 0.0)
    
    struct VoiceChannel {
        var volumeLeft: UInt8 = 0
        var volumeRight: UInt8 = 0
        var pitch: UInt16 = 0
        var sampleAddress: UInt16 = 0
        var keyOn: Bool = false
        var keyOff: Bool = false
        
        var envVolume: Float = 0.0
        var envelopeStage: EnvelopeStage = .release
        
        var brrDecoderHistory: (prev1: Int16, prev2: Int16) = (0, 0)
        var currentBlockByte: UInt8 = 0
        var sampleIndexInBlock: Int = 0
        var sampleAddressPitchAccumulator: Float = 0.0
        var adsrRegisters: UInt32 = 0
    }
    
    enum EnvelopeStage {
        case attack, decay, sustain, release, wait, manual
    }
    
    func reset() {
        channels = Array(repeating: VoiceChannel(), count: 8)
        masterVolumeLeft = 0
        masterVolumeRight = 0
    }

    func generateSample() -> (left: Float, right: Float) {
        var mixedLeft: Float = 0.0
        var mixedRight: Float = 0.0
        
        for index in 0..<channels.count {
            var channel = channels[index]
            
            if channel.keyOn && channel.envelopeStage == .release {
                channel.envelopeStage = .attack
            }
            if channel.keyOff && channel.envelopeStage != .release {
                channel.envelopeStage = .release
            }
            
            switch channel.envelopeStage {
            case .attack:
                channel.envVolume = min(1.0, channel.envVolume + (1.0 - channel.envVolume) * 0.05)
                if channel.envVolume >= 0.99 { channel.envelopeStage = .decay }
            case .decay:
                channel.envVolume = max(0.6, channel.envVolume - 0.0005)
                if channel.envVolume <= 0.6 { channel.envelopeStage = .sustain }
            case .sustain:
                break
            case .release:
                channel.envVolume = max(0.0, channel.envVolume - 0.002)
            default:
                break
            }
            
            let pitchRatio = Float(channel.pitch) / 4096.0
            channel.sampleAddressPitchAccumulator += pitchRatio
            
            let rawSample: Float = 0.0
            
            let sampleOutput = rawSample * channel.envVolume
            
            mixedLeft += sampleOutput * Float(channel.volumeLeft) / 128.0
            mixedRight += sampleOutput * Float(channel.volumeRight) / 128.0
            
            channels[index] = channel
        }
        
        mixedLeft *= Float(masterVolumeLeft) / 128.0
        mixedRight *= Float(masterVolumeRight) / 128.0
        
        mixedLeft = min(1.0, max(-1.0, mixedLeft))
        mixedRight = min(1.0, max(-1.0, mixedRight))
        
        return (mixedLeft, mixedRight)
    }
}
