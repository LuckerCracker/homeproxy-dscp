'use strict';
'require dom';
'require form';
'require fs';
'require network';
'require poll';
'require rpc';
'require uci';
'require ui';
'require view';

var LOG_FILE = '/var/run/homeproxy-dscp/sing-box.log';

return view.extend({
	callRcList: rpc.declare({
		object: 'rc',
		method: 'list',
		expect: { '': {} }
	}),

	callRcInit: rpc.declare({
		object: 'rc',
		method: 'init',
		params: [ 'name', 'action' ]
	}),

	callServiceList: rpc.declare({
		object: 'service',
		method: 'list',
		params: [ 'name' ],
		expect: { '': {} }
	}),

	callAddonStatus: rpc.declare({
		object: 'homeproxy-dscp',
		method: 'status',
		expect: { '': {} }
	}),

	callAddonAction: rpc.declare({
		object: 'homeproxy-dscp',
		method: 'action',
		params: [ 'name' ],
		expect: { '': {} }
	}),

	callClearLog: rpc.declare({
		object: 'homeproxy-dscp',
		method: 'clear_log',
		expect: { '': {} }
	}),

	callSetLogLevel: rpc.declare({
		object: 'homeproxy-dscp',
		method: 'set_log_level',
		params: [ 'level' ],
		expect: { '': {} }
	}),

	load: function() {
		return Promise.all([
			uci.load('homeproxy'),
			uci.load('homeproxy_dscp'),
			L.resolveDefault(network.getHostHints(), null),
			L.resolveDefault(this.callRcList(), {}),
			L.resolveDefault(this.callAddonStatus(), {}),
			L.resolveDefault(this.callServiceList('homeproxy-dscp'), {}),
			this.readLog()
		]);
	},

	readLog: function() {
		return L.resolveDefault(fs.read(LOG_FILE), '');
	},

	readNft: function() {
		return L.resolveDefault(fs.exec_direct('/usr/sbin/nft', [ 'list', 'table', 'inet', 'homeproxy_dscp' ]), '');
	},

	clearLog: function(ev) {
		return this.callClearLog().then(function(res) {
			if (!res || res.ok === false)
				throw new Error(res && res.error ? res.error : 'clear_log failed');

			var log = document.getElementById('homeproxy-dscp-log');

			if (log)
				log.value = '';

			ui.addNotification(null, E('p', 'Журнал очищен.'), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', 'Не удалось очистить журнал: %s'.format(e.message)));
		});
	},

	saveLogLevel: function(ev) {
		var select = document.getElementById('homeproxy-dscp-log-level'),
		    value = select ? select.value : 'warn';

		return this.callSetLogLevel(value).then(L.bind(function(res) {
			if (!res || res.ok === false)
				throw new Error(res && res.error ? res.error : 'set_log_level failed');

			ui.addNotification(null, E('p', 'Уровень журнала сохранен. Сервис перезапущен.'), 'info');
			return this.reloadStatus();
		}, this)).catch(function(e) {
			ui.addNotification(null, E('p', 'Не удалось сохранить уровень журнала: %s'.format(e.message || e)));
		});
	},

	reloadStatus: function() {
		return Promise.all([
			this.readLog(),
			this.readNft(),
			L.resolveDefault(this.callAddonStatus(), {}),
			L.resolveDefault(this.callServiceList('homeproxy-dscp'), {})
		]).then(L.bind(function(data) {
			var log = document.getElementById('homeproxy-dscp-log'),
			    nft = document.getElementById('homeproxy-dscp-nft'),
			    state = document.getElementById('homeproxy-dscp-state');

			if (log)
				log.value = data[0] || '';

			if (nft)
				nft.value = data[1] || 'Таблица nftables пока не создана.';

			if (state)
				dom.content(state, this.renderState(data[2], data[3]));
		}, this));
	},

	handleServiceAction: function(action, ev) {
		var btn = ev ? ev.currentTarget : null;

		if (btn)
			btn.classList.add('spinning');

		return this.callAddonAction(action).then(L.bind(function(res) {
			if (!res || res.ok === false)
				throw new Error(res && res.error ? res.error : 'action failed');

			return this.reloadStatus();
		}, this)).catch(function(e) {
			ui.addNotification(null, E('p', [
				'Не удалось выполнить действие сервиса: %s'.format(e.message || e),
				E('br'),
				'Проверьте через SSH: /etc/init.d/homeproxy-dscp %s'.format(action)
			]));
		}).finally(function() {
			if (btn)
				btn.classList.remove('spinning');
		});
	},

	getHostChoices: function(hints) {
		var choices = [];

		if (!hints || !hints.hosts)
			return choices;

		Object.keys(hints.hosts).forEach(function(mac) {
			var host = hints.hosts[mac],
			    name = host.name || mac,
			    ips = L.toArray(host.ipaddrs || host.ipv4);

			ips.forEach(function(ip) {
				if (/^\d+\.\d+\.\d+\.\d+$/.test(ip))
					choices.push([ ip, '%s (%s)'.format(ip, name) ]);
			});
		});

		choices.sort(function(a, b) {
			return L.naturalCompare(a[0], b[0]);
		});

		return choices;
	},

	renderSettings: function(hints) {
		var m, s, o, hostChoices;

		m = new form.Map('homeproxy_dscp', _('HomeProxy DSCP'),
			'Маршрутизация Windows-трафика с DSCP-меткой через отдельный sing-box instance без изменения файлов HomeProxy.');

		s = m.section(form.NamedSection, 'main', 'settings', 'Global Settings');
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', 'Включить');
		o.default = '0';
		o.rmempty = false;

		o = s.option(form.Value, 'tcp_port', 'Base TCP redirect port');
		o.datatype = 'port';
		o.default = '15331';
		o.rmempty = false;

		o = s.option(form.Value, 'udp_port', 'Base UDP TProxy port');
		o.datatype = 'port';
		o.default = '15332';
		o.rmempty = false;

		o = s.option(form.Value, 'fwmark', 'UDP fwmark');
		o.default = '0x5332';
		o.rmempty = false;

		o = s.option(form.Value, 'table', 'UDP routing table');
		o.datatype = 'uinteger';
		o.default = '5332';
		o.rmempty = false;

		o = s.option(form.Value, 'rule_priority', 'UDP ip rule priority');
		o.datatype = 'uinteger';
		o.default = '15332';
		o.rmempty = false;

		o = s.option(form.Flag, 'sniff', 'Sniff traffic');
		o.default = '1';
		o.rmempty = false;

		s = m.section(form.GridSection, 'rule', 'DSCP Routing Rules');
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;

		o = s.option(form.Flag, 'enabled', 'Включить');
		o.default = '1';
		o.rmempty = false;

		o = s.option(form.Value, 'label', 'Название');
		o.placeholder = 'Edge через EU_NODE';

		o = s.option(form.Value, 'src_ip', 'Windows source IPv4');
		o.datatype = 'ip4addr';
		o.placeholder = '192.168.1.123';
		o.rmempty = false;

		hostChoices = this.getHostChoices(hints);
		hostChoices.forEach(function(choice) {
			o.value(choice[0], choice[1]);
		});

		o = s.option(form.Value, 'dscp', 'DSCP value');
		o.datatype = 'range(0,63)';
		o.default = '46';
		o.rmempty = false;

		o = s.option(form.ListValue, 'proto', 'Protocols');
		o.value('both', 'TCP + UDP');
		o.value('tcp', 'Только TCP');
		o.value('udp', 'Только UDP');
		o.default = 'both';
		o.rmempty = false;

		o = s.option(form.ListValue, 'target', 'Target HomeProxy routing node');
		o.rmempty = false;
		o.value('', 'Выберите');
		o.value('direct-out', 'Direct');
		o.value('block-out', 'Block');

		uci.sections('homeproxy', 'routing_node').forEach(function(section) {
			var title = section.label || section.alias || section['.name'];

			if (section.enabled === '1')
				o.value('routing:' + section['.name'], title);
		});

		return m.render();
	},

	isRunning: function(serviceData) {
		var svc = serviceData && serviceData['homeproxy-dscp'];

		if (!svc || !svc.instances)
			return false;

		for (var name in svc.instances)
			if (svc.instances[name].running)
				return true;

		return false;
	},

	renderState: function(status, serviceData) {
		var autostart = status && status.autostart,
		    running = status && status.running;

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', 'Service Status'),
			E('table', { 'class': 'table' }, [
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '33%' }, 'Автозапуск'),
					E('td', { 'class': 'td left' }, autostart ? 'Включен' : 'Выключен')
				]),
				E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left' }, 'Состояние'),
					E('td', { 'class': 'td left' }, running ? E('strong', { 'style': 'color:green' }, 'RUNNING') : E('strong', { 'style': 'color:red' }, 'STOPPED'))
				])
			])
		]);
	},

	renderStatus: function(log, autostart, serviceData) {
		var running = this.isRunning(serviceData),
		    logLevel = uci.get('homeproxy_dscp', 'main', 'log_level') || 'warn';

		poll.add(L.bind(this.reloadStatus, this), 5);

		return E('div', {}, [
			E('div', { 'id': 'homeproxy-dscp-state' }, this.renderState(autostart, serviceData)),
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:1.25em' }, [
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleServiceAction', 'start')
				}, 'Start'),
				' ',
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleServiceAction', 'restart')
				}, 'Restart'),
				' ',
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleServiceAction', 'stop')
				}, 'Stop'),
				' ',
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleServiceAction', 'enable')
				}, 'Enable autostart'),
				' ',
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleServiceAction', 'disable')
				}, 'Disable autostart'),
				' ',
				E('span', { 'style': 'margin-left:1em' }, running ? 'Сервис запущен.' : 'Сервис остановлен.')
			]),
			E('h3', { 'style': 'margin-top:0.75em' }, [
				'HomeProxy DSCP log ',
				E('button', {
					'class': 'btn cbi-button-action',
					'click': ui.createHandlerFn(this, 'clearLog')
				}, 'Clean log')
			]),
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:0.75em' }, [
				E('label', { 'style': 'margin-right:0.75em' }, 'Уровень журнала'),
				E('select', { 'id': 'homeproxy-dscp-log-level', 'class': 'cbi-input-select' }, [
					E('option', { 'value': 'trace', 'selected': logLevel === 'trace' ? '' : null }, 'Trace'),
					E('option', { 'value': 'debug', 'selected': logLevel === 'debug' ? '' : null }, 'Debug'),
					E('option', { 'value': 'info', 'selected': logLevel === 'info' ? '' : null }, 'Info'),
					E('option', { 'value': 'warn', 'selected': logLevel === 'warn' ? '' : null }, 'Предупреждение'),
					E('option', { 'value': 'error', 'selected': logLevel === 'error' ? '' : null }, 'Ошибка'),
					E('option', { 'value': 'fatal', 'selected': logLevel === 'fatal' ? '' : null }, 'Fatal'),
					E('option', { 'value': 'panic', 'selected': logLevel === 'panic' ? '' : null }, 'Panic')
				]),
				' ',
				E('button', {
					'class': 'btn cbi-button-save',
					'click': ui.createHandlerFn(this, 'saveLogLevel')
				}, 'Сохранить уровень')
			]),
			E('textarea', {
				'id': 'homeproxy-dscp-log',
				'style': 'width:100%; min-height:360px; font-family:monospace; font-size:12px',
				'readonly': 'readonly',
				'wrap': 'off'
			}, [ log || '' ]),
			E('h3', 'nftables counters'),
			E('textarea', {
				'id': 'homeproxy-dscp-nft',
				'style': 'width:100%; min-height:180px; font-family:monospace; font-size:12px',
				'readonly': 'readonly',
				'wrap': 'off'
			}, [ 'Загрузка...' ])
		]);
	},

	render: function(data) {
		return Promise.all([
			this.renderSettings(data[2]),
			this.readNft()
		]).then(L.bind(function(rendered) {
			var viewNode = E('div', {}, [
				E('div', {}, [
					E('div', { 'data-tab': 'settings', 'data-tab-title': 'Global Settings' }, [ rendered[0] ]),
					E('div', { 'data-tab': 'status', 'data-tab-title': 'Service Status' }, [ this.renderStatus(data[6], data[4], data[5]) ])
				])
			]);

			ui.tabs.initTabGroup(viewNode.lastElementChild.childNodes);

			window.setTimeout(function() {
				var nft = document.getElementById('homeproxy-dscp-nft');

				if (nft)
					nft.value = rendered[1] || 'Таблица nftables пока не создана.';
			}, 0);

			return viewNode;
		}, this));
	}
});
