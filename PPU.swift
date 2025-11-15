import Foundation
import Combine

class PPU {
    
    var vram: [UInt8] = Array(repeating: 0, count: 64 * 1024)
    var cgram: [UInt16] = Array(repeating: 0, count: 256)
    var oam: [UInt8] = Array(repeating: 0, count: 544)
    
    let width = 256
    let height = 224 // Standard visible height
    let totalScanlines = 262 // Total scanlines per frame
    let totalDots = 341 // Total dots per scanline
    
    private var internalFramebuffer: [UInt32]
    var framebufferPublisher = PassthroughSubject<[UInt32], Never>()
    
    var currentScanline: Int = 0
    var currentDot: Int = 0
    
    var inidisp: UInt8 = 0
    var forceBlank: Bool { (inidisp & 0x80) != 0 }
    var nmiEnable: Bool = false
    
    var bgMode: UInt8 = 0
    
    var vramAddress: UInt16 = 0
    var vramAddressIncrement: UInt16 = 1
    var vramIncrementOnHigh: Bool = false
    
    var cgramAddress: UInt8 = 0
    var cgramWritePending = false
    var cgramBuffer: UInt8 = 0
    
    var nmiTriggered = false // Signal to CPU for NMI
    var irqTriggered = false // Signal to CPU for IRQ
    var nmiFlag: UInt8 = 0x00 // $4212 status register
    
    var oamAddress: UInt16 = 0
    private var oamReadBuffer: UInt8 = 0
    
    var tm: UInt8 = 0
    var ts: UInt8 = 0
    var cgadsub: UInt8 = 0
    var cgwsel: UInt8 = 0
    
    var fixedColorR: UInt8 = 0
    var fixedColorG: UInt8 = 0
    var fixedColorB: UInt8 = 0
    
    var wh0: UInt8 = 0
    var wh1: UInt8 = 0
    var wh2: UInt8 = 0
    var wh3: UInt8 = 0
    var wbglog: UInt8 = 0
    var wbgc: UInt8 = 0
    
    // ADDED: H/V Timer Registers
    var hTimer: UInt16 = 0
    var vTimer: UInt16 = 0
    var hTimerEnabled: Bool = false
    var vTimerEnabled: Bool = false
    
    // Status Toggles (Crucial for $2137/bus conflicts)
    var readOAMAddrToggle: Bool = false
    var readCGRAMAddrToggle: Bool = false
    
    weak var memory: MemoryBus?
    weak var dma: DMA?
    weak var cpu: CPU? // Required for IRQ signaling
    
    var bg1hofs: UInt16 = 0; var bg1vofs: UInt16 = 0
    var bg2hofs: UInt16 = 0; var bg2vofs: UInt16 = 0
    var bg3hofs: UInt16 = 0; var bg3vofs: UInt16 = 0
    var bg4hofs: UInt16 = 0; var bg4vofs: UInt16 = 0
    
    private var bg1hofsLatched: UInt16 = 0; private var bg1vofsLatched: UInt16 = 0
    private var bg2hofsLatched: UInt16 = 0; private var bg2vofsLatched: UInt16 = 0
    private var bg3hofsLatched: UInt16 = 0; private var bg3vofsLatched: UInt16 = 0
    private var bg4hofsLatched: UInt16 = 0; private var bg4vofsLatched: UInt16 = 0
    
    var m7a: Int16 = 0; var m7b: Int16 = 0
    var m7c: Int16 = 0; var m7d: Int16 = 0
    var m7x: Int16 = 0
    var m7y: Int16 = 0
    
    var hofsToggle = false
    var vofsToggle = false
    
    var bg1sc: UInt8 = 0; var bg2sc: UInt8 = 0
    var bg3sc: UInt8 = 0; var bg4sc: UInt8 = 0
    
    var bg12nba: UInt8 = 0; var bg34nba: UInt8 = 0
    
    typealias TileRowCache = (
        tileX: Int, tileY: Int,
        plane0: UInt8, plane1: UInt8,
        plane2: UInt8, plane3: UInt8,
        paletteIndex: Int, vFlip: Bool, hFlip: Bool
    )
    private var bgCache: [TileRowCache] = Array(repeating: (-1, -1, 0, 0, 0, 0, 0, false, false), count: 4)
    
    struct Sprite {
        var x: Int = 0
        var y: Int = 0
        var tileIndex: Int = 0
        var palette: Int = 0
        var priority: Int = 0
        var hFlip: Bool = false
        var vFlip: Bool = false
        var size: Bool = false
        var tileData: [UInt8] = Array(repeating: 0, count: 32)
    }
    
