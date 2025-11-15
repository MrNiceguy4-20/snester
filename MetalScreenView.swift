import SwiftUI
import MetalKit

struct MetalScreenView: NSViewRepresentable {
    @ObservedObject var viewModel: EmulatorViewModel
    
    typealias NSViewType = MTKView
    
    class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalScreenView
        var device: MTLDevice
        var commandQueue: MTLCommandQueue
        var renderPipelineState: MTLRenderPipelineState?
        var screenTexture: MTLTexture?
        private var quadVertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,
             1.0, -1.0, 1.0, 1.0,
            -1.0,  1.0, 0.0, 0.0,
             1.0,  1.0, 1.0, 0.0
        ]

        init(_ parent: MetalScreenView) {
            self.parent = parent
            self.device = MTLCreateSystemDefaultDevice()!
            self.commandQueue = device.makeCommandQueue()!
            super.init()
            buildPipelineState()
        }

        private func buildPipelineState() {
            guard let library = device.makeDefaultLibrary() else {
                assertionFailure("Unable to create default Metal library")
                return
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

            do {
                renderPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                assertionFailure("Failed to create pipeline state: \(error)")
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        
        func draw(in view: MTKView) {
            parent.viewModel.runFrame()
            guard let renderPipelineState = renderPipelineState,
                  let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let texture = screenTexture,
                  let commandBuffer = commandQueue.makeCommandBuffer() else { return }

            let width = 256
            let region = MTLRegionMake2D(0, 0, width, 224)
            let bytesPerRow = width * 4

            // FIX: Access the non-Published property directly via the viewModel instance.
            // (Note: The sharedVideoBuffer property MUST exist in the ViewModel for this to compile.)
            let bufferContents = parent.viewModel.sharedVideoBuffer.contents()
            
            // This copies the CPU-modified data from the shared buffer into the Metal texture
            texture.replace(region: region, mipmapLevel: 0, withBytes: bufferContents, bytesPerRow: bytesPerRow)
            
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
            encoder.setRenderPipelineState(renderPipelineState)
            encoder.setVertexBytes(&quadVertices,
                                   length: quadVertices.count * MemoryLayout<Float>.size,
                                   index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        let device = context.coordinator.device
        mtkView.delegate = context.coordinator
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 60
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 224, mipmapped: false)
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        context.coordinator.screenTexture = device.makeTexture(descriptor: textureDescriptor)
        
        return mtkView
        }
        
        func updateNSView(_ nsView: MTKView, context: Context) {}
    }
