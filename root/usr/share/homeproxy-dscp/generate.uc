#!/usr/bin/env ucode
/*
 * SPDX-License-Identifier: GPL-2.0-only
 *
 * Generate a small sing-box instance and nftables rules for DSCP-selected
 * Windows traffic. HomeProxy package files are intentionally not modified.
 */

'use strict';

import { writefile } from 'fs';
import { cursor } from 'uci';

const RUN_DIR = '/var/run/homeproxy-dscp';
const CONFIG_FILE = RUN_DIR + '/sing-box.json';
const NFT_FILE = RUN_DIR + '/ruleset.nft';
const STATE_FILE = RUN_DIR + '/state';
const TABLE_NAME = 'homeproxy_dscp';

const cfg_name = 'homeproxy_dscp';
const hp_name = 'homeproxy';
const network_name = 'network';
const uci = cursor();

uci.load(cfg_name);
uci.load(hp_name);
uci.load(network_name);

function is_empty(v) {
	return v == null || v === '' || (type(v) === 'array' && length(v) === 0);
}

function to_bool(v) {
	return v === true || v === '1' || v === 'true' || v === 'yes' || v === 'on';
}

function to_int(v) {
	return is_empty(v) ? null : int(v);
}

function to_time(v) {
	if (is_empty(v))
		return null;
	return match(v, /^[0-9]+$/) ? sprintf('%ss', v) : v;
}

function clean(obj) {
	if (type(obj) === 'array') {
		let out = [];
		for (let v in obj) {
			let cv = clean(v);
			if (cv != null && !(type(cv) === 'array' && length(cv) === 0))
				push(out, cv);
		}
		return out;
	}

	if (type(obj) === 'object') {
		for (let k in obj) {
			let cv = clean(obj[k]);
			if (cv == null || cv === '' || cv === false || (type(cv) === 'array' && length(cv) === 0))
				delete obj[k];
			else
				obj[k] = cv;
		}
	}

	return obj;
}

function parse_list(v) {
	if (is_empty(v))
		return [];
	return (type(v) === 'array') ? v : [ v ];
}

function parse_ports(v) {
	let ports = [];
	for (let p in parse_list(v))
		push(ports, int(p));
	return length(ports) ? ports : null;
}

function validate_ipv4(addr) {
	if (!match(addr, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/))
		return false;

	for (let p in split(addr, '.'))
		if (int(p) < 0 || int(p) > 255)
			return false;

	return true;
}

const POW2 = [
	1, 2, 4, 8, 16, 32, 64, 128,
	256, 512, 1024, 2048, 4096, 8192, 16384, 32768,
	65536, 131072, 262144, 524288, 1048576, 2097152, 4194304, 8388608,
	16777216, 33554432, 67108864, 134217728, 268435456, 536870912, 1073741824, 2147483648,
	4294967296
];

const BUILTIN_BYPASS4 = [
	'0.0.0.0/8',
	'10.0.0.0/8',
	'100.64.0.0/10',
	'127.0.0.0/8',
	'169.254.0.0/16',
	'172.16.0.0/12',
	'192.0.0.0/24',
	'192.0.2.0/24',
	'192.31.196.0/24',
	'192.52.193.0/24',
	'192.88.99.0/24',
	'192.168.0.0/16',
	'192.175.48.0/24',
	'198.18.0.0/15',
	'198.51.100.0/24',
	'203.0.113.0/24',
	'224.0.0.0/4',
	'240.0.0.0/4'
];

function join_list(arr, sep) {
	let out = '';
	let first = true;

	for (let v in arr) {
		if (!first)
			out += sep;
		first = false;
		out += v;
	}

	return out;
}

function add_unique(arr, value) {
	for (let v in arr)
		if (v === value)
			return;

	push(arr, value);
}

function ip_to_num(addr) {
	let p = split(addr, '.');
	return int(p[0]) * 16777216 + int(p[1]) * 65536 + int(p[2]) * 256 + int(p[3]);
}

