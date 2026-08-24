let equityChart = null;
let ws = null;
let currentKillSwitchState = false;

document.addEventListener('DOMContentLoaded', () => {
    initEquityChart();
    fetchMetrics();
    fetchTrades();
    fetchSignals();
    fetchRegime();
    fetchSystemStatus();
    connectWebSocket();
});

// Initialize Chart.js Equity Curve
function initEquityChart() {
    const ctx = document.getElementById('equityChart').getContext('2d');
    
    const gradient = ctx.createLinearGradient(0, 0, 0, 300);
    gradient.addColorStop(0, 'rgba(0, 240, 255, 0.35)');
    gradient.addColorStop(1, 'rgba(0, 240, 255, 0.0)');

    equityChart = new Chart(ctx, {
        type: 'line',
        data: {
            labels: [],
            datasets: [{
                label: 'Equity (¥)',
                data: [],
                borderColor: '#00f0ff',
                backgroundColor: gradient,
                borderWidth: 2.5,
                pointBackgroundColor: '#00f0ff',
                pointBorderColor: '#fff',
                pointRadius: 4,
                pointHoverRadius: 6,
                fill: true,
                tension: 0.2
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: { display: false },
                tooltip: {
                    backgroundColor: 'rgba(18, 24, 38, 0.95)',
                    titleColor: '#f0f4f8',
                    bodyColor: '#00f0ff',
                    borderColor: 'rgba(0, 240, 255, 0.4)',
                    borderWidth: 1,
                    padding: 12,
                    displayColors: false,
                    callbacks: {
                        label: function(context) {
                            return `累計損益: ¥${context.parsed.y.toLocaleString()}`;
                        }
                    }
                }
            },
            scales: {
                x: {
                    grid: { color: 'rgba(255, 255, 255, 0.05)' },
                    ticks: { color: '#8899a6', font: { family: 'JetBrains Mono', size: 10 } }
                },
                y: {
                    grid: { color: 'rgba(255, 255, 255, 0.05)' },
                    ticks: {
                        color: '#8899a6',
                        font: { family: 'JetBrains Mono', size: 10 },
                        callback: function(value) {
                            return '¥' + value.toLocaleString();
                        }
                    }
                }
            }
        }
    });
}

// Fetch Metrics from Go API
async function fetchMetrics() {
    try {
        const res = await fetch('/api/metrics');
        if (!res.ok) throw new Error(`HTTP error! status: ${res.status}`);
        const data = await res.json();
        updateKpiRibbon(data);
        updateEquityChart(data.trades || []);
    } catch (err) {
        console.error('Failed to fetch metrics:', err);
    }
}

function updateKpiRibbon(m) {
    const profitEl = document.getElementById('kpi-total-profit');
    profitEl.textContent = (m.total_profit >= 0 ? '+' : '') + `¥${m.total_profit.toLocaleString()}`;
    profitEl.className = 'kpi-value ' + (m.total_profit >= 0 ? 'highlight-green' : 'highlight-red');

    document.getElementById('kpi-gross-profit').textContent = `¥${m.gross_profit.toLocaleString()}`;
    document.getElementById('kpi-gross-loss').textContent = `¥${m.gross_loss.toLocaleString()}`;

    document.getElementById('kpi-win-rate').textContent = `${m.win_rate.toFixed(1)}%`;
    document.getElementById('kpi-trades-count').textContent = `${m.total_trades}戦 ${m.winning_trades}勝 ${m.losing_trades}敗`;
    document.getElementById('kpi-consecutive-wins').textContent = m.consecutive_wins;

    document.getElementById('kpi-profit-factor').textContent = m.profit_factor.toFixed(2);
    document.getElementById('kpi-avg-profit').textContent = `¥${Math.round(m.avg_trade_profit).toLocaleString()}`;
    document.getElementById('kpi-largest-win').textContent = `¥${m.largest_win.toLocaleString()}`;

    document.getElementById('kpi-max-drawdown').textContent = `¥${m.max_drawdown.toLocaleString()} (${m.max_drawdown_pct.toFixed(1)}%)`;
    document.getElementById('kpi-recommended-lot').textContent = `${m.recommended_lot.toFixed(2)} Lot`;
    document.getElementById('kpi-largest-loss').textContent = `¥${m.largest_loss.toLocaleString()}`;
}

function updateEquityChart(trades) {
    if (!equityChart) return;

    let cum = 0;
    const labels = ['Start'];
    const dataPoints = [0];

    trades.forEach((t, idx) => {
        cum += t.profit;
        labels.push(`#${t.ticket || idx + 1}`);
        dataPoints.push(cum);
    });

    equityChart.data.labels = labels;
    equityChart.data.datasets[0].data = dataPoints;
    equityChart.update();
}

// Fetch Closed Trades
async function fetchTrades() {
    try {
        const res = await fetch('/api/trades');
        if (!res.ok) return;
        const trades = await res.json();
        renderTradesTable(trades || []);
    } catch (err) {
        console.error('Failed to fetch trades:', err);
    }
}

function renderTradesTable(trades) {
    const tbody = document.getElementById('trades-table-body');
    const counter = document.getElementById('trades-counter');
    tbody.innerHTML = '';
    counter.textContent = `Showing ${trades.length} trades`;

    trades.slice().reverse().forEach(t => {
        const tr = document.createElement('tr');
        const isWin = t.profit >= 0;
        const actionBadge = `<span class="${t.action === 'BUY' ? 'badge-buy' : 'badge-sell'}">${t.action}</span>`;
        const profitClass = isWin ? 'highlight-green' : 'highlight-red';
        const closePriceStr = t.close_price ? t.close_price.toFixed(3) : '-';
        const closeTimeStr = t.close_time ? t.close_time : '-';

        tr.innerHTML = `
            <td>#${t.ticket}</td>
            <td><strong>${t.symbol}</strong></td>
            <td>${actionBadge}</td>
            <td>${t.lots.toFixed(2)}</td>
            <td>${t.open_price.toFixed(3)}</td>
            <td>${closePriceStr}</td>
            <td>${t.open_time}</td>
            <td>${closeTimeStr}</td>
            <td class="${profitClass}"><strong>${(t.profit >= 0 ? '+' : '') + '¥' + t.profit.toLocaleString()}</strong></td>
            <td><small>${t.comment || ''}</small></td>
        `;
        tbody.appendChild(tr);
    });
}

// Fetch Signals
async function fetchSignals() {
    try {
        const res = await fetch('/api/signals?limit=10');
        if (!res.ok) return;
        const signals = await res.json();
        renderSignals(signals || []);
    } catch (err) {
        console.error('Failed to fetch signals:', err);
    }
}

function renderSignals(signals) {
    const list = document.getElementById('signals-list');
    list.innerHTML = '';

    if (signals.length === 0) {
        list.innerHTML = `<div style="padding: 10px; color: #8899a6; font-size: 11px;">No recent signals recorded. Strategy engine listening...</div>`;
        return;
    }

    signals.forEach(s => {
        const row = document.createElement('div');
        row.className = `signal-row ${s.action}`;
        const regimeTag = s.regime ? `[${s.regime}] ` : '';
        const execTag = s.exec_type ? `(${s.exec_type}) ` : '';
        row.innerHTML = `
            <div>
                <strong>${s.symbol}</strong> [${s.action}] ${execTag}- Lot: ${s.lot.toFixed(2)}
                <div style="font-size: 10px; color: #8899a6;">${regimeTag}SL: ${s.stop_loss_pips} pips / TP: ${s.take_profit_pips} pips (${s.reason})</div>
            </div>
            <div style="font-size: 10px; color: #8899a6;">${s.created_at}</div>
        `;
        list.appendChild(row);
    });
}

// Fetch 4-State Market Regime Context
async function fetchRegime() {
    try {
        const res = await fetch('/api/regime?symbol=USDJPY');
        if (!res.ok) return;
        const data = await res.json();
        updateRegimeUI(data);
    } catch (err) {
        console.error('Failed to fetch regime:', err);
    }
}

function updateRegimeUI(reg) {
    const badge = document.getElementById('hud-regime-badge');
    const text = document.getElementById('regime-status-text');
    const dot = document.getElementById('regime-dot');

    const regime = reg.regime ? reg.regime.toUpperCase() : 'CLEAR';
    badge.className = `regime-badge state-${regime.toLowerCase()}`;
    text.textContent = `REGIME: ${regime} (${reg.entry_allowed ? 'ENTRY OK' : 'BLOCKED'})`;

    // Highlight state pill in subpanel
    document.querySelectorAll('.state-pill').forEach(pill => {
        pill.classList.remove('active');
    });
    const activePill = document.querySelector(`.state-pill.state-${regime.toLowerCase()}`);
    if (activePill) activePill.classList.add('active');
}

// Run Gemini AI Evaluation
async function runAiEvaluation() {
    const btn = document.getElementById('ai-eval-btn');
    btn.disabled = true;
    btn.textContent = '⏳ ANALYZING WITH GEMINI...';

    try {
        const res = await fetch('/api/ai/evaluate', { method: 'POST' });
        if (!res.ok) throw new Error('AI evaluation failed');
        const report = await res.json();
        updateAiReportUI(report);
    } catch (err) {
        alert('AI診断の実行に失敗しました: ' + err.message);
    } finally {
        btn.disabled = false;
        btn.textContent = '✨ RUN AI DIAGNOSIS';
    }
}

function updateAiReportUI(r) {
    document.getElementById('ai-overall-rank').textContent = r.overall_rank || 'S';
    document.getElementById('ai-report-title').textContent = r.title || 'AI Performance Report';
    document.getElementById('ai-report-summary').textContent = r.summary || '';

    const strengthsList = document.getElementById('ai-strengths-list');
    strengthsList.innerHTML = '';
    (r.strengths || []).forEach(s => {
        const li = document.createElement('li');
        li.textContent = s;
        strengthsList.appendChild(li);
    });

    const weaknessesList = document.getElementById('ai-weaknesses-list');
    weaknessesList.innerHTML = '';
    (r.action_points || r.weaknesses || []).forEach(w => {
        const li = document.createElement('li');
        li.textContent = w;
        weaknessesList.appendChild(li);
    });

    document.getElementById('ai-raw-report').textContent = r.raw_report || '';
}

// Emergency Kill Switch
async function toggleKillSwitch() {
    const nextState = !currentKillSwitchState;
    const confirmMsg = nextState 
        ? "⚠️ 【緊急キルスイッチ発動】全ポジションを即座に安全決済し、新規注文を全停止しますか？"
        : "キルスイッチを解除し、通常自動トレードを再開しますか？";
    
    if (!confirm(confirmMsg)) return;

    try {
        const res = await fetch('/api/kill-switch', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                active: nextState,
                reason: nextState ? "Manual Emergency Trigger from Pro Cockpit UI" : "Manual Reset"
            })
        });
        const data = await res.json();
        currentKillSwitchState = data.kill_switch;
        updateKillSwitchUI(currentKillSwitchState);
    } catch (err) {
        alert('キルスイッチ通信エラー: ' + err.message);
    }
}

