//
//  AppDelegate.m
//  AprilTag
//
//  Created by Edwin Olson on 10/14/13.
//  Copyright (c) 2013 Edwin Olson. All rights reserved.
//


// optimization TODO:
//  faster cosf/sinf/atan2f in line_fit
//  cache textures


#ifdef __ARM_NEON__
#include <arm_neon.h>
#endif

#import "AppDelegate.h"
#include "ShaderUtilities.h"

#include <netinet/in.h>
#include <arpa/inet.h>
#include <math.h>
#include <sys/sysctl.h>

#include "udp_util.h"

#define SHOW_BUTTON_BACKGROUND 0
#define TRANSITION_TIME 0.25

#include "apriltags/tag16h5.h"
#include "apriltags/tag25h9.h"
#include "apriltags/tag36h11.h"
#include "apriltags/tagStandard41h12.h"
#include "apriltags/tagStandard52h13.h"
#include "apriltags/tagCircle21h7.h"
#include "apriltags/tagCircle49h12.h"
#include "apriltags/tagCustom48h12.h"
#include "apriltags/tagCustom48h12.h"

#include "common/homography.h"


@interface ImageData : NSObject
{
    //    size_t width, height;
    //    void *data;
}
@property (readwrite) size_t width, height;
@property (readwrite) void* data;
@end

@implementation ImageData : NSObject
@end

@interface DieDelegate : NSObject <UIAlertViewDelegate>
@end

@implementation DieDelegate
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex
{
    exit(-1);
}
@end

/////////////////////////////////////////////////////////////
// Marshalling code (big endian)
static void encode_u32(uint8_t *buf, uint32_t maxlen, uint32_t *pos, uint32_t v)
{
    if ((*pos) + 4 <= maxlen) {
        buf[(*pos)+0] = (v>>24)&0xff;
        buf[(*pos)+1] = (v>>16)&0xff;
        buf[(*pos)+2] = (v>>8)&0xff;
        buf[(*pos)+3] = (v>>0)&0xff;
    }
    *pos = (*pos) + 4;
}

union float_uint32_t
{
    float f;
    uint32_t i;
};

static void encode_f32(uint8_t *buf, uint32_t maxlen, uint32_t *pos, float v)
{
    union float_uint32_t fu;
    fu.f = v;
    
    encode_u32(buf, maxlen, pos, fu.i);
}

/////////////////////////////////////////////////////////////
//
/*
 @interface TagFamilyHandler : NSObject <UIPickerViewDelegate>
 {
 AppDelegate *app;
 }
 @end
 
 @implementation TagFamilyHandler
 
 - (id) initWithApp:(AppDelegate*)_app
 {
 self = [super init];
 
 app = _app;
 
 
 return self;
 }
 
 - (void)pickerView:(UIPickerView *)pickerView didSelectRow: (NSInteger)row inComponent:(NSInteger)component {
 april_tag_family_t *family;
 zarray_get(app.tagFamilies, (int) row, &family);
 
 app.detector->tag_family = family;
 }
 
 - (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
 
 return zarray_size(app.tagFamilies);
 }
 
 - (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
 return 1;
 }
 
 - (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
 
 april_tag_family_t *family;
 zarray_get(app.tagFamilies, (int) row, &family);
 
 NSString *title = [NSString stringWithFormat:@"%dh%d", family->d*family->d, family->h];
 
 return title;
 }
 
 // tell the picker the width of each row for a given component
 - (CGFloat)pickerView:(UIPickerView *)pickerView widthForComponent:(NSInteger)component {
 
 return 300;
 }
 @end
 */
/////////////////////////////////////////////////////////////
// BlockWrappers are permanently-retained Objective-C blocks
// that recive an "id" as an argument.
typedef void (^blockwrapper_callback_t)(id);

// we hang on to the block wrapper objects so ARC doesn't remove them.
static NSMutableArray *blockWrappers;

@interface BlockWrapper : NSObject
{
    blockwrapper_callback_t block;
}
@end

@implementation BlockWrapper

- (BlockWrapper*) initWithBlock:(blockwrapper_callback_t) _block
{
    self = [super init];
    block = _block;
    
    if (blockWrappers == NULL)
        blockWrappers = [[NSMutableArray alloc] init];
    
    [blockWrappers addObject:self];
    return self;
}

- (void) invokeNil
{
    block(nil);
}

- (IBAction) invoke:(id) sender
{
    block(sender);
}

@end

/////////////////////////////////////////////////////////////

@implementation AppDelegate

- (void) setWorkingDirectory
{
    NSFileManager *filemgr =[NSFileManager defaultManager];
    
    NSArray *dirPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    
    NSString *docsDir = [dirPaths objectAtIndex:0];
    
    if ([filemgr changeCurrentDirectoryPath: docsDir] == NO)
        printf("uh oh\n");
}

- (void) restorePrefs
{
    unsigned int ncores;
    if (1) {
        size_t len;
        len = sizeof(ncores);
        sysctlbyname("hw.ncpu", &ncores, &len, NULL, 0);
    }
    
    // on single core devices, multiple threads seems to be a near-disaster.
    
    printf("Detected %d CPUs\n", ncores);
    
    [cameraWrapper setInput:0];
    hammingLimit = 0;
//    _detector->refine_decode = 0;
    _detector->quad_decimate = 2;
    _detector->quad_sigma = 0;
    
    _detector->nthreads = ncores;
    _detector->debug = 0;
    
    apriltag_detector_clear_families(_detector);
    apriltag_family_t *default_family;
    zarray_get(_tagFamilies, 0, &default_family);
    pthread_mutex_lock(&detector_mutex);
    apriltag_detector_add_family(_detector, default_family);
    pthread_mutex_unlock(&detector_mutex);
    
    // can listen on remote machine doing something like:
    // nc -lu 7709 | hexdump -C
    
    sock = udp_socket_create();
    udp_port = 7709;
    udp_address = strdup("192.168.1.1");
    udp_on = 0;
    
    show_welcome = 1;
    
    FILE *f = fopen("prefs.txt", "r");
    if (f == NULL)
        return;
    
    char key[1024], value[1024];
    while (fgets(key, sizeof(key), f)) {
        size_t keylen = strlen(key);
        if (key[keylen-1]=='\n')
            key[keylen-1] = 0;
        
        fgets(value, sizeof(value), f);
        size_t valuelen = strlen(value);
        if (value[valuelen-1]=='\n')
            value[valuelen-1] = 0;
        
        printf("pref %s=%s\n", key, value);
        
        // not allowed to reference any UI devices
        if (!strcmp(key, "cameraIndex"))
            [cameraWrapper setInput:atoi(value)];
        if (!strcmp(key, "focus")) {
            cameraWrapper.focus = atoi(value) / 100.0;
            [cameraWrapper setInput:-1];
        }
        if (!strcmp(key, "hammingLimit")) {
            hammingLimit = atoi(value);
            if (hammingLimit > 1)
                hammingLimit = 1;
        }
        
        if (!strcmp(key, "quad_decimate"))
            _detector->quad_decimate = atof(value);
//        if (!strcmp(key, "refine_decode"))
//            _detector->refine_decode = atoi(value);
//        if (!strcmp(key, "refine_pose"))
//            _detector->refine_pose = atoi(value);
        if (!strcmp(key, "nthreads"))
            _detector->nthreads = atoi(value);
        if (!strcmp(key, "udp_transmit_on"))
            udp_on = atoi(value);
        if (!strcmp(key, "udp_transmit_addr"))
            udp_address = strdup(value);
        if (!strcmp(key, "show_welcome"))
            show_welcome = atoi(value);
        if (!strcmp(key, "tag_families")) {
            apriltag_detector_clear_families(_detector);

            for (int i = 0; i < valuelen; i++) {
                apriltag_family_t *fam;
                int idx = value[i] - '0';
                if (idx < 0 || idx >= zarray_size(_tagFamilies))
                    continue;
                
                zarray_get(_tagFamilies, idx, &fam);
                apriltag_detector_add_family_bits(_detector, fam, hammingLimit);
            }
        }
    }
    
    fclose(f);
    
}