function num_to_ip(num) {
	let a = int(num / 16777216);
	num -= a * 16777216;
	let b = int(num / 65536);
	num -= b * 65536;
	let c = int(num / 256);
	let d = num - c * 256;

	return sprintf('%d.%d.%d.%d', a, b, c, d);
}

function cidr_parts(cidr) {
	let parts = split(cidr, '/');

	if (length(parts) !== 2 || !validate_ipv4(parts[0]))
		return null;

	let prefix = int(parts[1]);

	if (prefix < 0 || prefix > 32)
		return null;

	return {
		addr: ip_to_num(parts[0]),
		prefix: prefix
	};
}

function cidr_contains(parent, child) {
	parent = cidr_parts(parent);
	child = cidr_parts(child);

	if (parent == null || child == null || parent.prefix > child.prefix)
		return false;

	let block = POW2[32 - parent.prefix];
	return int(child.addr / block) * block === parent.addr;
}

function add_unique_cidr(arr, cidr) {
	for (let existing in arr)
		if (cidr_contains(existing, cidr))
			return;

	add_unique(arr, cidr);
}

function netmask_prefix(mask) {
	let bits = {
		'255': 8,
		'254': 7,
		'252': 6,
		'248': 5,
		'240': 4,
		'224': 3,
		'192': 2,
		'128': 1,
		'0': 0
	};

	if (!validate_ipv4(mask))
		return null;

	let prefix = 0;
	let zero_seen = false;

	for (let octet in split(mask, '.')) {
		let b = bits[octet];

		if (b == null)
			return null;

		if (zero_seen && b !== 0)
			return null;

		prefix += b;

		if (b !== 8)
			zero_seen = true;
	}

	return prefix;
}

function cidr_network(addr, prefix) {
	prefix = int(prefix);

	if (!validate_ipv4(addr) || prefix < 0 || prefix > 32)
		return null;

	let block = POW2[32 - prefix];
	let network = int(ip_to_num(addr) / block) * block;

	return sprintf('%s/%d', num_to_ip(network), prefix);
}

function normalize_cidr4(value) {
	if (is_empty(value))
		return null;

	value = trim(value);

	if (validate_ipv4(value))
		return value + '/32';

	let parts = split(value, '/');

	if (length(parts) !== 2)
		return null;

	return cidr_network(parts[0], int(parts[1]));
}

function collect_network_bypass4(out) {
	uci.foreach(network_name, 'interface', (iface) => {
		let addrs = parse_list(iface.ipaddr);
		let masks = parse_list(iface.netmask);
		let mask = length(masks) ? masks[0] : null;
		let prefix = mask ? netmask_prefix(mask) : null;

		for (let addr in addrs) {
			let cidr = null;
			let parts = split(addr, '/');

			if (length(parts) === 2)
				cidr = cidr_network(parts[0], int(parts[1]));
			else if (prefix != null)
				cidr = cidr_network(addr, prefix);

			if (cidr != null)
				add_unique_cidr(out, cidr);
		}
	});
}

function add_bypass_cidr_list(out, option) {
	for (let cidr in parse_list(uci.get(cfg_name, 'main', option))) {
		let normalized = normalize_cidr4(cidr);

		if (normalized == null)
			die(sprintf('Invalid bypass IPv4/CIDR "%s" in option "%s".\n', cidr, option));

		add_unique_cidr(out, normalized);
	}
}

function dscp_hex(v) {
	let d = int(v);
	if (d < 0 || d > 63)
		die(sprintf('Invalid DSCP value %s. Expected 0..63.\n', v));
	return sprintf('0x%02x', d);
}

const main_enabled = to_bool(uci.get(cfg_name, 'main', 'enabled'));
if (!main_enabled)
	die('homeproxy-dscp is disabled in /etc/config/homeproxy_dscp.\n');

