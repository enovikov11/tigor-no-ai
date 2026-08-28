<?xml version="1.0" encoding="UTF-8"?>
<xsl:stylesheet version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:cfg="urn:vm-config"
  xmlns:exsl="http://exslt.org/common"
  extension-element-prefixes="exsl"
  exclude-result-prefixes="cfg exsl">
  <xsl:output method="xml" encoding="UTF-8" indent="yes"/>

  <xsl:template match="/">
    <xsl:for-each select="/xsl:stylesheet/cfg:vm">
      <exsl:document href="{concat(@name, '.xml')}" method="xml" encoding="UTF-8" indent="yes">
        <xsl:apply-templates select="."/>
      </exsl:document>
    </xsl:for-each>
  </xsl:template>

  <xsl:template match="cfg:vm">
    <domain type="kvm">
      <name><xsl:value-of select="@name"/></name>
      <memory unit="GiB"><xsl:value-of select="@ram"/></memory>
      <memoryBacking>
        <xsl:choose>
            <xsl:when test="@hardened = 'true'"><locked/></xsl:when>
            <xsl:when test="cfg:mount"><source type="memfd"/><access mode="shared"/></xsl:when>
        </xsl:choose>
      </memoryBacking>
      <vcpu><xsl:value-of select="@cpu"/></vcpu>
      <os>
        <type arch="x86_64" machine="pc-q35-10.2">hvm</type>
        <loader readonly="yes" type="pflash" stateless="yes" format="raw">/run/libvirt/nix-ovmf/edk2-x86_64-code.fd</loader>
        <xsl:choose>
          <xsl:when test="@kernel"><kernel><xsl:value-of select="@kernel"/></kernel></xsl:when>
          <xsl:otherwise><boot dev="hd"/></xsl:otherwise>
        </xsl:choose>
      </os>
      <features><acpi/><apic/><ioapic driver="kvm"/><smm state="off"/><vmport state="off"/></features>
      <cpu mode="host-passthrough" check="none" migratable="off">
        <xsl:if test="not(@nested = 'true')">
          <feature policy="disable" name="svm"/>
        </xsl:if>
      </cpu>
      <clock offset="utc"/>
      <devices>
        <emulator>/run/libvirt/nix-emulators/qemu-system-x86_64</emulator>
        <xsl:for-each select="cfg:disk">
          <disk type="file" device="disk">
            <driver name="qemu" type="qcow2" iommu="on"/>
            <source file="{@src}"/>
            <target dev="{@dst}" bus="virtio"/>
          </disk>
        </xsl:for-each>
        <xsl:for-each select="cfg:net">
          <interface type="vhostuser">
            <source type="unix" path="{@socket}" mode="client"/>
            <model type="virtio"/>
            <rom enabled="no"/>
            <address type="pci" domain="0x0000" bus="{@bus}" slot="0x00" function="0x0"/>
          </interface>
        </xsl:for-each>
        <xsl:if test="@ui = 'true'">
          <input type="mouse" bus="ps2"/>
          <input type="keyboard" bus="ps2"/>
          <graphics type="spice" autoport="yes"><listen type="address"/><image compression="off"/><gl enable="no"/></graphics>
          <video><model type="virtio" heads="1" primary="yes"><acceleration accel3d="no"/></model></video>
        </xsl:if>
        <xsl:if test="@gpu = 'true'">
          <hostdev mode="subsystem" type="pci" managed="yes">
            <source><address domain="0x0000" bus="0x41" slot="0x00" function="0x0"/></source>
          </hostdev>
          <hostdev mode="subsystem" type="pci" managed="yes">
            <source><address domain="0x0000" bus="0x41" slot="0x00" function="0x1"/></source>
          </hostdev>
        </xsl:if>
        <audio id="1" type="none"/>
        <watchdog model="itco" action="reset"/>
        <memballoon model="none"/>
        <rng model="virtio"><driver iommu="on"/><backend model="random">/dev/urandom</backend></rng>
        <xsl:if test="@vsock = 'true'">
          <vsock model="virtio"><cid>auto</cid></vsock>
        </xsl:if>
        <xsl:for-each select="cfg:mount">
          <filesystem type="mount">
            <driver type="virtiofs"/>
            <source dir="{@src}"/>
            <target dir="{@dst}"/>
            <xsl:if test="@readonly"><readonly/></xsl:if>
          </filesystem>
        </xsl:for-each>
      </devices>
      <xsl:if test="@hardened = 'true'">
        <launchSecurity type="sev"><policy>0x000f</policy><cbitpos>47</cbitpos><reducedPhysBits>1</reducedPhysBits></launchSecurity>
      </xsl:if>
    </domain>
  </xsl:template>

  <vm xmlns="urn:vm-config" name="hermes" user="public" cpu="64" ram="128" ui="true" gpu="true" vsock="true" kernel="/ssd/public/vm/kernels/vm-r73-nvda-pods-vsock-public-BOOTX64.efi">
    <mount src="/ssd/public/internet" dst="/ssd/public/internet" readonly="true"/>
    <mount src="/hdd/public/internet/kiwix" dst="/hdd/public/internet/kiwix" readonly="true"/>
    <mount src="/hdd/public/internet/wikipedia" dst="/hdd/public/internet/wikipedia" readonly="true"/>
    <mount src="/ssd/public/vm/hermes" dst="/ssd/public/vm/hermes"/>
    <mount src="/ssd/public/vm/hermes/telegraf" dst="/ssd/public/telegraf"/>
    <disk src="/ssd/vm/hermes.qcow2" dst="vda"/>
    <net socket="/run/hermes-passt.sock" bus="0x04"/>
  </vm>

  <!-- test-bare: minimal — boot hd, svm off, no ui/gpu/vsock/mount/net, empty memoryBacking -->
  <vm xmlns="urn:vm-config" name="test-bare" cpu="2" ram="2">
    <disk src="/tmp/test-bare.qcow2" dst="vda"/>
  </vm>

  <!-- test-kernel: kernel boot instead of hd -->
  <vm xmlns="urn:vm-config" name="test-kernel" cpu="2" ram="2" kernel="/boot/vmlinuz">
    <disk src="/tmp/test-kernel.qcow2" dst="vda"/>
  </vm>

  <!-- test-nested: nested='true' — svm NOT disabled -->
  <vm xmlns="urn:vm-config" name="test-nested" cpu="4" ram="4" nested="true">
    <disk src="/tmp/test-nested.qcow2" dst="vda"/>
  </vm>

  <!-- test-ui: SPICE + virtio video + PS2 input -->
  <vm xmlns="urn:vm-config" name="test-ui" cpu="2" ram="4" ui="true">
    <disk src="/tmp/test-ui.qcow2" dst="vda"/>
  </vm>

  <!-- test-gpu: PCI passthrough (0x41/0 + 0x41/1) -->
  <vm xmlns="urn:vm-config" name="test-gpu" cpu="4" ram="8" gpu="true">
    <disk src="/tmp/test-gpu.qcow2" dst="vda"/>
  </vm>

  <!-- test-vsock: vsock device -->
  <vm xmlns="urn:vm-config" name="test-vsock" cpu="2" ram="4" vsock="true">
    <disk src="/tmp/test-vsock.qcow2" dst="vda"/>
  </vm>

  <!-- test-multidisk: multiple disks -->
  <vm xmlns="urn:vm-config" name="test-multidisk" cpu="2" ram="4">
    <disk src="/tmp/test-multi-1.qcow2" dst="vda"/>
    <disk src="/tmp/test-multi-2.qcow2" dst="vdb"/>
    <disk src="/tmp/test-multi-3.qcow2" dst="vdc"/>
  </vm>

  <!-- test-multinet: multiple vhost-user nets -->
  <vm xmlns="urn:vm-config" name="test-multinet" cpu="2" ram="4">
    <disk src="/tmp/test-multinet.qcow2" dst="vda"/>
    <net socket="/run/test-net0.sock" bus="0x04"/>
    <net socket="/run/test-net1.sock" bus="0x05"/>
  </vm>

  <!-- test-mount-ro: mount with readonly — hits memfd+shared path -->
  <vm xmlns="urn:vm-config" name="test-mount-ro" cpu="2" ram="4">
    <mount src="/tmp/ro-data" dst="shared" readonly="true"/>
    <disk src="/tmp/test-mount-ro.qcow2" dst="vda"/>
  </vm>

  <!-- test-mount-rw: mount without readonly — memfd+shared -->
  <vm xmlns="urn:vm-config" name="test-mount-rw" cpu="2" ram="4">
    <mount src="/tmp/rw-data" dst="shared"/>
    <disk src="/tmp/test-mount-rw.qcow2" dst="vda"/>
  </vm>

  <!-- test-mount-mixed: mix of readonly and rw mounts -->
  <vm xmlns="urn:vm-config" name="test-mount-mixed" cpu="2" ram="4">
    <mount src="/tmp/ro1" dst="ro1" readonly="true"/>
    <mount src="/tmp/rw1" dst="rw1"/>
    <mount src="/tmp/ro2" dst="ro2" readonly="true"/>
    <disk src="/tmp/test-mount-mixed.qcow2" dst="vda"/>
  </vm>

  <!-- test-hardened: SEV — locked memoryBacking + launchSecurity -->
  <vm xmlns="urn:vm-config" name="test-hardened" cpu="2" ram="8" hardened="true" kernel="/boot/vmlinuz">
    <mount src="/tmp/test-hardened-data" dst="data"/>
    <disk src="/tmp/test-hardened.qcow2" dst="vda"/>
  </vm>

  <!-- test-hardened-vsock: SEV + vsock + kernel, no mounts (locked path) -->
  <vm xmlns="urn:vm-config" name="test-hardened-vsock" cpu="2" ram="8" hardened="true" vsock="true" kernel="/boot/vmlinuz">
    <disk src="/tmp/test-hardened-vsock.qcow2" dst="vda"/>
  </vm>

  <!-- test-all: everything except gpu (memfd+shared, all features) -->
  <vm xmlns="urn:vm-config" name="test-all" cpu="8" ram="16" ui="true" vsock="true" kernel="/boot/vmlinuz">
    <mount src="/tmp/ro" dst="ro" readonly="true"/>
    <mount src="/tmp/rw" dst="rw"/>
    <disk src="/tmp/test-all-1.qcow2" dst="vda"/>
    <disk src="/tmp/test-all-2.qcow2" dst="vdb"/>
    <net socket="/run/test-all.sock" bus="0x06"/>
  </vm>
</xsl:stylesheet>