// commit UI choices back to state and save.
- (void) savePrefs
{
    FILE *f = fopen("prefs.txt", "w");
    fprintf(f, "cameraIndex\n%d\n", (int) [cameraWrapper getIndex]);
    fprintf(f, "focus\n%d\n", (int) (100*cameraWrapper.focus));
    fprintf(f, "hammingLimit\n%d\n", hammingLimit);
    fprintf(f, "quad_decimate\n%.1f\n", _detector->quad_decimate);
//    fprintf(f, "refine_pose\n%d\n", _detector->refine_pose);
//    fprintf(f, "refine_decode\n%d\n", _detector->refine_decode);

    //   fprintf(f, "min_mag\n%d\n", _detector->min_mag);
    fprintf(f, "show_welcome\n%d\n", show_welcome);
    fprintf(f, "udp_transmit_on\n%d\n", udp_on);
    fprintf(f, "udp_transmit_addr\n%s\n", udp_address);
    //    fprintf(f, "tag_family\n%d\n", (int) [tagFamilyPicker selectedRowInComponent:0 ]);
    fprintf(f, "tag_families\n");
    for (int i = 0; i < zarray_size(_detector->tag_families); i++) {
        apriltag_family_t *fam;
        zarray_get(_detector->tag_families, i, &fam);
        int idx = zarray_index_of(_tagFamilies, &fam);
        if (idx < 0) {
            printf("Huh, tag family wasn't in our master list.\n");
            continue;
        }
        fprintf(f, "%c", '0'+zarray_index_of(_tagFamilies, &fam));
    }
    fprintf(f, "\n");
    
    fclose(f);
}

