When you use nix tool, how it decides which store to use and which user to use? Do nix build has any suid capabilities?

--

`nix` itself normally has **no SUID-root capability**. In a multi-user installation, privilege separation is done through `nix-daemon`, not through a setuid `nix` executable.

The important distinction is between **the user running the CLI**, **the process owning/managing the store**, and **the UID used for the actual builder**.

### How Nix decides which store to use

Conceptually, `nix build` opens a Nix “store object.” The selection is roughly:

1. An explicit store, e.g.

   ```bash
   nix build --store /some/root ...
   nix build --store daemon ...
   nix build --store ssh://host ...
   ```
2. Configuration/environment, most notably `NIX_REMOTE`.
3. Otherwise the default `"auto"` behavior chooses the normal local setup.

For a normal multi-user installation:

```text
your shell
   |
   | nix build
   v
nix client, uid=you
   |
   | Unix socket
   v
/nix/var/nix/daemon-socket/socket
   |
   v
nix-daemon, uid=root
```

The pseudo-store `daemon` corresponds to the Unix socket `/nix/var/nix/daemon-socket/socket`. ([nix.dev][1])

Historically/configurationally you'll often see:

```bash
NIX_REMOTE=daemon
```

That tells the client to send store operations to `nix-daemon`. ([nix.dev][2])

In a single-user/no-daemon installation, the `nix` process accesses the local store directly, normally `/nix/store`, with the UID of the calling process.

You can inspect what you're actually talking to with things such as:

```bash
nix store info
echo "$NIX_REMOTE"
nix config show | grep -E 'store|build-users'
```

### Which user actually executes a build?

On a typical multi-user Linux installation, there are three identities involved:

```text
CLI:
    uid=evgenii

daemon:
    uid=root

builder:
    uid=nixbld<N>
```

When you do:

```bash
nix build nixpkgs#hello
```

your `nix` process doesn't become root. It talks to the already-running privileged daemon.

The daemon chooses one of the accounts in the configured:

```ini
build-users-group = nixbld
```

and forks/executes the derivation builder under that UID. The Nix manual explicitly says builds in multi-user mode are executed under dedicated build users such as `nixbld1`, `nixbld2`, etc. ([nix.dev][2])

So something approximating the privileged part internally is:

```c
// daemon is already root

fork();

setgroups(...);
setgid(nixbld_gid);
setuid(nixbld17_uid);

execve(builder, ...);
```

There are additional sandbox namespace/setup operations on Linux, but that's the basic privilege transition.

### Is `nix` SUID?

Normally:

```bash
$ ls -l "$(command -v nix)"
-r-xr-xr-x ... nix
```

not:

```text
-rwsr-xr-x
   ^
   SUID
```

There is no reason for the user-facing `nix` binary to be SUID root in the standard multi-user architecture.

Instead:

```text
unprivileged nix CLI
        |
        | IPC
        v
privileged nix-daemon
        |
        | drop privileges
        v
nixbldN
```

`nix-daemon` is started as root by the service manager. The current Nix manual describes it specifically as performing store operations on behalf of non-root clients. ([nix.dev][3])

### An interesting corner case

`build-users-group` controls this behavior.

The manual says that if the build users group is empty, builders execute with the UID of the Nix process:

```text
direct local store:
    builder UID = calling nix UID

daemon store:
    builder UID = daemon UID
```

So this configuration would be particularly dangerous:

```ini
build-users-group =
```

with a root `nix-daemon` exposed to untrusted clients, because builders could consequently execute as the daemon UID — usually root. The manual explicitly warns against that configuration. ([nix.dev][4])

The normal root-daemon configuration defaults to a `nixbld` build-user group. ([nix.dev][4])

### Why bother with separate `nixbld` users?

An important subtlety is that builders are **untrusted arbitrary programs**. A derivation can essentially say:

```nix
builder = "/path/to/arbitrary-program";
```

So running builders as the daemon's root UID would be an immediate privilege escalation.

