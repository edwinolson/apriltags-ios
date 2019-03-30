//
//  GLESProgram.m
//  AprilTag
//
//  Created by Edwin Olson on 10/18/13.
//  Copyright (c) 2013 Edwin Olson. All rights reserved.
//

#import "GLESProgram.h"

@implementation GLESProgram

- (const GLchar **)readFile:(NSString *)name
{
    NSString *path;
    const GLchar **source = calloc(2, sizeof(GLchar*));
    
    path = [[NSBundle mainBundle] pathForResource:name ofType: nil];
    source[0] = (GLchar *)[[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] UTF8String];
    
    if (source[0] == nil)
        printf("unable to load %s\n", [name UTF8String]);
        
    return source;
}

- (GLchar**) copyArray:(const GLchar**)array
{
    return NULL;
}

- (id) initWithVertexShaderPath:(NSString*)vertPath
          andFragmentShaderPath:(NSString*)fragPath
              andAttributeNames:(NSArray*)_attributeNames
                andUniformNames:(NSArray*)_uniformNames
{
    char log[1024];
    int logLength;

    self = [super init];
    
    attributeNames = _attributeNames;
    uniformNames = _uniformNames;
    
    const GLchar** vertSrc = [self readFile:vertPath];
    const GLchar** fragSrc = [self readFile:fragPath];

	GLint status = 1;
	_program = glCreateProgram();
    
    GLuint vertShader = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(vertShader, 1, vertSrc, NULL);
    glCompileShader(vertShader);
    glGetShaderiv(vertShader, GL_COMPILE_STATUS, &status);
    if (!status) {
        printf("Failed to compile vertex shader %s\n", [vertPath UTF8String]);
        glGetShaderInfoLog(vertShader, sizeof(log), &logLength, log);
        printf("Log: %s\n", log);
        exit(-1);
    }
    free(vertSrc);
    
    GLuint fragShader = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(fragShader, 1, fragSrc, NULL);
    glCompileShader(fragShader);
    glGetShaderiv(fragShader, GL_COMPILE_STATUS, &status);
    if (!status) {
        printf("Failed to compile fragment shader %s\n", [fragPath UTF8String]);
        glGetShaderInfoLog(fragShader, sizeof(log), &logLength, log);
        printf("Log: %s\n", log);
       exit(-1);
    }
    free(fragSrc);
    
    glAttachShader(_program, vertShader);
    glAttachShader(_program, fragShader);
    
    glLinkProgram(_program);
    glGetProgramiv(_program, GL_LINK_STATUS, &status);
	if (status == 0) {
		printf("Failed to link program %d\n", _program);
        glGetProgramInfoLog(_program, sizeof(log), &logLength, log);
        printf("Log: %s\n", log);
        exit(-1);
	}
    
    NSUInteger nattribs = [attributeNames count];
    
    attributeLocations = calloc(nattribs, sizeof(GLuint));
    
    for (int attribidx = 0; attribidx < nattribs; attribidx++)
        attributeLocations[attribidx] = glGetAttribLocation(_program, [[attributeNames objectAtIndex:attribidx] UTF8String]);

    NSUInteger nuniforms = [uniformNames count];
    
    uniformLocations = calloc(nuniforms, sizeof(GLuint));
    
    for (int uniformidx = 0; uniformidx < nuniforms; uniformidx++)
        uniformLocations[uniformidx] = glGetUniformLocation(_program, [[uniformNames objectAtIndex:uniformidx] UTF8String]);

    glDeleteShader(vertShader);
    glDeleteShader(fragShader);
    
    return self;
}

- (GLuint) getAttributeIndex:(NSString*)name
{
    NSUInteger nattribs = [attributeNames count];

    for (int idx = 0; idx < nattribs; idx++)
        if ([name isEqualToString:[attributeNames objectAtIndex:idx]])
            return idx;
    assert(0);
    return -1;
}

- (GLuint) getUniformIndex:(NSString*)name
{
    NSUInteger nuniforms = [uniformNames count];
    
    for (int idx = 0; idx < nuniforms; idx++)
        if ([name isEqualToString:[uniformNames objectAtIndex:idx]])
            return idx;
    assert(0);
    return -1;
}

- (void) enableVertexAttribute:(NSString*)name withFloats:(float*)v withNumComponents:(int)ncomponents
{
    int idx = [self getAttributeIndex:name];
    glVertexAttribPointer(attributeLocations[idx], ncomponents, GL_FLOAT, 0, 0, v);
	glEnableVertexAttribArray(idx);
}

- (void) enableVertexAttribute:(NSString*)name withInt32s:(uint32_t*)v
{

    assert(0);
}

- (void) uniformMatrix4f:(NSString*)name withFloats:(float*)v
{
    int idx = [self getUniformIndex:name];

    glUniformMatrix4fv(uniformLocations[idx], 1, 0, v);
}

- (void) uniform3f:(NSString*)name withFloats:(float*)v
{
    int idx = [self getUniformIndex:name];
    
    glUniform3fv(uniformLocations[idx], 1, v);
}

- (void) uniform4f:(NSString*)name withFloats:(float*)v
{
    int idx = [self getUniformIndex:name];
    
    glUniform4fv(uniformLocations[idx], 1, v);
}


- (void) disableVertexAttributes
{
    NSUInteger nattribs = [attributeNames count];

    for (int i = 0; i < nattribs; i++)
        glDisableVertexAttribArray(attributeLocations[i]);
}



@end
