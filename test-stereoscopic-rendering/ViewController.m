//
//  ViewController.m
//  HoloKitStereoscopicRendering
//
//  Created by Yuchen on 2021/2/4.
//

#import "ViewController.h"
#import "Renderer.h"

#define MIN(A,B)    ({ __typeof__(A) __a = (A); __typeof__(B) __b = (B); __a < __b ? __a : __b; })
#define MAX(A,B)    ({ __typeof__(A) __a = (A); __typeof__(B) __b = (B); __a < __b ? __b : __a; })

#define CLAMP(x, low, high) ({\
  __typeof__(x) __x = (x); \
  __typeof__(low) __low = (low);\
  __typeof__(high) __high = (high);\
  __x > __high ? __high : (__x < __low ? __low : __x);\
  })

@interface ViewController () <MTKViewDelegate, ARSessionDelegate, TrackerDelegate>

@property (nonatomic, strong) ARSession *session;
@property (nonatomic, strong) Renderer *renderer;
// for handtracking
@property (nonatomic, strong) HandTracker *handTracker;
@property (nonatomic, strong) NSArray<NSArray<Landmark *> *> *landmarks;
// for handtracking debug
@property (assign) double landmarkZMin;
@property (assign) double landmarkZMax;

@end


@interface MTKView () <RenderDestinationProvider>

@end


@implementation ViewController {
    
    // for depth data
    CVMetalTextureRef _depthTextureRef;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Create an ARSession
    self.session = [ARSession new];
    self.session.delegate = self;
    
    // Set hand tracker
    _landmarkZMin = 1000;
    _landmarkZMax = -1000;
    self.handTracker = [[HandTracker alloc] init];
    self.handTracker.delegate = self;
    [self.handTracker startGraph];
    
    // Set the view to use the default device
    MTKView *view = (MTKView *)self.view;
    view.device = MTLCreateSystemDefaultDevice();
    view.backgroundColor = UIColor.clearColor;
    view.delegate = self;
    
    if(!view.device) {
        NSLog(@"Metal is not supported on this device");
        return;
    }
    
    // Configure the renderer to draw to the view
    self.renderer = [[Renderer alloc] initWithSession:self.session metalDevice:view.device renderDestinationProvider:view];
    
    [self.renderer drawRectResized:view.bounds.size drawableSize:view.drawableSize];
    
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    NSMutableArray *gestureRecognizers = [NSMutableArray array];
    [gestureRecognizers addObject:tapGesture];
    [gestureRecognizers addObjectsFromArray:view.gestureRecognizers];
    view.gestureRecognizers = gestureRecognizers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    ARWorldTrackingConfiguration *configuration = [ARWorldTrackingConfiguration new];
    // for scene depth
    //configuration.frameSemantics = ARFrameSemanticSmoothedSceneDepth;
    configuration.frameSemantics = ARFrameSemanticSceneDepth;

    [self.session runWithConfiguration:configuration];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    [self.session pause];
}

- (void)handleTap:(UIGestureRecognizer*)gestureRecognize {
    ARFrame *currentFrame = [self.session currentFrame];
    
    // Create anchor using the camera's current position
    if (currentFrame) {
        
        // Create a transform with a translation of 0.2 meters in front of the camera
        matrix_float4x4 translation = matrix_identity_float4x4;
        // TODO: place the geometry on a physical plane
        translation.columns[3].z = -0.2;
        matrix_float4x4 transform = matrix_multiply(currentFrame.camera.transform, translation);
        
        // Add a new anchor to the session
        ARAnchor *anchor = [[ARAnchor alloc] initWithTransform:transform];
        [self.session addAnchor:anchor];
    }
}

#pragma mark - MTKViewDelegate

// Called whenever view changes orientation or layout is changed
- (void)mtkView:(nonnull MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self.renderer drawRectResized:view.bounds.size drawableSize:size];
}

// Called whenever the view needs to render
- (void)drawInMTKView:(nonnull MTKView *)view {
    [self.renderer update];
}

#pragma mark - ARSessionDelegate

- (void)session:(ARSession *)session didUpdateFrame:(ARFrame *)frame {
    // process capturedImage for handtracking
    
    //NSLog(@"handTracker.processVideoFrame is called");
    [_handTracker processVideoFrame: frame.capturedImage];
}

- (void)session:(ARSession *)session didFailWithError:(NSError *)error {
    // Present an error message to the user
    
}

- (void)sessionWasInterrupted:(ARSession *)session {
    // Inform the user that the session has been interrupted, for example, by presenting an overlay
    
}

- (void)sessionInterruptionEnded:(ARSession *)session {
    // Reset tracking and/or remove existing anchors if consistent tracking is required
    
}

#pragma mark - HandTracking