Also, Nix doesn't just use one permanent `nixbld` user for every concurrent job. Different simultaneous builds get separate build UIDs. That prevents a malicious builder owned by one user/build from modifying or spying on another concurrent builder's files. The manual explicitly guarantees it won't run two builds concurrently under the same build user. ([nix.dev][4])

So the security boundary is roughly:

```text
                  trusted
                    |
             +------+------+
             | nix-daemon  | root
             +------+------+
                    |
       validates / manages store
                    |
           drops privileges
                    |
        +-----------+-----------+
        |                       |
     nixbld1                 nixbld2
   untrusted build         untrusted build
```

One useful consequence: **the Unix socket is effectively the privileged API boundary**. If you're auditing Nix for privilege escalation, the interesting attack surface isn't a SUID `nix` binary; it's `nix-daemon`'s protocol/authentication, trusted-vs-untrusted client handling, builder privilege dropping, sandbox setup, and store permission/integrity logic.

[1]: https://nix.dev/manual/nix/2.32/command-ref/new-cli/nix3-help-stores?utm_source=chatgpt.com "nix help-stores - Nix 2.32.9 Reference Manual"
[2]: https://nix.dev/manual/nix/2.34/installation/multi-user?utm_source=chatgpt.com "Multi-User Mode - Nix 2.34.9 Reference Manual"
[3]: https://nix.dev/manual/nix/2.34/command-ref/nix-daemon.html?utm_source=chatgpt.com "nix-daemon - Nix 2.34.9 Reference Manual"
[4]: https://nix.dev/manual/nix/2.21/command-ref/conf-file.html?utm_source=chatgpt.com "nix.conf - Nix Reference Manual"

--

Why it not uses user namespaces

--

It actually **does use Linux namespaces**, and newer Nix can use **user namespaces too**. The important distinction is that historically Nix did **not use user namespaces as the primary replacement for `nixbld` users**.

On Linux with sandboxing enabled, Nix normally creates private **mount, PID, network, IPC, and UTS namespaces** for builds. The manual explicitly documents those. ([nix.dev][1])

The traditional model is still:

```text
root nix-daemon
    |
    +-- select nixbld17
    |
    +-- setuid(nixbld17)
    |
    +-- create namespaces/chroot-like sandbox
    |
    `-- exec builder
```

rather than:

```text
ordinary user
    |
    +-- unshare(CLONE_NEWUSER)
    +-- map itself -> uid 0 inside namespace
    `-- build
```

There are a few reasons for that.

First, **Nix predates widespread usable unprivileged user namespaces**. The multi-user/build-user architecture is old and portable. `nixbld` accounts also work on systems without Linux user namespaces, notably macOS, whereas user namespaces are Linux-specific.

Second, real build UIDs give Nix a useful security property that is independent of sandbox correctness. Concurrent builds get distinct host UIDs:

```text
build A -> host uid 30001
build B -> host uid 30002
```

So even if some namespace isolation is absent or deliberately relaxed, those processes don't normally have permission to tamper with each other's files. Nix explicitly guarantees that it doesn't run two concurrent builds under the same build user. ([nix.dev][1])

That matters because Nix historically permits cases where full sandboxing isn't applied, such as relaxed sandbox configurations. A real UID remains a kernel DAC boundary even when some namespace boundary isn't there.

There is also a security tradeoff: **unprivileged user namespaces massively increase kernel attack surface available to an unprivileged process**. A process that is UID 0 inside a user namespace can exercise namespace-aware privileged kernel paths that it otherwise couldn't. This is exactly why hardened systems sometimes disable unprivileged user namespaces; NixOS itself documents that concern in its `security.allowUserNamespaces` option. ([GitHub][2])

So from Nix's historical security model:

```text
malicious derivation
      |
      v
real unprivileged nixbld UID
      +
mount/pid/net/etc namespaces
```

is intentionally defense-in-depth.

### But modern Nix *can* use user namespaces

This is the interesting part.

Nix now has the experimental:

```ini
auto-allocate-uids = true
```

feature. Instead of requiring a static `/etc/passwd` pool like:

