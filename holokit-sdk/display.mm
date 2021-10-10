//
//  display.mm
//  holokit-sdk-skeleton
//
//  Created by Yuchen on 2021/3/29.
//

#include <memory>
#include <vector>

#import <os/log.h>
#import <os/signpost.h>

#include "IUnityXRTrace.h"
#include "IUnityXRDisplay.h"
#include "UnitySubsystemTypes.h"
#include "load.h"
#include "math_helpers.h"
#include "holokit_api.h"
#include "ar_recorder.h"

#if __APPLE__
#define XR_METAL 1
#define XR_ANDROID 0
#include "IUnityGraphicsMetal.h"
#include <Metal/Metal.h>
#include <MetalKit/MetalKit.h>
#import <simd/simd.h>
#else
#define XR_METAL 0
#define XR_ANDROID 1
#endif

/// If this is 1, both render passes will render to a single texture.
/// Otherwise, they will render to two separate textures.
#define SIDE_BY_SIDE 1
#define NUM_RENDER_PASSES 2

// @def Logs to Unity XR Trace interface @p message.
#define HOLOKIT_DISPLAY_XR_TRACE_LOG(trace, message, ...)                \
  XR_TRACE_LOG(trace, "[HoloKitDisplayProvider]: " message "\n", \
               ##__VA_ARGS__)

NSString* alignment_marker_shader = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VertexInOut\n"
    "{\n"
    "    float4  position [[position]];\n"
    "    float4  color;\n"
    "};\n"
    "vertex VertexInOut passThroughVertex(uint vid [[ vertex_id ]],\n"
    "                                     constant packed_float4* position  [[ buffer(0) ]])\n"
    "{\n"
    "    VertexInOut outVertex;\n"
    "    outVertex.position = position[vid];\n"
    "    return outVertex;\n"
    "};\n"
    "fragment half4 passThroughFragment(VertexInOut inFrag [[stage_in]])\n"
    "{\n"
    "//  return half4(1, 0, 0, 1);\n"
    "    return half4(1, 1, 1, 1);\n"
    "};\n";

// widgets data
float vertex_data[] = {
    0.829760, 1, 0.0, 1.0,
    0.829760, 0.7, 0.0, 1.0
};

// new content rendering data
constexpr static float main_vertices[] = { -1, -1, 1, -1, -1, 1, 1, 1 };
constexpr static float main_uvs[] = { 0, 0, 1, 0, 0, 1, 1, 1 };

/// @note This enum must be kept in sync with the shader counterpart.
typedef enum VertexInputIndex {
  VertexInputIndexPosition = 0,
  VertexInputIndexTexCoords,
} VertexInputIndex;

/// @note This enum must be kept in sync with the shader counterpart.
typedef enum FragmentInputIndex {
  FragmentInputIndexTexture = 0,
} FragmentInputIndex;

NSString* content_shader = @
    R"msl(#include <metal_stdlib>
    #include <simd/simd.h>
    
    using namespace metal;
    
    typedef enum VertexInputIndex {
        VertexInputIndexPosition = 0,
        VertexInputIndexTexCoords,
    } VertexInputIndex;
    
    typedef enum FragmentInputIndex {
        FragmentInputIndexTexture = 0,
    } FragmentInputIndex;
    
    struct VertexOut {
        float4 position [[position]];
        float2 tex_coords;
    };
    
    vertex VertexOut vertexShader(uint vertexID [[vertex_id]],
                                constant vector_float2 *position [[buffer(VertexInputIndexPosition)]],
                                constant vector_float2 *tex_coords [[buffer(VertexInputIndexTexCoords)]]) {
        VertexOut out;
        out.position = vector_float4(position[vertexID], 0.0, 1.0);
        // The v coordinate of the distortion mesh is reversed compared to what Metal expects, so we invert it.
        out.tex_coords = vector_float2(tex_coords[vertexID].x, 1.0 - tex_coords[vertexID].y);
        return out;
    }
    
    fragment float4 fragmentShader(VertexOut in [[stage_in]],
                                texture2d<half> colorTexture [[texture(0)]]) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        return float4(colorTexture.sample(textureSampler, in.tex_coords));
    })msl";

typedef void (*SetARCameraBackground)(bool value);
SetARCameraBackground SetARCameraBackgroundDelegate = NULL;

typedef void (*RenderCallback)(void);
RenderCallback RenderCallbackDelegate = NULL;

