(function () {
  "use strict";
  var REFRESH_MS = 60000;
  var GRAY = "#8c959f";
  var data = null, markers = [], first = true;

  function $(id) { return document.getElementById(id); }
  // Весь текст из Zabbix вставляется только через textContent / createTextNode.
  function el(tag, props, children) {
    var e = document.createElement(tag);
    Object.keys(props || {}).forEach(function (k) {
      if (k === "text") e.textContent = props[k]; else e.setAttribute(k, props[k]);
    });
    (children || []).forEach(function (c) { e.appendChild(typeof c === "string" ? document.createTextNode(c) : c); });
    return e;
  }

  var map = L.map("map", { center: [55.75, 37.62], zoom: 9, minZoom: 6, maxZoom: 17 });
  var layer = L.layerGroup().addTo(map);
  var tilesOn = false;
  map.attributionControl.setPrefix("");
  map.attributionControl.addAttribution("&copy; OpenStreetMap contributors");

  function addTiles() {
    if (tilesOn || !window.protomapsL) return;
    try {
      protomapsL.leafletLayer({
        url: location.origin + "/tiles.pmtiles", flavor: "light", lang: "ru",
        maxDataZoom: 13, attribution: ""
      }).addTo(map);
      tilesOn = true;
    } catch (e) { console.warn("Подложка недоступна:", e); }
  }

  function color(h) {
    if (!h.enabled) return GRAY;
    if (h.max_severity >= 0) return "#" + data.severity_colors[h.max_severity];
    if (h.availability === "unavailable") return GRAY;
    return "#" + data.ok_color;
  }

  function fmtTime(ts) {
    var d = new Date(ts * 1000), p = function (n) { return (n < 10 ? "0" : "") + n; };
    return p(d.getDate()) + "." + p(d.getMonth() + 1) + "." + d.getFullYear() + " " + p(d.getHours()) + ":" + p(d.getMinutes());
  }
  function fmtDur(s) {
    s = Math.max(0, s); var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
    return d ? d + " д " + h + " ч" : h ? h + " ч " + m + " мин" : m + " мин";
  }
  function hostUrl(h) {
    var base = data.frontend_url || (location.protocol + "//" + location.hostname);
    return base + "/zabbix.php?action=problem.view&filter_set=1&hostids%5B%5D=" + encodeURIComponent(h.hostid);
  }

  function popup(h) {
    var box = el("div", { "class": "popup" });
    box.appendChild(el("h3", { text: h.name }));
    box.appendChild(el("div", { text: h.state }));
    box.appendChild(el("div", { "class": "meta", text: [h.ip, h.groups.join(", ")].filter(Boolean).join(" | ") }));
    if (h.location) box.appendChild(el("div", { "class": "meta", text: h.location }));
    var act = h.problems.filter(function (p) { return !p.suppressed; });
    if (act.length) {
      var ul = el("ul");
      var now = data.generated_at;
      act.slice(0, 20).forEach(function (p) {
        var s = el("span", { text: data.severity_names[p.severity] });
        s.style.color = "#" + data.severity_colors[p.severity];
        s.style.fontWeight = "600";
        ul.appendChild(el("li", {}, [s, ": " + p.name + " (" + fmtTime(p.clock) + ", " + fmtDur(now - p.clock) + ")"]));
      });
      box.appendChild(ul);
      if (act.length > 20) box.appendChild(el("div", { "class": "meta", text: "и ещё " + (act.length - 20) }));
    }
    var a = el("a", { href: hostUrl(h), target: "_blank", rel: "noopener", text: "Открыть в Zabbix" });
    box.appendChild(a);
    return box;
  }

  function render() {
    layer.clearLayers(); markers = [];
    var g = $("group").value, pts = [];
    var nl = $("nocoords"); nl.textContent = "";
    var nocoords = 0;
    data.hosts.forEach(function (h) {
      if (g && h.groups.indexOf(g) < 0) return;
      if (h.lat === null) {
        nocoords++;
        var li = el("li", {}, [el("span", { "class": "dot" }), h.name]);
        li.firstChild.style.background = color(h);
        if (h.coords_note) li.title = h.coords_note;
        nl.appendChild(li);
        return;
      }
      var m = L.circleMarker([h.lat, h.lon], {
        radius: h.max_severity >= 3 ? 10 : 8, color: "#222", weight: 1.5,
        fillColor: color(h), fillOpacity: 0.95
      });
      m.bindPopup(function () { return popup(h); }, { maxWidth: 360 });
      m.bindTooltip(h.name);
      m.addTo(layer); pts.push([h.lat, h.lon]);
    });
    $("nocoords-count").textContent = "(" + nocoords + ")";
    if (first && pts.length) { first = false; map.fitBounds(pts, { padding: [40, 40], maxZoom: 12 }); }
    var s = data.summary;
    $("summary").textContent = "Устройств: " + s.total + ", с проблемами: " + s.with_problems;
    $("updated").textContent = "Обновлено " + fmtTime(data.generated_at);
    if (data.has_tiles) addTiles();
  }

  function fillGroups() {
    var sel = $("group"), cur = sel.value;
    sel.textContent = "";
    sel.appendChild(el("option", { value: "", text: "Все группы" }));
    data.groups.forEach(function (g) { sel.appendChild(el("option", { value: g, text: g })); });
    sel.value = data.groups.indexOf(cur) >= 0 ? cur : "";
  }

  function warn(text, isErr) {
    var w = $("warn"); w.hidden = !text; w.textContent = text || ""; w.className = isErr ? "err" : "";
  }

  function load() {
    fetch("/api/hosts", { cache: "no-store" }).then(function (r) {
      return r.json().then(function (j) { if (!r.ok) throw new Error(j.error || ("HTTP " + r.status)); return j; });
    }).then(function (j) {
      data = j; fillGroups(); render();
      var w = [];
      if (j.stale_error) w.push("Zabbix сейчас недоступен, показаны прежние данные: " + j.stale_error);
      if (!j.has_tiles) w.push("Файл подложки moscow.pmtiles не найден: карта без фона (см. docs/MAPS.md).");
      warn(w.join(" "), !!j.stale_error);
    }).catch(function (e) {
      warn("Не удалось получить данные: " + e.message, true);
    });
  }

  var lg = $("legend");
  [["97AAB3", "Не классифицировано"], ["7499FF", "Информация"], ["FFC859", "Предупреждение"],
   ["FFA059", "Средняя"], ["E97659", "Высокая"], ["E45959", "Чрезвычайная"],
   ["59DB8F", "В норме"], ["8c959f", "Недоступен / отключён"]].forEach(function (c) {
    var d = el("span", { "class": "dot" }); d.style.background = "#" + c[0];
    lg.appendChild(el("li", {}, [d, c[1]]));
  });
  $("group").addEventListener("change", function () { if (data) render(); });
  $("refresh").addEventListener("click", load);
  load();
  setInterval(load, REFRESH_MS);
})();
