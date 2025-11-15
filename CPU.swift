import Foundation

class CPU {
    
    var a: UInt16 = 0
    var x: UInt16 = 0
    var y: UInt16 = 0
    var s: UInt16 = 0x01FF
    var d: UInt16 = 0
    var db: UInt8 = 0
    var pc: UInt16 = 0
    var pbr: UInt8 = 0
    var p: UInt8 = 0x34
    
    var stopped = false
    
    weak var memory: MemoryBus?
    
    var e: Bool { (p & 0x01) != 0 }
    var m: Bool { (p & 0x20) != 0 }
    var xFlag: Bool { (p & 0x10) != 0 }
    
    enum Flag: UInt8 {
        case C = 0x01
        case Z = 0x02
        case I = 0x04
        case D = 0x08
        case X = 0x10
        case M = 0x20
        case V = 0x40
        case N = 0x80
    }

    init() {
    }
    
    func reset() {
        guard let memory = memory else { return }
        
        a = 0
        x = 0
        y = 0
        s = 0x01FF
        d = 0
        db = 0
        pbr = 0
        p = 0x34
        
        let low = memory.read(bank: 0x00, addr: 0xFFFC)
        let high = memory.read(bank: 0x00, addr: 0xFFFD)
        pc = (UInt16(high) << 8) | UInt16(low)
        
        stopped = false
    }
    
    func nmi() {
        stopped = false
        push(UInt8(pbr))
        pushWord(pc)
        push(p)
        
        p &= ~Flag.D.rawValue
        p |= Flag.I.rawValue
        
        pbr = 0
        let low = memory!.read(bank: 0x00, addr: 0xFFEA)
        let high = memory!.read(bank: 0x00, addr: 0xFFEB)
        pc = (UInt16(high) << 8) | UInt16(low)
    }
    
    // Helper function for indirect addressing logic
    func getIndirectAddr(dpAddr: UInt16, indexedBy: UInt16) -> UInt32 {
        let low = memory!.read(bank: 0, addr: (dpAddr &+ indexedBy) & 0xFF)
        let high = memory!.read(bank: 0, addr: (dpAddr &+ indexedBy &+ 1) & 0xFF)
        let indirectAddr = (UInt16(high) << 8) | UInt16(low)
        return UInt32(db) << 16 | UInt32(indirectAddr)
    }

    // Helper function for indirect indexed addressing logic
    func getIndexedIndirectAddr(dpAddr: UInt16, indexedBy: UInt16) -> (UInt32, Bool) {
        let low = memory!.read(bank: 0, addr: dpAddr & 0xFF)
        let high = memory!.read(bank: 0, addr: (dpAddr &+ 1) & 0xFF)
        let indirectAddr = (UInt16(high) << 8) | UInt16(low)
        let finalAddr = indirectAddr &+ indexedBy
        let pageCrossed = (indirectAddr & 0xFF00) != (finalAddr & 0xFF00)
        return (UInt32(db) << 16 | UInt32(finalAddr), pageCrossed)
    }

    // Helper function for indirect DP addressing logic (no indexing)
    func getDPIndirectAddr(dpAddr: UInt16) -> UInt32 {
        let low = memory!.read(bank: 0, addr: dpAddr & 0xFF)
        let high = memory!.read(bank: 0, addr: (dpAddr &+ 1) & 0xFF)
        let indirectAddr = (UInt16(high) << 8) | UInt16(low)
        return UInt32(db) << 16 | UInt32(indirectAddr)
    }

    func readData(from finalAddr: UInt32) -> UInt16 {
        let bank = UInt8(finalAddr >> 16)
        let addr = UInt16(finalAddr & 0xFFFF)
        if m {
            return UInt16(memory!.read(bank: bank, addr: addr))
        } else {
            return readWord(bank: bank, addr: addr)
        }
    }
    
    func writeData(_ data: UInt16, to finalAddr: UInt32) {
        let bank = UInt8(finalAddr >> 16)
        let addr = UInt16(finalAddr & 0xFFFF)
        if m {
            memory!.write(bank: bank, addr: addr, data: UInt8(data & 0xFF))
        } else {
            writeWord(bank: bank, addr: addr, data: data)
        }
    }

