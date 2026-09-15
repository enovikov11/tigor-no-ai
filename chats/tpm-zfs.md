I want my nixos home server to use a tpm to verify its state and secure boot, then reach my iphone OR pixel with recent attestation and key request, ask to authorize, and then once password/biometrics entered, they decrypt phone's safe store and wrap a key that then will unlock zfs

What protocols, apps, packets and open solutions can be used for this?

I want reasonably low amount of plumbing and custom stuff, as low as possible, while understanding then full stack solution likely not exists

--

Yes. The pieces exist, but the clean design is to treat this as **two independent attestations plus a key-release protocol**:

**server state → phone trusts server → human authorizes phone key → phone releases ZFS key to that exact boot instance.**

The part that does *not* really exist as an off-the-shelf product is the last 10–20% glue.

## What I would build

For the NixOS side, I would use **Lanzaboote + UEFI Secure Boot + measured boot + `systemd-pcrlock`**, with the actual unlock daemon inside the signed initrd/UKI. Current Lanzaboote has direct measured-boot support around `systemd-pcrlock`; its recommended useful PCRs include 0, 4 and 7, and its PCR 4 handling covers the Lanzaboote stub and, through the stub's verification, the kernel/initrd/cmdline. `systemd-stub` additionally measures UKI components into PCR 11. ([Nix community projects][1])

There is one NixOS-specific annoyance: Lanzaboote explicitly says its measured-boot integration does **not** integrate filesystem-level ZFS encryption. You need your own small unlock hook. ([Nix community projects][2]) Fortunately, OpenZFS makes that glue trivial: make the encryption root use `keyformat=raw,keylocation=prompt`; raw keys are exactly 32 random bytes, and `zfs load-key` will accept the raw key on stdin. ([openzfs.github.io][3])

The architecture I think gives the best plumbing/security ratio is:

| Piece                 | Minimal implementation                            |
| --------------------- | ------------------------------------------------- |
| NixOS boot            | Lanzaboote Secure Boot + measured boot            |
| Trusted boot endpoint | Tiny HTTPS `unlockd` in initrd                    |
| Proof of server boot  | TPM/PCR-bound TLS credential                      |
| Phone UI              | PWA/browser                                       |
| Human authorization   | WebAuthn + PRF, `userVerification=required`       |
| Phone notification    | standards-based Web Push                          |
| ZFS secret            | 32-byte raw key encrypted under phone-derived key |
| Transport             | TLS 1.3; no separate crypto protocol required     |
| Recovery              | separate offline ZFS recovery key                 |

The neat trick is the **TPM-bound TLS credential**.

Rather than implementing TPM quote verification on iOS and Android, encrypt the initrd HTTPS private key using `systemd-creds` and bind it to the desired TPM state. `systemd-creds` supports TPM2-bound credentials, explicit PCR bindings, and signed PCR policies. ([GitHub][4])

Conceptually:

```text
TPM state good
    |
    +--> unseal unlockd TLS private key
             |
             +--> phone can establish authenticated HTTPS
                       |
                       +--> FaceID / fingerprint / PIN
                                  |
                                  +--> recover/decrypt ZFS key
                                             |
                                             +--> POST key through TLS
                                                        |
                                                        +--> zfs load-key
```

If the machine boots an unapproved UKI, firmware configuration, Secure Boot policy, etc., it can't obtain the HTTPS identity. The TLS handshake itself provides freshness: an old recording of a successful boot doesn't let an attacker complete a new handshake.

This is **not identical to a remote TPM quote**. It's proof of possession of a secret that TPM policy only releases in a satisfactory boot state. For your use case, with a tiny one-shot initrd process that throws away its TLS key immediately after unlock, I think that's substantially simpler and quite defensible.

### The phone without writing native apps

WebAuthn's **PRF extension** is unusually well suited to this. WebAuthn Level 3 explicitly defines the `prf` extension for obtaining a credential-bound 32-byte pseudorandom value and calls out encrypting user data as a motivating use case. When backed by CTAP `hmac-secret`, the exposed PRF is the user-verified variant. ([W3C][5]) Safari has supported WebAuthn PRF for platform passkeys since Safari 18, so this works on current iPhones as well as the Android browser ecosystem. ([WebKit][6])

At enrollment, your PWA would roughly do:

```text
WebAuthn credential
        |
        +--- PRF(secret_salt) ---> 32-byte KEK
                                      |
                         AEAD_KEK(ZFS raw key)
                                      |
                            encrypted-key.bin
```

You can leave `encrypted-key.bin` on the server. It is useless without successful WebAuthn user verification.

At boot, the phone opens the unlock page, Face ID/fingerprint/PIN satisfies WebAuthn user verification, the browser evaluates the PRF, JavaScript decrypts the ZFS key locally, and sends it through the trusted TLS connection. The plaintext ZFS key exists in browser memory briefly and then in initrd memory briefly.

That gets you astonishingly close to your requested system with **zero native iOS/Android app development**.

There is a major caveat: **WebAuthn proves possession/user verification, not that this specific Pixel/iPhone has a fresh trustworthy OS state.** A synced passkey also deliberately weakens the notion that the credential belongs to one particular physical phone. If "recent phone attestation" is a hard security requirement rather than a nice-to-have, you need native platform APIs.

## If you really want TPM Quote remote attestation

Then I would use **Keylime**, rather than inventing a TPM verifier.

Keylime is specifically a TPM-based remote boot/runtime attestation system. Its agent obtains TPM quotes plus UEFI/IMA event logs; its registrar establishes TPM/AK identity; and its verifier evaluates the evidence. Keylime explicitly recommends UEFI event-log based measured-boot evaluation over static PCR allowlists because static PCRs are fragile across firmware/kernel/initrd changes. ([Keylime Documentation][7])