const base_tcp_port = int(uci.get(cfg_name, 'main', 'tcp_port') || 15331);
const base_udp_port = int(uci.get(cfg_name, 'main', 'udp_port') || 15332);
const fwmark = uci.get(cfg_name, 'main', 'fwmark') || '0x1d5c9';
const route_table = int(uci.get(cfg_name, 'main', 'table') || 10532);
const rule_priority = int(uci.get(cfg_name, 'main', 'rule_priority') || 10532);
const log_level = uci.get(cfg_name, 'main', 'log_level') || 'warn';
const sniff = to_bool(uci.get(cfg_name, 'main', 'sniff') || '1');
const bypass_local = to_bool(uci.get(cfg_name, 'main', 'bypass_local') || '1');
const nft_priority_tcp = int(uci.get(cfg_name, 'main', 'nft_priority_tcp') || -101);
const nft_priority_udp = int(uci.get(cfg_name, 'main', 'nft_priority_udp') || -151);
const udp_timeout = uci.get(hp_name, 'infra', 'udp_timeout') || '300';
const self_mark = int(uci.get(hp_name, 'infra', 'self_mark') || 100);

let bypass4 = [];

if (bypass_local) {
	for (let cidr in BUILTIN_BYPASS4)
		add_unique_cidr(bypass4, cidr);

	collect_network_bypass4(bypass4);
}

add_bypass_cidr_list(bypass4, 'bypass_ipv4');
add_bypass_cidr_list(bypass4, 'bypass_wan_ipv4');

let config = {
	log: {
		disabled: false,
		level: log_level,
		output: RUN_DIR + '/sing-box.log',
		timestamp: true
	},
	dns: {
		servers: [
			{
				tag: 'system-dns',
				type: 'local',
				detour: 'direct-out'
			}
		],
		final: 'system-dns'
	},
	inbounds: [],
	outbounds: [
		{
			type: 'direct',
			tag: 'direct-out',
			routing_mark: self_mark
		},
		{
			type: 'block',
			tag: 'block-out'
		}
	],
	endpoints: [],
	route: {
		rules: [],
		final: 'direct-out',
		auto_detect_interface: true
	}
};

let generated_tags = {};
let stack = {};

function add_outbound(obj) {
	if (obj == null || is_empty(obj.tag))
		return;
	if (generated_tags[obj.tag])
		return;
	generated_tags[obj.tag] = true;
	push(config.outbounds, obj);
}

function add_endpoint(obj) {
	if (obj == null || is_empty(obj.tag))
		return;
	if (generated_tags[obj.tag])
		return;
	generated_tags[obj.tag] = true;
	push(config.endpoints, obj);
}

function generate_endpoint(node, tag) {
	return {
		type: node.type,
		tag: tag,
		address: node.wireguard_local_address,
		mtu: to_int(node.wireguard_mtu),
		private_key: node.wireguard_private_key,
		peers: (node.type === 'wireguard') ? [
			{
				address: node.address,
				port: to_int(node.port),
				allowed_ips: [ '0.0.0.0/0', '::/0' ],
				persistent_keepalive_interval: to_int(node.wireguard_persistent_keepalive_interval),
				public_key: node.wireguard_peer_public_key,
				pre_shared_key: node.wireguard_pre_shared_key,
				reserved: parse_ports(node.wireguard_reserved)
			}
		] : null,
		system: (node.type === 'wireguard') ? false : null,
		tcp_fast_open: to_bool(node.tcp_fast_open),
		tcp_multi_path: to_bool(node.tcp_multi_path),
		udp_fragment: to_bool(node.udp_fragment)
	};
}

