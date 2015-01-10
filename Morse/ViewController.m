
//  ViewController.m
//  Morse
//
//  Created by Dr. Gerolf Ziegenhain on 05.01.15.
//  Copyright (c) 2015 Dr. Gerolf Ziegenhain. All rights reserved.
//

#import "ViewController.h"
#import <AudioToolbox/AudioToolbox.h>
#import <netdb.h>
#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#include "cwprotocol.h"

#import <AVFoundation/AVFoundation.h>

#include <mach/clock.h>
#include <mach/mach.h>


//#undef DEBUG
//#define DEBUG_NET
//#define DEBUG_TX
//#define EXT_KEY
#define SCROLLVIEWLOG

OSStatus RenderTone(
                    void *inRefCon,
                    AudioUnitRenderActionFlags 	*ioActionFlags,
                    const AudioTimeStamp 		*inTimeStamp,
                    UInt32 						inBusNumber,
                    UInt32 						inNumberFrames,
                    AudioBufferList 			*ioData)

{
    // Fixed amplitude is good enough for our purposes
    const double amplitude = 0.25;
    
    // Get the tone parameters out of the view controller
    ViewController *vviewController =
    (__bridge ViewController *)inRefCon;
    double theta = vviewController->theta;
    double theta_increment = 2.0 * M_PI * vviewController->frequency / vviewController->sampleRate;
    
    // This is a mono tone generator so we only need the first buffer
    const int channel = 0;
    Float32 *buffer = (Float32 *)ioData->mBuffers[channel].mData;
    
    // Generate the samples
    for (UInt32 frame = 0; frame < inNumberFrames; frame++)
    {
        buffer[frame] = sin(theta) * amplitude;
        
        theta += theta_increment;
        if (theta > 2.0 * M_PI)
        {
            theta -= 2.0 * M_PI;
        }
    }
    
    // Store the theta back in the view controller
    vviewController->theta = theta;
    
    return noErr;
}

void ToneInterruptionListener(void *inClientData, UInt32 inInterruptionState)
{
    ViewController *vviewController =
    (__bridge ViewController *)inClientData;
    
    [vviewController stop];
}

@interface ViewController ()



@end

@implementation ViewController
@synthesize txt_server, txt_status, txt_channel, txt_id, txt_version
;
@synthesize scr_view;
@synthesize webview;
@synthesize sw_connect, sw_circuit, sw_sounder;
@synthesize enter_id, enter_channel;
@synthesize mybutton;

// connect to server and send my id.
- (void)
identifyclient
{
    tx_sequence++;
    id_packet.sequence = tx_sequence;

    NSData *cc = [NSData dataWithBytes:&connect_packet length:sizeof(connect_packet)];
    NSData *ii = [NSData dataWithBytes:&id_packet length:sizeof(id_packet)];

    [udpSocket sendData:cc toHost:host port:port withTimeout:-1 tag:tx_sequence];
    [udpSocket sendData:ii toHost:host port:port withTimeout:-1 tag:tx_sequence];
}


- (void)connectMorse
{
    NSLog(@"Connect to server");
    char hostname[64] = "mtc-kob.dyndns.org"; // FIXME - make global
    char port1[16] = "7890";
    
    char *id = (char *)[enter_id.text UTF8String];
    int channel = atoi([enter_channel.text UTF8String]);
    
    if (strcmp(id,"")==0 || channel == 0 || channel > MAX_CHANNEL) { 
        NSLog(@"Connect only with ID and channel");
        [self disconnectMorse];
        return;
    }
    
    prepare_id (&id_packet, id);
    prepare_tx (&tx_data_packet, id);
    connect_packet.channel = channel;
    
    txt_server.text = [NSString stringWithFormat:@"srv: %s:%s", hostname, port1];
    
    udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    
    NSError *error = nil;
    if (![udpSocket bindToPort:0 error:&error])
    {
        NSLog(@"error");
        return;
    }
    if (![udpSocket beginReceiving:&error])
    {
        NSLog(@"error");
        return;
    }
    
    [self identifyclient];
    
    // Start Keepalive timer
    myTimer = [NSTimer scheduledTimerWithTimeInterval: KEEPALIVE_CYCLE/100 target: self selector: @selector(sendkeepalive:) userInfo: nil repeats: YES];
    
    connect = CONNECTED;
}