The crucial point is: **the verifier must not be the machine you're attesting**. Otherwise an evil boot can simply tell your phone, "yes, I checked myself, everything is excellent."

For one home server I'd put the Keylime verifier on something tiny and independent: another always-on device, a small VPS, or potentially implement just the verification portion in your phone application. Keylime is probably heavier than you need unless you want runtime IMA checking too.

If you write your own lean protocol instead, the packet flow I'd use is:

1. The initrd generates `request_id`, a random nonce `Ns`, and an ephemeral X25519/HPKE public key `E`. It asks the TPM for a Quote covering e.g. PCR 0/4/7/11, with the quote's qualifying data containing `H(request_id || Ns || E)`. That cryptographically binds the ephemeral key to this exact fresh attestation.
2. It sends `{quote, PCRs, UEFI event log, E, Ns}` to an **external verifier**. The verifier checks the TPM AK/EK identity, quote signature, nonce, PCR/event-log policy, approved NixOS generation, firmware policy, etc.
3. The verifier issues a short-lived signed result such as `{server, E, Ns, policyVersion, exp}`. This can just be COSE/JWS. If you want standards purity, IETF RATS/EAT is the family designed for this: RFC 9334 defines the RATS architecture and RFC 9711 defines Entity Attestation Tokens; measured-component claims were standardized in RFC 10013 in July 2026. ([IETF Datatracker][8])
4. Phone gets a push containing only `request_id`, obtains the attestation result, and verifies the verifier signature.
5. Phone displays something like `nas01 / NixOS generation 927 / firmware OK / Secure Boot OK` and requests biometrics/PIN.
6. Successful user authentication unlocks the phone-held KEK/private key; the phone obtains the 32-byte ZFS key.
7. Phone sends `HPKE(E, zfsKey || request_id || Ns)` plus its phone authentication/attestation proof.
8. Initrd decrypts it, feeds those 32 bytes to `zfs load-key`, zeroes buffers as best as practical, kills `unlockd`, and continues boot.

Binding `E` into the TPM quote is important. Otherwise a MITM could forward a perfectly valid TPM attestation from the genuine server while asking the phone to encrypt the key to an attacker-controlled key.

## Pixel: you can get the assurance you actually described

Android is much nicer for the strict version.

Android hardware-backed **Key Attestation** gives you an X.509 chain describing an Android Keystore key and whether it is protected by TEE or StrongBox. The verifier is expected to validate the Google hardware-attestation roots, certificate signatures and revocation state. ([Android Developers][9])

Your Android app can create a StrongBox/TEE key with a server-provided attestation challenge and require local authentication for every private-key operation. Android's `KeyGenParameterSpec` supports `setUserAuthenticationRequired(true)` and a zero timeout for per-use authorization via strong biometric/device credential. ([Android Developers][10])

So a Pixel implementation can get very close to:

```text
server TPM quote
      ↕
Pixel StrongBox-attested key
      |
BiometricPrompt
      |
ECDH / unwrap / signature
      |
release ZFS key
```

If by "recent attestation" you mean **prove right now that Android is still locked, certified and patched**, Google's easiest answer is Play Integrity. On Android 13+, `MEETS_STRONG_INTEGRITY` requires a genuine/certified device plus sufficiently recent OS and vendor security updates; Google currently defines recent as within the previous year. ([Android Developers][11])

That isn't open infrastructure, though. For something less Google-service-dependent, you can inspect Android hardware key-attestation fields yourself and generate a fresh attested ephemeral key periodically. That's more work and still ultimately depends on OEM/Google attestation roots.

## iPhone is the awkward side

For an ordinary native iOS app, **App Attest** is the closest available API. It creates a Secure-Enclave-backed App Attest key, has Apple certify it, and lets you generate assertions over server challenges/payloads. Apple describes it as proving a genuine Apple device, genuine app instance, and untampered request. ([Apple Developer][12])

You can separately create a `SecureEnclave.P256.KeyAgreement.PrivateKey`, protected using Keychain access-control flags. CryptoKit exposes P-256 ECDH directly inside Secure Enclave, and `.biometryCurrentSet` lets you require the currently enrolled Face ID/Touch ID state; changing the biometric enrollment invalidates the protected item. ([Apple Developer][13])

A pragmatic iPhone app therefore does:

```text
App Attest key  ------ signs/binds ------+
                                         |
Secure Enclave ECDH key -----------------+--> server registration
        |
FaceID/passcode ACL
        |
unwrap/re-wrap ZFS key
```

But there is a security distinction: App Attest attests the **app instance** very well; it isn't a generic API for asking "give me a fresh complete hardware/OS posture attestation for this arbitrary Secure Enclave ECDH key." Apple itself cautions that DeviceCheck/App Attest isn't definitive evidence against every compromised-OS condition. ([Apple Developer][14])

Apple does have exactly the stronger facility you'd ideally want: **Managed Device Attestation**. It can provide a challenge-fresh Apple-signed attestation describing device properties, and its ACME flow can attest that the certificate key is hardware-bound. The verifier can check software versions and device properties. ([Apple Developer][15])

Unfortunately, that's an MDM/device-management workflow. For a personal iPhone, adopting MDM solely to unlock your NAS is a lot of machinery.

So there is a fairly unavoidable asymmetry:

**Pixel:** native app + StrongBox + Android Key Attestation can do almost exactly what you want.

**iPhone without MDM:** App Attest + Secure Enclave + Face ID is very good, but isn't quite the same kind of fresh device-posture attestation.

**iPhone with MDM:** Managed Device Attestation gives you the stronger semantics, at the cost of substantial plumbing.

## Getting the request onto the phone

I wouldn't make the server directly initiate a connection to the phone. Mobile OSes fight that architecture.