- (void) didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    printf("got low memory warning\n");
}


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    [self setWorkingDirectory];
    
    // don't go to sleep while we're running.
    [application setIdleTimerDisabled:YES];
    
    immortals = [[NSMutableArray alloc] init];
    
    pthread_mutex_init(&detector_mutex, NULL);
    pthread_mutex_init(&pf_mutex, NULL);
    
    processed_frames = zarray_create(sizeof(struct processed_frame*));
    
    camera_wrapper_callback_t cb = ^(size_t width, size_t height, void *data) {
        ImageData *imdata = [[ImageData alloc] init];
        imdata.width = width;
        imdata.height = height;
        imdata.data = data;
        
        [self performSelectorOnMainThread:@selector(processImage:) withObject:imdata waitUntilDone:true];
//        [self processImageWithWidth:width andHeight:height andData:data];
    };
    
    cameraWrapper = [[CameraWrapper alloc] initWithCallbackBlock:cb];
    
    apriltag_family_t **objs = (apriltag_family_t*[]) { tag36h11_create(), tag25h9_create(), tag16h5_create(),
        tagStandard41h12_create(), tagStandard52h13_create(),
        tagCircle21h7_create(), tagCircle49h12_create(),
        tagCustom48h12_create(), NULL };
    
    _tagFamilies = zarray_create(sizeof(apriltag_family_t*));
    for (int i = 0; objs[i] != NULL; i++)
        zarray_add(_tagFamilies, &objs[i]);
    
    /////////////////////////////////////////
    // Set up detector
    _detector = apriltag_detector_create(NULL);
    
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    
    context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
    glView = [[GLKView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    glView.context = context;
    glView.delegate = self;
    
    if (1) {
        // remember: these coordinates are relative to the UIButton which contains them.
        frameRateLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 400, 30)];
        [frameRateLabel setTextColor:[UIColor yellowColor]];
        [frameRateLabel setText: @"000.00 ms"];
        [frameRateLabel setUserInteractionEnabled:NO];
        
        detectionsLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 25, 200, 30)];
        [detectionsLabel setTextColor:[UIColor yellowColor]];
        [detectionsLabel setText: @"00 tags"];
        [detectionsLabel setUserInteractionEnabled:NO];
        
        udpLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 50, 200, 30)];
        [udpLabel setTextColor:[UIColor yellowColor]];
        [udpLabel setText: @""];
        [udpLabel setUserInteractionEnabled:NO];
        
        UIButton *button = [[UIButton alloc] initWithFrame:CGRectMake(10, 30, 200, MIN_TAP_SIZE)];
        [button addSubview:frameRateLabel];
        [button addSubview:detectionsLabel];
        [button addSubview:udpLabel];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            [cameraWrapper stop];
            
            [UIView transitionFromView:glView toView:paramView duration:TRANSITION_TIME options:UIViewAnimationOptionTransitionFlipFromTop completion:nil];
        };
        
        [glView addSubview:button];
        
        [button addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventTouchDown];
        if (SHOW_BUTTON_BACKGROUND)
            [button setBackgroundColor:[UIColor grayColor]];
        
        /*
         if (button.frame.size.width < MIN_TAP_SIZE)
         button.frame = CGRectMake(button.frame.origin.x, button.frame.origin.y, MIN_TAP_SIZE, button.frame.size.height);
         if (button.frame.size.height < MIN_TAP_SIZE)
         button.frame = CGRectMake(button.frame.origin.x, button.frame.origin.y, button.frame.size.width, MIN_TAP_SIZE);
         */
        
    }
    
    if (1) {
        recordLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
        [recordLabel setTextColor:[UIColor redColor]];
        [recordLabel setText: @""];
        [recordLabel setUserInteractionEnabled:NO];
        
        
        UIButton *button = [[UIButton alloc] initWithFrame:CGRectMake(glView.frame.size.width-100, glView.frame.size.height - MIN_TAP_SIZE, 100, MIN_TAP_SIZE)];
        [button addSubview:recordLabel];
        if (SHOW_BUTTON_BACKGROUND)
            [button setBackgroundColor:[UIColor grayColor]];
        [self updateRecordLabel:@"o"];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            recordOne = 1;
        };
        [button addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventTouchDown];
        
        [glView addSubview:button];
    }
    
    
    if (0) {
        blockwrapper_callback_t cb = ^(UITapGestureRecognizer *recognizer){
            CGPoint point = [recognizer locationOfTouch:0 inView:glView];
            
            point.x /= glView.frame.size.width;
            point.y /= glView.frame.size.height;
            
            float tmp = point.x;
            point.x = point.y;
            point.y = tmp;
            
            int flipx = [cameraWrapper shouldFlipX];
            int flipy = [cameraWrapper shouldFlipY];
            
            if (flipy)
                point.y = 1 - point.y;
            if (flipx)
                point.x = 1 - point.x;
            
            AVCaptureDeviceInput *videoIn = [cameraWrapper getAVCaptureDeviceInput];
            if (videoIn && [[videoIn device] lockForConfiguration: nil]) {
                if ([[videoIn device] isFocusModeSupported:AVCaptureFocusModeAutoFocus])
                    [[videoIn device] setFocusMode:AVCaptureFocusModeAutoFocus];
                else
                    printf("Desired focus mode not supported\n");
                
                if ([[videoIn device] isFocusPointOfInterestSupported])
                    [[videoIn device] setFocusPointOfInterest: point];
                else
                    printf("focus point not supported\n");
                
                
                /*                   if ([[videoIn device] isFocusModeSupported:AVCaptureFocusModeLocked])
                 [[videoIn device] setFocusMode:AVCaptureFocusModeLocked];
                 else
                 printf("Desired focus mode not supported\n");
                 */
                [[videoIn device] unlockForConfiguration];
            }
            
            // focus point is always between (0,0) and (1,1), relative to a landscape orientation
            // with home button on right. (0,0) is top left, (1,1) is bottom right.
            printf("Focusing %f, %f\n", point.x, point.y);
        };
        
        UITapGestureRecognizer *singleFingerTap = [[UITapGestureRecognizer alloc] initWithTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:)];
        
        [glView addGestureRecognizer:singleFingerTap];
    }
    
    /////////////////////////////
    // restore preferences NOW, so that GUI is initialized with correct values.
    [self restorePrefs];
    
    if (show_welcome) {
        UIAlertView *alert = [[UIAlertView alloc]
                              initWithTitle:@"Welcome!"
                              message:@"To get started with this application, you'll need to get some AprilTags. Download and print these for free at:\n\n http://april.eecs.umich.edu/apriltag\n\nAlso, tap the status label in the upper left to access settings. \n\n" delegate:nil cancelButtonTitle:nil otherButtonTitles:@"Okay", nil];
        
        [alert show];
    }
    
    /////////////////////////////
    paramView = [[UIScrollView alloc] init];
    [paramView setScrollEnabled:YES];
    [paramView setShowsVerticalScrollIndicator:YES];
    
    
    //    UIWebView *view = [[UIWebView alloc] initWithFrame:CGRectMake(0, 0, 320, 480)];
    //    [view loadHTMLString:@"<h2>Hi!</h2>" baseURL: nil];
    //   [view show];
    
    int ypad = 25;
    int sizex = glView.frame.size.width, sizey = 50;
    int labelx = 10, controlx = 250;
    int y = 30;
    
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, sizex, MIN_TAP_SIZE)];
        [label setText:@" Done"];
        [label setTextColor:[UIColor blueColor]];
        [label setUserInteractionEnabled:NO];
        if (SHOW_BUTTON_BACKGROUND)
            [label setBackgroundColor:[UIColor grayColor]];
        
        UIButton *button = [[UIButton alloc] initWithFrame:CGRectMake(0, y, sizex-labelx, MIN_TAP_SIZE)];
        [button addSubview:label];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            // time to save user preferences!
            [self savePrefs];
            
            [UIView transitionFromView:paramView toView:glView duration:TRANSITION_TIME options:UIViewAnimationOptionTransitionFlipFromTop completion:nil];
            [cameraWrapper start];
        };
        
        [button addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventTouchDown ];
        [paramView addSubview:button];
        
        y += button.frame.size.height + ypad;
    }
    
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, 30)];
        [label setText:[NSString stringWithFormat:@"Input (%s)", [[cameraWrapper getName] UTF8String]]];
        [paramView addSubview:label];
        
        UIStepper *sw = [[UIStepper alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
        [sw setMinimumValue:0];
        [sw setMaximumValue: [cameraWrapper getCameraCount]-1];
        [sw setValue: [cameraWrapper getIndex]];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            [cameraWrapper setInput: sw.value];
            [label setText:[NSString stringWithFormat:@"Input (%s)", [[cameraWrapper getName] UTF8String]]];
        };
        
        [sw addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        [sw sizeToFit];
        [paramView addSubview:sw];
        
        y += fmax(label.frame.size.height, sw.frame.size.height) + ypad;
    }
    
    /*
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:@"Refine Tag Positions"];
        [label sizeToFit];
        [paramView addSubview:label];
        
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
        sw.on = _detector->refine_pose;
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            _detector->refine_pose = sw.on;
        };
        
        [sw addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        [sw sizeToFit];
        [paramView addSubview:sw];
        
        y += fmax(label.frame.size.height, sw.frame.size.height) + ypad;
    }
 */
    
    /*
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:@"Refine Tag Decodes"];
        [label sizeToFit];
        [paramView addSubview:label];
        
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
        sw.on = _detector->refine_decode;
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            _detector->refine_decode = sw.on;
        };
        
        [sw addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        [sw sizeToFit];
        [paramView addSubview:sw];
        
        y += fmax(label.frame.size.height, sw.frame.size.height) + ypad;
    }
    */
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:[NSString stringWithFormat:@"Decimation (%.1f)", _detector->quad_decimate]];
        [label sizeToFit];
        [paramView addSubview:label];
        
        UIStepper *sw = [[UIStepper alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
        static float decimate_settings[] = { 1, 1.5, 2.0, 3.0, 4.0 };
        int ndecimate_settings = sizeof(decimate_settings) / sizeof(float);
        [sw setMinimumValue:0];
        [sw setMaximumValue:ndecimate_settings-1];
        
        [sw setValue:2];
        for (int i = 0; i < ndecimate_settings; i++) {
            if (_detector->quad_decimate == decimate_settings[i])
                [sw setValue:i];
        }
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            int idx = ((UIStepper*) sender).value;
            _detector->quad_decimate = decimate_settings[idx];
            [label setText:[NSString stringWithFormat:@"Decimation (%.1f)", _detector->quad_decimate]];
        };
        
        [sw addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        
        [sw sizeToFit];
        [paramView addSubview:sw];
        
        y += fmax(label.frame.size.height, sw.frame.size.height) + ypad;
    }
    
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:[NSString stringWithFormat:@"Hamming Limit (%d)", hammingLimit]];
        [label sizeToFit];
        [paramView addSubview:label];
        
        UIStepper *sw = [[UIStepper alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
        [sw setMinimumValue:0];
        [sw setMaximumValue:1];
        [sw setValue:hammingLimit];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            hammingLimit = ((UIStepper*) sender).value;
            [label setText:[NSString stringWithFormat:@"Hamming Limit (%d)", hammingLimit]];
        };
        
        [sw addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        
        [sw sizeToFit];
        [paramView addSubview:sw];
        
        y += fmax(label.frame.size.height, sw.frame.size.height) + ypad;
        
    }
    
    
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:[NSString stringWithFormat:@"Camera Focus (%.2f)", [cameraWrapper focus]]];
        [paramView addSubview:label];
        y += label.frame.size.height;
        
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [slider setMaximumValue:1];
        [slider setMinimumValue:0];
        [slider setValue: [cameraWrapper focus]];
        [slider setEnabled:TRUE];
        [slider setContinuous:TRUE];
        [paramView addSubview:slider];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            cameraWrapper.focus = ((UISlider*) sender).value;
            [cameraWrapper setInput:-1];
            [label setText:[NSString stringWithFormat:@"Camera Focus (%.2f)", cameraWrapper.focus]];
        };
        
        [slider addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        
        y += slider.frame.size.height + ypad;
    }
    
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:@"UDP Transmit Enabled"];
        [label sizeToFit];
        [paramView addSubview:label];
        
        UISwitch *udpOnSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
        udpOnSwitch.on = udp_on;
        [paramView addSubview:udpOnSwitch];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            udp_on = [udpOnSwitch isOn];
        };
        
        [udpOnSwitch addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        y += fmax(label.frame.size.height, udpOnSwitch.frame.size.height);
        
        //////////////
        label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:@"UDP Transmit Addr (port 7709)"];
        [label sizeToFit];
        [paramView addSubview:label];
        
        y += label.frame.size.height;
        
        UITextField *udpAddressTextView = [[UITextField alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        udpAddressTextView.text = [NSString stringWithFormat:@"%s", udp_address];
        [udpAddressTextView setKeyboardType:UIKeyboardTypeNumbersAndPunctuation];
        [udpAddressTextView setReturnKeyType:UIReturnKeyDone];
        udpAddressTextView.borderStyle = UITextBorderStyleRoundedRect;
        
        cb = ^(UITextField *sender){
            free(udp_address);
            udp_address = strdup([[udpAddressTextView text] UTF8String]);
        };
        
        [udpAddressTextView addTarget:[[BlockWrapper alloc] initWithBlock:cb]
                               action:@selector(invoke:)
                     forControlEvents:UIControlEventAllEditingEvents];
        
        [paramView addSubview:udpAddressTextView];
        
        y += udpAddressTextView.frame.size.height + ypad;
    }
    
    /*    if (1) {
     UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
     [label setText:@"Tag Family"];
     [label sizeToFit];
     [paramView addSubview:label];
     
     TagFamilyHandler *handler = [[TagFamilyHandler alloc] initWithApp:self];
     [immortals addObject:handler];
     
     tagFamilyPicker = [[UIPickerView alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
     tagFamilyPicker.delegate = handler;
     tagFamilyPicker.showsSelectionIndicator = YES;
     [tagFamilyPicker selectRow:zarray_index_of(_tagFamilies, &_detector->tag_family) inComponent:0 animated:NO];
     //  [tagFamilyPicker sizeToFit];
     y += tagFamilyPicker.frame.size.height + ypad;
     //     tagFamilyPicker.backgroundColor = [UIColor lightGrayColor];
     [paramView addSubview:tagFamilyPicker];
     }
     */
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:@"Enabled tag families"];
        [label sizeToFit];
        [paramView addSubview:label];
        y += label.frame.size.height;
        /*
        UILabel *getTagsLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, sizex-labelx, MIN_TAP_SIZE)];
        [getTagsLabel setTextColor:[UIColor blueColor]];
        [getTagsLabel setText: @"Go to tag download page"];
        [getTagsLabel setUserInteractionEnabled:NO];
        
        UIButton *button = [[UIButton alloc] initWithFrame:CGRectMake(labelx+20, y, sizex-labelx, MIN_TAP_SIZE)];
        [button addSubview:getTagsLabel];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"http://april.eecs.umich.edu/apriltag"]];
        };
        
        
        [button addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventTouchDown];
        if (SHOW_BUTTON_BACKGROUND)
            [button setBackgroundColor:[UIColor grayColor]];
        
        [paramView addSubview:button];
        
        y += button.frame.size.height;
        */
        
        for (int i = 0; i < zarray_size(_tagFamilies); i++) {
            apriltag_family_t *fam;
            zarray_get(_tagFamilies, i, &fam);
            
            UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx+20, y, sizex-labelx, sizey)];
            [label setText: [NSString stringWithFormat:@"%s", fam->name]];
            [label sizeToFit];
            [paramView addSubview:label];
            
            UISwitch *familySwitch = [[UISwitch alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
            familySwitch.on = zarray_contains(_detector->tag_families, &fam);
            
            [paramView addSubview:familySwitch];
            
            blockwrapper_callback_t cb = ^(UIControl *sender){
                pthread_mutex_lock(&detector_mutex);
                if (familySwitch.isOn) {
                    apriltag_detector_add_family_bits(_detector, fam, hammingLimit);
//                    apriltag_detector_add_family(_detector, fam);
                } else {
                    apriltag_detector_remove_family(_detector, fam);
                }
                pthread_mutex_unlock(&detector_mutex);
            };
            
            [familySwitch addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
            y += fmax(label.frame.size.height, familySwitch.frame.size.height);
        }
        
        y+= ypad;
    }
    
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:[NSString stringWithFormat:@"Num Threads (%d)", _detector->nthreads]];
        [label sizeToFit];
        [paramView addSubview:label];
        
        UIStepper *sw = [[UIStepper alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
        [sw setMinimumValue:1];
        [sw setMaximumValue:8];
        [sw setValue:_detector->nthreads];
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            _detector->nthreads = ((UIStepper*) sender).value;
            [label setText:[NSString stringWithFormat:@"Num Threads (%d)", _detector->nthreads]];
        };
        
        [sw addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        
        [sw sizeToFit];
        [paramView addSubview:sw];
        
        y += fmax(label.frame.size.height, sw.frame.size.height) + ypad;
    }
    
    if (1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(labelx, y, sizex-labelx, sizey)];
        [label setText:@"Show welcome"];
        [label sizeToFit];
        [paramView addSubview:label];
        
        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(controlx, y, sizex-controlx, sizey)];
        sw.on = show_welcome;
        
        blockwrapper_callback_t cb = ^(UIControl *sender){
            show_welcome = sw.on;
        };
        
        [sw addTarget:[[BlockWrapper alloc] initWithBlock:cb] action:@selector(invoke:) forControlEvents:UIControlEventValueChanged ];
        [sw sizeToFit];
        [paramView addSubview:sw];
        
        y += fmax(label.frame.size.height, sw.frame.size.height) + ypad;
    }
    
    
    
    paramView.frame = CGRectMake(0, 0, self.view.frame.size.width, self.view.frame.size.height);
    //    [paramView sizeToFit];
    printf("%f %f %d\n", paramView.frame.size.height, self.window.frame.size.height, y);
    
    
    [paramView setContentSize:CGSizeMake(paramView.frame.size.width, y)];
    self.window.rootViewController = self;
    
    self.view = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.window.frame.size.width, self.window.frame.size.height)];
    [self.view addSubview:glView];
    
    self.window.backgroundColor = [UIColor whiteColor];
    [self.window makeKeyAndVisible];
    
    
    /////////////////////////////////////////
    // Set up video capture
    [cameraWrapper start];
    return YES;
}