- (void)handTracker:(HandTracker *)handTracker didOutputLandmarks:(NSArray<NSArray<Landmark *> *> *)multiLandmarks {
    
    //NSLog(@"handTracker function is called");
    _landmarks = multiLandmarks;
    
    if(_session.currentFrame == nil){
        return;
    }
    ARFrame *currentFrame = _session.currentFrame;
    // remove all handtracking anchors from last frame
    for(ARAnchor *anchor in currentFrame.anchors){
        if([anchor.name isEqual:@"handtracking"]) {
            [_session removeAnchor:anchor];
        }
    }
    
    // get the scene depth
    //ARDepthData* sceneDepth = _session.currentFrame.smoothedSceneDepth;
    ARDepthData* sceneDepth = _session.currentFrame.sceneDepth;
    if (!sceneDepth){
        NSLog(@"ViewController");
        NSLog(@"Failed to acquire scene depth.");
        return;
    }
    CVPixelBufferRef pixelBuffer = sceneDepth.depthMap;
    
    // from https://stackoverflow.com/questions/34569750/get-pixel-value-from-cvpixelbufferref-in-swift
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    size_t bufferWidth = CVPixelBufferGetWidth(pixelBuffer);
    size_t bufferHeight = CVPixelBufferGetHeight(pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    NSLog(@"bufferWidth: %d, bufferHeight: %d, bytesPerRow: %d", bufferWidth, bufferHeight, bytesPerRow);
    
    Float32* baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    
    for(NSArray<Landmark *> *landmarks in multiLandmarks){
        int idx = 0;
        for(Landmark *landmark in landmarks){
            
            int x = (CGFloat)landmark.x * currentFrame.camera.imageResolution.width;
            int y = (CGFloat)landmark.y * currentFrame.camera.imageResolution.height;
            CGPoint screenPoint = CGPointMake(x, y);
            
            // get the depth value of the landmark from the depthMap
            int depthX = CLAMP(landmark.x, 0, 1) * bufferWidth;
            int depthY = CLAMP(landmark.y, 0, 1) * bufferHeight;
            float landmarkDepth = baseAddress[depthY * bufferWidth + depthX];
            
            //CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
            
            // solving the depth problem
            //NSLog(@"%f %f %f", landmark.x, landmark.y, landmark.z);
            //NSLog(@"z value: %f", landmark.z);
            if(landmark.z < _landmarkZMin) {
                _landmarkZMin = landmark.z;
            }
            if(landmark.z > _landmarkZMax) {
                _landmarkZMax = landmark.z;
            }
            //NSLog(@"%f %f %f", landmark.x, landmark.y, landmark.z);
            //NSLog(@"Landmark Z Min is: %f", _landmarkZMin);
            //NSLog(@"Landmakr Z Max is: %f", _landmarkZMax);
            
            simd_float4x4 translation = matrix_identity_float4x4;
            // set z values for different landmarks
            translation.columns[3].z = -landmarkDepth;
            // TODO: find a better constant
            //float handDepthConstant = 0.13 / 0.75;
            //// the z value of the wrist landmark is temporarily fixed
            //if (idx != 0) {
            //    translation.columns[3].z += landmark.z * handDepthConstant;
            //}
            idx++;
            
            simd_float4x4 planeOrigin = simd_mul(currentFrame.camera.transform, translation);
            simd_float3 xAxis = simd_make_float3(1, 0, 0);
            //simd_float4x4 rotation = simd_quaternion(0.5 * M_PI, xAxis);
            //NSLog(@"%f", simd_quaternion(0.5 * M_PI, xAxis).vector.x);
            //NSLog(@"%f", simd_quaternion(0.5 * M_PI, xAxis).vector.y);
            //NSLog(@"%f", simd_quaternion(0.5 * M_PI, xAxis).vector.z);
            //NSLog(@"%f", simd_quaternion(0.5 * M_PI, xAxis).vector.w);
            simd_float4x4 rotation = simd_matrix4x4(simd_quaternion(0.5 * M_PI, xAxis));
            //NSLog(@"rotation");
            //[MathHelper logMatrix4x4:rotation];
            simd_float4x4 plane = simd_mul(planeOrigin, rotation);
            // make sure this plane matrix is correct
            //[MathHelper logMatrix4x4:plane];
            simd_float3 unprojectedPoint = [currentFrame.camera unprojectPoint:screenPoint ontoPlaneWithTransform:plane orientation:UIInterfaceOrientationLandscapeRight viewportSize:currentFrame.camera.imageResolution];
            //NSLog(@"image resolution: %d %d", (int)currentFrame.camera.imageResolution.width, (int)currentFrame.camera.imageResolution.height);
            // TODO: if unprojectedPoint is nil?
            simd_float4x4 tempTransform = matrix_identity_float4x4;
            tempTransform.columns[3].x = unprojectedPoint.x;
            tempTransform.columns[3].y = unprojectedPoint.y;
            tempTransform.columns[3].z = unprojectedPoint.z;
            simd_float4x4 landmarkTransform = simd_mul(currentFrame.camera.transform, tempTransform);
            
            ARAnchor *anchor = [[ARAnchor alloc] initWithName:@"handtracking" transform:tempTransform];
            
            [_session addAnchor:anchor];
        }
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

- (void)handTracker: (HandTracker*)handTracker didOutputHandednesses: (NSArray<Handedness *> *)handednesses {
    
}

- (void)handTracker: (HandTracker*)handTracker didOutputPixelBuffer: (CVPixelBufferRef)pixelBuffer {
    
}

@end
