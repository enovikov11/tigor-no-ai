What alternatives to tty password auth exist in nixos

--

On a normal NixOS virtual console, the path is roughly `agetty → login(1) → PAM`, so you can replace `pam_unix` password auth with essentially any PAM authentication mechanism.

The practical choices are:

| Method                              | NixOS support                            | Good password replacement? | Notes                                                                                |
| ----------------------------------- | ---------------------------------------- | -------------------------: | ------------------------------------------------------------------------------------ |
| **FIDO2/U2F hardware key**          | `pam_u2f`                                |      **Yes — best choice** | YubiKey, Nitrokey, SoloKey, etc. Touch/PIN depending on configuration.               |
| **PKCS#11 smartcard/token**         | `pam_p11`                                |                    **Yes** | PIV/CAC, OpenSC cards, USB crypto tokens.                                            |
| **Fingerprint**                     | `fprintd`                                |                      Maybe | Convenient, but I'd keep another auth method available.                              |
| **TOTP/OATH**                       | `pam_google_authenticator`, OATH Toolkit |             Usually as 2FA | Typing six digits at a TTY isn't much nicer than a password.                         |
| **YubiKey OTP/challenge-response**  | `yubico-pam`                             |                    Yes-ish | Older YubiKey-specific route; FIDO2/U2F is generally preferable now.                 |
| **Kerberos / SSSD / Kanidm / LDAP** | PAM integration                          |                        Yes | Makes sense for centrally managed identities.                                        |
| **SSH-agent based auth**            | `pam_ssh_agent_auth`, `rssh`, `pam-ussh` |                Situational | Much more useful for `sudo`/remote sessions than a fresh physical TTY.               |
| **Autologin**                       | getty configuration                      |                Technically | No authentication at all; reasonable if FDE is your actual physical-access boundary. |

NixOS's current PAM module explicitly exposes U2F, PKCS#11, fingerprint, OATH, Google Authenticator, Yubico, SSH-agent auth, SSSD, Kerberos, Kanidm, etc. ([GitHub][1])

### FIDO2/U2F is probably what you want

For a hardware security key, a simple setup is:

```nix
{
  security.pam.u2f = {
    enable = true;
    control = "sufficient";

    settings = {
      cue = true;
      authfile = "/etc/u2f-mappings";
    };
  };

  security.pam.services.login = {
    u2f.enable = true;

    # Keep this true initially!
    unixAuth = true;
  };
}
```

Generate the mapping using `pamu2fcfg`; NixOS's documentation uses the same mechanism. `control = "sufficient"` means a successful security-key authentication can replace the password. Setting it to `"required"` instead makes the key an additional factor. ([MyNixOS][2])

Once you've verified it from **another TTY while keeping a root shell open**, you can make the console genuinely passwordless:

```nix
security.pam.services.login = {
  u2f.enable = true;
  unixAuth = false;
};
```

NixOS documents exactly this arrangement for hardware-key-only login. ([NixOS Wiki][3])

I'd put the mappings in something like `/etc/u2f-mappings` rather than `~/.config/Yubico/u2f_keys`. It avoids awkward bootstrapping if `$HOME` is encrypted, network-mounted, or otherwise unavailable before PAM succeeds.

Also enroll **two hardware keys**. Otherwise losing one key changes "passwordless authentication" into "boot rescue media."

### Smartcard / PIV

For something more traditional cryptographically:

```nix
{
  services.pcscd.enable = true;

  security.pam.p11.enable = true;

  security.pam.services.login = {
    p11Auth = true;
    # unixAuth = false; # only after testing
  };
}
```

`pam_p11` can authenticate against public keys in `~/.ssh/authorized_keys` or certificates in `~/.eid/authorized_certificates`, using the private key on a PKCS#11 token. ([MyNixOS][4])

This is attractive if you're already using a YubiKey PIV applet/OpenSC smartcard infrastructure.

### Fingerprint

For laptops:

```nix
{
  services.fprintd.enable = true;
  security.pam.services.login.fprintAuth = true;
}
```

Enroll with:

```bash
fprintd-enroll
```

