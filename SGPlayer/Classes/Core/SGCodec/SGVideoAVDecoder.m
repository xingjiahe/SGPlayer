//
//  SGVideoAVDecoder.m
//  SGPlayer
//
//  Created by Single on 2018/1/26.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGVideoAVDecoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import "SGVideoVirtualFrame.h"
#import "SGVideoAVFrame.h"
#import "SGObjectPool.h"
#import <UIKit/UIKit.h>
#import "SGPlatform.h"

@interface SGVideoAVDecoder ()

{
    VTDecompressionSessionRef _decompressionSession;
    CMFormatDescriptionRef _formatDescription;
}

@property (nonatomic, assign) BOOL shouldFlush;
@property (nonatomic, assign) BOOL shouldConvertNALSize3To4;
@property (nonatomic, assign) OSStatus decodingStatus;
@property (nonatomic, assign) CVPixelBufferRef decodingPixelBuffer;

#if SGPLATFORM_TARGET_OS_IPHONE
@property (nonatomic, assign) UIApplicationState applicationState;
#endif

@end

@implementation SGVideoAVDecoder

- (SGMediaType)mediaType
{
    return SGMediaTypeVideo;
}

#if SGPLATFORM_TARGET_OS_IPHONE

- (instancetype)init
{
    if (self = [super init])
    {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillEnterForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    self.applicationState = [UIApplication sharedApplication].applicationState;
}

- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    self.applicationState = [UIApplication sharedApplication].applicationState;
}

