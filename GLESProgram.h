//
//  GLESProgram.h
//  AprilTag
//
//  Created by Edwin Olson on 10/18/13.
//  Copyright (c) 2013 Edwin Olson. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <stdint.h>

#include <OpenGLES/ES2/gl.h>
#include <OpenGLES/ES2/glext.h>

@interface GLESProgram : NSObject
{
    NSArray *attributeNames, *uniformNames;
    GLuint *attributeLocations;
    GLuint *uniformLocations;
}
@property(readonly) GLuint program;

- (id) initWithVertexShaderPath:(NSString*)vertPath
          andFragmentShaderPath:(NSString*)fragPath
              andAttributeNames:(NSArray*)attributeNames
                andUniformNames:(NSArray*)uniformNames;

- (void) enableVertexAttribute:(NSString*)name withFloats:(float*)v withNumComponents:(int)ncomponents;
- (void) enableVertexAttribute:(NSString*)name withInt32s:(uint32_t*)v;
- (void) disableVertexAttributes;

- (void) uniformMatrix4f:(NSString*)name withFloats:(float*)v;
- (void) uniform3f:(NSString*)name withFloats:(float*)v;
- (void) uniform4f:(NSString*)name withFloats:(float*)v;

@end
