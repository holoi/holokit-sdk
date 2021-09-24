//
//  watch_connectivity.m
//  watch_connectivity
//
//  Created by Yuchen on 2021/8/30.
//

#import "watch_connectivity.h"
#import "core_motion.h"
#import "math_helpers.h"
#import "IUnityInterface.h"

typedef void (*DidReceiveWatchSystemMessage)(int messageIndex);
DidReceiveWatchSystemMessage DidReceiveWatchSystemMessageDelegate = NULL;

typedef void (*DidReceiveWatchActionMessage)(int messageIndex, int watchPitch, int watchRoll, int watchYaw, int iphoneYaw);
DidReceiveWatchActionMessage DidReceiveWatchActionMessageDelegate = NULL;

typedef void (*DidChangeReachability)(bool reachable);
DidChangeReachability DidChangeReachabilityDelegate = NULL;

@interface HoloKitWatchConnectivity() <WCSessionDelegate>

@property (nonatomic, strong) WCSession *wcSession;

@end

@implementation HoloKitWatchConnectivity

- (instancetype)init {
    if (self = [super init]) {
        if ([WCSession isSupported]) {
            self.wcSession = [WCSession defaultSession];
            self.wcSession.delegate = self;
            // We let Unity manually activate the session when needed.
            [self.wcSession activateSession];
   
            HoloKitCoreMotion *coreMotionInstance = [HoloKitCoreMotion sharedCoreMotion];
            [coreMotionInstance startDeviceMotion:^void (CMDeviceMotion *) { }];
        }
    }
    return self;
}

- (void)sendMessage2WatchWithMessageType:(NSString *)messageType messageIndex:(int)index {
    if (self.wcSession.isReachable) {
        NSDictionary<NSString *, id> *message = @{ messageType : [NSNumber numberWithInt:index] };
        [self.wcSession sendMessage:message replyHandler:nil errorHandler:nil];
    } else {
        NSLog(@"[wc_session]: The Apple Watch is not reachable.");
    }
}

+ (id)sharedWatchConnectivity {
    static dispatch_once_t onceToken = 0;
    static id _sharedObject = nil;
    dispatch_once(&onceToken, ^{
        _sharedObject = [[self alloc] init];
    });
    return _sharedObject;
}

#pragma mark - WCSessionDelegate

- (void)session:(WCSession *)session activationDidCompleteWithState:(WCSessionActivationState)activationState error:(NSError *)error {
    if (activationState == WCSessionActivationStateActivated) {
        NSLog(@"[wc_session]: activation did compelete with state activated.");
    } else if (activationState == WCSessionActivationStateInactive) {
        NSLog(@"[wc_session]: activation did compelete with state inactive.");
    } else if (activationState == WCSessionActivationStateNotActivated) {
        NSLog(@"[wc_session]: activation did compelete with state not activated.");
    }
}

- (void)sessionReachabilityDidChange:(WCSession *)session {
    if (session.isReachable) {
        NSLog(@"[wc_session]: session reachability did change to reachable.");
    } else {
        NSLog(@"[wc_session]: session reachability did change to not reachable.");
    }
    if (DidChangeReachabilityDelegate != NULL) {
        DidChangeReachabilityDelegate(session.isReachable );
    }
}

- (void)session:(WCSession *)session didReceiveMessage:(NSDictionary<NSString *,id> *)message {
    if (id watchActionValue = [message objectForKey:@"WatchInput"]) {
        if (id watchPitchValue = [message objectForKey:@"WatchPitch"]) {
            if (id watchRollValue = [message objectForKey:@"WatchRoll"]) {
                if (id watchYawValue = [message objectForKey:@"WatchYaw"]) {
                    NSInteger watchActionIndex = [watchActionValue integerValue];
                    NSInteger watchPitch = [watchPitchValue integerValue];
                    NSInteger watchRoll = [watchRollValue integerValue];
                    NSInteger watchYaw = [watchYawValue integerValue];
                    HoloKitCoreMotion *coreMotionInstance = [HoloKitCoreMotion sharedCoreMotion];
                    DidReceiveWatchActionMessageDelegate((int)watchActionIndex, (int)watchPitch, (int)watchRoll, (int)watchYaw, (int)Radians2Degrees(coreMotionInstance.currentDeviceMotion.attitude.yaw));
                }
            }
        }
    } else if (id watchSystemValue = [message objectForKey:@"WatchSystem"]) {
        NSInteger watchSystemIndex = [watchSystemValue integerValue];
        DidReceiveWatchSystemMessageDelegate((int)watchSystemIndex);
    }
}

