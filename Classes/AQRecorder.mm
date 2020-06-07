/*
 
 File: AQRecorder.mm
 Abstract: n/a
 Version: 2.5
 
 Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
 Inc. ("Apple") in consideration of your agreement to the following
 terms, and your use, installation, modification or redistribution of
 this Apple software constitutes acceptance of these terms.  If you do
 not agree with these terms, please do not use, install, modify or
 redistribute this Apple software.
 
 In consideration of your agreement to abide by the following terms, and
 subject to these terms, Apple grants you a personal, non-exclusive
 license, under Apple's copyrights in this original Apple software (the
 "Apple Software"), to use, reproduce, modify and redistribute the Apple
 Software, with or without modifications, in source and/or binary forms;
 provided that if you redistribute the Apple Software in its entirety and
 without modifications, you must retain this notice and the following
 text and disclaimers in all such redistributions of the Apple Software.
 Neither the name, trademarks, service marks or logos of Apple Inc. may
 be used to endorse or promote products derived from the Apple Software
 without specific prior written permission from Apple.  Except as
 expressly stated in this notice, no other rights or licenses, express or
 implied, are granted by Apple herein, including but not limited to any
 patent rights that may be infringed by your derivative works or by other
 works in which the Apple Software may be incorporated.
 
 The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
 MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
 THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
 FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
 OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
 
 IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
 OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
 MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
 AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
 STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
 POSSIBILITY OF SUCH DAMAGE.
 
 Copyright (C) 2012 Apple Inc. All Rights Reserved.
 
 
 */

#include "AQRecorder.h"

// ____________________________________________________________________________________
// Determine the size, in bytes, of a buffer necessary to represent the supplied number
// of seconds of audio data.
int AQRecorder::ComputeRecordBufferSize(const AudioStreamBasicDescription *format, float seconds)
{
    int packets, frames, bytes = 0;
    try {
        // 得到帧数，也即包数——针对未压缩制式
        frames = (int)ceil(seconds * format->mSampleRate);
        
        if (format->mBytesPerFrame > 0)
            bytes = frames * format->mBytesPerFrame;
        else {
            UInt32 maxPacketSize;
            if (format->mBytesPerPacket > 0)
                maxPacketSize = format->mBytesPerPacket;	// constant packet size
            else {
                UInt32 propertySize = sizeof(maxPacketSize);
                XThrowIfError(AudioQueueGetProperty(mQueue, kAudioQueueProperty_MaximumOutputPacketSize, &maxPacketSize,
                                                    &propertySize), "couldn't get queue's maximum output packet size");
            }
            if (format->mFramesPerPacket > 0)
                packets = frames / format->mFramesPerPacket;
            else
                packets = frames;	// worst-case scenario: 1 frame in a packet
            if (packets == 0)		// sanity check
                packets = 1;
            bytes = packets * maxPacketSize;
        }
    } catch (CAXException e) {
        char buf[256];
        fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
        return 0;
    }
    return bytes;
}

// ____________________________________________________________________________________
// AudioQueue callback function, called when an input buffers has been filled.
void AQRecorder::MyInputBufferHandler(	void *								inUserData,
                                      AudioQueueRef						inAQ,
                                      AudioQueueBufferRef					inBuffer,
                                      const AudioTimeStamp *				inStartTime,
                                      UInt32								inNumPackets,
                                      const AudioStreamPacketDescription*	inPacketDesc)
{
    AQRecorder *aqr = (AQRecorder *)inUserData;
    try {
        if (inNumPackets > 0) {
            // write packets to file
            XThrowIfError(AudioFileWritePackets(aqr->mRecordFile, FALSE, inBuffer->mAudioDataByteSize,
                                                inPacketDesc, aqr->mRecordPacket, &inNumPackets, inBuffer->mAudioData),
                          "AudioFileWritePackets failed");
            aqr->mRecordPacket += inNumPackets;
        }
        
        // if we're not stopping, re-enqueue the buffe so that it gets filled again
        if (aqr->IsRunning())
            XThrowIfError(AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL), "AudioQueueEnqueueBuffer failed");
    } catch (CAXException e) {
        char buf[256];
        fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
    }
}