For the low-plumbing PWA version, use **Web Push**. iOS has supported standards-based Web Push for Home Screen web apps since 16.4, and Apple explicitly says you don't need an Apple Developer membership for it. It uses the normal Push API/service-worker model. ([WebKit][16]) The wire standards are RFC 8030 Web Push, RFC 8291 encrypted push payloads, and RFC 8292 VAPID. ([RFC Editor][17])

The push should contain **no key material and ideally no sensitive attestation data**, just something like:

```json
{
  "request": "7Jd91...",
  "host": "nas01"
}
```

Then the phone fetches the actual authenticated request.

`ntfy` is another reasonable open-source notification shim. Be aware that instant iOS delivery ultimately needs APNs; ntfy's self-hosted iOS setup forwards a privacy-minimized poll request through an APNs-connected upstream. ([Ntfy][18])

## Where I'd draw the line

For your stated desire to minimize custom stuff, I'd start with:

**Lanzaboote + `systemd-pcrlock` → PCR-bound initrd HTTPS identity → PWA/Web Push → WebAuthn PRF + FaceID/fingerprint → raw ZFS key over TLS.**

That needs basically one small NixOS initrd service and one small web application. No Swift, Kotlin, Keylime, MDM, APNs credentials, or custom TPM parsing.

The security property is:

> "Only an approved measured boot can ask for the key, and only someone who can satisfy my phone's passkey user verification can release it."

If you later decide you truly need:

> "Only an approved measured boot can ask for the key, **and the releasing device must itself have freshly proved an acceptable hardware/OS state**"

then replace just the PWA side with native clients: **Android Key Attestation/StrongBox** on Pixel, and **App Attest + Secure Enclave** on ordinary iPhone or **Managed Device Attestation** if you're willing to manage the iPhone.

One thing I would definitely *not* compromise on: keep your **approved-PCR / approved-generation update authority and Secure Boot signing authority off the server being protected**, plus retain a paper/offline recovery ZFS key. Otherwise a root compromise of a legitimate boot can approve/sign the attacker's next boot, which makes the whole attestation ceremony rather theatrical. Lanzaboote itself also warns that `systemd-pcrlock` is still considered experimental and recommends keeping a recovery mechanism. ([Nix community projects][2])

[1]: https://nix-community.github.io/lanzaboote/explanation/measured-boot.html?utm_source=chatgpt.com "Measured Boot"
[2]: https://nix-community.github.io/lanzaboote/how-to-guides/enable-measured-boot.html?utm_source=chatgpt.com "Enable Measured Boot"
[3]: https://openzfs.github.io/openzfs-docs/man/master/7/zfsprops.7.html?utm_source=chatgpt.com "zfsprops.7 — OpenZFS documentation"
[4]: https://github.com/systemd/systemd/blob/main/man/systemd-creds.xml?utm_source=chatgpt.com "systemd/man/systemd-creds.xml at main · systemd/systemd · GitHub"
[5]: https://www.w3.org/TR/webauthn-3/?utm_source=chatgpt.com "Web Authentication: An API for accessing Public Key Credentials - Level 3"
[6]: https://webkit.org/blog/15865/webkit-features-in-safari-18-0/?utm_source=chatgpt.com "WebKit Features in Safari 18.0 | WebKit"
[7]: https://keylime.readthedocs.io/en/latest/?utm_source=chatgpt.com "Keylime Documentation — Keylime Documentation 7.14.2 documentation"
[8]: https://datatracker.ietf.org/group/rats/documents/?utm_source=chatgpt.com "Remote ATtestation ProcedureS (rats)"
[9]: https://developer.android.com/privacy-and-security/security-key-attestation?authuser=5&utm_source=chatgpt.com "Verify hardware-backed key pairs with key attestation  |  Security  |  Android Developers"
[10]: https://developer.android.com/reference/kotlin/android/security/keystore/KeyGenParameterSpec.Builder?utm_source=chatgpt.com "KeyGenParameterSpec.Builder  |  API reference  |  Android Developers"
[11]: https://developer.android.com/google/play/integrity/overview?utm_source=chatgpt.com "Overview of the Play Integrity API  |  Android Developers"
[12]: https://developer.apple.com/documentation/devicecheck/dcappattestservice?changes=_1%2C_1&utm_source=chatgpt.com "DCAppAttestService | Apple Developer Documentation"
[13]: https://developer.apple.com/documentation/cryptokit/secureenclave/p256/keyagreement/privatekey?changes=latest_2%2Clatest_2&utm_source=chatgpt.com "SecureEnclave.P256.KeyAgreement.PrivateKey | Apple Developer Documentation"
[14]: https://developer.apple.com/documentation/devicecheck?language=objc&utm_source=chatgpt.com "DeviceCheck | Apple Developer Documentation"
[15]: https://developer.apple.com/documentation/devicemanagement/validating-a-managed-device-attestation-attestation?utm_source=chatgpt.com "Validating a Managed Device Attestation | Apple Developer Documentation"
[16]: https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/?utm_source=chatgpt.com "Web Push for Web Apps on iOS and iPadOS | WebKit"
[17]: https://www.rfc-editor.org/info/rfc8030/?utm_source=chatgpt.com "RFC 8030: Generic Event Delivery Using HTTP Push | RFC Editor"
[18]: https://docs.ntfy.sh/config/?utm_source=chatgpt.com "Configuration - ntfy"

--

I would also add some non cleanable used defined pcr

Once startup sequence finished, extend that pcr rendering a booted machine no longer able to acquire a key

--

Exactly. I’d make that a first-class property of the protocol:

> **An acceptable boot has a short “key acquisition phase”. Once the key has been consumed, TPM state irreversibly transitions to “too late to request secrets” until the next reboot.**

And I would probably **reuse PCR 11 rather than allocate a new PCR**.

