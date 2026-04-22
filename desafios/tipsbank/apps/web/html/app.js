// TipsBank — SPA dourada (neumorphism + role-play bancario)
// Roteamento via hash (#/rota), cada rota renderiza em #app.
// "Sessao" simulada via localStorage (conta atual). Sem senha — e lab.

const API = {
  contas: "/api/contas",
  transacoes: "/api/transacoes",
  auditoria: "/api/auditoria",
};
const LS_KEY = "tipsbank:current_account_id";
const AGENCIA = "0001"; // fake mas realista

// ─── util ─────────────────────────────────────────────────────────
const $ = (id) => document.getElementById(id);
const app = () => $("app");

const fmtBRL = (v) => Number(v).toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
const fmtDoc = (d) => (d && d.length === 11 ? `${d.slice(0,3)}.${d.slice(3,6)}.${d.slice(6,9)}-${d.slice(9)}` : d);
const fmtAccount = (id) => {
  // Transforma um UUID em "numero de conta" fake de 6 digitos + 1 de verificacao
  if (!id) return "";
  let hash = 0; for (let i = 0; i < id.length; i++) { hash = (hash * 31 + id.charCodeAt(i)) >>> 0; }
  const n = String(hash % 10000000).padStart(7, "0");
  return `${n.slice(0, 6)}-${n.slice(6)}`;
};
const fmtTs = (iso) => new Date(iso).toLocaleString("pt-BR");
const fmtDate = (iso) => new Date(iso).toLocaleDateString("pt-BR");
const short = (s) => s ? s.slice(0, 8) : "";
const firstName = (s) => (s || "").split(" ")[0];
const initials = (s) => (s || "").split(" ").filter(Boolean).slice(0, 2).map(x => x[0]).join("").toUpperCase();
const escapeHtml = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({"&":"&amp;","<":"&lt;",">":"&gt;","\"":"&quot;","'":"&#39;"}[c]));

function toast(msg, kind = "info") {
  const el = $("toast");
  el.textContent = msg;
  el.className = "toast " + kind;
  el.classList.remove("hidden");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => el.classList.add("hidden"), 3500);
}

async function j(url, opts = {}) {
  const r = await fetch(url, {
    headers: { "content-type": "application/json", ...(opts.headers || {}) },
    ...opts,
  });
  const text = await r.text();
  const body = text ? JSON.parse(text) : null;
  if (!r.ok) throw new Error(body?.detail || `HTTP ${r.status}`);
  return body;
}

// ─── state ────────────────────────────────────────────────────────
let EU = null;
let CACHE_CONTAS = [];

function getAccountId() { return localStorage.getItem(LS_KEY); }
function setAccountId(id) { localStorage.setItem(LS_KEY, id); }
function clearAccount() { localStorage.removeItem(LS_KEY); EU = null; }

async function loadEu() {
  const id = getAccountId();
  if (!id) { EU = null; return; }
  try { EU = await j(`${API.contas}/contas/${id}`); }
  catch { clearAccount(); EU = null; }
}

async function refreshCache() {
  try { CACHE_CONTAS = await j(`${API.contas}/contas`); } catch {}
}

// ─── health (passivo) ─────────────────────────────────────────────
let HEALTH = { state: "checando", text: "checando…" };

async function atualizarHealth() {
  const alvos = [`${API.contas}/health/live`, `${API.transacoes}/health/live`, `${API.auditoria}/health/live`];
  const results = await Promise.all(alvos.map(async (u) => { try { await j(u); return true; } catch { return false; }}));
  const allOk = results.every(Boolean);
  const someOk = results.some(Boolean);
  HEALTH = allOk ? { state: "ok", text: "sistema operando" } : someOk ? { state: "warn", text: "parcial" } : { state: "err", text: "offline" };
  document.querySelectorAll("[data-health-dot]").forEach(el => el.className = "health-dot " + HEALTH.state);
  document.querySelectorAll("[data-health-text]").forEach(el => el.textContent = HEALTH.text);
}

// ─── router ───────────────────────────────────────────────────────
const ROUTES = {};
function route(path, handler) { ROUTES[path] = handler; }

