#import <CoreNFC/CoreNFC.h>
#import "holokit_sdk-Swift.h"
#import "HoloKitOptics.h"
#import "HoloKitProfile.h"

void (*OnNFCSessionCompleted)(bool, float *) = NULL;

@interface NFCSessionController : NSObject

@end

@interface NFCSessionController () <NFCTagReaderSessionDelegate>

@property (nonatomic, strong) NFCTagReaderSession* readerSession;
@property (assign) BOOL success;
@property (assign) int holokitType;
@property (assign) float ipd;
@property (assign) float farClipPlane;

@end

@implementation NFCSessionController

- (instancetype)init {
    self = [super init];
    if (self) {

    }
    return self;
}

+ (id)sharedInstance {
    static dispatch_once_t onceToken = 0;
    static id _sharedObject = nil;
    dispatch_once(&onceToken, ^{
        _sharedObject = [[self alloc] init];
    });
    return _sharedObject;
}

- (void)startReaderSessionWithAlertMessage:(NSString *)alertMessage {
    self.success = NO;
    self.readerSession = [[NFCTagReaderSession alloc] initWithPollingOption:NFCPollingISO14443 delegate:self queue:nil];
    self.readerSession.alertMessage = alertMessage;
    [self.readerSession beginSession];
}

// https://stackoverflow.com/questions/9372815/how-can-i-convert-my-device-token-nsdata-into-an-nsstring
+ (NSString *)stringWithDeviceToken:(NSData *)deviceToken {
    const char *data = [deviceToken bytes];
    NSMutableString *token = [NSMutableString string];

    for (NSUInteger i = 0; i < [deviceToken length]; i++) {
        [token appendFormat:@"%02.2hhx", data[i]];
    }

    return [token copy];
}

+ (NSString *)getSignatureFromRawContent:(NSString *)rawContent {
    NSString *a = [rawContent componentsSeparatedByString:@"s="][1];
    NSString *b = [a componentsSeparatedByString:@"&"][0];
    return b;
}

+ (NSString *)getContentFromRawContent:(NSString *)rawContent {
    NSString *a = [rawContent componentsSeparatedByString:@"c="][1];
    return a;
}

#pragma mark - Delegates

- (void)tagReaderSessionDidBecomeActive:(NFCTagReaderSession *)session {

}

- (void)tagReaderSession:(NFCTagReaderSession *)session didInvalidateWithError:(NSError *)error {
    if (OnNFCSessionCompleted != NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.success) {
                HoloKitModel holokitModel = [HoloKitProfile getHoloKitModel:(HoloKitType)self.holokitType];
                float *cameraDataPtr = [HoloKitOptics getHoloKitCameraDataPtr:holokitModel ipd:self.ipd farClipPlane:self.farClipPlane];
                OnNFCSessionCompleted(self.success, cameraDataPtr);
            } else {
                OnNFCSessionCompleted(self.success, nil);
            }
        });
    }
}

- (void)tagReaderSession:(NFCTagReaderSession *)session didDetectTags:(NSArray<__kindof id<NFCTag>> *)tags {
    if ([tags count] > 1) {
        [session invalidateSessionWithErrorMessage:@"More than one NFC tags were detected"];
        return;
    }
    id<NFCTag> tag = tags[0];
    [session connectToTag:tag completionHandler:^(NSError * _Nullable error) {
        if (error != nil) {
            [session invalidateSessionWithErrorMessage:@"Failed to connect to the NFC tag"];
            return;
        }
        id<NFCISO7816Tag> sTag = [tag asNFCISO7816Tag];
        if (sTag == nil) {
            id<NFCMiFareTag> sTag2 = [tag asNFCMiFareTag];
            if (sTag2 == nil) {
                [session invalidateSessionWithErrorMessage:@"This tag is not compliant to ISO7816 or MiFare"];
                return;
            }
            [self processMiFareTag:sTag2 session:session];
        }
        [self processISO7816Tag:sTag session:session];
    }];
}

