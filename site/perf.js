// 성능 그래프: 앱의 성능 탭 기록(assets/performance-history.json)을 그린다.
// 세 그래프가 같은 시각을 가리키고(십자선), 범례에 그 시각의 값을 보여 준다. 기간을 바꾸면 그래프·평균·표가 함께 바뀐다.
(() => {
  const host = document.getElementById("perf-charts");
  if (!host) return;
  const statsBox = document.getElementById("perf-stats");
  const table = document.getElementById("perf-table");
  const status = document.getElementById("perf-status");
  const t = (key, values) => (window.gnText ? window.gnText(key, values) : key);
  const SVG = "http://www.w3.org/2000/svg";

  // 절전 프로필의 영상 처리 CPU 한도 (앱의 PerformanceLimits.saver)
  const LIMITS = { saver: 5 };

  const CHARTS = [
    {
      id: "cpu", title: "perf.cpu", unit: () => "%", format: (v) => `${v.toFixed(1)}%`,
      series: [
        { key: "processCPU", name: "perf.s.process", slot: 1 },
        { key: "trackingCPU", name: "perf.s.tracking", slot: 2 },
        { key: "mainCPU", name: "perf.s.main", slot: 3 },
      ],
      limit: (row) => LIMITS[row.profile] ?? null,
    },
    {
      id: "rate", title: "perf.rate", unit: () => t("perf.rateUnit"), format: (v) => v.toFixed(1),
      series: [
        { key: "processedHz", name: "perf.s.processed", slot: 1 },
        { key: "detectHz", name: "perf.s.detect", slot: 2 },
        { key: "receivedFPS", name: "perf.s.frames", slot: 3 },
        { key: "targetHz", name: "perf.s.target", reference: true },
      ],
    },
    {
      id: "time", title: "perf.time", unit: () => "ms", format: (v) => `${v.toFixed(1)}ms`,
      series: [
        // 랜드마크는 처리한 프레임마다, 얼굴 검출은 몇 프레임에 한 번 — 하지 않은 시각은 비워 둔다
        { key: "landmarksMs", name: "perf.s.landmarks", slot: 1, when: (row) => row.processedHz > 0 },
        { key: "detectMs", name: "perf.s.detect", slot: 2, when: (row) => row.detectHz > 0 },
      ],
    },
  ];

  let rows = [];
  let range = 600;
  let selected = null;   // 고른 기록의 순번 (null = 마지막 기록)
  let hoverChart = null; // 툴팁을 띄울 그래프
  const views = new Map();

  const value = (series, row) => {
    if (!row || (series.when && !series.when(row))) return null;
    const v = row[series.key];
    return Number.isFinite(v) ? v : null;
  };
  const clock = (seconds) => {
    const s = Math.max(0, Math.round(seconds));
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
  };
  const visible = () => {
    if (!rows.length) return [];
    const end = rows[rows.length - 1].t;
    return rows.filter((row) => row.t >= end - range);
  };
  const niceMax = (max) => {
    const raw = Math.max(max, 1) * 1.15 / 4;
    const power = 10 ** Math.floor(Math.log10(raw));
    const step = [1, 2, 2.5, 5, 10].map((m) => m * power).find((s) => s >= raw);
    return { max: step * 4, step };
  };
  const el = (name, attrs = {}, parent) => {
    const node = document.createElementNS(SVG, name);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    if (parent) parent.appendChild(node);
    return node;
  };
  const color = (series) => (series.reference ? "var(--chart-reference)" : `var(--series-${series.slot})`);

  // MARK: - 그래프 틀 (언어를 바꾸면 다시 만든다)

  function build() {
    host.replaceChildren();
    views.clear();
    for (const chart of CHARTS) {
      const card = document.createElement("div");
      card.className = "chart";
      const head = document.createElement("div");
      head.className = "chart-head";
      const title = document.createElement("h4");
      title.textContent = t(chart.title);
      const unit = document.createElement("span");
      unit.className = "chart-unit";
      unit.textContent = chart.unit();
      head.append(title, unit);
      const legend = document.createElement("ul");
      legend.className = "chart-legend";
      const items = chart.series.map((series) => {
        const li = document.createElement("li");
        const key = document.createElement("span");
        key.className = `line-key${series.reference ? " dashed" : ""}`;
        key.style.setProperty("--key", color(series));
        const name = document.createElement("span");
        name.className = "legend-name";
        name.textContent = t(series.name);
        const val = document.createElement("strong");
        li.append(key, name, val);
        legend.appendChild(li);
        return val;
      });
      const plot = document.createElement("div");
      plot.className = "chart-plot";
      const svg = el("svg", { "aria-hidden": "true" });
      const tip = document.createElement("div");
      tip.className = "chart-tip";
      tip.hidden = true;
      plot.append(svg, tip);
      card.append(head, legend, plot);
      host.appendChild(card);
      views.set(chart.id, { chart, card, svg, tip, items, plot });

      plot.addEventListener("pointermove", (event) => {
        const view = views.get(chart.id);
        if (!view.scale) return;
        const box = svg.getBoundingClientRect();
        const time = view.scale.invert(event.clientX - box.left);
        hoverChart = chart.id;
        select(nearest(time));
      });
      plot.addEventListener("pointerleave", () => { hoverChart = null; select(null); });
    }
  }

  function nearest(time) {
    const list = visible();
    let best = 0;
    for (let i = 0; i < list.length; i++) if (Math.abs(list[i].t - time) < Math.abs(list[best].t - time)) best = i;
    return rows.indexOf(list[best]);
  }

  // MARK: - 그리기

  function draw() {
    const list = visible();
    if (!list.length) return;
    const x0 = list[0].t, x1 = list[list.length - 1].t;
    for (const view of views.values()) {
      const { chart, svg, plot } = view;
      const width = Math.max(260, plot.clientWidth);
      const height = 168;
      const m = { top: 20, right: 10, bottom: 24, left: 38 };
      const w = width - m.left - m.right, h = height - m.top - m.bottom;
      svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
      svg.setAttribute("width", width);
      svg.setAttribute("height", height);
      svg.replaceChildren();

      const peak = Math.max(...list.flatMap((row) => [
        ...chart.series.map((s) => value(s, row) ?? 0),
        chart.limit ? chart.limit(row) ?? 0 : 0,
      ]));
      const y = niceMax(peak);
      const sx = (time) => m.left + (x1 === x0 ? w : ((time - x0) / (x1 - x0)) * w);
      const sy = (v) => m.top + h - (v / y.max) * h;
      view.scale = { invert: (px) => x0 + ((px - m.left) / w) * (x1 - x0) };
      view.sx = sx; view.sy = sy; view.m = m; view.h = h;

      // 프로필 구간: 절전은 옅게 칠하고, 구간마다 이름을 단다
      const segments = [];
      for (const row of list) {
        const last = segments[segments.length - 1];
        if (last && last.profile === row.profile) last.end = row.t;
        else segments.push({ profile: row.profile, start: row.t, end: row.t });
      }
      for (const seg of segments) {
        const left = sx(seg.start), right = sx(seg.end);
        if (seg.profile === "saver") el("rect", { x: left, y: m.top, width: Math.max(0, right - left), height: h, class: "band" }, svg);
        if (right - left > 40) {
          const label = el("text", { x: left + 6, y: m.top - 7, class: "band-label" }, svg);
          label.textContent = t(`perf.profile.${seg.profile}`);
        }
      }

      // 격자와 축 (실선 가는 선)
      for (let v = 0; v <= y.max + 1e-9; v += y.step) {
        el("line", { x1: m.left, x2: m.left + w, y1: sy(v), y2: sy(v), class: v === 0 ? "axis" : "grid" }, svg);
        const tick = el("text", { x: m.left - 6, y: sy(v) + 4, class: "tick", "text-anchor": "end" }, svg);
        tick.textContent = Number.isInteger(y.step) ? v.toFixed(0) : v.toFixed(1);
      }
      const span = x1 - x0;
      const step = [15, 30, 60, 120, 180].find((s) => span / s <= 6) || 300;
      for (let tt = Math.ceil(x0 / step) * step; tt <= x1; tt += step) {
        const tick = el("text", { x: sx(tt), y: m.top + h + 17, class: "tick", "text-anchor": "middle" }, svg);
        tick.textContent = clock(tt);
      }

      // CPU 한도: 그 프로필 구간에만 점선
      if (chart.limit) {
        let drewLabel = false;
        for (const seg of segments) {
          const limit = LIMITS[seg.profile];
          if (limit == null) continue;
          el("line", { x1: sx(seg.start), x2: sx(seg.end), y1: sy(limit), y2: sy(limit), class: "limit" }, svg);
          if (!drewLabel && sx(seg.end) - sx(seg.start) > 120) {
            const label = el("text", { x: sx(seg.start) + 6, y: sy(limit) - 5, class: "limit-label" }, svg);
            label.textContent = t("perf.limit", { v: limit });
            drewLabel = true;
          }
        }
      }

      // 선: 값이 없는 시각에서 끊는다. 앞뒤가 비어 있는 점은 작은 점으로
      for (const series of chart.series) {
        let d = "";
        let open = false;
        list.forEach((row, i) => {
          const v = value(series, row);
          if (v == null) { open = false; return; }
          const px = sx(row.t).toFixed(1), py = sy(v).toFixed(1);
          const prev = i > 0 ? value(series, list[i - 1]) : null;
          const next = i < list.length - 1 ? value(series, list[i + 1]) : null;
          if (prev == null && next == null) {
            el("circle", { cx: px, cy: py, r: 1.8, class: "lone", style: `fill:${color(series)}` }, svg);
          }
          d += `${open ? "L" : "M"}${px} ${py}`;
          open = true;
        });
        el("path", { d, class: `line${series.reference ? " reference" : ""}`, style: `stroke:${color(series)}` }, svg);
      }
      view.overlay = el("g", { class: "overlay" }, svg);
    }
    drawSelection();
    drawStats(list);
    drawTable(list);
  }

  function drawSelection() {
    const list = visible();
    if (!list.length) return;
    const row = selected != null ? rows[selected] : list[list.length - 1];
    for (const view of views.values()) {
      const { chart, items, tip } = view;
      chart.series.forEach((series, i) => {
        const v = value(series, row);
        items[i].textContent = v == null ? "—" : chart.format(v);
      });
      if (!view.overlay) continue;
      view.overlay.replaceChildren();
      if (selected == null) { tip.hidden = true; continue; }
      const x = view.sx(row.t);
      el("line", { x1: x, x2: x, y1: view.m.top, y2: view.m.top + view.h, class: "crosshair" }, view.overlay);
      for (const series of chart.series) {
        const v = value(series, row);
        if (v == null || series.reference) continue;
        el("circle", { cx: x, cy: view.sy(v), r: 4, class: "dot", style: `fill:${color(series)}` }, view.overlay);
      }
      const showTip = hoverChart ? hoverChart === chart.id : chart.id === CHARTS[0].id;
      tip.hidden = !showTip;
      if (showTip) fillTip(view, row, x);
    }
  }

  function fillTip(view, row, x) {
    const { chart, tip, plot } = view;
    tip.replaceChildren();
    const head = document.createElement("div");
    head.className = "tip-head";
    const lang = window.gnLanguage ? window.gnLanguage() : "en";
    const comma = lang === "ja" || lang === "zh" ? "、" : ", ";
    head.textContent = `${clock(row.t)}  ${t(`perf.profile.${row.profile}`)}${comma}${t(`perf.state.${row.rate}`)}`;
    tip.appendChild(head);
    for (const series of chart.series) {
      const line = document.createElement("div");
      line.className = "tip-row";
      const key = document.createElement("span");
      key.className = `line-key${series.reference ? " dashed" : ""}`;
      key.style.setProperty("--key", color(series));
      const strong = document.createElement("strong");
      const v = value(series, row);
      strong.textContent = v == null ? "—" : chart.format(v);
      const name = document.createElement("span");
      name.textContent = t(series.name);
      line.append(key, strong, name);
      tip.appendChild(line);
    }
    const width = plot.clientWidth;
    const left = x + 14 + 190 > width ? x - 14 - 190 : x + 14;
    tip.style.left = `${Math.max(0, left)}px`;
  }

  function drawStats(list) {
    statsBox.replaceChildren();
    const groups = new Map();
    for (const row of list) {
      if (!groups.has(row.profile)) groups.set(row.profile, []);
      groups.get(row.profile).push(row);
    }
    const mean = (items, key) => items.reduce((sum, row) => sum + row[key], 0) / items.length;
    for (const [profile, items] of groups) {
      const name = t(`perf.profile.${profile}`);
      for (const [label, text] of [
        [t("perf.stat.cpu", { profile: name }), `${mean(items, "processCPU").toFixed(1)}%`],
        [t("perf.stat.rate", { profile: name }), t("perf.perSecond", { v: mean(items, "processedHz").toFixed(1) })],
      ]) {
        const tile = document.createElement("div");
        tile.className = "stat";
        const l = document.createElement("span");
        l.textContent = label;
        const v = document.createElement("strong");
        v.textContent = text;
        tile.append(l, v);
        statsBox.appendChild(tile);
      }
    }
  }

  function drawTable(list) {
    const columns = [
      ["processCPU", `${t("perf.s.process")} (%)`],
      ["trackingCPU", `${t("perf.s.tracking")} (%)`],
      ["mainCPU", `${t("perf.s.main")} (%)`],
      ["processedHz", `${t("perf.s.processed")} (${t("perf.rateUnit")})`],
      ["detectHz", `${t("perf.s.detect")} (${t("perf.rateUnit")})`],
      ["receivedFPS", `${t("perf.s.frames")} (fps)`],
    ];
    table.replaceChildren();
    const caption = document.createElement("caption");
    caption.textContent = t("perf.table.caption");
    const headRow = document.createElement("tr");
    for (const text of [t("perf.table.time"), t("perf.table.profile"), ...columns.map((c) => c[1])]) {
      const th = document.createElement("th");
      th.scope = "col";
      th.textContent = text;
      headRow.appendChild(th);
    }
    const thead = document.createElement("thead");
    thead.appendChild(headRow);
    const tbody = document.createElement("tbody");
    const buckets = new Map();
    for (const row of list) {
      const minute = Math.floor(row.t / 60);
      if (!buckets.has(minute)) buckets.set(minute, []);
      buckets.get(minute).push(row);
    }
    for (const [minute, items] of buckets) {
      const tr = document.createElement("tr");
      const counts = {};
      for (const row of items) counts[row.profile] = (counts[row.profile] || 0) + 1;
      const profile = Object.entries(counts).sort((a, b) => b[1] - a[1])[0][0];
      const cells = [`${clock(minute * 60)}–${clock(minute * 60 + 60)}`, t(`perf.profile.${profile}`),
        ...columns.map(([key]) => (items.reduce((s, r) => s + r[key], 0) / items.length).toFixed(1))];
      cells.forEach((text, i) => {
        const td = document.createElement(i === 0 ? "th" : "td");
        if (i === 0) td.scope = "row";
        td.textContent = text;
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    }
    table.append(caption, thead, tbody);
  }

  function select(index) {
    selected = index;
    drawSelection();
  }

  // MARK: - 조작

  document.querySelectorAll(".perf .segmented button").forEach((button) => {
    button.addEventListener("click", () => {
      range = Number(button.dataset.range);
      document.querySelectorAll(".perf .segmented button").forEach((b) => b.setAttribute("aria-pressed", String(b === button)));
      selected = null;
      draw();
    });
  });

  host.addEventListener("keydown", (event) => {
    const list = visible();
    if (!list.length) return;
    const first = rows.indexOf(list[0]), last = rows.indexOf(list[list.length - 1]);
    const current = selected ?? last;
    const moves = { ArrowLeft: -1, ArrowRight: 1, Home: first - current, End: last - current };
    if (event.key === "Escape") { select(null); return; }
    if (!(event.key in moves)) return;
    event.preventDefault();
    hoverChart = null;
    const step = event.shiftKey && event.key.startsWith("Arrow") ? 10 : 1;
    select(Math.min(last, Math.max(first, current + moves[event.key] * step)));
  });
  host.addEventListener("blur", () => { if (!hoverChart) select(null); });

  new ResizeObserver(() => { if (rows.length) draw(); }).observe(host);
  document.addEventListener("gn:language", () => { if (rows.length) { build(); draw(); } });

  fetch(`assets/performance-history.json${window.gnAssetQuery || ""}`)
    .then((response) => (response.ok ? response.json() : Promise.reject(response.status)))
    .then((json) => {
      const columns = json.columns;
      rows = json.samples.map((sample) => Object.fromEntries(columns.map((name, i) => [name, sample[i]])));
      build();
      draw();
    })
    .catch(() => {
      if (!status) return;
      status.dataset.i18n = "perf.error";
      status.textContent = t("perf.error");
    });
})();
