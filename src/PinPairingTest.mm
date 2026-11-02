// SPDX-License-Identifier: GPL-3.0-or-later
// Independent client-side SRP-6a math, exercised over the actual RTSP listener.
// This tests the first PIN entry, not just cached pair-verify authentication.
#include <openssl/bn.h>
#include <openssl/evp.h>

static NSData *DMTestHash(NSArray<NSData *> *parts, const EVP_MD *algorithm = EVP_sha1()) {
    EVP_MD_CTX *ctx = EVP_MD_CTX_new(); EVP_DigestInit_ex(ctx,algorithm,nullptr);
    for (NSData *part in parts) EVP_DigestUpdate(ctx,part.bytes,part.length);
    uint8_t hash[64]; unsigned size = 0;
    EVP_DigestFinal_ex(ctx,hash,&size); EVP_MD_CTX_free(ctx);
    return [NSData dataWithBytes:hash length:size];
}
static NSData *DMBNBytes(const BIGNUM *number, int padded = 0) {
    int size = padded ?: BN_num_bytes(number);
    NSMutableData *result = [NSMutableData dataWithLength:size];
    BN_bn2binpad(number,(uint8_t *)result.mutableBytes,size); return result;
}
static NSDictionary *DMTestPlistPost(unsigned short port, NSDictionary *dictionary, NSString **header, int *fd) {
    NSData *body = [NSPropertyListSerialization dataWithPropertyList:dictionary format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSData *response = DMTestPost(port,"/pair-setup-pin",body,header,fd,@"application/x-apple-binary-plist");
    if (!response.length) return nil;
    return [NSPropertyListSerialization propertyListWithData:response options:NSPropertyListImmutable format:nullptr error:nil];
}
struct DMPINClient {
    NSData *__strong publicKey;
    NSData *__strong sessionKey;
    NSData *__strong proof;
    NSData *__strong serverProof;
    bool challenge(NSString *username, NSString *pin, NSData *salt, NSData *serverPublicKey) {
        if (salt.length != 16 || serverPublicKey.length < 1 || serverPublicKey.length > 256) return false;
        const char *prime =
            "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4"
            "A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF60"
            "95179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF"
            "747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B907"
            "8717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861"
            "60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DB"
            "FBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73";
        BN_CTX *ctx = BN_CTX_new(); BN_CTX_start(ctx);
        BIGNUM *N=BN_CTX_get(ctx), *g=BN_CTX_get(ctx), *a=BN_CTX_get(ctx), *A=BN_CTX_get(ctx),
            *B=BN_CTX_get(ctx), *k=BN_CTX_get(ctx), *u=BN_CTX_get(ctx), *x=BN_CTX_get(ctx),
            *gx=BN_CTX_get(ctx), *base=BN_CTX_get(ctx), *exponent=BN_CTX_get(ctx),
            *S=BN_CTX_get(ctx), *temporary=BN_CTX_get(ctx), *saltNumber=BN_CTX_get(ctx);
        BN_hex2bn(&N,prime); BN_set_word(g,2); BN_rand(a,256,BN_RAND_TOP_ONE,BN_RAND_BOTTOM_ANY);
        BN_mod_exp(A,g,a,N,ctx);
        BN_bin2bn((const uint8_t *)serverPublicKey.bytes,(int)serverPublicKey.length,B);
        BN_bin2bn((const uint8_t *)salt.bytes,(int)salt.length,saltNumber);
        NSData *minimalSalt = DMBNBytes(saltNumber), *aBytes = DMBNBytes(A), *bBytes = DMBNBytes(B);
        NSData *kHash = DMTestHash(@[DMBNBytes(N,256),DMBNBytes(g,256)]);
        BN_bin2bn((const uint8_t *)kHash.bytes,(int)kHash.length,k);
        NSData *uHash = DMTestHash(@[DMBNBytes(A,256),DMBNBytes(B,256)]);
        BN_bin2bn((const uint8_t *)uHash.bytes,(int)uHash.length,u);
        NSData *credentials = [[NSString stringWithFormat:@"%@:%@",username,pin] dataUsingEncoding:NSUTF8StringEncoding];
        NSData *xHash = DMTestHash(@[minimalSalt,DMTestHash(@[credentials])]);
        BN_bin2bn((const uint8_t *)xHash.bytes,(int)xHash.length,x);
        BN_mod_exp(gx,g,x,N,ctx); BN_mod_mul(temporary,k,gx,N,ctx);
        BN_mod_sub(base,B,temporary,N,ctx); BN_mul(temporary,u,x,ctx); BN_add(exponent,a,temporary);
        BN_mod_exp(S,base,exponent,N,ctx);
        const uint8_t zero[4] = {}, one[4] = {0,0,0,1};
        NSData *secret = DMBNBytes(S);
        NSMutableData *K = [DMTestHash(@[secret,[NSData dataWithBytes:zero length:4]]) mutableCopy];
        [K appendData:DMTestHash(@[secret,[NSData dataWithBytes:one length:4]])];
        NSData *hN=DMTestHash(@[DMBNBytes(N)]), *hg=DMTestHash(@[DMBNBytes(g)]);
        uint8_t xorHash[20];
        for (int i=0;i<20;++i) xorHash[i]=((const uint8_t *)hN.bytes)[i]^((const uint8_t *)hg.bytes)[i];
        NSData *identityHash=DMTestHash(@[[username dataUsingEncoding:NSUTF8StringEncoding]]);
        publicKey = aBytes; sessionKey = K;
        proof = DMTestHash(@[[NSData dataWithBytes:xorHash length:20],identityHash,minimalSalt,aBytes,bBytes,K]);
        serverProof = DMTestHash(@[aBytes,proof,K]);
        bool valid = !BN_is_zero(B) && !BN_is_zero(u) && proof.length==20 && K.length==40;
        BN_CTX_end(ctx); BN_CTX_free(ctx); return valid;
    }
};
static bool DMTestInitialPINPairing(unsigned short port, NSData *receiverKey, DMProtocolState *state, bool wrongPIN) {
    int fd=-1; NSString *header=nil; bool ok=false;
    @autoreleasepool {
        NSData *start=[@"POST /pair-pin-start RTSP/1.0\r\nCSeq: 1\r\nContent-Length: 0\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        DMTestWire(port,start,&header,&fd);
        if (![header hasPrefix:@"RTSP/1.0 200"] || state->code.load()>9999) goto finished;
        {
            unsigned code=state->code.load(); if(wrongPIN) code=(code+1)%10000;
            NSString *pin=[NSString stringWithFormat:@"%04u",code];
            NSString *username=@"02:CA:FE:00:00:01";
            NSDictionary *challenge=DMTestPlistPost(port,@{@"method":@"pin",@"user":username},&header,&fd);
            DMPINClient client;
            if (![header hasPrefix:@"RTSP/1.0 200"] || !client.challenge(username,pin,challenge[@"salt"],challenge[@"pk"])) {
                fprintf(stderr,"Initial PIN pairing: SRP challenge failed\n"); goto finished;
            }
            NSDictionary *answer=DMTestPlistPost(port,@{@"pk":client.publicKey,@"proof":client.proof},&header,&fd);
            if (wrongPIN) { ok=[header hasPrefix:@"RTSP/1.0 470"]; goto finished; }
            if (![header hasPrefix:@"RTSP/1.0 200"] || ![answer[@"proof"] isEqual:client.serverProof]) {
                fprintf(stderr,"Initial PIN pairing: 20-byte SRP proof rejected (%s)\n", [header componentsSeparatedByString:@"\r\n"].firstObject.UTF8String); goto finished;
            }
            int keyResult=0;
            ed25519_key_t *identity=ed25519_key_generate("DeviceMirror-initial-pairing-client","",&keyResult);
            uint8_t key[16],iv[16],publicKey[32],epk[32],tag[16];
            NSData *keyHash=DMTestHash(@[[@"Pair-Setup-AES-Key" dataUsingEncoding:NSASCIIStringEncoding],client.sessionKey],EVP_sha512());
            NSData *ivHash=DMTestHash(@[[@"Pair-Setup-AES-IV" dataUsingEncoding:NSASCIIStringEncoding],client.sessionKey],EVP_sha512());
            memcpy(key,keyHash.bytes,16); memcpy(iv,ivHash.bytes,16); ++iv[15];
            ed25519_key_get_raw(publicKey,identity);
            gcm_encrypt(publicKey,32,epk,key,iv,tag);
            NSDictionary *exchange=DMTestPlistPost(port,@{@"epk":[NSData dataWithBytes:epk length:32],
                @"authTag":[NSData dataWithBytes:tag length:16]},&header,&fd);
            if ([header hasPrefix:@"RTSP/1.0 200"] && [exchange[@"epk"] length]==32 && [exchange[@"authTag"] length]==16) {
                memcpy(epk,[exchange[@"epk"] bytes],32); memcpy(tag,[exchange[@"authTag"] bytes],16); ++iv[15];
                int count=gcm_decrypt(epk,32,publicKey,key,iv,tag);
                ok=count==32 && receiverKey.length==32 && !memcmp(publicKey,receiverKey.bytes,32);
                if (ok) { int pairedFD=fd; fd=-1; ok=DMTestResumedPairing(port,receiverKey,identity,pairedFD); }
                if (ok) ok=DMTestResumedPairing(port,receiverKey,identity);
            }
            ed25519_key_destroy(identity);
        }
    finished:
        if(fd>=0) { shutdown(fd,SHUT_RDWR); close(fd); }
    }
    return ok;
}