    var spritesThisScanline: [Sprite] = []
    
    init() {
        self.internalFramebuffer = Array(repeating: 0xFF000000, count: width * height)
    }
    
    private func latchOffsets() {
        bg1hofsLatched = bg1hofs & 0x3FFF // Only 14 bits are latched
        bg1vofsLatched = bg1vofs & 0x3FFF
        bg2hofsLatched = bg2hofs & 0x3FFF
        bg2vofsLatched = bg2vofs & 0x3FFF
        bg3hofsLatched = bg3hofs & 0x3FFF
        bg3vofsLatched = bg3vofs & 0x3FFF
        bg4hofsLatched = bg4hofs & 0x3FFF
        bg4vofsLatched = bg4vofs & 0x3FFF
        
        m7a = getSigned16(bg2hofs)
        m7b = getSigned16(bg2vofs)
        m7c = getSigned16(bg3hofs)
        m7d = getSigned16(bg3vofs)
        m7x = getSigned16(bg1hofs)
        m7y = getSigned16(bg1vofs)
    }
    
    private func getSigned16(_ val: UInt16) -> Int16 {
        return Int16(bitPattern: val)
    }
    
    func step(cycles: Int) {
        for _ in 0..<cycles {
            
            // NMI/V-Blank Check: Occurs just before dot 0 of the first scanline after height (V-Blank start)
            if currentScanline == height && currentDot == 0 {
                latchOffsets()
                dma?.initHDMA()
                
                nmiFlag |= 0x80 // Set V-Blank flag
                
                if nmiEnable {
                    nmiTriggered = true
                }
                
                framebufferPublisher.send(internalFramebuffer)
                internalFramebuffer = Array(repeating: 0xFF000000, count: width * height)
            }
            
            // H-Blank Check: Set H-Blank flag at dot 256
            if currentDot == width && currentScanline < height {
                nmiFlag |= 0x40 // Set H-Blank flag
            }
            
            // Timer Check Logic (Triggers IRQ)
            if hTimerEnabled && currentDot == Int(hTimer) && currentScanline < totalScanlines {
                nmiFlag |= 0x20 // Set H-IRQ flag
                irqTriggered = true
            }
            if vTimerEnabled && currentScanline == Int(vTimer) && currentDot == 0 {
                nmiFlag |= 0x20 // Set V-IRQ flag
                irqTriggered = true
            }
            
            // Start of Frame Cleanup: Reset NMI/IRQ flags and state
            if currentScanline == 0 && currentDot == 0 {
                nmiFlag &= ~0xC0 // Clear V-Blank and H-Blank
                nmiTriggered = false
                irqTriggered = false
                // cpu?.irqTriggered = false // Placeholder for CPU IRQ line reset
            }

            currentDot += 1
            
            if currentDot == totalDots { // End of scanline (341 dots)
                currentDot = 0
                
                // Reset H-Blank flag at start of visible line
                nmiFlag &= ~0x40
                
                // Run HDMA (Occurs before rendering, typically at dot 10)
                let _ = dma?.runHDMA() ?? 0
                
                if currentScanline < height {
                    if !forceBlank {
                        fetchOAMData(scanline: currentScanline)
                        renderScanline(currentScanline)
                    } else {
                        blankScanline(currentScanline)
                    }
                }
                
                currentScanline += 1
                if currentScanline == totalScanlines {
                    currentScanline = 0
                    hofsToggle = false
                    vofsToggle = false
                }
            }
        }
    }
    
    func resetDMAState() {
        vramAddress = 0
        cgramWritePending = false
    }
    
    private func extractRGB(color: UInt16) -> (r: UInt8, g: UInt8, b: UInt8) {
        let r = UInt8((color >> 0) & 0x1F)
        let g = UInt8((color >> 5) & 0x1F)
        let b = UInt8((color >> 10) & 0x1F)
        return (r, g, b)
    }
    