AQRecorder::AQRecorder()
{
    mIsRunning = false;
    mRecordPacket = 0;
}

AQRecorder::~AQRecorder()
{
    AudioQueueDispose(mQueue, TRUE);
    AudioFileClose(mRecordFile);
    if (mFileName) CFRelease(mFileName);
}

// ____________________________________________________________________________________
// Copy a queue's encoder's magic cookie to an audio file.
void AQRecorder::CopyEncoderCookieToFile()
{
    UInt32 propertySize;
    // get the magic cookie, if any, from the converter
    OSStatus err = AudioQueueGetPropertySize(mQueue, kAudioQueueProperty_MagicCookie, &propertySize);
    
    // we can get a noErr result and also a propertySize == 0
    // -- if the file format does support magic cookies, but this file doesn't have one.
    if (err == noErr && propertySize > 0) {
        Byte *magicCookie = new Byte[propertySize];
        UInt32 magicCookieSize;
        XThrowIfError(AudioQueueGetProperty(mQueue, kAudioQueueProperty_MagicCookie, magicCookie, &propertySize), "get audio converter's magic cookie");
        magicCookieSize = propertySize;	// the converter lies and tell us the wrong size
        
        // now set the magic cookie on the output file
        UInt32 willEatTheCookie = false;
        // the converter wants to give us one; will the file take it?
        err = AudioFileGetPropertyInfo(mRecordFile, kAudioFilePropertyMagicCookieData, NULL, &willEatTheCookie);
        if (err == noErr && willEatTheCookie) {
            err = AudioFileSetProperty(mRecordFile, kAudioFilePropertyMagicCookieData, magicCookieSize, magicCookie);
            XThrowIfError(err, "set audio file's magic cookie");
        }
        delete[] magicCookie;
    }
}

void AQRecorder::SetupAudioFormat(UInt32 inFormatID)
{
    // 给 mRecordFormat 的内存重写为 0
    // mRecordFormat 是音频流基本描述
    memset(&mRecordFormat, 0, sizeof(mRecordFormat));
    
    UInt32 size = sizeof(mRecordFormat.mSampleRate);
    // 获取当前硬件支持的最大采样率或默认采样率，写入基本描述的 mSampleRate 中
    XThrowIfError(AudioSessionGetProperty(	kAudioSessionProperty_CurrentHardwareSampleRate,
                                          &size,
                                          &mRecordFormat.mSampleRate), "couldn't get hardware sample rate");
    
    size = sizeof(mRecordFormat.mChannelsPerFrame);
    /**
     Indicates the current number of audio hardware input channels. A read-only UInt32 value.
     标示当前音频硬件输入声道的数量。一个只读的 UInt32 值。
     */
    XThrowIfError(AudioSessionGetProperty(	kAudioSessionProperty_CurrentHardwareInputNumberChannels,
                                          &size,
                                          &mRecordFormat.mChannelsPerFrame), "couldn't get input channel count");
    
    // 设定制式唯一标识符
    mRecordFormat.mFormatID = inFormatID;
    
    // 如果是无损，则帧数每包为 1 ，则字节数每包 == 字节数每帧 == 比特数每声道/8（得出字节数每声道） * 声道数每帧
    if (inFormatID == kAudioFormatLinearPCM)
    {
        // if we want pcm, default to signed 16-bit little-endian
        mRecordFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        // 量化位深
        mRecordFormat.mBitsPerChannel = 16;
        // 线性 PCM
        // 字节每包 = 字节每帧（一个帧就是一个取样）= 比特每声道/8 * 声道数每帧
        mRecordFormat.mBytesPerPacket = mRecordFormat.mBytesPerFrame = (mRecordFormat.mBitsPerChannel / 8) * mRecordFormat.mChannelsPerFrame;
        // 线性 PCM 每帧即每包
        mRecordFormat.mFramesPerPacket = 1;
    }
}

