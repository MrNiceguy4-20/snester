import Foundation

class ROM {
    
    let data: Data
    let romName: String
    private let headerOffset: Int
    
    init(data: Data) {
        // Check for 512-byte header (SMC header)
        if (data.count % 1024) == 512 {
            self.headerOffset = 512
            print("Detected headered ROM (512-byte offset).")
        } else {
            self.headerOffset = 0
            print("Detected unheadered ROM.")
        }
        
        self.data = data
        
        // Read ROM name from header (if present) or native location
        // The address in the file is different for headered vs. unheadered.
        // 0xFFC0 (native) + 0x200 (header) = 0x81C0 is wrong.
        // The *mapped* address is 0x7FC0.
        
        let nameMapAddress = 0x7FC0 // 0xFFC0 is for HiROM
        
        // We read from the file, so we must apply the offset
        let nameFileOffset = nameMapAddress + self.headerOffset
        
        if nameFileOffset + 21 <= data.count, // Check bounds
           let name = String(data: data[(nameFileOffset)...(nameFileOffset + 20)], encoding: .ascii) {
            self.romName = name.trimmingCharacters(in: .whitespaces)
        } else {
            // Fallback if header is weird
            self.romName = "Unknown"
        }
    }
    
    // Reads data from the ROM, applying the header offset
    // `addr` is the mapped, ROM-relative address from the MemoryBus.
    @inline(__always) func read(addr: UInt32) -> UInt8 {
        let fileOffset = Int(addr) + headerOffset
        if fileOffset < data.count {
            return data[fileOffset]
        }
        return 0
    }
}
