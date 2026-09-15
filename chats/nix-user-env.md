In a Nix flake, `outputs` can technically contain arbitrary attributes, but Nix recognizes a conventional schema for certain output names. The main ones are: ([NixOS Wiki][1])

| Output                | Shape                            | Used by / purpose                                   |
| --------------------- | -------------------------------- | --------------------------------------------------- |
| `packages`            | `packages.<system>.<name>`       | Buildable derivations; `nix build .#foo`            |
| `apps`                | `apps.<system>.<name>`           | Executables; `nix run .#foo`                        |
| `devShells`           | `devShells.<system>.<name>`      | Development environments; `nix develop .#foo`       |
| `checks`              | `checks.<system>.<name>`         | Tests/checks run by `nix flake check`               |
| `formatter`           | `formatter.<system>`             | Formatter used by `nix fmt`                         |
| `legacyPackages`      | `legacyPackages.<system>...`     | Arbitrary package attrsets, commonly nixpkgs itself |
| `nixosConfigurations` | `nixosConfigurations.<hostname>` | Complete NixOS systems for `nixos-rebuild --flake`  |
| `nixosModules`        | `nixosModules.<name>`            | Reusable NixOS modules                              |
| `overlays`            | `overlays.<name>`                | nixpkgs overlays                                    |
| `templates`           | `templates.<name>`               | Templates for `nix flake init -t`                   |
| `hydraJobs`           | `hydraJobs...`                   | Hydra CI jobs                                       |

A fairly representative flake looks like:

```nix
{
  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.default = ...;
    packages.x86_64-linux.foo = ...;

    apps.x86_64-linux.default = {
      type = "app";
      program = "...";
    };

    devShells.x86_64-linux.default = ...;

    checks.x86_64-linux.tests = ...;

    formatter.x86_64-linux = ...;

    nixosConfigurations.myhost = ...;

    nixosModules.default = ...;
    nixosModules.myModule = ...;

    overlays.default = final: prev: {
      # ...
    };

    templates.default = {
      path = ./template;
      description = "My template";
    };
  };
}
```

The important distinction is that some outputs are **per-system** and some aren't.

```text
per-system:
  packages.<system>
  apps.<system>
  devShells.<system>
  checks.<system>
  formatter.<system>
  legacyPackages.<system>

not normally per-system:
  nixosConfigurations.<hostname>
  nixosModules.<name>
  overlays.<name>
  templates.<name>
```

For example:

```nix
packages.x86_64-linux.foo
packages.aarch64-linux.foo
```

but:

```nix
nixosConfigurations.server
```

not usually:

```nix
nixosConfigurations.x86_64-linux.server
```

### `default` has special meaning

Several output types support a conventional `default` member:

```nix
packages.x86_64-linux.default
apps.x86_64-linux.default
devShells.x86_64-linux.default
overlays.default
nixosModules.default
templates.default
```

So these work without naming an attribute:

```bash
nix build
nix run
nix develop
```

instead of:

```bash
nix build .#foo
nix run .#foo
nix develop .#foo
```

### Arbitrary outputs are allowed

This is a subtle but useful point: the schema isn't a restriction on what your `outputs` function may return.

You can do:

```nix
outputs = { self, nixpkgs }: {
  myStuff = {
    foo = 123;
    bar = "hello";
  };
};
```

Other flakes can access it as:

```nix
inputs.myFlake.myStuff.foo
```

Nix's commands simply don't attach special semantics to `myStuff`. The standard names above are essentially a **protocol between flakes and Nix CLI commands**. ([NixOS Wiki][1])

To see what a particular flake exports:

```bash
nix flake show
```

and for the raw attribute tree, which is often more useful:

```bash
nix flake show --all-systems
```

or:

```bash
nix eval .#packages --json
```

One extra gotcha: older examples may mention singular `defaultPackage`, `defaultApp`, or `devShell`. Modern flakes normally use `packages.<system>.default`, `apps.<system>.default`, and `devShells.<system>.default` instead.