- (void)disconnectMorse
{
    NSLog(@"Disconnect from server");
    // Stop keepalive timer
    [myTimer invalidate];
    txt_server.text = @"NONE";
    //udpSocket.finalize;
    connect = DISCONNECTED;
    [sw_connect setOn:false];
}

- (void)createToneUnit
{
    NSLog(@"Create tone Unit");
    // Configure the search parameters to find the default playback output unit
    // (called the kAudioUnitSubType_RemoteIO on iOS but
    // kAudioUnitSubType_DefaultOutput on Mac OS X)
    AudioComponentDescription defaultOutputDescription;
    defaultOutputDescription.componentType = kAudioUnitType_Output;
    defaultOutputDescription.componentSubType = kAudioUnitSubType_RemoteIO;
    defaultOutputDescription.componentManufacturer = kAudioUnitManufacturer_Apple;
    defaultOutputDescription.componentFlags = 0;
    defaultOutputDescription.componentFlagsMask = 0;
    
    // Get the default playback output unit
    AudioComponent defaultOutput = AudioComponentFindNext(NULL, &defaultOutputDescription);
    NSAssert(defaultOutput, @"Can't find default output");
    
    // Create a new unit based on this that we'll use for output
    OSErr err = AudioComponentInstanceNew(defaultOutput, &toneUnit);
    NSAssert1(toneUnit, @"Error creating unit: %hd", err);
    
    // Set our tone rendering function on the unit
    AURenderCallbackStruct input;
    input.inputProc = RenderTone;
    input.inputProcRefCon = (__bridge void *)(self);
    err = AudioUnitSetProperty(toneUnit,
                               kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input,
                               0,
                               &input,
                               sizeof(input));
    NSAssert1(err == noErr, @"Error setting callback: %hd", err);
    
    // Set the format to 32 bit, single channel, floating point, linear PCM
    const int four_bytes_per_float = 4;
    const int eight_bits_per_byte = 8;
    AudioStreamBasicDescription streamFormat;
    streamFormat.mSampleRate = sampleRate;
    streamFormat.mFormatID = kAudioFormatLinearPCM;
    streamFormat.mFormatFlags =
    kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    streamFormat.mBytesPerPacket = four_bytes_per_float;
    streamFormat.mFramesPerPacket = 1;
    streamFormat.mBytesPerFrame = four_bytes_per_float;
    streamFormat.mChannelsPerFrame = 1;
    streamFormat.mBitsPerChannel = four_bytes_per_float * eight_bits_per_byte;
    err = AudioUnitSetProperty (toneUnit,
                                kAudioUnitProperty_StreamFormat,
                                kAudioUnitScope_Input,
                                0,
                                &streamFormat,
                                sizeof(AudioStreamBasicDescription));
    NSAssert1(err == noErr, @"Error setting stream format: %hd", err);
}

- (void)inittone
{
    NSLog(@"Starting tone Unit");

    sampleRate = 44100;
    frequency = 800;

    [self createToneUnit];
    
    // Stop changing parameters on the unit
    OSErr err = AudioUnitInitialize(toneUnit);
    NSAssert1(err == noErr, @"Error initializing unit: %hd", err); // FIXME: we can use this for other quality stuff
}

- (void)stoptone
{
    NSLog(@"Stopping tone Unit");
    if (!toneUnit) return;
    AudioOutputUnitStop(toneUnit);
    AudioUnitUninitialize(toneUnit);
    AudioComponentInstanceDispose(toneUnit);
    toneUnit = nil;
}

