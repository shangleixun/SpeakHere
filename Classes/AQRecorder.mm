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
        
        /*
         此函数作用为：取得任何音频制式下，半秒钟的此音频，的数据大小（字节计）。
         主要是在分配一个录制音频的缓冲区时使用。所以此方法是制式依赖的。
         
         像 LPCM 类型的，每个包里只有一个音频帧，根据采样率算出来这个秒数有几帧，再乘以 mBytesPerFrame
         就可以了。无损音频制式，如 16 bit ，44100 Hz ，双通道，其 mBytesPerFrame
         是恒定的，Core Audio 可以根据音频制式直接给出。
         16 / 8 * 2 * 44100 * 0.5 = 88200 bytes. 即 0.5 秒需要数据的大小为：86.1328125 KiB。
         
         但对压缩制式的音频，则因为压缩技术的不同，并不能使用上面的方式来计算。
         需要使用 frames / mFramesPerPacket * mBytesPerPacket 来计算。
         其中的关键是 mBytesPerPacket 的获取。
         */
        
        
        // 得到帧数：时间长度 * 采样率
        frames = (int)ceil(seconds * format->mSampleRate);
        
        /*
         mBytesPerFrame 的介绍
         Summary
         The number of bytes from the start of one frame to the start of the next
         frame in an audio buffer. Set this field to 0 for compressed formats.
         一个音频缓冲区（audio buffer）中，从一帧的开始到下一帧的开始的字节数量。为压缩制式设置此字段成 0。
         
         Declaration
         UInt32 mBytesPerFrame;
         
         Discussion
         For an audio buffer containing interleaved data for n channels, with each
         sample of type AudioSampleType, calculate the value for this field as follows:
         mBytesPerFrame = n * sizeof (AudioSampleType);
         For an audio buffer containing noninterleaved (monophonic) data, also using
         AudioSampleType samples, calculate the value for this field as follows:
         mBytesPerFrame = sizeof (AudioSampleType);
         
         对一个包含着 n 个声道的交叉存取的（interleaved）数据的音频缓冲，兼之每个采样的类型
         是 AudioSampleType ，计算此字段的值如下：
         mBytesPerFrame = n * sizeof(AudioSampleType);
         对一个包含着非交叉存取的（noninterleaved）（单声道的）数据的音频缓冲，亦使用 AudioSampleType 的
         采样，计算此字段的值如下：
         mBytesPerFrame = sizeof(AudioSampleType);
         
         */
        if (format->mBytesPerFrame > 0)
            bytes = frames * format->mBytesPerFrame;
        else {
            UInt32 maxPacketSize;
            /*
             Summary
             The number of bytes in a packet of audio data. To indicate variable packet size,
             set this field to 0. For a format that uses variable packet size, specify the size
             of each packet using an AudioStreamPacketDescription structure.
             一个音频数据包的字节数量。欲标示可变包体积（variable packet size），设置此字段为 0。
             对一个使用可变包体积的制式，使用一个 ASPD 结构体来明确说明（specify）每个包的大小。
             
             Declaration
             UInt32 mBytesPerPacket;
             */
            if (format->mBytesPerPacket > 0)
                maxPacketSize = format->mBytesPerPacket;	// constant packet size 恒定的数据包大小
            else {
                // 为 0 ，可变包体积的音频制式
                UInt32 propertySize = sizeof(maxPacketSize);
                /*
                 Summary
                 Value is a read-only UInt32 value that is the size, in bytes, of the largest
                 single packet of data in the output format. Primarily useful when encoding
                 VBR compressed data.
                 值为一个只读的 UInt32 值，它是在输出制式中最大的单个数据包的大小，以字节计。当编码 VBR
                 压缩数据时主要有用（primarily useful）。
                 （内在原理推测：此函数应该是专门用于录制音频的。最大输出包体积。有一个重要的依赖项是制式，比如 AAC，
                 最大码率是 320 kbps，倒推一下，320 kbps == 320000 bit/s == 320000/8 byte/s == 40000/1024 KiB/s
                 == 39.0625 KiB/s。半秒则为 19.53125 KiB。mp3 的最大码率 AAC 差不多，所以一样的。其他的依此类推可得。）
                 
                 Declaration
                 kAudioQueueProperty_MaximumOutputPacketSize = 'xops'
                 */
                XThrowIfError(AudioQueueGetProperty(mQueue, kAudioQueueProperty_MaximumOutputPacketSize, &maxPacketSize,
                                                    &propertySize), "couldn't get queue's maximum output packet size");
            }
            // 未压缩音频数据，此值恒为 1
            // 可变码率音频数据，此值是一个较大的固定的值，AAC 是 1024
            // 如果音频每个包的帧数不一样如 ogg，这个值就是 0
            if (format->mFramesPerPacket > 0)
                packets = frames / format->mFramesPerPacket;
            else
                packets = frames;	// worst-case scenario: 1 frame in a packet
            if (packets == 0)		// sanity check 健全测试；完整性测试
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
// 音频队列的回调函数，当一个输入缓冲区被填满后，调用此函数。
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
            /*
             Summary
             把音频数据的数据包写入一个音频数据文件。
             Declaration
             
             OSStatus AudioFileWritePackets(AudioFileID inAudioFile, Boolean inUseCache,
             UInt32 inNumBytes, const AudioStreamPacketDescription *inPacketDescriptions,
             SInt64 inStartingPacket, UInt32 *ioNumPackets, const void *inBuffer);
             Discussion
             对所有非压缩音频制式，此函数将数据包数和帧包数视作等同。
             Parameters
             
             inAudioFile
             要写入的音频文件。
             inUseCache
             如果你想缓存数据，设置此项为 true. 否则，设置为 false.
             inNumBytes
             正写入的音频数据的字节数量。
             inPacketDescriptions
             一个指向数据包描述的数组的指针——针对音频数据的。并不是所有制式都必需数据包描述。
             如果没有数据包描述是必需的，例如，如果你在写一个 CBR 数据，传 NULL.
             inStartingPacket
             替换第一个提供的数据包的数据包索引。
             ioNumPackets
             输入时，指向要写入的数据包数量的一个指针。输出时，指向实际已写入的数据包数量的一个指针。
             inBuffer
             一个指针，指向用户分配的包含了新的要定稿音频数据文件的音频数据的内存空间。
             Returns
             
             A result code. See Result Codes.
             Open in Developer Documentation
             */
            // write packets to file
            XThrowIfError(AudioFileWritePackets(aqr->mRecordFile, FALSE, inBuffer->mAudioDataByteSize,
                                                inPacketDesc, aqr->mRecordPacket, &inNumPackets, inBuffer->mAudioData),
                          "AudioFileWritePackets failed");
            aqr->mRecordPacket += inNumPackets;
        }
        
        // if we're not stopping, re-enqueue the buffer so that it gets filled again
        // 如果我们不打算要停止，重新入队缓冲区以让它再次被填满（音频数据）
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
        // 得到录制制式从（back from）队列的音频转换器中——
        // 文件可能要求一个更明确说明的流描述比创建编码器需要的
        mRecordPacket = 0;
        
        size = sizeof(mRecordFormat);
        /*
         Value is a read-only AudioStreamBasicDescription structure, indicating an audio
         queue’s data format. Primarily useful for obtaining a complete ASBD when recording,
         in cases where you initially specify a sample rate of 0.
         值为一个只读的 ASBD 结构体，标示着一个音频队列的数据制式。当录制时，在你起初明确指定一个采样率为 0 的
         情形中，为要获得一个完整的 ASBD （这个属性）是较为有用的（primarily useful）。
         
         我的理解：录制的时候，如果你最开始明确指定（specify）了采样率为 0，这个属性就可以获得（obtain）
         一个完整的 ASBD 。意思是：在获取到的这个完整的 ASBD 内，你就能获取到真实可用的采样率了。
         */
        XThrowIfError(AudioQueueGetProperty(mQueue, kAudioQueueProperty_StreamDescription,
                                            &mRecordFormat, &size), "couldn't get queue's format");
        
        NSString *recordFile = [NSTemporaryDirectory() stringByAppendingPathComponent: (NSString*)inRecordFile];
        
        url = CFURLCreateWithString(kCFAllocatorDefault, (CFStringRef)recordFile, NULL);
        
        // create the audio file
        /*!
         @enum AudioFileFlags
         
         @abstract   These are flags that can be used with the CreateURL API call
         
         @constant   kAudioFileFlags_EraseFile
         If set, then the CreateURL call will erase the contents of an existing file
         If not set, then the CreateURL call will fail if the file already exists
         如果设置此选项，则 CreateURL 调用会抹除（erase）一个现有文件的内容；
         如果不设置此选项，则 CreateURL 调用会失败，如果文件已经存在的话。
         
         @constant   kAudioFileFlags_DontPageAlignAudioData
         Normally, newly created and optimized files will have padding added in order to page align
         the data to 4KB boundaries. This makes reading the data more efficient.
         When disk space is a concern, this flag can be set so that the padding will not be added.
         正常情况下，新创建及优化的文件会添加补白（padding）以页面对齐数据到 4 KB 边界。这使得读取数据更有效率。
         当硬盘空间是一个问题（is a concern）时，此标记（flag）可被设置以使补白不被添加。
         */
        /**
         第一个参数：inFileRef 完整的明确说明的要创建或初始化的文件的路径。
         第二个参数：inFileType 要创建的音频文件的类型。查看 AudioFileTypeID 来了解可用的常量。
         第三个参数：inFormat 一个指向描述了数据制式的结构体的指针。
         第四个参数：inFlags 创建或打开文件相关的标记。如果 kAudioFileFlags_EraseFile 被设置，它抹除一个已存的文件。
         如果此标记未被设置，且 URL 是一个已存的文件时，此函数就会失败。
         第五个参数：outAudioFile 在输出时，是一个指向新创建的或初始化了的文件的指针。
         */
        OSStatus status = AudioFileCreateWithURL(url, kAudioFileCAFType, &mRecordFormat, kAudioFileFlags_EraseFile, &mRecordFile);
        CFRelease(url);
        
        XThrowIfError(status, "AudioFileCreateWithURL failed");
        
        // copy the cookie first to give the file object as much info as we can about the data going in
        // not necessary for pcm, but required for some compressed audio
        // 首先拷贝曲奇来给文件对象尽可能多的关于要进来的数据的信息
        // PCM 数据不需要（not necessary），但一些压缩的音频是必需的（required）
        CopyEncoderCookieToFile();
        
        // allocate and enqueue buffers
        // 分配并入队缓冲区
        bufferByteSize = ComputeRecordBufferSize(&mRecordFormat, kBufferDurationSeconds);	// enough bytes for half a second
        for (i = 0; i < kNumberRecordBuffers; ++i) {
            XThrowIfError(AudioQueueAllocateBuffer(mQueue, bufferByteSize, &mBuffers[i]),
                          "AudioQueueAllocateBuffer failed");
            /*
             Summary
             
             Adds a buffer to the buffer queue of a recording or playback audio queue.
             添加一个缓冲区到一个录制或播放音频队列的缓冲队列中。
             
             Declaration
             
             OSStatus AudioQueueEnqueueBuffer(AudioQueueRef inAQ, AudioQueueBufferRef inBuffer, UInt32 inNumPacketDescs, const AudioStreamPacketDescription *inPacketDescs);
             Discussion
             
             Audio queue callbacks use this function to reenqueue buffers—placing them
             “last in line” in a buffer queue. A playback (or output) callback reenqueues
             a buffer after the buffer is filled with fresh audio data (typically from a
             file). A recording (or input) callback reenqueues a buffer after the buffer’s
             contents were written (typically to a file).
             音频队列回调使用此函数来重新入队缓冲区们——把它们以“队中的最后一个”的方式放入一个缓冲队列中。
             一个播放（或输出）回调重新入队一个缓冲区在这个缓冲区被填入新鲜的（refresh）音频数据
             （通常（typically）来自一个文件）之后。一个录制（或输入）回调重新入队一个缓冲区在这个缓冲区
             的内容被写入（通常写到一个文件中）之后。
             Parameters
             
             inAQ
             The audio queue that owns the audio queue buffer.
             拥有音频队列缓冲的音频队列。
             inBuffer
             The audio queue buffer to add to the buffer queue.
             要添加到缓冲队列中的音频队列缓冲区。
             inNumPacketDescs
             The number of packets of audio data in the inBuffer parameter.
             Use a value of 0 for any of the following situations:
             When playing a constant bit rate (CBR) format.
             When the audio queue is a recording (input) audio queue.
             When the buffer you are reenqueuing was allocated with the
             AudioQueueAllocateBufferWithPacketDescriptions function.
             In this case, your callback should describe the buffer’s packets
             in the buffer’s mPacketDescriptions and mPacketDescriptionCount fields.
             在 inBuffer 参数中的音频数据包的数量。有下列情形之一的，使用 0 值：
             当播放一个恒定比特率（CBR）制式时。
             当音频队列是一个录制（输入）音频队列时。
             当你正添加的缓冲区是由 AudioQueueAllocateBufferWithPacketsDescriptions 函数分配的时。在这种情况下，你的回调应该描述缓冲区的包们，在缓冲区的 mPacketDescriptions
             和 mPacketDescriptionCount 字段中。
             inPacketDescs
             An array of packet descriptions. Use a value of NULL for any of the following situations:
             When playing a constant bit rate (CBR) format.
             When the audio queue is an input (recording) audio queue.
             When the buffer you are reenqueuing was allocated with the
             AudioQueueAllocateBufferWithPacketDescriptions function.
             In this case, your callback should describe the buffer’s
             packets in the buffer’s mPacketDescriptions and mPacketDescriptionCount fields.
             包描述的一个数组。有下列情形之一的，使用一个 NULL 值：
             当播放一个恒定比特率（CBR）制式时。
             当音频队列是一个输入（录制）音频队列时。
             当你正重新入队的缓冲区是由 AudioQueueAllocateBufferWithPacketDescriptions
             函数分配的时。在这种情况下，你的回调应当描述缓冲区的包们，在缓冲区的 mPacketDescriptions
             和 mPacketDescriptionCount 字段中。
             Returns
             
             A result code. See Result Codes.
             一个结果码。见 Result Codes。
             */
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