[1]: https://wiki.nixos.org/wiki/Flakes?utm_source=chatgpt.com "Flakes - Official NixOS Wiki"

--

Да. Для `nix profile` основной и нормальный output — **`packages`**.

Например:

```nix
{
  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system} = {
      myenv = pkgs.buildEnv {
        name = "myenv";
        paths = [
          pkgs.git
          pkgs.ripgrep
          pkgs.less
          pkgs.jq
        ];
      };

      default = self.packages.${system}.myenv;
    };
  };
}
```

Тогда:

```bash
nix profile install .#myenv
```

резолвится примерно в:

```text
packages.x86_64-linux.myenv
```

А если есть:

```nix
packages.x86_64-linux.default = ...;
```

то можно:

```bash
nix profile install .
```

Nix действительно сохраняет в profile конкретный flake attribute вроде `packages.x86_64-linux.default` или `packages.x86_64-linux.foo`. ([NixOS Releases][1])

Для твоего сценария я бы сделал именно:

```text
packages.${system}.home
```

и:

```bash
nix profile install .#home
```

### А `devShells`?

Нет, напрямую это другая сущность:

```bash
nix develop .#home
```

использует:

```text
devShells.${system}.home
```

`nix profile install` ожидает installable package/derivation, а не dev shell.

Поэтому если хочется и permanent profile, и dev shell, можно сделать оба от одного набора пакетов:

```nix
let
  homePackages = with pkgs; [
    git
    ripgrep
    less
    jq
  ];
in {
  packages.${system}.home = pkgs.buildEnv {
    name = "home";
    paths = homePackages;
  };

  devShells.${system}.home = pkgs.mkShell {
    packages = homePackages;
  };
}
```

И получаешь две разные модели:

```bash
# Постоянное rootless userspace environment
nix profile install .#home

# Временное environment
nix develop .#home
```

Для твоей идеи **“rootless почти OS-wide environment без Home Manager”** я бы считал `packages.${system}.home` главным output, а `devShells` вообще не использовал, если тебе не нужна дополнительная изоляция окружения.

[1]: https://releases.nixos.org/nix/nix-2.18.2/manual/command-ref/new-cli/nix3-profile-list.html?utm_source=chatgpt.com "nix profile list - Nix Reference Manual"

--

Если один и тот же `package` уже добавлен в profile, повторный `nix profile add` обычно не является способом его обновить. Для обновления есть отдельный `nix profile upgrade`. В актуальном Nix `nix profile install` — просто deprecated alias для `nix profile add`. ([Nix][1])

Например:

```bash
nix profile add .#home
```

После изменения `flake.nix`/`flake.lock` правильнее:

```bash
nix profile upgrade home
```

Посмотреть имя элемента:

```bash
nix profile list
```

`nix profile` хранит не просто symlink на один package, а manifest с отдельными элементами и provenance: откуда flake был взят, какой attr path использован и какой locked revision получился. ([Nix][2])

Есть важная тонкость для локального flake `.#home`. Если тебе нужна модель именно **“rebuild/switch моего rootless userspace”**, imperative `profile upgrade` не столь элегантен, как кажется. `upgrade` предназначен для ранее установленного flake и заново получает его latest revision; официально он работает для unlocked flake references. ([Nix][3])

Profile при каждом изменении создаёт новую generation, то есть старая версия не уничтожается сразу:

```text
generation 1
    home -> /nix/store/...-home-v1

          nix profile upgrade

generation 2
    home -> /nix/store/...-home-v2
                 ^
                 current
```

Поэтому можно:

```bash
nix profile history
```

и откатиться:

```bash
nix profile rollback
```

Profiles как раз предназначены для atomic upgrades и rollback. ([Nix][4])

Для твоего use case я бы делал один aggregate package:

```nix
packages.${system}.home = pkgs.buildEnv {
  name = "home";

  paths = [
    git
    vim
    less
    ripgrep
    jq
  ];
};
```

и **один profile element**, а не:

```bash
nix profile add .#git
nix profile add .#vim
nix profile add .#less
nix profile add .#rg
...
```

То есть:

```bash
nix profile add .#home
```

А затем меняешь содержимое `packages.${system}.home` и обновляешь этот один элемент.

Это значительно ближе к твоей модели:

```text
flake.nix
   ↓
packages.x86_64-linux.home
   ↓
one profile element
   ↓
rootless user environment
```

чем profile из десятков independently managed packages.

И ещё плюс: profile generations означают, что **“затирания” в обычном смысле нет**. Новый environment становится current atomically, а предыдущий остаётся доступен для rollback, пока ты не почистишь history. ([Nix][5])

Если хочешь именно семантику уровня `nixos-rebuild switch`, но rootless и без Home Manager, то поверх этого можно сделать буквально маленький `switch`-скрипт: build нового `packages.home` → заменить единственный profile element → сохранить generations. Это, на мой взгляд, самый чистый вариант на чистом Nix.

[1]: https://nix.dev/manual/nix/2.35/command-ref/new-cli/nix3-profile-add.html "nix profile add - Nix 2.35.2 Reference Manual"
[2]: https://nix.dev/manual/nix/2.35/command-ref/files/manifest.json.html?utm_source=chatgpt.com "manifest.json - Nix 2.35.2 Reference Manual"
[3]: https://nix.dev/manual/nix/2.35/command-ref/new-cli/nix3-profile-upgrade.html?utm_source=chatgpt.com "nix profile upgrade - Nix 2.35.2 Reference Manual"
[4]: https://nix.dev/manual/nix/2.35/command-ref/new-cli/nix3-profile.html?utm_source=chatgpt.com "nix profile - Nix 2.35.2 Reference Manual"
[5]: https://nix.dev/manual/nix/2.35/package-management/profiles.html?utm_source=chatgpt.com "Profiles - Nix 2.35.2 Reference Manual"

--

I want a nixos config for system

To be universal efi uki for vm

And then whatever is defined in cache-like home dir of user runs

Also posibly to have another nix flake for that user profile, built separately

Ideally that defines user's stuff

--

Yes. The last version was too aggressively simplified. The important breakages were: the user generation wasn't protected from GC, systemd was being pointed at logical `/nix/store/...` paths instead of the **physical private-store paths**, and the activation model was doing work that can instead live entirely in the user flake.

The minimal design that still works is:

```text
host:
  Nix CLI, no daemon
  user namespaces
  fixed user + linger
  /home/user mounted before systemd --user

user flake:
  generation
    └── systemd/user/*
  switch app
    └── swaps ~/.config/systemd/user
        stops removed
        restarts changed
        starts added
        maintains one GC root
```

Nix's chroot store keeps logical paths as `/nix/store/...` while physically storing them under `~/.local/share/nix/root/nix/store/...`; Nix itself sets up the mount/user namespace when running programs from it. ([Nix][1])

## Host flake

This is the entire user-related addition I would make to the host:

```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }: {
    nixosConfigurations.vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";

      modules = [
        ./your-existing-host.nix

        ({ pkgs, ... }:
          let
            user = "user";
            uid = 1000;
          in
          {
            # No nix-daemon, nixbld users, profiles, etc.
            nix.enable = false;

            # But keep the Nix CLI.
            environment.systemPackages = [
              pkgs.nix
            ];

            environment.etc."nix/nix.conf".text = ''
              experimental-features = nix-command flakes
            '';

            # Required for the unprivileged chroot store.
            security.allowUserNamespaces = true;

            users.users.${user} = {
              isNormalUser = true;
              inherit uid;
              home = "/home/${user}";
              createHome = false;

              # Start systemd --user at boot.
              linger = true;
            };

            # Your other host config must mount /home/user.
            #
            # Do not let the lingered user manager start until
            # the persistent home image is mounted.
            environment.etc."systemd/system/user@${toString uid}.service.d/home.conf".text = ''
              [Unit]
              RequiresMountsFor=/home/${user}
            '';
          })
      ];
    };
  };
}
```