- (void)beep:(double)duration_ms
{
    if (!toneUnit) [self inittone];

    if (sounder == true)
    {
        [self play_click];
        usleep(abs(duration_ms)*1000.);
        [self play_clack];
    }
    else
    {
        OSErr err = AudioOutputUnitStart(toneUnit);
        NSAssert1(err == noErr, @"Error starting unit: %hd", err);
        usleep(abs(duration_ms)*1000.);
        AudioOutputUnitStop(toneUnit);
    }
}

- (void)initCWvars
{
    NSLog(@"Init CW Vars");
    connect_packet.channel = DEFAULT_CHANNEL;
    connect_packet.command = CON;
    disconnect_packet.channel = 0;
    disconnect_packet.command = DIS;
    tx_sequence = 0;
    last_message = 0;
    tx_timeout = 0;
    last_message = 0;
    circuit = LATCHED;
    connect = DISCONNECTED;
    
    host = @"mtc-kob.dyndns.org";
    port = 7890;

    // init id selector
    enter_id.placeholder = @"iOS/DG6FL, intl. Morse";
    enter_channel.placeholder = @"33";
    
    sounder = false;
}

// This method is called once we click inside the textField
-(void)textFieldDidBeginEditing:(UITextField *)ff{
#ifdef DEBUG
    NSLog(@"Text field did begin editing");
#endif
    [self disconnectMorse];
}

// This method is called once we complete editing
-(void)textFieldDidEndEditing:(UITextField *)ff{
#ifdef DEBUG
    NSLog(@"Text field ended editing");
#endif
    [sw_connect setOn:true];
    [self connectMorse];
}

// This method enables or disables the processing of return key
-(BOOL) textFieldShouldReturn:(UITextField *)ff{
    [ff resignFirstResponder];
    return YES;
}

- (void)switchcircuit
{
    if (circuit == LATCHED)
    {
        [self unlatch];
    }
    else
    {
        [self latch];
    }
}

-(void) switchconnect
{
    if (connect == CONNECTED)
    {
        [self disconnectMorse];
    }
    else
    {
        [self connectMorse];
    }
}

-(void) switchsounder
{
    NSLog(@"switch sounder");
    if (sounder == true)
    {
        sounder = false;
        UIImage *image2 = [UIImage imageNamed:@"key.png"];
        [mybutton setBackgroundImage:image2 forState:UIControlStateNormal];
    }
    else
    {
        sounder = true;
        UIImage *image2 = [UIImage imageNamed:@"kob2.png"];
        [mybutton setBackgroundImage:image2 forState:UIControlStateNormal];
    }
}

- (void)viewDidLoad {
    NSLog(@"Load View");
    
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
#pragma GCC diagnostic push // I know that this does not work!
#pragma GCC diagnostic ignored "-Wdeprecated"
    OSStatus result = AudioSessionInitialize(NULL, NULL, ToneInterruptionListener, (__bridge void *)(self));
    if (result == kAudioSessionNoError)
    {
        UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
        AudioSessionSetProperty(kAudioSessionProperty_AudioCategory, sizeof(sessionCategory), &sessionCategory);
    }
    
    // set the buffer duration to 5 ms
    // set preferred buffer size
    Float32 preferredBufferSize = 5./1000.; // in seconds
    result = AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration, sizeof(preferredBufferSize), &preferredBufferSize);
    
    // get actuall buffer size
    Float32 audioBufferSize;
    UInt32 size = sizeof (audioBufferSize);
    result = AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareIOBufferDuration, &size, &audioBufferSize);
    
    AudioSessionSetActive(true);
#pragma GCC diagnostic pop

    // Key text button
    UIImage *image2 = [UIImage imageNamed:@"key.png"];
    [mybutton setBackgroundImage:image2 forState:UIControlStateNormal];
    [mybutton addTarget:self action:@selector(buttonIsDown) forControlEvents:UIControlEventTouchDown];
    [mybutton addTarget:self action:@selector(buttonWasReleased) forControlEvents:UIControlEventTouchUpInside];
    
    // (Un-)Latch text switch
    [sw_circuit addTarget:self action:@selector(switchcircuit) forControlEvents:UIControlEventValueChanged];

    // Connect to server switch
    [sw_connect addTarget:self action:@selector(switchconnect) forControlEvents:UIControlEventValueChanged];
    [sw_connect setOn:false];
    
    // sounder switch
    [sw_sounder addTarget:self action:@selector(switchsounder) forControlEvents:UIControlEventValueChanged];
    [sw_sounder setOn:false];
    
    // initialize vars
    [self initCWvars];
    [self inittone];
    [self displaywebstuff];