function generate_outbound(node, tag) {
	return {
		type: node.type,
		tag: tag,
		routing_mark: self_mark,

		server: node.address,
		server_port: to_int(node.port),
		server_ports: node.hysteria_hopping_port,

		username: (node.type !== 'ssh') ? node.username : null,
		user: (node.type === 'ssh') ? node.username : null,
		password: node.password,

		override_address: node.override_address,
		override_port: to_int(node.override_port),
		proxy_protocol: to_int(node.proxy_protocol),

		idle_session_check_interval: to_time(node.anytls_idle_session_check_interval),
		idle_session_timeout: to_time(node.anytls_idle_session_timeout),
		min_idle_session: to_int(node.anytls_min_idle_session),

		hop_interval: to_time(node.hysteria_hop_interval),
		up_mbps: to_int(node.hysteria_up_mbps),
		down_mbps: to_int(node.hysteria_down_mbps),
		obfs: node.hysteria_obfs_type ? {
			type: node.hysteria_obfs_type,
			password: node.hysteria_obfs_password
		} : node.hysteria_obfs_password,
		auth: (node.hysteria_auth_type === 'base64') ? node.hysteria_auth_payload : null,
		auth_str: (node.hysteria_auth_type === 'string') ? node.hysteria_auth_payload : null,
		recv_window_conn: to_int(node.hysteria_recv_window_conn),
		recv_window: to_int(node.hysteria_revc_window),
		disable_mtu_discovery: to_bool(node.hysteria_disable_mtu_discovery),

		method: node.shadowsocks_encrypt_method,
		plugin: node.shadowsocks_plugin,
		plugin_opts: node.shadowsocks_plugin_opts,

		version: (node.type === 'shadowtls') ? to_int(node.shadowtls_version) : ((node.type === 'socks') ? node.socks_version : null),

		client_version: node.ssh_client_version,
		host_key: node.ssh_host_key,
		host_key_algorithms: node.ssh_host_key_algo,
		private_key: node.ssh_priv_key,
		private_key_passphrase: node.ssh_priv_key_pp,

		uuid: node.uuid,
		congestion_control: node.tuic_congestion_control,
		udp_relay_mode: node.tuic_udp_relay_mode,
		udp_over_stream: to_bool(node.tuic_udp_over_stream),
		zero_rtt_handshake: to_bool(node.tuic_enable_zero_rtt),
		heartbeat: to_time(node.tuic_heartbeat),

		flow: node.vless_flow,
		alter_id: to_int(node.vmess_alterid),
		security: node.vmess_encrypt,
		global_padding: to_bool(node.vmess_global_padding),
		authenticated_length: to_bool(node.vmess_authenticated_length),
		packet_encoding: node.packet_encoding,

		multiplex: (node.multiplex === '1') ? {
			enabled: true,
			protocol: node.multiplex_protocol,
			max_connections: to_int(node.multiplex_max_connections),
			min_streams: to_int(node.multiplex_min_streams),
			max_streams: to_int(node.multiplex_max_streams),
			padding: to_bool(node.multiplex_padding),
			brutal: (node.multiplex_brutal === '1') ? {
				enabled: true,
				up_mbps: to_int(node.multiplex_brutal_up),
				down_mbps: to_int(node.multiplex_brutal_down)
			} : null
		} : null,

		tls: (node.tls === '1') ? {
			enabled: true,
			server_name: node.tls_sni,
			insecure: to_bool(node.tls_insecure),
			alpn: parse_list(node.tls_alpn),
			min_version: node.tls_min_version,
			max_version: node.tls_max_version,
			cipher_suites: parse_list(node.tls_cipher_suites),
			certificate_path: node.tls_cert_path,
			ech: (node.tls_ech === '1') ? {
				enabled: true,
				config: node.tls_ech_config,
				config_path: node.tls_ech_config_path
			} : null,
			utls: !is_empty(node.tls_utls) ? {
				enabled: true,
				fingerprint: node.tls_utls
			} : null,
			reality: (node.tls_reality === '1') ? {
				enabled: true,
				public_key: node.tls_reality_public_key,
				short_id: node.tls_reality_short_id
			} : null
		} : null,

		transport: !is_empty(node.transport) ? {
			type: node.transport,
			host: node.http_host || node.httpupgrade_host,
			path: node.http_path || node.ws_path,
			headers: node.ws_host ? { Host: node.ws_host } : null,
			method: node.http_method,
			max_early_data: to_int(node.websocket_early_data),
			early_data_header_name: node.websocket_early_data_header,
			service_name: node.grpc_servicename,
			idle_timeout: to_time(node.http_idle_timeout),
			ping_timeout: to_time(node.http_ping_timeout),
			permit_without_stream: to_bool(node.grpc_permit_without_stream)
		} : null,

		udp_over_tcp: (node.udp_over_tcp === '1') ? {
			enabled: true,
			version: to_int(node.udp_over_tcp_version)
		} : null,
		tcp_fast_open: to_bool(node.tcp_fast_open),
		tcp_multi_path: to_bool(node.tcp_multi_path),
		udp_fragment: to_bool(node.udp_fragment)
	};
}

