// SPDX-License-Identifier: Apache-2.0
//! CTAP2: the status codes, and the two requests whose lengths an attacker
//! chooses.
//!
//! [exp170] is the experiment about why this is worth doing once and carefully:
//! **a CTAP2 authenticator parses input somebody else picked, and the lengths
//! in CBOR are part of that input.** Its reader is
//! [`crates/cbor`](../../../crates/cbor/), bounds-checked and canonical-only,
//! and every length in it goes through one `checked_add`.
//!
//! What this module adds is the layer above: which map key means what. That is
//! where this repository has been wrong twice, both times in a copy, and both
//! times invisibly —
//!
//! | | was read as | is |
//! |---|---|---|
//! | `makeCredential` `0x06` | `pinUvAuthParam` | **`extensions`** |
//! | `getAssertion` `0x07` | `pinUvAuthParam` | **`pinUvAuthProtocol`**, a uint |
//!
//! `0x06` *is* pinUvAuthParam — in `getAssertion`. The two requests do not
//! share a numbering and a copy carried one into the other. Both are tests
//! below, and neither needs a board.
//!
//! [exp170]: ../../../experiments/exp170-a-map-somebody-else-wrote/

use cbor::{Item, ReadError, Reader};

pub const CTAP2_OK: u8 = 0x00;
pub const CTAP1_ERR_INVALID_COMMAND: u8 = 0x01;
pub const CTAP1_ERR_INVALID_LENGTH: u8 = 0x03;
pub const CTAP2_ERR_INVALID_CBOR: u8 = 0x12;
pub const CTAP2_ERR_MISSING_PARAMETER: u8 = 0x14;
pub const CTAP2_ERR_UNSUPPORTED_ALGORITHM: u8 = 0x26;
pub const CTAP2_ERR_OPERATION_DENIED: u8 = 0x27;
pub const CTAP2_ERR_UNSUPPORTED_OPTION: u8 = 0x2b;
pub const CTAP2_ERR_KEEPALIVE_CANCEL: u8 = 0x2d;
pub const CTAP2_ERR_NO_CREDENTIALS: u8 = 0x2e;
pub const CTAP2_ERR_NOT_ALLOWED: u8 = 0x30;
pub const CTAP2_ERR_PIN_INVALID: u8 = 0x31;
pub const CTAP2_ERR_PIN_AUTH_INVALID: u8 = 0x32;
pub const CTAP2_ERR_PIN_BLOCKED: u8 = 0x34;
pub const CTAP2_ERR_PIN_NOT_SET: u8 = 0x35;
pub const CTAP2_ERR_PIN_AUTH_BLOCKED: u8 = 0x36;
pub const CTAP2_ERR_UNAUTHORIZED_PERMISSION: u8 = 0x3f;

pub const CMD_MAKE_CREDENTIAL: u8 = 0x01;
pub const CMD_GET_ASSERTION: u8 = 0x02;
pub const CMD_GET_INFO: u8 = 0x04;
pub const CMD_CLIENT_PIN: u8 = 0x06;
pub const CMD_RESET: u8 = 0x07;
pub const CMD_CREDENTIAL_MANAGEMENT: u8 = 0x0a;

/// authData flag bits.
pub const FLAG_UP: u8 = 0x01;
pub const FLAG_UV: u8 = 0x04;
pub const FLAG_AT: u8 = 0x40;
/// Extension data follows the attested credential data.
pub const FLAG_ED: u8 = 0x80;

pub const MAX_ALGS: usize = 8;
pub const MAX_ALLOW: usize = 8;