- (void)applicationWillResignActive:(UIApplication *)application
{
    // Sent when the application is about to move from active to inactive state. This can occur for certain types of temporary interruptions (such as an incoming phone call or SMS message) or when the user quits the application and it begins the transition to the background state.
    // Use this method to pause ongoing tasks, disable timers, and throttle down OpenGL ES frame rates. Games should use this method to pause the game.
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
    // Use this method to release shared resources, save user data, invalidate timers, and store enough application state information to restore your application to its current state in case it is terminated later.
    // If your application supports background execution, this method is called instead of applicationWillTerminate: when the user quits.
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    // Called as part of the transition from the background to the inactive state; here you can undo many of the changes made on entering the background.
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    // Restart any tasks that were paused (or not yet started) while the application was inactive. If the application was previously in the background, optionally refresh the user interface.
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    // Called when the application is about to terminate. Save data if appropriate. See also applicationDidEnterBackground:.
}

- (UIInterfaceOrientationMask) supportedInterfaceOrientations
{
    return UIInterfaceOrientationMaskPortrait;
}

- (void) willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration
{
    orientation = toInterfaceOrientation;
    printf("will rotate %d\n", (int) toInterfaceOrientation);
    
    [glView setNeedsLayout];
    [paramView setNeedsLayout];
}