#ifdef EXT_KEY
    [self beep:(1000)];
#endif
    
    enter_id.delegate = self;
    enter_channel.delegate = self;

#ifdef SCROLLVIEWLOG
    scr_view.editable = false;
    scr_view.text = @" ";
    scr_view.scrollEnabled = true;
#endif
    NSString * appVersionString = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString * appBuildString = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"];

    txt_version.text = [NSString stringWithFormat:@"Version: %@ (%@)", appVersionString, appBuildString];
}


-(void)displaywebstuff
{
    NSString *urlAddress = @"http://mtc-kob.dyndns.org";
    NSURL *url = [NSURL URLWithString:urlAddress];
    NSURLRequest *requestObj = [NSURLRequest requestWithURL:url];
    [webview loadRequest:requestObj];
}

- (void) message:(int) msg
{
    switch(msg){
        case 1:
            if(last_message == msg) return;
            if(last_message == 2) NSLog(@"\n");
            last_message = msg;
            txt_status.text =[NSString stringWithFormat:@"Transmitting\n"];
            break;
        case 2:
            if(last_message == msg && strncmp(last_sender, rx_data_packet.id, 3) == 0) return;
            else {
                if(last_message == 2) NSLog(@"\n");
                last_message = msg;
                strncpy(last_sender, rx_data_packet.id, 3);
                txt_status.text = [NSString stringWithFormat:@"recv: (%s).\n",rx_data_packet.id];
            }
            break;
        case 3:
            txt_status.text = [NSString stringWithFormat:@"latched by %s.\n",rx_data_packet.id];
            break;
        case 4:
            txt_status.text = [NSString stringWithFormat:@"unlatched by %s.\n",rx_data_packet.id];
            break;
        default:
            break;
    }
#ifdef SCROLLVIEWLOG
    scr_view.text = [txt_status.text stringByAppendingString:scr_view.text];
#endif
}


-(BOOL) playSoundFXnamed: (NSString*) vSFXName Loop: (BOOL) vLoop
{
    NSError *error;
    NSBundle* bundle = [NSBundle mainBundle];
    NSString* bundleDirectory = (NSString*)[bundle bundlePath];
    NSURL *url = [NSURL fileURLWithPath:[bundleDirectory stringByAppendingPathComponent:vSFXName]];
    AVAudioPlayer *audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&error];
    
    if(vLoop)
        audioPlayer.numberOfLoops = -1;
    else
        audioPlayer.numberOfLoops = 0;
    
    BOOL success = YES;
    
    if (audioPlayer == nil)
    {
        success = NO;
        NSLog(@"no");
    }
    else
    {
        success = [audioPlayer play];
        NSLog(@"yes");
    }
    return success;
}


- (void)play_clack
{
    NSLog(@"play clack");
    SystemSoundID completeSound;
    NSURL *audioPath = [[NSBundle mainBundle] URLForResource:@"clack48" withExtension:@"wav"];
    AudioServicesCreateSystemSoundID((__bridge CFURLRef)audioPath, &completeSound);
    AudioServicesPlaySystemSound (completeSound);
}
- (void)play_click
{
    NSLog(@"play click");
    SystemSoundID completeSound;
    NSURL *audioPath = [[NSBundle mainBundle] URLForResource:@"click48" withExtension:@"wav"];
    AudioServicesCreateSystemSoundID((__bridge CFURLRef)audioPath, &completeSound);
    AudioServicesPlaySystemSound (completeSound);
}

- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data
      fromAddress:(NSData *)address
