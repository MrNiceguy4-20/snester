import Foundation
import Foundation

class DMA {
    
    struct Channel {
        var direction: UInt8 = 0
        var transferMode: UInt8 = 0
        var fixed: Bool = false
        var wordSize: Bool = false
        var isRepeating: Bool = false
        var enabled: Bool = false
        var hdmaActive: Bool = false
        
        var bBusAddress: UInt16 = 0
        var aBusAddress: UInt16 = 0
        var aBusBank: UInt8 = 0
        var transferSize: UInt16 = 0
        var hdmaAddress: UInt16 = 0
        
        var currentTransferSize: UInt16 = 0
        var currentAAddress: UInt16 = 0
        
        var hdmaTableAddress: UInt16 = 0
        var hdmaLineCounter: UInt8 = 0
        var hdmaDeferredTransfer: UInt8 = 0
    }
    
    var channels: [Channel] = Array(repeating: Channel(), count: 8)
    
    weak var memory: MemoryBus?
    weak var ppu: PPU?
    
    var transferEnable: UInt8 = 0
    var hdmaEnable: UInt8 = 0
    
    var isTransferActive: Bool {
        return transferEnable != 0
    }
    
    func readDMAStatus() -> UInt8 {
        return transferEnable
    }
    
    func startTransfer(data: UInt8) {
        transferEnable = data
        for i in 0..<8 {
            if (data & (1 << i)) != 0 {
                channels[i].currentTransferSize = channels[i].transferSize
                channels[i].currentAAddress = channels[i].aBusAddress
                channels[i].enabled = true
            }
        }
    }
    
    func writeRegister(addr: UInt16, data: UInt8) {
        let channelIndex = Int((addr & 0x70) >> 4)
        let registerIndex = Int(addr & 0x0F)
        
        guard channelIndex < 8 else { return }
        
        var channel = channels[channelIndex]
        
        switch registerIndex {
        case 0:
            channel.direction = (data >> 7) & 1
            channel.transferMode = (data >> 4) & 0x07
            channel.fixed = (data & 0x08) != 0
            channel.wordSize = (data & 0x04) != 0
            channel.isRepeating = (data & 0x02) != 0
        case 1:
            channel.bBusAddress = UInt16(data)
        case 2:
            channel.aBusAddress = (channel.aBusAddress & 0xFF00) | UInt16(data)
        case 3:
            channel.aBusAddress = (channel.aBusAddress & 0x00FF) | (UInt16(data) << 8)
        case 4:
            channel.aBusBank = data
        case 5:
            channel.transferSize = (channel.transferSize & 0xFF00) | UInt16(data)
        case 6:
            channel.transferSize = (channel.transferSize & 0x00FF) | (UInt16(data) << 8)
        case 7:
            channel.hdmaAddress = (channel.hdmaAddress & 0xFF00) | UInt16(data)
        case 8:
            channel.hdmaAddress = (channel.hdmaAddress & 0x00FF) | (UInt16(data) << 8)
        default:
            break
        }
        
        channels[channelIndex] = channel
    }
    
    func performTransferBlock(channelIndex: Int, channel: inout Channel) -> Int {
        guard let memory = memory, let ppu = ppu else { return 0 }
        
        let dmaBlockCycles = 8
        var cycles = 0
        
        let bytesPerBlock = (Int(channel.transferMode) + 1)
        
        for byteIndex in 0..<bytesPerBlock {
            
            if channel.currentTransferSize == 0 {
                channel.enabled = false
                transferEnable &= ~(1 << channelIndex)
                print("[DMA] Channel \(channelIndex) Finished. $4211 is now \(String(format: "%02X", transferEnable))") // ADDED TRACE
                ppu.resetDMAState()
                return cycles
            }
            
            let aAddr = (UInt32(channel.aBusBank) << 16) | UInt32(channel.currentAAddress)
            let data = memory.read(aAddr)
            
            var destAddr = channel.bBusAddress
            
            switch channel.transferMode {
            case 0: destAddr = channel.bBusAddress
            case 1: destAddr = channel.bBusAddress + UInt16(byteIndex)
            case 2: destAddr = channel.bBusAddress
            case 3: destAddr = channel.bBusAddress + UInt16(byteIndex % 2)
            default: destAddr = channel.bBusAddress
            }
            
            switch destAddr {
            case 0x2104: ppu.writeRegister(addr: 0x2104, data: data)
            case 0x2118, 0x2119: ppu.writeRegister(addr: destAddr, data: data)
            case 0x2122: ppu.writeRegister(addr: 0x2122, data: data)
            default: memory.write(bank: 0x00, addr: destAddr, data: data)
            }
            
            if !channel.fixed {
                channel.currentAAddress &+= 1
                channel.currentAAddress &= 0xFFFF
            }
            
            channel.currentTransferSize &-= 1
            cycles += dmaBlockCycles / 8
        }
        
        return cycles
    }
    
