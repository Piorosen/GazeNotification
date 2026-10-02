// 홈페이지 동작: 언어 고르기, 32:9 화면 데모, 최신 릴리스 정보
(() => {
  const REPO = "Piorosen/GazeNotification";
  const LANGS = { ko: "ko", en: "en", ja: "ja", zh: "zh-Hans" }; // 사전 키 → html lang
  const dict = window.I18N || {};
  const root = document.documentElement;
  let lang = "en";
  let release = null; // GitHub 최신 릴리스 (없거나 못 읽으면 null)
  // 배포 버전 (pages.yml 이 넣는다). 이미지 주소에 붙여 캐시된 예전 이미지를 쓰지 않게 한다
  const version = document.querySelector('meta[name="asset-version"]')?.content;
  const bust = version && version !== "dev" ? `?v=${version}` : "";
  window.gnAssetQuery = bust;

  // MARK: - 언어

  function detectLanguage() {
    // ?lang=ja 처럼 주소로 고를 수도 있다 (링크 공유용)
    const fromURL = new URLSearchParams(location.search).get("lang");
    if (fromURL && dict[fromURL]) return fromURL;
    try {
      const saved = localStorage.getItem("lang");
      if (saved && dict[saved]) return saved;
    } catch (_) { /* 사생활 보호 모드 등: 저장소 없이 진행 */ }
    for (const code of navigator.languages || [navigator.language || "en"]) {
      const base = code.toLowerCase().split("-")[0];
      if (dict[base]) return base;
    }
    return "en";
  }

  // perf.js 도 같은 사전을 쓴다
  window.gnText = (key, values) => t(key, values);
  window.gnLanguage = () => lang;

  function t(key, values) {
    let text = (dict[lang] && dict[lang][key]) ?? dict.en[key] ?? "";
    for (const [name, value] of Object.entries(values || {})) text = text.replaceAll(`{${name}}`, value);
    return text;
  }

  function applyLanguage(next) {
    lang = dict[next] ? next : "en";
    root.lang = LANGS[lang];
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    // 제목: 쉼표까지를 한 구절로 묶어, 한중일 문장이 낱말 중간에서 끊기지 않게 한다
    const title = document.querySelector("h1[data-i18n]");
    if (title) {
      title.replaceChildren(...t(title.dataset.i18n).split(/(?<=[,、，])(\s*)/).map((part, i) => {
        if (i % 2) return document.createTextNode(part);
        const phrase = document.createElement("span");
        phrase.className = "phrase";
        phrase.textContent = part;
        return phrase;
      }));
    }
    // 사전에 직접 쓴 <code>, <a> 만 들어 있는 문구 (외부 입력 아님)
    document.querySelectorAll("[data-i18n-html]").forEach((el) => { el.innerHTML = t(el.dataset.i18nHtml); });
    document.querySelectorAll("[data-i18n-attr]").forEach((el) => {
      const [attr, key] = el.dataset.i18nAttr.split(":");
      el.setAttribute(attr, t(key));
    });
    // 화면 살펴보기의 앱 스크린샷은 언어마다 따로 찍어 두었다
    document.querySelectorAll("img[data-tour]").forEach((img) => {
      img.src = `assets/tour/${LANGS[lang]}/${img.dataset.tour}.webp${bust}`;
    });
    const picker = document.getElementById("lang");
    if (picker) picker.value = lang;
    renderRelease();
    renderMode();
    root.classList.add("i18n-ready");
    document.dispatchEvent(new CustomEvent("gn:language", { detail: { lang } })); // perf.js 가 그래프 글자를 다시 그린다
  }

  // MARK: - 최신 릴리스

  function renderRelease() {
    const meta = document.getElementById("release-meta");
    const gatekeeper = document.getElementById("gatekeeper");
    if (!meta) return;
    if (release === null) {
      meta.textContent = t("hero.metaFallback");
      return;
    }
    if (release === "none") {
      meta.textContent = t("hero.noRelease");
      document.getElementById("download").href = `https://github.com/${REPO}/releases`;
      return;
    }
    const dmg = (release.assets || []).find((a) => a.name === "GazeNotification.dmg");
    const size = dmg ? `${(dmg.size / 1048576).toFixed(1)} MB` : "";
    const version = String(release.tag_name || "").replace(/^v/, "");
    meta.textContent = size ? t("hero.meta", { version, size }) : t("hero.metaFallback");
    // 릴리스 본문에 서명 상태가 적혀 있다 (scripts/publish-release.sh). 공증된 버전이면 Gatekeeper 안내를 숨긴다
    if (gatekeeper) gatekeeper.hidden = /signing:\s*notarized/.test(release.body || "");
  }

  async function loadRelease() {
    try {
      const response = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (response.status === 404) release = "none";
      else if (response.ok) release = await response.json();
    } catch (_) { /* 오프라인 등: 기본 문구 유지 */ }
    renderRelease();
  }

  // MARK: - 32:9 화면 데모

  const screen = document.getElementById("screen");
  const banner = document.getElementById("banner");
  const gazeDot = document.getElementById("gaze");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  let mode = "gaze";
  let gaze = { x: 0.22, y: 0.6 };     // 화면 안 상대 위치
  let bannerX = null;                  // 지금 배너 왼쪽 위치(px)
  let lastPointer = 0;
  let shownAt = performance.now();

  function renderMode() {
    document.querySelectorAll(".mode").forEach((button) => {
      button.setAttribute("aria-pressed", String(button.dataset.mode === mode));
    });
    const note = document.getElementById("demo-note");
    if (note) note.textContent = t(mode === "gaze" ? "demo.noteGaze" : "demo.noteDefault");
  }

  function targetX(width, bannerWidth) {
    const margin = Math.max(12, width * 0.008);
    if (mode === "standard") return width - bannerWidth - margin;
    const center = gaze.x * width;
    return Math.min(Math.max(center - bannerWidth / 2, margin), width - bannerWidth - margin);
  }

  // 위치 계산 한 번 (애니메이션 루프와, 처음 그릴 때·크기가 바뀔 때 바로)
  function update(now) {
    if (!screen || !banner) return;
    const width = screen.clientWidth, height = screen.clientHeight;
    const bannerWidth = banner.offsetWidth;

    // 마우스가 없으면(터치 기기, 가만히 둠) 시선이 천천히 화면을 훑는다
    if (now - lastPointer > 2500 && !reduceMotion.matches) {
      const s = now / 1000;
      gaze = { x: 0.5 + 0.42 * Math.sin(s * 0.45), y: 0.58 + 0.12 * Math.sin(s * 0.9) };
    }

    // 알림은 7초마다 새로 뜬다: 미리 옮겨 둔 자리에 바로 나타나는 것을 보여 준다
    const cycle = (now - shownAt) % 7000;
    const visible = reduceMotion.matches || cycle < 5200;
    banner.classList.toggle("hidden", !visible);

    const goal = targetX(width, bannerWidth);
    if (bannerX === null || !visible || reduceMotion.matches) bannerX = goal;
    else bannerX += (goal - bannerX) * 0.12; // 떠 있는 동안은 부드럽게 따라간다
    banner.style.setProperty("--x", `${bannerX.toFixed(1)}px`);
    if (gazeDot) {
      gazeDot.style.setProperty("--gx", `${(gaze.x * width).toFixed(1)}px`);
      gazeDot.style.setProperty("--gy", `${(gaze.y * height).toFixed(1)}px`);
    }
  }

  function frame(now) {
    update(now);
    requestAnimationFrame(frame);
  }

  if (screen) {
    screen.addEventListener("pointermove", (event) => {
      if (event.pointerType === "touch") return;
      const rect = screen.getBoundingClientRect();
      gaze = {
        x: Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1),
        y: Math.min(Math.max((event.clientY - rect.top) / rect.height, 0.12), 1),
      };
      lastPointer = performance.now();
    });
    document.querySelectorAll(".mode").forEach((button) => {
      button.addEventListener("click", () => {
        mode = button.dataset.mode;
        shownAt = performance.now(); // 바꾸면 알림을 새로 띄워 차이를 바로 보여 준다
        bannerX = null;
        renderMode();
      });
    });
    update(performance.now());
    window.addEventListener("resize", () => { bannerX = null; update(performance.now()); });
    requestAnimationFrame(frame);
  }

  const clock = document.getElementById("clock");
  if (clock) {
    const tick = () => { clock.textContent = new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }); };
    tick();
    setInterval(tick, 30000);
  }

  // MARK: - 시작

  const picker = document.getElementById("lang");
  if (picker) {
    picker.addEventListener("change", () => {
      try { localStorage.setItem("lang", picker.value); } catch (_) { /* 저장 못 해도 이번 방문엔 적용 */ }
      applyLanguage(picker.value);
    });
  }
  applyLanguage(detectLanguage());
  loadRelease();
})();
