/*
 
 File: AQPlayer.mm
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


#include "AQPlayer.h"

void AQPlayer::AQBufferCallback(void *					inUserData,
                                AudioQueueRef			inAQ,
                                AudioQueueBufferRef		inCompleteAQBuffer)
{
    AQPlayer *THIS = (AQPlayer *)inUserData;
    
    // 已经结束，不再做任何处理
    if (THIS->mIsDone) return;
    
    UInt32 numBytes;
    // 获取要读取的包的数量
    UInt32 nPackets = THIS->GetNumPacketsToRead();
    /**
     从音频数据中读包，第一个参数是文件格式，第二个用不用缓存，第三个是读取到的数据量，以字节计
     第四个参数是读取到的音频包的描述，第五个从哪个 index 开始读，第六个读到的包的数量，第七个读取的包数据。
     
     注意，此函数并不是从音频数据文件中读取包数据，其所依据的是音频的文件名
     
     但：有没有可能从当前处理的多条音频中，获取符合指定的 FileID 的来读取数据呢？是有可能的。
     */
    OSStatus result = AudioFileReadPackets(THIS->GetAudioFileID(), false, &numBytes, inCompleteAQBuffer->mPacketDescriptions, THIS->GetCurrentPacket(), &nPackets,
                                           inCompleteAQBuffer->mAudioData);
    if (result)
        printf("AudioFileReadPackets failed: %d", (int)result);
    if (nPackets > 0) {
        // 要压进队列的 buffer 字节大小，播放时此值必须设置
        inCompleteAQBuffer->mAudioDataByteSize = numBytes;
        // buffer 中有效的包描述数量，播放时，此值由人来设置
        inCompleteAQBuffer->mPacketDescriptionCount = nPackets;
        // 带有 mPacketDescription 的 AudioBuffer，最后一个参数可以传 NULL
        /*
         这一步是压进队列的操作
         */
        AudioQueueEnqueueBuffer(inAQ, inCompleteAQBuffer, 0, NULL);
        // 设置当前包的偏移量
        THIS->mCurrentPacket = (THIS->GetCurrentPacket() + nPackets);
    }
    // 读不到任何数据
    else
    {
        if (THIS->IsLooping())
        {
            // 重设当前包的偏移量为 0
            THIS->mCurrentPacket = 0;
            AQBufferCallback(inUserData, inAQ, inCompleteAQBuffer);
        }
        else
        {
            // 停止播放
            // stop
            THIS->mIsDone = true;
            AudioQueueStop(inAQ, false);
        }
    }
}

void AQPlayer::isRunningProc (  void *              inUserData,
                              AudioQueueRef           inAQ,
                              AudioQueuePropertyID    inID)
{
    AQPlayer *THIS = (AQPlayer *)inUserData;
    UInt32 size = sizeof(THIS->mIsRunning);
    OSStatus result = AudioQueueGetProperty (inAQ, kAudioQueueProperty_IsRunning, &THIS->mIsRunning, &size);
    
    if ((result == noErr) && (!THIS->mIsRunning))
        [[NSNotificationCenter defaultCenter] postNotificationName: @"playbackQueueStopped" object: nil];
}

/// 计算一定时间的 buffer 需要的字节数。
/// @param inDesc 输入的基本信息描述。
/// @param inMaxPacketSize 输入的最大包体积。
/// @param inSeconds 输入的时间长度。这里是半秒。
/// @param outBufferSize 输出的 buffer 的尺寸。
/// @param outNumPackets 输出的包数量。
void AQPlayer::CalculateBytesForTime (CAStreamBasicDescription & inDesc, UInt32 inMaxPacketSize, Float64 inSeconds, UInt32 *outBufferSize, UInt32 *outNumPackets)
{
    // we only use time here as a guideline
    // we're really trying to get somewhere between 16K and 64K buffers, but not allocate too much if we don't need it
    static const int maxBufferSize = 0x10000; // limit size to 64K
    static const int minBufferSize = 0x4000; // limit size to 16K
    
    // 未压缩音频数据，此值恒为 1
    // 可变码率音频数据，此值是一个较大的固定的值，AAC 是 1024
    // 如果音频每个包的帧数不一样如 ogg，这个值就是 0
    if (inDesc.mFramesPerPacket) {
        Float64 numPacketsForTime = inDesc.mSampleRate / inDesc.mFramesPerPacket * inSeconds;
        *outBufferSize = numPacketsForTime * inMaxPacketSize;
    } else {
        // if frames per packet is zero, then the codec has no predictable packet == time
        // so we can't tailor this (we don't know how many Packets represent a time period
        // we'll just return a default buffer size
        *outBufferSize = maxBufferSize > inMaxPacketSize ? maxBufferSize : inMaxPacketSize;
    }
    
    // we're going to limit our size to our default
    if (*outBufferSize > maxBufferSize && *outBufferSize > inMaxPacketSize)
        *outBufferSize = maxBufferSize;
    else {
        // also make sure we're not too small - we don't want to go the disk for too small chunks
        if (*outBufferSize < minBufferSize)
            *outBufferSize = minBufferSize;
    }
    *outNumPackets = *outBufferSize / inMaxPacketSize;
}