On a PC-class TPM, PCRs **0–15 are not resettable using `TPM2_PCR_Reset`**; they return to their initial state only through the appropriate TPM startup/reset cycle. PCR 16 and PCR 23 are explicitly resettable, so those are *not* what you want for this. ([Trusted Computing Group][1])

Conveniently, systemd's measured-boot design already uses PCR 11 exactly as a monotonic boot-phase register:

```text
UKI measurements
      ↓
PCR11 = H(...UKI...)

enter-initrd
      ↓
PCR11 = H(old || H("enter-initrd"))

... phone key release allowed HERE ...

unlock-complete
      ↓
PCR11 = H(old || H("unlock-complete"))

... impossible to return to previous PCR11 until reboot ...
```

`systemd-pcrphase` already extends PCR 11 at milestones including `enter-initrd`, `leave-initrd`, `sysinit`, `ready`, `shutdown`, and `final`, and explicitly supports administrators adding finer-grained phases. The documentation specifically calls out using this mechanism to make a key inaccessible after leaving the appropriate boot phase. ([Man ArchLinux][2])

That is almost exactly your requirement.

### I would make the unlock protocol state machine something like

```text
                 TPM reset
                    │
                    ▼
              ┌────────────┐
              │ boot starts │
              └─────┬──────┘
                    │ measured UKI
                    ▼
            PCR11 = BOOTED_INITRD
                    │
                    │ network comes up
                    ▼
            ┌─────────────────┐
            │ ACQUIRE_ALLOWED │
            └────────┬────────┘
                     │
      fresh TPM quote + phone challenge
                     │
                     ▼
             biometric approval
                     │
                     ▼
                receive key
                     │
                     ▼
               zfs load-key
                     │
                     │ success
                     ▼
         TPM2_PCR_Extend(PCR11,
                 H("zfs-unlock-consumed-v1"))
                     │
                     ▼
            ┌─────────────────┐
            │ ACQUIRE_BURNED  │
            └────────┬────────┘
                     │
                     ▼
              switch_root
```

The phone should only release a key if the TPM quote contains the **pre-burn PCR11 value**.

After the extension, a new fresh quote cannot satisfy that policy.

This also protects against something like:

```text
1. machine boots correctly
2. user unlocks it
3. attacker gets root later
4. attacker asks phone for ZFS key again
```

At step 4 the TPM quote now contains the post-unlock PCR11 state, so the phone rejects it.

## Don't use PCR 23 for this

PCR 23 sounds tempting because TCG labels it `Application Support`.

Unfortunately it's specifically resettable by software. PCR 16 is similarly unsuitable. Current TCG PC Client profiles make PCRs 0–15 non-resettable via `TPM2_PCR_Reset`, while PCR 16 and 23 are resettable from normal localities. ([Trusted Computing Group][1])

I also wouldn't casually commandeer another static PCR like PCR 8. PCR space is annoyingly scarce, and Linux already has conventions for 8–15. The Linux TPM PCR registry explicitly warns that co-opting PCRs used by another component is likely to cause problems. PCR 11 is *already intended* for UKI identity plus boot phases. ([GitHub][3])

So:

```text
PCR 7   Secure Boot policy
PCR 11  UKI + your boot-phase state machine
PCR 12  kernel configuration / external parameters
perhaps PCR 0/2/4 as desired
```

is cleaner than inventing `PCR_X = unlock-used`.

### Add your own phase to PCR11

Conceptually, your initrd unlock service can just perform the equivalent of:

```bash
systemd-pcrextend \
    --pcr=11 \
    --graceful \
    "zfs-unlock-consumed-v1"
```

I'd verify the exact CLI against whatever systemd version NixOS has when implementing it, but `systemd-pcrextend` is the systemd-native primitive for these userspace measurements. Systemd's measurement docs explicitly describe PCR 11 as carrying custom boot-phase measurements. ([Systemd][4])

I would log the corresponding event as well, rather than merely extending an opaque digest. That makes future attestation debugging much less unpleasant.

## There is one subtle ordering issue

I'd make this:

```text
receive key
    ↓
zfs load-key
    ↓
verify success
    ↓
BURN PCR
```

rather than:

```text
receive key
    ↓
BURN PCR
    ↓
zfs load-key
```

Otherwise a mundane `zfs load-key` failure turns into:

> reboot the whole machine and Face-ID it again.

There's consequently a tiny period between receiving the key and burning the PCR.

Make `unlockd` single-threaded and incapable of servicing another request during that period:

```text
WAITING
  ↓
AUTH_IN_PROGRESS
  ↓
KEY_RECEIVED       ← no new connections accepted
  ↓
ZFS_UNLOCKED
  ↓
PCR_BURNED
  ↓
EXIT
```

Then stop/remove the initrd network service before `switch_root`.

You can make this even stronger by **burning immediately after `zfs load-key` succeeds, before mounting/importing anything attacker-controlled**.

## Freshness becomes very important

The phone must not accept some quote that the server generated earlier while PCR11 was still in the allowed state.

So the quote's `extraData`/qualifying data should include a phone-generated challenge:

```text
C = random(32)
```

and preferably also bind the server's one-time transport key:

```text
Q.extraData =
    SHA256(
        "zfs-unlock-v1" ||
        phone_nonce ||
        boot_request_id ||
        ephemeral_x25519_public_key
    )
```

Then:

```text
Phone                                  Server / initrd

C=random()
------------------------------------->

                              generate ephemeral E

                     TPM Quote(
                       PCR 7,11,...,
                       extraData=H(C || E || id)
                     )

<---------- Quote + eventlog + E -------

verify:
  quote sig
  challenge
  PCR11 == ACQUIRE_ALLOWED
  event log
  UKI / SB state

FaceID / fingerprint

HPKE(E, ZFS key || C || id)
------------------------------------->

                                 decrypt
                                 zfs load-key
                                 PCR11 extend "consumed"
                                 erase E private key
                                 exit
```