- (void)sessionDidBecomeInactive:(nonnull WCSession *)session {
    
}


- (void)sessionDidDeactivate:(nonnull WCSession *)session {
    
}

@end

#pragma mark - extern "C"

extern "C" {

// You need to manually init WCSession in Unity.
void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_InitWatchConnectivitySession() {
    [HoloKitWatchConnectivity sharedWatchConnectivity];
}

void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SendMessage2Watch(const char *messageType, int index) {
    HoloKitWatchConnectivity *instance = [HoloKitWatchConnectivity sharedWatchConnectivity];
    [instance sendMessage2WatchWithMessageType:[NSString stringWithUTF8String:messageType] messageIndex:index];
}

void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SetDidReceiveWatchSystemMessageDelegate(DidReceiveWatchSystemMessage callback) {
    DidReceiveWatchSystemMessageDelegate = callback;
}

void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SetDidReceiveWatchActionMessageDelegate(DidReceiveWatchActionMessage callback) {
    DidReceiveWatchActionMessageDelegate = callback;
}

bool UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_GetIsReachable() {
    return [[HoloKitWatchConnectivity sharedWatchConnectivity] wcSession].isReachable;
}

void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SetDidChangeReachabilityDelegate(DidChangeReachability callback) {
    DidChangeReachabilityDelegate = callback;
}

/// This function is used for The Magic.
void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityHoloKit_SendSetupMessage2Watch(int magicNum, const char **actionTypes, const char **gatherTypes, float gatherTimes[], float coolingDowns[]) {
    WCSession *wcSession = [[HoloKitWatchConnectivity sharedWatchConnectivity] wcSession];
    if (wcSession.activationState != WCSessionActivationStateActivated) {
        NSLog(@"[wc_session]: session is not activated.");
        return;
    }
    
    NSDictionary<NSString *, id> *message = @{ @"Setup": @"3",
                                               @"Magic1-ActionType": [NSString stringWithUTF8String:actionTypes[0]],
                                               @"Magic1-GatherType": [NSString stringWithUTF8String:gatherTypes[0]],
                                               @"Magic1-GatherTime": [NSString stringWithFormat:@"%f", gatherTimes[0]],
                                               @"Magic1-CoolingDown": [NSString stringWithFormat:@"%f", coolingDowns[0]],
                                               
                                               @"Magic2-ActionType": [NSString stringWithUTF8String:actionTypes[1]],
                                               @"Magic2-GatherType": [NSString stringWithUTF8String:gatherTypes[1]],
                                               @"Magic2-GatherTime": [NSString stringWithFormat:@"%f", gatherTimes[1]],
                                               @"Magic2-CoolingDown": [NSString stringWithFormat:@"%f", coolingDowns[1]],
                                               
                                               @"Magic3-ActionType": [NSString stringWithUTF8String:actionTypes[2]],
                                               @"Magic3-GatherType": [NSString stringWithUTF8String:gatherTypes[2]],
                                               @"Magic3-GatherTime": [NSString stringWithFormat:@"%f", gatherTimes[2]],
                                               @"Magic3-CoolingDown": [NSString stringWithFormat:@"%f", coolingDowns[2]]
    };
    
    __block bool success = YES;
    void (^errorHandler)(NSError *error) = ^void(NSError *error) {
        NSLog(@"[wc_session]: Failed to send the watch reset message.");
        success = NO;
    };
    
    // TODO: Should I also pass the replyHandler?
    [wcSession sendMessage:message replyHandler:nil errorHandler:errorHandler];
}
} // extern "C"
