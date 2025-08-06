/*
 SyphonMetalServer.m
 Syphon
 
 Copyright 2020-2023 Maxime Touroute & Philippe Chaurand (www.millumin.com),
 bangnoise (Tom Butterworth) & vade (Anton Marini). All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "SyphonMetalServer.h"
#import "SyphonServerRendererMetal.h"
#import "SyphonPrivate.h"
#import "SyphonSubclassing.h"

// Helper function to map Metal pixel format to IOSurface pixel format
OSType iosurfacePixelFormatFromMetal(MTLPixelFormat metalFormat) {
    switch (metalFormat) {
        case MTLPixelFormatRGBA32Float:
            return kCVPixelFormatType_128RGBAFloat;
        case MTLPixelFormatRGBA16Float:
            return kCVPixelFormatType_64RGBAHalf;
        case MTLPixelFormatRGB10A2Unorm:
            return kCVPixelFormatType_30RGB;
        case MTLPixelFormatBGRA8Unorm:
        default:
            return kCVPixelFormatType_32BGRA;
    }
}

// Helper function to get bytes per element for a Metal pixel format
NSUInteger bytesPerElementForMetal(MTLPixelFormat metalFormat) {
    switch (metalFormat) {
        case MTLPixelFormatRGBA32Float:
            return 16; // 4 channels * 4 bytes
        case MTLPixelFormatRGBA16Float:
            return 8;  // 4 channels * 2 bytes
        case MTLPixelFormatRGB10A2Unorm:
            return 4;  // Packed format
        case MTLPixelFormatBGRA8Unorm:
        default:
            return 4;  // 4 channels * 1 byte
    }
}

@implementation SyphonMetalServer
{
    id<MTLTexture> _surfaceTexture;
    id<MTLDevice> _device;
    SyphonServerRendererMetal *_renderer;
    MTLPixelFormat _pixelFormat;
    NSString *_currentFrameMetadata;
    NSMutableDictionary *_extendedServerDescription;
}

// These are redeclared from SyphonServerBase.h
@dynamic name;
@dynamic hasClients;

// Override serverDescription to include metadata
- (NSDictionary<NSString *, id<NSCoding>> *)serverDescription
{
    @synchronized (self) {
        NSMutableDictionary *description = [[super serverDescription] mutableCopy];
        [description addEntriesFromDictionary:_extendedServerDescription];
        return [description copy];
    }
}

#pragma mark - Lifecycle

- (id)initWithName:(NSString *)name device:(id<MTLDevice>)theDevice options:(NSDictionary<NSString *, id> *)options
{
    self = [super initWithName:name options:options];
    if( self )
    {
        _device = theDevice;
        _surfaceTexture = nil;
        
        // Get pixel format from options, default to RGBA32Float for backward compatibility with our implementation
        NSNumber *pixelFormatNumber = options[@"SyphonMetalPixelFormat"];
        if (pixelFormatNumber) {
            _pixelFormat = (MTLPixelFormat)[pixelFormatNumber unsignedIntegerValue];
        } else {
            _pixelFormat = MTLPixelFormatRGBA32Float; // Default to 32-bit float
        }
        
        _renderer = [[SyphonServerRendererMetal alloc] initWithDevice:theDevice colorPixelFormat:_pixelFormat];
        if (!_renderer)
        {
            return nil;
        }
        
        // Initialize metadata storage
        _currentFrameMetadata = nil;
        _extendedServerDescription = [[NSMutableDictionary alloc] init];
    }
    return self;
}

- (id)init
{
    self = [super init];
    if (self)
    {
        self = nil;
    }
    return self;
}

- (void)dealloc
{
    [self destroyResources];
}

- (id<MTLDevice>)device
{
    return _device;
}

- (id<MTLTexture>)prepareToDrawFrameOfSize:(NSSize)size
{
    @synchronized (self) {
        BOOL hasSizeChanged = !NSEqualSizes(CGSizeMake(_surfaceTexture.width, _surfaceTexture.height), size);
        if (hasSizeChanged)
        {
            _surfaceTexture = nil;
        }
        if(_surfaceTexture == nil)
        {
            MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_pixelFormat
                                                                                                  width:size.width
                                                                                                 height:size.height
                                                                                              mipmapped:NO];
            descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            // Pass pixel format options to IOSurface creation
            NSDictionary *surfaceOptions = @{@"SyphonMetalPixelFormat": @(_pixelFormat)};
            IOSurfaceRef surface = [self newSurfaceForWidth:size.width height:size.height options:surfaceOptions];
            if (surface)
            {
                _surfaceTexture = [_device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
                _surfaceTexture.label = @"Syphon Surface Texture";
                CFRelease(surface);
            }
        }
        return _surfaceTexture;
    }
}

- (void)destroyResources
{
    @synchronized (self) {
        _surfaceTexture = nil;
    }
    _device = nil;
    _renderer = nil;
}

- (void)stop
{
    [self destroyResources];
    [super stop];
}


#pragma mark - Public API

- (id<MTLTexture>)newFrameImage
{
    @synchronized (self) {
        return _surfaceTexture;
    }
}

- (void)publishFrameTexture:(id<MTLTexture>)textureToPublish onCommandBuffer:(id<MTLCommandBuffer>)commandBuffer imageRegion:(NSRect)region flipped:(BOOL)isFlipped
{
    
    if(textureToPublish == nil) {
        SYPHONLOG(@"TextureToPublish is nil. Syphon will not publish");
        return;
    }
    
    region = NSIntersectionRect(region, NSMakeRect(0, 0, textureToPublish.width, textureToPublish.height));
    
    id<MTLTexture> destination = [self prepareToDrawFrameOfSize:region.size];
    
    // When possible, use faster blit
    if( !isFlipped && textureToPublish.pixelFormat == destination.pixelFormat
       && textureToPublish.sampleCount == destination.sampleCount
       && !textureToPublish.framebufferOnly)
    {
        id<MTLBlitCommandEncoder> blitCommandEncoder = [commandBuffer blitCommandEncoder];
        blitCommandEncoder.label = @"Syphon Server Optimised Blit commandEncoder";
        [blitCommandEncoder copyFromTexture:textureToPublish
                                sourceSlice:0
                                sourceLevel:0
                               sourceOrigin:MTLOriginMake(region.origin.x, region.origin.y, 0)
                                 sourceSize:MTLSizeMake(region.size.width, region.size.height, 1)
                                  toTexture:destination
                           destinationSlice:0
                           destinationLevel:0
                          destinationOrigin:MTLOriginMake(0, 0, 0)];

        [blitCommandEncoder endEncoding];
    }
    // otherwise, re-draw the frame
    else
    {
        [_renderer renderFromTexture:textureToPublish inTexture:destination region:region onCommandBuffer:commandBuffer flip:isFlipped];
    }
    
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull commandBuffer) {
        [self publish];
    }];
}

// Enhanced method that accepts frame metadata
- (void)publishFrameTexture:(id<MTLTexture>)textureToPublish 
           onCommandBuffer:(id<MTLCommandBuffer>)commandBuffer 
               imageRegion:(NSRect)region 
                   flipped:(BOOL)isFlipped 
             frameMetadata:(NSString *)frameMetadata
{
    // Store the metadata for this frame
    @synchronized (self) {
        _currentFrameMetadata = [frameMetadata copy];
    }
    
    // Publish frame metadata to clients via messaging system
    if (_currentFrameMetadata) {
        [self publishFrameMetadata:_currentFrameMetadata];
    }
    
    // Call the original method
    [self publishFrameTexture:textureToPublish onCommandBuffer:commandBuffer imageRegion:region flipped:isFlipped];
}

// Method to get current frame metadata
- (NSString *)currentFrameMetadata
{
    @synchronized (self) {
        return _currentFrameMetadata;
    }
}

// Method to get extended server description with metadata
- (NSDictionary *)extendedServerDescription
{
    @synchronized (self) {
        NSMutableDictionary *description = [[super serverDescription] mutableCopy];
        [description addEntriesFromDictionary:_extendedServerDescription];
        return [description copy];
    }
}

@end