That prevents replaying an old pre-burn quote after the PCR has moved on.

### One further improvement

Earlier I suggested TPM-unsealing a TLS private key. With this one-shot design I'd slightly revise that.

If you **unseal a software TLS private key into RAM** while PCR11 is good, extending PCR11 afterward doesn't magically erase that already-unsealed key.

So for the strongest interpretation of your property, either:

* use a **TPM-resident signing/private key whose operation itself is authorized by the PCR policy**, or
* use only a one-shot ephemeral session and explicitly destroy everything immediately after the PCR transition.

The second is dramatically easier and is probably what I'd do for a home server.

The phone's security decision should ultimately be based on the **fresh TPM quote**, not solely "HTTPS worked".

## There's also a nice consequence

You don't actually need the phone to recognize every later systemd phase.

It has exactly one accepted PCR11 state per permitted UKI:

```text
allowed:
    H(UKI measurements
      || enter-initrd
      || perhaps networking-ready
      || unlock-server-ready)

everything else:
    reject
```

Then after successful release:

```text
PCR11 ← extend("zfs-unlock-consumed-v1")
```

and that boot can never satisfy another acquisition request.

That is a considerably stronger design than just checking measured boot. It turns the TPM into a **hardware-backed one-shot capability per boot**.

The only thing I'd avoid calling it is literally a "user-defined PCR": using **your own phase/event within PCR11** fits the existing Linux/systemd measured-boot model much better, and gets the non-resettable-until-reboot behavior you're after. ([GitHub][3])

[1]: https://trustedcomputinggroup.org/wp-content/uploads/PC-Client-Specific-Platform-TPM-Profile-for-TPM-2p0-v1p07_Pub.pdf?utm_source=chatgpt.com "TCG PC Client Platform TPM Profile Specification for TPM 2.0"
[2]: https://man.archlinux.org/man/core/systemd/systemd-pcrmachine.service.8.en?utm_source=chatgpt.com "systemd-pcrmachine.service(8) — Arch manual pages"
[3]: https://github.com/uapi-group/specifications/blob/main/specs/linux_tpm_pcr_registry.md "specifications/specs/linux_tpm_pcr_registry.md at main · uapi-group/specifications · GitHub"
[4]: https://systemd.io/TPM2_PCR_MEASUREMENTS/?utm_source=chatgpt.com "TPM2 PCR Measurements Made by systemd"

--

I would add an additional tpm involvement, let browser unwrap a not zfs key but some key that tpm later can unwrap to zfs key

So browser compromise alone would not be sufficient

--

Yes. I think that is a better construction than letting WebAuthn/JavaScript ever see `K_zfs`.

The nice TPM-native version is:

```text
                    phone
                     │
              FaceID / biometric
                     │
              WebAuthn PRF
                     │
                     ▼
             decrypt TPM capsule
             (NOT the ZFS key)
                     │
                     ▼
network ─────── opaque TPM2B_PRIVATE ───────► server
                                                │
                                                ▼
                                         TPM2_Load()
                                                │
                                  PCR policy + boot phase
                                                │
                                                ▼
                                         TPM2_Unseal()
                                                │
                                                ▼
                                            K_zfs
                                                │
                                         zfs load-key
                                                │
                                      extend PCR "consumed"
```

A TPM sealing object can contain your 32-byte ZFS key directly; `tpm2_create` supports sealing up to 128 bytes. Its authorization policy can incorporate PCR state, and `PolicyCommandCode` can restrict use specifically to `TPM2_Unseal`. ([TPM2 Tools][1])

### The especially nice trick: encrypt the TPM private blob

At provisioning:

```text
Kzfs = random(32)

TPM:
    create SRK / persistent parent

    create sealed object:
        sensitiveData = Kzfs
        policy =
            PolicyPCR(expected boot state including pre-burn PCR11)
            AND PolicyCommandCode(TPM2_CC_Unseal)

outputs:
    seal.pub
    seal.priv          # TPM2B_PRIVATE
```

`seal.priv` is **not `Kzfs` encrypted with some ordinary software key**. It is a TPM private object blob protected by its TPM parent. With the normal `fixedTPM|fixedParent` properties, it is useful only with that TPM/parent relationship.

Then enroll the phone:

```text
Kphone = WebAuthn-PRF(credential, fixed enrollment salt)

capsule =
    AES-256-GCM(
        key = HKDF(Kphone, "nixos-zfs-tpm-capsule-v1"),
        plaintext = seal.priv,
        AD = seal.pub || machine-id || version
    )
```

Store:

```text
server:
    seal.pub
    capsule
    salt
    WebAuthn credential metadata
```

You could equally store the capsule on the phone; cryptographically it doesn't matter much.

WebAuthn Level 3's PRF extension is explicitly designed to expose a credential-bound pseudorandom secret for applications such as protecting encrypted data. Level 3 became a W3C Recommendation in August 2026. ([W3C][2])

So JavaScript sees:

```text
Kphone
seal.priv
```

but **never sees `Kzfs`**.

And `seal.priv` by itself is essentially an opaque bearer capsule for *that TPM*, subject to the TPM object's policy.

## I would actually add one more TPM condition

I'd make the object policy approximately:

```text
PolicyPCR(
    SecureBoot/firmware PCRs,
    PCR11 == approved UKI + "enter-initrd" + "unlock-ready"
)

AND

PolicyCommandCode(Unseal)

AND optionally

PolicyAuthValue
```

`PolicyAuthValue` lets the object require an additional authorization value as part of the TPM policy; TPM2 tooling explicitly supports composing an object's authorization policy this way. ([TPM2 Tools][3])

