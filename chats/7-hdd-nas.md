I have 7 pocket size hdds 2.5 4tb each usb

What x64 single board computer i can use that has 7 usb 3.0 ports or either pcie for usb so i can connect them?

I used hub chips and they die under raid load on rpi

--

Yes. For this workload I would **not** look for an SBC with seven onboard USB sockets. That usually just means hidden hub silicon somewhere.

### Best small SBC solution: Radxa X4 + real PCIe USB controller

The **Radxa X4** is probably the cleanest fit. It is genuinely Raspberry-Pi-sized at **85 × 56 mm**, uses an Intel **N100 x86-64**, has **3× USB 3.x Type-A**, optional onboard eMMC, and—most importantly—its M.2 M-key connector exposes **PCIe 3.0 x4**. ([Radxa Docs][1])

Use the optional eMMC for the OS, leaving the M.2 slot free:

```text
Radxa X4
│
├── USB3 #1 ── HDD
├── USB3 #2 ── HDD
├── USB3 #3 ── HDD
│
└── M.2 M-key PCIe 3.0 x4
       │
       └── M.2 → PCIe x4/x16 powered riser
              │
              └── 4-port PCIe USB controller
                   ├── HDD
                   ├── HDD
                   ├── HDD
                   └── HDD
```

For the controller, the interesting card is [StarTech PEXUSB3S44V](). It uses **four independent USB channels**, requires PCIe x4, supports UASP, and has auxiliary SATA/LP4 power. StarTech explicitly specifies **5 Gbit/s per port / 20 Gbit/s aggregate**, rather than hanging four sockets behind one USB hub. ([StarTech.com][2])

For exposing the Radxa's M.2 PCIe lanes, something in the ADT-Link family works. The R43SG, for example, exposes M.2 NVMe PCIe as an externally powered x16 physical slot with an **x4 PCIe 3.0 link**. ([ADT-Link][3]) There are also simpler R42A/R42C/R43B x4 adapters. ([Adt Link][4])

### [StarTech PEXUSB3S44V]()

*Цена није доступна*

### [ADT-Link R43SG]()

*Цена није доступна*

This is the configuration I'd choose if **physical size is important**.

### If this is really a NAS: ODROID-H5 is more interesting

The newly released **ODROID-H5** is a very storage-oriented x86 SBC: Intel **N300 8-core**, **10GbE**, 120 × 120 mm, and four M.2 slots providing **3× PCIe 3.0 x2 + 1× PCIe 3.0 x1**. It launched in May 2026. ([ODROID][5])

Unfortunately it only has one native USB 3 port, so I'd do something slightly different:

```text
ODROID-H5
  M.2 x2 -> powered PCIe adapter -> 4-port USB controller
  M.2 x2 -> powered PCIe adapter -> 4-port USB controller
```

Use two PCIe x1 cards based on **Renesas µPD720201**. That chip is particularly nice for this application because it is an actual PCIe USB host controller with **four native SuperSpeed ports**—PCIe Gen2 x1 in, four USB3 ports out. There is no downstream USB hub required. ([Renesas][6])

The StarTech **PEXUSB3S4V** is one such card: PCIe x1, Renesas µPD720201, four USB-A ports, auxiliary SATA power. ([StarTech.com][7])

Two of those would give you **8 HDD ports across two independent xHCI controllers**, roughly:

```text
PCIe Gen2 x1 -> Renesas #1 -> HDD 1..4
PCIe Gen2 x1 -> Renesas #2 -> HDD 5..7
```

That's actually a pretty sensible topology for seven spinning disks. Four 2.5" HDDs may collectively outrun one Gen2 x1 link during ideal sequential reads, but two controllers give you somewhere around ~800 MB/s of realistic aggregate PCIe-side headroom. Your seven mechanical disks are in that general neighborhood anyway.

And the H5's onboard **10GbE** means the network won't immediately ruin all the effort. Hardkernel reports around 9.5 Gbit/s in its own testing. ([ODROID][5])

### Easier but physically larger: mini-ITX