void AQRecorder::StartRecord(CFStringRef inRecordFile)
{
    int i, bufferByteSize;
    UInt32 size;
    CFURLRef url = nil;
    
    try {
        // CF 对象有专用的拷贝方法
        // 拷贝出来的一定是不可改变的（immutable）
        // 拷贝出来的对象的内在存储特性可能与传进来的 CFStringRef 不同，
        // 因而 CFStringGetCStringPtr 之类函数对它们的调用，返回的结果可能是不同的
        // 当使用的分配器和原始的对象是一样的，并且原始对象已经是不可变的时候，这个函数
        // 只是增加其保留计数而非真实地去拷贝。但结果对象是真的不可变的，只是这样的操作
        // 效率更高
        mFileName = CFStringCreateCopy(kCFAllocatorDefault, inRecordFile);
        
        // specify the recording format
        SetupAudioFormat(kAudioFormatLinearPCM);
        
        // create the queue
        XThrowIfError(AudioQueueNewInput(
                                         &mRecordFormat,
                                         MyInputBufferHandler,
                                         this /* userData */,
                                         NULL /* run loop */, NULL /* run loop mode */,
                                         0 /* flags */, &mQueue), "AudioQueueNewInput failed");
        
        // get the record format back from the queue's audio converter --
        // the file may require a more specific stream description than was necessary to create the encoder.
        mRecordPacket = 0;
        
        size = sizeof(mRecordFormat);
        /**
         Value is a read-only AudioStreamBasicDescription structure, indicating an audio queue’s data format. Primarily useful for obtaining a complete ASBD when recording, in cases where you initially specify a sample rate of 0.
         值为一个只读的 ASBD 结构体，标示着一个音频队列的数据制式。当录制时，在你起初明确指定一个采样率为 0 的情形中，为要获得一个完整的 ASBD （这个属性）是非常有用的（primarily useful）。
         
         录制的时候，如果你最开始明确指定（specify）了采样率为 0，这个属性就可以获得（obtain）一个完整的 ASBD 。意思是：在获取到的这个
         完整的 ASBD 内，你就能获取到真实可用的采样率了。
         这是我的理解。
         */
        XThrowIfError(AudioQueueGetProperty(mQueue, kAudioQueueProperty_StreamDescription,
                                            &mRecordFormat, &size), "couldn't get queue's format");
        
        NSString *recordFile = [NSTemporaryDirectory() stringByAppendingPathComponent: (NSString*)inRecordFile];
        
        url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)recordFile, NULL);
        
        // create the audio file
        OSStatus status = AudioFileCreateWithURL(url, kAudioFileCAFType, &mRecordFormat, kAudioFileFlags_EraseFile, &mRecordFile);
        CFRelease(url);
        
        XThrowIfError(status, "AudioFileCreateWithURL failed");
        
        // copy the cookie first to give the file object as much info as we can about the data going in
        // not necessary for pcm, but required for some compressed audio
        CopyEncoderCookieToFile();
        
        // allocate and enqueue buffers
        bufferByteSize = ComputeRecordBufferSize(&mRecordFormat, kBufferDurationSeconds);	// enough bytes for half a second
        for (i = 0; i < kNumberRecordBuffers; ++i) {
            XThrowIfError(AudioQueueAllocateBuffer(mQueue, bufferByteSize, &mBuffers[i]),
                          "AudioQueueAllocateBuffer failed");
            XThrowIfError(AudioQueueEnqueueBuffer(mQueue, mBuffers[i], 0, NULL),
                          "AudioQueueEnqueueBuffer failed");
        }
        // start the queue
        mIsRunning = true;
        XThrowIfError(AudioQueueStart(mQueue, NULL), "AudioQueueStart failed");
    }
    catch (CAXException e) {
        char buf[256];
        fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
    }
    catch (...) {
        fprintf(stderr, "An unknown error occurred\n");;
    }
    
}

void AQRecorder::StopRecord()
{
    // end recording
    mIsRunning = false;
    XThrowIfError(AudioQueueStop(mQueue, true), "AudioQueueStop failed");
    // a codec may update its cookie at the end of an encoding session, so reapply it to the file now
    CopyEncoderCookieToFile();
    if (mFileName)
    {
        CFRelease(mFileName);
        mFileName = NULL;
    }
    AudioQueueDispose(mQueue, true);
    AudioFileClose(mRecordFile);
}