You could put a random:

```text
Aphone = random(32)
```

inside the browser-encrypted capsule too:

```text
browser capsule plaintext:

{
    tpmPrivateBlob: seal.priv,
    objectAuth: Aphone
}
```

and create the sealed TPM object with `authValue=Aphone`.

Then:

```text
TPM2_Load(seal.pub, seal.priv)

policy session:
    PolicyPCR(...)
    PolicyAuthValue()
    PolicyCommandCode(Unseal)

TPM2_Unseal(auth=Aphone)
```

That makes your intended AND relationship explicit inside the TPM:

```text
correct TPM
    AND
correct PCR state
    AND
phone-provided secret
    AND
operation == Unseal
```

`PolicyAuthValue` exists precisely to make possession of the object's authorization value part of a policy session. ([TPM2 Tools][3])

I would use a salted/encrypted TPM authorization session when passing that value to a discrete TPM. `tpm2_startauthsession` supports AES-CFB parameter encryption for exactly this sort of traffic, so someone sniffing LPC/SPI isn't handed the authorization material trivially. ([TPM2 Tools][4])

It obviously doesn't hide it from your measured initrd process itself.

## But there's an important replay problem

Suppose evil JavaScript compromises Safari during one legitimate unlock.

You authenticate once:

```text
FaceID
  ↓
PRF
  ↓
decrypt seal.priv + Aphone
```

Malicious JS can now exfiltrate:

```text
seal.priv
Aphone
```

It still cannot recover `Kzfs` without your TPM in the correct PCR state, which satisfies your original goal:

> browser compromise alone is insufficient.

But it has effectively stolen the **phone half forever**.

On a later legitimate boot:

```text
attacker has seal.priv + Aphone
              +
server TPM enters ACQUIRE_ALLOWED PCR state
              ↓
TPM can unseal
```

So the browser's intermediate secret must not be considered proof of **fresh user consent**.

I'd therefore use *two* WebAuthn properties:

```text
WebAuthn assertion
    = freshness / user consent for THIS boot

WebAuthn PRF
    = decrypt opaque TPM material
```

### Per-boot protocol

Server generates:

```text
boot_id     = random(32)
server_eph  = X25519 ephemeral public key
TPM quote extraData =
    H(
      "zfs-unlock-v1"
      || boot_id
      || server_eph
      || phone_challenge
    )
```

Phone verifies the TPM quote and its pre-consumption PCR11.

Then invoke WebAuthn with:

```text
challenge =
    H(
      quote
      || boot_id
      || server_eph
      || "authorize-zfs-unlock-v1"
    )

userVerification = "required"

extensions:
    prf = ...
```

The result gives you both:

```text
1. fresh signed WebAuthn assertion
2. PRF output
```

The assertion is boot-specific and replay-resistant.

The PRF output decrypts:

```text
seal.priv + Aphone
```

Phone sends something approximately:

```text
{
    boot_id,
    webauthn_assertion,
    encrypted_transport {
        seal_private,
        object_auth
    }
}
```

to the initrd.

The measured initrd:

```text
verify WebAuthn assertion
verify challenge == this boot request

TPM2_Load(seal.pub, seal.priv)

start TPM policy session
PolicyPCR(current PCRs)
PolicyAuthValue()
PolicyCommandCode(Unseal)

Kzfs = TPM2_Unseal(...)

zfs load-key

PCR11 <- Extend("zfs-unlock-consumed-v1")

zero Kzfs
zero Aphone
flush TPM object
flush policy session
destroy server ephemeral key
kill unlock daemon
```

Thus stealing yesterday's browser state doesn't authorize today's boot.

## There's an even simpler variant

On reflection, this is worth comparing:

```text
phone
  │
fresh WebAuthn assertion
  │
  ▼
trusted measured unlockd
  │
  │ only after verifying assertion
  ▼
TPM2_Unseal(Kzfs, PCR policy)
```

Here the server can store `seal.priv` openly.

That's already quite strong because `TPM2B_PRIVATE` is useless away from its TPM, and a modified `unlockd` changes the measured boot state and therefore cannot unseal.

The security boundary becomes:

```text
TPM enforces:
    correct code + correct boot phase

measured unlockd enforces:
    fresh phone authorization
```

The browser never handles any encryption key other than its WebAuthn credential.

That actually has **better resistance to a one-time browser compromise** than exposing a long-lived PRF result/auth secret, because a captured WebAuthn assertion is tied to one random challenge.

Your extra encrypted TPM-capsule layer nevertheless gives a valuable additional property:

> even an approved boot cannot *attempt* to load/unseal the ZFS-key object until the phone supplies the missing TPM material.

I like that defense-in-depth.

## The theoretically cleanest version needs a native phone client

TPM has an even more elegant primitive for what we're trying to do:

```text
PolicyPCR(...)
AND
PolicySigned(phone-public-key)
AND
PolicyCommandCode(Unseal)
```

`TPM2_PolicySigned` lets an external signing authority authorize a TPM policy session; importantly, it can include the TPM session's `nonceTPM`, expiration, `cpHashA`, and `policyRef`. That makes the authorization fresh and TPM-native rather than relying on `unlockd` to verify it. ([TPM2 Tools][5])

It would look beautiful:

```text
TPM starts policy session
        │
        ├── nonceTPM
        │
        ▼
phone Secure Enclave / StrongBox
        │
   biometric approval
        │
   signs authorization
        │
        ▼
TPM PolicySigned
        │
PolicyPCR + PolicySigned + Unseal-only
        │
        ▼
       Kzfs
```

Now the TPM itself enforces:

```text
good PCR state
AND
fresh phone signature
AND
only Unseal
```

No long-lived phone secret ever enters server RAM.

