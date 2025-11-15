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

    func step() -> Int {
        guard let memory = memory, !stopped else { return 1 }
        
        let opcode = memory.read(bank: pbr, addr: pc)
        pc &+= 1
        
        switch opcode {
        
        case 0x01:
            pc &+= 1
            return 6
            
        case 0x02:
            pc &+= 1
            return 7
            
        case 0x03:
            pc &+= 1
            return 4
            
        case 0x04:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let (newVal, _) = tsb8(addr: addr, bank: 0)
                memory.write(bank: 0, addr: addr, data: newVal)
                return 5
            } else {
                let (newVal, _) = tsb16(addr: addr, bank: 0)
                writeWord(bank: 0, addr: addr, data: newVal)
                return 6
            }
            
        case 0x05:
            pc &+= 1
            return 3
            
        case 0x08:
            push(p)
            return 3
            
        case 0x0F:
            pc &+= 1
            return 4
            
        case 0x0A:
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
            
        case 0x0C:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let (newVal, _) = tsb8(addr: addr, bank: db)
                memory.write(bank: db, addr: addr, data: newVal)
                return 6
            } else {
                let (newVal, _) = tsb16(addr: addr, bank: db)
                writeWord(bank: db, addr: addr, data: newVal)
                return 7
            }
            
        case 0x0D:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(bank: db, addr: addr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: db, addr: addr)
                a |= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x10:
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.N.rawValue) == 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0x11:
            pc &+= 1
            return 5
            
        case 0x12:
            pc &+= 1
            return 5
            
        case 0x13:
            pc &+= 1
            return 5
            
        case 0x14:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let (newVal, _) = trb8(addr: addr, bank: 0)
                memory.write(bank: 0, addr: addr, data: newVal)
                return 5
            } else {
                let (newVal, _) = trb16(addr: addr, bank: 0)
                writeWord(bank: 0, addr: addr, data: newVal)
                return 6
            }
            
        case 0x19:
            pc &+= 2
            return 4
            
        case 0x1A:
            if m { a = (a & 0xFF00) | ((a & 0xFF) &+ 1); updateP(a & 0xFF) }
            else { a &+= 1; updateP(a) }
            return 2
            
        case 0x1B:
            if e {
                s = (0x0100) | (a & 0xFF)
            } else {
                s = a
            }
            return 3
            
        case 0x1C:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let (newVal, _) = trb8(addr: addr, bank: db)
                memory.write(bank: db, addr: addr, data: newVal)
                return 6
            } else {
                let (newVal, _) = trb16(addr: addr, bank: db)
                writeWord(bank: db, addr: addr, data: newVal)
                return 7
            }
            
        case 0x1D:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                a = (a & 0xFF00) | (a & 0xFF) | UInt16(memory.read(bank: db, addr: addr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: db, addr: addr)
                a |= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x18: clc(); return 2
            
        case 0x1E: // ASL (Absolute, X)
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

        case 0x20:
            let low = memory.read(bank: pbr, addr: pc)
            pc &+= 1
            let high = memory.read(bank: pbr, addr: pc)
            pushWord(pc &- 1)
            pc = (UInt16(high) << 8) | UInt16(low)
            return 6
            
        case 0x22:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            push(pbr); pushWord(pc &- 1)
            pbr = bank
            pc = (UInt16(high) << 8) | UInt16(low)
            return 8
            
        case 0x24:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            bit(addr: addr, bank: 0)
            return 3
            
        case 0x25:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                a = (a & 0xFF00) | (a & 0xFF & UInt16(memory.read(bank: 0, addr: addr)))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: 0, addr: addr)
                a &= val
                updateP(a)
            }
            return m ? 3 : 4
            
        case 0x26:
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
            
        case 0x28:
            p = pop()
            return 4
            
        case 0x29:
            if m {
                a = (a & 0xFF00) | (a & 0xFF & UInt16(memory.read(bank: pbr, addr: pc))); pc &+= 1
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: pbr, addr: pc); pc &+= 2
                a &= val
                updateP(a)
            }
            return m ? 2 : 3
            
        case 0x2C:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            bit(addr: addr, bank: db)
            return 4
            
        case 0x30:
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.N.rawValue) != 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0x34:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)) &+ x; pc &+= 1
            bit(addr: addr, bank: 0)
            return 4
            
        case 0x3C:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            bit(addr: addr, bank: db)
            return 4

        case 0x38: sec(); return 2
            
        case 0x3B:
            if e {
                s = (0x0100) | (a & 0xFF)
            } else {
                s = a
            }
            return 2
            
        case 0x40:
            p = pop()
            let pcLow = pop()
            let pcHigh = pop()
            pc = (UInt16(pcHigh) << 8) | UInt16(pcLow)
            pbr = pop()
            return 6
            
        case 0x41:
            pc &+= 1
            return 6
            
        case 0x42:
            pc &+= 1
            return 2
            
        case 0x43:
            pc &+= 1
            return 4
            
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
            
        case 0x45:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: 0, addr: addr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: 0, addr: addr)
                a ^= val
                updateP(a)
            }
            return m ? 3 : 4
            
        case 0x48:
            if m { push(UInt8(a & 0xFF)) } else { pushWord(a) }
            return m ? 3 : 4
            
        case 0x4A:
            if m {
                let val = a & 0xFF
                if (val & 0x01) != 0 { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                a = (a & 0xFF00) | (val >> 1); updateP(a & 0xFF)
            } else {
                if (a & 0x0001) != 0 { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
                a >>= 1; updateP(a)
            }
            return 2
            
        case 0x4B:
            push(pbr)
            return 3
            
        case 0x4C:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc)
            pc = (UInt16(high) << 8) | UInt16(low)
            return 3
            
        case 0x4D:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: db, addr: addr))
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: db, addr: addr)
                a ^= val
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0x49:
            if m {
                a = (a & 0xFF00) | (a & 0xFF) ^ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: pbr, addr: pc); pc &+= 2
                a ^= val
                updateP(a)
            }
            return m ? 2 : 3
            
        case 0x50:
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.V.rawValue) == 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
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
            
        case 0x5A:
            if xFlag { push(UInt8(y & 0xFF)) } else { pushWord(y) }
            return xFlag ? 3 : 4
            
        case 0x5B:
            d = a
            return 2
            
        case 0x58: cli(); return 2
            
        case 0x60:
            pc = popWord() &+ 1
            return 6
            
        case 0x62:
            let relLow = memory.read(bank: pbr, addr: pc); pc &+= 1
            let relHigh = memory.read(bank: pbr, addr: pc); pc &+= 1
            let relOffset = (UInt16(relHigh) << 8) | UInt16(relLow)
            let address = pc &+ relOffset
            pushWord(address)
            return 6
            
        case 0x64:
            pc &+= 1
            return 3
            
        case 0x68:
            if m { a = (a & 0xFF00) | UInt16(pop()); updateP(a & 0xFF) }
            else { a = popWord(); updateP(a) }
            return m ? 4 : 5
            
        case 0x65:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                adc8(val)
            } else {
                let val = readWord(bank: 0, addr: addr)
                adc16(val)
            }
            return m ? 3 : 4
            
        case 0x69:
            if m {
                let val = memory.read(bank: pbr, addr: pc); pc &+= 1
                adc8(val)
            } else {
                let val = readWord(bank: pbr, addr: pc); pc &+= 2
                adc16(val)
            }
            return m ? 2 : 3
            
        case 0x6D:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                adc8(val)
            } else {
                let val = readWord(bank: db, addr: addr)
                adc16(val)
            }
            return m ? 4 : 5
            
        case 0x6B:
            pc = popWord() &+ 1
            pbr = pop()
            return 6
            
        case 0x7C:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let indirectAddr = readWord(bank: pbr, addr: addr &+ x)
            pc = indirectAddr
            return 6
            
        case 0x7A:
            if xFlag { y = (y & 0xFF00) | UInt16(pop()); updateP(y & 0xFF) }
            else { y = popWord(); updateP(y) }
            return xFlag ? 4 : 5
            
        case 0x78: sei(); return 2
        case 0xB8: clv(); return 2
        case 0xD8: cld(); return 2
        case 0xF8: sed(); return 2
            
        case 0x80:
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            pc = pc &+ UInt16(bitPattern: Int16(offset))
            return 3
            
        case 0x81:
            pc &+= 1
            return 6
            
        case 0x82:
            pc &+= 1
            push(UInt8(pbr))
            pushWord(pc)
            push(p)
            p &= ~Flag.D.rawValue
            p |= Flag.I.rawValue
            
            pbr = 0
            let low = memory.read(bank: 0x00, addr: 0xFFFE)
            let high = memory.read(bank: 0x00, addr: 0xFFFF)
            pc = (UInt16(high) << 8) | UInt16(low)
            return 7
            
        case 0x85:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                memory.write(bank: 0, addr: addr, data: UInt8(a & 0xFF))
            } else {
                memory.write(bank: 0, addr: addr, data: UInt8(a & 0xFF))
                memory.write(bank: 0, addr: addr &+ 1, data: UInt8(a >> 8))
            }
            return m ? 3 : 4
            
        case 0x84:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if xFlag {
                memory.write(bank: 0, addr: addr, data: UInt8(y & 0xFF))
            } else {
                memory.write(bank: 0, addr: addr, data: UInt8(y & 0xFF))
                memory.write(bank: 0, addr: addr &+ 1, data: UInt8(y >> 8))
            }
            return xFlag ? 3 : 4
            
        case 0x86:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if xFlag {
                memory.write(bank: 0, addr: addr, data: UInt8(x & 0xFF))
            } else {
                memory.write(bank: 0, addr: addr, data: UInt8(x & 0xFF))
                memory.write(bank: 0, addr: addr &+ 1, data: UInt8(x >> 8))
            }
            return xFlag ? 3 : 4
            
        case 0x88:
            if xFlag {
                y = (y & 0xFF00) | ((y & 0xFF) &- 1)
                updateP(y & 0xFF)
            } else {
                y &-= 1
                updateP(y)
            }
            return 2
            
        case 0x89:
            if m {
                let val = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                bit(val: val & 0xFF)
                return 2
            } else {
                let val = readWord(bank: pbr, addr: pc); pc &+= 2
                bit(val: val)
                return 3
            }
            
        case 0x8B:
            push(db)
            return 3
            
        case 0x8C:
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
            
        case 0x8D:
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
            
        case 0x8E:
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
            
        case 0x8F:
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

        case 0x9C:
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
            
        case 0x98:
            if m { a = (a & 0xFF00) | (y & 0x00FF); updateP(a & 0xFF) }
            else { a = y; updateP(a) }
            return 2
            
        case 0x9E:
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
            
        case 0x9F:
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
            
        case 0x9B:
            if xFlag { y = (y & 0xFF00) | (x & 0x00FF); updateP(y & 0xFF) }
            else { y = x; updateP(y) }
            return 2

        case 0xA0:
            if xFlag {
                y = (y & 0xFF00) | UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(y & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                y = (UInt16(high) << 8) | UInt16(low); updateP(y)
            }
            return xFlag ? 2 : 3
            
        case 0xA1:
            pc &+= 1
            return 6
            
        case 0xA2:
            if xFlag {
                x = (x & 0xFF00) | UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(x & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                x = (UInt16(high) << 8) | UInt16(low); updateP(x)
            }
            return xFlag ? 2 : 3
            
        case 0xA4:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if xFlag {
                y = (y & 0xFF00) | UInt16(memory.read(bank: 0, addr: addr))
                updateP(y & 0xFF)
            } else {
                y = readWord(bank: 0, addr: addr)
                updateP(y)
            }
            return xFlag ? 3 : 4
            
        case 0xA5:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: 0, addr: addr))
                updateP(a & 0xFF)
            } else {
                a = readWord(bank: 0, addr: addr)
                updateP(a)
            }
            return m ? 3 : 4
            
        case 0xA7:
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let addrLow = memory.read(bank: 0, addr: dpAddr)
            let addrHigh = memory.read(bank: 0, addr: dpAddr &+ 1)
            let addrBank = memory.read(bank: 0, addr: dpAddr &+ 2)
            let addr = (UInt32(addrBank) << 16) | UInt32(UInt16(addrHigh) << 8) | UInt32(addrLow)
            
            if m {
                let val = UInt16(memory.read(addr))
                a = (a & 0xFF00) | val
                updateP(a & 0xFF)
            } else {
                let val = readWord(bank: UInt8(addr >> 16), addr: UInt16(addr & 0xFFFF))
                a = val
                updateP(a)
            }
            return m ? 6 : 7
            
        case 0xA8:
            if xFlag { y = (y & 0xFF00) | (a & 0x00FF); updateP(y & 0xFF) }
            else { y = a; updateP(y) }
            return 2
            
        case 0xAB:
            db = pop()
            updateP(UInt16(db))
            return 4

        case 0xAC:
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

        case 0xAD:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                a = (a & 0xFF00) | UInt16(val); updateP(a & 0xFF)
            } else {
                a = readWord(bank: db, addr: addr)
                updateP(a)
            }
            return m ? 4 : 5

        case 0xAE:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if xFlag {
                let val = memory.read(bank: db, addr: addr)
                x = (x & 0xFF00) | UInt16(val); updateP(x & 0xFF)
            } else {
                x = readWord(bank: db, addr: addr)
                updateP(x)
            }
            return xFlag ? 4 : 5
            
        case 0xA9:
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                updateP(a & 0xFF)
            } else {
                let low = memory.read(bank: pbr, addr: pc); pc &+= 1
                let high = memory.read(bank: pbr, addr: pc); pc &+= 1
                a = (UInt16(high) << 8) | UInt16(low); updateP(a)
            }
            return m ? 2 : 3
            
        case 0xAA:
            if xFlag { x = (x & 0xFF00) | (a & 0x00FF); updateP(x & 0xFF) }
            else { x = a; updateP(x) }
            return 2
            
        case 0xBA:
            if xFlag { x = (x & 0xFF00) | (s & 0x00FF); updateP(x & 0xFF) }
            else { x = s; updateP(x) }
            return 2
            
        case 0xB0:
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.C.rawValue) != 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0xB7:
            pc &+= 1
            return 5
            
        case 0xB9:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ y
            
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: db, addr: finalAddr))
                updateP(a & 0xFF)
            } else {
                a = readWord(bank: db, addr: finalAddr)
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0xBD:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ x
            
            if m {
                a = (a & 0xFF00) | UInt16(memory.read(bank: db, addr: finalAddr))
                updateP(a & 0xFF)
            } else {
                a = readWord(bank: db, addr: finalAddr)
                updateP(a)
            }
            return m ? 4 : 5
            
        case 0xBC:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ x
            
            if xFlag {
                y = (y & 0xFF00) | UInt16(memory.read(bank: db, addr: finalAddr))
                updateP(y & 0xFF)
            } else {
                y = readWord(bank: db, addr: finalAddr)
                updateP(y)
            }
            return xFlag ? 4 : 5
            
        case 0xBE:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let finalAddr = addr &+ y
            
            if xFlag {
                x = (x & 0xFF00) | UInt16(memory.read(bank: db, addr: finalAddr))
                updateP(x & 0xFF)
            } else {
                x = readWord(bank: db, addr: finalAddr)
                updateP(x)
            }
            return xFlag ? 4 : 5
            
        case 0xCC:
            pc &+= 2
            return 4
            
        case 0xCD:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            let val = m ? UInt16(memory.read(bank: db, addr: addr)) : readWord(bank: db, addr: addr)
            let comp = m ? (a & 0xFF) : a
            compare(comp, val)
            return m ? 4 : 5
            
        case 0xC9:
            if m {
                let val = UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
                compare(a & 0xFF, val)
            } else {
                let val = readWord(bank: pbr, addr: pc); pc &+= 2
                compare(a, val)
            }
            return m ? 2 : 3
            
        case 0xC2:
            let mask = memory.read(bank: pbr, addr: pc); pc &+= 1
            
            let oldM = m
            let oldX = xFlag
            p &= ~mask
            
            if oldM && !m { a &= 0x00FF }
            if oldX && !xFlag { x &= 0x00FF; y &= 0x00FF }
            
            updateP(a)
            return 3
            
        case 0xC8:
            if xFlag {
                y = (y & 0xFF00) | ((y & 0xFF) &+ 1)
                updateP(y & 0xFF)
            } else {
                y &+= 1
                updateP(y)
            }
            return 2
            
        case 0xCA:
            if xFlag {
                x = (x & 0xFF00) | ((x & 0xFF) &- 1)
                updateP(x & 0xFF)
            } else {
                x &-= 1
                updateP(x)
            }
            return 2
            
        case 0xD0:
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.Z.rawValue) == 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0xD4:
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let effectiveAddr = readWord(bank: 0, addr: dpAddr)
            pushWord(effectiveAddr)
            return 6
            
        case 0xD7:
            pc &+= 1
            return 5

        case 0xD9:
            pc &+= 2
            return 4

        case 0xDA:
            if xFlag { push(UInt8(x & 0xFF)) } else { pushWord(x) }
            return xFlag ? 3 : 4

        case 0xDB:
            stopped = true
            return 3

        case 0xDF:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let bank = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low) &+ x
            if m {
                let val = memory.read(bank: bank, addr: addr)
                sbc8(val)
            } else {
                let val = readWord(bank: bank, addr: addr)
                sbc16(val)
            }
            return m ? 5 : 6

        case 0xE0:
            if xFlag { pc &+= 1 } else { pc &+= 2 }
            return xFlag ? 2 : 3
            
        case 0xE6:
            pc &+= 1
            return 5
            
        case 0xC6:
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
            
        case 0x36:
            let dpAddr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            let addr = d &+ dpAddr &+ x
            
            if m {
                let val = memory.read(bank: 0, addr: addr) &+ 1
                memory.write(bank: 0, addr: addr, data: val)
                updateP(UInt16(val))
                return 6
            } else {
                let val = readWord(bank: 0, addr: addr) &+ 1
                writeWord(bank: 0, addr: addr, data: val)
                updateP(val)
                return 7
            }
            
        case 0xE7:
            pc &+= 1
            return 6
            
        case 0xE9:
            if m {
                let val = memory.read(bank: pbr, addr: pc); pc &+= 1
                sbc8(val)
            } else {
                let val = readWord(bank: pbr, addr: pc); pc &+= 2
                sbc16(val)
            }
            return m ? 2 : 3

        case 0xE5:
            let addr = d &+ UInt16(memory.read(bank: pbr, addr: pc)); pc &+= 1
            if m {
                let val = memory.read(bank: 0, addr: addr)
                sbc8(val)
            } else {
                let val = readWord(bank: 0, addr: addr)
                sbc16(val)
            }
            return m ? 3 : 4
            
        case 0xED:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            if m {
                let val = memory.read(bank: db, addr: addr)
                sbc8(val)
            } else {
                let val = readWord(bank: db, addr: addr)
                sbc16(val)
            }
            return m ? 4 : 5
            
        case 0xEB:
            let b = (a >> 8) & 0xFF
            let aLow = a & 0xFF
            a = (aLow << 8) | b
            updateP(a & 0xFF)
            return 3
            
        case 0xE8:
            if xFlag {
                x = (x & 0xFF00) | ((x & 0xFF) &+ 1)
                updateP(x & 0xFF)
            } else {
                x &+= 1
                updateP(x)
            }
            return 2
            
        case 0xEE:
            let low = memory.read(bank: pbr, addr: pc); pc &+= 1
            let high = memory.read(bank: pbr, addr: pc); pc &+= 1
            let addr = (UInt16(high) << 8) | UInt16(low)
            return 6
            
        case 0xE2:
            let mask = memory.read(bank: pbr, addr: pc); pc &+= 1
            
            let oldM = m
            let oldX = xFlag
            p |= mask
            
            if oldM && !m { a &= 0x00FF }
            if oldX && !xFlag { x &= 0x00FF; y &= 0x00FF }
            
            updateP(a)
            return 3
            
        case 0xEA:
            return 2
            
        case 0xF0:
            let offset = Int8(bitPattern: memory.read(bank: pbr, addr: pc))
            pc &+= 1
            if (p & Flag.Z.rawValue) != 0 {
                pc = pc &+ UInt16(bitPattern: Int16(offset))
                return 3
            }
            return 2
            
        case 0xF9:
            pc &+= 2
            return 4
            
        case 0xFA:
            if xFlag { push(UInt8(x & 0xFF)) } else { pushWord(x) }
            return xFlag ? 4 : 5
            
        case 0xFB:
            let tempE = e
            if (p & Flag.C.rawValue) != 0 { p |= 0x01 } else { p &= ~0x01 }
            if tempE { p |= Flag.C.rawValue } else { p &= ~Flag.C.rawValue }
            p |= Flag.M.rawValue
            p |= Flag.X.rawValue
            return 2
            
        case 0x00:
            print("CPU Halted by BRK")
            stopped = true
            return 7
            
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
        updateP(a & 0xFF)
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
        updateP(a & 0xFF)
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
        guard let memory = memory else { return (0, 0) }
        let val = memory.read(bank: bank, addr: addr)
        let test = val & UInt8(a & 0xFF)
        
        if test == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let newVal = val | UInt8(a & 0xFF)
        return (newVal, 7)
    }
    
    func tsb16(addr: UInt16, bank: UInt8) -> (UInt16, Int) {
        guard let memory = memory else { return (0, 0) }
        let val = readWord(bank: bank, addr: addr)
        let test = val & a
        
        if test == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let newVal = val | a
        return (newVal, 8)
    }
    
    func trb8(addr: UInt16, bank: UInt8) -> (UInt8, Int) {
        guard let memory = memory else { return (0, 0) }
        let val = memory.read(bank: bank, addr: addr)
        let test = val & UInt8(a & 0xFF)
        
        if test == 0 { p |= Flag.Z.rawValue } else { p &= ~Flag.Z.rawValue }
        
        let newVal = val & ~UInt8(a & 0xFF)
        return (newVal, 7)
    }
    
    func trb16(addr: UInt16, bank: UInt8) -> (UInt16, Int) {
        guard let memory = memory else { return (0, 0) }
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