NixOS wires `fprintd` into PAM when enabled. ([NixOS Wiki][5])

I wouldn't make fingerprint your **sole recovery credential**. Fingerprints are not replaceable secrets, reader support varies, and PAM/fprintd integration has had some rough edges around display managers and suspend. For TTY-only use it's simpler than the graphical cases, but FIDO2 is a cleaner security primitive.

### If you already have FDE

There's another reasonable design:

```text
power-on
   ↓
LUKS2 + FIDO2/PIN
   ↓
system boots
   ↓
agetty autologin
```

NixOS 26.05 supports FIDO2-backed LUKS2 through `systemd-cryptenroll`, and recent NixOS also has `services.getty.autologinOnce`, specifically useful when you've already authenticated while decrypting the machine and don't want to enter another credential immediately afterward. ([NixOS Wiki][6])

For a **single-user physically secured workstation**, I actually like:

**FIDO2 + PIN for LUKS → autologinOnce on tty1 → FIDO2 for `sudo` / screen unlock**

better than asking for basically the same human credential two or three times during startup. The disk-unlock credential protects data at rest; the later FIDO challenge protects privilege escalation and unattended sessions.

If your actual goal is **"touch YubiKey instead of typing anything at `login:`"**, `pam_u2f` with `unixAuth = false` is the straightforward NixOS-native solution.

[1]: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/security/pam.nix?utm_source=chatgpt.com "nixpkgs/nixos/modules/security/pam.nix at master · NixOS/nixpkgs · GitHub"
[2]: https://mynixos.com/nixpkgs/option/security.pam.u2f.control?utm_source=chatgpt.com "security.pam.u2f.control - MyNixOS"
[3]: https://wiki.nixos.org/wiki/Yubikey?utm_source=chatgpt.com "Yubikey - Official NixOS Wiki"
[4]: https://mynixos.com/options/security.pam.p11?utm_source=chatgpt.com "security.pam.p11 - MyNixOS"
[5]: https://wiki.nixos.org/wiki/Fingerprint_scanner?utm_source=chatgpt.com "Fingerprint scanner - Official NixOS Wiki"
[6]: https://wiki.nixos.org/wiki/FIDO2_based_Full_Disk_Encryption_%28FDE%29_on_NixOS?utm_source=chatgpt.com "FIDO2 based Full Disk Encryption (FDE) on NixOS - Official NixOS Wiki"

--

Can phone work as pam factor?

--

Yes. There are several ways, but they differ a lot in security and maturity.

For **NixOS + local TTY**, I'd rank them roughly like this:

| Phone mechanism                         | PAM experience       |     Offline | Security              | Maturity                    |
| --------------------------------------- | -------------------- | ----------: | --------------------- | --------------------------- |
| **TOTP on phone**                       | type 6-digit code    |           ✅ | good                  | excellent                   |
| **Duo Push**                            | approve notification |           ❌ | good                  | excellent                   |
| **Phone BLE challenge-response**        | approve/biometric    |           ✅ | potentially very good | experimental                |
| **Phone as FIDO/passkey authenticator** | biometric/passkey    | potentially | excellent             | **not drop-in for PAM yet** |
| Bluetooth proximity = phone nearby      | automatic            |           ✅ | poor                  | avoid                       |

### Easiest open-source option: TOTP

NixOS directly supports PAM Google Authenticator/OATH. Despite the name, you don't need Google's app; use something like Aegis on Android.

For `login`:

```nix
security.pam.services.login.googleAuthenticator.enable = true;
```

This makes the phone a factor, but you still manually type:

```text
login: evgenii
Verification code: 123456
```

You can combine it with a password, FIDO key, etc. NixOS has first-class PAM support for this. ([GitHub][1])

The advantage is boring reliability: no Bluetooth, daemon, network, or phone/Linux communication required.

---

### More interesting: approve login on the phone

There are projects doing exactly what you're probably imagining:

```text
tty login
   ↓
PAM generates random challenge
   ↓ BLE
Android phone
   ↓
fingerprint / face / PIN
   ↓
phone signs challenge
   ↓ BLE
PAM verifies signature
   ↓
login
```

