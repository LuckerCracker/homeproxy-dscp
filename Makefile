# SPDX-License-Identifier: GPL-2.0-only

include $(TOPDIR)/rules.mk

PKG_NAME:=homeproxy-dscp
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-only
PKG_MAINTAINER:=local

include $(INCLUDE_DIR)/package.mk

define Package/homeproxy-dscp
  SECTION:=net
  CATEGORY:=Network
  TITLE:=DSCP routing addon for HomeProxy
  DEPENDS:=+firewall4 +ip-full +jsonfilter +kmod-nft-tproxy +luci-app-homeproxy +nftables +sing-box +ucode +ucode-mod-fs +ucode-mod-uci
endef

define Package/homeproxy-dscp/description
  Update-safe DSCP routing addon for HomeProxy. It captures marked LAN
  TCP/UDP traffic with nftables and routes it through a separate sing-box
  instance using existing HomeProxy node definitions.
endef

define Package/homeproxy-dscp/conffiles
/etc/config/homeproxy_dscp
endef

define Build/Compile
endef

define Package/homeproxy-dscp/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/homeproxy_dscp $(1)/etc/config/homeproxy_dscp

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/homeproxy-dscp $(1)/etc/init.d/homeproxy-dscp

	$(INSTALL_DIR) $(1)/usr/share/homeproxy-dscp
	$(INSTALL_BIN) ./root/usr/share/homeproxy-dscp/generate.uc $(1)/usr/share/homeproxy-dscp/generate.uc

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/homeproxy-dscp $(1)/usr/libexec/rpcd/homeproxy-dscp

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-homeproxy-dscp.json $(1)/usr/share/luci/menu.d/luci-app-homeproxy-dscp.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-homeproxy-dscp.json $(1)/usr/share/rpcd/acl.d/luci-app-homeproxy-dscp.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/homeproxy-dscp
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/homeproxy-dscp/client.js $(1)/www/luci-static/resources/view/homeproxy-dscp/client.js
endef

$(eval $(call BuildPackage,homeproxy-dscp))