    private func applyColorMath(mainR: UInt8, mainG: UInt8, mainB: UInt8, subR: UInt8, subG: UInt8, subB: UInt8) -> UInt16 {
        
        let targetR = subR
        let targetG = subG
        let targetB = subB
        
        let isSubtraction = (cgadsub & 0x80) != 0
        let isHalf = (cgadsub & 0x40) != 0
        
        let operation: (UInt8, UInt8) -> UInt8 = { a, b in
            if isSubtraction {
                let result = Int(a) - Int(b)
                return UInt8(max(0, result))
            } else {
                let result = Int(a) + Int(b)
                return UInt8(min(31, result))
            }
        }
        
        var finalR = operation(mainR, targetR)
        var finalG = operation(mainG, targetG)
        var finalB = operation(mainB, targetB)
        
        if isHalf {
            finalR >>= 1
            finalG >>= 1
            finalB >>= 1
        }
        
        return (UInt16(finalB) << 10) | (UInt16(finalG) << 5) | UInt16(finalR)
    }
    
    private func checkWindow(layerIndex: Int, x: Int, isMainScreen: Bool) -> Bool {
        
        // Simplified window check, assumes full window logic is correctly implemented elsewhere
        return true
    }

    func renderMode7Pixel(x: Int, y: Int) -> UInt8 {
        let u: Int32 = Int32(x) - Int32(width / 2)
        let v: Int32 = Int32(y) - Int32(height / 2)
        
        let sx = (Int32(m7a) * u >> 8) + (Int32(m7b) * v >> 8) + Int32(m7x)
        let sy = (Int32(m7c) * u >> 8) + (Int32(m7d) * v >> 8) + Int32(m7y)
        
        // Mode 7 address wrapping (256x256 map)
        let mapX = Int(sx & 0x3FF)
        let mapY = Int(sy & 0x3FF)
        
        let tileX = mapX >> 3
        let tileY = mapY >> 3
        let pixelX = mapX & 0x07
        let pixelY = mapY & 0x07
        
        let tilemapAddress = UInt16(tileY * 128 + tileX) * 2 // 16-bit entries
        let tilemapEntry = readVRAM(addr: tilemapAddress)
        let tileIndex = tilemapEntry & 0xFF
        
        let tileDataAddress = UInt16(tileIndex) * 64 + UInt16(pixelY * 8 + pixelX)
        let colorIndex = vram[Int(tileDataAddress) & 0xFFFF] // VRAM wrap for data
        
        guard checkWindow(layerIndex: 0, x: x, isMainScreen: true) else { return 0 }
        
        return colorIndex
    }
    
    func fetchOAMData(scanline y: Int) {
        spritesThisScanline.removeAll(keepingCapacity: true)
        let smallSize = 8
        
        // Full OAM table size is 128 * 4 = 512 bytes
        for i in 0..<128 {
            let base = i * 4
            let oamY = Int(oam[base + 0])
            let oamX = Int(oam[base + 1])
            let charIndex = Int(oam[base + 2])
            let attr = oam[base + 3]
            
            if y >= oamY && y < oamY + smallSize {
                var sprite = Sprite()
                sprite.x = oamX
                sprite.y = oamY
                sprite.tileIndex = charIndex
                sprite.palette = Int(attr & 0x07)
                sprite.priority = Int((attr >> 5) & 0x03)
                sprite.hFlip = (attr & 0x40) != 0
                sprite.vFlip = (attr & 0x80) != 0
                sprite.size = (oam[512] & 0x01) != 0
                
                // Simplified: Fetching 4bpp is standard for sprites
                sprite.tileData = fetchTileData(tileIndex: charIndex, bpp: 4)
                
                spritesThisScanline.append(sprite)
                
                if spritesThisScanline.count >= 32 { break } // Max 32 sprites per line
            }
        }
    }
    
    func fetchTileData(tileIndex: Int, bpp: Int) -> [UInt8] {
        // Logic is simplified; VRAM tile data is complex and interwoven.
        var data = Array(repeating: UInt8(0), count: bpp * 8)
        
        let tileDataSize = bpp * 8
        let tileOffset = UInt16(tileIndex) * UInt16(tileDataSize)
        let tileDataBaseAddr: UInt16 = 0
        
        for i in 0..<tileDataSize/2 {
            let addr = tileDataBaseAddr + tileOffset + UInt16(i * 2)
            data[i * 2] = readVRAMByte(addr: addr)
            data[i * 2 + 1] = readVRAMByte(addr: addr + 1)
        }
        
        return data
    }
    