namespace holokit {
class HoloKitDisplayProvider {
public:
    HoloKitDisplayProvider(IUnityXRTrace* trace,
                           IUnityXRDisplayInterface* display)
        : trace_(trace), display_(display) {}
    
    IUnityXRTrace* GetTrace() { return trace_; }
    
    IUnityXRDisplayInterface* GetDisplay() { return display_; }
    
    void SetHandle(UnitySubsystemHandle handle) { handle_ = handle; }
    
    void SetMtlInterface(IUnityGraphicsMetal* mtl_interface) { metal_interface_ = mtl_interface; }
    
    ///@return A reference to the static instance of this singleton class.
    static std::unique_ptr<HoloKitDisplayProvider>& GetInstance();

#pragma mark - Display Lifecycle Methods
    /// @brief Initializes the display subsystem.
    ///
    /// @details Loads and configures a UnityXRDisplayGraphicsThreadProvider and
    ///         UnityXRDisplayProvider with pointers to `display_provider_`'s methods.
    /// @param handle Opaque Unity pointer type passed between plugins.
    /// @return kUnitySubsystemErrorCodeSuccess when the registration is
    ///         successful. Otherwise, a value in UnitySubsystemErrorCode flagging
    ///         the error.
    UnitySubsystemErrorCode Initialize(UnitySubsystemHandle handle) {
        HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f Initialize()", GetCurrentTime());
        
        SetHandle(handle);
        
        // Register for callbacks on the graphics thread.
        UnityXRDisplayGraphicsThreadProvider gfx_thread_provider{};
        gfx_thread_provider.userData = NULL;
        gfx_thread_provider.Start = [](UnitySubsystemHandle, void*, UnityXRRenderingCapabilities* rendering_caps) -> UnitySubsystemErrorCode {
            return GetInstance()->GfxThread_Start(rendering_caps);
        };
        gfx_thread_provider.SubmitCurrentFrame = [](UnitySubsystemHandle, void*) -> UnitySubsystemErrorCode {
            return GetInstance()->GfxThread_SubmitCurrentFrame();
        };
        gfx_thread_provider.PopulateNextFrameDesc = []
        (UnitySubsystemHandle, void*, const UnityXRFrameSetupHints* frame_hints, UnityXRNextFrameDesc* next_frame) -> UnitySubsystemErrorCode {
            return GetInstance()->GfxThread_PopulateNextFrameDesc(frame_hints, next_frame);
        };
        gfx_thread_provider.Stop = [](UnitySubsystemHandle, void*) -> UnitySubsystemErrorCode {
            return GetInstance()->GfxThread_Stop();
        };
        GetInstance()->GetDisplay()->RegisterProviderForGraphicsThread(handle, &gfx_thread_provider);
        
        // Register for callbacks on display provider.
        UnityXRDisplayProvider provider{NULL, NULL, NULL};
        provider.QueryMirrorViewBlitDesc = [](UnitySubsystemHandle, void*, const UnityXRMirrorViewBlitInfo, UnityXRMirrorViewBlitDesc*) -> UnitySubsystemErrorCode {
            return kUnitySubsystemErrorCodeFailure;
        };
        GetInstance()->GetDisplay()->RegisterProvider(handle, &provider);
        
        return kUnitySubsystemErrorCodeSuccess;
    }
    
    UnitySubsystemErrorCode Start() {
        HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f Start()", GetCurrentTime());
        
        return kUnitySubsystemErrorCodeSuccess;
    }
    
    void Stop() const {}
    
    void Shutdown() const {}
    
