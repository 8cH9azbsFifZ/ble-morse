//
//  ViewController.h
//  Morse
//
//  Created by Dr. Gerolf Ziegenhain on 05.01.15.
//  Copyright (c) 2015 Dr. Gerolf Ziegenhain. All rights reserved.
//
// icons:   

#import <UIKit/UIKit.h>
#import <AudioUnit/AudioUnit.h>
#include "cwprotocol.h"
#include "GCDAsyncUdpSocket.h"

#define TX_WAIT  5000
#define TX_TIMEOUT 240.0
#define KEEPALIVE_CYCLE 100 //msec
#define NUMSEND 5

#define MAXDATASIZE 1024 // max number of bytes we can get at once
#define LATCHED 0
#define UNLATCHED 1
#define CONNECTED 0
#define DISCONNECTED 1

@interface ViewController : UIViewController
{
    UILabel *frequencyLabel;
    UIButton *playButton;
    UISlider *frequencySlider;
    AudioComponentInstance toneUnit;
    
@public
    double frequency;
    double sampleRate;
    double theta;
    int fd_socket;
    NSTimer*  myTimer;
    struct command_packet_format connect_packet;
    struct command_packet_format disconnect_packet;
    struct data_packet_format id_packet;
    struct data_packet_format rx_data_packet;
    struct data_packet_format tx_data_packet;
    
    // server connecting
    NSString *host;
    int port;

    int tx_sequence, rx_sequence;
    long tx_timer;

    // message queues
    int last_message;
    char last_sender[16];
    
    // Networking
    GCDAsyncUdpSocket *udpSocket;
    
    // sending
    long key_press_t1;
    long key_release_t1;
    long tx_timeout;
    
    int circuit;
    int connect;
    BOOL sounder;
}

@property (weak, nonatomic) IBOutlet UISwitch *sw_connect;
@property (weak, nonatomic) IBOutlet UISwitch *sw_circuit;
@property (weak, nonatomic) IBOutlet UISwitch *sw_sounder;

@property (strong, nonatomic) IBOutlet UITextField *enter_id;
@property (strong, nonatomic) IBOutlet UITextField *enter_channel;

@property (strong, nonatomic) IBOutlet UITextView *scr_view;
@property (weak, nonatomic) IBOutlet UIButton *mybutton;

@property (weak, nonatomic) IBOutlet UILabel *txt_server;
@property (weak, nonatomic) IBOutlet UILabel *txt_status;
@property (weak, nonatomic) IBOutlet UILabel *txt_channel;
@property (weak, nonatomic) IBOutlet UILabel *txt_id;
@property (weak, nonatomic) IBOutlet UILabel *txt_version;

@property (weak, nonatomic) IBOutlet UIWebView *webview;

- (void)beep:(double)duration_ms;
- (void)stop;
- (void)connectMorse;
- (void)disconnectMorse;
- (void)message:(int)msg;
- (void)identifyclient;
- (void)initCWvars;

@end