AQPlayer::AQPlayer() :
mQueue(0),
mAudioFile(0),
mFilePath(NULL),
mIsRunning(false),
mIsInitialized(false),
mNumPacketsToRead(0),
mCurrentPacket(0),
mIsDone(false),
mIsLooping(false) { }

AQPlayer::~AQPlayer() 
{
    DisposeQueue(true);
}

OSStatus AQPlayer::StartQueue(BOOL inResume)
{	
    // if we have a file but no queue, create one now
    if ((mQueue == NULL) && (mFilePath != NULL)) CreateQueueForFile(mFilePath);
    
    mIsDone = false;
    
    // if we are not resuming, we also should restart the file read index
    if (!inResume) {
        mCurrentPacket = 0;
        
        // prime the queue with some data before starting
        for (int i = 0; i < kNumberBuffers; ++i) {
            AQBufferCallback (this, mQueue, mBuffers[i]);
        }
    }
    return AudioQueueStart(mQueue, NULL);
}

OSStatus AQPlayer::StopQueue()
{
    mIsDone = true;
    
    OSStatus result = AudioQueueStop(mQueue, true);
    if (result) printf("ERROR STOPPING QUEUE!\n");
    
    return result;
}

OSStatus AQPlayer::PauseQueue()
{
    OSStatus result = AudioQueuePause(mQueue);
    
    return result;
}

void AQPlayer::CreateQueueForFile(CFStringRef inFilePath) 
{
    // 初始化要指定为 NULL
    CFURLRef sndFile = NULL;
    
    try {
        if (mFilePath == NULL)
        {
            // 不需要循环
            mIsLooping = false;
            
            // 使用提供的路径来创建 CFURLRef
            // 参数解释：第一个是空间分配器，用来给要生成的 CF 对象分配内存，传 NULL 或 kCFAllocatorDefault 就行了
            // 第二个是路径的字符串
            // 第三个是 CFURL 的路径风格，只有两种，这里选择默认的 POSIX 风格
            // 第四个告诉是否目录
            sndFile = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, inFilePath, kCFURLPOSIXPathStyle, false);
            if (!sndFile) { printf("can't parse file path\n"); return; }
            
            // AudioFile 打开 URL
            // 参数第一个是 CFURL 路径
            // 第二个告诉处理文件的权限，是读还是写还是读写
            // 第三个暗示一下文件类型，有些不好处理的（比如没有扩展名的）暗示一下好处理一点，一般传 0
            // 第四个是找到了文件后，把文件所在位置的指针整出来
            // 原来 mAudioFile 这个东西是指向文件的指针，我上面还怀疑那么智能，原来这个东西是文件的指针！
            OSStatus rc = AudioFileOpenURL (sndFile, kAudioFileReadPermission, 0/*inFileTypeHint*/, &mAudioFile);
            // 所有 CF 对象，不用了的时候，要释放掉，不然编译器会提示没释放
            CFRelease(sndFile); // release sndFile here to quiet analyzer
            XThrowIfError(rc, "can't open file");
            
            UInt32 size = sizeof(mDataFormat);
            // 获取音频数据描述
            // 参数第一个是文件
            // 第二个是要获取的属性，这里指明是数据格式
            // 第三个要写入的数据大小
            // 第四个写入格式的具体信息，本函数会 duplicate 一份基本描述信息出来，
            // 这个数据体的内存管理，由调用者来负责
            XThrowIfError(AudioFileGetProperty(mAudioFile, kAudioFilePropertyDataFormat, &size, &mDataFormat), "couldn't get file's data format");
            // CF 对象的复制，都有单独的方法的
            // 这里是单独再分配内存，把传进来的 filePath 赋值给 mFilePath
            mFilePath = CFStringCreateCopy(kCFAllocatorDefault, inFilePath);
        }
        // 初始化一个新的队列
        SetupNewQueue();
    }
    catch (CAXException e) {
        char buf[256];
        fprintf(stderr, "Error: %s (%s)\n", e.mOperation, e.FormatError(buf));
    }
}