    func step() -> Int {
        guard let memory = memory, !stopped else { return 1 }
        
        let opcode = memory.read(bank: pbr, addr: pc)
        pc &+= 1
        
        switch opcode {
        
        case 0x00: // BRK (Break)
            print("CPU executing BRK interrupt sequence.")
            let returnPC = pc &+ 1
            if e {
                pushWord(returnPC)
                push(p)
                pbr = 0
                let low = memory.read(bank: 0x00, addr: 0xFFFE)
                let high = memory.read(bank: 0x00, addr: 0xFFFF)
                pc = (UInt16(high) << 8) | UInt16(low)
                return 7
            } else {
                push(pbr)
                pushWord(returnPC)
                push(p)
                pbr = 0
                let low = memory.read(bank: 0x00, addr: 0xFFE6)
                let high = memory.read(bank: 0x00, addr: 0xFFE7)
                pc = (UInt16(high) << 8) | UInt16(low)
                return 8
            }
            
        case 0x01: // ORA (DP Indirect, X)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getIndirectAddr(dpAddr: dpAddr, indexedBy: x)
            let val = readData(from: finalAddr)
            a |= val
            updateP(a)
            return 6
            
        case 0x02: // COP (Coprocessor)
            let returnPC = pc &+ 1
            if e {
                pushWord(returnPC)
                push(p)
                pbr = 0
                let low = memory.read(bank: 0x00, addr: 0xFFF4)
                let high = memory.read(bank: 0x00, addr: 0xFFF5)
                pc = (UInt16(high) << 8) | UInt16(low)
                return 7
            } else {
                push(pbr)
                pushWord(returnPC)
                push(p)
                pbr = 0
                let low = memory.read(bank: 0x00, addr: 0xFFE4)
                let high = memory.read(bank: 0x00, addr: 0xFFE5)
                pc = (UInt16(high) << 8) | UInt16(low)
                return 8
            }
            
        case 0x03: // ORA (Stack Relative)
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0x01, addr: sr_addr)
                a = (a & 0xFF00) | ((a & 0xFF) | UInt16(val))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: 0x01, addr: sr_addr)
                a |= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x04: // TSB (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let (newVal, cycles) = tsb8(addr: addr, bank: 0)
                memory.write(bank: 0, addr: addr, data: newVal)
                return cycles - 2
            } else {
                let (newVal, cycles) = tsb16(addr: addr, bank: 0)
                writeWord(bank: 0, addr: addr, data: newVal)
                return cycles - 2
            }
            
        case 0x05: // ORA (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                a = (a & 0xFF00) | ((a & 0xFF) | UInt16(val))
                let result = a & 0xFF
                if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
                if (result & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                a |= val
                updateP(a)
            }
            return m ? 3 : 4
            
        case 0x06: // ASL (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                let oldC = (val & 0x80) != 0
                let newVal = val << 1
                memory.write(bank: 0, addr: addr, data: newVal)
                if oldC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: 0, addr: addr)
                let oldC = (val & 0x8000) != 0
                let newVal = val << 1
                writeWord(bank: 0, addr: addr, data: newVal)
                if oldC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 5 : 6

        case 0x07: // ORA (Absolute Long Indirect)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            
            if m {
                let val = UInt16(memory.read(addr))
                a = (a & 0xFF00) | ((a & 0xFF) | val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(addr >> 16), addr: UInt16(addr & 0xFFFF))
                a |= val
                updateP(a)
            }
            return m ? 5 : 6
            
        case 0x08: // PHP (Push Processor Status)
            push(p)
            return 3
            
        case 0x09: // ORA #Immediate
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                a |= val
                updateP(a)
            }
            return m ? 2 : 3
            
        case 0x0A: // ASL A (Arithmetic Shift Left Accumulator)
            if m {
                let val = a & 0xFF
                if (val & 0x80) != 0 { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                a = (a & 0xFF00) | ((val << 1) & 0xFF)
                updateP(a & 0xFF)
            } else {
                if (a & 0x8000) != 0 { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                a <<= 1
                updateP(a)
            }
            return 2
            
        case 0x0B: // PHD (Push Direct Page)
            pushWord(d)
            return 3

        case 0x0C: // TSB (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let (newVal, cycles) = tsb8(addr: addr, bank: db)
                memory.write(bank: db, addr: addr, data: newVal)
                return cycles - 1
            } else {
                let (newVal, cycles) = tsb16(addr: addr, bank: db)
                writeWord(bank: db, addr: addr, data: newVal)
                return cycles - 1
            }
            
        case 0x0D: // ORA (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(bank: db, addr: addr))
                updateP(a & 0xFF)
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a |= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x0E: // ASL (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                let oldC = (val & 0x80) != 0
                let newVal = val << 1
                memory.write(bank: db, addr: addr, data: newVal)
                if oldC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: db, addr: addr)
                let oldC = (val & 0x8000) != 0
                let newVal = val << 1
                writeWord(bank: db, addr: addr, data: newVal)
                if oldC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 6 : 7
            
        case 0x0F: // ORA (Absolute Long)
            pc &+= 3
            return 5
            
        case 0x10: // BPL (Branch if Positive)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.N.rawValue) == 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0x11: // ORA (DP Indirect), Y
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let (finalAddr, pageCrossed) = getIndexedIndirectAddr(dpAddr: dpAddr, indexedBy: y)
            let val = readData(from: finalAddr)
            a |= val
            updateP(a)
            return m ? (pageCrossed ? 6 : 5) : (pageCrossed ? 6 : 5)
            
        case 0x12: // ORA (DP Indirect)
            pc &+= 1
            return 5
            
        case 0x13: // ORA (Stack Relative Indirect), Y
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0x01, addr: sr_addr & 0xFF)
            let high = memory.read(bank: 0x01, addr: (sr_addr &+ 1) & 0xFF)
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(db) << 16 | UInt32(indirectAddr &+ y)
            
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(finalAddr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a |= val
                updateP(a)
            }
            return m ? 5 : 6
            
        case 0x14: // TRB (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let (newVal, cycles) = trb8(addr: addr, bank: 0)
                memory.write(bank: 0, addr: addr, data: newVal)
                return cycles - 2
            } else {
                let (newVal, cycles) = trb16(addr: addr, bank: 0)
                writeWord(bank: 0, addr: addr, data: newVal)
                return cycles - 2
            }
            
        case 0x15: // ORA (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(bank: 0, addr: addr))
                let result = a & 0xFF
                if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
                if (result & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            } else {
                let valLow = memory.read(bank: 0, addr: addr)
                let valHigh = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a |= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x16: // ASL (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                let oldC = (val & 0x80) != 0
                let newVal = val << 1
                memory.write(bank: 0, addr: addr, data: newVal)
                if oldC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: 0, addr: addr)
                let oldC = (val & 0x8000) != 0
                let newVal = val << 1
                writeWord(bank: 0, addr: addr, data: newVal)
                if oldC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 6 : 7
            
        case 0x17: // ORA (DP Indirect Long), Y
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let indirectAddr = (UInt32(bank) << 16) | UInt32(UInt16(high) << 8) | UInt32(low)
            let finalAddr = indirectAddr &+ UInt32(y)
            
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(finalAddr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a |= val
                updateP(a)
            }
            return m ? 5 : 6 // Takes 6 if page crossed
            
        case 0x18: clc(); return 2
            
        case 0x19: // ORA (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ y
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(bank: db, addr: addr))
                let result = a & 0xFF
                if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
                if (result & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a |= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x1A: // INC A
            if m {
                a = (a & 0xFF00) | ((a & 0xFF) &+ 1)
                let result = a & 0xFF
                if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
                if (result & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            } else {
                a &+= 1
                updateP(a)
            }
            return 2
            
        case 0x1B: // TCS (Transfer A to S)
            if e {
                s = (0x0100) | (a & 0xFF)
            } else {
                s = a
            }
            return 2
            
        case 0x1C: // TRB (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let (newVal, cycles) = trb8(addr: addr, bank: db)
                memory.write(bank: db, addr: addr, data: newVal)
                return cycles - 1
            } else {
                let (newVal, cycles) = trb16(addr: addr, bank: db)
                writeWord(bank: db, addr: addr, data: newVal)
                return cycles - 1
            }
            
        case 0x1D: // ORA (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(bank: db, addr: addr))
                updateP(a & 0xFF)
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a |= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x1E: // ASL (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: db, addr: addr)
                let oldC = (val & 0x80) != 0
                let newVal = val << 1
                memory.write(bank: db, addr: addr, data: newVal)
                if oldC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: db, addr: addr)
                let oldC = (val & 0x8000) != 0
                let newVal = val << 1
                writeWord(bank: db, addr: addr, data: newVal)
                if oldC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 7 : 8

        case 0x1F: // ORA (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            let finalAddr = addr &+ UInt32(x)
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | ((a & 0xFF) | val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a |= val
                updateP(a)
            }
            return m ? 5 : 6

        case 0x20: // JSR (Absolute)
            let low = memory.read(bank: pbr, addr: pc)
            pc &+= 1
            let high = memory.read(bank: pbr, addr: pc)
            pc &+= 1
            pushWord(pc &- 1)
            pc = (UInt16(high) << 8) | UInt16(low)
            return 6
            
        
        case 0x21: // AND (DP Indirect, X)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getIndirectAddr(dpAddr: dpAddr, indexedBy: x)
            let val = readData(from: finalAddr)
            a &= val
            updateP(a)
            return 6
            
        case 0x22: // JSL (Jump to Subroutine Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            push(pbr); pushWord(pc &- 1)
            pbr = bank
            pc = (UInt16(high) << 8) | UInt16(low)
            return 8
            
        case 0x23: // AND (Stack Relative)
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0x01, addr: sr_addr)
                a = (a & 0xFF00) | ((a & 0xFF) & UInt16(val))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: 0x01, addr: sr_addr)
                a &= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x24: // BIT (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            bit(addr: addr, bank: 0)
            return 3
            
        case 0x25: // AND (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                a = (a & 0xFF00) | (a & 0xFF & UInt16(memory.read(bank: 0, addr: addr)))
                let result = a & 0xFF
                if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
                if (result & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                a &= val
                updateP(a)
            }
            return m ? 3 : 4
            
        case 0x26: // ROL (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                let (newVal, newC) = rol8(val)
                memory.write(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: 0, addr: addr)
                let (newVal, newC) = rol16(val)
                writeWord(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 5 : 6
            
        case 0x27: // AND (DP Indirect Long)
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let finalAddr = UInt32(bank) << 16 | UInt32(UInt16(high) << 8) | UInt32(low)
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | ((a & 0xFF) & val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a &= val
                updateP(a)
            }
            return m ? 6 : 7
            
        case 0x28: // PLP (Pull Processor Status)
            p = pop()
            return 4
            
        case 0x29: // AND #Immediate
            if m {
                a = (a & 0xFF00) | (a & 0xFF & UInt16(memory.read(bank: pbr, addr: pc))); pc &+= 1
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                a &= val
                updateP(a)
            }
            return m ? 2 : 3
            
        case 0x2A: // ROL A (Rotate Left Accumulator)
            if m {
                let val = UInt8(a & 0xFF)
                let (newVal, newC) = rol8(val)
                a = (a & 0xFF00) | UInt16(newVal);
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(a & 0xFF)
            } else {
                let (newVal, newC) = rol16(a)
                a = newVal;
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(a)
            }
            return 2
            
        case 0x2B: // PLD (Pull Direct Page)
            d = popWord()
            updateP(d)
            return 5
            
        case 0x2C: // BIT (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            bit(addr: addr, bank: db)
            return 4
            
        case 0x2D: // AND (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                a = (a & 0xFF00) | (a & 0xFF & UInt16(memory.read(bank: db, addr: addr)))
                updateP(a & 0xFF)
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a &= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x2E: // ROL (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                let (newVal, newC) = rol8(val)
                memory.write(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: db, addr: addr)
                let (newVal, newC) = rol16(val)
                writeWord(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 6 : 7
            
        case 0x2F: // AND (Absolute Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let finalAddr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | ((a & 0xFF) & val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a &= val
                updateP(a)
            }
            return m ? 5 : 6

        case 0x30: // BMI (Branch if Minus)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.N.rawValue) != 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0x31: // AND (DP Indirect), Y
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let (finalAddr, pageCrossed) = getIndexedIndirectAddr(dpAddr: dpAddr, indexedBy: y)
            let val = readData(from: finalAddr)
            a &= val
            updateP(a)
            return m ? (pageCrossed ? 6 : 5) : (pageCrossed ? 6 : 5)
            
        case 0x32: // AND (DP Indirect)
            pc &+= 1
            return 5

        case 0x33: // AND (Stack Relative Indirect), Y
            let dpAddr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0x01, addr: dpAddr & 0xFF)
            let high = memory.read(bank: 0x01, addr: (dpAddr &+ 1) & 0xFF)
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(db) << 16 | UInt32(indirectAddr &+ y)
            
            if m {
                a = (a & 0xFF00) | (a & 0xFF) & UInt16(memory.read(finalAddr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a &= val
                updateP(a)
            }
            return m ? 5 : 6
            
        case 0x34: // BIT (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            bit(addr: addr, bank: 0)
            return 4
            
        case 0x35: // AND (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                a = (a & 0xFF00) | (a & 0xFF & UInt16(memory.read(bank: 0, addr: addr)))
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                a &= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x36: // ROL (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                let (newVal, newC) = rol8(val)
                memory.write(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: 0, addr: addr)
                let (newVal, newC) = rol16(val)
                writeWord(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 6 : 7
            
        case 0x37: // AND (DP Indirect Long), Y
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let indirectAddr = (UInt32(bank) << 16) | UInt32(UInt16(high) << 8) | UInt32(low)
            let finalAddr = indirectAddr &+ UInt32(y)
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | (a & 0xFF) & val
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a &= val
                updateP(a)
            }
            return m ? 6 : 7
            
        case 0x38: sec(); return 2
            
        case 0x39: // AND (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ y
            if m {
                a = (a & 0xFF00) | (a & 0xFF & UInt16(memory.read(bank: db, addr: addr)))
                let result = a & 0xFF
                if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
                if (result & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a &= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x3A: // DEC A
            if m {
                a = (a & 0xFF00) | ((a & 0xFF) &- 1)
                updateP(a & 0xFF)
            } else {
                a &-= 1
                updateP(a)
            }
            return 2
            
        case 0x3B: // TSC (Transfer S to A)
            if e {
                a = (a & 0xFF00) | (s & 0x00FF)
                updateP(a & 0xFF)
            } else {
                a = s
                updateP(a)
            }
            return 2
            
        case 0x3C: // BIT (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            bit(addr: addr, bank: db)
            return 4
            
        case 0x3D: // AND (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                a = (a & 0xFF00) | (a & 0xFF & UInt16(memory.read(bank: db, addr: addr)))
                updateP(a & 0xFF)
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a &= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x3E: // ROL (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: db, addr: addr)
                let (newVal, newC) = rol8(val)
                memory.write(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: db, addr: addr)
                let (newVal, newC) = rol16(val)
                writeWord(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 7 : 8

        case 0x3F: // AND (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            let finalAddr = addr &+ UInt32(x)
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | ((a & 0xFF) & val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a &= val
                updateP(a)
            }
            return m ? 5 : 6

        case 0x40: // RTI (Return from Interrupt)
            if e {
                p = pop()
                let pcLow = pop()
                let pcHigh = pop()
                pc = (UInt16(pcHigh) << 8) | UInt16(pcLow)
                return 6
            } else {
                p = pop()
                let pcLow = pop()
                let pcHigh = pop()
                pc = (UInt16(pcHigh) << 8) | UInt16(pcLow)
                pbr = pop()
                return 7
            }
            
        case 0x41: // EOR (DP Indirect, X)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getIndirectAddr(dpAddr: dpAddr, indexedBy: x)
            let val = readData(from: finalAddr)
            a ^= val
            updateP(a)
            return 6
            
        case 0x42: // WDM (Reserved for future expansion)
            pc &+= 1
            return 2
            
        case 0x43: // EOR (Stack Relative)
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0x01, addr: sr_addr)
                a = (a & 0xFF00) | ((a & 0xFF) ^ UInt16(val))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: 0x01, addr: sr_addr)
                a ^= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x44: // MVP (Move Block Positive)
            let destBank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let srcBank = memory.read(bank: pbr, addr: pc); pc &+= 1
            
            let data = memory.read(bank: srcBank, addr: x)
            memory.write(bank: destBank, addr: y, data: data)
            
            x &+= 1
            y &+= 1
            a &-= 1
            
            if (a & 0xFFFF) != 0 {
                pc &-= 3
                return 8
            }
            return 5
            
        case 0x45: // EOR (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: 0, addr: addr))
                let result = a & 0xFF
                if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
                if (result & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                a ^= val
                updateP(a)
            }
            return m ? 3 : 4
            
        case 0x46: // LSR (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                let (newVal, newC) = lsr8(val)
                memory.write(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: 0, addr: addr)
                let (newVal, newC) = lsr16(val)
                writeWord(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 5 : 6
            
        case 0x47: // EOR (DP Indirect Long)
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let finalAddr = UInt32(bank) << 16 | UInt32(UInt16(high) << 8) | UInt32(low)
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | ((a & 0xFF) ^ val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a ^= val
                updateP(a)
            }
            return m ? 6 : 7
            
        case 0x48: // PHA (Push Accumulator)
            if m { push(UInt8(a & 0xFF)) } else { pushWord(a) }
            return m ? 3 : 4
            
        case 0x49: // EOR #Immediate
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                a ^= val
                updateP(a)
            }
            return m ? 2 : 3
            
        case 0x4A: // LSR A (Logical Shift Right Accumulator)
            if m {
                let val = a & 0xFF
                let (newVal, newC) = lsr8(UInt8(val))
                a = (a & 0xFF00) | UInt16(newVal);
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(a & 0xFF)
            } else {
                let (newVal, newC) = lsr16(a)
                a = newVal;
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(a)
            }
            return 2
            
        case 0x4B: // PHK (Push Program Bank Register)
            push(pbr)
            return 3
            
        case 0x4C: // JMP (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc)
            pc = (UInt16(high) << 8) | UInt16(low)
            return 3
            
        case 0x4D: // EOR (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: db, addr: addr))
                updateP(a & 0xFF)
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a ^= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x4E: // LSR (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                let (newVal, newC) = lsr8(val)
                memory.write(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: db, addr: addr)
                let (newVal, newC) = lsr16(val)
                writeWord(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 6 : 7

        case 0x4F: // EOR (Absolute Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let finalAddr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | ((a & 0xFF) ^ val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a ^= val
                updateP(a)
            }
            return m ? 5 : 6

        case 0x50: // BVC (Branch if Overflow Clear)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.V.rawValue) == 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0x51: // EOR (DP Indirect), Y
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let (finalAddr, pageCrossed) = getIndexedIndirectAddr(dpAddr: dpAddr, indexedBy: y)
            let val = readData(from: finalAddr)
            a ^= val
            updateP(a)
            return m ? (pageCrossed ? 6 : 5) : (pageCrossed ? 6 : 5)
            
        case 0x52: // EOR (DP Indirect)
            pc &+= 1
            return 5

        case 0x53: // EOR (Stack Relative Indirect), Y
            let dpAddr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0x01, addr: dpAddr & 0xFF)
            let high = memory.read(bank: 0x01, addr: (dpAddr &+ 1) & 0xFF)
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(db) << 16 | UInt32(indirectAddr &+ y)
            
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(finalAddr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a ^= val
                updateP(a)
            }
            return m ? 5 : 6
            
        case 0x54: // MVN (Move Block Negative)
            let destBank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let srcBank = memory.read(bank: pbr, addr: pc); pc &+= 1
            
            let data = memory.read(bank: srcBank, addr: x)
            memory.write(bank: destBank, addr: y, data: data)
            
            x &-= 1
            y &-= 1
            a &-= 1
            
            if (a & 0xFFFF) != 0 {
                pc &-= 3
                return 8
            }
            return 5
            
        case 0x55: // EOR (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: 0, addr: addr))
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                a ^= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x56: // LSR (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                let (newVal, newC) = lsr8(val)
                memory.write(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: 0, addr: addr)
                let (newVal, newC) = lsr16(val)
                writeWord(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 6 : 7
            
        case 0x57: // EOR (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            let finalAddr = addr &+ UInt32(x)
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | ((a & 0xFF) ^ val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a ^= val
                updateP(a)
            }
            return m ? 5 : 6
            
        case 0x58: cli(); return 2
            
        case 0x59: // EOR (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ y
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: db, addr: addr))
                updateP(a & 0xFF)
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a ^= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x5A: // PHY (Push Y)
            if xFlag { push(UInt8(y & 0xFF)) } else { pushWord(y) }
            return xFlag ? 3 : 4
            
        case 0x5B: // TCD (Transfer A to D)
            d = a
            updateP(d)
            return 2
            
        case 0x5C: // JMP (Absolute Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            pbr = bank
            pc = (UInt16(high) << 8) | UInt16(low)
            return 4
            
        case 0x5D: // EOR (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: db, addr: addr))
                updateP(a & 0xFF)
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(valHigh) << 8) | UInt16(valLow)
                a ^= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x5E: // LSR (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: db, addr: addr)
                let (newVal, newC) = lsr8(val)
                memory.write(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: db, addr: addr)
                let (newVal, newC) = lsr16(val)
                writeWord(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 7 : 8

        case 0x5F: // EOR (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            let finalAddr = addr &+ UInt32(x)
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | ((a & 0xFF) ^ val)
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a ^= val
                updateP(a)
            }
            return m ? 5 : 6

        case 0x60: // RTS (Return from Subroutine)
            pc = popWord() &+ 1
            return 6
            
        case 0x61: // ADC (DP Indirect, X)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getIndirectAddr(dpAddr: dpAddr, indexedBy: x)
            let val = readData(from: finalAddr)
            if m { adc8(UInt8(val & 0xFF)) } else { adc16(val) }
            return 6
            
        case 0x62: // PER (Push Effective Relative)
            let relLow = memory.read(bank: pbr, addr: pc); pc &+= 1
            let relHigh = memory.read(bank: pbr, addr: pc); pc &+= 1
            let relOffset = (UInt16(relHigh) << 8) | UInt16(relLow)
            let address = pc &+ relOffset
            pushWord(address)
            return 6
            
        case 0x63: // ADC (Stack Relative)
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0x01, addr: sr_addr)
                adc8(val)
            } else {
                let val = readWord(bank: 0x01, addr: sr_addr)
                adc16(val)
            }
            return m ? 4 : 5

        case 0x64: // STZ (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                memory.write(bank: 0, addr: addr, data: 0x00)
            } else {
                memory.write(bank: 0, addr: addr, data: 0x00)
                memory.write(bank: 0, addr: addr &+ 1, data: 0x00)
            }
            return m ? 3 : 4
            
        case 0x65: // ADC (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                adc8(val)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                adc16(val)
            }
            return m ? 3 : 4
            
        case 0x66: // ROR (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                let (newVal, newC) = ror8(val)
                memory.write(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: 0, addr: addr)
                let (newVal, newC) = ror16(val)
                writeWord(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 5 : 6
            
        case 0x67: // ADC (DP Indirect Long)
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let finalAddr = UInt32(bank) << 16 | UInt32(UInt16(high) << 8) | UInt32(low)
            
            if m {
                let val = memory.read(finalAddr)
                adc8(val)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                adc16(val)
            }
            return m ? 6 : 7
            
        case 0x68: // PLA (Pull Accumulator)
            if m {
                a = (a & 0xFF00) | UInt16(pop())
                updateP(a & 0xFF)
            } else {
                a = popWord()
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x69: // ADC #Immediate
            if m {
                let val = memory.read(bank: pbr, addr: pc); pc &+= 1
                adc8(val)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                adc16(val)
            }
            return m ? 2 : 3
            
        case 0x6A: // ROR A (Rotate Right Accumulator)
            if m {
                let val = UInt8(a & 0xFF)
                let (newVal, newC) = ror8(val)
                a = (a & 0xFF00) | UInt16(newVal);
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(a & 0xFF)
            } else {
                let (newVal, newC) = ror16(a)
                a = newVal;
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(a)
            }
            return 2
            
        case 0x6B: // RTL (Return from Long Subroutine)
            let pcLow = pop()
            let pcHigh = pop()
            pc = (UInt16(pcHigh) << 8) | UInt16(pcLow)
            pbr = pop()
            pc &+= 1
            return 6
            
        case 0x6C: // JMP (Absolute Indirect)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let indirectAddr = readWord(bank: pbr, addr: addr)
            pc = indirectAddr
            return 5
            
        case 0x6D: // ADC (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                adc8(val)
            } else {
                let low = memory.read(bank: db, addr: addr)
                let high = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                adc16(val)
            }
            return m ? 4 : 5
            
        case 0x6E: // ROR (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                let (newVal, newC) = ror8(val)
                memory.write(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: db, addr: addr)
                let (newVal, newC) = ror16(val)
                writeWord(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 6 : 7

        case 0x6F: // ADC (Absolute Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let finalAddr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            
            if m {
                let val = memory.read(finalAddr)
                adc8(val)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                adc16(val)
            }
            return m ? 5 : 6

        case 0x70: // BVS (Branch if Overflow Set)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.V.rawValue) != 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0x71: // ADC (DP Indirect), Y
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let (finalAddr, pageCrossed) = getIndexedIndirectAddr(dpAddr: dpAddr, indexedBy: y)
            let val = readData(from: finalAddr)
            if m { adc8(UInt8(val & 0xFF)) } else { adc16(val) }
            return m ? (pageCrossed ? 6 : 5) : (pageCrossed ? 6 : 5)
            
        case 0x72: // ADC (DP Indirect)
            pc &+= 1
            return 5

        case 0x73: // ADC (Stack Relative Indirect), Y
            let dpAddr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0x01, addr: dpAddr & 0xFF)
            let high = memory.read(bank: 0x01, addr: (dpAddr &+ 1) & 0xFF)
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(db) << 16 | UInt32(indirectAddr &+ y)
            
            if m {
                let val = memory.read(finalAddr)
                adc8(val)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                adc16(val)
            }
            return m ? 5 : 6
            
        case 0x74: // STZ (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                memory.write(bank: 0, addr: addr, data: 0x00)
            } else {
                memory.write(bank: 0, addr: addr, data: 0x00)
                memory.write(bank: 0, addr: addr &+ 1, data: 0x00)
            }
            return m ? 4 : 5

        case 0x75: // ADC (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                adc8(val)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                adc16(val)
            }
            return m ? 4 : 5
            
        case 0x76: // ROR (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                let (newVal, newC) = ror8(val)
                memory.write(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: 0, addr: addr)
                let (newVal, newC) = ror16(val)
                writeWord(bank: 0, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 6 : 7
            
        case 0x77: // ADC (DP Indirect Long), Y
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let indirectAddr = (UInt32(bank) << 16) | UInt32(UInt16(high) << 8) | UInt32(low)
            let finalAddr = indirectAddr &+ UInt32(y)
            
            if m {
                let val = memory.read(finalAddr)
                adc8(val)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                adc16(val)
            }
            return m ? 6 : 7
            
        case 0x78: sei(); return 2
            
        case 0x79: // ADC (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ y
            if m {
                let val = memory.read(bank: db, addr: addr)
                adc8(val)
            } else {
                let low = memory.read(bank: db, addr: addr)
                let high = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                adc16(val)
            }
            return m ? 4 : 5
            
        case 0x7A: // PLY (Pull Y)
            if xFlag { y = (y & 0xFF00) | UInt16(pop()); updateP(y & 0xFF) }
            else { y = popWord(); updateP(y) }
            return xFlag ? 4 : 5
            
        case 0x7B: // TDC (Transfer D to A)
            a = d
            updateP(a)
            return 2

        case 0x7C: // JMP (Absolute Indirect, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let indirectAddr = readWord(bank: pbr, addr: addr &+ x)
            pc = indirectAddr
            return 6
            
        case 0x7D: // ADC (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: db, addr: addr)
                adc8(val)
            } else {
                let low = memory.read(bank: db, addr: addr)
                let high = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                adc16(val)
            }
            return m ? 4 : 5
            
        case 0x7E: // ROR (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: db, addr: addr)
                let (newVal, newC) = ror8(val)
                memory.write(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(UInt16(newVal))
            } else {
                let val = readWord(bank: db, addr: addr)
                let (newVal, newC) = ror16(val)
                writeWord(bank: db, addr: addr, data: newVal)
                if newC { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                updateP(newVal)
            }
            return m ? 7 : 8

        case 0x7F: // ADC (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(bank) << 16 | UInt32(addr &+ x)
            
            if m {
                let val = memory.read(finalAddr)
                adc8(val)
            } else {
                let val = readWord(bank: bank, addr: addr &+ x)
                adc16(val)
            }
            return m ? 5 : 6

        case 0x80: // BRA (Branch Always)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            pc = pc &+ UInt16(bitPattern: Int16(offset))
            return 3
            
        case 0x81: // STA (DP Indirect, X)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getIndirectAddr(dpAddr: dpAddr, indexedBy: x)
            writeData(a, to: finalAddr)
            return 6
            
        case 0x82: // BRL (Branch Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let offset = (UInt16(high) << 8) | UInt16(low)
            pc = pc &+ offset
            return 4
            
        case 0x83: // STA (Stack Relative)
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                memory.write(bank: 0x01, addr: sr_addr, data: UInt8(a & 0xFF))
            } else {
                writeWord(bank: 0x01, addr: sr_addr, data: a)
            }
            return m ? 4 : 5
            
        case 0x84: // STY (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if xFlag {
                memory.write(bank: 0, addr: addr, data: UInt8(y & 0xFF))
            } else {
                memory.write(bank: 0, addr: addr, data: UInt8(y & 0xFF))
                memory.write(bank: 0, addr: addr &+ 1, data: UInt8(y >> 8))
            }
            return xFlag ? 3 : 4
            
        case 0x85: // STA (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                memory.write(bank: 0, addr: addr, data: UInt8(a & 0xFF))
            } else {
                memory.write(bank: 0, addr: addr, data: UInt8(a & 0xFF))
                memory.write(bank: 0, addr: addr &+ 1, data: UInt8(a >> 8))
            }
            return m ? 3 : 4
            
        case 0x86: // STX (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if xFlag {
                memory.write(bank: 0, addr: addr, data: UInt8(x & 0xFF))
            } else {
                memory.write(bank: 0, addr: addr, data: UInt8(x & 0xFF))
                memory.write(bank: 0, addr: addr &+ 1, data: UInt8(x >> 8))
            }
            return xFlag ? 3 : 4
            
        case 0x87: // STA (DP Indirect Long)
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let finalAddr = UInt32(bank) << 16 | UInt32(UInt16(high) << 8) | UInt32(low)
            
            if m {
                memory.write(finalAddr, data: UInt8(a & 0xFF))
            } else {
                writeWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF), data: a)
            }
            return m ? 6 : 7
            
        case 0x88: // DEY (Decrement Y)
            if xFlag {
                y = (y & 0xFF00) | ((y & 0xFF) &- 1)
                updateP(y & 0xFF)
            } else {
                y &-= 1
                updateP(y)
            }
            return 2
            
        case 0x89: // BIT #Immediate
            if m {
                let val = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                bit(val: val & 0xFF)
                return 2
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                bit(val: val)
                return 3
            }
            
        case 0x8A: // TXA (Transfer X to A)
            if m {
                a = (a & 0xFF00) | (x & 0x00FF)
                updateP(a & 0xFF)
            } else {
                a = x
                updateP(a)
            }
            return 2
            
        case 0x8B: // PHB (Push Data Bank Register)
            push(db)
            return 3
            
        case 0x8C: // STY (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if xFlag {
                memory.write(bank: db, addr: addr, data: UInt8(y & 0xFF))
            } else {
                memory.write(bank: db, addr: addr, data: UInt8(y & 0xFF))
                memory.write(bank: db, addr: addr &+ 1, data: UInt8(y >> 8))
            }
            return xFlag ? 4 : 5
            
        case 0x8D: // STA (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                memory.write(bank: db, addr: addr, data: UInt8(a & 0xFF))
            } else {
                memory.write(bank: db, addr: addr, data: UInt8(a & 0xFF))
                memory.write(bank: db, addr: addr &+ 1, data: UInt8(a >> 8))
            }
            return m ? 4 : 5
            
        case 0x8E: // STX (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if xFlag {
                memory.write(bank: db, addr: addr, data: UInt8(x & 0xFF))
            } else {
                memory.write(bank: db, addr: addr, data: UInt8(x & 0xFF))
                memory.write(bank: db, addr: addr &+ 1, data: UInt8(x >> 8))
            }
            return xFlag ? 4 : 5
            
        case 0x8F: // STA (Absolute Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            
            if m {
                memory.write(bank: bank, addr: addr, data: UInt8(a & 0xFF))
            } else {
                memory.write(bank: bank, addr: addr, data: UInt8(a & 0xFF))
                memory.write(bank: bank, addr: addr &+ 1, data: UInt8(a >> 8))
            }
            return m ? 5 : 6

        case 0x90: // BCC (Branch if Carry Clear)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.C.rawValue) == 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2

        case 0x91: // STA (DP Indirect), Y
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let (finalAddr, _) = getIndexedIndirectAddr(dpAddr: dpAddr, indexedBy: y)
            writeData(a, to: finalAddr)
            return m ? 6 : 7
            
        case 0x92: // STA (DP Indirect)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getDPIndirectAddr(dpAddr: dpAddr)
            writeData(a, to: finalAddr)
            return 5

        case 0x93: // STA (Stack Relative Indirect), Y
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0x01, addr: sr_addr & 0xFF)
            let high = memory.read(bank: 0x01, addr: (sr_addr &+ 1) & 0xFF)
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(db) << 16 | UInt32(indirectAddr &+ y)
            
            if m {
                memory.write(finalAddr, data: UInt8(a & 0xFF))
            } else {
                writeWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF), data: a)
            }
            return m ? 5 : 6
            
        case 0x94: // STY (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if xFlag {
                memory.write(bank: 0, addr: addr, data: UInt8(y & 0xFF))
            } else {
                writeWord(bank: 0, addr: addr, data: y)
            }
            return xFlag ? 4 : 5
            
        case 0x95: // STA (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                memory.write(bank: 0, addr: addr, data: UInt8(a & 0xFF))
            } else {
                writeWord(bank: 0, addr: addr, data: a)
            }
            return m ? 4 : 5

        case 0x96: // STX (Direct Page, Y)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ y; pc &+= 1
            if xFlag {
                memory.write(bank: 0, addr: addr, data: UInt8(x & 0xFF))
            } else {
                memory.write(bank: 0, addr: addr, data: UInt8(x & 0xFF))
                memory.write(bank: 0, addr: addr &+ 1, data: UInt8(x >> 8))
            }
            return xFlag ? 4 : 5

        case 0x97: // STA (DP Indirect Long), Y
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let indirectAddr = (UInt32(bank) << 16) | UInt32(UInt16(high) << 8) | UInt32(low)
            let finalAddr = indirectAddr &+ UInt32(y)
            
            if m {
                memory.write(finalAddr, data: UInt8(a & 0xFF))
            } else {
                writeWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF), data: a)
            }
            return m ? 6 : 7
            
        case 0x98: // TYA (Transfer Y to A)
            if m {
                a = (a & 0xFF00) | (y & 0x00FF)
                updateP(a & 0xFF)
            } else {
                a = y
                updateP(a)
            }
            return 2

        case 0x99: // STA (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ y
            if m {
                memory.write(bank: db, addr: addr, data: UInt8(a & 0xFF))
            } else {
                writeWord(bank: db, addr: addr, data: a)
            }
            return m ? 4 : 5

        case 0x9A: // TXS (Transfer X to S)
            s = x
            return 2
        
        case 0x9B: // TXY (Transfer X to Y)
            if xFlag { y = (y & 0xFF00) | (x & 0x00FF); updateP(y & 0xFF) }
            else { y = x; updateP(y) }
            return 2
            
        case 0x9C: // STZ (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                memory.write(bank: db, addr: addr, data: 0x00)
            } else {
                memory.write(bank: db, addr: addr, data: 0x00)
                memory.write(bank: db, addr: addr &+ 1, data: 0x00)
            }
            return m ? 4 : 5
            
        case 0x9D: // STA (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                memory.write(bank: db, addr: addr, data: UInt8(a & 0xFF))
            } else {
                memory.write(bank: db, addr: addr, data: UInt8(a & 0xFF))
                memory.write(bank: db, addr: addr &+ 1, data: UInt8(a >> 8))
            }
            return m ? 5 : 6
            
        case 0x9E: // STX (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ y
            if xFlag {
                memory.write(bank: db, addr: finalAddr, data: UInt8(x & 0xFF))
            } else {
                memory.write(bank: db, addr: finalAddr, data: UInt8(x & 0xFF))
                memory.write(bank: db, addr: finalAddr &+ 1, data: UInt8(x >> 8))
            }
            return xFlag ? 5 : 6
            
        case 0x9F: // STA (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ x
            if m {
                memory.write(bank: bank, addr: finalAddr, data: UInt8(a & 0xFF))
            } else {
                memory.write(bank: bank, addr: finalAddr, data: UInt8(a & 0xFF))
                memory.write(bank: bank, addr: finalAddr &+ 1, data: UInt8(a >> 8))
            }
            return m ? 5 : 6
            
        case 0xA0: // LDY #Immediate
            if xFlag {
                y = (y & 0xFF00) | UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(y & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                y = (UInt16(high) << 8) | UInt16(low); updateP(y)
            }
            return xFlag ? 2 : 3
            
        case 0xA1: // LDA (DP Indirect, X)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getIndirectAddr(dpAddr: dpAddr, indexedBy: x)
            a = readData(from: finalAddr)
            updateP(a)
            return 6
            
        case 0xA2: // LDX #Immediate
            if xFlag {
                x = (x & 0xFF00) | UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(x & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                x = (UInt16(high) << 8) | UInt16(low); updateP(x)
            }
            return xFlag ? 2 : 3
            
        case 0xA3: // LDA (Stack Relative)
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: 0x01, addr: sr_addr))
                updateP(a & 0xFF)
            } else {
                a = readWord(bank: 0x01, addr: sr_addr)
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0xA4: // LDY (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if xFlag {
                y = (y & 0xFF00) | UInt16(memory.read(bank: 0, addr: addr))
                updateP(y & 0xFF)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                y = (UInt16(high) << 8) | UInt16(low)
                updateP(y)
            }
            return xFlag ? 3 : 4
            
        case 0xA5: // LDA (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: 0, addr: addr))
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                a = (UInt16(high) << 8) | UInt16(low)
                updateP(a)
            }
            return m ? 3 : 4
            
        case 0xA6: // LDX (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if xFlag {
                x = (x & 0xFF00) | UInt16(memory.read(bank: 0, addr: addr))
                updateP(x & 0xFF)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                x = (UInt16(high) << 8) | UInt16(low)
                updateP(x)
            }
            return xFlag ? 3 : 4
            
        case 0xA7: // LDA (Absolute Long Indirect)
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let addrLow = memory.read(bank: 0, addr: dpAddr)
            let addrHigh = memory.read(bank: 0, addr: dpAddr &+ 1)
            let addrBank = memory.read(bank: 0, addr: dpAddr &+ 2)
            let finalAddr = (UInt32(addrBank) << 16) | UInt32(UInt16(addrHigh) << 8) | UInt32(addrLow)
            
            if m {
                let val = UInt16(memory.read(finalAddr))
                a = (a & 0xFF00) | val
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a = val
                updateP(a)
            }
            return m ? 6 : 7
            
        case 0xA8: // TAY (Transfer A to Y)
            if xFlag { y = (y & 0xFF00) | (a & 0x00FF); updateP(y & 0xFF) }
            else { y = a; updateP(y) }
            return 2
            
        case 0xA9: // LDA #Immediate
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                a = (UInt16(high) << 8) | UInt16(low); updateP(a)
            }
            return m ? 2 : 3
            
        case 0xAA: // TAX (Transfer A to X)
            if xFlag { x = (x & 0xFF00) | (a & 0x00FF); updateP(x & 0xFF) }
            else { x = a; updateP(x) }
            return 2
            
        case 0xAB: // PLB (Pull Data Bank Register)
            db = pop()
            updateP(UInt16(db))
            return 4

        case 0xAC: // LDY (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if xFlag {
                let val = memory.read(bank: db, addr: addr)
                y = (y & 0xFF00) | UInt16(val); updateP(y & 0xFF)
            } else {
                let valLow = memory.read(bank: db, addr: addr)
                let valHigh = memory.read(bank: db, addr: addr &+ 1)
                y = (UInt16(valHigh) << 8) | UInt16(valLow); updateP(y)
            }
            return xFlag ? 4 : 5

        case 0xAD: // LDA (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                a = (a & 0xFF00) | UInt16(val); updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: db, addr: addr)
                let high = memory.read(bank: db, addr: addr &+ 1)
                a = (UInt16(high) << 8) | UInt16(low)
                updateP(a)
            }
            return m ? 4 : 5

        case 0xAE: // LDX (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if xFlag {
                let val = memory.read(bank: db, addr: addr)
                x = (x & 0xFF00) | UInt16(val); updateP(x & 0xFF)
            } else {
                let low = memory.read(bank: db, addr: addr)
                let high = memory.read(bank: db, addr: addr &+ 1)
                x = (UInt16(high) << 8) | UInt16(low)
                updateP(x)
            }
            return xFlag ? 4 : 5
            
        case 0xAF: // LDA (Absolute Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let finalAddr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(finalAddr))
                updateP(a & 0xFF)
            } else {
                a = readWord(bank: bank, addr: UInt16(finalAddr & 0xFFFF))
                updateP(a)
            }
            return m ? 5 : 6
            
        case 0xB0: // BCS (Branch if Carry Set)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.C.rawValue) != 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0xB1: // LDA (DP Indirect), Y
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let (finalAddr, pageCrossed) = getIndexedIndirectAddr(dpAddr: dpAddr, indexedBy: y)
            a = readData(from: finalAddr)
            updateP(a)
            return m ? (pageCrossed ? 6 : 5) : (pageCrossed ? 6 : 5)
            
        case 0xB2: // LDA (DP Indirect)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getDPIndirectAddr(dpAddr: dpAddr)
            a = readData(from: finalAddr)
            updateP(a)
            return 5
            
        case 0xB3: // LDA (Stack Relative Indirect), Y
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0x01, addr: sr_addr & 0xFF)
            let high = memory.read(bank: 0x01, addr: (sr_addr &+ 1) & 0xFF)
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(db) << 16 | UInt32(indirectAddr &+ y)
            
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(finalAddr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a = val
                updateP(a)
            }
            return m ? 5 : 6
            
        case 0xB4: // LDY (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if xFlag {
                y = (y & 0xFF00) | UInt16(memory.read(bank: 0, addr: addr))
                updateP(y & 0xFF)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                y = (UInt16(high) << 8) | UInt16(low)
                updateP(y)
            }
            return xFlag ? 4 : 5

        case 0xB5: // LDA (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: 0, addr: addr))
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                a = (UInt16(high) << 8) | UInt16(low)
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0xB6: // LDX (DP, Y)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ y; pc &+= 1
            if xFlag {
                x = (x & 0xFF00) | UInt16(memory.read(bank: 0, addr: addr))
                updateP(x & 0xFF)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                x = (UInt16(high) << 8) | UInt16(low)
                updateP(x)
            }
            return xFlag ? 4 : 5
            
        case 0xB7: // LDA (DP Indirect Long), Y
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let indirectAddr = (UInt32(bank) << 16) | UInt32(UInt16(high) << 8) | UInt32(low)
            let finalAddr = indirectAddr &+ UInt32(y)
            
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(finalAddr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                a = val
                updateP(a)
            }
            return m ? 5 : 6
            
        case 0xB8: clv(); return 2
            
        case 0xB9: // LDA (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ y
            let finalAddr = addr
            
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: db, addr: finalAddr))
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: db, addr: finalAddr)
                let high = memory.read(bank: db, addr: finalAddr &+ 1)
                a = (UInt16(high) << 8) | UInt16(low)
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0xBA: // TSX (Transfer S to X)
            if xFlag { x = (x & 0xFF00) | (s & 0x00FF); updateP(x & 0xFF) }
            else { x = s; updateP(x) }
            return 2
            
        case 0xBB: // TYX (Transfer Y to X)
            if xFlag { x = (x & 0xFF00) | (y & 0x00FF); updateP(x & 0xFF) }
            else { x = y; updateP(x) }
            return 2
            
        case 0xBC: // LDY (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ x
            
            if xFlag {
                y = (y & 0xFF00) | UInt16(memory.read(bank: db, addr: finalAddr))
                updateP(y & 0xFF)
            } else {
                let low = memory.read(bank: db, addr: finalAddr)
                let high = memory.read(bank: db, addr: finalAddr &+ 1)
                y = (UInt16(high) << 8) | UInt16(low)
                updateP(y)
            }
            return xFlag ? 4 : 5
            
        case 0xBD: // LDA (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ x
            
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: db, addr: finalAddr))
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: db, addr: finalAddr)
                let high = memory.read(bank: db, addr: finalAddr &+ 1)
                a = (UInt16(high) << 8) | UInt16(low)
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0xBE: // LDX (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ y
            
            if xFlag {
                x = (x & 0xFF00) | UInt16(memory.read(bank: db, addr: finalAddr))
                updateP(x & 0xFF)
            } else {
                let low = memory.read(bank: db, addr: finalAddr)
                let high = memory.read(bank: db, addr: finalAddr &+ 1)
                x = (UInt16(high) << 8) | UInt16(low)
                updateP(x)
            }
            return xFlag ? 4 : 5
            
        case 0xBF: // LDA (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            let finalAddr = addr &+ UInt32(x)
            
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(finalAddr))
                updateP(a & 0xFF)
            } else {
                a = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                updateP(a)
            }
            return m ? 5 : 6

        case 0xC0: // CPY #Immediate
            if xFlag {
                let val = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                compare(y & 0xFF, val)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                compare(y, val)
            }
            return xFlag ? 2 : 3
            
        case 0xC1: // CMP (DP Indirect, X)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getIndirectAddr(dpAddr: dpAddr, indexedBy: x)
            let val = readData(from: finalAddr)
            compare(a, val)
            return 6
            
        case 0xC2: // REP (Reset Processor Status bits)
            let mask = memory.read(bank: pbr, addr: pc); pc &+= 1
            
            let oldM = m
            let oldX = xFlag
            p &= ~mask
            
            if oldM && !m { a &= 0x00FF }
            if oldX && !xFlag { x &= 0x00FF; y &= 0x00FF }
            
            updateP(a)
            return 3
            
        case 0xC3: // CMP (Stack Relative)
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let comp = m ? (a & 0xFF) : a
            let val: UInt16
            if m {
                val = UInt16(memory.read(bank: 0x01, addr: sr_addr))
            } else {
                val = readWord(bank: 0x01, addr: sr_addr)
            }
            compare(comp, val)
            return m ? 4 : 5
            
        case 0xC4: // CPY (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let comp = xFlag ? (y & 0xFF) : y
            let val: UInt16
            if xFlag {
                val = UInt16(memory.read(bank: 0, addr: addr))
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                val = (UInt16(high) << 8) | UInt16(low)
            }
            compare(comp, val)
            return xFlag ? 3 : 4

        case 0xC5: // CMP (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let comp = m ? (a & 0xFF) : a
            let val: UInt16
            if m {
                val = UInt16(memory.read(bank: 0, addr: addr))
            } else {
                val = readWord(bank: 0, addr: addr)
            }
            compare(comp, val)
            return m ? 3 : 4
            
        case 0xC6: // DEC (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr) &- 1
                memory.write(bank: 0, addr: addr, data: val)
                updateP(UInt16(val))
            } else {
                let val = readWord(bank: 0, addr: addr) &- 1
                writeWord(bank: 0, addr: addr, data: val)
                updateP(val)
            }
            return m ? 5 : 6
            
        case 0xC7: // CMP (DP Indirect Long)
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let finalAddr = UInt32(bank) << 16 | UInt32(UInt16(high) << 8) | UInt32(low)
            
            let comp = m ? (a & 0xFF) : a
            let val: UInt16
            if m {
                val = UInt16(memory.read(finalAddr))
            } else {
                val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
            }
            compare(comp, val)
            return m ? 6 : 7
            
        case 0xC8: // INY (Increment Y)
            if xFlag {
                y = (y & 0xFF00) | ((y & 0xFF) &+ 1)
                updateP(y & 0xFF)
            } else {
                y &+= 1
                updateP(y)
            }
            return 2
            
        case 0xC9: // CMP #Immediate
            if m {
                let val = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                compare(a & 0xFF, val)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                compare(a, val)
            }
            return m ? 2 : 3
            
        case 0xCA: // DEX
            if xFlag {
                x = (x & 0xFF00) | ((x & 0xFF) &- 1)
                updateP(x & 0xFF)
            } else {
                x &-= 1
                updateP(x)
            }
            return 2
            
        case 0xCB: // WAI (Wait for Interrupt)
            stopped = true
            return 3
            
        case 0xCC: // CPY (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let comp = xFlag ? (y & 0xFF) : y
            let val: UInt16
            if xFlag {
                val = UInt16(memory.read(bank: db, addr: addr))
            } else {
                val = readWord(bank: db, addr: addr)
            }
            compare(comp, val)
            return xFlag ? 4 : 5
            
        case 0xCD: // CMP (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let val = m ? UInt16(memory.read(bank: db, addr: addr)) : readWord(bank: db, addr: addr)
            let comp = m ? (a & 0xFF) : a
            compare(comp, val)
            return m ? 4 : 5
            
        case 0xCE: // DEC (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr) &- 1
                memory.write(bank: db, addr: addr, data: val)
                updateP(UInt16(val))
            } else {
                let val = readWord(bank: db, addr: addr) &- 1
                writeWord(bank: db, addr: addr, data: val)
                updateP(val)
            }
            return m ? 6 : 7
            
        case 0xCF: // CMP (Absolute Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let finalAddr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            
            let comp = m ? (a & 0xFF) : a
            let val: UInt16
            if m {
                val = UInt16(memory.read(finalAddr))
            } else {
                val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
            }
            compare(comp, val)
            return m ? 5 : 6

        case 0xD0: // BNE (Branch if Not Equal)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.Z.rawValue) == 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0xD1: // CMP (DP Indirect), Y
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let (finalAddr, pageCrossed) = getIndexedIndirectAddr(dpAddr: dpAddr, indexedBy: y)
            let val = readData(from: finalAddr)
            compare(a, val)
            return m ? (pageCrossed ? 6 : 5) : (pageCrossed ? 6 : 5)
            
        case 0xD2: // CMP (DP Indirect)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getDPIndirectAddr(dpAddr: dpAddr)
            let val = readData(from: finalAddr)
            compare(a, val)
            return 5
            
        case 0xD3: // CMP (Stack Relative Indirect), Y
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0x01, addr: sr_addr & 0xFF)
            let high = memory.read(bank: 0x01, addr: (sr_addr &+ 1) & 0xFF)
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(db) << 16 | UInt32(indirectAddr &+ y)
            
            let comp = m ? (a & 0xFF) : a
            let val: UInt16
            if m {
                val = UInt16(memory.read(finalAddr))
            } else {
                val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
            }
            compare(comp, val)
            return m ? 5 : 6
            
        case 0xD4: // PEI (Push Effective Indirect)
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0, addr: dpAddr)
            let high = memory.read(bank: 0, addr: dpAddr &+ 1)
            let effectiveAddr = (UInt16(high) << 8) | UInt16(low)
            pushWord(effectiveAddr)
            return 6
            
        case 0xD5: // CMP (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            let comp = m ? (a & 0xFF) : a
            let val: UInt16
            if m {
                val = UInt16(memory.read(bank: 0, addr: addr))
            } else {
                val = readWord(bank: 0, addr: addr)
            }
            compare(comp, val)
            return m ? 4 : 5
            
        case 0xD6: // DEC (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr) &- 1
                memory.write(bank: 0, addr: addr, data: val)
                updateP(UInt16(val))
            } else {
                let val = readWord(bank: 0, addr: addr) &- 1
                writeWord(bank: 0, addr: addr, data: val)
                updateP(val)
            }
            return m ? 6 : 7
            
        case 0xD7: // CMP (DP Indirect Long), Y
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let indirectAddr = (UInt32(bank) << 16) | UInt32(UInt16(high) << 8) | UInt32(low)
            let finalAddr = indirectAddr &+ UInt32(y)
            
            let comp = m ? (a & 0xFF) : a
            let val: UInt16
            if m {
                val = UInt16(memory.read(finalAddr))
            } else {
                val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
            }
            compare(comp, val)
            return m ? 6 : 7
            
        case 0xD8: cld(); return 2

        case 0xD9: // CMP (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ y
            let val = m ? UInt16(memory.read(bank: db, addr: addr)) : readWord(bank: db, addr: addr)
            let comp = m ? (a & 0xFF) : a
            compare(comp, val)
            return m ? 4 : 5

        case 0xDA: // PHX (Push X)
            if xFlag { push(UInt8(x & 0xFF)) } else { pushWord(x) }
            return xFlag ? 3 : 4

        case 0xDB: // STP (SToP the processor)
            stopped = true
            return 3

        case 0xDC: // JMP (Absolute Indirect Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            
            let pcLow = memory.read(bank: pbr, addr: addr)
            let pcHigh = memory.read(bank: pbr, addr: addr &+ 1)
            let pbrNew = memory.read(bank: pbr, addr: addr &+ 2)
            
            pc = (UInt16(pcHigh) << 8) | UInt16(pcLow)
            pbr = pbrNew
            return 6

        case 0xDD: // CMP (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            let val = m ? UInt16(memory.read(bank: db, addr: addr)) : readWord(bank: db, addr: addr)
            let comp = m ? (a & 0xFF) : a
            compare(comp, val)
            return m ? 4 : 5

        case 0xDE: // DEC (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: db, addr: addr) &- 1
                memory.write(bank: db, addr: addr, data: val)
                updateP(UInt16(val))
            } else {
                let val = readWord(bank: db, addr: addr) &- 1
                writeWord(bank: db, addr: addr, data: val)
                updateP(val)
            }
            return m ? 7 : 8

        case 0xDF: // SBC (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(bank) << 16 | UInt32(addr &+ x)
            if m {
                let val = memory.read(finalAddr)
                sbc8(val)
            } else {
                let val = readWord(bank: bank, addr: addr &+ x)
                sbc16(val)
            }
            return m ? 5 : 6

        case 0xE0: // CPX #Immediate
            if xFlag {
                let val = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                compare(x & 0xFF, val)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                compare(x, val)
            }
            return xFlag ? 2 : 3
            
        case 0xE1: // SBC (DP Indirect, X)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getIndirectAddr(dpAddr: dpAddr, indexedBy: x)
            let val = readData(from: finalAddr)
            if m { sbc8(UInt8(val & 0xFF)) } else { sbc16(val) }
            return 6
            
        case 0xE2: // SEP (Set Processor Status bits)
            let mask = memory.read(bank: pbr, addr: pc); pc &+= 1
            
            let oldM = m
            let oldX = xFlag
            p |= mask
            
            if oldM && !m { a &= 0x00FF }
            if oldX && !xFlag { x &= 0x00FF; y &= 0x00FF }
            
            updateP(a)
            return 3

        case 0xE3: // SBC (Stack Relative)
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0x01, addr: sr_addr)
                sbc8(val)
            } else {
                let val = readWord(bank: 0x01, addr: sr_addr)
                sbc16(val)
            }
            return m ? 4 : 5
            
        case 0xE4: // CPX (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let comp = xFlag ? (x & 0xFF) : x
            let val: UInt16
            if xFlag {
                val = UInt16(memory.read(bank: 0, addr: addr))
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                val = (UInt16(high) << 8) | UInt16(low)
            }
            compare(comp, val)
            return xFlag ? 3 : 4
            
        case 0xE5: // SBC (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                sbc8(val)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                sbc16(val)
            }
            return m ? 3 : 4
            
        case 0xE6: // INC (Direct Page)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr) &+ 1
                memory.write(bank: 0, addr: addr, data: val)
                updateP(UInt16(val))
            } else {
                let val = readWord(bank: 0, addr: addr) &+ 1
                writeWord(bank: 0, addr: addr, data: val)
                updateP(val)
            }
            return m ? 5 : 6
            
        case 0xE7: // SBC (DP Indirect Long)
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let finalAddr = UInt32(bank) << 16 | UInt32(UInt16(high) << 8) | UInt32(low)
            
            if m {
                let val = memory.read(finalAddr)
                sbc8(val)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                sbc16(val)
            }
            return m ? 6 : 7
            
        case 0xE8: // INX (Increment X)
            if xFlag {
                x = (x & 0xFF00) | ((x & 0xFF) &+ 1)
                updateP(x & 0xFF)
            } else {
                x &+= 1
                updateP(x)
            }
            return 2
            
        case 0xE9: // SBC #Immediate
            if m {
                let val = memory.read(bank: pbr, addr: pc); pc &+= 1
                sbc8(val)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                let val = (UInt16(high) << 8) | UInt16(low)
                sbc16(val)
            }
            return m ? 2 : 3
            
        case 0xEA: // NOP
            return 2
            
        case 0xEB: // XBA (Exchange B/A)
            let b = (a >> 8) & 0xFF
            let aLow = a & 0xFF
            a = (aLow << 8) | b
            updateP(a & 0xFF)
            return 3
            
        case 0xEC: // CPX (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let comp = xFlag ? (x & 0xFF) : x
            let val: UInt16
            if xFlag {
                val = UInt16(memory.read(bank: db, addr: addr))
            } else {
                val = readWord(bank: db, addr: addr)
            }
            compare(comp, val)
            return xFlag ? 4 : 5
            
        case 0xED: // SBC (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                sbc8(val)
            } else {
                let low = memory.read(bank: db, addr: addr)
                let high = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                sbc16(val)
            }
            return m ? 4 : 5
            
        case 0xEE: // INC (Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr) &+ 1
                memory.write(bank: db, addr: addr, data: val)
                updateP(UInt16(val))
            } else {
                let val = readWord(bank: db, addr: addr) &+ 1
                writeWord(bank: db, addr: addr, data: val)
                updateP(val)
            }
            return m ? 6 : 7
            
        case 0xEF: // SBC (Absolute Long)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let finalAddr = (UInt32(bank) << 16) | UInt32((UInt16(high) << 8) | UInt16(low))
            
            if m {
                let val = memory.read(finalAddr)
                sbc8(val)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                sbc16(val)
            }
            return m ? 5 : 6

        case 0xF0: // BEQ (Branch if Equal)
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.Z.rawValue) != 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0xF1: // SBC (DP Indirect), Y
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let (finalAddr, pageCrossed) = getIndexedIndirectAddr(dpAddr: dpAddr, indexedBy: y)
            let val = readData(from: finalAddr)
            if m { sbc8(UInt8(val & 0xFF)) } else { sbc16(val) }
            return m ? (pageCrossed ? 6 : 5) : (pageCrossed ? 6 : 5)
            
        case 0xF2: // SBC (DP Indirect)
            let dpAddr = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let finalAddr = getDPIndirectAddr(dpAddr: dpAddr)
            let val = readData(from: finalAddr)
            if m { sbc8(UInt8(val & 0xFF)) } else { sbc16(val) }
            return 5
            
        case 0xF3: // SBC (Stack Relative Indirect), Y
            let sr_addr = s &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0x01, addr: sr_addr & 0xFF)
            let high = memory.read(bank: 0x01, addr: (sr_addr &+ 1) & 0xFF)
            let indirectAddr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(db) << 16 | UInt32(indirectAddr &+ y)
            
            if m {
                let val = memory.read(finalAddr)
                sbc8(val)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                sbc16(val)
            }
            return m ? 5 : 6
            
        case 0xF4: // PEA (Push Effective Absolute)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            pushWord(addr)
            return 5
            
        case 0xF5: // SBC (Direct Page, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                sbc8(val)
            } else {
                let low = memory.read(bank: 0, addr: addr)
                let high = memory.read(bank: 0, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                sbc16(val)
            }
            return m ? 4 : 5
            
        case 0xF6: // INC (DP, X)
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr) &+ 1
                memory.write(bank: 0, addr: addr, data: val)
                updateP(UInt16(val))
            } else {
                let val = readWord(bank: 0, addr: addr) &+ 1
                writeWord(bank: 0, addr: addr, data: val)
                updateP(val)
            }
            return m ? 6 : 7
            
        case 0xF7: // SBC (DP Indirect Long), Y
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let low = memory.read(bank: 0, addr: dpAddr & 0xFFFF)
            let high = memory.read(bank: 0, addr: (dpAddr &+ 1) & 0xFFFF)
            let bank = memory.read(bank: 0, addr: (dpAddr &+ 2) & 0xFFFF)
            let indirectAddr = (UInt32(bank) << 16) | UInt32(UInt16(high) << 8) | UInt32(low)
            let finalAddr = indirectAddr &+ UInt32(y)
            
            if m {
                let val = memory.read(finalAddr)
                sbc8(val)
            } else {
                let val = readWord(bank: UInt8(finalAddr >> 16), addr: UInt16(finalAddr & 0xFFFF))
                sbc16(val)
            }
            return m ? 6 : 7
            
        case 0xF8: sed(); return 2

        case 0xF9: // SBC (Absolute, Y)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ y
            if m {
                let val = memory.read(bank: db, addr: addr)
                sbc8(val)
            } else {
                let low = memory.read(bank: db, addr: addr)
                let high = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                sbc16(val)
            }
            return m ? 4 : 5
            
        case 0xFA: // PLX (Pull X)
            if xFlag { x = (x & 0xFF00) | UInt16(pop()); updateP(x & 0xFF) }
            else { x = popWord(); updateP(x) }
            return xFlag ? 4 : 5
            
        case 0xFB: // XCE (Exchange Carry and Emulation flags)
            let oldE = e
            let oldC = (p & Flag.C.rawValue) != 0
            if oldC { p |= 0x01 } else { p &= ~0x01 }
            if oldE { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }

            if e {
                p |= Flag.M.rawValue
                p |= Flag.X.rawValue
                a &= 0x00FF
                x &= 0x00FF
                y &= 0x00FF
                s = (s & 0xFF) | 0x0100
            }
            return 2
            
        case 0xFC: // JSR (Absolute Indirect, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let indirectAddr = readWord(bank: pbr, addr: addr &+ x)
            pushWord(pc - 1)
            pc = indirectAddr
            return 6
            
        case 0xFD: // SBC (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: db, addr: addr)
                sbc8(val)
            } else {
                let low = memory.read(bank: db, addr: addr)
                let high = memory.read(bank: db, addr: addr &+ 1)
                let val = (UInt16(high) << 8) | UInt16(low)
                sbc16(val)
            }
            return m ? 4 : 5
            
        case 0xFE: // INC (Absolute, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: db, addr: addr) &+ 1
                memory.write(bank: db, addr: addr, data: val)
                updateP(UInt16(val))
            } else {
                let val = readWord(bank: db, addr: addr) &+ 1
                writeWord(bank: db, addr: addr, data: val)
                updateP(val)
            }
            return m ? 7 : 8

        case 0xFF: // SBC (Absolute Long, X)
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = UInt32(bank) << 16 | UInt32(addr &+ x)
            
            if m {
                let val = memory.read(finalAddr)
                sbc8(val)
            } else {
                let val = readWord(bank: bank, addr: addr &+ x)
                sbc16(val)
            }
            return m ? 5 : 6
            
        default:
            print("Unimplemented opcode: \(String(format: "0x%02X", opcode)) at \(String(format: "%02X:%04X", pbr, pc &- 1))")
            return 1
        }
    }
    
    func pop() -> UInt8 {
        s &+= 1
        let data = memory!.read(bank: e ? 0x01 : 0x00, addr: s)
        if e { s = (s & 0xFF) | 0x0100 }
        return data
    }
    
    func popWord() -> UInt16 {
        let low = pop()
        let high = pop()
        return (UInt16(high) << 8) | UInt16(low)
    }
    
    func push(_ data: UInt8) {
        memory?.write(bank: e ? 0x01 : 0x00, addr: s, data: data)
        s &-= 1
        if e { s = (s & 0xFF) | 0x0100 }
    }
    
    func pushWord(_ data: UInt16) {
        push(UInt8(data >> 8))
        push(UInt8(data & 0xFF))
    }
    
    // NOTE: readWord is retained for cleaner access outside of the main step() loop.
    func readWord(bank: UInt8, addr: UInt16) -> UInt16 {
        guard let memory = memory else { return 0 }
        let low = memory.read(bank: bank, addr: addr)
        let high = memory.read(bank: bank, addr: addr &+ 1)
        return (UInt16(high) << 8) | UInt16(low)
    }
    
    func writeWord(bank: UInt8, addr: UInt16, data: UInt16) {
        guard let memory = memory else { return }
        memory.write(bank: bank, addr: addr, data: UInt8(data & 0xFF))
        memory.write(bank: bank, addr: addr &+ 1, data: UInt8(data >> 8))
    }
    
    func bit(addr: UInt16, bank: UInt8) {
        if m {
            let val = UInt16(memory!.read(bank: bank, addr: addr))
            bit(val: val & 0xFF)
            
            if (val & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            if (val & 0x40) != 0 { p |= Flag.V.rawValue } else { p &= ~Flag.V.rawValue }
        } else {
            let val = readWord(bank: bank, addr: addr)
            bit(val: val)
            
            if (val & 0x8000) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
            if (val & 0x4000) != 0 { p |= Flag.V.rawValue } else { p &= ~Flag.V.rawValue }
        }
    }
    
    func bit(val: UInt16) {
        let result = a & val
        if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
    }
    
    func compare(_ a: UInt16, _ b: UInt16) {
        let (result, _) = a.subtractingReportingOverflow(b)
        if a >= b { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
        if result == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let checkN = m ? (result & 0x80) : (result & 0x8000)
        if (checkN != 0) { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
    }
    
    func adc8(_ val: UInt8) {
        let carry: UInt8 = (p & Flag.C.rawValue) != 0 ? 1 : 0
        let aLow = UInt8(a & 0xFF)
        let result = UInt16(aLow) + UInt16(val) + UInt16(carry)
        
        let overflowCheck: UInt8 = (aLow ^ val) & 0x80
        let resultCheck: UInt8 = (aLow ^ UInt8(result & 0xFF)) & 0x80
        let overflow = (overflowCheck == 0) && (resultCheck != 0)
        
        if overflow { p |= Flag.V.rawValue } else { p &= ~Flag.V.rawValue }
        
        if result > 0xFF { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
        
        a = (a & 0xFF00) | (result & 0xFF)
        let finalResult = a & 0xFF
        if finalResult == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        if (finalResult & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
    }
    
    func adc16(_ val: UInt16) {
        let carry: UInt16 = (p & Flag.C.rawValue) != 0 ? 1 : 0
        let result = UInt32(a) + UInt32(val) + UInt32(carry)
        
        let overflowCheck: UInt16 = (a ^ val) & 0x8000
        let resultCheck: UInt16 = (a ^ UInt16(result & 0xFFFF)) & 0x8000
        let overflow = (overflowCheck == 0) && (resultCheck != 0)
        
        if overflow { p |= Flag.V.rawValue } else { p &= ~Flag.V.rawValue }
        
        if result > 0xFFFF { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
        
        a = UInt16(result & 0xFFFF)
        updateP(a)
    }
    
    func sbc8(_ val: UInt8) {
        let carry: UInt8 = (p & Flag.C.rawValue) != 0 ? 0 : 1
        let aLow = UInt8(a & 0xFF)
        
        let result = Int16(aLow) - Int16(val) - Int16(carry)
        let newA = UInt8(result & 0xFF)
        
        if result >= 0 { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
        
        let overflow = (aLow ^ val) & 0x80
        let resultCheck = (aLow ^ newA) & 0x80
        
        if (overflow == 0) && (resultCheck != 0) { p |= Flag.V.rawValue } else { p &= ~Flag.V.rawValue }
        
        a = (a & 0xFF00) | UInt16(newA)
        let finalResult = a & 0xFF
        if finalResult == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        if (finalResult & 0x80) != 0 { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
    }

    func sbc16(_ val: UInt16) {
        let carry: UInt16 = (p & Flag.C.rawValue) != 0 ? 0 : 1
        
        let result = Int32(a) - Int32(val) - Int32(carry)
        let newA = UInt16(result & 0xFFFF)
        
        if result >= 0 { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }

        let overflow = (a ^ val) & 0x8000
        let resultCheck = (a ^ newA) & 0x8000
        
        if (overflow == 0) && (resultCheck != 0) { p |= Flag.V.rawValue } else { p &= ~Flag.V.rawValue }

        a = newA
        updateP(a)
    }
    
    func tsb8(addr: UInt16, bank: UInt8) -> (UInt8, Int) {
        guard memory != nil else { return (0, 0) }
        
        let val = self.memory!.read(bank: bank, addr: addr)
        let test = val & UInt8(a & 0xFF)
        
        if test == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let newVal = val | UInt8(a & 0xFF)
        return (newVal, 7)
    }
    
    func tsb16(addr: UInt16, bank: UInt8) -> (UInt16, Int) {
        guard memory != nil else { return (0, 0) }
        
        let val = readWord(bank: bank, addr: addr)
        let test = val & a
        
        if test == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let newVal = val | a
        return (newVal, 8)
    }
    
    func trb8(addr: UInt16, bank: UInt8) -> (UInt8, Int) {
        guard memory != nil else { return (0, 0) }
        
        let val = self.memory!.read(bank: bank, addr: addr)
        let test = val & UInt8(a & 0xFF)
        
        if test == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let newVal = val & ~UInt8(a & 0xFF)
        return (newVal, 7)
    }
    
    func trb16(addr: UInt16, bank: UInt8) -> (UInt16, Int) {
        guard memory != nil else { return (0, 0) }
        
        let val = readWord(bank: bank, addr: addr)
        let test = val & a
        
        if test == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let newVal = val & ~a
        return (newVal, 8)
    }
    
    func rol8(_ val: UInt8) -> (UInt8, Bool) {
        let carry: UInt8 = (p & Flag.C.rawValue) != 0 ? 1 : 0
        let newCarry = (val & 0x80) != 0
        let result = (val << 1) | carry
        return (result, newCarry)
    }
    
    func rol16(_ val: UInt16) -> (UInt16, Bool) {
        let carry: UInt16 = (p & Flag.C.rawValue) != 0 ? 1 : 0
        let newCarry = (val & 0x8000) != 0
        let result = (val << 1) | carry
        return (result, newCarry)
    }
    
    func ror8(_ val: UInt8) -> (UInt8, Bool) {
        let newCarry = (val & 0x01) != 0
        let carry: UInt8 = (p & Flag.C.rawValue) != 0 ? 0x80 : 0
        let result = (val >> 1) | carry
        return (result, newCarry)
    }
    
    func ror16(_ val: UInt16) -> (UInt16, Bool) {
        let newCarry = (val & 0x0001) != 0
        let carry: UInt16 = (p & Flag.C.rawValue) != 0 ? 0x8000 : 0
        let result = (val >> 1) | carry
        return (result, newCarry)
    }
    
    func lsr8(_ val: UInt8) -> (UInt8, Bool) {
        let newCarry = (val & 0x01) != 0
        let result = val >> 1
        return (result, newCarry)
    }
    
    func lsr16(_ val: UInt16) -> (UInt16, Bool) {
        let newCarry = (val & 0x0001) != 0
        let result = val >> 1
        return (result, newCarry)
    }
    
    func updateP(_ value: UInt16) {
        if (value == 0) { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let checkN: UInt16 = m ? (value & 0x80) : (value & 0x8000)
        if (checkN != 0) { p |= Flag.N.rawValue } else { p &= ~Flag.N.rawValue }
        
        if !m {
            p &= ~Flag.M.rawValue
        }
        
        if !xFlag {
            p &= ~Flag.X.rawValue
        }
    }
    
    func clc() { p &= ~Flag.C.rawValue }
    func sec() { p |= Flag.C.rawValue }
    func cli() { p &= ~Flag.I.rawValue }
    func sei() { p |= Flag.I.rawValue }
    func clv() { p &= ~Flag.V.rawValue }
    func cld() { p &= ~Flag.D.rawValue }
    func sed() { p |= Flag.D.rawValue }
    
    func debugStatus() -> String {
        let pString = String(p, radix: 2).padding(toLength: 8, withPad: "0", startingAt: 0)
        let flags = "NVMXDIZC\n\(pString)"
        
        return """
        PC: \(String(format: "%02X:%04X", pbr, pc))
        A:  \(String(format: "%04X", a))
        X:  \(String(format: "%04X", x))
        Y:  \(String(format: "%04X", y))
        S:  \(String(format: "%04X", s))
        D:  \(String(format: "%04X", d))
        DB: \(String(format: "%02X", db))
        P:  \(String(format: "%02X", p)) (\(flags))
        M: \(m)  X: \(xFlag)  E: \(e)
        Stopped: \(stopped)
        """
    }
}