If 17 × 17 cm is acceptable, I'd seriously consider forgetting the "SBC" requirement. A **mini-ITX N100 board + ATX PSU** solves a lot of power-distribution nonsense.

For example, ASUS's **PRIME N100I-D D4** has:

| Feature              | ASUS N100I-D D4 |
| -------------------- | --------------- |
| CPU                  | Intel N100      |
| Rear USB3            | 4               |
| Internal USB3 header | 2 more ports    |
| Total USB3           | **6**           |
| PCIe                 | PCIe 3.0 x1     |
| NVMe                 | PCIe 3.0 x2     |
| Size                 | 170 × 170 mm    |

([ASUS Global][8])

Add one PEXUSB3S4V and you have ten USB3 ports available. More importantly, you get a normal ATX PSU with a beefy 5V rail.

The downside is bandwidth: that PCIe x1 USB controller is limited to one 5-Gbit/s host link. Also this board only has 1GbE, which is unimpressive for a 28TB array.

### The part I would worry about most: power

Seven bus-powered 2.5" HDDs are nasty at spin-up.

At the USB 3 nominal maximum:

```text
0.9 A × 5 V × 7 = 31.5 W
```

And startup transient current can be worse than that.

So I would design for **at least ~50 W available on the 5V side**, not merely 31.5 W. This is probably a significant part of why your Raspberry Pi hub setup dies under load: not just USB bandwidth, but hub power switching/regulation, connector heating, and hub-controller instability when several bridges/drives are hammering it simultaneously.

For the PCIe cards, use their **auxiliary power inputs**. On the PEXUSB3S44V I'd prefer the LP4/Molex input over a questionable SATA splitter.

Also, avoid cards marketed as:

> "7-port PCIe USB 3.0 card"

unless you inspect their topology. Many are essentially:

```text
PCIe
  -> one xHCI USB controller
     -> USB hub
        -> 7 ports
```

which puts you right back where you started.

What you want is:

```text
PCIe -> xHCI controller -> physical USB ports
```

or, ideally:

```text
PCIe
├── xHCI controller -> port
├── xHCI controller -> port
├── xHCI controller -> port
└── xHCI controller -> port
```

After assembling it, `lspci -nn` and `lsusb -t` will tell you immediately whether someone snuck a hub chip into the design.

**My pick:** **Radxa X4 + eMMC + M.2→PCIe x4 + PEXUSB3S44V** for minimum size. If this is intended to be a serious 24/7 NAS and 10GbE matters, I'd instead build around the **ODROID-H5 with two Renesas µPD720201 controllers**.

[1]: https://docs.radxa.com/en/x/x4?utm_source=chatgpt.com "Radxa X4 | Radxa Docs"
[2]: https://www.startech.com/en-us/cards-adapters/pexusb3s44v?utm_source=chatgpt.com "Add four USB 3.0 (USB 3.2 Gen 1) ports with four independent channels, LP/SATA power, and charging support to your PC through a PCI Express slot"
[3]: https://www.adtlink.cn/en/product/R43SG.html?utm_source=chatgpt.com "R43SG"
[4]: https://www.adt.link/product/R42A-R43B.html?utm_source=chatgpt.com "ADT M.2 NVMe to PCIe 4.0 x4/x16 adapter"
[5]: https://www.hardkernel.com/shop/odroid-h5/ "ODROID-H5 – ODROID"
[6]: https://www.renesas.com/en/products/upd720201?tab=documentation&utm_source=chatgpt.com "UPD720201 - USB 3.0 Host Controller | Renesas"
[7]: https://www.startech.com/en-us/cards-adapters/pexusb3s4v?utm_source=chatgpt.com "Add 4 external USB 3.0 (USB 3.2 Gen 1) ports to a low profile or standard computer, through PCI Express"
[8]: https://www.asus.com/motherboards-components/motherboards/prime/prime-n100i-d-d4/?utm_source=chatgpt.com "PRIME N100I-D D4｜Motherboards｜ASUS Global"