    func run() -> Int {
        var totalCycles = 0
        
        for i in 0..<8 {
            if (transferEnable & (1 << i)) != 0 && channels[i].enabled {
                var channel = channels[i]
                
                let cycles = performTransferBlock(channelIndex: i, channel: &channel)
                totalCycles += cycles
                
                channels[i] = channel
            }
        }
        
        return totalCycles
    }
    
    func initHDMA() {
        if hdmaEnable == 0 { return }
        
        for i in 0..<8 {
            if (hdmaEnable & (1 << i)) != 0 {
                var channel = channels[i]
                channel.hdmaActive = true
                channel.hdmaTableAddress = channel.hdmaAddress
                channel.currentAAddress = channel.aBusAddress
                
                let controlByte = memory!.read(bank: channel.aBusBank, addr: channel.hdmaTableAddress)
                channel.hdmaTableAddress &+= 1
                
                channel.hdmaLineCounter = controlByte & 0x7F
                
                if (controlByte & 0x80) != 0 {
                    let low = memory!.read(bank: channel.aBusBank, addr: channel.hdmaTableAddress)
                    channel.hdmaTableAddress &+= 1
                    let high = memory!.read(bank: channel.aBusBank, addr: channel.hdmaTableAddress)
                    channel.hdmaTableAddress &+= 1
                    
                    channel.currentAAddress = (UInt16(high) << 8) | UInt16(low)
                }
                
                channel.hdmaDeferredTransfer = 1
                channels[i] = channel
            }
        }
    }
    
    func runHDMA() -> Int {
        var totalCycles = 0
        
        if hdmaEnable == 0 { return 0 }
        
        for i in 0..<8 {
            if (hdmaEnable & (1 << i)) != 0 {
                var channel = channels[i]
                
                guard channel.hdmaActive else { continue }
                
                if channel.hdmaDeferredTransfer > 0 {
                    totalCycles += 8
                    
                    for _ in 0..<(Int(channel.transferMode) + 1) {
                         let aAddr = (UInt32(channel.aBusBank) << 16) | UInt32(channel.currentAAddress)
                         let data = memory!.read(aAddr)
                        
                         memory!.write(bank: 0x00, addr: channel.bBusAddress, data: data)
                        
                         if !channel.fixed {
                            channel.currentAAddress &+= 1
                            channel.currentAAddress &= 0xFFFF
                         }
                    }
                    channel.hdmaDeferredTransfer = 0
                }
                
                channel.hdmaLineCounter &-= 1
                
                if channel.hdmaLineCounter == 0 {
                    
                    let controlByte = memory!.read(bank: channel.aBusBank, addr: channel.hdmaTableAddress)
                    channel.hdmaTableAddress &+= 1
                    
                    channel.hdmaLineCounter = controlByte & 0x7F
                    
                    if controlByte == 0 {
                        channel.hdmaActive = false
                        hdmaEnable &= ~(1 << i)
                    }
                    else if (controlByte & 0x80) != 0 {
                        let low = memory!.read(bank: channel.aBusBank, addr: channel.hdmaTableAddress)
                        channel.hdmaTableAddress &+= 1
                        let high = memory!.read(bank: channel.aBusBank, addr: channel.hdmaTableAddress)
                        channel.hdmaTableAddress &+= 1
                        
                        channel.currentAAddress = (UInt16(high) << 8) | UInt16(low)
                    }
                    
                    if channel.hdmaActive {
                        channel.hdmaDeferredTransfer = 1
                    }
                }
                
                channels[i] = channel
            }
        }
        
        return totalCycles
    }
}