- (void)processISO7816Tag:(id<NFCISO7816Tag>)sTag session:(NFCTagReaderSession *)session{
    NSString *uid = [NFCSessionController stringWithDeviceToken:[sTag identifier]];
    uid = [uid uppercaseString];
    uid = [NSString stringWithFormat:@"%@%@", @"0x", uid];
    //NSLog(@"[nfc_session] tag uid %@", uid);
    [sTag queryNDEFStatusWithCompletionHandler:^(NFCNDEFStatus status, NSUInteger capacity, NSError * _Nullable error) {
        if (error != nil) {
            [session invalidateSessionWithErrorMessage:@"Failed to query NDEF status of the tag"];
            return;
        }
        switch (status) {
            case NFCNDEFStatusNotSupported: {
                [session invalidateSessionWithErrorMessage:@"NDEF is not supported on this tag"];
                return;
            }
            case NFCNDEFStatusReadOnly: {
                [session invalidateSessionWithErrorMessage:@"This tag is read only"];
                return;
            }
            case NFCNDEFStatusReadWrite: {
                [sTag readNDEFWithCompletionHandler:^(NFCNDEFMessage * _Nullable message, NSError * _Nullable error) {
                    if (error != nil) {
                        [session invalidateSessionWithErrorMessage:@"Failed to write data to the tag"];
                        return;
                    }
                    if ([message.records count] < 1 || message.records[0].payload == nil) {
                        [session invalidateSessionWithErrorMessage:@"There is no data in this tag"];
                        return;
                    }
                    NSString *rawContent = [[NSString alloc] initWithData:message.records[0].payload encoding:NSUTF8StringEncoding];
                    NSString *signature = [NFCSessionController getSignatureFromRawContent:rawContent];
                    NSString *content = [NFCSessionController getContentFromRawContent:rawContent];
                    if ([content isEqualToString:uid]) {
                        if ([Crypto validateSignatureWithSignature:signature content:content]) {
                            self.success = YES;
                            [session setAlertMessage:@"NFC authentication succeeded"];
                            [session invalidateSession];
                            return;
                        } else {
                            [session invalidateSessionWithErrorMessage:@"NFC authentication failed"];
                            return;
                        }
                    } else {
                        [session invalidateSessionWithErrorMessage:@"NFC authentication failed"];
                        return;
                    }
                }];
                break;
            }
            default: {
                [session invalidateSessionWithErrorMessage:@"Failed to write data to the tag"];
                return;
            }
        }
    }];
}

- (void)processMiFareTag:(id<NFCMiFareTag>)sTag session:(NFCTagReaderSession *)session{
    NSString *uid = [NFCSessionController stringWithDeviceToken:[sTag identifier]];
    uid = [uid uppercaseString];
    uid = [NSString stringWithFormat:@"%@%@", @"0x", uid];
    //NSLog(@"[nfc_session] tag uid %@", uid);
    [sTag queryNDEFStatusWithCompletionHandler:^(NFCNDEFStatus status, NSUInteger capacity, NSError * _Nullable error) {
        if (error != nil) {
            [session invalidateSessionWithErrorMessage:@"Failed to query NDEF status of the tag"];
            return;
        }
        switch (status) {
            case NFCNDEFStatusNotSupported: {
                [session invalidateSessionWithErrorMessage:@"NDEF is not supported on this tag"];
                return;
            }
            case NFCNDEFStatusReadOnly: {
                [session invalidateSessionWithErrorMessage:@"This tag is read only"];
                return;
            }
            case NFCNDEFStatusReadWrite: {
                [sTag readNDEFWithCompletionHandler:^(NFCNDEFMessage * _Nullable message, NSError * _Nullable error) {
                    if (error != nil) {
                        [session invalidateSessionWithErrorMessage:@"Failed to write data to the tag"];
                        return;
                    }
                    if ([message.records count] < 1 || message.records[0].payload == nil) {
                        [session invalidateSessionWithErrorMessage:@"There is no data in this tag"];
                        return;
                    }
                    NSString *rawContent = [[NSString alloc] initWithData:message.records[0].payload encoding:NSUTF8StringEncoding];
                    NSString *signature = [NFCSessionController getSignatureFromRawContent:rawContent];
                    NSString *content = [NFCSessionController getContentFromRawContent:rawContent];
                    if ([content isEqualToString:uid]) {
                        if ([Crypto validateSignatureWithSignature:signature content:content]) {
                            self.success = YES;
                            [session setAlertMessage:@"NFC authentication succeeded"];
                            [session invalidateSession];
                            return;
                        } else {
                            [session invalidateSessionWithErrorMessage:@"NFC authentication failed"];
                            return;
                        }
                    } else {
                        [session invalidateSessionWithErrorMessage:@"NFC authentication failed"];
                        return;
                    }
                }];
                break;
            }
            default: {
                [session invalidateSessionWithErrorMessage:@"Failed to write data to the tag"];
                return;
            }
        }
    }];
}

@end

void HoloKitSDK_StartNFCSession(const char *alertMessage, int holokitType, float ipd, float farClipPlane) {
    NFCSessionController *controller = [NFCSessionController sharedInstance];
    controller.holokitType = holokitType;
    controller.ipd = ipd;
    controller.farClipPlane = farClipPlane;
    if (alertMessage == NULL) {
        [controller startReaderSessionWithAlertMessage:nil];
    } else {
        [controller startReaderSessionWithAlertMessage:[NSString stringWithUTF8String:alertMessage]];
    }
}

void HoloKitSDK_RegisterNFCSessionControllerDelegates(void (*OnNFCSessionCompletedDelegate)(bool, float *)) {
    OnNFCSessionCompleted = OnNFCSessionCompletedDelegate;
}