#pragma mark - GLKViewDelegate

- (void) glInit
{
    texture_pm_program = [[GLESProgram alloc] initWithVertexShaderPath:@"texture_pm.vert"
                                                 andFragmentShaderPath:@"texture_pm.frag"
                                                     andAttributeNames:[NSArray arrayWithObjects: @"position", @"textureCoord", nil]
                                                       andUniformNames:[NSArray arrayWithObjects: @"PM", nil]];
    
    
    vcolor_pm_program = [[GLESProgram alloc] initWithVertexShaderPath:@"vcolor_pm.vert"
                                                andFragmentShaderPath:@"vcolor_pm.frag"
                                                    andAttributeNames:[NSArray arrayWithObjects: @"position", @"color", nil]
                                                      andUniformNames:[NSArray arrayWithObjects: @"PM", nil]];
    
    
    ucolor_pm_program = [[GLESProgram alloc] initWithVertexShaderPath:@"ucolor_pm.vert"
                                                andFragmentShaderPath:@"ucolor_pm.frag"
                                                    andAttributeNames:[NSArray arrayWithObjects: @"position", nil]
                                                      andUniformNames:[NSArray arrayWithObjects: @"PM", @"color", nil]];
    
    glEnable(GL_BLEND);
    glGenTextures(1, &texid);
    
    glInitted = 1;
}

