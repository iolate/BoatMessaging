//
//  BoatMessaging.h
//  ShipMessaging
//
//  Created by iolate on 2014. 1. 28..
//  Copyright (c) 2014년 iolate. All rights reserved.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif
    
    typedef enum {
        BMachClientConnect = 1,
        BMachOneWayMessage,
        BMachTwoWayMessage
    } BMachMessageType;
    
    /*
     BMachClientConnect @{ @"BundleId": NSString*, @"port": mach_port_t }
     */
    typedef NSDictionary* (*BoatMessagingCallBack) (CFMachPortRef machPort, BMachMessageType type, NSDictionary* contents);
    
    CFMachPortRef BoatMessagingStartServer(NSString* serverName, BoatMessagingCallBack callback);
    BOOL BoatMessagingServerSendMessages(mach_port_t port, NSDictionary* contents);
    //Reply timeout: 2 seconds
    NSDictionary* BoatMessagingServerSendMessagesWithReply(mach_port_t port, NSDictionary* contents);
    
    BOOL BoatMessagingClientConnectToServer(NSString* serverName, BoatMessagingCallBack callback);
    BOOL BoatMessagingClientSendMessages(NSString* serverName, NSDictionary* contents);
    //Reply timeout: 2 seconds
    NSDictionary* BoatMessagingClientSendMessagesWithReply(NSString* serverName, NSDictionary* contents);
    
#ifdef __cplusplus
} // extern "C"
#endif

/*
 
 void machInvalidationCallback(CFMachPortRef port, void *info) { }
 CFMachPortRef machPort = CFMachPortCreateWithPort(kCFAllocatorDefault, port, NULL, NULL, NULL);
 CFMachPortSetInvalidationCallBack(machPort, machInvalidationCallback);
 
 */