function build_node(name, tag) {
	let node = uci.get_all(hp_name, name);
	if (node == null || node['.type'] !== 'node')
		die(sprintf('HomeProxy node "%s" not found.\n', name));

	if (node.type === 'wireguard')
		add_endpoint(clean(generate_endpoint(node, tag)));
	else
		add_outbound(clean(generate_outbound(node, tag)));

	return tag;
}

function build_routing_node(name, tag, prefix) {
	if (stack['routing:' + name])
		die(sprintf('Recursive HomeProxy routing_node detour detected at "%s".\n', name));
	stack['routing:' + name] = true;

	let rn = uci.get_all(hp_name, name);
	if (rn == null || rn['.type'] !== 'routing_node')
		die(sprintf('HomeProxy routing_node "%s" not found.\n', name));
	if (rn.enabled !== '1')
		die(sprintf('HomeProxy routing_node "%s" is disabled.\n', name));

	if (rn.node === 'urltest') {
		let children = [];
		for (let n in parse_list(rn.urltest_nodes)) {
			let child_tag = sprintf('%s-node-%s-out', prefix, n);
			build_node(n, child_tag);
			push(children, child_tag);
		}
		if (!length(children))
			die(sprintf('HomeProxy routing_node "%s" has no urltest nodes.\n', name));

		add_outbound(clean({
			type: 'urltest',
			tag: tag,
			outbounds: children,
			url: rn.urltest_url,
			interval: to_time(rn.urltest_interval),
			tolerance: to_int(rn.urltest_tolerance),
			idle_timeout: to_time(rn.urltest_idle_timeout),
			interrupt_exist_connections: to_bool(rn.urltest_interrupt_exist_connections)
		}));
	} else {
		build_node(rn.node, tag);
		let out = config.outbounds[length(config.outbounds) - 1];
		if (out && out.tag === tag) {
			out.bind_interface = rn.bind_interface;
			if (!is_empty(rn.outbound))
				out.detour = resolve_target(rn.outbound, sprintf('%s-detour', prefix));
		}
	}

	delete stack['routing:' + name];
	return tag;
}

function resolve_target(target, prefix) {
	if (target === 'direct-out' || target === 'block-out')
		return target;

	if (match(target, /^node:/))
		return build_node(substr(target, 5), prefix + '-out');

	if (match(target, /^routing:/))
		return build_routing_node(substr(target, 8), prefix + '-out', prefix);

	let any = uci.get_all(hp_name, target);
	if (any != null && any['.type'] === 'node')
		return build_node(target, prefix + '-out');
	if (any != null && any['.type'] === 'routing_node')
		return build_routing_node(target, prefix + '-out', prefix);

	die(sprintf('Unsupported target "%s". Use node:<name>, routing:<name>, direct-out, or block-out.\n', target));
}

let nft_tcp = [];
let nft_udp = [];
let active = 0;
let has_udp = false;
let daddr_filter = length(bypass4) ? 'ip daddr != @bypass4 ' : '';