- (void)glkView:(GLKView *)__view drawInRect:(CGRect)rect {
    
    if (__view == NULL)
        return;
    
    if (texture_pm_program==nil)
        [self glInit];

    if (!glInitted) {
        printf("no camera data (yet)\n");
        return;
    }
    
    struct processed_frame *pf;
    
    if (1) {
        pthread_mutex_lock(&pf_mutex);
        int sz = zarray_size(processed_frames);
    
        if (sz==0) {
            pthread_mutex_unlock(&pf_mutex);
            return;
        }
    
        // deallocate all but the most recent frame.
        while (zarray_size(processed_frames) > 1) {
            struct processed_frame *thispf;
            zarray_get(processed_frames, 0, &thispf);
            image_u8_destroy(thispf->im);
            apriltag_detections_destroy(thispf->detections);
            free(thispf);
            zarray_remove_index(processed_frames, 0, 0);
        }

        zarray_get(processed_frames, 0, &pf);
        pthread_mutex_unlock(&pf_mutex);
        
        // NB: We'll deallocate this frame the next time this function is called.
    }
    
    int textureWidth = pf->im->width, textureHeight = pf->im->height;
    
     glBindTexture(GL_TEXTURE_2D, texid);
     glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, (GLsizei) pf->im->width, (GLsizei) pf->im->height,
                  0, GL_LUMINANCE, GL_UNSIGNED_BYTE, pf->im->buf);
     glBindTexture(GL_TEXTURE_2D, texid);
    
 //    timeprofile_stamp(tp, "make texture");
    

    glClearColor(0, 0, 0, 0);
    
    glClear(GL_COLOR_BUFFER_BIT);
    
    
    // Set the view port to the entire view
    glViewport(0, 0, (GLsizei) [glView drawableWidth], (GLsizei) [glView drawableHeight]);
    
    //    printf("%d x %d \n", [glView drawableWidth], [glView drawableHeight]);
    /*
     double theta = 0;
     switch (orientation) {
     
     case UIInterfaceOrientationPortrait:
     theta = 0;
     break;
     case UIInterfaceOrientationPortraitUpsideDown:
     theta = M_PI;
     break;
     case UIInterfaceOrientationLandscapeLeft:
     theta = M_PI / 2;
     break;
     case UIInterfaceOrientationLandscapeRight:
     theta = M_PI * 3 / 2;
     break;
     default:
     break;
     }
     */
    GLfloat squareVertices[] = {
        -1.0f, -1.0f,
        1.0f, -1.0f,
        -1.0f,  1.0f,
        1.0f,  1.0f,
    };
    
    GLfloat textureVertices[] = { 0, 0,  1,0,   0, 1,   1, 1 };
    
    double theta = -M_PI / 2;
    
    int flipx = [cameraWrapper shouldFlipX];
    int flipy = [cameraWrapper shouldFlipY];
    
    //    flipx = 0; flipy = 1; theta = M_PI/2;
    
    // with the camera oriented horizontally with the home button on the right, pixel (0,0) is the upper left.
    // Relative
    theta = M_PI/2;
    
    // flipx = 0; flipy = 0; theta = 0;
    
    // compute the projection-model matrix. These will be freed below.
    float fPM[16];
    matd_t *mPMtranspose;
    
    if (1) {
        matd_t *mR = matd_create_data(4, 4, (double[]) {
            cos(theta), -sin(theta), 0, 0,
            sin(theta), cos(theta), 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1});
        
        matd_t *mFlipX = matd_create_data(4, 4, (double[]) {
            flipx ? -1 : 1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1 });
        
        matd_t *mFlipY = matd_create_data(4, 4, (double[]) {
            1, 0, 0, 0,
            0, flipy ? -1 : 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1 });
        
        // make sure aspect ratio is correct. Use the texure dimensions as they would be rotated by mR.
        matd_t *texDim = matd_create_data(4, 1, (double[]) { textureWidth, textureHeight, 0, 1 });
        matd_t *RtexDim = matd_op("M*M", mR, texDim);
        
        double xfactor = [glView drawableWidth]*1.0 / fabs(MATD_EL(RtexDim, 0, 0));
        double yfactor = [glView drawableHeight]*1.0 / fabs(MATD_EL(RtexDim, 1, 0));
        double mfactor = fmax(xfactor, yfactor);
        
        matd_destroy(texDim);
        matd_destroy(RtexDim);
        
        double xscale = 1 * xfactor / mfactor;
        double yscale = 1 * yfactor / mfactor;
        
        matd_t *mScale = matd_create_data(4, 4, (double[]) {
            xscale, 0, 0, 0,
            0, yscale, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1 });
        
        mPMtranspose = matd_op("(M*M*M*M)'",  mR, mFlipX, mFlipY, mScale);
        
        for (int i = 0; i < 16; i++)
            fPM[i] = (float) mPMtranspose->data[i];
        
        matd_destroy(mR);
        matd_destroy(mFlipX);
        matd_destroy(mFlipY);
        matd_destroy(mScale);
    }
    
    //////////////////////////////////////////////////////
    // Draw the image
    if (1) {
        glBindTexture(GL_TEXTURE_2D, texid);
        
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        
        glUseProgram(texture_pm_program.program);
        [texture_pm_program enableVertexAttribute:@"position" withFloats:squareVertices withNumComponents:2];
        [texture_pm_program enableVertexAttribute:@"textureCoord" withFloats:textureVertices withNumComponents:2];
        [texture_pm_program uniformMatrix4f:@"PM" withFloats:fPM];
        
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        
        [texture_pm_program disableVertexAttributes];
        
        glBindTexture(GL_TEXTURE_2D, 0);
        
        // we recycle this texture id; don't delete it.
   //     glDeleteTextures(1, &texid);
    }
    
    int naccepted_tags = 0;
    
    //////////////////////////////////////////////////////
    // Draw the bounding boxes
    if (1) {
        
        int ndet = zarray_size(pf->detections);
        for (int detidx = 0; detidx < ndet; detidx++) {
            apriltag_detection_t *det;
            zarray_get(pf->detections, detidx, &det);
            
            if (det->hamming > hammingLimit)
                continue;
            
            naccepted_tags ++;
            if (1) {
                matd_t *P;
                
                if (1) {
                    // The P matrix parameters aren't very relevant for getting aligned augmented reality since
                    // we explicitly compensate for P when computing the model view matrix below.
                    double f = 1.0 / tan(40*M_PI/180/2); // cotan(fovy/2)
                    double aspect = 1.0*textureWidth/textureHeight; //[glView drawableWidth] / [glView drawableHeight];
                    double near = .1, far = 100;
                    
                    P = matd_create_data(4, 4, (double[]) { f/aspect, 0, 0, 0,
                        0, f, 0, 0,
                        0, 0, (far+near)/(near-far), 2*far*near/(near-far),
                        0, 0, -1, 0 });
                }
                
                // Our tag detection homography maps from tag coordinates (-1,-1 to +1,+1) into image coordinates.
                // What we want to do is to compute a homography which maps from tag coordinates into normalized device
                // coordinates.
                
                // Scaling the homography like this will cause us to produce normalized coordinates (from -1,-1 to +1,+1)
                // in texture space.
                matd_t *HS = matd_create_data(3,3, (double[]) { 2.0/textureWidth, 0, -1, 0, 2.0/textureHeight, -1, 0, 0, 1});
                matd_t *HH = matd_op("M*M", HS, det->H);
                
                // Now, given the projection matrix, what model view matrix would yield the correct overall transformation?
                matd_t *M = homography_to_model_view(HH, MATD_EL(P,0,0), MATD_EL(P,1,1), MATD_EL(P,0,2), MATD_EL(P,1,2), MATD_EL(P,2,2), MATD_EL(P,2,3));
                
                // Insert the transform that we used when displaying the texture.
                matd_t *PMtranspose = matd_op("(M'*M*M)'", mPMtranspose, P, M);
                float fPM[16];
                for (int i = 0; i < 16; i++)
                    fPM[i] = (float) PMtranspose->data[i];
                
   //             double e = 1 - 1.0*det->family->black_border / (2*det->family->black_border + det->family->d);
// XXX!
                double e = 1 - 1.0/ (det->family->total_width);
                
                float verts[] = {-1,-1,  1,-1,  -e,-e,  e,-e,  e,-e,
                    e,e,  1,-1,    1,1,   1,1,
                    -1,1,  e,e,  -e,e,   -e,e,
                    -e,-e,  -1,1,  -1,-1 };
                
                float colors[] = { 1,0,0,1,   1,0,0,1,  1,0,0,1,  1,0,0,1,
                    0,0,1,1,   0,0,1,1,  0,0,1,1,  0,0,1,1,
                    0,0,1,1,   0,0,1,1,  0,0,1,1,  0,0,1,1,
                    0,1,0,1,   0,1,0,1,  0,1,0,1, 0,1,0,1};
                
                glUseProgram(vcolor_pm_program.program);
                [vcolor_pm_program enableVertexAttribute:@"position" withFloats:verts withNumComponents:2];
                [vcolor_pm_program enableVertexAttribute:@"color" withFloats:colors withNumComponents:4];
                [vcolor_pm_program uniformMatrix4f:@"PM" withFloats:fPM];
                
                glDrawArrays(GL_TRIANGLE_STRIP, 0, 16);
                [vcolor_pm_program disableVertexAttributes];
                
                if (0) {
                    // draw a wireframe cube
                    //  float verts[] = (float[]) { -1,-1,-1,1,-1,-1,1,1,-1,-1,1,-1,-1,-1,-1,-1,-1,1,1,-1,1,1,-1,-1,1,-1,1,1,1,1,1,1,-1,1,1,1,-1,1,1,-1,1,-1,-1,1,1,-1,-1,1 };
                    float verts[] = (float[]) { -1,-1,0,1,-1,0,1,1,0,-1,1,0,-1,-1,0,-1,-1,2,1,-1,2,1,-1,0,1,-1,2,1,1,2,1,1,0,1,1,2,-1,1,2,-1,1,0,-1,1,2,-1,-1,2 };
                    //  float verts[] = (float[]) { -1,-1,0,1,-1,0,1,1,0,-1,1,0,-1,-1,0,-1,-1,-2,1,-1,-2,1,-1,0,1,-1,-2,1,1,-2,1,1,0,1,1,-2,-1,1,-2,-1,1,0,-1,1,-2,-1,-1,-2 };
                    
                    float color[] = (float[]) { 0, 1, 0, 1 }; // RGBA
                    
                    glLineWidth(2.0f);
                    glUseProgram(ucolor_pm_program.program);
                    [ucolor_pm_program enableVertexAttribute:@"position" withFloats:verts withNumComponents:3];
                    [ucolor_pm_program uniformMatrix4f:@"PM" withFloats:fPM];
                    [ucolor_pm_program uniform4f:@"color" withFloats:color];
                    glDrawArrays(GL_LINE_STRIP, 0, sizeof(verts)/(3*sizeof(float)));
                    [ucolor_pm_program disableVertexAttributes];
                    
                }
                
                if (1) {
                    const int CACHE_SIZE = 128;
                    static int64_t cache_id[CACHE_SIZE];
                    static GLuint cache_texid[CACHE_SIZE];
                    
                    int bucket = det->id % CACHE_SIZE;
                    
                    GLuint tex;
                    glEnable(GL_BLEND);

                    // a valid texture cache entry will be marked by having a non-zero texid. (we may leak
                    // the texture with texid=0? ).
                    if (cache_id[bucket] != det->id || !cache_texid[bucket]) {
                        
                        // if there was already a texture here, but it wasn't the one we want, free the old one!
                        if (cache_texid[bucket]) {
//                            printf("freed texture\n");
                            glDeleteTextures(1, &cache_texid[bucket]);
                        }
                        
                        // render texture
                        UILabel *myLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
                        myLabel.text = [NSString stringWithFormat:@"%d", det->id];
                        myLabel.font = [UIFont fontWithName:@"Helvetica" size:48];
                        myLabel.textColor = [UIColor whiteColor];
                        myLabel.backgroundColor = [UIColor clearColor];
                        [myLabel sizeToFit];
                        
                        int image_width = [myLabel frame].size.width, image_height = [myLabel frame].size.height;
                        
                        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
                        uint32_t *imageData = calloc(1, image_height * image_width * 4 );
                        
                        CGContextRef cgcontext = CGBitmapContextCreate( imageData, image_width, image_height, 8, 4 * image_width, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
                        [myLabel.layer renderInContext:cgcontext];
                        
                        CGContextRelease(cgcontext);
                        
                        glGenTextures(1, &tex);
                        glBindTexture(GL_TEXTURE_2D, tex);
                        
                        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, image_width, image_height, 0, GL_BGRA, GL_UNSIGNED_BYTE, imageData);
                        
                        cache_id[bucket] = det->id;
                        cache_texid[bucket] = tex;
                        
                    } else {
                        tex = cache_texid[bucket];
                        glBindTexture(GL_TEXTURE_2D, tex);
                    }

                    
                    // Set texture parameters
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

                    glBlendFunc (GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

                    // flip texture upside down to account for the fact that we render in an environment where +Y is down,
                    // whereas in OpenGL we have +Y is up.
                    GLfloat textureVertices[] = { 0, 1,  1,1,   0, 0,   1, 0 };
                    
                    GLfloat verts[] = (float[]) {  -e,-e,  e,-e,  -e,e,  e,e };
                    
                    glUseProgram(texture_pm_program.program);
                    [texture_pm_program enableVertexAttribute:@"position" withFloats:verts withNumComponents:2];
                    [texture_pm_program enableVertexAttribute:@"textureCoord" withFloats:textureVertices withNumComponents:2];
                    [texture_pm_program uniformMatrix4f:@"PM" withFloats:fPM];
                    
                    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
                    
                    [texture_pm_program disableVertexAttributes];
                    
                    glBindTexture(GL_TEXTURE_2D, 0);
                    glDisable(GL_BLEND);
                }
                
                matd_destroy(HS);
                matd_destroy(HH);
                matd_destroy(P);
                matd_destroy(M);
                matd_destroy(PMtranspose);
            }
        }
    }
    
    matd_destroy(mPMtranspose);
    
    //////////////////////////////////////////////////////
    // Draw the bounding boxes
    
    if (0) {
        int ndet = zarray_size(pf->detections);
        float *verts = calloc(16*ndet, sizeof(float)); // 4 lines, 2 vertices per line, 2 coordinates per vertex (16 vertices total)
        float *colors = calloc(32*ndet, sizeof(float));
        
        int nverts = 0; // output
        
        for (int detidx = 0; detidx < ndet; detidx++) {
            apriltag_detection_t *det;
            zarray_get(pf->detections, detidx, &det);
            
            if (det->hamming > hammingLimit)
                continue;
            
            naccepted_tags++;
            
            float linecolor[4][4] = { { 1, 0, 0, 1 },
                { 0, 0, 1, 1},
                { 0, 0, 1, 1},
                { 0, 1, 0, 1} };
            
            for (int lineidx = 0; lineidx < 4; lineidx++) {
                int p0 = lineidx;
                int p1 = (lineidx + 1) & 3;
                
                verts[2*nverts + 0] = det->p[p0][0];
                verts[2*nverts + 1] = det->p[p0][1];
                for (int k = 0; k < 4; k++)
                    colors[4*nverts + k] = linecolor[lineidx][k];
                nverts++;
                
                verts[2*nverts + 0] = det->p[p1][0];
                verts[2*nverts + 1] = det->p[p1][1];
                for (int k = 0; k < 4; k++)
                    colors[4*nverts + k] = linecolor[lineidx][k];
                nverts++;
            }
        }
        
        // normalize the coordinates so they match up with the texture coordinates
        for (int vidx = 0; vidx < nverts; vidx++) {
            verts[2*vidx + 0] = 2.0*verts[2*vidx+0] / textureWidth - 1;
            verts[2*vidx + 1] = 2.0*verts[2*vidx+1] / textureHeight - 1;;
        }
        
        glUseProgram(vcolor_pm_program.program);
        [vcolor_pm_program enableVertexAttribute:@"position" withFloats:verts withNumComponents:2];
        [vcolor_pm_program enableVertexAttribute:@"color" withFloats:colors withNumComponents:4];
        [vcolor_pm_program uniformMatrix4f:@"PM" withFloats:fPM];
        
        glDrawArrays(GL_LINES, 0, nverts);
        [vcolor_pm_program disableVertexAttributes];
        
        free(colors);
        free(verts);
    }
    
    uint64_t this_utime = utime_now();
    double dtime = (this_utime - last_utime) / 1000000.0;
    last_utime = this_utime;
    
    [self performSelectorOnMainThread:@selector(executeBlock:) withObject:^{
        [frameRateLabel setText: [NSString stringWithFormat:@"%5.2f FPS (%5.2f ms CPU)", 1.0/dtime, timeprofile_total_utime(_detector->tp) / 1000.0]];
        [detectionsLabel setText: [NSString stringWithFormat:@"%d tags", naccepted_tags]];
        if (udp_on)
            [udpLabel setText:[NSString stringWithFormat:@"UDP on: %s:7709", udp_address]];
        else
            [udpLabel setText:@""];
   
    } waitUntilDone:false];
    
}