One current project is **syauth**. It has a PAM module plus Android application, uses BLE, generates a per-authentication challenge, and keeps the Ed25519 key inside Android Keystore with user authentication required. It explicitly targets `login`, `sudo`, GDM and screen lockers. ([GitHub][2])

That's substantially better conceptually than:

```text
if bluetooth MAC aa:bb:cc is nearby:
    auth_success();
```

because simple Bluetooth proximity authentication is relayable.

The downside: **syauth is a small/new third-party project**, rather than an established NixOS authentication primitive. I would be comfortable experimenting with it while retaining FIDO/password recovery, but I wouldn't initially make it the sole way into an important machine.

You'd likely package its PAM `.so`, daemon and Android app yourself in NixOS; there doesn't appear to be a standard NixOS module for it today.

---

### Phone as an actual FIDO2/passkey

This is the technically nicest answer, but there's a catch.

Modern Android/iPhones can already authenticate another computer using a phone-held passkey:

```text
PC displays QR
      ↓
scan with phone
      ↓
FaceID / fingerprint / PIN
      ↓
FIDO credential signs challenge
```

FIDO calls this **hybrid/cross-device authentication**. Bluetooth establishes proximity while the actual protocol uses cryptographic authentication; it isn't trusting Bluetooth pairing itself. ([Google for Developers][3])

CTAP explicitly has USB, NFC, BLE and hybrid transports. ([FIDO Alliance][4])

But **`pam_u2f` does not currently turn ordinary Android/iPhone passkeys into a Chrome-style "scan this QR with your phone" TTY login experience**. `pam_u2f` is built around FIDO authenticators visible through its `libfido2` stack. ([developers.yubico.com][5])

So this:

```text
security.pam.services.login.u2f.enable = true;
```

works beautifully with a YubiKey/SoloKey/etc., but doesn't magically produce:

```text
┌──────────────────┐
│ █▀▀ ███ ██▀ ... │
│ QR login         │
└──────────────────┘
Scan with Pixel
```

on `tty1`.

That's a gap I'd very much like Linux/PAM to close.

### There's also Duo

NixOS has native PAM support for Duo Security:

```nix
security.pam.duoSecurity.enable = true;
security.duosec.enable = true;
```

and the phone gets a push approval request. The current NixOS PAM module includes `pam_duo` directly. ([GitHub][1])

It's mature and convenient, but given your preference for open systems, the architecture isn't particularly attractive:

```text
your computer → Duo servers → your phone
```

Authentication now depends on Internet access and an external service.

---

For your use case, I'd choose one of two architectures:

```text
                   recovery
                      │
                      ▼
TTY → phone BLE signing → FIDO2 hardware key → password
```

using something like syauth experimentally, **or**, for the boring/reliable setup:

```text
TTY → FIDO2 hardware key
sudo → FIDO2 hardware key
phone → TOTP recovery/second factor
```

The really compelling future setup is **phone-held FIDO2 credential over hybrid CTAP → PAM**, because then Android/iOS handles biometric verification and secure-key storage without inventing a Linux-specific authentication protocol. The standards exist; the PAM/TTY plumbing is the weak part today.

[1]: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/security/pam.nix?utm_source=chatgpt.com "nixpkgs/nixos/modules/security/pam.nix at master · NixOS/nixpkgs · GitHub"
[2]: https://github.com/dmytrogajewski/syauth?utm_source=chatgpt.com "GitHub - dmytrogajewski/syauth: Phone-as-key Linux unlock: PAM module + Android app. LESC pair, Keystore-resident Ed25519, FIDO2 fallback. · GitHub"
[3]: https://developers.google.com/identity/passkeys/use-cases?authuser=2&utm_source=chatgpt.com "Passkeys use cases  |  Google for Developers"
[4]: https://fidoalliance.org/specs/fido-v2.3-ps-20260226/fido-client-to-authenticator-protocol-v2.3-ps-20260226.html?utm_source=chatgpt.com "Client to Authenticator Protocol (CTAP)"
[5]: https://developers.yubico.com/pam-u2f/index.html?utm_source=chatgpt.com "pam-u2f"