/// The `hmac-secret` extension in a `getAssertion`, as the client sent it.
///
/// The only extension this repository implements; see
/// [exp189](../../../experiments/exp189-the-same-salt-twice/).
#[derive(Debug)]
pub struct HmacSecretRequest<'a> {
    pub peer_x: [u8; 32],
    pub peer_y: [u8; 32],
    pub salt_enc: &'a [u8],
    pub salt_auth: &'a [u8],
}
#[derive(Debug)]
pub struct MakeCredential<'a> {
    pub client_data_hash: &'a [u8],
    pub rp_id: &'a str,
    pub user_id: &'a [u8],
    pub user_name: Option<&'a str>,
    pub user_display_name: Option<&'a str>,
    pub algs: [i64; MAX_ALGS],
    pub n_algs: usize,
    pub pin_uv_auth_param: Option<&'a [u8]>,
    pub uv_required: bool,
    pub rk_required: bool,
    pub hmac_secret: bool,
}

#[derive(Debug)]
pub struct GetAssertion<'a> {
    pub rp_id: &'a str,
    pub client_data_hash: &'a [u8],
    pub allow: [&'a [u8]; MAX_ALLOW],
    pub n_allow: usize,
    pub pin_uv_auth_param: Option<&'a [u8]>,
    pub uv_required: bool,
    pub hmac_secret: Option<HmacSecretRequest<'a>>,
}

pub fn find_text_key(r: &mut Reader, pairs: u64, want: &str) -> Result<bool, ReadError> {
    for _ in 0..pairs {
        let is_it = match r.next()? {
            Item::Text(k) => k == want,
            Item::Uint(_) | Item::Nint(_) => false,
            _ => return Err(ReadError::NotCanonical),
        };
        if is_it {
            return Ok(true);
        }
        r.skip()?;
    }
    Ok(false)
}

pub fn skip_map_pairs(r: &mut Reader, pairs: u64) -> Result<(), ReadError> {
    for _ in 0..pairs {
        r.skip()?;
        r.skip()?;
    }
    Ok(())
}

pub fn status_for(e: ReadError) -> u8 {
    match e {
        ReadError::Truncated
        | ReadError::NotCanonical
        | ReadError::BadText => CTAP2_ERR_INVALID_CBOR,
        ReadError::Unsupported | ReadError::TooDeep => CTAP2_ERR_UNSUPPORTED_OPTION,
    }
}

/// Parse peer COSE_Key public point (x and y coordinates).
pub fn parse_cose_key_point(r: &mut Reader) -> Result<([u8; 32], [u8; 32]), u8> {
    let pairs = match r.next().map_err(|_| CTAP2_ERR_INVALID_CBOR)? {
        Item::Map(n) => n,
        _ => return Err(CTAP2_ERR_INVALID_CBOR),
    };
    let mut x_coord: Option<[u8; 32]> = None;
    let mut y_coord: Option<[u8; 32]> = None;

    for _ in 0..pairs {
        let key_item = r.next().map_err(|_| CTAP2_ERR_INVALID_CBOR)?;
        match key_item {
            Item::Nint(n) if n == -2 => { // -2: x
                if let Item::Bytes(b) = r.next().map_err(|_| CTAP2_ERR_INVALID_CBOR)? {
                    if b.len() == 32 {
                        let mut arr = [0u8; 32];
                        arr.copy_from_slice(b);
                        x_coord = Some(arr);
                    }
                }
            }
            Item::Nint(n) if n == -3 => { // -3: y
                if let Item::Bytes(b) = r.next().map_err(|_| CTAP2_ERR_INVALID_CBOR)? {
                    if b.len() == 32 {
                        let mut arr = [0u8; 32];
                        arr.copy_from_slice(b);
                        y_coord = Some(arr);
                    }
                }
            }
            _ => {
                r.skip().map_err(|_| CTAP2_ERR_INVALID_CBOR)?;
            }
        }
    }

    match (x_coord, y_coord) {
        (Some(x), Some(y)) => Ok((x, y)),
        _ => Err(CTAP2_ERR_MISSING_PARAMETER),
    }
}

