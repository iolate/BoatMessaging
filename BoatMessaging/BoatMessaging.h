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
     BMachClientConnect @{ @"bundleId": NSString*, @"port": mach_port_t, @"userInfo": NSDictionary }
     */
    typedef NSDictionary* (*BoatMessagingCallBack) (CFMachPortRef machPort, BMachMessageType type, NSDictionary* contents);
    
    CFMachPortRef BoatMessagingStartServer(NSString* serverName, BoatMessagingCallBack callback);
    mach_port_t BoatMessagingGetServerPort(NSString* serverName);
    BOOL BoatMessagingPortIsValid(mach_port_t port);
    
    CFMachPortRef BoatMessagingClientConnectToServer(NSString* serverName, BoatMessagingCallBack callback, NSDictionary* userInfo);
    
    //Reply timeout: 2 seconds
    NSDictionary* BoatMessagingSendMessageWithReply(mach_port_t port, NSDictionary* contents);
    BOOL BoatMessagingSendMessage(mach_port_t port, NSDictionary* contents);
    
    void BoatMessagingInvalidatePort(CFMachPortRef machPort);
    
#ifdef __cplusplus
} // extern "C"
#endif

/*
 
 void machInvalidationCallback(CFMachPortRef port, void *info) { }
 CFMachPortRef machPort = CFMachPortCreateWithPort(kCFAllocatorDefault, port, NULL, NULL, NULL);
 CFMachPortSetInvalidationCallBack(machPort, machInvalidationCallback);
 
 */