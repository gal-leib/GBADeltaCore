//
//  GBAEmulatorBridge.h
//  GBADeltaCore
//
//  Created by Riley Testut on 6/3/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//
#pragma once

#import <Foundation/Foundation.h>

@protocol DLTAEmulatorBridging;

NS_ASSUME_NONNULL_BEGIN

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything" // Silence "Cannot find protocol definition" warning due to forward declaration.
@interface GBAEmulatorBridge : NSObject <DLTAEmulatorBridging>
#pragma clang diagnostic pop

@property (class, nonatomic, readonly) GBAEmulatorBridge *sharedBridge;

// Wireless Adapter (RFU) WAN Relay methods
@property (nonatomic, readonly) BOOL isWirelessActive;
@property (nonatomic, readonly) BOOL isWirelessAdapterConnected;
@property (nonatomic, copy, nullable) void (^wirelessSendDatagramHandler)(NSData *datagram);

- (BOOL)startWirelessWithHost:(BOOL)isHost sessionId:(uint64_t)sessionId;
- (void)stopWireless;
- (void)receiveWirelessDatagram:(NSData *)datagram;
- (nullable NSData *)generateWirelessDiscoveryProbe;
- (void)getWirelessStatsWithSessionId:(nullable uint64_t *)sessionId
                        sessionActive:(nullable BOOL *)sessionActive
                     adapterConnected:(nullable BOOL *)adapterConnected
                      retransmissions:(nullable uint64_t *)retransmissions
                        parseFailures:(nullable uint64_t *)parseFailures
                          overflowed:(nullable uint64_t *)overflowed;

@end

NS_ASSUME_NONNULL_END
