//
//  CameraWrapper.h
//  AprilTag
//
//  Created by Edwin Olson on 10/24/13.
//  Copyright (c) 2013 Edwin Olson. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <UIKit/UIKit.h>
#import <GLKit/GLKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CVOpenGLESTextureCache.h>

#include "common/image_types.h"

typedef void (^camera_wrapper_callback_t)(size_t width, size_t height, void *data);

@interface CameraWrapper : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
{
    NSMutableArray *devices; // only the video devices (AVCaptureDevice*)
    AVCaptureSession *session;
    AVCaptureDeviceInput *videoIn;
    
    NSUInteger cameraIndex;
    int running;
    
    camera_wrapper_callback_t callback;
    
    image_u8x4_t *image;
    
    NSTimer *timer;
    
//    float focus; // used when cameras support fixed focus mode
}

- (id) initWithCallbackBlock:(camera_wrapper_callback_t) _callback;

- (void) stop;
- (void) start;
- (void) setInput:(int) deviceidx;
- (NSUInteger) getCameraCount;
- (NSUInteger) getIndex;
- (BOOL) shouldFlipX;
- (BOOL) shouldFlipY;
- (AVCaptureDeviceInput*) getAVCaptureDeviceInput;
- (NSString*) getName;

@property float focus;

@end