async function navigate() {
  const hash = (location.hash || "#/").replace(/^#/, "");
  const [path, qs] = hash.split("?");
  const query = new URLSearchParams(qs || "");

  // Proteção: rotas autenticadas
  const PROTEGIDAS = ["/conta", "/transferir", "/extrato", "/auditoria", "/perfil"];
  if (PROTEGIDAS.some(p => path.startsWith(p))) {
    await loadEu();
    if (!EU) { location.hash = "#/entrar"; return; }
  }

  // Landing: se logado, vai pro dashboard
  if ((path === "/" || path === "") && getAccountId()) {
    location.hash = "#/conta"; return;
  }

  const handler = ROUTES[path] || ROUTES["/404"];
  app().innerHTML = "";
  await handler(query);
  await atualizarHealth();
}

window.addEventListener("hashchange", navigate);
window.addEventListener("popstate", navigate);

function go(hash) { location.hash = hash; }
window.go = go;

// ─── componentes reusáveis ────────────────────────────────────────
function topbarPublica() {
  return `
    <header class="topbar">
      <div class="brand" onclick="go('#/')">
        <img src="/img/logo-banco.png" class="logo-mini" alt="TipsBank" />
        <div>
          <div class="brand-name">TipsBank</div>
          <div class="brand-tag">Internet Banking · LinuxTips</div>
        </div>
      </div>
      <div class="topbar-right">
        <div class="health-badge">
          <span class="health-dot" data-health-dot></span>
          <span data-health-text>checando…</span>
        </div>
      </div>
    </header>`;
}

function topbarPrivada(rotaAtiva) {
  const nav = [
    ["/conta", "Inicio"],
    ["/transferir", "Transferir"],
    ["/extrato", "Extrato"],
    ["/auditoria", "Auditoria"],
  ].map(([p, t]) => `<button class="nav-link ${rotaAtiva === p ? "active" : ""}" onclick="go('#${p}')">${t}</button>`).join("");
  return `
    <header class="topbar">
      <div class="brand" onclick="go('#/conta')">
        <img src="/img/logo-banco.png" class="logo-mini" alt="TipsBank" />
        <div>
          <div class="brand-name">TipsBank</div>
          <div class="brand-tag">Internet Banking · LinuxTips</div>
        </div>
      </div>
      <nav class="topbar-nav">${nav}</nav>
      <div class="topbar-right">
        <div class="health-badge">
          <span class="health-dot" data-health-dot></span>
          <span data-health-text>checando…</span>
        </div>
        <div class="user-chip" onclick="go('#/perfil')" title="Ver perfil">
          <img src="/img/mascote-rock.png" alt="" />
          <div>
            <div class="uname">${escapeHtml(firstName(EU?.titular))}</div>
            <div class="usub">AG ${AGENCIA} · CC ${fmtAccount(EU?.id)}</div>
          </div>
        </div>
      </div>
    </header>`;
}

function footer() {
  return `
    <footer class="footer">
      TipsBank S.A. (ficticio) · Desafio Final DK8s 2025 ·
      <a href="https://linuxtips.io" target="_blank">LinuxTips</a> ·
      Infra: Distroless + Cosign + Kubernetes
    </footer>`;
}

// ═════════════════════════════════════════════════════════════════
// ROTA: / (landing)
// ═════════════════════════════════════════════════════════════════
route("/", async () => {
  app().innerHTML = `
    <div class="page">
      ${topbarPublica()}
      <main class="container">
        <section class="hero">
          <div>
            <span class="hero-badge">Internet Banking · Fundado em 2025</span>
            <h1>O banco dos <span class="gold">descomplicadores.</span></h1>
            <p class="lede">
              Abre conta em 10 segundos, transfere pra qualquer correntista,
              acompanha tudo em um extrato que nem o BACEN tem coragem de auditar.
              Atendimento 24/7.
            </p>
            <div class="hero-cta">
              <button class="btn btn-gold" onclick="go('#/abrir')">Abrir minha conta</button>
              <button class="btn btn-ghost" onclick="go('#/entrar')">Ja sou cliente</button>
            </div>
          </div>
          <div class="hero-art">
            <img src="/img/hero-gold.png" alt="TipsBank dourado" />
          </div>
        </section>

        <section class="trust-strip fade-in">
          <div>
            <div class="t-num" id="trust-contas">—</div>
            <div class="t-lbl">Correntistas</div>
          </div>
          <div>
            <div class="t-num">100%</div>
            <div class="t-lbl">Uptime teorico</div>
          </div>
          <div>
            <div class="t-num">0,00</div>
            <div class="t-lbl">Taxas</div>
          </div>
          <div>
            <div class="t-num">24/7</div>
            <div class="t-lbl">Atendimento</div>
          </div>
        </section>

        <section class="grid grid-3 mt-8 mb-6">
          <div class="card">
            <h3>Conta digital com PIX</h3>
            <p style="color:var(--ink-soft);font-size:14px;margin-top:10px">
              Transferencias instantaneas entre correntistas. Nao tem conveniencia, tem velocidade.
            </p>
          </div>
          <div class="card">
            <h3>Auditoria blindada</h3>
            <p style="color:var(--ink-soft);font-size:14px;margin-top:10px">
              Todo movimento vai pra um arquivo imutavel, armazenado em NFS distribuido. BACEN adoraria.
            </p>
          </div>
          <div class="card">
            <h3>Saldo inicial cortesia</h3>
            <p style="color:var(--ink-soft);font-size:14px;margin-top:10px">
              Toda nova conta ja comeca com R$ 1.000,00. A gente acredita nos descomplicadores.
            </p>
          </div>
        </section>
      </main>
      ${footer()}
    </div>`;
  // trust: contar contas
  try {
    const lista = await j(`${API.contas}/contas?limit=200`);
    $("trust-contas").textContent = lista.length;
  } catch {}
});

// ═════════════════════════════════════════════════════════════════
// ROTA: /abrir
// ═════════════════════════════════════════════════════════════════
route("/abrir", async () => {
  app().innerHTML = `
    <div class="page">
      ${topbarPublica()}
      <main class="container center" style="padding: 60px 24px;">
        <div class="card" style="max-width: 480px; width: 100%;">
          <button class="nav-link" onclick="go('#/')" style="margin-bottom:12px;padding-left:0">&laquo; voltar</button>
          <h2 class="section-title">Abrir conta</h2>
          <p class="section-sub">E gratis e leva 10 segundos.</p>

          <div class="field">
            <label>Nome completo</label>
            <input id="ab-titular" class="input" placeholder="Ex: Descomplicador da Silva" />
          </div>
          <div class="field">
            <label>CPF (apenas numeros)</label>
            <input id="ab-doc" class="input mono" maxlength="11" placeholder="12345678901" inputmode="numeric" />
          </div>
          <div class="field">
            <label>Senha de acesso (minimo 4 caracteres)</label>
            <input id="ab-senha" class="input mono" type="password" minlength="4" maxlength="72" placeholder="••••••" autocomplete="new-password" />
            <div class="field-hint">Nao perca. Use algo memoravel — o suporte nao reseta senhas em lab.</div>
          </div>
          <div class="field">
            <label>Confirme a senha</label>
            <input id="ab-senha2" class="input mono" type="password" minlength="4" maxlength="72" placeholder="••••••" autocomplete="new-password" />
          </div>
          <div class="field">
            <label>Deposito inicial (R$)</label>
            <input id="ab-saldo" class="input" type="number" min="0" step="0.01" value="1000" />
            <div class="field-hint">Cortesia da LinuxTips pra iniciar os estudos.</div>
          </div>

          <button class="btn btn-gold full mt-4" onclick="abrirConta()">Abrir minha conta</button>
          <div class="divider"></div>
          <div class="tc" style="font-size:12px;color:var(--ink-mute)">Ja e cliente? <a onclick="go('#/entrar')">Entre aqui</a></div>
        </div>
      </main>
      ${footer()}
    </div>`;
});

window.abrirConta = async function() {
  const titular = $("ab-titular").value.trim();
  const documento = $("ab-doc").value.replace(/\D/g, "");
  const senha = $("ab-senha").value;
  const senha2 = $("ab-senha2").value;
  const saldo = $("ab-saldo").value || "0";
  if (titular.length < 3) return toast("Informe o nome completo", "err");
  if (documento.length !== 11) return toast("CPF precisa de 11 digitos", "err");
  if (senha.length < 4) return toast("Senha precisa ter pelo menos 4 caracteres", "err");
  if (senha !== senha2) return toast("As senhas nao conferem", "err");
  try {
    const nova = await j(`${API.contas}/contas`, {
      method: "POST",
      body: JSON.stringify({ titular, documento, senha, saldo_inicial: saldo }),
    });
    setAccountId(nova.id);
    toast("Conta aberta! Bem-vindo ao TipsBank.", "ok");
    go("#/conta");
  } catch (e) { toast(e.message, "err"); }
};

// ═════════════════════════════════════════════════════════════════
// ROTA: /entrar (login por CPF + senha)
// ═════════════════════════════════════════════════════════════════
route("/entrar", async () => {
  app().innerHTML = `
    <div class="page">
      ${topbarPublica()}
      <main class="container center" style="padding: 60px 24px;">
        <div class="card" style="max-width: 460px; width: 100%;">
          <button class="nav-link" onclick="go('#/')" style="margin-bottom:12px;padding-left:0">&laquo; voltar</button>
          <h2 class="section-title">Acessar sua conta</h2>
          <p class="section-sub">Informe seu CPF e senha pra entrar no internet banking.</p>

          <form id="login-form" onsubmit="event.preventDefault(); fazerLogin();">
            <div class="field">
              <label>CPF</label>
              <input id="lg-doc" class="input mono" maxlength="14" placeholder="000.000.000-00" inputmode="numeric" autocomplete="username" />
            </div>
            <div class="field">
              <label>Senha</label>
              <input id="lg-senha" class="input mono" type="password" maxlength="72" placeholder="••••••" autocomplete="current-password" />
              <div class="field-hint">Contas seed usam a senha <code>giropops</code>.</div>
            </div>
            <button class="btn btn-gold full mt-4" id="lg-btn" type="submit">Entrar</button>
          </form>

          <div class="divider"></div>
          <div class="tc" style="font-size:12px;color:var(--ink-mute)">
            Ainda nao tem conta? <a onclick="go('#/abrir')">Abrir conta gratis</a>
          </div>
        </div>
      </main>
      ${footer()}
    </div>`;

  // Enter no input de senha dispara o submit ja pelo form
  setTimeout(() => $("lg-doc") && $("lg-doc").focus(), 50);
});

window.fazerLogin = async function() {
  const documento = ($("lg-doc").value || "").replace(/\D/g, "");
  const senha = $("lg-senha").value;
  if (documento.length !== 11) return toast("CPF precisa de 11 digitos", "err");
  if (!senha) return toast("Informe a senha", "err");
  const btn = $("lg-btn");
  btn.disabled = true; btn.textContent = "Autenticando…";
  try {
    const conta = await j(`${API.contas}/login`, {
      method: "POST",
      body: JSON.stringify({ documento, senha }),
    });
    setAccountId(conta.id);
    toast(`Bem-vindo de volta, ${firstName(conta.titular)}!`, "ok");
    go("#/conta");
  } catch (e) {
    const msg = e.message.includes("credenciais") ? "CPF ou senha invalidos" : e.message;
    toast(msg, "err");
    btn.disabled = false; btn.textContent = "Entrar";
    const senhaInp = $("lg-senha"); if (senhaInp) senhaInp.value = "";
  }
};

// ═════════════════════════════════════════════════════════════════
// ROTA: /conta (dashboard)
// ═════════════════════════════════════════════════════════════════
route("/conta", async () => {
  await loadEu();
  await refreshCache();
  const extratoCurto = await extratoData(5);

  app().innerHTML = `
    <div class="page">
      ${topbarPrivada("/conta")}
      <main class="container" style="padding: 30px 24px 60px;">
        <div class="greeting">Ola, ${escapeHtml(firstName(EU.titular))}.</div>
        <div class="greeting-sub">Seu patrimonio em tempo real.</div>

        <div class="balance-card">
          <div style="display:flex;justify-content:space-between;align-items:flex-start;gap:20px;flex-wrap:wrap">
            <div>
              <div class="balance-label">Saldo disponivel</div>
              <div class="balance-value">${fmtBRL(EU.saldo)}</div>
              <div class="balance-meta">
                <span>Agencia <strong>${AGENCIA}</strong></span>
                <span>Conta <strong>${fmtAccount(EU.id)}</strong></span>
                <span>CPF <strong>${fmtDoc(EU.documento)}</strong></span>
              </div>
            </div>
            <img src="/img/hero-gold.png" style="height:130px;border-radius:14px;box-shadow:var(--shadow-outset-sm);object-fit:cover;max-width:280px" alt="" />
          </div>
        </div>

        <div class="quick-actions">
          <button class="action-tile" onclick="go('#/transferir')"><div class="action-ico">$</div><div class="action-label">Transferir</div></button>
          <button class="action-tile" onclick="go('#/extrato')"><div class="action-ico">≡</div><div class="action-label">Extrato</div></button>
          <button class="action-tile" onclick="go('#/auditoria')"><div class="action-ico">⌂</div><div class="action-label">Auditoria</div></button>
          <button class="action-tile" onclick="go('#/perfil')"><div class="action-ico">@</div><div class="action-label">Perfil</div></button>
        </div>

        <div class="flex items-center justify-between mb-4">
          <h3 style="font-size:22px;">Ultimas movimentacoes</h3>
          <button class="nav-link" onclick="go('#/extrato')">Ver tudo &raquo;</button>
        </div>
        <div class="card">
          ${extratoCurto || `<p class="tc" style="color:var(--ink-mute);padding:20px">Sem movimentacoes ainda. <a onclick="go('#/transferir')">Fazer a primeira transferencia</a>.</p>`}
        </div>
      </main>
      ${footer()}
    </div>`;
});

// Helper — renderiza extrato em HTML
async function extratoData(limit = 50) {
  try {
    const lista = await j(`${API.transacoes}/extrato/${EU.id}?limit=${limit}`);
    if (lista.length === 0) return "";
    return lista.map(tx => {
      const saida = tx.origem_id === EU.id;
      const outroId = saida ? tx.destino_id : tx.origem_id;
      const outro = CACHE_CONTAS.find(c => c.id === outroId);
      const nome = outro ? outro.titular : short(outroId);
      return `
        <div class="tx-item">
          <div class="tx-ico ${saida ? "tx-out" : "tx-in"}">${initials(nome) || (saida ? "−" : "+")}</div>
          <div>
            <div class="tx-title">${saida ? "Transferencia enviada para" : "Transferencia recebida de"} <span style="color:var(--gold-700)">${escapeHtml(nome)}</span></div>
            <div class="tx-sub">ID ${short(tx.id)} · status: ${tx.status}</div>
          </div>
          <div class="tx-amount ${saida ? "out" : "in"}">${saida ? "−" : "+"}${fmtBRL(tx.valor)}</div>
        </div>`;
    }).join("");
  } catch (e) { return `<p class="tc" style="color:var(--danger);padding:20px">Falha ao carregar: ${escapeHtml(e.message)}</p>`; }
}

// ═════════════════════════════════════════════════════════════════
// ROTA: /extrato
// ═════════════════════════════════════════════════════════════════
route("/extrato", async () => {
  await loadEu();
  await refreshCache();
  const html = await extratoData(200);

  app().innerHTML = `
    <div class="page">
      ${topbarPrivada("/extrato")}
      <main class="container" style="padding: 30px 24px 60px;">
        <h2 class="section-title">Extrato completo</h2>
        <p class="section-sub">Todas as suas movimentacoes, da mais recente pra mais antiga.</p>
        <div class="card">
          ${html || `<p class="tc" style="color:var(--ink-mute);padding:20px">Ainda sem movimentacoes.</p>`}
        </div>
      </main>
      ${footer()}
    </div>`;
});

// ═════════════════════════════════════════════════════════════════
// ROTA: /transferir
// ═════════════════════════════════════════════════════════════════
route("/transferir", async () => {
  await loadEu();
  await refreshCache();

  app().innerHTML = `
    <div class="page">
      ${topbarPrivada("/transferir")}
      <main class="container" style="padding: 30px 24px 60px; max-width: 720px;">
        <h2 class="section-title">Nova transferencia</h2>
        <p class="section-sub">Movimenta entre correntistas do TipsBank. Processamento instantaneo.</p>

        <div class="card">
          <div class="field">
            <label>Origem</label>
            <div class="card-inset">
              <div style="display:flex;align-items:center;gap:12px">
                <img src="/img/mascote-rock.png" style="width:36px;height:36px;border-radius:50%" alt="" />
                <div>
                  <div style="font-weight:600">${escapeHtml(EU.titular)}</div>
                  <div class="doc-big">AG ${AGENCIA} · CC ${fmtAccount(EU.id)} · ${fmtDoc(EU.documento)}</div>
                </div>
                <div style="margin-left:auto;text-align:right">
                  <div class="chip-plain chip">saldo</div>
                  <div class="mono" style="font-weight:600;color:var(--gold-700)">${fmtBRL(EU.saldo)}</div>
                </div>
              </div>
            </div>
          </div>

          <div class="field">
            <label>Destinatario</label>
            <div id="tr-chosen" class="hidden"></div>
            <div id="tr-searchbox" class="searchbox">
              <svg class="search-ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="11" cy="11" r="8"/><path d="M21 21l-4.35-4.35"/></svg>
              <input id="tr-busca" class="input search-input" placeholder="Buscar por nome ou CPF…" autocomplete="off" />
              <div id="tr-results" class="search-results hidden"></div>
            </div>
          </div>

          <div class="field">
            <label>Valor (R$)</label>
            <input id="tr-valor" class="input" type="number" min="0.01" step="0.01" placeholder="0,00" />
            <div class="field-hint">Voce tem ${fmtBRL(EU.saldo)} disponivel.</div>
          </div>

          <button id="tr-btn" class="btn btn-gold full mt-4" disabled>Transferir agora</button>
        </div>

        <div id="tr-recibo" class="mt-6"></div>
      </main>
      ${footer()}
    </div>`;

  setupBuscaDestinatario();
});

let TR_DESTINO = null;
function setupBuscaDestinatario() {
  TR_DESTINO = null;
  const busca = $("tr-busca");
  const results = $("tr-results");
  const valorInput = $("tr-valor");
  const btn = $("tr-btn");

  busca.addEventListener("input", () => {
    const q = busca.value.trim().toLowerCase();
    if (q.length < 2) { results.classList.add("hidden"); return; }
    const matches = CACHE_CONTAS
      .filter(c => c.id !== EU.id)
      .filter(c => c.titular.toLowerCase().includes(q) || (c.documento || "").includes(q.replace(/\D/g, "")))
      .slice(0, 8);
    if (matches.length === 0) {
      results.innerHTML = `<div style="padding:14px;color:var(--ink-mute);font-size:13px">Ninguem encontrado.</div>`;
    } else {
      results.innerHTML = matches.map(c => `
        <button class="search-item" onclick="escolherDestino('${c.id}')">
          <img src="/img/mascote-rock.png" alt="" />
          <div>
            <div class="si-name">${escapeHtml(c.titular)}</div>
            <div class="si-doc">${fmtDoc(c.documento)} · CC ${fmtAccount(c.id)}</div>
          </div>
        </button>`).join("");
    }
    results.classList.remove("hidden");
  });

  valorInput.addEventListener("input", validarBtn);
  btn.addEventListener("click", executarTransferencia);
}

window.escolherDestino = function(id) {
  const c = CACHE_CONTAS.find(x => x.id === id);
  if (!c) return;
  TR_DESTINO = c;
  const box = $("tr-chosen");
  box.innerHTML = `
    <div class="chosen-dest">
      <img src="/img/mascote-rock.png" alt="" />
      <div class="cd-info">
        <div class="n">${escapeHtml(c.titular)}</div>
        <div class="d">${fmtDoc(c.documento)} · CC ${fmtAccount(c.id)}</div>
      </div>
      <button onclick="limparDestino()">trocar</button>
    </div>`;
  box.classList.remove("hidden");
  $("tr-searchbox").classList.add("hidden");
  validarBtn();
};

window.limparDestino = function() {
  TR_DESTINO = null;
  $("tr-chosen").classList.add("hidden");
  $("tr-searchbox").classList.remove("hidden");
  $("tr-busca").value = "";
  $("tr-results").classList.add("hidden");
  validarBtn();
};

function validarBtn() {
  const v = parseFloat($("tr-valor").value || "0");
  $("tr-btn").disabled = !(TR_DESTINO && v > 0);
}

async function executarTransferencia() {
  if (!TR_DESTINO) return;
  const valor = $("tr-valor").value;
  const btn = $("tr-btn");
  btn.disabled = true; btn.textContent = "Processando…";
  try {
    const tx = await j(`${API.transacoes}/transferencias`, {
      method: "POST",
      body: JSON.stringify({ origem_id: EU.id, destino_id: TR_DESTINO.id, valor }),
    });
    toast(`Transferencia concluida! ${fmtBRL(tx.valor)}`, "ok");
    $("tr-recibo").innerHTML = `
      <div class="receipt fade-in">
        <div class="receipt-brand">
          <img src="/img/logo-banco.png" style="height:32px;width:32px;border-radius:50%;object-fit:cover" alt="" />
          <strong style="font-family:'Roc Grotesk',Impact,sans-serif;color:var(--gold-700);font-size:18px;letter-spacing:1.5px;text-transform:uppercase">TipsBank · Comprovante</strong>
        </div>
        <div class="receipt-row"><span class="k">Autenticacao</span><span class="v">${tx.id}</span></div>
        <div class="receipt-row"><span class="k">Data/hora</span><span class="v">${fmtTs(new Date().toISOString())}</span></div>
        <div class="receipt-row"><span class="k">De</span><span class="v">${escapeHtml(EU.titular)}</span></div>
        <div class="receipt-row"><span class="k">Conta origem</span><span class="v">AG ${AGENCIA} CC ${fmtAccount(EU.id)}</span></div>
        <div class="receipt-row"><span class="k">Para</span><span class="v">${escapeHtml(TR_DESTINO.titular)}</span></div>
        <div class="receipt-row"><span class="k">Conta destino</span><span class="v">AG ${AGENCIA} CC ${fmtAccount(TR_DESTINO.id)}</span></div>
        <div class="receipt-amount">${fmtBRL(tx.valor)}</div>
        <div class="receipt-foot">
          Operacao processada e auditada &middot; status: <strong>${tx.status}</strong><br/>
          Guarde este comprovante. Voce pode vincular no seu repositorio de evidencias.
        </div>
      </div>
      <div class="flex gap-3 mt-4">
        <button class="btn btn-ghost" onclick="go('#/conta')">Voltar ao inicio</button>
        <button class="btn btn-gold" onclick="go('#/transferir')">Nova transferencia</button>
      </div>`;
    window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" });
    await loadEu();
  } catch (e) {
    toast(e.message, "err");
    btn.disabled = false; btn.textContent = "Transferir agora";
  }
}

// ═════════════════════════════════════════════════════════════════
// ROTA: /auditoria
// ═════════════════════════════════════════════════════════════════
route("/auditoria", async (query) => {
  await loadEu();
  await refreshCache();
  const dia = query.get("dia");

  app().innerHTML = `
    <div class="page">
      ${topbarPrivada("/auditoria")}
      <main class="container" style="padding: 30px 24px 60px;">
        <h2 class="section-title">Auditoria</h2>
        <p class="section-sub">Eventos imutaveis gravados em <code>/data/eventos-YYYY-MM-DD.jsonl</code>. Usado pelo BACEN ficticio.</p>
        <div id="aud-dias" class="day-pills"></div>
        <div id="aud-lista" class="card">
          <p class="tc" style="color:var(--ink-mute);padding:20px">Carregando…</p>
        </div>
      </main>
      ${footer()}
    </div>`;

  try {
    const [arquivos, eventos] = await Promise.all([
      j(`${API.auditoria}/arquivos`),
      j(`${API.auditoria}/eventos${dia ? `?dia=${dia}` : ""}`),
    ]);
    $("aud-dias").innerHTML = arquivos.map(a => {
      const d = a.replace("eventos-", "").replace(".jsonl", "");
      const ativo = dia === d || (!dia && arquivos[arquivos.length - 1] === a);
      return `<button class="day-pill ${ativo ? "active" : ""}" onclick="go('#/auditoria?dia=${d}')">${d}</button>`;
    }).join("");
    if (eventos.length === 0) {
      $("aud-lista").innerHTML = `<p class="tc" style="color:var(--ink-mute);padding:20px">Sem eventos neste dia.</p>`;
      return;
    }
    $("aud-lista").innerHTML = eventos.reverse().map(e => {
      const or = CACHE_CONTAS.find(c => c.id === e.origem_id)?.titular || short(e.origem_id);
      const de = CACHE_CONTAS.find(c => c.id === e.destino_id)?.titular || short(e.destino_id);
      return `
        <div class="tx-item">
          <div class="tx-ico" style="background:var(--gold-100);color:var(--gold-700)">A</div>
          <div>
            <div class="tx-title">${escapeHtml(or)} <span style="color:var(--ink-mute)">&rarr;</span> ${escapeHtml(de)}</div>
            <div class="tx-sub">${fmtTs(e.recebido_em)} · <span class="chip chip-plain">${e.tipo}</span>${e.versao_app ? ` · app ${e.versao_app}` : ""}</div>
            <div class="tx-sub mono" style="font-size:10px">tx=${e.transacao_id} · evt=${e.id}</div>
          </div>
          <div class="tx-amount" style="color:var(--gold-700)">${fmtBRL(e.valor)}</div>
        </div>`;
    }).join("");
  } catch (e) {
    $("aud-lista").innerHTML = `<p class="tc" style="color:var(--danger);padding:20px">Falha: ${escapeHtml(e.message)}</p>`;
  }
});

// ═════════════════════════════════════════════════════════════════
// ROTA: /perfil
// ═════════════════════════════════════════════════════════════════
route("/perfil", async () => {
  await loadEu();
  app().innerHTML = `
    <div class="page">
      ${topbarPrivada("/perfil")}
      <main class="container" style="padding: 30px 24px 60px; max-width: 680px;">
        <h2 class="section-title">Meu perfil</h2>
        <p class="section-sub">Dados do correntista.</p>

        <div class="card">
          <div style="display:flex;align-items:center;gap:16px;margin-bottom:22px">
            <img src="/img/mascote-rock.png" style="width:72px;height:72px;border-radius:50%;box-shadow:var(--shadow-outset-sm)" alt="" />
            <div>
              <h3 style="font-size:22px">${escapeHtml(EU.titular)}</h3>
              <div class="doc-big">${fmtDoc(EU.documento)}</div>
            </div>
          </div>

          <div class="card-inset">
            <div class="account-badge" style="display:grid;grid-template-columns:1fr 1fr 1fr;gap:16px">
              <div><span class="k">Agencia</span><strong>${AGENCIA}</strong></div>
              <div><span class="k">Conta</span><strong>${fmtAccount(EU.id)}</strong></div>
              <div><span class="k">Saldo</span><strong style="color:var(--gold-700)">${fmtBRL(EU.saldo)}</strong></div>
            </div>
          </div>

          <div class="divider"></div>

          <h4 style="font-size:16px;margin-bottom:10px">Identificador interno</h4>
          <div class="card-inset mono" style="font-size:12px;color:var(--ink-soft);word-break:break-all">${EU.id}</div>
          <div class="field-hint mt-4">Este ID eh o primary key da sua conta no Postgres e o identificador no audit log.</div>

          <div class="divider"></div>

          <div class="flex gap-3">
            <button class="btn btn-ghost" onclick="go('#/conta')">Voltar</button>
            <button class="btn btn-danger" onclick="sair()">Sair da conta</button>
          </div>
        </div>
      </main>
      ${footer()}
    </div>`;
});

window.sair = function() {
  clearAccount();
  toast("Ate logo!", "info");
  go("#/");
};

// ═════════════════════════════════════════════════════════════════
// 404
// ═════════════════════════════════════════════════════════════════
route("/404", async () => {
  app().innerHTML = `
    <div class="page">
      ${topbarPublica()}
      <main class="container center" style="padding: 80px 24px; flex:1">
        <div class="card tc" style="max-width:480px">
          <img src="/img/mascote-duvida.png" style="width:160px;margin:0 auto 16px;display:block;opacity:.85" alt="" />
          <h2 class="section-title">Pagina nao encontrada</h2>
          <p class="section-sub">A rota <code>${location.hash}</code> nao existe neste internet banking.</p>
          <button class="btn btn-gold" onclick="go('#/')">Voltar ao inicio</button>
        </div>
      </main>
      ${footer()}
    </div>`;
});

// ═════════════════════════════════════════════════════════════════
// boot
// ═════════════════════════════════════════════════════════════════
(async function boot() {
  if (!location.hash) location.hash = "#/";
  setInterval(atualizarHealth, 15_000);
  await navigate();
})();
