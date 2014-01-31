//
//  BoatMessaging.m
//  ShipMessaging
//
//  Created by iolate on 2014. 1. 28..
//  Copyright (c) 2014년 iolate. All rights reserved.
//

#include <mach/mach.h>
#include <mach/mach_init.h>
#include "rocketbootstrap.h"

#import "BoatMessaging.h"

#pragma mark - Private

#define __BMachMaxInlineSize 4096 + sizeof(BMachMessage)
typedef struct __BMachMessage {
	mach_msg_header_t head;
	mach_msg_body_t body;
	union {
		struct {
			mach_msg_ool_descriptor_t descriptor;
		} out_of_line;
		struct {
			uint32_t length;
			uint8_t bytes[0];
		} in_line;
	} data;
} BMachMessage;

typedef struct __BMachResponseBuffer {
	BMachMessage message;
	uint8_t slack[__BMachMaxInlineSize - sizeof(BMachMessage) + MAX_TRAILER_SIZE];
} BMachResponseBuffer;

bool BMachMessageIsValid(const void *data, CFIndex size)
{
	if (size < sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t))
		return false;
	const BMachMessage *message = (const BMachMessage *)data;
	if (message->body.msgh_descriptor_count)
		return size >= sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) + sizeof(mach_msg_ool_descriptor_t);
	if (size < sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) + sizeof(uint32_t))
		return false;
	if (size < sizeof(mach_msg_header_t) + sizeof(mach_msg_body_t) + sizeof(uint32_t) + message->data.in_line.length)
		return false;
	return true;
}

uint32_t BMachBufferSizeForLength(uint32_t length)
{
	if (length + sizeof(BMachMessage) > __BMachMaxInlineSize)
		return sizeof(BMachMessage);
	else
		return ((sizeof(BMachMessage) + length) + 3) & ~0x3;
}

uint32_t BMachMessageGetDataLength(BMachMessage *message)
{
	if (message->body.msgh_descriptor_count)
		return message->data.out_of_line.descriptor.size;
    
	uint32_t result = message->data.in_line.length;
	if (result > __BMachMaxInlineSize - offsetof(BMachMessage, data.in_line.bytes))
		return __BMachMaxInlineSize - offsetof(BMachMessage, data.in_line.bytes);
    
	return result;
}

CFDataRef BMachMessageGetData(BMachMessage* message) {
    const void *data;
    size_t length = BMachMessageGetDataLength(message);
    
    if (message->body.msgh_descriptor_count) {
		data = message->data.out_of_line.descriptor.address;
    } else if (message->data.in_line.length == 0) {
        data = NULL;
    } else {
        data = &message->data.in_line.bytes;
    }
    
    CFDataRef cfdata = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, data ?: &data, length, kCFAllocatorNull);
    return cfdata;
}

void BMachMessageAssignData(BMachMessage *message, const void *data, uint32_t length)
{
	if (length == 0) {
		message->body.msgh_descriptor_count = 0;
		message->data.in_line.length = length;
	} else if (message->head.msgh_size != sizeof(BMachMessage)) {
		message->body.msgh_descriptor_count = 0;
		message->data.in_line.length = length;
		memcpy(message->data.in_line.bytes, data, length);
	} else {
        //AssignOutOfLine
		message->head.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
        message->body.msgh_descriptor_count = 1;
        message->data.out_of_line.descriptor.type = MACH_MSG_OOL_DESCRIPTOR;
        message->data.out_of_line.descriptor.copy = MACH_MSG_VIRTUAL_COPY;
        message->data.out_of_line.descriptor.deallocate = false;
        message->data.out_of_line.descriptor.address = (void *)data;
        message->data.out_of_line.descriptor.size = length;
	}
}

void BMachResponseBufferFree(BMachResponseBuffer *responseBuffer)
{
	if (responseBuffer->message.body.msgh_descriptor_count != 0 && responseBuffer->message.data.out_of_line.descriptor.type == MACH_MSG_OOL_DESCRIPTOR) {
		vm_deallocate(mach_task_self(), (vm_address_t)responseBuffer->message.data.out_of_line.descriptor.address, responseBuffer->message.data.out_of_line.descriptor.size);
		responseBuffer->message.body.msgh_descriptor_count = 0;
	}
}

NSDictionary* BMachMResponseToDictionary(BMachResponseBuffer *buffer)
{
	uint32_t length = BMachMessageGetDataLength(&buffer->message);
	id result = nil;
	if (length) {
		CFDataRef data = BMachMessageGetData(&buffer->message);
		result = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
		CFRelease(data);
	}
	BMachResponseBufferFree(buffer);
    
    if (![result isKindOfClass:[NSDictionary class]]) {
        return @{@"UnknownType": result};
    }
    
	return result;
}

mach_msg_return_t BMachSendMessage(mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send_size, mach_msg_size_t rcv_size, mach_port_name_t rcv_name, mach_msg_timeout_t timeout) {
    
    for (;;) {
		kern_return_t err = mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, MACH_PORT_NULL);
		if (err != MACH_SEND_INVALID_DEST)
			return err;
		mach_port_deallocate(mach_task_self(), msg->msgh_remote_port);
    }
}

