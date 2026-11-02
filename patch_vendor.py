#!/usr/bin/env python3
"""Apply narrow, reproducible fixes to pinned UxPlay sources before compiling."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent / 'vendor/uxplay/lib'

def replace(name, before, after):
    path = ROOT / name
    source = path.read_text()
    if after in source:
        return
    if source.count(before) != 1:
        raise RuntimeError('Unexpected upstream source for patch: ' + name + ': ' + before[:70])
    path.write_text(source.replace(before, after, 1))

# AirPlay legacy PIN pairing uses SRP-SHA1, so M1 and M2 are 20 bytes.
# UxPlay 1.73.7 mistakenly checks M1 against a 64-byte temporary-buffer size.
replace('pairing.h', '#define SRP_M2_SIZE 64', '#define SRP_PROOF_SIZE 20\n#define SRP_M2_SIZE 64')
replace('raop_handlers.h', "unsigned char proof[64] = { '\\0' };",
        "unsigned char proof[SRP_PROOF_SIZE] = { '\\0' };")
replace('raop_handlers.h',
'''            logger_log(raop->logger, LOGGER_ERR, "Client Authentication Failure (client_proof_len %d invalid)", (int) client_proof_len);
            goto authentication_failed;''',
'''            logger_log(raop->logger, LOGGER_ERR, "Client Authentication Failure (client_proof_len %d invalid)", (int) client_proof_len);
            free(client_pk);
            free(client_proof);
            plist_free(req_root_node);
            goto authentication_failed;''')
replace('pairing.c',
'''    int authenticated  = 0;
    const unsigned char *B =  NULL;''',
'''    if (!session || !session->srp || !A || len_A < 1 || len_A > SRP_PK_SIZE ||
        !proof || client_proof_len != SRP_PROOF_SIZE || proof_len != SRP_PROOF_SIZE) {
        return -1;
    }
    int authenticated  = 0;
    const unsigned char *B =  NULL;''')
replace('pairing.c',
'''    srp_verifier_verify_session(verifier, proof, &M2);''',
'''    if (!verifier) {
        free(session->srp);
        session->srp = NULL;
        return -1;
    }
    srp_verifier_verify_session(verifier, proof, &M2);''')
replace('pairing.c',
'''                       unsigned char *epk, unsigned char *auth_tag) {
    unsigned char aesKey[16]''',
'''                       unsigned char *epk, unsigned char *auth_tag) {
    if (!session || !session->srp || !epk || !auth_tag) return -1;
    unsigned char aesKey[16]''')
replace('raop_handlers.h',
'''        plist_get_data_val(req_authtag_node, &client_authtag, &client_authtag_len);

        if (logger_debug)''',
'''        plist_get_data_val(req_authtag_node, &client_authtag, &client_authtag_len);
        if (client_epk_len != sizeof(epk) || client_authtag_len != sizeof(authtag)) {
            free(client_epk);
            free(client_authtag);
            plist_free(req_root_node);
            logger_log(raop->logger, LOGGER_ERR, "DeviceMirror pairing: invalid encrypted key lengths");
            goto authentication_failed;
        }

        if (logger_debug)''')

# Log only fixed stage names. The app translates them without logging PINs,
# cryptographic material, request bodies, device names, or network addresses.
replace('raop_handlers.h',
'''        plist_dict_set_item(res_root_node, "salt", res_salt_node);
        plist_to_bin(res_root_node, response_data, (uint32_t*) response_datalen);''',
'''        plist_dict_set_item(res_root_node, "salt", res_salt_node);
        logger_log(raop->logger, LOGGER_INFO, "DeviceMirror pairing: challenge sent");
        plist_to_bin(res_root_node, response_data, (uint32_t*) response_datalen);''')
replace('raop_handlers.h',
'''        plist_t res_proof_node = plist_new_data((const char *) proof, 20);''',
'''        logger_log(raop->logger, LOGGER_INFO, "DeviceMirror pairing: client proof verified");
        plist_t res_proof_node = plist_new_data((const char *) proof, SRP_PROOF_SIZE);''')
replace('raop_handlers.h',
'''logger_log(raop->logger, LOGGER_DEBUG, "pair-pin-setup success\\n");''',
'''logger_log(raop->logger, LOGGER_INFO, "DeviceMirror pairing: trusted keys exchanged");''')
replace('raop_handlers.h',
'''logger_log(raop->logger, LOGGER_DEBUG, "pair-verify: signature is verified");''',
'''logger_log(raop->logger, LOGGER_INFO, "DeviceMirror pairing: verification complete");''')

for name in ('pairing.h','pairing.c','raop_handlers.h'):
    path = ROOT / name
    note = ('/* Modified for Device Mirror on 2026-11-01: correct 20-byte legacy PIN\n'
            ' * proof validation, bound-check pairing payloads, and report pairing stages. */\n')
    source = path.read_text()
    if not source.startswith(note): path.write_text(note + source)