- (void)applicationWillResignActive:(NSNotification *)notification
{
    self.applicationState = [UIApplication sharedApplication].applicationState;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification
{
    self.applicationState = [UIApplication sharedApplication].applicationState;
}

#endif

- (BOOL)close
{
    if (![super close])
    {
        return NO;
    }
    [self destoryDecompressionSession];
    return YES;
}

- (void)doSetup
{
    [super doSetup];
    [self setupDecompressionSession];
}

- (void)doDestory
{
    [super doDestory];
    [self destoryDecompressionSession];
}

- (void)doFlush
{
    [super doFlush];
    [self doDestory];
    [self doSetup];
}

- (NSArray <__kindof SGFrame *> *)doDecode:(SGPacket *)packet
{
#if SGPLATFORM_TARGET_OS_IPHONE
    if (self.applicationState == UIApplicationStateBackground)
    {
        self.shouldFlush = YES;
        SGVideoVirtualFrame * frame = [[SGObjectPool sharePool] objectWithClass:[SGVideoVirtualFrame class]];
        [frame fillWithPacket:packet];
        return @[frame];
    }
#endif
    if (self.shouldFlush)
    {
        self.shouldFlush = NO;
        [self doFlush];
    }
    SGVideoFrame * frame = [self decodeInternal:packet];
    if (frame)
    {
        return @[frame];
    }
    return nil;
}

- (SGVideoFrame *)decodeInternal:(SGPacket *)packet
{
    SGVideoFrame * ret = nil;
    CMSampleTimingInfo timingInfo =
    {
        packet.duration,
        packet.originalTimeStamp,
        packet.decodeTimeStamp,
    };
    CMSampleBufferRef sampleBuffer = [self sampleBufferFromData:packet.corePacket->data size:packet.corePacket->size timingInfo:timingInfo];
    if (!sampleBuffer)
    {
        return nil;
    }
    OSStatus status = VTDecompressionSessionDecodeFrame(_decompressionSession, sampleBuffer, 0, NULL, 0);
    if (status == noErr)
    {
        VTDecompressionSessionWaitForAsynchronousFrames(_decompressionSession);
        status = self.decodingStatus;
        if (status == noErr)
        {
            if (self.decodingPixelBuffer)
            {
                SGVideoAVFrame * frame = [[SGObjectPool sharePool] objectWithClass:[SGVideoAVFrame class]];
                frame.corePixelBuffer = self.decodingPixelBuffer;
                [frame fillWithPacket:packet];
                ret = frame;
                CFRelease(self.decodingPixelBuffer);
                self.decodingPixelBuffer = NULL;
            }
        }
    }
    if (status == kVTInvalidSessionErr)
    {
        [self doFlush];
    }
    CFRelease(sampleBuffer);
    return ret;
}
    
#pragma mark - VideoToolbox

- (BOOL)setupDecompressionSession
{
    if (self.codecpar->codec_id != AV_CODEC_ID_H264)
    {
        return NO;
    }
    uint8_t * extradata = self.codecpar->extradata;
    int extradata_size = self.codecpar->extradata_size;
    if (extradata_size < 7 || extradata == NULL)
    {
        return NO;
    }
    if (extradata[0] == 1)
    {
        if (extradata[4] == 0xFE)
        {
            extradata[4] = 0xFF;
            self.shouldConvertNALSize3To4 = YES;
        }
        _formatDescription = CreateFormatDescription(kCMVideoCodecType_H264,
                                                     self.codecpar->width,
                                                     self.codecpar->height,
                                                     extradata,
                                                     extradata_size);
        if (_formatDescription == NULL)
        {
            return NO;
        }
        NSDictionary * destinationImageBufferAttributes = @{(NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
                                                            (NSString *)kCVPixelBufferWidthKey : @(self.codecpar->width),
                                                            (NSString *)kCVPixelBufferHeightKey : @(self.codecpar->height)};
        
        VTDecompressionOutputCallbackRecord outputCallbackRecord;
        outputCallbackRecord.decompressionOutputCallback = SGVideoAVDecoderOutputCallback;
        outputCallbackRecord.decompressionOutputRefCon = (__bridge void *)self;
        
        OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                                       _formatDescription,
                                                       NULL,
                                                       (__bridge CFDictionaryRef)destinationImageBufferAttributes,
                                                       &outputCallbackRecord,
                                                       &_decompressionSession);
        if (status != noErr)
        {
            _decompressionSession = NULL;
            return NO;
        }
        return YES;
    }
    return NO;
}

- (void)destoryDecompressionSession
{
    if (_decompressionSession)
    {
        VTDecompressionSessionWaitForAsynchronousFrames(_decompressionSession);
        VTDecompressionSessionInvalidate(_decompressionSession);
        CFRelease(_decompressionSession);
        _decompressionSession = NULL;
    }
    if (_formatDescription)
    {
        CFRelease(_formatDescription);
        _formatDescription = NULL;
    }
    self.shouldConvertNALSize3To4 = NO;
}

- (CMSampleBufferRef)sampleBufferFromData:(void *)data size:(size_t)size timingInfo:(CMSampleTimingInfo)timingInfo
{
    CMSampleBufferRef sampleBuffer = NULL;
    if (self.shouldConvertNALSize3To4)
    {
        AVIOContext * io_context = NULL;
        if (avio_open_dyn_buf(&io_context) > 0)
        {
            uint32_t nal_size;
            uint8_t * end = data + size;
            uint8_t * nal_start = data;
            while (nal_start < end)
            {
                nal_size = (nal_start[0] << 16) | (nal_start[1] << 8) | nal_start[2];
                avio_wb32(io_context, nal_size);
                nal_start += 3;
                avio_write(io_context, nal_start, nal_size);
                nal_start += nal_size;
            }
            uint8_t * demux_buffer = NULL;
            int demux_size = avio_close_dyn_buf(io_context, &demux_buffer);
            sampleBuffer = CreateSampleBuffer(_formatDescription, timingInfo, demux_buffer, demux_size);
        }
    }
    else
    {
        sampleBuffer = CreateSampleBuffer(_formatDescription, timingInfo, data, size);
    }
    return sampleBuffer;
}

static void SGVideoAVDecoderOutputCallback(void * decompressionOutputRefCon, void * sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimeStamp, CMTime presentationDuration)
{
    @autoreleasepool
    {
        SGVideoAVDecoder * decoder = (__bridge SGVideoAVDecoder *)decompressionOutputRefCon;
        decoder.decodingStatus = status;
        decoder.decodingPixelBuffer = imageBuffer;
        if (imageBuffer != NULL)
        {
            CVPixelBufferRetain(imageBuffer);
        }
    }
}

static CMSampleBufferRef CreateSampleBuffer(CMFormatDescriptionRef formatDescription, CMSampleTimingInfo timingInfo, void * data, size_t size)
{
    OSStatus status;
    CMBlockBufferRef blockBuffer = NULL;
    CMSampleBufferRef sampleBuffer = NULL;
    status = CMBlockBufferCreateWithMemoryBlock(NULL, data, size, kCFAllocatorNull, NULL, 0, size, FALSE, &blockBuffer);
    if (status == noErr)
    {
        status = CMSampleBufferCreate(NULL, blockBuffer, TRUE, 0, 0, formatDescription, 1, 1, &timingInfo, 0, NULL, &sampleBuffer);
    }
    if (blockBuffer)
    {
        CFRelease(blockBuffer);
        blockBuffer = NULL;
    }
    if (status != noErr)
    {
        if (sampleBuffer)
        {
            CFRelease(sampleBuffer);
            sampleBuffer = NULL;
        }
        return NULL;
    }
    return sampleBuffer;
}
    
static CMFormatDescriptionRef CreateFormatDescription(CMVideoCodecType codec_type,
                                                      int width,
                                                      int height,
                                                      const uint8_t * extradata,
                                                      int extradata_size)
{
    OSStatus status;
    CMFormatDescriptionRef formatDescription = nil;
    NSDictionary * pixelAspectRatio = @{@"HorizontalSpacing" : @(0),
                                        @"VerticalSpacing" : @(0)};
    NSDictionary * sampleDescriptionExtensionAtoms = @{@"avcC" : [NSData dataWithBytes:extradata length:extradata_size]};
    NSDictionary * extensions = @{@"CVImageBufferChromaLocationBottomField" : @"left",
                                  @"CVImageBufferChromaLocationTopField" : @"left",
                                  @"FullRangeVideo" : @(NO),
                                  @"CVPixelAspectRatio" : pixelAspectRatio,
                                  @"SampleDescriptionExtensionAtoms" : sampleDescriptionExtensionAtoms};
    status = CMVideoFormatDescriptionCreate(NULL,
                                            codec_type,
                                            width,
                                            height,
                                            (__bridge CFDictionaryRef)extensions,
                                            &formatDescription);
    if (status != noErr)
    {
        return NULL;
    }
    return formatDescription;
}

@end
