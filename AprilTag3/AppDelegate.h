//
//  AppDelegate.h
//  AprilTag
//
//  Created by Edwin Olson on 10/14/13.
//  Copyright (c) 2013 Edwin Olson. All rights reserved.
//

#import <UIKit/UIKit.h>
#import <GLKit/GLKit.h>
#import <AVFoundation/AVFoundation.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import <OpenGLES/ES2/glext.h>
#import <CoreVideo/CVOpenGLESTextureCache.h>

#import "GLESProgram.h"
#import "CameraWrapper.h"

#include "common/zarray.h"
#include "apriltags/apriltag.h"

#define MIN_TAP_SIZE 44

struct processed_frame
{
    image_u8_t *im;
    zarray_t *detections;
};

@interface AppDelegate : UIViewController <UIApplicationDelegate, GLKViewDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, UIPickerViewDelegate>
{
    CameraWrapper *cameraWrapper;
        
    int glInitted;
    GLKView *glView;
    GLuint texid;
    uint64_t last_utime;
    
    
/*    CVOpenGLESTextureRef texture;
    size_t textureWidth, textureHeight;
    zarray_t *detections;
  */
	EAGLContext* context;
    GLESProgram *ucolor_pm_program, *vcolor_pm_program, *texture_pm_program;
    
    UIScrollView *paramView;
    UIPickerView *tagFamilyPicker;

    int show_welcome;
    
    char *udp_address;
    int udp_port;
    int udp_on;
    int sock; // UDP transmission socket

    UILabel *frameRateLabel, *detectionsLabel, *udpLabel, *recordLabel;
    int recordOne;
    
    int hammingLimit;

    NSMutableArray *immortals; // defeat ARC
    
    UIInterfaceOrientation orientation;
    
    pthread_mutex_t detector_mutex;  // protects apriltag_detector
 
    // Info from last frame
    pthread_mutex_t pf_mutex;  // protects processed_frames

    zarray_t *processed_frames; // struct processed_frame*
 
}
@property (strong, nonatomic) UIWindow *window;
@property zarray_t *tagFamilies;
@property apriltag_detector_t *detector;

@end