    func renderSpritePixel(x: Int, y: Int) -> (colorIndex: UInt8, priority: Int) {
        // Renders sprites from back to front (reversed order) to ensure correct priority.
        var finalColorIndex: UInt8 = 0
        var finalPriority: Int = -1
        
        for sprite in spritesThisScanline.reversed() {
            let spriteX = x - sprite.x
            let spriteY = y - sprite.y
            let size = sprite.size ? 16 : 8
            
            if spriteX >= 0 && spriteX < size && spriteY >= 0 && spriteY < size {
                
                let tileX = spriteX / 8
                let tileY = spriteY / 8
                var pixelX = spriteX % 8
                var pixelY = spriteY % 8
                
                if sprite.vFlip { pixelY = 7 - pixelY }
                if sprite.hFlip { pixelX = 7 - pixelX }
                
                let subTileIndex = (tileY * 2 + tileX) * 32
                
                let tileData = sprite.tileData
                let rowOffset = (pixelY * 2) + subTileIndex
                
                guard rowOffset + 17 < tileData.count else { continue }
                
                let plane0 = tileData[rowOffset]
                let plane1 = tileData[rowOffset + 1]
                let plane2 = tileData[rowOffset + 16]
                let plane3 = tileData[rowOffset + 17]
                
                let bit = 7 - pixelX
                
                let bit0 = (Int(plane0) >> bit) & 1
                let bit1 = (Int(plane1) >> bit) & 1
                let bit2 = (Int(plane2) >> bit) & 1
                let bit3 = (Int(plane3) >> bit) & 1
                
                let color = (bit3 << 3 | bit2 << 2 | bit1 << 1 | bit0)
                
                if color != 0 {
                    finalColorIndex = UInt8(128 + sprite.palette * 16 + color)
                    finalPriority = sprite.priority
                    return (finalColorIndex, finalPriority)
                }
            }
        }
        return (0, -1)
    }
    
    func renderScanline(_ y: Int) {
        for i in 0..<bgCache.count {
            bgCache[i] = (-1, -1, 0, 0, 0, 0, 0, false, false)
        }
        
        for x in 0..<width {
            renderPixel(x: x, y: y)
        }
    }
    
    func blankScanline(_ y: Int) {
        let backdrop = convertColor(cgram[0])
        for x in 0..<width {
            internalFramebuffer[y * width + x] = backdrop
        }
    }
    
    func renderPixel(x: Int, y: Int) {
        // Full pixel rendering priority logic is complex and simplified here for clarity.
        var mainScreenColorIndex: UInt8 = 0
        let subScreenColorIndex: UInt8 = 0
        var bgPriority: (color: UInt8, priority: Int) = (0, 0)
        
        if bgMode == 7 {
            mainScreenColorIndex = renderMode7Pixel(x: x, y: y)
            bgPriority = (mainScreenColorIndex, 3)
        } else {
            // RENDER ALL FOUR BGS
            let bg1Color = renderBackground(bgIndex: 0, x: x, y: y, bpp: 4, 1, hofs: bg1hofsLatched, vofs: bg1vofsLatched)
            let bg2Color = renderBackground(bgIndex: 1, x: x, y: y, bpp: 4, 1, hofs: bg2hofsLatched, vofs: bg2vofsLatched)
            let bg3Color = renderBackground(bgIndex: 2, x: x, y: y, bpp: 2, 2, hofs: bg3hofsLatched, vofs: bg3vofsLatched)
            let bg4Color = renderBackground(bgIndex: 3, x: x, y: y, bpp: 2, 2, hofs: bg4hofsLatched, vofs: bg4vofsLatched)
            
            // Simplified BG Priority Merge: Highest active priority wins
            let bgColors = [bg1Color.priority, bg2Color.priority, bg3Color.priority, bg4Color.priority]
                .filter { $0.color > 0 }
                .sorted { $0.priority > $1.priority }
            
            if let highestBG = bgColors.first { bgPriority = (highestBG.color, highestBG.priority) }
            
            let (spriteColor, spritePriority) = renderSpritePixel(x: x, y: y)
            
            if spriteColor > 0 {
                if spritePriority >= bgPriority.priority {
                    mainScreenColorIndex = spriteColor
                } else if bgPriority.color > 0 {
                    mainScreenColorIndex = bgPriority.color
                } else {
                    mainScreenColorIndex = spriteColor
                }
            } else if bgPriority.color > 0 {
                mainScreenColorIndex = bgPriority.color
            }
        }
        
        if mainScreenColorIndex > 0 {
            let layerIndex = (mainScreenColorIndex >= 128) ? 4 : 0
            if !checkWindow(layerIndex: layerIndex, x: x, isMainScreen: true) {
                mainScreenColorIndex = 0
            }
        }
        
        // Sub-screen rendering is often simplified to just the backdrop color or the fixed color.
        
        // FIX: Explicitly define subColor as UInt16 to resolve potential type ambiguity.
        let subColor: UInt16 = (subScreenColorIndex > 0)
            ? cgram[Int(subScreenColorIndex)]
            : ( (UInt16(fixedColorB) << 10) | (UInt16(fixedColorG) << 5) | UInt16(fixedColorR) )

        let mainColor = (mainScreenColorIndex > 0) ? cgram[Int(mainScreenColorIndex)] : cgram[0]
        
        let layerBit: UInt8 = (mainScreenColorIndex >= 128) ? 0x10 : 0x01
        let isMainLayerMathActive = (tm & layerBit) != 0
        
        var finalColor15bit: UInt16 = 0
        
        if isMainLayerMathActive && subColor > 0 {
            let (mainR, mainG, mainB) = extractRGB(color: mainColor)
            let (subR, subG, subB) = extractRGB(color: subColor)
            
            finalColor15bit = applyColorMath(mainR: mainR, mainG: mainG, mainB: mainB, subR: subR, subG: subG, subB: subB)
        } else {
            finalColor15bit = mainColor
        }
        
        internalFramebuffer[y * width + x] = convertColor(finalColor15bit)
    }
    
