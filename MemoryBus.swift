import Foundation

class MemoryBus {
    
    weak var rom: ROM?
    var ram: RAM! // Assuming RAM class is defined elsewhere
    weak var cpu: CPU?
    weak var ppu: PPU?
    weak var dma: DMA?
    weak var controller: Controller?
    weak var apu: APU?
    
    init() {}
    
    func read(bank: UInt8, addr: UInt16) -> UInt8 {
        
        switch (bank, addr) {
        case (0x00...0x3F, 0x0000...0x1FFF):
            return ram.data[Int(addr)]
        
        case (0x00...0x3F, 0x2100...0x213F):
            // PPU control/status reads (VRAM, CGRAM, OAM status/data)
            return ppu?.readRegister(addr: addr) ?? 0
        
        case (0x00...0x3F, 0x2140...0x2143):
            // APU Port Reads
            return apu?.readRegister(addr: addr) ?? 0
        
        case (0x00...0x3F, 0x4200...0x421F):
            // S-CPU Status/Control Registers
            if addr == 0x4210 { return ppu?.readNMIStatus() ?? 0 }
            if addr == 0x4211 { return dma?.readDMAStatus() ?? 0 } // DMA Enable Status Read
            if addr == 0x4218 || addr == 0x4219 { // Controller Port 1/2 Read
                return controller?.readRegister(addr: addr) ?? 0
            }
            if addr >= 0x4212 && addr <= 0x4217 { // V/H Status and Counters
                return ppu?.readRegister(addr: addr) ?? 0
            }
            return 0
        
        case (0x00...0x3F, 0x6000...0x7FFF):
            return ram.data[Int(addr & 0x1FFF)]
        
        case (0x00...0x3F, 0x8000...0xFFFF):
            let romAddr = mapHiROM(bank: bank, addr: addr)
            return rom?.read(addr: romAddr) ?? 0
        
        case (0x7E...0x7F, 0x0000...0xFFFF):
            return ram.data[Int(addr) + (Int(bank - 0x7E) * 0x10000)]
        
        case (0x80...0xBF, 0x0000...0x1FFF):
            return ram.data[Int(addr)]
        
        case (0x80...0xBF, 0x8000...0xFFFF):
            let romAddr = mapHiROM(bank: bank, addr: addr)
            return rom?.read(addr: romAddr) ?? 0
        default:
            return 0
        }
    }
    
    func write(bank: UInt8, addr: UInt16, data: UInt8) {
        
        switch (bank, addr) {
        case (0x00...0x3F, 0x0000...0x1FFF):
            ram.data[Int(addr)] = data
        
        case (0x00...0x3F, 0x2100...0x213F):
            // PPU control/status writes
            ppu?.writeRegister(addr: addr, data: data)
            
        case (0x00...0x3F, 0x2140...0x217F):
            // APU/DSP writes
            apu?.writeRegister(addr: addr, data: data)
            
        case (0x00...0x3F, 0x4200...0x421F):
            // S-CPU Control/DMA writes
            if addr == 0x420B { dma?.startTransfer(data: data); return } // DMA Enable
            if addr == 0x4200 {
                controller?.writeRegister(addr: addr, data: data)
                ppu?.writeRegister(addr: addr, data: data)
                return
            }
            if addr == 0x4203 { apu?.writeRegister(addr: addr, data: data) } // APU Reset
            
            // H/V Timer settings (4207-420A) and other control
            if addr >= 0x4207 && addr <= 0x420A || addr == 0x420C {
                ppu?.writeRegister(addr: addr, data: data)
                return
            }
            return
        case (0x00...0x3F, 0x4016):
            controller?.writeRegister(addr: addr, data: data)
            return
        case (0x00...0x3F, 0x4300...0x437F):
            // DMA Register writes
            dma?.writeRegister(addr: addr, data: data)
        case (0x00...0x3F, 0x6000...0x7FFF):
            ram.data[Int(addr & 0x1FFF)] = data
        case (0x7E...0x7F, 0x0000...0xFFFF):
            ram.data[Int(addr) + (Int(bank - 0x7E) * 0x10000)] = data
        case (0x80...0xBF, 0x0000...0x1FFF):
            ram.data[Int(addr)] = data
        case (0x80...0xBF, 0x4016):
            controller?.writeRegister(addr: addr, data: data)
            return
        default: break
        }
    }
    
    func read(_ addr: UInt32) -> UInt8 {
        let bank = UInt8(addr >> 16)
        let lowAddr = UInt16(addr & 0xFFFF)
        if (bank <= 0x7F && lowAddr >= 0x8000) || (bank >= 0x80 && bank <= 0xFF && lowAddr >= 0x8000) {
            let romAddr = mapHiROM(bank: bank, addr: lowAddr)
            return rom?.read(addr: romAddr) ?? 0
        }
        return read(bank: bank, addr: lowAddr)
    }
    
    func write(_ addr: UInt32, data: UInt8) {
        let bank = UInt8(addr >> 16)
        let lowAddr = UInt16(addr & 0xFFFF)
        if (bank <= 0x3F && lowAddr <= 0x7FFF) || (bank >= 0x7E && bank <= 0x7F) {
            write(bank: bank, addr: lowAddr, data: data)
        }
    }
    
    private func mapHiROM(bank: UInt8, addr: UInt16) -> UInt32 {
        let romBank = UInt32(bank & 0x7F)
        let romAddr = (romBank * 0x8000) + UInt32(addr & 0x7FFF)
        return romAddr
    }
}