```text
nixbld1
nixbld2
...
nixbld32
```

Nix dynamically allocates UIDs starting at a high range. ([nix.dev][1])

And Nix has a `uid-range` system feature. On Linux, a derivation requesting it can be run in a **user namespace where the derivation sees itself as UID 0 and gets a range of 65,536 UIDs**. The documented motivation is precisely workloads that need subordinate identities, such as running `systemd-nspawn` inside a Nix build. ([nix.dev][1])

Conceptually:

```text
host                       build user namespace

872415232   ------------>   UID 0
872415233   ------------>   UID 1
...
872480767   ------------>   UID 65535
```

So inside the derivation:

```bash
$ id
uid=0(root)
```

but that's namespace-root, not host-root.

The derivation can then do things like:

```text
container root
container daemon user
container nobody
...
```

without requiring 65k real `/etc/passwd` users.

### Why not simply make every Nix build work that way?

Because then Nix would depend on user namespaces being enabled and trustworthy.

That's not universally true. For example, contemporary Nix still has bug reports around systems configured with:

```text
kernel.unprivileged_userns_clone=0
```

where namespace setup behaves differently. ([GitHub][3])

And some administrators intentionally disable user namespaces precisely because they've historically exposed a substantial number of kernel privilege-escalation bugs.

There's also no major benefit to pretending that an ordinary package builder is root. Most builds only need:

```text
write $TMPDIR
write $out
read dependencies
exec compiler
```

A real unprivileged UID is simpler.

So for a normal package build:

```text
UID nixbld42
+
mount namespace
+
PID namespace
+
network namespace
+
IPC namespace
+
UTS namespace
```

already gives Nix what it wants.

User namespaces become especially useful when the **builder itself needs multiple UIDs**, which is why `uid-range` exists.

One other subtle point: using a user namespace would **not eliminate the need for a privileged component managing `/nix/store`**. The daemon still needs to validate outputs, atomically install paths, set ownership/permissions, update the store DB, garbage collect, etc. Namespace-root cannot simply modify arbitrary host-owned `/nix/store` objects.

So Nix's architecture is closer to:

```text
                    host root
                 nix-daemon
                     |
          +----------+----------+
          |                     |
     build UID A            build UID B
          |                     |
     namespaces              namespaces
          |
     [optional userns]
     UID 0..65535 inside
```

rather than treating user namespaces as a substitute for the daemon.

And interestingly, there has been active discussion upstream about exactly the architecture you're thinking of: running the Nix daemon non-root and using subordinate UID/user-namespace mappings instead of static `nixbld` users. The Nix issue discussing a non-root daemon explicitly proposes subuid mappings as one way to replace that part of the current root daemon model. ([GitHub][4])

So your intuition is basically right: **Linux user namespaces could support a significantly more rootless Nix architecture. Nix's current design is mostly a mixture of historical compatibility, portability, defense-in-depth, and avoiding mandatory dependence on userns.**

[1]: https://nix.dev/manual/nix/2.34/command-ref/conf-file.html?utm_source=chatgpt.com "nix.conf - Nix 2.34.9 Reference Manual"
[2]: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/security/misc.nix?utm_source=chatgpt.com "nixpkgs/nixos/modules/security/misc.nix at master · NixOS/nixpkgs · GitHub"
[3]: https://github.com/nixos/nix/issues/14914?utm_source=chatgpt.com "Nix silently refuses to setup a userns for the sandbox if kernel.unprivileged_userns_clone=0 · Issue #14914 · NixOS/nix · GitHub"
[4]: https://github.com/NixOS/nix/issues/5208?utm_source=chatgpt.com "Make it possible to run the Nix daemon as a non-root user · Issue #5208 · NixOS/nix · GitHub"

--

Looks like disable daemon and invest heavy into a namespaces is what is sane secure modern default should be

--

For a **single-user Linux workstation**, I mostly agree. The clean modern model would be: no root daemon, no static `nixbld*` accounts, and builds run inside aggressively restricted user namespaces.