    // Fix: Changed parameter 'priority' to '_ initialPriority' and declared 'var priority' inside.
    func renderBackground(bgIndex: Int, x: Int, y: Int, bpp: Int, _ initialPriority: Int, hofs: UInt16, vofs: UInt16) -> (color: UInt8, priority: (color: UInt8, priority: Int)) {
        var priority = initialPriority
        
        var tilemapBaseAddr: UInt16 = 0
        var tileDataBaseAddr: UInt16 = 0
        var tileMapScreenSize: UInt8 = 0
        
        switch bgIndex {
        case 0:
            tilemapBaseAddr = (UInt16(bg1sc & 0xFC) << 7)
            tileDataBaseAddr = (UInt16(bg12nba & 0x0F) << 13)
            tileMapScreenSize = bg1sc & 0x03
        case 1:
            tilemapBaseAddr = (UInt16(bg2sc & 0xFC) << 7)
            tileDataBaseAddr = (UInt16(bg12nba >> 4) << 13)
            tileMapScreenSize = bg2sc & 0x03
        case 2:
            tilemapBaseAddr = (UInt16(bg3sc & 0xFC) << 7)
            tileDataBaseAddr = (UInt16(bg34nba & 0x0F) << 13)
            tileMapScreenSize = bg3sc & 0x03
        case 3:
            tilemapBaseAddr = (UInt16(bg4sc & 0xFC) << 7)
            tileDataBaseAddr = (UInt16(bg34nba >> 4) << 13)
            tileMapScreenSize = bg4sc & 0x03
        default:
            return (0, (0, 0))
        }
        
        let scrolledX = (x + Int(hofs)) & 0x3FF // Max 1024 width
        let scrolledY = (y + Int(vofs)) & 0x3FF // Max 1024 height
        
        let tileX = scrolledX / 8
        let tileY = scrolledY / 8
        var pixelX = scrolledX % 8
        var pixelY = scrolledY % 8
        
        // Calculate Tile Map address based on screen size
        let tileMapBaseRow = (tileY & 0x1F) * 32
        var tileMapFinalAddr = UInt16(tileMapBaseRow + (tileX & 0x1F)) * 2
        
        // Handle Screen Wrapping/Mirroring (0x01 = 64x32, 0x02 = 32x64, 0x03 = 64x64)
        if tileMapScreenSize == 0x01 && tileX >= 32 { tileMapFinalAddr += 0x0800 } // Horizontal Mirror
        if tileMapScreenSize == 0x02 && tileY >= 32 { tileMapFinalAddr += 0x0400 } // Vertical Mirror
        if tileMapScreenSize == 0x03 {
            if tileX >= 32 { tileMapFinalAddr += 0x0800 }
            if tileY >= 32 { tileMapFinalAddr += 0x0400 }
        }
        
        var plane0: UInt8, plane1: UInt8, plane2: UInt8, plane3: UInt8
        var paletteIndex: Int
        var hFlip: Bool
        
        // Cache Hit Check
        if tileX == bgCache[bgIndex].tileX && tileY == bgCache[bgIndex].tileY {
            (plane0, plane1, plane2, plane3) = (bgCache[bgIndex].plane0, bgCache[bgIndex].plane1, bgCache[bgIndex].plane2, bgCache[bgIndex].plane3)
            paletteIndex = bgCache[bgIndex].paletteIndex
            hFlip = bgCache[bgIndex].hFlip
            if bgCache[bgIndex].vFlip { pixelY = 7 - pixelY }
        } else {
            let tilemapEntry = readVRAM(addr: tilemapBaseAddr + tileMapFinalAddr)
            
            let tileIndex = tilemapEntry & 0x03FF
            let palette = Int((tilemapEntry >> 10) & 0x07)
            let vFlip = (tilemapEntry & 0x8000) != 0
            hFlip = (tilemapEntry & 0x4000) != 0
            let tilePriorityBit = Int((tilemapEntry >> 13) & 0x01)
            
            if vFlip { pixelY = 7 - pixelY }
            
            // Fetch the raw tile data
            let tileDataSize = bpp * 8
            let tileOffset = tileIndex * UInt16(tileDataSize)
            let pixelRowAddr = tileDataBaseAddr + tileOffset + UInt16(pixelY * 2)
            
            plane0 = readVRAMByte(addr: pixelRowAddr)
            plane1 = readVRAMByte(addr: pixelRowAddr + 1)
            plane2 = (bpp == 4) ? readVRAMByte(addr: pixelRowAddr + 16) : 0
            plane3 = (bpp == 4) ? readVRAMByte(addr: pixelRowAddr + 17) : 0
            
            paletteIndex = palette
            
            bgCache[bgIndex] = (tileX, tileY, plane0, plane1, plane2, plane3, paletteIndex, vFlip, hFlip)
            priority = priority | tilePriorityBit // Merge tile's priority bit (0 or 1) with layer default
        }
        
        if hFlip { pixelX = 7 - pixelX }
        let bit = 7 - pixelX
        
        let bit0 = (Int(plane0) >> bit) & 1
        let bit1 = (Int(plane1) >> bit) & 1
        let color = (bpp == 4) ? ((Int(plane3) >> bit & 1) << 3 | (Int(plane2) >> bit & 1) << 2 | bit1 << 1 | bit0)
                               : (bit1 << 1 | bit0)
        
        if color == 0 { return (0, (0, 0)) }
        
        let paletteStart = (bgIndex == 2) ? 128 : 0 // Simplified palette split for BG3
        let paletteSize = (bgIndex == 2) ? 4 : 16
        let finalColorIndex = paletteStart + paletteIndex * paletteSize + color
        
        return (UInt8(finalColorIndex), (UInt8(finalColorIndex), priority))
    }
    