- (void) executeBlock:(void (^)(void))code
{
    code();
}

- (void) updateRecordLabel:(NSString*) s
{
    [recordLabel setText:[NSString stringWithFormat:@"%s  ", [s UTF8String]]];
    
    // right alignment within enclosing box
    [recordLabel sizeToFit];
    recordLabel.frame = CGRectMake(recordLabel.superview.frame.size.width - recordLabel.frame.size.width,
                                   recordLabel.frame.origin.y,
                                   recordLabel.frame.size.width,
                                   recordLabel.frame.size.height);
}
#pragma mark Capture

#ifdef __ARM_NEON__
void neon_convert2 (uint8_t * __restrict dest, uint8_t * __restrict src, int numPixels)
{
    int i;
    uint8x8_t rfac = vdup_n_u8 (77);
    uint8x8_t gfac = vdup_n_u8 (151);
    uint8x8_t bfac = vdup_n_u8 (28);
    int n = numPixels / 16;
    
    uint16x8_t  temp1, temp2;
    
    uint8x8x4_t rgb1, rgb2;
    uint8x8_t result1, result2;
    
    // Convert per eight pixels
    for (i=0; i < n; ++i)
    {
        rgb1  = vld4_u8 (src);
        temp1 = vmull_u8 (rgb1.val[0],      bfac);
        temp1 = vmlal_u8 (temp1, rgb1.val[1], gfac);
        temp1 = vmlal_u8 (temp1, rgb1.val[2], rfac);
        result1 = vshrn_n_u16 (temp1, 8);
        vst1_u8 (dest, result1);
        
        src  += 8*4;
        dest += 8;
        
        rgb2  = vld4_u8 (src);
        temp2 = vmull_u8 (rgb2.val[0],      bfac);
        temp2 = vmlal_u8 (temp2, rgb2.val[1], gfac);
        temp2 = vmlal_u8 (temp2, rgb2.val[2], rfac);
        result2 = vshrn_n_u16 (temp2, 8);
        vst1_u8 (dest, result2);
        
        src  += 8*4;
        dest += 8;
    }
}

void neon_convert(uint8_t * __restrict dest, uint8_t * __restrict src, int numPixels)
{
    uint8x8_t rfac = vdup_n_u8 (77);
    uint8x8_t gfac = vdup_n_u8 (151);
    uint8x8_t bfac = vdup_n_u8 (28);
    
    uint8_t *destend = dest + numPixels;
    
    while (dest < destend)
    {
        uint16x8_t  temp;
        uint8x8_t result;
        
        uint8x8x4_t rgb  =  vld4_u8 (src);
        temp = vmull_u8(rgb.val[0], bfac);
        temp = vmlal_u8(temp, rgb.val[1], gfac);
        temp = vmlal_u8(temp, rgb.val[2], rfac);
        result = vshrn_n_u16 (temp, 8);
        vst1_u8 (dest, result);
        
        src  += 8*4;
        dest += 8;
    }
}

