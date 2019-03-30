//
//  CameraWrapper.m
//  AprilTag
//
//  Created by Edwin Olson on 10/24/13.
//  Copyright (c) 2013 Edwin Olson. All rights reserved.
//

#import "CameraWrapper.h"
#include "common/image_types.h"
#include "common/image_u8x4.h"

@implementation CameraWrapper

- (id) initWithCallbackBlock:(camera_wrapper_callback_t) _callback
{
    self = [super init];
    callback = _callback;
    
    devices = [[NSMutableArray alloc] init];
    NSArray *allDevices = [AVCaptureDevice devices];
    
    for (int i = 0; i < [allDevices count]; i++) {
        AVCaptureDevice *device = [allDevices objectAtIndex:i];
        
        if ([device hasMediaType:AVMediaTypeVideo]) {
            [devices addObject:device];
            printf(" device index %d: %s\n", i, [[device localizedName] UTF8String]);
        }
    }
    
    if ([devices count] > 0) {
        session = [[AVCaptureSession alloc] init];

        AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
        [videoOut setAlwaysDiscardsLateVideoFrames:YES];
        [videoOut setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];

        dispatch_queue_t queue = dispatch_queue_create("com.example.MyQueue", NULL);
        // queue = dispatch_get_main_queue();
        
        [videoOut setSampleBufferDelegate:self queue:queue];
        
        assert([session canAddOutput:videoOut]);
        [session addOutput:videoOut];
    } else {
        if (1) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"No cameras" message:@"No cameras were found. Using 'example.pnm' instead." delegate:nil cancelButtonTitle:@"Okay" otherButtonTitles:nil, nil];
            [alert show];
        }
    }
    
    cameraIndex = 0;
    
    return self;
}

- (NSUInteger) getCameraCount
{
    return [devices count] + 1;
}

- (NSUInteger) getIndex
{
    return cameraIndex;
}

- (void) stop
{
    if (cameraIndex < [devices count]) {
        [session stopRunning];
    } else {
        // it's the static image.
        [timer invalidate];
    }
    
    running = NO;
}

- (void) start
{
    if (cameraIndex < [devices count]) {
        [session startRunning];
    } else {
        // use static image
        if (image == NULL) {
            NSString *path = [[NSBundle mainBundle] pathForResource:@"example.pnm" ofType: nil];
            image = image_u8x4_create_from_pnm([path UTF8String]);
        }
        
        double fps = 0.01;
        timer = [[NSTimer alloc] initWithFireDate:[NSDate date] interval:fps target:self selector:@selector(onTimer:) userInfo:nil repeats:YES];
        [[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
            
    }
    running = YES;
}

// can call with deviceidx = -1 to keep same input, but reset focus
- (void) setInput:(int) deviceidx
{
    if (deviceidx >= 0) {
        cameraIndex = deviceidx;
    }
    
    if (cameraIndex >= [self getCameraCount])
        cameraIndex = [self getCameraCount];    
    
    if (videoIn)
        [session removeInput:videoIn];
    
    if (cameraIndex < [devices count]) {
        [session beginConfiguration];
        
        AVCaptureDevice *videoDevice = [devices objectAtIndex:cameraIndex];
        
        AVCaptureDeviceFormat *bestFormat = NULL;
        
        printf("*** setInput(%u) --- all available formats:\n", (int) cameraIndex);
        for (AVCaptureDeviceFormat *fmt in [videoDevice formats]) {
            printf("    %s\n", [[fmt debugDescription] UTF8String]);
            
            if (bestFormat == NULL) {
                bestFormat = fmt;
                break;
            }
        }
        
        
        videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:nil];
    
        if (videoIn) {
            
            if ([[videoIn device] lockForConfiguration: nil]) {
                
                printf("selecting format: %s\n", [[bestFormat debugDescription] UTF8String]);
                //  [videoDevice setActiveFormat:bestFormat];
                
                if ([videoDevice isFocusModeSupported:AVCaptureFocusModeLocked]) {
                    [videoDevice setFocusModeLockedWithLensPosition:_focus completionHandler:nil];
                    printf("set focus %f\n", _focus);
                }
                printf("selected: %s\n", [[[videoDevice activeFormat] debugDescription] UTF8String]);
                
                //    session.sessionPreset = AVCaptureSessionPreset3840x2160;
                [[videoIn device] unlockForConfiguration];
            }
            
            assert([session canAddInput:videoIn]);
            [session addInput:videoIn];
        } else {
            printf("videoIn was null\n");
        }
        
        [session commitConfiguration];
    }
}

- (NSString*) getName
{
    if (cameraIndex < [devices count])
        return [[devices objectAtIndex:cameraIndex] localizedName];
    return @"Example image";
}

- (BOOL) shouldFlipX
{
   return 1;
}

- (BOOL) shouldFlipY
{
    if (cameraIndex == 1) // front facing
        return 1;
    return 0;
}

- (AVCaptureDeviceInput*) getAVCaptureDeviceInput
{
    if (cameraIndex < [devices count])
        return videoIn;
    return nil;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	CVPixelBufferLockBaseAddress( pixelBuffer, 0 );

    uint32_t *pixels = (uint32_t*)CVPixelBufferGetBaseAddress(pixelBuffer);
	size_t width = CVPixelBufferGetWidth(pixelBuffer);
	size_t height = CVPixelBufferGetHeight(pixelBuffer);
    size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
    
    printf("stride %zu\n", stride);
    callback(width, height, pixels);
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
}

- (void) onTimer:(NSTimer *)timer
{
    callback(image->width, image->height, image->buf);
}

@end
