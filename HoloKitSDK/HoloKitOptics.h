//
//  HoloKitOptics.h
//  holokit
//
//  Created by Yuchen Zhang on 2022/7/19.
//

#import <Foundation/Foundation.h>
#import <simd/simd.h>
#import "HoloKitProfile.h"

typedef struct {
    simd_float4 LeftViewportRect;
    simd_float4 RightViewportRect;
    float NearClipPlane;
    float FarClipPlane;
    simd_float4x4 LeftProjectionMatrix;
    simd_float4x4 RightProjectionMatrix;
    simd_float3 CameraToCenterEyeOffset;
    simd_float3 CameraToScreenCenterOffset;
    simd_float3 CenterEyeToLeftEyeOffset;
    simd_float3 CenterEyeToRightEyeOffset;
    // The horizontal distance from the screen center in pixels
    float AlignmentMarkerOffset;
} HoloKitCameraData;

@interface HoloKitOptics : NSObject

+ (HoloKitCameraData)getHoloKitCameraData:(HoloKitModel)holokitModel ipd:(float)ipd farClipPlane:(float)farClipPlane;

@end
