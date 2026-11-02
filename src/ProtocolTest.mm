// SPDX-License-Identifier: GPL-3.0-or-later
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include "crypto.h"

struct DMProtocolState { std::atomic<bool> pin{false}; std::atomic<unsigned> code{10000}; };
static void DMTestProtocolLog(void *, int level, const char *message) {
    if (level<=LOGGER_ERR) fprintf(stderr,"Protocol test: %s\n",message);
}
static void DMTestPIN(void *context, char *pin) {
    bool valid = pin && strlen(pin) == 4;
    for (int i = 0; valid && i < 4; ++i) valid &= pin[i] >= '0' && pin[i] <= '9';
    ((DMProtocolState *)context)->pin.store(valid);
    if (valid) ((DMProtocolState *)context)->code.store((unsigned)strtoul(pin,nullptr,10));
}
static NSData *DMTestWire(unsigned short port, NSData *request, NSString **header, int *persistent = nullptr) {
    int fd = persistent && *persistent >= 0 ? *persistent : socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    if (!persistent || *persistent < 0) {
        timeval timeout = {2,0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        sockaddr_in address = {}; address.sin_family = AF_INET;
        address.sin_port = htons(port); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (connect(fd, (sockaddr *)&address, sizeof(address))) { close(fd); return nil; }
        if (persistent) *persistent = fd;
    }
    for (size_t offset = 0; offset < request.length;) {
        ssize_t sent = send(fd, (const uint8_t *)request.bytes+offset, request.length-offset, 0);
        if (sent <= 0) { close(fd); if (persistent) *persistent = -1; return nil; }
        offset += sent;
    }
    NSMutableData *response = [NSMutableData data];
    NSData *delimiter = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange boundary = {NSNotFound, 0}; NSUInteger bodyLength = 0;
    uint8_t buffer[8192];
    while (response.length < 1024*1024) {
        ssize_t received = recv(fd, buffer, sizeof(buffer), 0);
        if (received <= 0) break;
        [response appendBytes:buffer length:received];
        boundary = [response rangeOfData:delimiter options:0 range:NSMakeRange(0, response.length)];
        if (boundary.location == NSNotFound) continue;
        NSString *text = [[NSString alloc] initWithData:[response subdataWithRange:NSMakeRange(0,boundary.location)] encoding:NSASCIIStringEncoding];
        *header = text;
        for (NSString *line in [text componentsSeparatedByString:@"\r\n"])
            if ([line.lowercaseString hasPrefix:@"content-length:"])
                bodyLength = [[line substringFromIndex:15] integerValue];
        if (response.length >= NSMaxRange(boundary) + bodyLength) break;
    }
    if (!persistent) { shutdown(fd, SHUT_RDWR); close(fd); }
    if (boundary.location == NSNotFound || response.length < NSMaxRange(boundary)+bodyLength) return nil;
    return [response subdataWithRange:NSMakeRange(NSMaxRange(boundary),bodyLength)];
}
static NSData *DMTestRequest(unsigned short port, const char *request, NSString **header) {
    return DMTestWire(port, [NSData dataWithBytes:request length:strlen(request)], header);
}
static NSData *DMTestPost(unsigned short port, const char *route, NSData *body, NSString **header, int *fd,
                         NSString *contentType = @"application/octet-stream") {
    NSString *text = [NSString stringWithFormat:@"POST %s RTSP/1.0\r\nCSeq: 3\r\nContent-Type: %@\r\nContent-Length: %zu\r\n\r\n", route, contentType, (size_t)body.length];
    NSMutableData *wire = [[text dataUsingEncoding:NSASCIIStringEncoding] mutableCopy];
    [wire appendData:body]; return DMTestWire(port, wire, header, fd);
}
static bool DMTestResumedPairing(unsigned short port, NSData *receiverKey,
                                ed25519_key_t *suppliedKey = nullptr, int existingFD = -1) {
    if (receiverKey.length != 32) return false;
    x25519_key_t *clientX = x25519_key_generate();
    int result = 0;
    ed25519_key_t *clientED = suppliedKey ? ed25519_key_copy(suppliedKey) :
        ed25519_key_generate("DeviceMirror-regression-client", "", &result);
    uint8_t request[68] = {1,0,0,0};
    x25519_key_get_raw(request+4, clientX); ed25519_key_get_raw(request+36, clientED);
    NSString *header = nil; int fd = existingFD;
    NSData *response = DMTestPost(port, "/pair-verify", [NSData dataWithBytes:request length:sizeof(request)], &header, &fd);
    bool ok = response.length == 96 && [header hasPrefix:@"RTSP/1.0 200"];
    if (ok) {
        const uint8_t *serverBytes = (const uint8_t *)response.bytes;
        x25519_key_t *serverX = x25519_key_from_raw(serverBytes);
        ed25519_key_t *serverED = ed25519_key_from_raw((const uint8_t *)receiverKey.bytes);
        uint8_t secret[32], key[16], iv[16], hash[64];
        x25519_derive_secret(secret, clientX, serverX);
        for (int i = 0; i < 2; ++i) {
            const char *salt = i ? "Pair-Verify-AES-IV" : "Pair-Verify-AES-Key";
            sha_ctx_t *sha = sha_init(); sha_update(sha, (const uint8_t *)salt, (int)strlen(salt));
            sha_update(sha, secret, sizeof(secret)); sha_final(sha, hash, nullptr); sha_destroy(sha);
            memcpy(i ? iv : key, hash, 16);
        }
        aes_ctx_t *aes = aes_ctr_init(key, iv);
        uint8_t signature[64], signedData[64];
        aes_ctr_decrypt(aes, serverBytes+32, signature, 64);
        memcpy(signedData, serverBytes, 32); memcpy(signedData+32, request+4, 32);
        ok &= ed25519_verify(signature, 64, signedData, 64, serverED) == 1;
        memcpy(signedData, request+4, 32); memcpy(signedData+32, serverBytes, 32);
        ed25519_sign(signature, 64, signedData, 64, clientED);
        uint8_t finish[68] = {};
        aes_ctr_encrypt(aes, signature, finish+4, 64);
        header = nil;
        DMTestPost(port, "/pair-verify", [NSData dataWithBytes:finish length:sizeof(finish)], &header, &fd);
        ok &= [header hasPrefix:@"RTSP/1.0 200"] && [header.lowercaseString containsString:@"content-type: application/octet-stream"];
        aes_ctr_destroy(aes); x25519_key_destroy(serverX); ed25519_key_destroy(serverED);
    }
    if (fd >= 0) { shutdown(fd,SHUT_RDWR); close(fd); }
    x25519_key_destroy(clientX); ed25519_key_destroy(clientED);
    return ok;
}
#import "PinPairingTest.mm"
static int DMProtocolTest() {
    bool passed = true;
    for (int round = 0; round < 3; ++round) {
        DMProtocolState state;
        raop_callbacks_t callbacks = DMReceiverCallbacks(&state);
        callbacks.audio_process = DMTestAudioNoop; callbacks.video_process = DMTestVideoNoop;
        callbacks.audio_set_client_volume = DMVolume; callbacks.display_pin = DMTestPIN;
        raop_t *server = raop_init(&callbacks);
        if (!server || raop_init2(server, 0, "02:23:45:67:89:AB", "")) return 1;
        raop_set_log_callback(server,DMTestProtocolLog,nullptr);
        raop_set_log_level(server, LOGGER_ERR);
        const char hardware[] = {2,0x23,0x45,0x67,(char)0x89,(char)0xab};
        int error = 0;
        dnssd_t *service = dnssd_init("Device Mirror Test", 18, hardware, 6, &error, 1);
        if (!service || error) { raop_destroy(server); return 1; }
        raop_set_dnssd(server, service);
        raop_set_plist(server, "width", 1920); raop_set_plist(server, "height", 1440);
        raop_set_plist(server, "maxFPS", 60); raop_set_plist(server, "pin", 0);
        unsigned short port = 0;
        bool started = raop_start_httpd(server, &port) == 1 && port > 0;
        NSString *header = nil;
        NSData *body = started ? DMTestRequest(port, "GET /info RTSP/1.0\r\nCSeq: 1\r\n\r\n", &header) : nil;
        NSDictionary *info = body ? [NSPropertyListSerialization propertyListWithData:body options:NSPropertyListImmutable format:nullptr error:nil] : nil;
        NSDictionary *display = [info[@"displays"] firstObject];
        bool infoOK = [header hasPrefix:@"RTSP/1.0 200"] && [info[@"name"] isEqual:@"Device Mirror Test"] &&
            [display[@"width"] intValue] == 1920 && [display[@"height"] intValue] == 1440 && [display[@"maxFPS"] intValue] == 60;
        header = nil;
        DMTestRequest(port, "POST /pair-pin-start RTSP/1.0\r\nCSeq: 2\r\nContent-Length: 0\r\n\r\n", &header);
        bool pinOK = [header hasPrefix:@"RTSP/1.0 200"] && state.pin.load();
        bool initialPairingOK = DMTestInitialPINPairing(port, info[@"pk"], &state, false);
        bool wrongPINRejected = DMTestInitialPINPairing(port, info[@"pk"], &state, true);
        bool pairingOK = DMTestResumedPairing(port, info[@"pk"]);
        raop_destroy(server); dnssd_destroy(service);
        printf("AirPlay round %d: info %s; PIN display %s; initial PIN pairing %s; wrong PIN rejected %s; resumed handshake %s; shutdown PASS\n", round+1,
            infoOK ? "PASS" : "FAIL", pinOK ? "PASS" : "FAIL", initialPairingOK ? "PASS" : "FAIL",
            wrongPINRejected ? "PASS" : "FAIL", pairingOK ? "PASS" : "FAIL");
        passed &= started && infoOK && pinOK && initialPairingOK && wrongPINRejected && pairingOK;
    }
    return passed ? 0 : 1;
}