Something like:

```text
user
 |
 +-- nix evaluator
 |
 +-- build supervisor
      |
      +-- CLONE_NEWUSER
      +-- CLONE_NEWNS
      +-- CLONE_NEWPID
      +-- CLONE_NEWNET
      +-- CLONE_NEWIPC
      +-- CLONE_NEWUTS
      |
      +-- uid/gid mapping
      +-- read-only dependency mounts
      +-- private writable build dir
      +-- no_new_privs
      +-- seccomp / Landlock where useful
      `-- builder
```

The host `/nix/store` could simply be owned by a dedicated unprivileged account or, for a genuinely single-user setup, by the user. Nothing in compiling GCC fundamentally needs host root.

And interestingly, Nix has now moved materially in this direction. **Nix 2.34, released February 27, 2026, added `nix-nswrapper`, specifically to run `nix-daemon` inside an unprivileged user namespace with subuid/subgid allocations.** It allows full sandboxing without the daemon executing as host root. Nixpkgs also gained `nix.daemonUser` / `nix.daemonGroup`. ([nix.dev][1])

So upstream has effectively acknowledged the same architectural issue.

The part I'd push back on is **“disable daemon” for multi-user machines**. The daemon and *root daemon* are separate questions.

For a shared system you still need some authority answering:

> Is this user allowed to add this path to the common store?

Otherwise Alice and Bob writing directly into the same namespace becomes nasty:

```text
Alice -> /nix/store/abc-openssl
Bob   -> /nix/store/abc-openssl
```

Nix needs an arbiter for things such as:

* store/database consistency;
* atomic registration of paths;
* verifying hashes/signatures;
* garbage collection and GC roots;
* ensuring users cannot replace another user's supposedly immutable path;
* deciding which substituters/keys are trusted;
* coordinating concurrent builds.

That's the actual reason for a daemon-like process. The current manual describes the shared-store security requirement explicitly: allowing arbitrary users to modify the store/database would let one user Trojan packages consumed by another. ([nix.dev][2])

What isn't necessary is:

```text
nix-daemon == UID 0
```

A substantially nicer architecture is:

```text
                dedicated nix-store UID
                        |
               unprivileged daemon
                        |
         +--------------+--------------+
         |                             |
     request A                       request B
         |                             |
     userns A                        userns B
     uid range A                     uid range B
         |                             |
      builder                       builder
```

Then the daemon has **capability over the store, rather than capability over the entire host**.

That's a much tighter privilege model.

There was already an upstream issue specifically arguing that the root daemon represents an unnecessarily large privileged codebase and that most daemon operations only require ownership of `/nix`, not UID 0. ([GitHub][3]) The 2.34 `nix-nswrapper` work is essentially progress toward that goal.

Where I'd go even further architecturally is to split privileges:

```text
nix frontend
    |
    +---- evaluator                ordinary user
    |
    +---- build supervisor        ordinary user + userns
    |
    `---- store service           dedicated nix-store UID
              |
              +-- CAS verification
              +-- DB transactions
              +-- atomic store insertion
              `-- GC
```

The store service should ideally **never execute derivation-controlled code**. Builders shouldn't share its UID, namespace, writable filesystem, or ideally even much of its syscall surface.

That is a much easier component to reason about than today's historically evolved daemon that both controls the store and orchestrates builds.

There is one nontrivial downside to betting heavily on user namespaces: **they transfer some security burden from userspace privilege separation into a very large kernel API surface**. NixOS's own security configuration explicitly notes that user namespaces have historically been problematic because kernel permission checks can accidentally fail to account for namespacing. ([GitHub][4])

But I don't think the sane conclusion in 2026 is “therefore run a huge daemon as real root.” It's more like:

```text
userns
+ real unprivileged host UID
+ no_new_privs
+ tight mounts
+ minimal capabilities
+ syscall restrictions where practical
+ no privileged daemon executing attacker-controlled programs
```

Defense in depth.

So I'd rank the designs roughly:

```text
Bad:
    root daemon directly executes arbitrary builders as root

