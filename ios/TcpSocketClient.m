/**
 * Copyright (c) 2015-present, Peel Technologies, Inc.
 * All rights reserved.
 */

#import <netinet/in.h>
#import <arpa/inet.h>
#import "TcpSocketClient.h"

#import <React/RCTLog.h>

NSString *const RCTTCPErrorDomain = @"RCTTCPErrorDomain";

@interface TcpSocketClient()
{
@private
    GCDCSSLAsyncSocket *_tcpSocket;
    NSString *_host;
    NSMutableDictionary<NSNumber *, RCTResponseSenderBlock> *_pendingSends;
    RCTResponseSenderBlock _pendingUpgrade;
    NSLock *_lock;
    long _sendTag;
}

- (id)initWithClientId:(NSNumber *)clientID andConfig:(id<SocketClientDelegate>)aDelegate;
- (id)initWithClientId:(NSNumber *)clientID andConfig:(id<SocketClientDelegate>)aDelegate andSocket:(GCDCSSLAsyncSocket*)tcpSocket;

@end

@implementation TcpSocketClient

+ (id)socketClientWithId:(nonnull NSNumber *)clientID andConfig:(id<SocketClientDelegate>)delegate
{
    return [[[self class] alloc] initWithClientId:clientID andConfig:delegate andSocket:nil];
}

- (id)initWithClientId:(NSNumber *)clientID andConfig:(id<SocketClientDelegate>)aDelegate
{
    return [self initWithClientId:clientID andConfig:aDelegate andSocket:nil];
}

- (id)initWithClientId:(NSNumber *)clientID andConfig:(id<SocketClientDelegate>)aDelegate andSocket:(GCDCSSLAsyncSocket*)tcpSocket;
{
    self = [super init];
    if (self) {
        _id = clientID;
        _clientDelegate = aDelegate;
        _pendingSends = [NSMutableDictionary dictionary];
        _lock = [[NSLock alloc] init];
        _tcpSocket = tcpSocket;
        [_tcpSocket setUserData: clientID];
    }

    return self;
}

- (BOOL)connect:(NSString *)host port:(int)port withOptions:(NSDictionary *)options error:(NSError **)error
{
    return [self connect:host port:port withOptions:options useSsl:NO error:error];
}

- (BOOL)connect:(NSString *)host port:(int)port withOptions:(NSDictionary *)options useSsl:(BOOL)useSsl error:(NSError **)error
{
    self.useSsl = useSsl;
    if (_tcpSocket) {
        if (error) {
            *error = [self badInvocationError:@"this client's socket is already connected"];
        }

        return false;
    }

    _host = host;
    _tcpSocket = [[GCDCSSLAsyncSocket alloc] initWithDelegate:self delegateQueue:[self methodQueue]];
    [_tcpSocket setUserData: _id];

    BOOL result = false;

    NSString *localAddress = (options?options[@"localAddress"]:nil);
    NSNumber *localPort = (options?options[@"localPort"]:nil);

    if (!localAddress && !localPort) {
        result = [_tcpSocket connectToHost:host onPort:port error:error];
    } else {
        NSMutableArray *interface = [NSMutableArray arrayWithCapacity:2];
        [interface addObject: localAddress?localAddress:@""];
        if (localPort) {
            [interface addObject:[localPort stringValue]];
        }
        result = [_tcpSocket connectToHost:host
                                    onPort:port
                              viaInterface:[interface componentsJoinedByString:@":"]
                               withTimeout:-1
                                     error:error];
    }

    return result;
}

- (void)upgradeToSecure:(NSString *)host port:(int)port callback:(RCTResponseSenderBlock) callback;
{
    if (callback) {
        self->_pendingUpgrade = callback;
    }
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];

    [_tcpSocket startTLSCancelCurrentRead:settings];
}

- (NSDictionary<NSString *, id> *)getAddress
{
    if (_tcpSocket)
    {
        if (_tcpSocket.isConnected) {
            return @{ @"port": @(_tcpSocket.connectedPort),
                      @"address": _tcpSocket.connectedHost ?: @"unknown",
                      @"family": _tcpSocket.isIPv6?@"IPv6":@"IPv4" };
        } else {
            return @{ @"port": @(_tcpSocket.localPort),
                      @"address": _tcpSocket.localHost ?: @"unknown",
                      @"family": _tcpSocket.isIPv6?@"IPv6":@"IPv4" };
        }
    }

    return @{ @"port": @(0),
              @"address": @"unknown",
              @"family": @"unkown" };
}

- (BOOL)listen:(NSString *)host port:(int)port error:(NSError **)error
{
    if (_tcpSocket) {
        if (error) {
            *error = [self badInvocationError:@"this client's socket is already connected"];
        }

        return false;
    }

    _tcpSocket = [[GCDCSSLAsyncSocket alloc] initWithDelegate:self delegateQueue:[self methodQueue]];
    [_tcpSocket setUserData: _id];

    // GCDCSSLAsyncSocket doesn't recognize 0.0.0.0
    if ([@"0.0.0.0" isEqualToString: host]) {
        host = @"localhost";
    }
    BOOL isListening = [_tcpSocket acceptOnInterface:host port:port error:error];
    if (isListening == YES) {
        [_clientDelegate onConnect: self];
        [_tcpSocket readDataWithTimeout:-1 tag:_id.longValue];
    }

    return isListening;
}