    func readVRAMByte(addr: UInt16) -> UInt8 {
        let index = Int(addr) & 0xFFFF
        return vram[index]
    }
    
    func readVRAM(addr: UInt16) -> UInt16 {
        let index = Int(addr)
        let low = vram[index % vram.count]
        let high = vram[(index + 1) % vram.count]
        return (UInt16(high) << 8) | UInt16(low)
    }
    
    func convertColor(_ color15bit: UInt16) -> UInt32 {
        let r = UInt32((color15bit >> 0) & 0x1F) * 255 / 31
        let g = UInt32((color15bit >> 5) & 0x1F) * 255 / 31
        let b = UInt32((color15bit >> 10) & 0x1F) * 255 / 31
        return 0xFF000000 | (r << 16) | (g << 8) | b
    }
    
    func readNMIStatus() -> UInt8 {
        // Reads $4210 NMI Status (resets NMI pending flag)
        let val = nmiFlag
        nmiFlag &= ~0x80 // Clear NMI flag
        return val
    }
    
    func readRegister(addr: UInt16) -> UInt8 {
        switch addr {
        case 0x2134: // MPYL
            let result = UInt32(m7x) * UInt32(m7y)
            return UInt8(result & 0xFF)
        case 0x2135: // MPM
            let result = UInt32(m7x) * UInt32(m7y)
            return UInt8((result >> 8) & 0xFF)
        case 0x2136: // MPH
            let result = UInt32(m7x) * UInt32(m7y)
            return UInt8((result >> 16) & 0xFF)
        case 0x2137: // PPU Status Read
            // Crucial sync register. Toggles are read and reset.
            let oldOAMToggle = readOAMAddrToggle
            let oldCGRAMToggle = readCGRAMAddrToggle
            readOAMAddrToggle = false
            readCGRAMAddrToggle = false
            var result: UInt8 = 0
            if oldOAMToggle { result |= 0x40 }
            if oldCGRAMToggle { result |= 0x80 }
            return result
        case 0x2138: // OAM Read
            let addr = Int(oamAddress & 0x1FF)
            var val: UInt8
            if addr >= 512 {
                val = oam[512 + (addr - 512) % 32] // Attribute table
            } else {
                val = oam[addr]
            }
            oamAddress &+= 1 // Auto-increment
            readOAMAddrToggle = true
            return val
        case 0x2139: // VRAM Read Low
            let addr = Int(vramAddress * 2) & 0xFFFF
            let val = vram[addr]
            vramAddress &+= vramIncrementOnHigh ? 0 : vramAddressIncrement // Only increment if not high-byte-first
            return val
        case 0x213A: // VRAM Read High
            let addr = Int(vramAddress * 2 + 1) & 0xFFFF
            let val = vram[addr]
            vramAddress &+= vramIncrementOnHigh ? vramAddressIncrement : 0 // Only increment if high-byte-first
            return val
        case 0x213B: // CGRAM Read
            let color = cgram[Int(cgramAddress) & 0xFF]
            let val: UInt8 = readCGRAMAddrToggle ? UInt8(color >> 8) : UInt8(color & 0xFF)
            readCGRAMAddrToggle.toggle()
            if !readCGRAMAddrToggle { cgramAddress &+= 1 } // Increment after reading high byte
            return val
        case 0x4210: return readNMIStatus()
        case 0x4211: // IRQ Status Read (resets IRQ pending flag)
            let val = irqTriggered ? 0x80 : 0x00
            irqTriggered = false
            return UInt8(val) // FIX: Explicit cast to UInt8
        case 0x4212: // V/H Status Read
            var status: UInt8 = 0
            if currentScanline >= height { status |= 0x80 } // V-Blank
            if currentDot >= width { status |= 0x40 } // H-Blank
            if nmiFlag & 0x20 != 0 { status |= 0x20 } // IRQ pending
            nmiFlag &= ~0x20
            return status
        case 0x4214: return UInt8(currentScanline & 0xFF) // VCOUNT Low
        case 0x4215: return UInt8((currentScanline >> 8) & 0x01) // VCOUNT High
        case 0x4216: return UInt8(currentDot & 0xFF) // HCOUNT Low
        case 0x4217: return UInt8((currentDot >> 8) & 0x01) // HCOUNT High
        default:
            return 0
        }
    }
    