void AQPlayer::SetupNewQueue() 
{
    
    // 创建一个新的输出的 AudioQueue
    // 参数解释
    // 第一个 传入的数据基本信息描述
    // 第二个 输出的回调函数
    // 第三个 传入当前对象，会回传到 callback 中
    // 第四个 RunLoop
    // 第五个 RunLoopMode
    // 第六个 保留未来使用，必须设为 0
    // 第七个 生成的 AudioQueueRef ，会赋值给传进去的 AudioQueueRef 指针
    XThrowIfError(AudioQueueNewOutput(&mDataFormat, AQPlayer::AQBufferCallback, this,
                                      CFRunLoopGetCurrent(), kCFRunLoopCommonModes, 0, &mQueue), "AudioQueueNew failed");
    UInt32 bufferByteSize;
    // we need to calculate how many packets we read at a time, and how big a buffer we need
    // we base this on the size of the packets in the file and an approximate duration for each buffer
    // first check to see what the max size of a packet is - if it is bigger
    // than our allocation default size, that needs to become larger
    // 我们需要计算我们一次读多少个包，以及我们需要一个 buffer 有多大
    // 我们基于文件中包的大小和每个 buffer 大概的持续时间
    // 首先，检查一下看看一个包的最大尺寸是多少——如果它比我们分配的默认尺寸大，那就需要扩大 buffer 的尺寸
    
    UInt32 maxPacketSize;
    UInt32 size = sizeof(maxPacketSize);
    // 获取音频文件信息 理论最大包尺寸
    // 第一个参数 文件指针
    // 第二个 要获取的属性，这里指定为 包尺寸的上限边界；这个 key 代表的是理论上的，如果要获取实际上的，使用 kAudioFilePropertyMaximumPacketSize
    // 第三个 写入数据的大小
    // 第四个 写入读取到的数据，这里是最大的包的尺寸
    XThrowIfError(AudioFileGetProperty(mAudioFile,
                                       kAudioFilePropertyPacketSizeUpperBound, &size, &maxPacketSize), "couldn't get file's max packet size");
    
    // adjust buffer size to represent about a half second of audio based on this format
    // 调整 buffer 尺寸来代表大约半秒钟的基于此制式（format）的音频数据
    CalculateBytesForTime (mDataFormat, maxPacketSize, kBufferDurationSeconds, &bufferByteSize, &mNumPacketsToRead);
    
    //printf ("Buffer Byte Size: %d, Num Packets to Read: %d\n", (int)bufferByteSize, (int)mNumPacketsToRead);
    
    // (2) If the file has a cookie, we should get it and set it on the AQ
    size = sizeof(UInt32);
    // 获取 AudioFile 的属性信息 property info 这里是魔法曲奇数据
    // Magic Cookie Data
    // kAudioFilePropertyMagicCookieData
    // 释义：
    // 指向由调用者建立（set up）的一块内存。在包可以被写入一个音频文件之前，一些文件类型需要提供一个魔法曲奇。
    // 如果一个魔法曲奇存在的话，在你调用 AudioFileWriteBytes 或 AudioFileWritePackets 之前，设置此属性。
    //
    // kAudioQueueProperty_MagicCookie
    // 释义
    // 值为一个指向一块内存的可读写的空指针，是你建立（set up）的，包含了一个音频制式魔法曲奇。
    // 如果你正在播放或录制的音频制式要求（require）一个魔法曲奇的话，
    // 在入列（enqueue）任何缓冲数据之前，你必须为此属性设定一个值。
    
    
    // 魔法曲奇的其他介绍
    // Some audio formats have an magic cookie associated with them that are required to decompress
    // audio data. Magic cookies (some times called magic numbers) are information included in audio
    // file headers that are used to describe data formats. When converting audio data you must
    // check to see if the format of the data has a magic cookie. If the audio data format has a
    // magic cookie associated with it, you must need to add this information to an audio converter
    // using AudioConverterSetProperty and kAudioConverterDecompressionMagicCookie to appropriately
    // decompress the Audio File.
    // Note: Most data formats do not have magic cookie information, but you must check before
    // converting the data.
    
    // 一些音频制式拥有一个魔法曲奇关联着它们，这个曲奇是需要解压缩的音频数据。魔法曲奇（有时也称为魔法数字）是包括在音频
    // 文件头部中的信息，用来描述音频制式。当转换音频数据时，你必须检查来看一下是否那个数据的制式有一个魔法曲奇。如果这个
    // 音频数据制式有一个魔法曲奇关联着它，你必须得（must need to）添加这个信息到一个音频转换器上，使用
    // AudioConverterSetProperty 和 kAudioConverterDecompressionMagicCookie 来恰当地解压缩这个 Audio
    // File 。
    // 注意：大多数数据制式并不会有魔法曲奇信息，但你必须在转换数据前检查一下。
    
    OSStatus result = AudioFileGetPropertyInfo (mAudioFile, kAudioFilePropertyMagicCookieData, &size, NULL);
    
    if (!result && size) {
        /**
         根据上面的解释，这里就是从文件中获取到了魔法曲奇，然后将它设置给 Audio Queue 的属性 kAudioQueueProperty_MagicCookie 。
         */
        char* cookie = new char [size];
        XThrowIfError (AudioFileGetProperty (mAudioFile, kAudioFilePropertyMagicCookieData, &size, cookie), "get cookie from file");
        XThrowIfError (AudioQueueSetProperty(mQueue, kAudioQueueProperty_MagicCookie, cookie, size), "set cookie on queue");
        delete [] cookie;
    }
    
    // channel layout?
    // 声道布局？
    result = AudioFileGetPropertyInfo(mAudioFile, kAudioFilePropertyChannelLayout, &size, NULL);
    if (result == noErr && size > 0) {
        AudioChannelLayout *acl = (AudioChannelLayout *)malloc(size);
        
        result = AudioFileGetProperty(mAudioFile, kAudioFilePropertyChannelLayout, &size, acl);
        if (result) { free(acl); XThrowIfError(result, "get audio file's channel layout"); }
        
        /* kAudioQueueProperty_ChannelLayout 释义
         Value is a read/write AudioChannelLayout structure that describes an audio queue channel
         layout. The number of channels in the layout must match the number of channels in the audio
         format. This property is typically not used in the case of one or two channel audio. For
         more than two channels (such as in the case of 5.1 surround sound), you may need to specify
         a channel layout to indicate channel order, such as left, then center, then right.
         
         值为一个可读写的 AudioChannelLayout 结构体，描述了一个音频队列（Audio Queue）的声道布局。在布局中的声道数量必须匹配在
         音频制式中的声道数量。这个属性通常（typically）不会用在只有一个或两个声道的音频中。对于多于两个声道的音频，你可能需要指定
         一个声道布局来标示声道的序列，如左，然后中，然后右。
         */
        
        result = AudioQueueSetProperty(mQueue, kAudioQueueProperty_ChannelLayout, acl, size);
        if (result){ free(acl); XThrowIfError(result, "set channel layout on queue"); }
        
        free(acl);
    }
    /*
     Adds a property listener callback to an audio queue.
     给一个音频队列添加一个属性监听回调函数。
     Declaration
     
     OSStatus AudioQueueAddPropertyListener(AudioQueueRef inAQ, AudioQueuePropertyID inID, AudioQueuePropertyListenerProc inProc, void *inUserData);
     Discussion
     
     Use this function to let your application respond to property value changes in an audio queue.
     For example, say your application’s user interface has a button that acts as a Play/Stop toggle
     switch. When an audio file has finished playing, the audio queue stops and the value of the
     kAudioQueueProperty_IsRunning property changes from true to false. You can use a property listener
     callback to update the button text appropriately.
     
     使用此函数来让你的应用对一个音频队列中的属性值改变做出回应（respond）。举个例子，比方说你的应用程序的用户界面有一个按钮，
     充当一个播放/停止的拨动开关。当一个音频文件已经结束了播放，音频队列停止，且 kAudioQueueProperty_IsRunning
     属性的值会从 true 变为 false 。你可以使用一个属性监听回调函数来适当地更新按钮的文字。
     
     Parameters
     
     inAQ
     The audio queue that you want to assign a property listener callback to.
     要监听的音频队列。
     inID
     The ID of the property whose changes you want to respond to. See AudioQueuePropertyID.
     要监听的属性 ID 。
     inProc
     The callback to be invoked when the property value changes.
     回调函数。
     inUserData
     Custom data for the property listener callback.
     自定义的数据，可在回调函数中使用。
     */
    // 监听音频队列的 IsRunning 属性值改变
    XThrowIfError(AudioQueueAddPropertyListener(mQueue, kAudioQueueProperty_IsRunning, isRunningProc, this), "adding property listener");
    
    bool isFormatVBR = (mDataFormat.mBytesPerPacket == 0 || mDataFormat.mFramesPerPacket == 0);
    for (int i = 0; i < kNumberBuffers; ++i) {
        XThrowIfError(AudioQueueAllocateBufferWithPacketDescriptions(mQueue, bufferByteSize, (isFormatVBR ? mNumPacketsToRead : 0), &mBuffers[i]), "AudioQueueAllocateBuffer failed");
    }
    
    // set the volume of the queue
    XThrowIfError (AudioQueueSetParameter(mQueue, kAudioQueueParam_Volume, 1.0), "set queue volume");
    
    mIsInitialized = true;
}

void AQPlayer::DisposeQueue(Boolean inDisposeFile)
{
    if (mQueue)
    {
        AudioQueueDispose(mQueue, true);
        mQueue = NULL;
    }
    if (inDisposeFile)
    {
        if (mAudioFile)
        {
            AudioFileClose(mAudioFile);
            mAudioFile = 0;
        }
        if (mFilePath)
        {
            CFRelease(mFilePath);
            mFilePath = NULL;
        }
    }
    mIsInitialized = false;
}