    UnitySubsystemErrorCode GfxThread_Start(
            UnityXRRenderingCapabilities* rendering_caps) {
        HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f GfxThread_Start()", GetCurrentTime());
        // Does the system use multi-pass rendering?
        rendering_caps->noSinglePassRenderingSupport = true;
        rendering_caps->invalidateRenderStateAfterEachCallback = false;
        // Unity will swap buffers for us after GfxThread_SubmitCurrentFrame() is executed.
        rendering_caps->skipPresentToMainScreen = false;
        
        allocate_new_textures_ = true;
        is_first_frame_ = true;
        if (holokit::HoloKitApi::GetInstance()->StereoscopicRendering() && SetARCameraBackgroundDelegate) {
            SetARCameraBackgroundDelegate(false);
        }
        
        return kUnitySubsystemErrorCodeSuccess;
    }
    
#pragma mark - SubmitCurrentFrame()
    UnitySubsystemErrorCode GfxThread_SubmitCurrentFrame() {
        HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f GfxThread_SubmitCurrentFrame()", GetCurrentTime());
        NSLog(@"[time_interval]: %f", GetCurrentTime() - holokit::HoloKitApi::GetInstance()->GetLastPopulateNextFrameTime());
        
        os_log_t log = os_log_create("com.HoloInteractive.TheMagic", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
        os_signpost_id_t spid = os_signpost_id_generate(log);
        os_signpost_interval_begin(log, spid, "SubmitCurrentFrame");
        
        double currentTime = [[NSProcessInfo processInfo] systemUptime];
        //NSLog(@"[submitCurrentFrame]: current time: %f, time from last populate next frame: %f", currentTime, currentTime - holokit::HoloKitApi::GetInstance()->GetLastPopulateNextFrameTime());
        holokit::HoloKitApi::GetInstance()->SetLastSubmitCurrentFrameTime(currentTime);
        
        //RenderContent();
        RenderAlignmentMarker();
        
        if (RenderCallbackDelegate != NULL) {
            RenderCallbackDelegate();
        }
        
        os_signpost_interval_end(log, spid, "SubmitCurrentFrame");
        return kUnitySubsystemErrorCodeSuccess;
    }
    
    // Mimic how Google Cardboard does the rendering
    void RenderContent() {
        if (!main_metal_setup_) {
            id<MTLDevice> mtl_device = metal_interface_->MetalDevice();
            // Compile Metal library
            id<MTLLibrary> mtl_library = [mtl_device newLibraryWithSource:content_shader
                                                                  options:nil
                                                                    error:nil];
            if (mtl_library == nil) {
                HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "Failed to compile Metal content library.");
                return;
            }
            id<MTLFunction> vertex_function = [mtl_library newFunctionWithName:@"vertexShader"];
            id<MTLFunction> fragment_function = [mtl_library newFunctionWithName:@"fragmentShader"];
            
            // Create pipeline
            MTLRenderPipelineDescriptor* mtl_render_pipeline_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
            mtl_render_pipeline_descriptor.vertexFunction = vertex_function;
            mtl_render_pipeline_descriptor.fragmentFunction = fragment_function;
            mtl_render_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            //mtl_render_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            mtl_render_pipeline_descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            mtl_render_pipeline_descriptor.stencilAttachmentPixelFormat =
                MTLPixelFormatDepth32Float_Stencil8;
            mtl_render_pipeline_descriptor.sampleCount = 1;
            // Blending options
            mtl_render_pipeline_descriptor.colorAttachments[0].blendingEnabled = YES;
            mtl_render_pipeline_descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
            mtl_render_pipeline_descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
            mtl_render_pipeline_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
            mtl_render_pipeline_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
            mtl_render_pipeline_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
            mtl_render_pipeline_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
            
            main_render_pipeline_state_ = [mtl_device newRenderPipelineStateWithDescriptor:mtl_render_pipeline_descriptor error:nil];
            if (mtl_render_pipeline_descriptor == nil) {
                HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "Failed to create Metal content render pipeline.");
                return;
            }
            main_metal_setup_ = true;
        }
        
        id<MTLRenderCommandEncoder> mtl_render_command_encoder =
            (id<MTLRenderCommandEncoder>)metal_interface_->CurrentCommandEncoder();
        [mtl_render_command_encoder setRenderPipelineState:main_render_pipeline_state_];
        [mtl_render_command_encoder setVertexBytes:main_vertices length:sizeof(main_vertices) atIndex:VertexInputIndexPosition];
        [mtl_render_command_encoder setVertexBytes:main_uvs length:sizeof(main_uvs) atIndex:VertexInputIndexTexCoords];
        [mtl_render_command_encoder setFragmentTexture:metal_color_textures_[0] atIndex:FragmentInputIndexTexture];
        [mtl_render_command_encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip
                                       vertexStart:0
                                       vertexCount:4];
    }
    