- (void)setPendingSend:(RCTResponseSenderBlock)callback forKey:(NSNumber *)key
{
    [_lock lock];
    @try {
        [_pendingSends setObject:callback forKey:key];
    }
    @finally {
        [_lock unlock];
    }
}

- (RCTResponseSenderBlock)getPendingSend:(NSNumber *)key
{
    [_lock lock];
    @try {
        return [_pendingSends objectForKey:key];
    }
    @finally {
        [_lock unlock];
    }
}

- (void)dropPendingSend:(NSNumber *)key
{
    [_lock lock];
    @try {
        [_pendingSends removeObjectForKey:key];
    }
    @finally {
        [_lock unlock];
    }
}

- (void)socket:(GCDCSSLAsyncSocket *)sock didWriteDataWithTag:(long)msgTag
{
    NSNumber* tagNum = [NSNumber numberWithLong:msgTag];
    RCTResponseSenderBlock callback = [self getPendingSend:tagNum];
    if (callback) {
        callback(@[]);
        [self dropPendingSend:tagNum];
    }
}

- (void) writeData:(NSData *)data
          callback:(RCTResponseSenderBlock)callback
{
    if (callback) {
        [self setPendingSend:callback forKey:@(_sendTag)];
    }
    [_tcpSocket writeData:data withTimeout:-1 tag:_sendTag];
    _sendTag++;
}

- (void)end
{
    [_tcpSocket disconnectAfterWriting];
}

- (void)destroy
{
    [_tcpSocket disconnect];
}

- (void)socket:(GCDCSSLAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag {
    if (!_clientDelegate) {
        RCTLogWarn(@"didReadData with nil clientDelegate for %@", [sock userData]);
        return;
    }

    [_clientDelegate onData:@(tag) data:data];

    if (!_pendingUpgrade) {
        // if we add a read, the special packet will not be picked up in time
        [sock readDataWithTimeout:-1 tag:tag];
    }
}

- (void)socket:(GCDCSSLAsyncSocket *)sock didAcceptNewSocket:(GCDCSSLAsyncSocket *)newSocket
{
    TcpSocketClient *inComing = [[TcpSocketClient alloc] initWithClientId:[_clientDelegate getNextId]
                                                                andConfig:_clientDelegate
                                                                andSocket:newSocket];
    [_clientDelegate onConnection: inComing
                         toClient: _id];
    [newSocket readDataWithTimeout:-1 tag:inComing.id.longValue];
}

- (void)socket:(GCDCSSLAsyncSocket *)sock didConnectToHost:(NSString *)host port:(uint16_t)port
{
    if (!_clientDelegate) {
        RCTLogWarn(@"didConnectToHost with nil clientDelegate for %@", [sock userData]);
        return;
    }

    if (self.useSsl)
    {
        NSMutableDictionary *settings = [NSMutableDictionary dictionary];
        [sock startTLS:settings];

        [_clientDelegate onConnect:self];
    }
    else
    {
        [_clientDelegate onConnect:self];
        [sock readDataWithTimeout:-1 tag:_id.longValue];
    }
}

- (void)socketDidSecure:(GCDCSSLAsyncSocket *)sock {
    RCTLogInfo(@"socket secured");
    if (self->_pendingUpgrade) {
        self.useSsl= true;
        self->_pendingUpgrade(@[]);
        self->_pendingUpgrade = nil;
        [_clientDelegate onSecureConnect:self];
    }
    // start receiving messages
    if (self.useSsl)
    {
        [sock readDataWithTimeout:-1 tag:_id.longValue];
    }
}
- (void)socketDidCloseReadStream:(GCDCSSLAsyncSocket *)sock
{
    // TODO : investigate for half-closed sockets
    // for now close the stream completely
    [sock disconnect];
}

- (void)socketDidDisconnect:(GCDCSSLAsyncSocket *)sock withError:(NSError *)err
{
    if (!_clientDelegate) {
        RCTLogWarn(@"socketDidDisconnect with nil clientDelegate for %@", [sock userData]);
        return;
    }

    [_clientDelegate onClose:[sock userData] withError:(!err || err.code == GCDCSSLAsyncSocketClosedError ? nil : err)];
}

- (NSError *)badInvocationError:(NSString *)errMsg
{
    NSDictionary *userInfo = [NSDictionary dictionaryWithObject:errMsg forKey:NSLocalizedDescriptionKey];

    return [NSError errorWithDomain:RCTTCPErrorDomain
                               code:RCTTCPInvalidInvocationError
                           userInfo:userInfo];
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

- (void)socket:(GCDCSSLAsyncSocket *)sock didReceiveTrust:(SecTrustRef)trust
completionHandler:(void (^)(BOOL shouldTrustPeer))completionHandler
{
    completionHandler(YES);
}

@end
