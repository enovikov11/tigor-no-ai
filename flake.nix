{
  description = "Tigor no AI Monorepo";

  inputs = {
    # 2026-08-20 https://github.com/NixOS/nixpkgs/commits/nixos-26.05/
    nixpkgs.url = "github:NixOS/nixpkgs/5880666fd9eb563038431edb35c2d0aa595884e6";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      # Number of a commit in a repo, r123 = 123th commit in tigor-no-ai
      revision = "r73";

      # Public password hash is a tradeoff between usability and security, underlying is high entropy
      yubiSshKey = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIMltMQTMSIcxPbZLNCxkAT/MWRqJo1IFOfH95OoscQbCAAAABHNzaDo= enovikov11@novikov.local";
      mainPassword = "$6$JsF575e4YV0MxwGU$aDy3BMHg/5lvWZoMvsAV0TL/BIcXMu3ps1DnOf3.o.hQ3IqT/sfCwKJHdMaaRy2exNAEUFxpxPbO966DE5cm./";

      lib = nixpkgs.lib;
      system = "x86_64-linux";

      gnomeModule =
        {
          scalingFactor,
          includeVMManager ? false,
        }:
        { lib, pkgs, ... }: {
          hardware.graphics.enable = true;

          services.xserver.enable = true;
          services.displayManager.gdm.enable = true;
          services.desktopManager.gnome.enable = true;

          environment.gnome.excludePackages = with pkgs; [
            gnome-backgrounds
            gnome-bluetooth
            gnome-color-manager
            gnome-tour
            gnome-user-docs
            gnome-menus
            orca
          ];

          hardware.bluetooth.enable = false;
          services.hardware.bolt.enable = false;
          i18n.inputMethod.enable = false;
          services.avahi.enable = false;
          services.colord.enable = false;
          services.dleyna.enable = false;
          services.geoclue2.enable = false;
          services.power-profiles-daemon.enable = false;
          services.orca.enable = false;
          services.upower.enable = lib.mkForce false;
          services.gnome = {
            core-apps.enable = false;
            evolution-data-server.enable = lib.mkForce false;
            gcr-ssh-agent.enable = false;
            gnome-browser-connector.enable = false;
            gnome-initial-setup.enable = false;
            gnome-keyring.enable = false;
            gnome-online-accounts.enable = false;
            gnome-remote-desktop.enable = false;
            gnome-user-share.enable = false;
            localsearch.enable = false;
            rygel.enable = false;
            tinysparql.enable = false;
          };

          services.pipewire = {
            enable = true;
            alsa.enable = true;
            pulse.enable = true;
          };

          programs.gnome-disks.enable = true;

          environment.systemPackages = with pkgs; [
            nautilus
            gnome-console
          ];

          xdg.mime.defaultApplications = {
            "inode/directory" = [ "org.gnome.Nautilus.desktop" ];
          };

          programs.dconf.profiles = {
            gdm.databases = [
              {
                settings = {
                  "org/gnome/desktop/interface".scaling-factor = lib.gvariant.mkUint32 scalingFactor;
                  "org/gnome/settings-daemon/plugins/power" = {
                    sleep-inactive-ac-type = "nothing";
                    sleep-inactive-battery-type = "nothing";
                  };
                };
              }
            ];

            user.databases = [
              {
                settings = {
                  "org/gnome/desktop/interface".scaling-factor = lib.gvariant.mkUint32 scalingFactor;
                  "org/gnome/desktop/session".idle-delay = lib.gvariant.mkUint32 0;
                  "org/gnome/settings-daemon/plugins/housekeeping".donation-reminder-enabled = false;
                  "org/gnome/settings-daemon/plugins/power" = {
                    sleep-inactive-ac-type = "nothing";
                    sleep-inactive-battery-type = "nothing";
                  };
                  "org/gnome/shell".favorite-apps = [
                    "org.gnome.Nautilus.desktop"
                    "org.gnome.Console.desktop"
                    "org.gnome.DiskUtility.desktop"
                  ]
                  ++ lib.optionals includeVMManager [ "virt-manager.desktop" ];
                };
              }
            ];
          };
        };

      nvidiaModule =
        { gnome }:
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          nvidiaSmi = lib.getExe' config.hardware.nvidia.package "nvidia-smi";
        in
        {
          hardware.graphics.enable = true;
          services.xserver.videoDrivers = [ "nvidia" ];
          hardware.nvidia = {
            branch = "production";
            modesetting.enable = gnome;
            open = true;
            nvidiaSettings = gnome;
            nvidiaPersistenced = true;
          };

          systemd.services.nvidia-profile = {
            description = "Configure NVIDIA GPU ECC and power profile";
            wantedBy = [ "multi-user.target" ];
            after = [ "nvidia-persistenced.service" ];
            wants = [ "nvidia-persistenced.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              Restart = "on-failure";
              RestartSec = "2s";
            };
            script = ''
              current="$(${nvidiaSmi} --query-gpu=ecc.mode.current --format=csv,noheader 2>&1)" || {
                echo "NVIDIA ECC status unavailable: $current"
                current=
              }
              if [[ -n "$current" ]] &&
                 ${pkgs.gnugrep}/bin/grep -qv '^Enabled$' <<< "$current"; then
                ${nvidiaSmi} --ecc-config=1 ||
                  echo "NVIDIA ECC is not configurable on this GPU in its current mode"
              fi
              ${nvidiaSmi} -pm 1 &&
                ${nvidiaSmi} -pl 450 &&
                ${nvidiaSmi} --lock-gpu-clocks=300,2400
            '';
          };

        };

      containersModule = { pkgs, ... }: {
        virtualisation.podman = {
          enable = true;
          dockerCompat = true;
          extraRuntimes = [ pkgs.gvisor ];
        };
        environment.systemPackages = with pkgs; [
          podman
          podman-compose
          gvisor
        ];
      };

      nvidiaContainerToolkitModule = { lib, pkgs, ... }: {
        hardware.nvidia-container-toolkit.enable = true;

        environment.etc."nvidia-container-runtime/config.toml".text = ''
          [nvidia-container-runtime-hook]
          path = "${pkgs.nvidia-container-toolkit.tools}/bin/nvidia-container-runtime-hook"

          [nvidia-ctk]
          path = "${pkgs.nvidia-container-toolkit}/bin/nvidia-ctk"

          [features]
          disable-cuda-compat-lib-hook = true
        '';
      };

      stateless =
        {
          vm ? false,
          nvidia ? false,
          containers ? false,
          gnome ? false,
          scalingFactor ? 1,
          firefox ? false,
          vscodium ? false,
          sudo ? false,
          password ? "!",
          authorizedSshKeys ? [ yubiSshKey ],
          vsock ? false,
          mainUser ? "public",
        }:
        let
          hostNvidia = (!vm) && nvidia;
          rtxPassthrough = (!vm) && (!nvidia);
          userUids = {
            public = 2000;
            private = 2001;
            secret = 2002;
          };
          telegrafUser = if vm then mainUser else "private";
          telegrafDir = if vm then "/ssd/${mainUser}/telegraf" else "/hdd/private/telegraf";
          vfioPciIds =
            # Bind the unused GPU's complete IOMMU group before display drivers probe.
            lib.optionals hostNvidia [
              # 01:00.0 GT 710 and 01:00.1 HDMI audio.
              "10de:128b"
              "10de:0e0f"
            ]
            ++ lib.optionals rtxPassthrough [
              # 41:00.0 RTX PRO 6000 and 41:00.1 HDMI audio.
              "10de:2bb1"
              "10de:22e8"
            ];
          imageName =
            (if vm then "vm-" else "host-")
            + revision
            + lib.optionalString nvidia "-nvda"
            + lib.optionalString containers "-pods"
            + lib.optionalString gnome "-gui"
            + lib.optionalString firefox "-ff"
            + lib.optionalString vscodium "-vs"
            + lib.optionalString sudo "-su"
            + lib.optionalString vsock "-vsock"
            + lib.optionalString vm ("-" + mainUser);
          ukiName = "${imageName}-BOOTX64";
        in
        lib.nixosSystem {
          inherit system;

          modules = [
            (
              {
                config,
                lib,
                pkgs,
                modulesPath,
                ...
              }:
              {
                imports = [
                  (modulesPath + "/installer/netboot/netboot.nix")
                  (modulesPath + (if vm then "/profiles/qemu-guest.nix" else "/profiles/minimal.nix"))
                ];

                time.timeZone = "Europe/Belgrade";
                i18n.defaultLocale = "en_US.UTF-8";

                nixpkgs.config.allowUnfreePredicate = pkg: lib.hasPrefix "nvidia-" (lib.getName pkg);
                nix.settings = {
                  experimental-features = [
                    "nix-command"
                    "flakes"
                  ];
                  max-jobs = 4;
                  cores = 32;
                };

                networking = {
                  hostName = imageName;
                  hostId = lib.mkIf (!vm) "06e694f9";
                  firewall.enable = !vm;
                  nftables.enable = true;
                  nftables.tables = lib.optionalAttrs (!vm) {
                    vm_jail_guard = {
                      family = "inet";
                      content = ''
                        chain forward {
                          type filter hook forward priority raw; policy accept;
                          iifname "tap-*" counter drop
                        }
                      '';
                    };
                  };
                  networkmanager.enable = true;
                };

                fileSystems."/ssd/${mainUser}" = lib.mkIf vm {
                  device = "/dev/vda";
                  fsType = "ext4";
                  options = [
                    "noatime"
                    "nofail"
                    "nosuid"
                    "x-systemd.device-timeout=1s"
                  ];
                };

                services.openssh = {
                  enable = true;
                  generateHostKeys = vm;
                  openFirewall = true;
                  settings = {
                    AuthenticationMethods = "publickey";
                    PasswordAuthentication = false;
                    KbdInteractiveAuthentication = false;
                    PermitEmptyPasswords = false;
                    X11Forwarding = false;
                    PermitRootLogin = "prohibit-password";
                    AllowUsers = [
                      "root"
                      "public"
                      "private"
                      "secret"
                    ];
                  };
                };

                security.sudo = {
                  enable = sudo;
                }
                // lib.optionalAttrs sudo { wheelNeedsPassword = false; };

                users.mutableUsers = false;
                users.users =
                  {
                    root = {
                      hashedPassword = "!";
                      openssh.authorizedKeys.keys = [ yubiSshKey ];
                    };
                    public = {
                      uid = 2000;
                      group = "public";
                    };
                    private = {
                      uid = 2001;
                      group = "private";
                    };
                    secret = {
                      uid = 2002;
                      group = "secret";
                    };
                  }
                  // lib.optionalAttrs (!vm) {
                    public = {
                      uid = 2000;
                      group = "public";
                      isNormalUser = true;
                      home = "/ssd/public";
                    };
                    private = {
                      uid = 2001;
                      group = "private";
                      isNormalUser = true;
                      home = "/ssd/private";
                    };
                    secret = {
                      uid = 2002;
                      group = "secret";
                      isNormalUser = true;
                      home = "/ssd/secret";
                    };
                  }
                  // lib.optionalAttrs vm {
                    "${mainUser}" = {
                      uid = userUids."${mainUser}";
                      group = mainUser;
                      isNormalUser = true;
                      home = "/ssd/${mainUser}";
                      linger = true;
                      hashedPassword = password;
                      extraGroups =
                        lib.optionals sudo [ "wheel" ]
                        ++ lib.optionals (gnome || nvidia) [
                          "video"
                          "render"
                        ];
                      openssh.authorizedKeys.keys = authorizedSshKeys;
                    };
                  };
                users.groups = {
                  public = {
                    gid = 2000;
                    members = [
                      "public"
                      "private"
                      "secret"
                    ];
                  };
                  private = {
                    gid = 2001;
                    members = [
                      "private"
                      "secret"
                    ];
                  };
                  secret = {
                    gid = 2002;
                    members = [ "secret" ];
                  };
                  kvm.members = lib.optionals (!vm) [ "qemu-libvirtd" ];
                };

                boot = {
                  supportedFilesystems = lib.optionals (!vm) [ "zfs" ];

                  initrd.kernelModules =
                    lib.optionals (vfioPciIds != [ ]) [
                      "vfio_pci"
                      "vfio"
                      "vfio_iommu_type1"
                    ]
                    # NVIDIA GeForce GT 710
                    ++ lib.optionals (gnome && !nvidia) [ "nouveau" ];
                  kernelModules = lib.optionals vm [ "virtiofs" ]
                    ++ lib.optionals (vm && vsock) [ "vsock_virtio" ]
                    ++ lib.optionals (!vm) [ "kvm-amd" ];
                  kernelParams = [
                    "nohibernate"
                    "modprobe.blacklist=ast"
                    "transparent_hugepage=madvise"
                  ]
                  ++ lib.optionals vm [
                    "console=tty0"
                    "console=ttyS0,115200n8"
                  ]
                  ++ lib.optionals (!vm) [
                    "default_hugepagesz=1G"
                    "hugepagesz=1G"
                    "hugepages=256"
                    "kvm_amd.sev=1"
                    "kvm_amd.sev_es=1"
                    "amd_iommu=on"
                    "iommu=pt"
                    "iommu.strict=1"
                  ]
                  ++ lib.optional (vfioPciIds != [ ]) "vfio-pci.ids=${lib.concatStringsSep "," vfioPciIds}";
                  blacklistedKernelModules =
                    [ "ast" ]
                    # NVIDIA's open driver supports the RTX PRO, not the GT 710.
                    ++ lib.optionals hostNvidia [ "nouveau" ];
                  uki = {
                    name = ukiName;
                    version = null;
                    settings.UKI.Initrd = lib.mkForce "${config.system.build.netbootRamdisk}/initrd";
                  };
                  zfs.forceImportRoot = lib.mkIf (!vm) false;
                };

                systemd.services."serial-getty@ttyS0".enable = lib.mkIf vm true;

                # Allow non-root users to bind to ports <= 1024 (VM services)
                boot.kernel.sysctl = lib.mkIf vm {
                  "net.ipv4.ip_unprivileged_port_start" = 0;
                };

                services.udev.extraRules = lib.optionalString (!vm) ''
                  SUBSYSTEM=="misc", KERNEL=="sev", GROUP="kvm", MODE="0660"
                '';
                services.xserver.videoDrivers = lib.mkIf (gnome && !nvidia) [ "nouveau" ];

                services.qemuGuest.enable = vm;
                services.spice-vdagentd.enable = vm && gnome;
                systemd.sockets.sshd = lib.mkIf (vm && vsock) {
                  socketConfig.ListenStream = lib.mkForce [
                    "0.0.0.0:22"
                    "vsock::22"
                  ];
                };
                systemd.services.mount-virtiofs-shares = lib.mkIf vm {
                  description = "Mount virtiofs path shares";
                  wantedBy = [ "multi-user.target" ];
                  after = [ "systemd-modules-load.service" ];
                  serviceConfig.Type = "oneshot";
                  path = with pkgs; [
                    coreutils
                    util-linux
                  ];
                  script = ''
                    shopt -s nullglob
                    for tagFile in /sys/fs/virtiofs/*/tag; do
                      IFS= read -r path < "$tagFile"
                      mkdir -p -- "$path"
                      mount -t virtiofs -o nosuid -- "$path" "$path"
                    done
                  '';
                };
                services.displayManager.autoLogin = lib.mkIf (vm && gnome) {
                  enable = true;
                  user = mainUser;
                };

                programs.firefox.enable = firefox;
                programs.virt-manager.enable = (!vm);

                virtualisation.libvirtd = lib.mkIf (!vm) {
                  enable = true;
                  onBoot = "ignore";
                  onShutdown = "shutdown";
                  firewallBackend = "nftables";
                  qemu = {
                    package = pkgs.qemu_kvm;

                    runAsRoot = false;

                    verbatimConfig = ''
                      namespaces = []
                      seccomp_sandbox = 1
                      spice_auto_unix_socket = 1
                      vnc_auto_unix_socket = 1
                    '';

                    vhostUserPackages = [ pkgs.virtiofsd ];
                  };
                };

                systemd.services.virt-secret-init-encryption = lib.mkIf (!vm) {
                  serviceConfig = {
                    StateDirectory = "libvirt/secrets";
                    StateDirectoryMode = "0700";
                    ExecStart = lib.mkForce [
                      ""
                      (pkgs.writeShellScript "virt-secret-init-encryption" ''
                        umask 0077
                        ${pkgs.coreutils}/bin/chmod 0700 /var/lib/libvirt/secrets
                        ${pkgs.coreutils}/bin/dd if=/dev/random status=none bs=32 count=1 | \
                          ${pkgs.systemd}/bin/systemd-creds encrypt --with-key=tpm2-absent \
                            --name=secrets-encryption-key \
                            - /var/lib/libvirt/secrets/secrets-encryption-key
                      '')
                    ];
                  };
                };

                systemd.tmpfiles.rules =
                  [ "w /sys/kernel/mm/transparent_hugepage/defrag - - - - defer" ]
                  ++ lib.optionals (!vm) [
                    "d /etc/tigor 0775 root libvirtd -"
                    "d /hdd/private/telegraf 0750 private private -"
                  ]
                  ++ lib.optionals vm [ "d /ssd/${mainUser}/telegraf 0750 ${mainUser} ${mainUser} -" ];
                systemd.targets.sleep.enable = false;
                systemd.targets.suspend.enable = false;
                systemd.targets.hibernate.enable = false;
                systemd.targets.hybrid-sleep.enable = false;

                environment.etc =
                  {
                    "nixos/telegraf.conf".text = ''
                      [agent]
                        interval = "10s"
                      [[inputs.cpu]]
                        percpu = true
                        totalcpu = true
                      [[inputs.mem]]
                      [[inputs.disk]]
                        ignore_fs = ["tmpfs", "devtmpfs", "devfs", "sysfs", "squashfs", "efivarfs"]
                      [[inputs.diskio]]
                      [[inputs.swap]]
                      [[inputs.net]]
                      [[inputs.netstat]]
                      [[inputs.processes]]
                      [[inputs.system]]
                      [[inputs.kernel]]
                      [[inputs.nvidia_smi]]
                      [[outputs.file]]
                        files = ["${telegrafDir}/metrics.log"]
                        rotation_max_archives = 3
                        data_format = "influx"
                    '';
                    "tigor/flake.nix.bak".source = ./flake.nix;
                    "tigor/flake.nix" = {
                      source = ./flake.nix;
                      mode = "0644";
                    };
                  }
                  // lib.optionalAttrs (!vm) {
                    "tigor/vm.xsl.bak".source = ./vm.xsl;
                    "tigor/vm.xsl" = {
                      source = ./vm.xsl;
                      mode = "0644";
                    };
                    "tigor/vm.sh.bak".source = ./vm.sh;
                    "tigor/vm.sh" = {
                      source = ./vm.sh;
                      mode = "0644";
                    };
                    "tigor/ssh_host_ed25519_key" = {
                      source = ./ssh_host_ed25519_key;
                      mode = "0600";
                    };
                    "ssh/ssh_host_ed25519_key" = {
                      source = ./ssh_host_ed25519_key;
                      mode = "0600";
                    };
                  };
                environment.systemPackages =
                  (with pkgs; [
                    bubblewrap
                    virt-viewer
                    spice-gtk
                    curl
                    git
                    htop
                    python3
                    reptyr
                    tmux
                    vim
                    tree
                    wireguard-tools
                    jq
                    pciutils
                    usbutils
                    dmidecode
                    ethtool
                    smartmontools
                    nvme-cli
                    lm_sensors
                    hdparm
                    ipmitool
                    efibootmgr
                    e2fsprogs
                    libxslt
                    telegraf
                    ncdu
                  ])
                  ++ lib.optionals vscodium (with pkgs; [ vscodium ])
                  ++ lib.optionals (!vm) (with pkgs; [ zfs ])
                  ++ lib.optionals (!vm) (
                    with pkgs;
                    [
                      qemu_kvm
                      libvirt
                      openssl
                      virt-manager
                      passt
                      virtiofsd
                      socat
                    ]
                  );
                environment.sessionVariables = lib.optionalAttrs vscodium { NIXOS_OZONE_WL = "1"; };
                environment.shellAliases = lib.optionalAttrs (!vm) {
                  mnt = "zpool import -a && zfs load-key -a && zfs mount -a";
                  vm-up = "tmux new-session -s hermes 'bash /etc/tigor/vm.sh; exec bash'";
                  vm-attach = "tmux a -t hermes";
                }
                // lib.optionalAttrs (vm) {
                  pod = "podman compose up -d --remove-orphans";
                };
                systemd.services.telegraf = {
                  description = "Telegraf metrics collector";
                  wantedBy = [ "multi-user.target" ];
                  after = [ "network.target" ];
                  serviceConfig = {
                    Type = "simple";
                    User = telegrafUser;
                    Group = telegrafUser;
                  };
                  script = ''
                    exec ${pkgs.telegraf}/bin/telegraf --non-strict-env-handling \
                      -c /etc/nixos/telegraf.conf \
                      --config-directory /etc/nixos/telegraf.d
                  '';
                };

                system.stateVersion = "26.05";
              }
            )
          ]
          ++ lib.optional gnome (gnomeModule {
            inherit scalingFactor;
            includeVMManager = (!vm);
          })
          ++ lib.optional nvidia (nvidiaModule {
            inherit gnome;
          })
          ++ lib.optional containers containersModule
          ++ lib.optional (containers && nvidia) nvidiaContainerToolkitModule;
        };
    in
    {
      nixosConfigurations = {
        host = stateless {
          containers = true;
          gnome = true;
          scalingFactor = 2;
          sudo = true;
          password = mainPassword;
        };
        vm = stateless {
          vm = true;
          nvidia = true;
          containers = true;
          vsock = true;
          password = "";
        };
      };

      packages.${system} = {
        host = self.nixosConfigurations.host.config.system.build.uki;
        vm = self.nixosConfigurations.vm.config.system.build.uki;
      };
    };
}