static void machCallback(CFMachPortRef port, void *bytes, CFIndex size, void *info) {
    if (!BMachMessageIsValid(bytes, size)) {
        return;
    }
    
    BMachMessage* message = bytes;
    NSData* data = (__bridge NSData*)BMachMessageGetData(message);
    BMachMessageType type = message->head.msgh_id;
    BoatMessagingCallBack callback = info;
    NSDictionary* dic = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:0 format:NULL errorDescription:NULL];
    
    if (type == BMachClientConnect) {
        mach_port_t client_port = message->head.msgh_remote_port;
        NSString* bundleId = dic[@"bundleId"];
        NSDictionary* userInfo = dic[@"userInfo"] ?: nil;
        NSDictionary* dic = userInfo ? @{@"bundleId": bundleId, @"port": [NSNumber numberWithUnsignedInt:client_port], @"userInfo": userInfo} : @{@"bundleId": bundleId, @"port": [NSNumber numberWithUnsignedInt:client_port]};
        callback(port, type, dic);
    }else if (type == BMachOneWayMessage) {
        
        
        callback(port, type, dic);
    }else if (type == BMachTwoWayMessage) {
        mach_port_t reply_port = message->head.msgh_remote_port;
        if (reply_port == MACH_PORT_NULL) return;
        
        NSDictionary* reply = callback(port, type, dic);
        
        NSData* nsData = reply ? [NSPropertyListSerialization dataFromPropertyList:reply format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL] : nil;
        
        const void* data = nsData ? [nsData bytes] : NULL;
        uint32_t length = nsData ? (uint32_t)[nsData length] : 0;
        
        uint32_t size = BMachBufferSizeForLength(length);
        uint8_t buffer[size];
        memset(buffer, 0, sizeof(BMachMessage));
        BMachMessage *response = (BMachMessage *)&buffer[0];
        response->head.msgh_id = 0;
        response->head.msgh_size = size;
        response->head.msgh_remote_port = reply_port;
        response->head.msgh_local_port = MACH_PORT_NULL;
        response->head.msgh_reserved = 0;
        response->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
        BMachMessageAssignData(response, data, length);
        // Send message
        kern_return_t err = mach_msg(&response->head, MACH_SEND_MSG, size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (err) {
            // Cleanup leaked SEND_ONCE
            mach_port_mod_refs(mach_task_self(), reply_port, MACH_PORT_RIGHT_SEND_ONCE, -1);
        }
    }
    
    [data release];
}

#pragma mark -

CFMachPortRef BoatMessagingStartServer(NSString* serverName, BoatMessagingCallBack callback) {
    mach_port_t bootstrap = MACH_PORT_NULL;
	task_get_bootstrap_port(mach_task_self(), &bootstrap);
	CFMachPortContext context = { 0, callback, NULL, NULL, NULL };
    CFMachPortRef machPort = CFMachPortCreate(kCFAllocatorDefault, machCallback, &context, NULL);
    CFRunLoopSourceRef machPortSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), machPortSource, kCFRunLoopCommonModes);
	mach_port_t port = CFMachPortGetPort(machPort);
    
    const char* utf8String = [serverName UTF8String];
    size_t len = strlen(utf8String) + 1;
    char server_name[len];
    memcpy(server_name, utf8String, len);
    
    rocketbootstrap_unlock(server_name);
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    bootstrap_register(bootstrap, server_name, port);
#pragma GCC diagnostic warning "-Wdeprecated-declarations"
    
    return machPort;
}

void BoatMessagingInvalidatePort(CFMachPortRef machPort) {
    if (machPort == NULL) return;
    
    if (CFMachPortIsValid(machPort)) {
        CFMachPortInvalidate(machPort);
    }
}

BOOL BoatMessagingPortIsValid(mach_port_t port) {
    if (port == MACH_PORT_NULL) return NO;
    
    CFMachPortRef machPort = CFMachPortCreateWithPort(kCFAllocatorDefault, port, NULL, NULL, NULL);
    if (machPort == nil) return NO;
    
    BOOL valid = CFMachPortIsValid(machPort);
    
    CFRelease(machPort);
    
    return valid;
}

mach_port_t BoatMessagingGetServerPort(NSString* serverName) {
    mach_port_t selfTask = mach_task_self();
    
    // Lookup remote port
    mach_port_t bootstrap = MACH_PORT_NULL;
    task_get_bootstrap_port(selfTask, &bootstrap);
    
    const char* utf8String = [serverName UTF8String];
    size_t len = strlen(utf8String) + 1;
    char server_name[len];
    memcpy(server_name, utf8String, len);
    
    mach_port_t server_port = MACH_PORT_NULL;
    
    if (rocketbootstrap_look_up(bootstrap, server_name, &server_port))
        return MACH_PORT_NULL;
    
    return server_port;
}