void neon_convert3im(image_u8_t *destim, uint8_t * __restrict src)
{
    int width = destim->width, height = destim->height, deststride = destim->stride;
    
    assert(width % 16 == 0);
    
    for (int y = 0; y < height; y++) {
        uint8_t *__restrict dest = &destim->buf[y*deststride];
        
        for (int x = 0; x < width; x += 16, src += 16*4) {
            uint8x16x4_t rgb = vld4q_u8(src);
            uint8x16_t sum = vhaddq_u8(rgb.val[0], rgb.val[2]);
            sum = vhaddq_u8(sum, rgb.val[1]);
            vst1q_u8(&dest[x], sum);
        }
    }
}
void neon_convert3(uint8_t * __restrict dest, uint8_t * __restrict src, int numPixels)
{
    uint8_t *destend = dest + numPixels;
    
    while (dest < destend)
    {
        uint8x16x4_t rgb = vld4q_u8(src);
        uint8x16_t sum = vhaddq_u8(rgb.val[0], rgb.val[2]);
        sum = vhaddq_u8(sum, rgb.val[1]);
        vst1q_u8(dest, sum);
        
        src  += 16*4;
        dest += 16;
    }
}

#endif

- (void) processImage:(ImageData*) data
{
    [self processImageWithWidth:data.width andHeight:data.height andData:data.data];
}


- (void) processImageWithWidth:(size_t) width andHeight:(size_t) height andData:(void *)data
{
    timeprofile_t *tp = timeprofile_create();
    timeprofile_stamp(tp, "begin");
    
    image_u8_t *im = image_u8_create_stride((int) width, (int) height, (int) width);
    uint32_t *pixel = (uint32_t*) data;
    
    timeprofile_stamp(tp, "alloc image_u8");
    
#ifdef __ARM_NEON__
    neon_convert3im(im, (void*)pixel);
    //    neon_convert3((void*) im->buf, (void*)pixel, (int) (width*height));
#else
    int inpos = 0;
    for (int y = 0; y < height; y++) {
        int outpos = im->stride*y;
        
        for (int x = 0; x < width; x++) {
            uint32_t v = pixel[inpos++];
            // NB: alpha is in upper 8 bits. Not *really* sure about order of RGB or BGR, but it doesn't matter.
            uint32_t sum = (v & 0x000000ff);
            sum += (v & 0x0000ff00) >> 7; // green * 2
            sum += (v & 0x00ff0000) >> 16;
            
            im->buf[outpos++] = sum >> 2;
        }
    }
#endif
    
    timeprofile_stamp(tp, "build grayscale");
    
    if (recordOne) {
        char path[1024];
        uint64_t now = utime_now() / 1000;
        sprintf(path, "img_%"PRId64".pnm", now); // file names as # of milliseconds since the epoch.
        printf("writing %s\n", path);
  
        char *f = strdup(path);
        [self performSelectorOnMainThread:@selector(executeBlock:) withObject:^{

            [self updateRecordLabel:[NSString stringWithFormat:@"%s", f]];
            free(f);
        } waitUntilDone:false];
        
        image_u8_write_pnm(im, path);
        recordOne = 0;
        
        timeprofile_stamp(tp, "write debug image");
    }
    
    /*
    if (detections) {
        // deallocate detections
        for (int i = 0; i < zarray_size(detections); i++) {
            apriltag_detection_t *det;
            zarray_get(detections, i, &det);
            
            apriltag_detection_destroy(det);
        }
        zarray_destroy(detections);
    }
    */
    
    pthread_mutex_lock(&detector_mutex);
    zarray_t *detections = apriltag_detector_detect(_detector, im);
    pthread_mutex_unlock(&detector_mutex);

    pthread_mutex_lock(&pf_mutex);
    struct processed_frame *pf = calloc(1, sizeof(struct processed_frame));
    pf->detections = detections;
    pf->im = im;
    zarray_add(processed_frames, &pf);
    pthread_mutex_unlock(&pf_mutex);
    
    timeprofile_stamp(tp, "detect");
    
    // with minimum possible latency, transmit!
    if (udp_on) {
        uint64_t utime = utime_now();
        
        int ndets = zarray_size(pf->detections);
        uint32_t packetmax = 24 + 88*ndets;
        uint8_t *packet = malloc(packetmax);
        uint32_t packetpos = 0;
        
        // output the header (24 bytes)
        encode_u32(packet, packetmax, &packetpos, 0x41505249); // "APRI";
        encode_u32(packet, packetmax, &packetpos, 0x4c544147); // "LTAG";
        encode_u32(packet, packetmax, &packetpos, 0x00010002); // protocol version (high 16 bits), sub-version (low 16 bits);
        encode_u32(packet, packetmax, &packetpos, ndets);
        encode_u32(packet, packetmax, &packetpos, (utime >> 32) & 0xffffffff);
        encode_u32(packet, packetmax, &packetpos, utime & 0xffffffff);
        
        // output information for each tag (88 bytes each)
        for (int detidx = 0; detidx < ndets; detidx++) {
            apriltag_detection_t *det;
            zarray_get(pf->detections, detidx, &det);
            
            encode_u32(packet, packetmax, &packetpos, det->id);
            encode_u32(packet, packetmax, &packetpos, det->hamming);
            encode_u32(packet, packetmax, &packetpos, det->family->ncodes);  // a pretty good approximation for family name
            
            for (int i = 0; i < 2; i++)
                encode_f32(packet, packetmax, &packetpos, det->c[i]);
            for (int i = 0; i < 4; i++) {
                encode_f32(packet, packetmax, &packetpos, det->p[i][0]);
                encode_f32(packet, packetmax, &packetpos, det->p[i][1]);
            }
            for (int i = 0; i < 9; i++)
                encode_f32(packet, packetmax, &packetpos, det->H->data[i]);
        }
        
        assert(packetmax == packetpos);
        
        int res = udp_send_fd(sock, udp_address, udp_port, packet, packetpos);
        if (res < 0) {
            printf("bind failed %d\n", res);
        }
        
        free(packet);
        timeprofile_stamp(tp, "transmit");
    }
/*
    glBindTexture(GL_TEXTURE_2D, texid);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei) width, (GLsizei) height, 0, GL_BGRA, GL_UNSIGNED_BYTE, pixel);
    glBindTexture(GL_TEXTURE_2D, texid);
    textureWidth = width; // we'll need this info at render time.
    textureHeight = height;
    
    timeprofile_stamp(tp, "make texture");
  */
    [glView display];
    
    timeprofile_stamp(tp, "trigger display");
    
    // debug detections
    for (int i = 0; i < zarray_size(detections); i++) {
        apriltag_detection_t *det;
        zarray_get(detections, i, &det);
        
//        printf("detection %3d: tag%dh%02d_%04d, hamming %d, goodness %15f\n", i, det->family->d*det->family->d, det->family->h, det->id, det->hamming, det->goodness);
    }
    
 //   image_u8_destroy(im);
    timeprofile_stamp(tp, "output/cleanup");
    
    
    timeprofile_display(tp);
    printf("\n");
    timeprofile_display(_detector->tp);
    printf("\n");
    
    
    timeprofile_destroy(tp);
}

@end