`nix.enable = false` really matters here: the NixOS module otherwise installs the normal Nix machinery; with it false we explicitly add only `pkgs.nix`. ([GitHub][2])

`security.allowUserNamespaces` is required because a local chroot store needs mount and user namespaces. ([GitHub][3])

And linger is what makes the user manager exist at boot without a login. ([NixOS Wiki][4])

If you're importing NixOS's hardened profile specifically, also set:

```nix
security.unprivilegedUsernsClone = true;
```

On ordinary 26.05 NixOS that isn't necessary. ([GitHub][3])

---

# User flake

This is a complete example with one service.

```nix
{
  description = "User environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      #
      # An example long-running user service.
      #
      heartbeat = pkgs.writeShellApplication {
        name = "heartbeat";

        runtimeInputs = [
          pkgs.coreutils
        ];

        text = ''
          while true; do
            echo "heartbeat $(date -Is)"
            sleep 30
          done
        '';
      };

      #
      # Immutable desired user-systemd generation.
      #
      generation = pkgs.runCommand "user-generation" {} ''
        units="$out/systemd/user"

        mkdir -p "$units/default.target.wants"

        cat > "$units/heartbeat.service" <<EOF
        [Unit]
        Description=Heartbeat

        [Service]
        ExecStart=/run/current-system/sw/bin/nix --offline --store %h/.local/share/nix/root shell ${heartbeat} --command ${heartbeat}/bin/heartbeat
        Restart=always
        RestartSec=2s
        EOF

        ln -s \
          ../heartbeat.service \
          "$units/default.target.wants/heartbeat.service"
      '';

      #
      # One-shot activation command.
      #
      switch = pkgs.writeShellApplication {
        name = "user-switch";

        # These must come from the PRIVATE store because this program
        # itself executes inside the private-store mount namespace.
        runtimeInputs = [
          pkgs.coreutils
          pkgs.systemd
        ];

        text = ''
          set -eu

          store="$HOME/.local/share/nix/root"

          # ${generation} is the logical path:
          #
          #   /nix/store/xxx-user-generation
          #
          # systemd, outside the Nix namespace, needs its physical path:
          #
          #   ~/.local/share/nix/root/nix/store/xxx-user-generation
          #
          new="$store${generation}/systemd/user"

          units="$HOME/.config/systemd/user"

          roots="$store/nix/var/nix/gcroots"
          current="$roots/user-generation"
          candidate="$roots/user-generation.new"

          export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

          mkdir -p "$HOME/.config/systemd" "$roots"

          #
          # This scheme owns the complete user unit directory.
          #
          if [ -e "$units" ] || [ -L "$units" ]; then
            if [ ! -L "$units" ]; then
              echo "$units already exists and is not a symlink" >&2
              exit 1
            fi

            old="$(readlink -f "$units")"
          else
            old=
          fi

          #
          # Protect the new generation before touching running services.
          #
          rm -f "$candidate"
          ln -s ${generation} "$candidate"

          #
          # Stop services that disappeared.
          #
          if [ -n "$old" ] && [ -d "$old" ]; then
            for f in "$old"/*.service; do
              [ -e "$f" ] || continue

              name="''${f##*/}"

              if [ ! -e "$new/$name" ]; then
                systemctl --user stop "$name"
              fi
            done
          fi

          #
          # Atomically make the new unit generation visible to systemd.
          #
          tmp="$HOME/.config/systemd/user.new.$$"

          rm -f "$tmp"
          ln -s "$new" "$tmp"
          mv -Tf "$tmp" "$units"

          systemctl --user daemon-reload

          #
          # New       -> start
          # Changed   -> restart
          # Unchanged -> nothing
          #
          for f in "$new"/*.service; do
            [ -e "$f" ] || continue

            name="''${f##*/}"

            if [ -z "$old" ] || [ ! -e "$old/$name" ]; then
              systemctl --user start "$name"

            elif ! cmp -s "$old/$name" "$f"; then
              systemctl --user restart "$name"
            fi
          done

          #
          # New generation is now committed.
          #
          mv -Tf "$candidate" "$current"
        '';
      };
    in
    {
      packages.${system}.generation = generation;

      apps.${system}.switch = {
        type = "app";
        program = "${switch}/bin/user-switch";
      };
    };
}
```