CFMachPortRef BoatMessagingClientConnectToServer(NSString* serverName, BoatMessagingCallBack callback, NSDictionary* userInfo) {
    mach_port_t server_port = BoatMessagingGetServerPort(serverName);
    if (server_port == MACH_PORT_NULL)
        return NULL;
    
    mach_port_t bootstrap = MACH_PORT_NULL;
	task_get_bootstrap_port(mach_task_self(), &bootstrap);
	CFMachPortContext context = { 0, callback, NULL, NULL, NULL };
    CFMachPortRef machPort = CFMachPortCreate(kCFAllocatorDefault, machCallback, &context, NULL);
    CFRunLoopSourceRef machPortSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), machPortSource, kCFRunLoopCommonModes);
	mach_port_t port = CFMachPortGetPort(machPort);
    
    NSString* bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    
    NSDictionary* dic = userInfo ? @{@"bundleId": bundleIdentifier, @"userInfo": userInfo} : @{@"bundleId": bundleIdentifier};
    
    NSData* nsData = [NSPropertyListSerialization dataFromPropertyList:dic format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
    
    const void* data = [nsData bytes];
    uint32_t length = (uint32_t)[nsData length];
    // Send message
	uint32_t size = BMachBufferSizeForLength(length);
    uint8_t buffer[size];
	BMachMessage *message = (BMachMessage *)&buffer[0];
	memset(message, 0, sizeof(BMachMessage));
	message->head.msgh_id = BMachClientConnect;
	message->head.msgh_size = size;
	message->head.msgh_local_port = port;
    message->head.msgh_remote_port = server_port;
	message->head.msgh_reserved = 0;
	message->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND);
	BMachMessageAssignData(message, data, length);
    
    kern_return_t err = BMachSendMessage(&message->head, MACH_SEND_MSG, size, 0, port, MACH_MSG_TIMEOUT_NONE);
    if (err) {
        CFRelease(machPort);
        return NULL;
    }
    
    return machPort;
}

BOOL BoatMessagingSendMessage(mach_port_t port, NSDictionary* contents) {
    if (contents == nil)
        return NO;
    
    if (port == MACH_PORT_NULL) return NO;
    
    NSData *nsData = [NSPropertyListSerialization dataFromPropertyList:contents format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
    
    const void* data = [nsData bytes];
    uint32_t length = (uint32_t)[nsData length];
    
    uint32_t size = BMachBufferSizeForLength(length);
    int8_t buffer[size];
	BMachMessage *message = (BMachMessage *)&buffer[0];
	memset(message, 0, sizeof(BMachMessage));
	message->head.msgh_id = BMachOneWayMessage;
	message->head.msgh_size = size;
	message->head.msgh_local_port = MACH_PORT_NULL;
    message->head.msgh_remote_port = port;
	message->head.msgh_reserved = 0;
	message->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
	BMachMessageAssignData(message, data, length);
    
    kern_return_t err = BMachSendMessage(&message->head, MACH_SEND_MSG, size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE);
    if (err)
        return NO;
    
    return YES;
}

NSDictionary* BoatMessagingSendMessageWithReply(mach_port_t remote_port, NSDictionary* contents) {
    if (contents == nil) return nil;
    if (remote_port == MACH_PORT_NULL) return nil;
    
    BMachResponseBuffer response;
    BMachResponseBuffer* responseBuffer = &response;
    
    mach_port_t selfTask = mach_task_self();
	mach_port_name_t replyPort = MACH_PORT_NULL;
	int err = mach_port_allocate(selfTask, MACH_PORT_RIGHT_RECEIVE, &replyPort);
	if (err) {
		responseBuffer->message.body.msgh_descriptor_count = 0;
		return nil;
	}
    
    NSData *nsData = [NSPropertyListSerialization dataFromPropertyList:contents format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
    
    const void* data = [nsData bytes];
    uint32_t length = (uint32_t)[nsData length];
    
    uint32_t size = BMachBufferSizeForLength(length);
    BMachMessage *message = &responseBuffer->message;
	memset(message, 0, sizeof(BMachMessage));
	message->head.msgh_id = BMachTwoWayMessage;
	message->head.msgh_size = size;
	message->head.msgh_local_port = replyPort;
    message->head.msgh_remote_port = remote_port;
	message->head.msgh_reserved = 0;
	message->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	BMachMessageAssignData(message, data, length);
    
    err = BMachSendMessage(&message->head, MACH_SEND_MSG | MACH_RCV_MSG | MACH_SEND_TIMEOUT | MACH_SEND_INTERRUPT | MACH_RCV_TIMEOUT | MACH_RCV_INTERRUPT, size, sizeof(BMachResponseBuffer), replyPort, 2000); //MACH_MSG_TIMEOUT_NONE
    if (err) {
        responseBuffer->message.body.msgh_descriptor_count = 0;
        return nil;
    }
    
    mach_port_deallocate(selfTask, replyPort);
    
    return BMachMResponseToDictionary(responseBuffer);
}