    func writeRegister(addr: UInt16, data: UInt8) {
        // Reset H/V OFS toggle on $2105 write (BG Mode)
        if addr == 0x2105 { hofsToggle = false; vofsToggle = false }
        
        // OAM Address write resets the OAM read/write toggle
        if addr == 0x2102 || addr == 0x2103 { readOAMAddrToggle = false }
        
        switch addr {
        case 0x2100: inidisp = data
        case 0x2105: bgMode = data & 0x07
        case 0x2107: bg1sc = data
        case 0x2108: bg2sc = data
        case 0x2109: bg3sc = data
        case 0x210A: bg4sc = data
        case 0x210B: bg12nba = data
        case 0x210C: bg34nba = data
            
        case 0x210D: bg1hofs = hofsToggle ? (bg1hofs & 0x00FF) | (UInt16(data) << 8) : (bg1hofs & 0xFF00) | UInt16(data); hofsToggle.toggle()
        case 0x210E: bg1vofs = vofsToggle ? (bg1vofs & 0x00FF) | (UInt16(data) << 8) : (bg1vofs & 0xFF00) | UInt16(data); vofsToggle.toggle()
        case 0x210F: bg2hofs = hofsToggle ? (bg2hofs & 0x00FF) | (UInt16(data) << 8) : (bg2hofs & 0xFF00) | UInt16(data); hofsToggle.toggle()
        case 0x2110: bg2vofs = vofsToggle ? (bg2vofs & 0x00FF) | (UInt16(data) << 8) : (bg2vofs & 0xFF00) | UInt16(data); vofsToggle.toggle()
        case 0x2111: bg3hofs = hofsToggle ? (bg3hofs & 0x00FF) | (UInt16(data) << 8) : (bg3hofs & 0xFF00) | UInt16(data); hofsToggle.toggle()
        case 0x2112: bg3vofs = vofsToggle ? (bg3vofs & 0x00FF) | (UInt16(data) << 8) : (bg3vofs & 0xFF00) | UInt16(data); vofsToggle.toggle()
        case 0x2113: bg4hofs = hofsToggle ? (bg4hofs & 0x00FF) | (UInt16(data) << 8) : (bg4hofs & 0xFF00) | UInt16(data); hofsToggle.toggle()
        case 0x2114: bg4vofs = vofsToggle ? (bg4vofs & 0x00FF) | (UInt16(data) << 8) : (bg4vofs & 0xFF00) | UInt16(data); vofsToggle.toggle()
        case 0x2115:
            vramIncrementOnHigh = (data & 0x80) != 0
            switch data & 3 {
            case 0: vramAddressIncrement = 1
            case 1: vramAddressIncrement = 32
            case 2,3: vramAddressIncrement = 128
            default: break
            }
        case 0x2116: vramAddress = (vramAddress & 0xFF00) | UInt16(data)
        case 0x2117: vramAddress = (vramAddress & 0x00FF) | (UInt16(data) << 8)
        case 0x2118:
            let addr = Int(vramAddress * 2) & 0xFFFF
            if addr < vram.count { vram[addr] = data }
            if !vramIncrementOnHigh { vramAddress &+= vramAddressIncrement }
        case 0x2119:
            let addr = Int(vramAddress * 2 + 1) & 0xFFFF
            if addr < vram.count { vram[addr] = data }
            if vramIncrementOnHigh { vramAddress &+= vramAddressIncrement }
        case 0x2121: cgramAddress = data; cgramWritePending = false
        case 0x2122:
            if !cgramWritePending {
                cgramBuffer = data; cgramWritePending = true
            } else {
                let color = (UInt16(data & 0x7F) << 8) | UInt16(cgramBuffer)
                if Int(cgramAddress) < cgram.count { cgram[Int(cgramAddress)] = color }
                cgramAddress &+= 1
                cgramWritePending = false
            }
        case 0x2102: oamAddress = (oamAddress & 0xFE00) | UInt16(data)
        case 0x2103: oamAddress = (oamAddress & 0x00FF) | (UInt16(data & 0x03) << 8)
        case 0x2104:
            let addr = Int(oamAddress & 0x1FF)
            if (oamAddress & 0x0100) != 0 {
                oam[512 + (addr % 32)] = data
            } else {
                oam[addr] = data
            }
            oamAddress &+= 1
            oamAddress &= 0x1FF
        case 0x2130: tm = data
        case 0x2131: ts = data
        case 0x4200:
            nmiEnable = (data & 0x80) != 0
            hTimerEnabled = (data & 0x40) != 0
            vTimerEnabled = (data & 0x20) != 0
        case 0x420C: dma?.hdmaEnable = data
        case 0x2132:
            fixedColorB = data & 0x1F
            fixedColorG = (data & 0xE0) >> 5
        case 0x2133:
            cgwsel = data
            fixedColorG |= (data & 0x60) >> 3
            fixedColorR = (fixedColorR & 0x07) | ((data & 0x03) << 3)
            fixedColorB = (fixedColorB & 0x07) | ((data & 0x0C) << 1)
        case 0x2123: wh0 = data
        case 0x2124: wh1 = data
        case 0x2125: wh2 = data
        case 0x2126: wh3 = data
        case 0x2127: wbglog = data
        case 0x2128: wbgc = data
        case 0x4207: hTimer = (hTimer & 0xFF00) | UInt16(data); irqTriggered = false
        case 0x4208: hTimer = (hTimer & 0x00FF) | (UInt16(data) << 8)
        case 0x4209: vTimer = (vTimer & 0xFF00) | UInt16(data); irqTriggered = false
        case 0x420A: vTimer = (vTimer & 0x00FF) | (UInt16(data) << 8)
        
        default: break
        }
    }
    
    func debugStatus() -> String {
        let vramAddr = String(vramAddress, radix: 16).padding(toLength: 4, withPad: "0", startingAt: 0)
        let cgramAddr = String(cgramAddress, radix: 16).padding(toLength: 2, withPad: "0", startingAt: 0)
        let oamAddr = String(oamAddress, radix: 16).padding(toLength: 3, withPad: "0", startingAt: 0)
        let spriteCount = spritesThisScanline.count
        return """
        Scanline: \(currentScanline) Dot: \(currentDot)
        BG Mode: \(bgMode) (Mode 7 Active: \(bgMode == 7))
        NMI Enabled: \(nmiEnable) Force Blank: \(forceBlank)
        VRAM Addr: $\(vramAddr) CGRAM Addr: $\(cgramAddr)
        OAM Addr: $\(oamAddr)
        Sprites on Line: \(spriteCount)
        """
    }
}