## Why the GC root is necessary

This:

```bash
ln -s /nix/store/...-user-generation \
    ~/.local/share/nix/root/nix/var/nix/gcroots/user-generation
```

isn't extra framework; it's necessary.

Otherwise:

```bash
nix store gc
```

could delete the active generation and its service packages even though systemd has filesystem symlinks pointing at them. Nix defines persistent roots exactly as symlinks under its `gcroots` directory. ([Nix][5])

We only retain **one** root: the current generation.

The temporary `user-generation.new` exists solely so that both old and new closures remain alive while switching.

---

## Deployment

From the unprivileged user:

```bash
nix \
  --store "$HOME/.local/share/nix/root" \
  run 'github:you/user-config/<commit>#switch'
```

That one command:

```text
fetch/evaluate flake
        ↓
build/download into private store
        ↓
run #switch
        ↓
stop removed services
        ↓
atomically swap ~/.config/systemd/user
        ↓
daemon-reload
        ↓
restart changed
start added
        ↓
update GC root
        ↓
exit
```

There is **no deployment daemon** left behind.

You could actually omit `--store ...` because, in the absence of a writable system store and nix-daemon socket, current Nix automatically falls back to `~/.local/share/nix/root`. I would keep it explicit because this machine is deliberately designed around that invariant. ([Nix][1])

## Boot

After one successful switch:

```text
boot
 │
 ├─ mount persistent /home/user
 │
 └─ user@1000.service      <- linger
          │
          ▼
      systemd --user
          │
          ▼
      default.target
          │
          ▼
 default.target.wants/
          │
          ▼
 heartbeat.service
          │
          ▼
 host Nix CLI
   --store ~/.local/share/nix/root
          │
          ▼
 private /nix/store mounted over /nix/store
          │
          ▼
      heartbeat
```

`default.target` is specifically the main target started automatically by a systemd **user** manager, so putting the relative wants links inside the generation is sufficient for boot autostart. ([man7.org][6])

Also, the Nix process isn't a daemon around the service. Its chroot-store execution path sets up the namespace and then `exec`s the requested program. 

This is about the minimum I'd remove down to. The pieces remaining each serve an actual requirement:

```text
linger                  boot without login
RequiresMountsFor        don't race persistent home
private Nix store        rootless package management
physical unit-dir link   host systemd can read units
Nix launcher             private packages see logical /nix/store
default.target.wants     boot autostart
daemon-reload            systemd sees switched generation
service diff             only changed things restart
one GC root              active closure cannot disappear
```

Everything else from the earlier design — manifests, custom target, host switch helper, `previous`, enable/disable calls, per-unit home symlinks — is unnecessary.

[1]: https://nix.dev/manual/nix/2.34/command-ref/new-cli/nix3-help-stores?utm_source=chatgpt.com "nix help-stores - Nix 2.34.9 Reference Manual"
[2]: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/config/nix.nix "nixpkgs/nixos/modules/config/nix.nix at master · NixOS/nixpkgs · GitHub"
[3]: https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/security/misc.nix?utm_source=chatgpt.com "nixpkgs/nixos/modules/security/misc.nix at master · NixOS/nixpkgs · GitHub"
[4]: https://wiki.nixos.org/wiki/Systemd/User_Services?utm_source=chatgpt.com "Systemd/User Services - Official NixOS Wiki"
[5]: https://nix.dev/manual/nix/2.34/package-management/garbage-collector-roots?utm_source=chatgpt.com "Garbage Collector Roots - Nix 2.34.9 Reference Manual"
[6]: https://man7.org/linux/man-pages/man7/systemd.special.7.html?utm_source=chatgpt.com "systemd.special(7) - Linux manual page"