uci.foreach(cfg_name, 'rule', (rule) => {
	if (rule.enabled !== '1')
		return;

	let src_ip = rule.src_ip;
	if (!validate_ipv4(src_ip))
		die(sprintf('Rule "%s" has invalid Windows source IPv4: %s\n', rule['.name'], src_ip));

	let proto = rule.proto || 'both';
	if (!(proto in [ 'both', 'tcp', 'udp' ]))
		die(sprintf('Rule "%s" has invalid proto: %s\n', rule['.name'], proto));

	if (is_empty(rule.target))
		die(sprintf('Rule "%s" has no target.\n', rule['.name']));

	let index = active++;
	let prefix = sprintf('rule-%d', index);
	let outbound = resolve_target(rule.target, prefix);
	let inbound_tags = [];
	let dscp = dscp_hex(rule.dscp || 46);

	if (proto === 'both' || proto === 'tcp') {
		let port = base_tcp_port + index;
		let tag = prefix + '-tcp-in';
		push(config.inbounds, clean({
			type: 'redirect',
			tag: tag,
			listen: '::',
			listen_port: port,
			sniff: sniff,
			sniff_override_destination: sniff
		}));
		push(inbound_tags, tag);
		push(nft_tcp, sprintf('\t\tip saddr %s %sip dscp %s meta l4proto tcp counter redirect to :%d\n', src_ip, daddr_filter, dscp, port));
	}

	if (proto === 'both' || proto === 'udp') {
		let port = base_udp_port + index;
		let tag = prefix + '-udp-in';
		push(config.inbounds, clean({
			type: 'tproxy',
			tag: tag,
			listen: '::',
			listen_port: port,
			network: 'udp',
			udp_timeout: to_time(udp_timeout),
			sniff: sniff,
			sniff_override_destination: sniff
		}));
		push(inbound_tags, tag);
		has_udp = true;
		push(nft_udp, sprintf('\t\tip saddr %s %sip dscp %s meta l4proto udp counter meta mark set %s tproxy ip to 127.0.0.1:%d accept\n', src_ip, daddr_filter, dscp, fwmark, port));
	}

	push(config.route.rules, {
		inbound: inbound_tags,
		action: 'route',
		outbound: outbound
	});
});

if (active === 0)
	die('homeproxy-dscp has no enabled DSCP rules.\n');

if (!length(config.endpoints))
	config.endpoints = null;

let nft = sprintf('table inet %s {\n', TABLE_NAME);
if (length(bypass4)) {
	nft += '\tset bypass4 {\n';
	nft += '\t\ttype ipv4_addr\n';
	nft += '\t\tflags interval\n';
	nft += '\t\tauto-merge\n';
	nft += sprintf('\t\telements = { %s }\n', join_list(bypass4, ', '));
	nft += '\t}\n\n';
}
nft += sprintf('\tchain tcp_redirect {\n\t\ttype nat hook prerouting priority %d; policy accept;\n', nft_priority_tcp);
for (let line in nft_tcp)
	nft += line;
nft += '\t}\n\n';
nft += sprintf('\tchain udp_tproxy {\n\t\ttype filter hook prerouting priority %d; policy accept;\n', nft_priority_udp);
for (let line in nft_udp)
	nft += line;
nft += '\t}\n';
nft += '}\n';

system('mkdir -p ' + RUN_DIR);
writefile(CONFIG_FILE, sprintf('%.J\n', clean(config)));
writefile(NFT_FILE, nft);
writefile(STATE_FILE, sprintf("CONFIG_FILE='%s'\nNFT_FILE='%s'\nFWMARK='%s'\nTABLE='%d'\nRULE_PRIORITY='%d'\nHAS_UDP='%d'\n",
	CONFIG_FILE, NFT_FILE, fwmark, route_table, rule_priority, has_udp ? 1 : 0));