withFilterContext:(id)filterContext
{
    int i;
    int translate = 0;
    int audio_status = 1;
    
    [data getBytes:&rx_data_packet length:sizeof(rx_data_packet)];
#ifdef DEBUG_NET
    NSLog(@"length: %i\n", rx_data_packet.length);
    NSLog(@"id: %s\n", rx_data_packet.id);
    NSLog(@"sequence no.: %i\n", rx_data_packet.sequence);
    NSLog(@"version: %s\n", rx_data_packet.status);
    NSLog(@"n: %i\n", rx_data_packet.n);
    NSLog(@"code:\n");
    for(i = 0; i < SIZE_CODE; i++)NSLog(@"%i ", rx_data_packet.code[i]); NSLog(@"\n");
#endif
    txt_status.text = [NSString stringWithFormat:@"recv from: %s\n", rx_data_packet.id];
#ifdef SCROLLVIEWLOG
    scr_view.text = [txt_status.text stringByAppendingString:scr_view.text];
#endif
        if(rx_data_packet.n > 0 && rx_sequence != rx_data_packet.sequence){
            [self message:2];
            if(translate == 1){
                txt_status.text = [NSString stringWithFormat:@"%s\n",rx_data_packet.status];
#ifdef SCROLLVIEWLOG
                scr_view.text = [txt_status.text stringByAppendingString:scr_view.text];
#endif
            }
            rx_sequence = rx_data_packet.sequence;
            for(i = 0; i < rx_data_packet.n; i++){
                switch(rx_data_packet.code[i]){
                    case 1:
                        [self message:3];
                        break;
                    case 2:
                        [self message:4];
                        break;
                    default:
                        if(audio_status == 1)
                        {
                            int length = rx_data_packet.code[i];
                            if(length == 0 || abs(length) > 2000) { // FIXME: magic number
                            }
                            else
                            {
                                if(length < 0) {
                                    usleep(abs(length)*1000.); // pause
                                }
                                else
                                {
                                    [self beep:(abs(length))];
                                }
                            }
                        }
                        break;
                }
            }
        }
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)stop
{
    [self disconnectMorse];
    [self stoptone];
}

- (void)viewDidUnload {
    [self stop];
    AudioSessionSetActive(false);
    
}

- (void)viewDidAppear:(BOOL)animated {
}

- (void)viewWillDisappear:(BOOL)animated
{
}

/* portable time, as listed in https://gist.github.com/jbenet/1087739  */
void current_utc_time(struct timespec *ts) {
    clock_serv_t cclock;
    mach_timespec_t mts;
    host_get_clock_service(mach_host_self(), CALENDAR_CLOCK, &cclock);
    clock_get_time(cclock, &mts);
    mach_port_deallocate(mach_task_self(), cclock);
    ts->tv_sec = mts.tv_sec;
    ts->tv_nsec = mts.tv_nsec;
}
/* a better clock() in milliseconds */
long
fastclock(void)
{
    struct timespec t;
    long r;
    
    current_utc_time (&t);
    r = t.tv_sec * 1000;
    r = r + t.tv_nsec / 1000000;
    return r;
}

-(void)buttonIsDown
{
    key_press_t1 = fastclock();

    if (sounder == true)
        [self play_click];
    else
        AudioOutputUnitStart(toneUnit);
    
    tx_timeout = 0;
    int timing = (int) ((key_press_t1 - key_release_t1) * -1); // negative timing
    if (timing > TX_WAIT) timing = TX_WAIT; // limit to timeout
    tx_data_packet.n++;
    tx_data_packet.code[tx_data_packet.n - 1] = timing;
#ifdef DEBUG_TX
    NSLog(@"timing: %d", timing);
#endif
    [self message:1];
}