Traditional Nix:
    root daemon -> real nixbld UID + namespaces

Better:
    unprivileged store daemon -> isolated builder UID + namespaces

Better still on Linux:
    unprivileged store daemon
        -> unique subordinate UID range
        -> userns + mount/pid/net/... namespaces
        -> builder

Single-user:
    no daemon at all
        -> user-owned store
        -> userns sandbox per build
```

The **single-user/no-daemon version is especially compelling** because once there's no cross-user store trust boundary, a huge amount of Nix's privilege machinery simply stops being necessary.

And the 2.34 changes make this more than theoretical now: the project is actively making host-root unnecessary for sandboxing. ([nix.dev][1])

[1]: https://nix.dev/manual/nix/2.34/release-notes/rl-2.34?utm_source=chatgpt.com "Release 2.34 (2026-02-27) - Nix 2.34.9 Reference Manual"
[2]: https://nix.dev/manual/nix/2.34/installation/multi-user?utm_source=chatgpt.com "Multi-User Mode - Nix 2.34.9 Reference Manual"
[3]: https://github.com/NixOS/nix/issues/5208?utm_source=chatgpt.com "Make it possible to run the Nix daemon as a non-root user · Issue #5208 · NixOS/nix · GitHub"
[4]: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/security/misc.nix?utm_source=chatgpt.com "nixpkgs/nixos/modules/security/misc.nix at master · NixOS/nixpkgs · GitHub"

--

I run netboot based uki efi

--

That changes the tradeoff quite a bit.

With a **netbooted UKI** and an ephemeral/immutable userspace, I’d care less about “root daemon can persist arbitrary junk forever” and more about **runtime privilege separation**. If every boot starts from a measured/signed image, persistence through `/etc`, systemd units, `/usr`, etc. is already much harder.

For that setup, I’d lean toward:

```text
firmware / Secure Boot
        |
        v
signed UKI
(kernel + initrd + cmdline)
        |
        v
ephemeral root
        |
        +-- mostly immutable system closure
        |
        +-- writable state only where explicitly needed
        |
        `-- builds in userns
             + mount ns
             + pid ns
             + net ns
             + seccomp/no_new_privs
             + tmpfs workspace
```

The interesting question is then **what `/nix/store` means on your machines**.

If the machines mostly consume prebuilt closures from a trusted cache, I would avoid local privileged builds entirely. A very clean model is:

```text
CI/build host
    |
    | signed narinfo / trusted cache
    v
netboot host
    |
    `-- read-only-ish Nix store
```

Then the booted machine doesn't need a powerful build daemon at all. It just needs enough privilege to materialize verified store paths, or you can arrange for the store itself to be part of the immutable image / mounted content.

For occasional local builds, I'd prefer a **separate writable build/store area owned by the user**, rather than granting the standard root daemon authority over the persistent system store:

```text
system store
/nix/store
    immutable/trusted

user build store
/var/tmp/nix-$UID   or persistent per-user volume
    owned by user
    builder runs under userns
```

Then promotion into the trusted system store is an explicit operation.

The distinction matters because user namespaces don't solve this problem:

```text
untrusted build
     |
     v
"please make this output trusted system state"
```

Some component must cross that trust boundary. But on a netboot machine, you can often simply **remove that operation from the machine entirely**. Build elsewhere, sign, reboot into a new closure.

That gives you a much nicer security model:

```text
runtime root compromise
       |
       +-- can own current boot
       |
       X-- cannot modify signed next boot
       X-- cannot forge trusted Nix artifacts
       X-- cannot persist unless it reaches explicit persistent state