    void RenderAlignmentMarker() {
        if (!second_metal_setup_) {
            id<MTLDevice> mtl_device = metal_interface_->MetalDevice();
            vertex_data[0] = vertex_data[4] = holokit::HoloKitApi::GetInstance()->GetHorizontalAlignmentMarkerOffset();
            
            second_vertex_buffer_ = [mtl_device newBufferWithBytes:vertex_data length:sizeof(vertex_data) options:MTLResourceOptionCPUCacheModeDefault];
            second_vertex_buffer_.label = @"vertices";
            //id<MTLBuffer> vertex_color_buffer = [mtl_device_ newBufferWithBytes:vertex_color_data length:sizeof(vertex_color_data) options:MTLResourceOptionCPUCacheModeDefault];
            //vertex_color_buffer.label = @"colors";
            
            id<MTLLibrary> lib = [mtl_device newLibraryWithSource:alignment_marker_shader options:nil error:nil];
            id<MTLFunction> vertex_function = [lib newFunctionWithName:@"passThroughVertex"];
            id<MTLFunction> fragment_function = [lib newFunctionWithName:@"passThroughFragment"];
            
            MTLRenderPipelineDescriptor* pipeline_descriptor = [[MTLRenderPipelineDescriptor alloc] init];
            pipeline_descriptor.vertexFunction = vertex_function;
            pipeline_descriptor.fragmentFunction = fragment_function;
            pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
            pipeline_descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            pipeline_descriptor.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
            pipeline_descriptor.sampleCount = 1;
            
            second_render_pipeline_state_ = [mtl_device newRenderPipelineStateWithDescriptor:pipeline_descriptor error:nil];
            second_metal_setup_ = true;
        }
        
        id<MTLRenderCommandEncoder> command_encoder = (id<MTLRenderCommandEncoder>)metal_interface_->CurrentCommandEncoder();
        [command_encoder setRenderPipelineState:second_render_pipeline_state_];
        [command_encoder setVertexBuffer:second_vertex_buffer_ offset:0 atIndex:0];
        //[command_encoder setVertexBuffer:vertex_color_buffer offset:0 atIndex:1];
        [command_encoder drawPrimitives:MTLPrimitiveTypeLine vertexStart:0 vertexCount:(sizeof(vertex_data) / sizeof(float))];
    }

#pragma mark - PopulateNextFrame()
    UnitySubsystemErrorCode GfxThread_PopulateNextFrameDesc(const UnityXRFrameSetupHints* frame_hints, UnityXRNextFrameDesc* next_frame) {
        NSLog(@" ");
        HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f GfxThread_PopulateNextFrameDesc()", GetCurrentTime());
        
        os_log_t log = os_log_create("com.HoloInteractive.TheMagic", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
        os_signpost_id_t spid = os_signpost_id_generate(log);
        os_signpost_interval_begin(log, spid, "PopulateNextFrame");
        
        double currentTime = [[NSProcessInfo processInfo] systemUptime];
        holokit::HoloKitApi::GetInstance()->SetLastPopulateNextFrameTime(currentTime);
        //NSLog(@"[populateNextFrame]: current time: %f", [[NSProcessInfo processInfo] systemUptime]);
        
        // We interrupt the graphics thread if it is not manually opened by SDK.
        if (!holokit::HoloKitApi::GetInstance()->StereoscopicRendering()) {
            NSLog(@"[display]: Manually shut down the display subsystem.");
            return kUnitySubsystemErrorCodeFailure;
        }
        
        // If this is the first frame for stereoscopic rendering mode.
        if (allocate_new_textures_) {
            DestroyTextures();
            int num_textures = 1;
            CreateTextures(num_textures);
            allocate_new_textures_ = false;
        }
        
        if (!holokit::HoloKitApi::GetInstance()->SinglePassRendering())
        {
            next_frame->renderPassesCount = NUM_RENDER_PASSES;
            
            // Iterate through each render pass.
            for (int pass = 0; pass < next_frame->renderPassesCount; ++pass)
            {
                auto& render_pass = next_frame->renderPasses[pass];
                
                if (pass < 2) {
                    // The first two passes for stereo rendering.
                    render_pass.textureId = unity_textures_[0];

                    render_pass.renderParamsCount = 1;
                    // Both passes share the same set of culling parameters.
                    render_pass.cullingPassIndex = pass;

                    auto& render_params = render_pass.renderParams[0];
                    // Render a black image in the first frame to avoid left viewport glitch.
                    if (is_first_frame_) {
                        UnityXRVector3 sky_position = UnityXRVector3 { 0, 999, 0 };
                        UnityXRVector4 sky_rotation = UnityXRVector4 { 0, 0, 0, 1 };
                        UnityXRPose sky_pose = { sky_position, sky_rotation };
                        render_params.deviceAnchorToEyePose = sky_pose;
                        is_first_frame_ = false;
                    } else {
                        render_params.deviceAnchorToEyePose = EyePositionToUnityXRPose(holokit::HoloKitApi::GetInstance()->GetEyePosition(pass));
                    }
                    render_params.projection.type = kUnityXRProjectionTypeMatrix;
                    render_params.projection.data.matrix = Float4x4ToUnityXRMatrix(holokit::HoloKitApi::GetInstance()->GetProjectionMatrix(pass));
                    render_params.viewportRect = Float4ToUnityXRRect(holokit::HoloKitApi::GetInstance()->GetViewportRect(pass));
                    
                    // Do culling for each eye seperately.
                    auto& culling_pass = next_frame->cullingPasses[pass];
                    culling_pass.separation = 0.064f;
                    culling_pass.deviceAnchorToCullingPose = next_frame->renderPasses[pass].renderParams[0].deviceAnchorToEyePose;
                    culling_pass.projection.type = kUnityXRProjectionTypeMatrix;
                    culling_pass.projection.data.matrix = next_frame->renderPasses[pass].renderParams[0].projection.data.matrix;
                } else {
                    // The extra pass for the invisible AR camera.
                    render_pass.textureId = unity_textures_[1];
                    //NSLog(@"texture id: %u", unity_textures_[1]);
                    render_pass.renderParamsCount = 1;
                    render_pass.cullingPassIndex = 0;
                    
                    auto& render_params = render_pass.renderParams[0];
                    UnityXRVector3 position = UnityXRVector3 { 0, 0, 0 };
                    UnityXRVector4 rotation = UnityXRVector4 { 0, 0, 0, 1 };
                    UnityXRPose pose = { position, rotation };
                    render_params.deviceAnchorToEyePose = pose;
                    render_params.projection.type = kUnityXRProjectionTypeMatrix;
                    simd_float4x4 projection_matrix = holokit::HoloKitApi::GetInstance()->GetArSessionHandler().arSession.currentFrame.camera.projectionMatrix;
                    render_params.projection.data.matrix = Float4x4ToUnityXRMatrix(projection_matrix);
                    render_params.viewportRect = {
                        0.0f,                    // x
                        0.0f,                    // y
                        1.0f,                    // width
                        1.0f                     // height
                    };
                }
            }
        }
        else
        {
            // Single-pass rendering
            next_frame->renderPassesCount = 1;
            auto& render_pass = next_frame->renderPasses[0];
            render_pass.textureId = unity_textures_[0];
            render_pass.renderParamsCount = 2;
            render_pass.cullingPassIndex = 0;
            for (int i = 0; i < 2; i++) {
                auto& render_params = render_pass.renderParams[i];
                render_params.deviceAnchorToEyePose = EyePositionToUnityXRPose(holokit::HoloKitApi::GetInstance()->GetEyePosition(i));
                render_params.projection.type = kUnityXRProjectionTypeMatrix;
                render_params.projection.data.matrix = Float4x4ToUnityXRMatrix(holokit::HoloKitApi::GetInstance()->GetProjectionMatrix(i));
                render_params.viewportRect = Float4ToUnityXRRect(holokit::HoloKitApi::GetInstance()->GetViewportRect(i));
            }
            auto& culling_pass = next_frame->cullingPasses[0];
            culling_pass.separation = 0.064f;
            culling_pass.deviceAnchorToCullingPose = next_frame->renderPasses[0].renderParams[0].deviceAnchorToEyePose;
            culling_pass.projection.type = kUnityXRProjectionTypeMatrix;
            culling_pass.projection.data.matrix = next_frame->renderPasses[0].renderParams[0].projection.data.matrix;
        }
        os_signpost_interval_end(log, spid, "PopulateNextFrame");
        return kUnitySubsystemErrorCodeSuccess;
    }
    
    UnitySubsystemErrorCode GfxThread_Stop() {
        HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f GfxThread_Stop()", GetCurrentTime());

        //holokit::HoloKitApi::GetInstance()->SetStereoscopicRendering(false);
        if (holokit::HoloKitApi::GetInstance()->StereoscopicRendering() && SetARCameraBackgroundDelegate) {
            SetARCameraBackgroundDelegate(true);
        }
        
        return kUnitySubsystemErrorCodeSuccess;
    }

    UnitySubsystemErrorCode UpdateDisplayState(UnityXRDisplayState* state) {
        return kUnitySubsystemErrorCodeSuccess;
    }
    
    UnitySubsystemErrorCode QueryMirrorViewBlitDesc(const UnityXRMirrorViewBlitInfo mirrorBlitInfo, UnityXRMirrorViewBlitDesc * blitDescriptor) {
        //HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f QueryMirrorViewBlitDesc()", GetCurrentTime());
        //return kUnitySubsystemErrorCodeSuccess;
        return kUnitySubsystemErrorCodeFailure;
    }
    
#pragma mark - CreateTextures()
private:
    
    /// @brief Allocate unity textures.
    void CreateTextures(int num_textures) {
        HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f CreateTextures()", GetCurrentTime());
        
        id<MTLDevice> mtl_device = metal_interface_->MetalDevice();
        
        const int screen_width = holokit::HoloKitApi::GetInstance()->GetScreenWidth();
        const int screen_height = holokit::HoloKitApi::GetInstance()->GetScreenHeight();
        
        unity_textures_.resize(num_textures);
        native_color_textures_.resize(num_textures);
        native_depth_textures_.resize(num_textures);
        metal_color_textures_.resize(num_textures);
        io_surfaces_.resize(num_textures);
        
        for (int i = 0; i < num_textures; i++) {
            UnityXRRenderTextureDesc texture_descriptor;
            memset(&texture_descriptor, 0, sizeof(UnityXRRenderTextureDesc));
            
            texture_descriptor.width = screen_width;
            texture_descriptor.height = screen_height;
            texture_descriptor.flags = 0;
            texture_descriptor.depthFormat = kUnityXRDepthTextureFormatNone;
            
            // Create texture color buffer.
            NSDictionary* color_surface_attribs = @{
                (NSString*)kIOSurfaceIsGlobal : @ YES,
                (NSString*)kIOSurfaceWidth : @(screen_width),
                (NSString*)kIOSurfaceHeight : @(screen_height),
                (NSString*)kIOSurfaceBytesPerElement : @4u
            };
            io_surfaces_[i] = IOSurfaceCreate((CFDictionaryRef)color_surface_attribs);
            MTLTextureDescriptor* texture_color_buffer_descriptor = [[MTLTextureDescriptor alloc] init];
            texture_color_buffer_descriptor.textureType = MTLTextureType2D;
            texture_color_buffer_descriptor.width = screen_width;
            texture_color_buffer_descriptor.height = screen_height;
            texture_color_buffer_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
            //texture_color_buffer_descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
            texture_color_buffer_descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
            metal_color_textures_[i] = [mtl_device newTextureWithDescriptor:texture_color_buffer_descriptor iosurface:io_surfaces_[i] plane:0];
            
            uint64_t color_buffer = reinterpret_cast<uint64_t>(io_surfaces_[i]);
            native_color_textures_[i] = reinterpret_cast<void*>(color_buffer);
            uint64_t depth_buffer = 0;
            native_depth_textures_[i] = reinterpret_cast<void*>(depth_buffer);
            
            //io_surfaces_[i] = color_surface;
            
            texture_descriptor.color.nativePtr = native_color_textures_[i];
            texture_descriptor.depth.nativePtr = native_depth_textures_[i];
            
            UnityXRRenderTextureId unity_texture_id;
            display_->CreateTexture(handle_, &texture_descriptor, &unity_texture_id);
            unity_textures_[i] = unity_texture_id;
        }
    }
    
    /// @brief Deallocate textures.
    void DestroyTextures() {
        HOLOKIT_DISPLAY_XR_TRACE_LOG(trace_, "%f DestroyTextures()", GetCurrentTime());
        
        for (int i = 0; i < unity_textures_.size(); i++) {
            if(unity_textures_[i] != 0) {
                display_->DestroyTexture(handle_, unity_textures_[i]);
                native_color_textures_[i] = nullptr;
                native_depth_textures_[i] = nullptr;
                metal_color_textures_[i] = nil;
                io_surfaces_[i] = nil;
            }
        }
        
        unity_textures_.clear();
        native_color_textures_.clear();
        metal_color_textures_.clear();
        io_surfaces_.clear();
    }
    
#pragma mark - Private Properties
private:
    ///@brief Points to Unity XR Trace interface.
    IUnityXRTrace* trace_ = nullptr;
    
    ///@brief Points to Unity XR Display interface.
    IUnityXRDisplayInterface* display_ = nullptr;
    
    ///@brief Opaque Unity pointer type passed between plugins.
    UnitySubsystemHandle handle_;
    
    /// @brief An array of UnityXRRenderTextureId.
    std::vector<UnityXRRenderTextureId> unity_textures_;
    
    /// @brief An array of native texture pointers.
    std::vector<void*> native_color_textures_;
    
    std::vector<void*> native_depth_textures_;
    
    /// @brief An array of metal textures.
    std::vector<id<MTLTexture>> metal_color_textures_;
    
    std::vector<IOSurfaceRef> io_surfaces_;
    
    /// @brief This value is set to true when Metal is initialized for the first time.
    bool main_metal_setup_ = false;
    
    /// @brief The render pipeline state for content rendering.
    id <MTLRenderPipelineState> main_render_pipeline_state_;
    
    /// @brief This value is used for rendering widgets.
    bool second_metal_setup_ = false;
    
    id <MTLBuffer> main_vertex_buffer_;
    
    id <MTLBuffer> main_index_buffer_;
    
    id <MTLBuffer> second_vertex_buffer_;
    
    /// @brief The render pipeline state for rendering alignment marker.
    id <MTLRenderPipelineState> second_render_pipeline_state_;
    
    bool is_first_frame_ = true;
    
    bool allocate_new_textures_ = true;
    
    /// @brief Points to Metal interface.
    IUnityGraphicsMetal* metal_interface_;
    
    static std::unique_ptr<HoloKitDisplayProvider> display_provider_;
};

std::unique_ptr<HoloKitDisplayProvider> HoloKitDisplayProvider::display_provider_;

std::unique_ptr<HoloKitDisplayProvider>& HoloKitDisplayProvider::GetInstance() {
    return display_provider_;
}

} // namespace

