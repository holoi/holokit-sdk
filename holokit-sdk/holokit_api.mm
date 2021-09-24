//
//  holokit_xr_unity.cpp
//  holokit-sdk-skeleton
//
//  Created by Yuchen on 2021/3/29.
//

#import "holokit_api.h"
#import "IUnityInterface.h"
#import <sys/utsname.h>
#import "display.mm"
#import "hand_tracking.h"

const float kUserInterpupillaryDistance = 0.064;

namespace holokit {

#pragma mark - Initialize()
void HoloKitApi::Initialize() {
    NSLog(@"[HoloKitApi]: Initialize()");
    
    GetDeviceModel();
    
    InitOpticalParameters();
    
    ar_session_handler_ = [HoloKitARSession sharedARSession];
    
    if ([device_name_ isEqualToString:@"iPhone13,3"] == NO &&
        [device_name_ isEqualToString:@"iPhone13,4"] == NO) {
        NSLog(@"[HoloKitApi]: the phone type does not support hand tracking.");
        [[HoloKitHandTracker sharedHandTracker] setIsHandTrackingEnabled:NO];
    } else {
        NSLog(@"[HoloKitApi]: the phone type does support hand tracking.");
    }
    
    is_initialized_ = true;
}

void HoloKitApi::GetDeviceModel() {
    // see: https://stackoverflow.com/questions/9617301/how-to-print-out-string-constant-with-nslog-on-ios
    struct utsname system_info;
    uname(&system_info);
    device_name_ = [NSString stringWithCString:system_info.machine encoding:NSUTF8StringEncoding];
    NSLog(@"[holoki_api]: device name: %@", device_name_);
}

void HoloKitApi::InitOpticalParameters() {
    auto phone = Profile::GetPhoneModel(Profile::DeviceNameToPhoneType(device_name_));
    auto model = Profile::GetHoloKitModel(Profile::HoloKitX);
    screen_width_ = phone.screenResolutionWidth;
    screen_height_ = phone.screenResolutionHeight;
    
    // projection matrices
    float center_x = 0.5f * phone.screenWidth + phone.centerLineOffset;
    float center_y = phone.screenHeight - (model.axisToBottom - phone.screenBottom);
    float full_width = model.viewportOuter * 2 + model.opticalAxisDistance + model.viewportCushion * 2;
    float width = model.viewportOuter + model.viewportInner + model.viewportCushion * 2;
    float height = model.viewportTop + model.viewportBottom + model.viewportCushion * 2;
    float ipd = kUserInterpupillaryDistance;
    float near = model.lensToEye;
    float far = 1000.0f;
    
    simd_float4x4 left_projection_matrix;
    left_projection_matrix.columns[0].x = 2 * near / width;
    left_projection_matrix.columns[1].y = 2 * near / height;
    left_projection_matrix.columns[2].x = (full_width - ipd - width) / width;
    left_projection_matrix.columns[2].y = (model.viewportTop - model.viewportBottom) / height;
    left_projection_matrix.columns[2].z = -(far + near) / (far - near);
    left_projection_matrix.columns[3].z = -(2.0 * far * near) / (far - near);
    left_projection_matrix.columns[2].w = -1.0;
    left_projection_matrix.columns[3].w = 0.0;
    
    simd_float4x4 right_projection_matrix = left_projection_matrix;
    right_projection_matrix.columns[2].x = -right_projection_matrix.columns[2].x;
    
    projection_matrices_.resize(2);
    projection_matrices_[0] = left_projection_matrix;
    projection_matrices_[1] = right_projection_matrix;
    
    // viewport rects
    double y_min_in_pixel = (double)((center_y - (model.viewportTop + model.viewportCushion)) / phone.screenHeight * (float)screen_height_);
    double x_min_right_in_pixel = (double)((center_x + full_width / 2 - width) / phone.screenWidth * (float)screen_width_);
    double x_min_left_in_pixel = (double)((center_x - full_width / 2) / phone.screenWidth * (float)screen_width_);
    
    double width_in_pixel = (double)(width / phone.screenWidth * (float)screen_width_);
    double height_in_pixel = (double)(height / phone.screenHeight * (float)screen_height_);
    
    simd_float4 leftRect;
    leftRect.x = x_min_left_in_pixel / screen_width_;
    leftRect.z = width_in_pixel / screen_width_;
    leftRect.w = height_in_pixel / screen_height_;
    leftRect.y = 1 - y_min_in_pixel / screen_height_ - leftRect.w;
    simd_float4 rightRect;
    rightRect.x = x_min_right_in_pixel / screen_width_;
    rightRect.z = width_in_pixel / screen_width_;
    rightRect.w = height_in_pixel / screen_height_;
    rightRect.y = 1 - y_min_in_pixel / screen_height_ - rightRect.w;
    
    viewport_rects_.resize(2);
    viewport_rects_[0] = leftRect;
    viewport_rects_[1] = rightRect;
    
    // view matrices
    simd_float3 offset = phone.cameraOffset + model.mrOffset;
    // offset is in Unity coordinate and camera_to_center_eye_offset is in ARKit coordinate.
    camera_to_center_eye_offset_ = offset;
    eye_positions_.resize(2);
    eye_positions_[0] = simd_make_float3(offset.x - ipd / 2, offset.y, offset.z);
    eye_positions_[1] = simd_make_float3(offset.x + ipd / 2, offset.y, offset.z);
    //eye_positions_[0] = simd_make_float3(- ipd / 2, 0, 0);
    //eye_positions_[1] = simd_make_float3(+ ipd / 2, 0, 0);
    
    // horizontal alignment marker offset
    horizontal_alignment_marker_offset_ = model.horizontalAlignmentMarkerOffset / (phone.screenWidth / 2);
}

simd_float4x4 HoloKitApi::GetProjectionMatrix(int eye_index) {
    if(eye_index == 0) {
        return projection_matrices_[0];
    } else if (eye_index == 1) {
        return projection_matrices_[1];
    }
    NSLog(@"[HoloKitApi]: projection matrices are not initialized.");
    return matrix_identity_float4x4;
}

simd_float4 HoloKitApi::GetViewportRect(int eye_index) {
    if(eye_index == 0) {
        return viewport_rects_[0];
    } else if (eye_index == 1) {
        return viewport_rects_[1];
    }
    NSLog(@"[HoloKitApi]: viewport rects are not initialized.");
    return simd_make_float4(0);
}

simd_float3 HoloKitApi::GetEyePosition(int eye_index) {
    if(eye_index == 0) {
        return eye_positions_[0];
    } else if (eye_index == 1) {
        return eye_positions_[1];
    }
    NSLog(@"[HoloKitApi]: eye positions are not initialized.");
    return simd_make_float3(0);
}

bool HoloKitApi::StartNfcSession() {
    NFCSession* nfcSession = [NFCSession sharedNFCSession];
    [nfcSession startReaderSession];
    
    double nfc_start_time = [[NSProcessInfo processInfo] systemUptime];
    double nfc_timeout = 15;
    while([[NSProcessInfo processInfo] systemUptime] - nfc_start_time < nfc_timeout && !nfcSession.isFinished) {
         //Waiting the user to validate NFC
    }
    
    // BETA: Wait for a short period of time
    double start_time = [[NSProcessInfo processInfo] systemUptime];
    double interval;
    if (nfcSession.isValid) {
        interval = 4;
    } else {
        interval = 1.5;
    }
    while([[NSProcessInfo processInfo] systemUptime] - start_time < interval) {
        // Wait
    }
    
    return nfcSession.isValid;
}

simd_float4x4 HoloKitApi::GetCurrentCameraTransform() {
    if (ar_session_handler_ != nullptr && ar_session_handler_.arSession != NULL) {
        return ar_session_handler_.arSession.currentFrame.camera.transform;
    } else {
        return matrix_identity_float4x4;
    }
}

} // namespace

extern "C" {

bool UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_StereoscopicRendering() {
    return holokit::HoloKitApi::GetInstance()->StereoscopicRendering();
}

void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SetStereoscopicRendering(bool value) {
    return holokit::HoloKitApi::GetInstance()->SetStereoscopicRendering(value);
}

float* UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_GetCameraToCenterEyeOffsetPtr() {
    simd_float3 offset = holokit::HoloKitApi::GetInstance()->GetCameraToCenterEyeOffset();
    float* result = new float[3];
    result[0] = offset.x;
    result[1] = offset.y;
    result[2] = offset.z;
    return result;
}

int UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_ReleaseCameraToCenterEyeOffsetPtr(float* ptr) {
    // https://stackoverflow.com/questions/17634480/return-c-array-to-c-sharp/18041888
    delete[] ptr;
    return 0;
}

bool UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_StartNfcSession() {
    // TEMPORARY
    return true;
    return holokit::HoloKitApi::GetInstance()->StartNfcSession();
}

void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SetSecondDisplayAvailable(bool value) {
    holokit::HoloKitApi::GetInstance()->SetSecondDisplayAvailable(value);
}


} // extern "C"