Unfortunately **ordinary WebAuthn doesn't map directly onto `TPM2_PolicySigned`**. WebAuthn authenticators don't give JavaScript a raw `"sign these exact TPM bytes"` primitive: the assertion signature covers WebAuthn's authenticator data plus the client-data hash, with the RP/origin/challenge semantics baked in. `TPM2_PolicySigned`, meanwhile, verifies its own precisely defined authorization structure involving things such as `nonceTPM` and `cpHashA`. ([TPM2 Tools][5])

With your own Android/iOS app, however, a StrongBox/Secure-Enclave signing key can do this directly.

That would be my **end-game architecture**.

### So I'd rank them

| Design                                            | Browser sees ZFS key | TPM enforces phone factor | Fresh approval | Plumbing |
| ------------------------------------------------- | -------------------: | ------------------------: | -------------: | -------: |
| PRF decrypts ZFS key                              |              **yes** |                        no |            yes |   lowest |
| WebAuthn assertion → measured daemon → TPM unseal |                   no |                indirectly |        **yes** |      low |
| PRF unwraps TPM blob/auth + fresh assertion → TPM |                   no |                    partly |        **yes** |   medium |
| Native phone key → `TPM2_PolicySigned` + PCR      |                   no |                   **yes** |        **yes** |  highest |

For what you're describing now, I'd choose the **third**.

In other words, the browser is not a key escrow endpoint. It is a **courier for a TPM capability**:

```text
                   ┌────────────────────┐
                   │      iPhone        │
                   │                    │
                   │ FaceID             │
                   │   ↓                │
                   │ WebAuthn assertion │── fresh permission
                   │ WebAuthn PRF       │
                   │   ↓                │
                   │ opaque TPM capsule │
                   └─────────┬──────────┘
                             │
                             ▼
┌────────────────────────────────────────────────┐
│                measured initrd                 │
│                                                │
│ verify fresh WebAuthn assertion                │
│           │                                    │
│           ▼                                    │
│     TPM2_Load(capsule)                         │
│           │                                    │
│ PCR7 + PCR11 + authValue + Unseal-only         │
│           │                                    │
│           ▼                                    │
│        Kzfs ───────────────► zfs load-key      │
│           │                                    │
│           └───────────────► PCR11 "consumed"   │
└────────────────────────────────────────────────┘
```

That has a property I think is particularly appropriate for your threat model: **there is never a protocol packet anywhere containing the ZFS key**, even encrypted specifically for the phone. The only place outside the TPM that `Kzfs` exists is the measured initrd for the very short interval required to feed it to OpenZFS.

[1]: https://tpm2-tools.readthedocs.io/en/latest/man/tpm2_create.1/?utm_source=chatgpt.com "tpm2_create - tpm2-tools"
[2]: https://www.w3.org/news/2026/web-authentication-an-api-for-accessing-public-key-credentials-level-3-is-now-a-w3c-recommendation/?utm_source=chatgpt.com "Web Authentication: An API for accessing Public Key Credentials Level 3 is now a W3C Recommendation | 2026 | News | W3C"
[3]: https://tpm2-tools.readthedocs.io/en/stable/man/tpm2_policyauthvalue.1/?utm_source=chatgpt.com "tpm2_policyauthvalue - tpm2-tools"
[4]: https://tpm2-tools.readthedocs.io/en/latest/man/tpm2_startauthsession.1/?utm_source=chatgpt.com "tpm2_startauthsession - tpm2-tools"
[5]: https://tpm2-tools.readthedocs.io/en/latest/man/tpm2_policysigned.1/?utm_source=chatgpt.com "tpm2_policysigned - tpm2-tools"

--

I love web and tpm backed tls part of it

--

Then I’d lean into that and make **HTTPS itself the primary server identity channel**, with explicit TPM attestation layered into the application protocol only where it adds something.

The clean version is:

```text
iPhone / Pixel browser
        │
        │ TLS 1.3
        ▼
TPM-backed server TLS key
        │
        ├─ private key never leaves TPM
        │
        └─ only usable in allowed PCR/boot phase
```

Then the browser gets two useful guarantees at once:

1. It is talking to the enrolled physical TPM/server.
2. That TPM will only perform the TLS private-key operation while the machine is in an approved boot state.

For the implementation, I’d prefer a **real TPM-resident TLS key** over “TPM unseals PEM private key into initrd RAM.” `tpm2-openssl` is an OpenSSL 3 provider that supports TPM-backed signing/ECDH keys, including persistent TPM handles. ([GitHub][1])

So conceptually:

```text
TPM persistent key Ktls
    attributes: fixedTPM, fixedParent, signing
    authPolicy:
        approved boot PCRs
        AND
        PCR11 == "unlock-ready"
```

and:

```text
HTTPS server
    cert = cert.pem
    key  = TPM handle/object
```

The TLS certificate can be utterly boring. I'd create my own tiny CA once, trust that CA/profile on the phones, and issue:

```text
DNS: unlock.home.example
public key: Ktls.pub
```

The CA cert isn't the interesting security element. The important part is that the private key associated with that certificate literally cannot perform the TLS signature unless the TPM policy session succeeds.

That gives a very nice lifecycle:

```text
BOOT

PCR11:
  UKI measurements
  + enter-initrd
  + unlock-ready

             HTTPS works
                  │
                  ▼
       phone visits unlock URL
                  │
          browser verifies TLS
                  │
          WebAuthn / biometric
                  │
                  ▼
           authorize release
                  │
                  ▼
            TPM unseals Kzfs
                  │
             zfs load-key
                  │
                  ▼
PCR11 += "zfs-unlock-consumed"

             HTTPS key policy
                  ↓
             no longer valid
```

And then something amusing happens:

**the HTTPS endpoint cryptographically dies after successful boot.**

