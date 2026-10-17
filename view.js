'use strict';
'require view';

// Compose 管理（LuCI 内嵌，挂 Docker 分类下）
// iframe 固定定位填满主内容区，适配 iStoreOS/Argon 等主题（同 n1filemgr 方案）
return view.extend({
	render: function() {
		var attached = false;
		var busy = false;
		var hostEl = null;
		var ro = null;
		var CONTENT_IDS = ['maincontent', 'maincontent-inner'];
		var HEADER_SEL = '.main-header, #header, header, .header, .navbar';

		var iframe = document.createElement('iframe');
		iframe.setAttribute('frameborder', '0');
		iframe.setAttribute('scrolling', 'auto');
		iframe.src = '/luci-static/resources/dockercompose/index.html?v=0.6.3';
		iframe.style.cssText = 'display:block;margin:0;padding:0;border:0;width:100%;height:100%;';

		var wrap = document.createElement('div');
		wrap.style.cssText = 'margin:0;padding:0;';
		wrap.appendChild(iframe);

		var style = document.createElement('style');
		style.textContent = '.cbi-page-actions{display:none !important;}'
			+ '#maincontent, .main-right, .cbi-map, .cbi-map-node { padding:0 !important; margin:0 !important; }';
		document.head.appendChild(style);

		function host() {
			if (hostEl && document.body.contains(hostEl))
				return hostEl;
			hostEl = null;
			for (var i = 0; i < CONTENT_IDS.length; i++) {
				var el = document.getElementById(CONTENT_IDS[i]);
				if (el) { hostEl = el; break; }
			}
			if (!hostEl)
				hostEl = document.querySelector('.main-right') || document.querySelector('.main');
			return hostEl;
		}

		function headerBottom() {
			var h = document.querySelector(HEADER_SEL);
			return h ? h.getBoundingClientRect().bottom : 0;
		}

		function fixedOrigin() {
			var ox = 0, oy = 0, h = host();
			var el = h ? h.parentElement : null;
			while (el && el !== document.documentElement) {
				var cs = window.getComputedStyle(el);
				if (cs && (cs.transform !== 'none' || cs.filter !== 'none' || cs.perspective !== 'none')) {
					var r = el.getBoundingClientRect();
					ox = r.left; oy = r.top;
				}
				el = el.parentElement;
			}
			return { x: ox, y: oy };
		}

		function fitHeight() {
			if (window.innerWidth >= 760) return;
			try {
				var d = iframe.contentDocument;
				if (d && d.body) {
					var h = Math.max(d.body.scrollHeight, (d.documentElement ? d.documentElement.scrollHeight : 0));
					if (h > 200) iframe.style.height = h + 'px';
				}
			} catch (e) {}
		}
		iframe.addEventListener('load', function() {
			setTimeout(fitHeight, 120);
			setTimeout(fitHeight, 500);
			if (typeof window.ResizeObserver === 'function') {
				try {
					var bd = iframe.contentDocument && iframe.contentDocument.body;
					if (bd) new ResizeObserver(fitHeight).observe(bd);
				} catch (e) {}
			}
		});

		function apply() {
			if (!document.body.contains(wrap)) {
				if (attached) {
					window.removeEventListener('resize', apply);
					if (ro) { ro.disconnect(); ro = null; }
				}
				return;
			}
			attached = true;
			if (busy) return;
			busy = true;

			var vw = window.innerWidth, vh = window.innerHeight;
			if (vw < 760) {
				iframe.style.position = 'static';
				iframe.style.left = 'auto';
				iframe.style.top = 'auto';
				iframe.style.width = '100%';
				iframe.style.height = 'auto';
				setTimeout(fitHeight, 50);
				return;
			}
			var box = null, h = host();
			if (h && h.getBoundingClientRect) {
				var r = h.getBoundingClientRect();
				if (r && r.width >= 200 && r.top >= 0 && r.left < vw) {
					var o = fixedOrigin();
					box = { left: Math.round(r.left - o.x), top: Math.round(r.top - o.y), width: Math.round(r.width) };
				}
			}

			if (box) {
				iframe.style.position = 'fixed';
				iframe.style.left = box.left + 'px';
				iframe.style.top = box.top + 'px';
				iframe.style.width = box.width + 'px';
				iframe.style.height = Math.max(320, vh - box.top) + 'px';
			} else {
				iframe.style.position = 'static';
				iframe.style.left = 'auto';
				iframe.style.top = 'auto';
				iframe.style.width = '100%';
				iframe.style.height = Math.max(320, Math.round(vh - headerBottom())) + 'px';
			}

			if (!ro && typeof window.ResizeObserver === 'function') {
				ro = new ResizeObserver(function() { apply(); });
				if (host()) ro.observe(host());
				if (document.body) ro.observe(document.body);
			}
			busy = false;
		}

		window.addEventListener('resize', apply);
		setTimeout(apply, 0);
		setTimeout(apply, 150);
		setTimeout(apply, 600);
		setTimeout(apply, 1500);

		return wrap;
	}
});