UnitySubsystemErrorCode LoadDisplay(IUnityInterfaces* xr_interfaces) {
    auto* display = xr_interfaces->Get<IUnityXRDisplayInterface>();
    if(display == NULL) {
        return kUnitySubsystemErrorCodeFailure;
    }
    auto* trace = xr_interfaces->Get<IUnityXRTrace>();
    if(trace == NULL) {
        return kUnitySubsystemErrorCodeFailure;
    }
    holokit::HoloKitDisplayProvider::GetInstance().reset(new holokit::HoloKitDisplayProvider(trace, display));
    HOLOKIT_DISPLAY_XR_TRACE_LOG(trace, "%f LoadDisplay()", GetCurrentTime());
    
    holokit::HoloKitDisplayProvider::GetInstance()->SetMtlInterface(xr_interfaces->Get<IUnityGraphicsMetal>());
    
    UnityLifecycleProvider display_lifecycle_handler;
    display_lifecycle_handler.userData = NULL;
    display_lifecycle_handler.Initialize = [](UnitySubsystemHandle handle, void*) -> UnitySubsystemErrorCode {
        return holokit::HoloKitDisplayProvider::GetInstance()->Initialize(handle);
    };
    display_lifecycle_handler.Start = [](UnitySubsystemHandle, void*) -> UnitySubsystemErrorCode {
        return holokit::HoloKitDisplayProvider::GetInstance()->Start();
    };
    display_lifecycle_handler.Stop = [](UnitySubsystemHandle, void*) -> void {
        return holokit::HoloKitDisplayProvider::GetInstance()->Stop();
    };
    display_lifecycle_handler.Shutdown = [](UnitySubsystemHandle, void*) -> void {
        return holokit::HoloKitDisplayProvider::GetInstance()->Shutdown();
    };

    // the names do matter
    // The parameters passed to RegisterLifecycleProvider must match the name and id fields in your manifest file.
    // see https://docs.unity3d.com/Manual/xrsdk-provider-setup.html
    return holokit::HoloKitDisplayProvider::GetInstance()->GetDisplay()->RegisterLifecycleProvider("HoloKit XR Plugin", "HoloKit Display", &display_lifecycle_handler);
}

void UnloadDisplay() { holokit::HoloKitDisplayProvider::GetInstance().reset(); }

extern "C" {

void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SetSetARCameraBackgroundDelegate(SetARCameraBackground callback) {
    SetARCameraBackgroundDelegate = callback;
}

void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SetRenderCallbackDelegate(RenderCallback callback) {
    RenderCallbackDelegate = callback;
}

} // extern "C"