-(void)buttonWasReleased
{
    key_release_t1 = fastclock();
    if (sounder == true)
        [self play_clack];
    else
        AudioOutputUnitStop(toneUnit);

    
    int timing =(int) ((key_release_t1 - key_press_t1) * 1); // positive timing
    if (abs(timing) > TX_WAIT) timing = -TX_WAIT; // limit to timeout FIXME this is the negative part
    if (tx_data_packet.n == SIZE_CODE) NSLog(@"warning: packet is full");
    tx_data_packet.n++;
    tx_data_packet.code[tx_data_packet.n - 1] = timing;
#ifdef DEBUG_TX
    NSLog(@"timing: %d", timing);
#endif

    
    //NSLog(@"mark: %i\n", tx_data_packet.code[tx_data_packet.n -1]);
    /* TBD = TIMEOUT FOR keypress maximal 5 seconds
    while(1){
        ioctl(fd_serial, TIOCMGET, &serial_status);
        if(serial_status & TIOCM_DSR) break;
        tx_timeout = fastclock() - key_release_t1;
        if(tx_timeout > TX_TIMEOUT) return;
    }
    key_press_t1 = fastclock();
    if(tx_data_packet.n == SIZE_CODE) {
        NSLog(@"irmc: warning packet is full.\n");
        return;
    }
*/
    [self send_data];
    [self send_tx_packet]; // FIXME: why run the code below, if we can send right now?
}


-(void) send_data
{
#ifdef DEBUG_TX
    NSLog(@"Send udp data");
#endif
    //if (tx_data_packet.code[0]>0) return; // assert first pause

    //if(tx_data_packet.n == 2 ) {NSLog(@"tx_data.n eq 2");return;} // assert only two packages // FIXME??
    if (tx_data_packet.n <= 1) {return;}
    
    tx_sequence++;
    tx_data_packet.sequence = tx_sequence;

    [self send_tx_packet];
    tx_data_packet.n = 0;
}

- (void) send_tx_packet
{
    int i;
    NSData *cc = [NSData dataWithBytes:&tx_data_packet length:sizeof(tx_data_packet)];
    for(i = 0; i < 2; i++) [udpSocket sendData:cc toHost:host port:port withTimeout:-1 tag:tx_sequence];
#ifdef DEBUG_NET
    NSLog(@"sent seq %d n %d (%d,%d).", tx_sequence, tx_data_packet.n,
          tx_data_packet.code[0] ,
          tx_data_packet.code[1]
          );
#endif
}


- (void)latch
{
    NSLog(@"latch");

    tx_sequence++; // FIXME: This is a special packet an can go into networking.
    tx_data_packet.sequence = tx_sequence;
    tx_data_packet.code[0] = -1;
    tx_data_packet.code[1] = 1;
    tx_data_packet.n = 2;
    
    [self send_tx_packet];
    
    tx_data_packet.n = 0;
    circuit = LATCHED;
    [self play_click];

#ifdef NOTIFICATIONS //TODO not implemented yet
    //[ postNotification:@"Hello World"];
#endif
}


-(void) unlatch
{
    NSLog(@"unlatch");

    tx_sequence++;
    tx_data_packet.sequence = tx_sequence;
    tx_data_packet.code[0] = -1;
    tx_data_packet.code[1] = 2;
    tx_data_packet.n = 2;
    
    [self send_tx_packet];
    
    tx_data_packet.n = 0;
    
    circuit = UNLATCHED;
    [self play_clack];
}

-(void) sendkeepalive:(NSTimer*)t
{
#ifdef DEBUG_NET
    NSLog(@"Keepalive");
#endif
    [self identifyclient];
}

-(void) calli
{
    NSLog(@"Calli");
}


 // TODO: Bluetooth serial support? http://www.adafruit.com/products/1697

#ifdef EXT_KEY
/*
 1(Tip) - Key (Masse)
 2 - Ear (Kontakt)
 3 - Ear (Masse)
 4(Masse) - R2(46,6k ge-br?-sw-rt-br) - Key 1
 4(Masse) - R3(22k br-rt-sw-rt-rt) - Key 2
 4(Masse) - R1(1k br-sw-sw-br-br) - 3
 
 (1) left earphone (tip), (2) right earphone (ring), (3) com- mon/ground (ring), and (4) microphone (sleeve)
 
 
 https://web.eecs.umich.edu/~prabal/pubs/papers/kuo10hijack.pdf
 
 
 ton auf kanal -> empfange lautstärke -> an / aus
 */
#endif

@end