function updateKillSwitchUI(active) {
    const badge = document.getElementById('hud-killswitch-status');
    const btn = document.getElementById('kill-switch-btn');
    if (active) {
        badge.className = 'status-badge killswitch-badge active';
        badge.innerHTML = `<span>🚨 KILL-SWITCH: TRIGGERED</span>`;
        btn.textContent = '🔄 RESET KILL-SWITCH';
        btn.style.background = '#445566';
    } else {
        badge.className = 'status-badge killswitch-badge';
        badge.innerHTML = `<span>KILL-SWITCH: NORMAL</span>`;
        btn.textContent = '🚨 EMERGENCY KILL';
        btn.style.background = 'linear-gradient(135deg, #ff2244, #bb0022)';
    }
}

// System Status
async function fetchSystemStatus() {
    try {
        const res = await fetch('/api/status');
        if (!res.ok) return;
        const data = await res.json();
        currentKillSwitchState = data.kill_switch;
        updateKillSwitchUI(currentKillSwitchState);
    } catch (e) {
        console.error(e);
    }
}

// WebSocket Connection
function connectWebSocket() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}/ws`;
    
    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
        console.log('[WS] Connected to Go Native Real-time Hub');
        document.getElementById('chart-refresh-status').textContent = '● Real-time live connected';
        document.getElementById('chart-refresh-status').style.color = '#00ff88';
    };

    ws.onmessage = (event) => {
        try {
            const msg = JSON.parse(event.data);
            if (msg.type === 'KILL_SWITCH_UPDATED') {
                currentKillSwitchState = msg.kill_switch;
                updateKillSwitchUI(currentKillSwitchState);
            } else if (msg.type === 'AI_REPORT_GENERATED') {
                updateAiReportUI(msg.report);
            }
            // Auto refresh metrics & signals
            fetchMetrics();
            fetchSignals();
            fetchTrades();
        } catch (e) {
            console.error('WS parse error:', e);
        }
    };

    ws.onclose = () => {
        console.log('[WS] Disconnected. Reconnecting in 3s...');
        document.getElementById('chart-refresh-status').textContent = '○ Reconnecting...';
        document.getElementById('chart-refresh-status').style.color = '#ffaa00';
        setTimeout(connectWebSocket, 3000);
    };
}