A process can remain listening on `:443`, but the TPM will refuse subsequent TLS private-key operations because PCR11 no longer matches.

That's an excellent property.

Systemd already treats PCR11 as the UKI/boot-phase PCR, and explicitly supports administrators extending it with additional phases. ([Systemd][2])

### One complication I'd test early

I'd prototype **TPM-backed TLS before writing any other component**.

`tpm2-openssl` absolutely supports TPM signing operations, but TLS stresses TPM resource handling more than a one-shot signature. Its own installation documentation says complex SSL/X.509 workloads may need `tpm2-abrmd` rather than relying solely on `/dev/tpmrm`; there have also been OpenSSL-3-provider TLS interoperability/issues reported upstream. ([GitHub][3])

For your application that's not necessarily bad: the unlock server gets maybe **one TLS connection per boot**, not nginx serving 50k requests/sec.

I'd actually deliberately make it extremely boring:

```text
one listener
one TLS connection at a time
TLS 1.3 only
P-256 TPM signing key
tiny static HTML/JS bundle
~3 API methods
process exits after successful unlock
```

No reverse proxy if you can avoid it.

### Your browser side can stay almost completely standard

I like this because you can reduce the browser application to roughly:

```text
GET /
GET /api/challenge
POST /api/authorize
```

The browser doesn't need TPM libraries.

Something like:

```text
GET /api/challenge

{
    "boot_id": "...",
    "challenge": "...",
    "host": "nas.example",
    "generation": "...",
    "expires": "..."
}
```

Then:

```text
navigator.credentials.get({
    publicKey: {
        challenge: ...,
        rpId: "unlock.example",
        userVerification: "required",
        ...
    }
})
```

followed by:

```text
POST /api/authorize
{
    "boot_id": "...",
    "webauthn": ...
}
```

The initrd verifies it and then asks the TPM to perform the second protected operation that ultimately releases `Kzfs`.

So you get:

```text
                         TPM
                       ┌───────┐
TLS handshake ────────►│ Ktls  │◄── PCR policy
                       │       │
ZFS key unseal ───────►│ Kzfs  │◄── PCR + phone auth
                       └───────┘
```

That separation is quite nice. The TPM has one object for **"may this boot prove itself to the phone?"** and another for **"may this boot obtain storage secrets?"**

### I would still include an explicit fresh quote

Even though TPM-backed TLS gives you a very useful implicit attestation, I'd probably have `/api/challenge` return a TPM quote too.

Not because TLS isn't useful, but because these answer subtly different questions:

```text
TPM-backed TLS:
    "the TPM allowed use of Ktls"

TPM quote:
    "here are the actual current PCR values,
     signed now in response to your nonce"
```

Then your web UI can eventually show something genuinely useful:

```text
NAS01

✓ TLS identity bound to TPM
✓ Secure Boot
✓ expected UKI
✓ NixOS generation 1842
✓ unlock phase active
✓ fresh TPM quote: 0.3 s ago

[ Authorize unlock ]
```

You could start without quote parsing in JS and add it later.

In fact, a nice minimal first version is:

```text
V1:
TPM-policy TLS
+ WebAuthn
+ TPM sealed ZFS key
+ PCR burn

V2:
add explicit quote + event log verification

V3:
native phone app / PolicySigned if desired
```

That gives you useful security at every stage rather than requiring a huge attestation stack before anything works.

### One detail I would change from the earlier design

I wouldn't put your whole trust policy into a pile of fixed raw PCR hashes if you can avoid it.

Systemd's current measured-boot machinery is increasingly built around **signed PCR policies**, precisely because software updates otherwise change PCR values and require resealing everything. PCR11 is explicitly the systemd UKI/boot-phase chain. ([Systemd][2])

Ideally:

```text
Ktls policy:

PolicyPCR(PCR7, ...)
AND
signed policy authorizing approved PCR11 states
```

Then your offline/update signing authority can say:

```text
generation 1842: unlock-ready PCR11 = X
generation 1843: unlock-ready PCR11 = Y
generation 1844: unlock-ready PCR11 = Z
```

without ever recreating `Ktls`.

The authorization key stays off the NAS.

And your terminal event:

```text
systemd-pcrextend --pcr=11 \
    "zfs-unlock-consumed-v1"
```

takes you into a state for which you've deliberately issued **no signed policy**.

So there simply isn't an authorization path back to the TLS key until reboot.

---

If I were implementing this on your NixOS machine, my first prototype would be only about 5 pieces:

```text
Lanzaboote / UKI
        │
        ▼
systemd PCR11 phases
        │
        ▼
tpm2-openssl
        │
        ▼
minimal HTTPS daemon in initrd
        │
        ▼
Safari/Chrome connects using TPM-held TLS key
```

Once that handshake reliably works, adding WebAuthn and the ZFS sealed object is comparatively mundane.

And aesthetically I agree with your instinct here: **making a normal browser TLS handshake itself depend on the machine still being in its one-shot trusted boot phase is much cleaner than inventing a bespoke "attestation transport protocol."** The weird crypto stays behind OpenSSL/TPM APIs; everything above it remains ordinary HTTPS.

[1]: https://github.com/tpm2-software/tpm2-openssl/blob/master/docs/asymmetric.md?utm_source=chatgpt.com "tpm2-openssl/docs/asymmetric.md at master · tpm2-software/tpm2-openssl · GitHub"
[2]: https://systemd.io/TPM2_PCR_MEASUREMENTS/?utm_source=chatgpt.com "TPM2 PCR Measurements Made by systemd"
[3]: https://github.com/tpm2-software/tpm2-openssl/blob/master/docs/INSTALL.md?utm_source=chatgpt.com "tpm2-openssl/docs/INSTALL.md at master · tpm2-software/tpm2-openssl · GitHub"