pub fn parse_make_credential(body: &[u8]) -> Result<MakeCredential<'_>, u8> {
    let mut r = Reader::new(body);
    let pairs = r.map_header().map_err(status_for)?;

    let mut client_data_hash: Option<&[u8]> = None;
    let mut rp_id: Option<&str> = None;
    let mut user_id: Option<&[u8]> = None;
    let mut user_name: Option<&str> = None;
    let mut user_display_name: Option<&str> = None;
    let mut algs = [0i64; MAX_ALGS];
    let mut n_algs = 0usize;
    let mut have_params = false;
    let mut pin_uv_auth_param: Option<&[u8]> = None;
    let mut uv_required = false;
    let mut rk_required = false;
    let mut hmac_secret = false;

    for _ in 0..pairs {
        let key = match r.next().map_err(status_for)? {
            Item::Uint(k) => k,
            _ => return Err(CTAP2_ERR_INVALID_CBOR),
        };
        match key {
            0x01 => match r.next().map_err(status_for)? {
                Item::Bytes(b) => client_data_hash = Some(b),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            0x02 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "id").map_err(status_for)? {
                    match it.next().map_err(status_for)? {
                        Item::Text(v) => rp_id = Some(v),
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x03 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it_id = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_id, n, "id").map_err(status_for)? {
                    match it_id.next().map_err(status_for)? {
                        Item::Bytes(v) => user_id = Some(v),
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    }
                }
                let mut it_name = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_name, n, "name").map_err(status_for)? {
                    if let Ok(Item::Text(v)) = it_name.next() {
                        user_name = Some(v);
                    }
                }
                let mut it_dn = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_dn, n, "displayName").map_err(status_for)? {
                    if let Ok(Item::Text(v)) = it_dn.next() {
                        user_display_name = Some(v);
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x04 => {
                have_params = true;
                let entries = match r.next().map_err(status_for)? {
                    Item::Array(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                for _ in 0..entries {
                    let n = match r.next().map_err(status_for)? {
                        Item::Map(n) => n,
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    };
                    let mut it = Reader::new(&body[r.position()..]);
                    if find_text_key(&mut it, n, "alg").map_err(status_for)? {
                        let v = match it.next().map_err(status_for)? {
                            Item::Nint(v) => v,
                            Item::Uint(v) => v as i64,
                            _ => return Err(CTAP2_ERR_INVALID_CBOR),
                        };
                        if n_algs < MAX_ALGS {
                            algs[n_algs] = v;
                            n_algs += 1;
                        }
                    }
                    skip_map_pairs(&mut r, n).map_err(status_for)?;
                }
            }
            0x07 => { // options map
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it_uv = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_uv, n, "uv").map_err(status_for)? {
                    if let Ok(Item::Bool(b)) = it_uv.next() {
                        uv_required = b;
                    }
                }
                let mut it_rk = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it_rk, n, "rk").map_err(status_for)? {
                    if let Ok(Item::Bool(b)) = it_rk.next() {
                        rk_required = b;
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            // 0x06 is **extensions** in makeCredential; 0x08 is pinUvAuthParam.
            // The inherited code read `0x06 | 0x08` as pinUvAuthParam, which is
            // getAssertion's numbering — so any makeCredential carrying an
            // extension map was refused with CTAP2_ERR_INVALID_CBOR, because a
            // map is not Bytes. Nothing caught it: no client had ever sent one.
            0x06 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "hmac-secret").map_err(status_for)? {
                    if let Ok(Item::Bool(b)) = it.next() {
                        hmac_secret = b;
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x08 => match r.next().map_err(status_for)? {
                Item::Bytes(v) => pin_uv_auth_param = Some(v),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            _ => r.skip().map_err(status_for)?,
        }
    }

    if !r.is_empty() {
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    let client_data_hash = client_data_hash.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    let rp_id = rp_id.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    let user_id = user_id.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    if !have_params {
        return Err(CTAP2_ERR_MISSING_PARAMETER);
    }
    if client_data_hash.len() != 32 {
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    Ok(MakeCredential {
        client_data_hash,
        rp_id,
        user_id,
        user_name,
        user_display_name,
        algs,
        n_algs,
        pin_uv_auth_param,
        uv_required,
        rk_required,
        hmac_secret,
    })
}

pub fn parse_get_assertion(body: &[u8]) -> Result<GetAssertion<'_>, u8> {
    let mut r = Reader::new(body);
    let pairs = r.map_header().map_err(status_for)?;

    let mut rp_id: Option<&str> = None;
    let mut client_data_hash: Option<&[u8]> = None;
    let mut allow: [&[u8]; MAX_ALLOW] = [&[]; MAX_ALLOW];
    let mut n_allow = 0usize;
    let mut pin_uv_auth_param: Option<&[u8]> = None;
    let mut uv_required = false;
    let mut hmac_secret: Option<HmacSecretRequest> = None;

    for _ in 0..pairs {
        let key = match r.next().map_err(status_for)? {
            Item::Uint(k) => k,
            _ => return Err(CTAP2_ERR_INVALID_CBOR),
        };
        match key {
            0x01 => match r.next().map_err(status_for)? {
                Item::Text(v) => rp_id = Some(v),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            0x02 => match r.next().map_err(status_for)? {
                Item::Bytes(v) => client_data_hash = Some(v),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            0x03 => {
                let entries = match r.next().map_err(status_for)? {
                    Item::Array(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                for _ in 0..entries {
                    let n = match r.next().map_err(status_for)? {
                        Item::Map(n) => n,
                        _ => return Err(CTAP2_ERR_INVALID_CBOR),
                    };
                    let mut it = Reader::new(&body[r.position()..]);
                    if find_text_key(&mut it, n, "id").map_err(status_for)? {
                        match it.next().map_err(status_for)? {
                            Item::Bytes(v) => {
                                if n_allow < MAX_ALLOW {
                                    allow[n_allow] = v;
                                    n_allow += 1;
                                }
                            }
                            _ => return Err(CTAP2_ERR_INVALID_CBOR),
                        }
                    }
                    skip_map_pairs(&mut r, n).map_err(status_for)?;
                }
            }
            // 0x04: extensions. The client sends
            //   "hmac-secret": { 01: keyAgreement, 02: saltEnc, 03: saltAuth }
            // and every part of the tunnel carrying it was built by exp185.
            0x04 => {
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "hmac-secret").map_err(status_for)? {
                    let inner = match it.next() {
                        Ok(Item::Map(m)) => m,
                        Ok(_) => { return Err(CTAP2_ERR_INVALID_CBOR); }
                        Err(e) => { return Err(status_for(e)); }
                    };
                    let mut px = [0u8; 32];
                    let mut py = [0u8; 32];
                    let mut have_key = false;
                    let mut enc: Option<&[u8]> = None;
                    let mut tag: Option<&[u8]> = None;
                    for _ in 0..inner {
                        let k = match it.next() {
                            Ok(Item::Uint(k)) => k,
                            Ok(other) => { return Err(CTAP2_ERR_INVALID_CBOR); }
                            Err(e) => { return Err(status_for(e)); }
                        };
                        match k {
                            0x01 => {
                                let (x, y) = match parse_cose_key_point(&mut it) {
                                    Ok(v) => v,
                                    Err(e) => { return Err(e); }
                                };
                                px = x;
                                py = y;
                                have_key = true;
                            }
                            0x02 => match it.next() {
                                Ok(Item::Bytes(b)) => enc = Some(b),
                                Ok(o) => { return Err(CTAP2_ERR_INVALID_CBOR); }
                                Err(e) => { return Err(status_for(e)); }
                            },
                            0x03 => match it.next() {
                                Ok(Item::Bytes(b)) => tag = Some(b),
                                Ok(o) => { return Err(CTAP2_ERR_INVALID_CBOR); }
                                Err(e) => { return Err(status_for(e)); }
                            },
                            _ => it.skip().map_err(status_for)?,
                        }
                    }
                    match (have_key, enc, tag) {
                        (true, Some(e), Some(a)) => {
                            hmac_secret = Some(HmacSecretRequest {
                                peer_x: px,
                                peer_y: py,
                                salt_enc: e,
                                salt_auth: a,
                            })
                        }
                        _ => return Err(CTAP2_ERR_MISSING_PARAMETER),
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x05 => { // options map
                let n = match r.next().map_err(status_for)? {
                    Item::Map(n) => n,
                    _ => return Err(CTAP2_ERR_INVALID_CBOR),
                };
                let mut it = Reader::new(&body[r.position()..]);
                if find_text_key(&mut it, n, "uv").map_err(status_for)? {
                    if let Ok(Item::Bool(b)) = it.next() {
                        uv_required = b;
                    }
                }
                skip_map_pairs(&mut r, n).map_err(status_for)?;
            }
            0x06 => match r.next().map_err(status_for)? {
                Item::Bytes(v) => pin_uv_auth_param = Some(v),
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            // 0x07 is pinUvAuthProtocol, a uint. Reading it as Bytes refused
            // every request that named a protocol — the same shape of mistake
            // as makeCredential's 0x06, and found the same way.
            0x07 => match r.next().map_err(status_for)? {
                Item::Uint(_) => {}
                _ => return Err(CTAP2_ERR_INVALID_CBOR),
            },
            _ => r.skip().map_err(status_for)?,
        }
    }
    if !r.is_empty() {
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    let rp_id = rp_id.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    let client_data_hash = client_data_hash.ok_or(CTAP2_ERR_MISSING_PARAMETER)?;
    if client_data_hash.len() != 32 {
        return Err(CTAP2_ERR_INVALID_CBOR);
    }

    Ok(GetAssertion { rp_id, client_data_hash, allow, n_allow, pin_uv_auth_param, uv_required, hmac_secret })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a CBOR map from (key, value-bytes) pairs, already canonical.
    fn map(pairs: &[(u8, Vec<u8>)]) -> Vec<u8> {
        let mut v = vec![0xa0 | pairs.len() as u8];
        for (k, body) in pairs {
            v.push(*k);
            v.extend_from_slice(body);
        }
        v
    }
    fn bytes(b: &[u8]) -> Vec<u8> {
        let mut v = vec![];
        if b.len() < 24 { v.push(0x40 | b.len() as u8) } else { v.push(0x58); v.push(b.len() as u8) }
        v.extend_from_slice(b);
        v
    }
    fn text(s: &str) -> Vec<u8> {
        let mut v = vec![0x60 | s.len() as u8];
        v.extend_from_slice(s.as_bytes());
        v
    }
    fn cdh() -> Vec<u8> { bytes(&[7u8; 32]) }

    fn rp(id: &str) -> Vec<u8> {
        let mut v = vec![0xa1];
        v.extend(text("id"));
        v.extend(text(id));
        v
    }
    fn user() -> Vec<u8> {
        let mut v = vec![0xa1];
        v.extend(text("id"));
        v.extend(bytes(&[1u8; 16]));
        v
    }
    /// `[{"alg": -7, "type": "public-key"}]`, canonical: "alg" before "type".
    fn params() -> Vec<u8> {
        let mut v = vec![0x81, 0xa2];
        v.extend(text("alg"));
        v.push(0x26); // -7
        v.extend(text("type"));
        v.extend(text("public-key"));
        v
    }

    /// **The defect that cost exp188 and exp189.** `0x06` is `extensions` in
    /// makeCredential and `pinUvAuthParam` in getAssertion; a copy carried one
    /// numbering into the other, an extension map is not a byte string, and
    /// every request carrying any extension was refused with INVALID_CBOR.
    ///
    /// Measured on hardware before the fix: `fido2-cred -M -h` came back in
    /// 0.094 s instead of waiting out the user-presence window.
    #[test]
    fn make_credential_reads_0x06_as_extensions() {
        let mut ext = vec![0xa1];
        ext.extend(text("hmac-secret"));
        ext.push(0xf5); // true
        let req = map(&[
            (0x01, cdh()),
            (0x02, rp("example.test")),
            (0x03, user()),
            (0x04, params()),
            (0x06, ext),
        ]);
        let r = parse_make_credential(&req).expect("an extension map is not a parse error");
        assert_eq!(r.rp_id, "example.test");
        assert!(r.hmac_secret, "and the extension it names is read");
    }

    /// The same request with `hmac-secret: false` parses and asks for nothing.
    #[test]
    fn make_credential_without_the_extension_is_unaffected() {
        let req = map(&[(0x01, cdh()), (0x02, rp("example.test")), (0x03, user()), (0x04, params())]);
        let r = parse_make_credential(&req).unwrap();
        assert!(!r.hmac_secret);
        assert!(r.pin_uv_auth_param.is_none());
    }

    /// `0x08` is pinUvAuthParam here, and it really is a byte string.
    #[test]
    fn make_credential_reads_0x08_as_pin_uv_auth_param() {
        let req = map(&[
            (0x01, cdh()), (0x02, rp("example.test")), (0x03, user()),
            (0x04, params()), (0x08, bytes(&[9u8; 16])),
        ]);
        let r = parse_make_credential(&req).unwrap();
        assert_eq!(r.pin_uv_auth_param, Some(&[9u8; 16][..]));
    }

    /// **The second half of the same defect.** `0x07` in getAssertion is
    /// `pinUvAuthProtocol`, a uint — read as a byte string it refused every
    /// request that named its protocol.
    #[test]
    fn get_assertion_reads_0x07_as_a_uint() {
        let mut allow = vec![0x81, 0xa2];
        allow.extend(text("id"));
        allow.extend(bytes(&[3u8; 48]));
        allow.extend(text("type"));
        allow.extend(text("public-key"));
        let req = map(&[
            (0x01, text("example.test")),
            (0x02, cdh()),
            (0x03, allow),
            (0x06, bytes(&[9u8; 16])),
            (0x07, vec![0x01]), // pinUvAuthProtocol: 1
        ]);
        let r = parse_get_assertion(&req).expect("naming a PIN protocol is not a parse error");
        assert_eq!(r.rp_id, "example.test");
        assert_eq!(r.n_allow, 1);
        assert_eq!(r.pin_uv_auth_param, Some(&[9u8; 16][..]));
    }

    /// A request missing what the specification requires is refused, and with
    /// the code that says which kind of wrong it is.
    #[test]
    fn a_missing_parameter_is_not_an_invalid_cbor() {
        let req = map(&[(0x01, cdh()), (0x02, rp("example.test"))]);
        assert_eq!(parse_make_credential(&req).err(), Some(CTAP2_ERR_MISSING_PARAMETER));
    }

    #[test]
    fn a_client_data_hash_that_is_not_thirty_two_bytes_is_refused() {
        let req = map(&[
            (0x01, bytes(&[7u8; 31])), (0x02, rp("example.test")),
            (0x03, user()), (0x04, params()),
        ]);
        assert_eq!(parse_make_credential(&req).err(), Some(CTAP2_ERR_INVALID_CBOR));
    }

    /// Trailing bytes after a complete map are not ignored. A message that
    /// promises one thing and carries another is exp170's subject.
    #[test]
    fn bytes_after_the_map_are_refused() {
        let mut req = map(&[(0x01, text("example.test")), (0x02, cdh())]);
        req.push(0x00);
        assert_eq!(parse_get_assertion(&req).err(), Some(CTAP2_ERR_INVALID_CBOR));
    }

    /// A COSE key's negative labels — the shape that made `crates/cbor`'s
    /// canonical check refuse every real hmac-secret request.
    #[test]
    fn a_cose_key_point_is_read_out_of_its_negative_labels() {
        // {1: 2, 3: -25, -1: 1, -2: h'aa..', -3: h'bb..'}
        let mut k = vec![0xa5, 0x01, 0x02, 0x03, 0x38, 0x18, 0x20, 0x01];
        k.push(0x21);
        k.extend(bytes(&[0xaa; 32]));
        k.push(0x22);
        k.extend(bytes(&[0xbb; 32]));
        let mut r = Reader::new(&k);
        let (x, y) = parse_cose_key_point(&mut r).expect("negative labels are canonical");
        assert_eq!(x, [0xaa; 32]);
        assert_eq!(y, [0xbb; 32]);
    }
}