```

That is substantially stronger than trying to make a mutable NixOS installation perfectly secure.

One thing I would be fairly aggressive about in your architecture is the kernel command line. With UKIs, keeping the command line embedded/signed instead of accepting arbitrary EFI-loader-provided arguments closes off a surprisingly useful mutation surface. Likewise, I’d explicitly enumerate persistent mounts rather than having a broadly writable `/var`.

So in your case, I think the natural end-state is even more radical than “rootless `nix-daemon`”:

**production/netboot nodes shouldn't build at all.** They should verify and consume artifacts; compilation belongs on disposable builders.

--

So no daemon and writable global nix store

Only non root running with local nix store for local stuff

--

Yes — for your setup that separation is very reasonable:

```text
system /nix/store
    read-only at runtime
    populated by the boot/deployment pipeline
    trusted system closure

user-local Nix store
    writable by your normal UID
    no nix-daemon
    used for nix build / nix shell / nix run / experiments
```

Modern Nix already gets surprisingly close to this automatically. If `/nix/var/nix` isn't writable and there is no daemon socket, on Linux the `auto` store selection falls back to a local chroot store under:

```text
~/.local/share/nix/root
```

Physically its store is:

```text
~/.local/share/nix/root/nix/store
```

but **logically it is still `/nix/store`**. Nix enters a user+mount namespace/chroot-like environment so binaries continue seeing their dependencies at `/nix/store`. ([nix.dev][1])

That's substantially better than changing the logical store path to something like:

```text
/home/tigor/.nix/store
```

because changing the logical store prefix breaks compatibility with normal `/nix/store/...` binaries and therefore with ordinary binary caches. Nix explicitly discourages doing that. ([nix.dev][1])

So your runtime could effectively be:

```text
/
├── nix/store/                    <- immutable system store
└── home/tigor/.local/share/nix/root/
    ├── nix/store/                <- writable personal store
    └── nix/var/nix/db/           <- personal store DB
```

When you run:

```bash
nix build nixpkgs#foo
```

with no daemon and no writable global store, Nix's current `auto` logic can select that per-user chroot store. ([nix.dev][1])

And the process hierarchy becomes essentially:

```text
UID 1000
  nix
   |
   +-- user namespace
   +-- mount namespace
   +-- build sandbox
   |
   `-- builder
```

No host-root `nix-daemon`, no `nixbld*` account required for the personal store.

The one thing I'd change in your wording is **don't make the global `/nix/store` writable by the user**. That throws away the strongest boundary you have.

I'd want:

```text
global /nix/store:
    user cannot write
    preferably filesystem-level RO
    deployment/boot machinery owns it

personal store:
    user can write
    disposable
```

If the user can modify the system `/nix/store`, an attacker compromising your user account can potentially replace system artifacts that happen to live there. The whole reason multi-user Nix protects the global store is exactly this cross-trust problem. ([nix.dev][2])

There's one especially interesting new option if you want both worlds: Nix 2.34 has an experimental **local overlay store**. It lets you combine a lower store and a writable upper store while presenting a merged `/nix/store`. ([nix.dev][3])

Conceptually:

```text
immutable system store
        |
        | lower
        v
   OverlayFS /nix/store
        ^
        | upper
        |
personal writable store
```

That architecture fits a netboot machine extremely well:

```text
signed/netboot image
      |
      +-- immutable lower /nix/store
      |
normal user
      |
      +-- private upper store
      |
      +-- userns + mountns
      `-- nix build
```

Your locally built package can then reference both system dependencies and newly built paths without giving your UID write access to the trusted lower store.

I'd probably aim for **RO global store + per-user chroot/overlay store + zero system `nix-daemon`** on this kind of machine. The daemon is useful for safely multiplexing a *shared writable store*. Once you've explicitly decided you don't want a shared writable store, much of its raison d'être disappears.

[1]: https://nix.dev/manual/nix/2.34/command-ref/new-cli/nix3-help-stores?utm_source=chatgpt.com "nix help-stores - Nix 2.34.9 Reference Manual"
[2]: https://nix.dev/manual/nix/2.34/installation/multi-user?utm_source=chatgpt.com "Multi-User Mode - Nix 2.34.9 Reference Manual"
[3]: https://nix.dev/manual/nix/2.34/store/types/experimental-local-overlay-store?utm_source=chatgpt.com "Experimental Local Overlay Store - Nix 2.34.9 Reference Manual"
