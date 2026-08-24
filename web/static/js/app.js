let equityChart = null;
let backtestEquityChart = null;
let monthlyChart = null;
let ws = null;
let currentKillSwitchState = false;

document.addEventListener('DOMContentLoaded', () => {
    initEquityChart();
    initBacktestCharts();
    fetchMetrics();
    fetchTrades();
    fetchSignals();
    fetchRegime();
    fetchSystemStatus();
    connectWebSocket();
});

// Tab Switcher
function switchTab(tabName) {
    document.querySelectorAll('.nav-tab-btn').forEach(btn => btn.classList.remove('active'));
    document.querySelectorAll('.tab-view').forEach(view => view.classList.remove('active'));

    const activeBtn = document.getElementById(`tab-btn-${tabName}`);
    const activeView = document.getElementById(`view-${tabName}`);

    if (activeBtn) activeBtn.classList.add('active');
    if (activeView) activeView.classList.add('active');

    // Trigger chart resize if needed
    if (tabName === 'backtest' && backtestEquityChart) {
        backtestEquityChart.resize();
        if (monthlyChart) monthlyChart.resize();
    }
}

// Initialize Live Chart.js Equity Curve
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

// Initialize Backtest Chart.js Instances
function initBacktestCharts() {
    // 1. Backtest Equity Growth Curve
    const ctxBt = document.getElementById('backtestEquityChart').getContext('2d');
    const gradBt = ctxBt.createLinearGradient(0, 0, 0, 300);
    gradBt.addColorStop(0, 'rgba(0, 255, 136, 0.35)');
    gradBt.addColorStop(1, 'rgba(0, 255, 136, 0.0)');

    backtestEquityChart = new Chart(ctxBt, {
        type: 'line',
        data: {
            labels: [],
            datasets: [{
                label: 'Backtest Equity (¥)',
                data: [],
                borderColor: '#00ff88',
                backgroundColor: gradBt,
                borderWidth: 2,
                pointRadius: 0,
                pointHoverRadius: 5,
                fill: true,
                tension: 0.1
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
                    bodyColor: '#00ff88',
                    borderColor: 'rgba(0, 255, 136, 0.4)',
                    borderWidth: 1,
                    padding: 12,
                    callbacks: {
                        label: (ctx) => `累積損益: ¥${ctx.parsed.y.toLocaleString()}`
                    }
                }
            },
            scales: {
                x: {
                    grid: { color: 'rgba(255, 255, 255, 0.04)' },
                    ticks: { color: '#8899a6', font: { family: 'JetBrains Mono', size: 10 }, maxTicksLimit: 12 }
                },
                y: {
                    grid: { color: 'rgba(255, 255, 255, 0.04)' },
                    ticks: {
                        color: '#8899a6',
                        font: { family: 'JetBrains Mono', size: 10 },
                        callback: (v) => '¥' + v.toLocaleString()
                    }
                }
            }
        }
    });

    // 2. Monthly PnL Bar Chart
    const ctxM = document.getElementById('monthlyChart').getContext('2d');
    monthlyChart = new Chart(ctxM, {
        type: 'bar',
        data: {
            labels: [],
            datasets: [{
                label: 'Monthly PnL (¥)',
                data: [],
                backgroundColor: [],
                borderRadius: 4
            }]
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: {
                legend: { display: false },
                tooltip: {
                    backgroundColor: 'rgba(18, 24, 38, 0.95)',
                    padding: 10,
                    callbacks: {
                        label: (ctx) => `月間損益: ¥${ctx.parsed.y.toLocaleString()}`
                    }
                }
            },
            scales: {
                x: {
                    grid: { display: false },
                    ticks: { color: '#8899a6', font: { family: 'JetBrains Mono', size: 10 } }
                },
                y: {
                    grid: { color: 'rgba(255, 255, 255, 0.04)' },
                    ticks: {
                        color: '#8899a6',
                        font: { family: 'JetBrains Mono', size: 10 },
                        callback: (v) => '¥' + v.toLocaleString()
                    }
                }
            }
        }
    });
}

let currentJstStart = 16;
let currentJstEnd = 24;

function updateJstPreset(val) {
    if (val === '16-24') {
        currentJstStart = 16;
        currentJstEnd = 24;
        document.getElementById('val-jst-hours').textContent = '16:00 - 24:00';
    } else if (val === '09-24') {
        currentJstStart = 9;
        currentJstEnd = 24;
        document.getElementById('val-jst-hours').textContent = '09:00 - 24:00';
    } else {
        currentJstStart = 0;
        currentJstEnd = 24;
        document.getElementById('val-jst-hours').textContent = '24時間フル稼働';
    }
}

// Run 1-Year Backtest
async function runOneYearBacktest() {
    const btn = document.getElementById('btn-run-backtest');
    btn.disabled = true;
    btn.textContent = '⏳ RUNNING BACKTEST (370,000 TICKS)...';

    const slPips = parseFloat(document.getElementById('param-sl-pips').value);
    const rrRatio = parseFloat(document.getElementById('param-rr-ratio').value);
    const riskPct = parseFloat(document.getElementById('param-risk-pct').value);

    const params = {
        bb_period: 20,
        bb_std_dev: parseFloat(document.getElementById('param-bb-std').value),
        rsi_period: 14,
        rsi_oversold: parseFloat(document.getElementById('param-rsi').value),
        rsi_overbought: 100.0 - parseFloat(document.getElementById('param-rsi').value),
        adx_period: 14,
        adx_threshold: parseFloat(document.getElementById('param-adx').value),
        atr_lookback: 50,
        atr_factor: parseFloat(document.getElementById('param-atr').value),
        pyramidding_max: 2,
        timeout_minutes: parseInt(document.getElementById('param-timeout').value),
        lot_size: 0.20,
        stop_loss_pips: slPips,
        take_profit_pips: slPips * rrRatio,
        spread_pips: 0.2,
        enable_hour_filter: true,
        start_jst_hour: currentJstStart,
        end_jst_hour: currentJstEnd,
        initial_balance: 100000.0,
        risk_percent: riskPct,
        risk_reward_ratio: rrRatio,
        use_dynamic_risk_lot: true
    };

    try {
        const res = await fetch('/api/backtest/run', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(params)
        });
        if (!res.ok) throw new Error('Backtest failed');
        const data = await res.json();
        updateBacktestUI(data.result, data.ai_report);
    } catch (err) {
        alert('バックテスト実行エラー: ' + err.message);
    } finally {
        btn.disabled = false;
        btn.textContent = '🚀 1年バックテスト実行';
    }
}

// Update Backtest UI elements
function updateBacktestUI(r, ai) {
    if (!r) return;

    document.getElementById('bt-kpi-profit').textContent = `${r.total_profit >= 0 ? '+' : ''}¥${r.total_profit.toLocaleString()}`;
    document.getElementById('bt-kpi-gross-profit').textContent = `¥${r.gross_profit.toLocaleString()}`;
    document.getElementById('bt-kpi-gross-loss').textContent = `¥${r.gross_loss.toLocaleString()}`;

    document.getElementById('bt-kpi-win-rate').textContent = `${r.win_rate.toFixed(1)}%`;
    document.getElementById('bt-kpi-trades-count').textContent = `${r.total_trades}戦 ${r.winning_trades}勝 ${r.losing_trades}敗`;
    document.getElementById('bt-kpi-avg-profit').textContent = `¥${r.average_profit.toLocaleString()}`;

    document.getElementById('bt-kpi-pf').textContent = r.profit_factor.toFixed(2);
    document.getElementById('bt-kpi-largest-win').textContent = `+¥${r.largest_win.toLocaleString()}`;
    document.getElementById('bt-kpi-largest-loss').textContent = `-¥${Math.abs(r.largest_loss).toLocaleString()}`;

    document.getElementById('bt-kpi-max-dd').textContent = `¥${r.max_drawdown.toLocaleString()} (${r.max_drawdown_pct.toFixed(1)}%)`;

    // Update 1-Year Equity Curve
    if (r.equity_curve && backtestEquityChart) {
        const labels = r.equity_curve.map(pt => pt.time.split('T')[0]);
        const data = r.equity_curve.map(pt => pt.equity);
        backtestEquityChart.data.labels = labels;
        backtestEquityChart.data.datasets[0].data = data;
        backtestEquityChart.update();
    }

    // Update Monthly Breakdown Chart
    if (r.monthly_breakdown && monthlyChart) {
        const mLabels = r.monthly_breakdown.map(m => m.month);
        const mData = r.monthly_breakdown.map(m => m.profit);
        const mColors = mData.map(p => p >= 0 ? '#00ff88' : '#ff3344');
        monthlyChart.data.labels = mLabels;
        monthlyChart.data.datasets[0].data = mData;
        monthlyChart.data.datasets[0].backgroundColor = mColors;
        monthlyChart.update();
    }

    // Update Gemini AI Audit
    if (ai) {
        document.getElementById('bt-ai-rank').textContent = ai.overall_rank || 'S';
        document.getElementById('bt-ai-title').textContent = ai.title || 'AI Backtest Audit';
        document.getElementById('bt-ai-summary').textContent = ai.summary || '';

        const strengthsList = document.getElementById('bt-ai-strengths');
        strengthsList.innerHTML = '';
        (ai.strengths || []).forEach(s => {
            const li = document.createElement('li');
            li.textContent = s;
            strengthsList.appendChild(li);
        });

        const weaknessesList = document.getElementById('bt-ai-weaknesses');
        weaknessesList.innerHTML = '';
        (ai.action_points || ai.weaknesses || []).forEach(w => {
            const li = document.createElement('li');
            li.textContent = w;
            weaknessesList.appendChild(li);
        });
    }
}

// Run Parallel Grid Search Optimization
async function runGridOptimization() {
    const btn = document.getElementById('btn-optimize-backtest');
    btn.disabled = true;
    btn.textContent = '⚡ OPTIMIZING GRID (PARALLEL)...';

    try {
        const res = await fetch('/api/backtest/optimize', { method: 'POST' });
        if (!res.ok) throw new Error('Optimization failed');
        const data = await res.json();
        renderGridRankings(data.rankings || []);
    } catch (err) {
        alert('グリッド最適化エラー: ' + err.message);
    } finally {
        btn.disabled = false;
        btn.textContent = '⚡ グリッド最適化 (PF探索)';
    }
}

function renderGridRankings(rankings) {
    const tbody = document.getElementById('grid-ranking-tbody');
    tbody.innerHTML = '';

    if (rankings.length === 0) {
        tbody.innerHTML = '<tr><td colspan="10" style="text-align:center;">有効な最適化結果が得られませんでした</td></tr>';
        return;
    }

    rankings.forEach(r => {
        const tr = document.createElement('tr');
        const pfHighlight = r.profit_factor >= 1.30 ? 'style="color: var(--accent-gold); font-weight: bold;"' : '';
        tr.innerHTML = `
            <td>#${r.rank}</td>
            <td ${pfHighlight}>${r.profit_factor.toFixed(2)}</td>
            <td>${r.win_rate.toFixed(1)}%</td>
            <td style="color: ${r.total_profit >= 0 ? 'var(--accent-green)' : 'var(--accent-red)'}">¥${r.total_profit.toLocaleString()}</td>
            <td>¥${r.max_drawdown.toLocaleString()}</td>
            <td>${r.total_trades}</td>
            <td>${r.params.bb_std_dev.toFixed(1)}σ</td>
            <td>${r.params.rsi_oversold}/${r.params.rsi_overbought}</td>
            <td>${r.params.adx_threshold}</td>
            <td>${r.params.timeout_minutes}m</td>
        `;
        tbody.appendChild(tr);
    });
}

function exportBacktestCsv() {
    window.location.href = '/api/backtest/export';
}

// --- Live Monitoring Logic ---
async function fetchMetrics() {
    try {
        const res = await fetch('/api/metrics');
        if (!res.ok) return;
        const m = await res.json();
        updateLiveKPIs(m);
    } catch (e) {
        console.error('Failed to fetch metrics:', e);
    }
}

function updateLiveKPIs(m) {
    document.getElementById('kpi-total-profit').textContent = `${m.total_profit >= 0 ? '+' : ''}¥${m.total_profit.toLocaleString()}`;
    document.getElementById('kpi-gross-profit').textContent = `¥${m.gross_profit.toLocaleString()}`;
    document.getElementById('kpi-gross-loss').textContent = `¥${m.gross_loss.toLocaleString()}`;
    document.getElementById('kpi-win-rate').textContent = `${m.win_rate.toFixed(1)}%`;
    document.getElementById('kpi-trades-count').textContent = `${m.total_trades}戦 ${m.winning_trades}勝 ${m.losing_trades}敗`;
    document.getElementById('kpi-consecutive-wins').textContent = m.consecutive_wins;
    document.getElementById('kpi-profit-factor').textContent = m.profit_factor.toFixed(2);
    document.getElementById('kpi-avg-profit').textContent = `¥${m.avg_trade_profit.toLocaleString()}`;
    document.getElementById('kpi-largest-win').textContent = `¥${m.largest_win.toLocaleString()}`;
    document.getElementById('kpi-max-drawdown').textContent = `¥${m.max_drawdown.toLocaleString()} (${m.max_drawdown_pct.toFixed(1)}%)`;
    document.getElementById('kpi-largest-loss').textContent = `¥${m.largest_loss.toLocaleString()}`;
    document.getElementById('kpi-recommended-lot').textContent = `${m.recommended_lot.toFixed(2)} Lot`;
}

async function fetchTrades() {
    try {
        const res = await fetch('/api/trades');
        if (!res.ok) return;
        const trades = await res.json();
        renderTradesTable(trades);
        updateLiveChart(trades);
    } catch (e) {
        console.error('Failed to fetch trades:', e);
    }
}

function renderTradesTable(trades) {
    const tbody = document.getElementById('trades-table-body');
    const counter = document.getElementById('trades-counter');
    tbody.innerHTML = '';
    counter.textContent = `Showing ${trades.length} trades`;

    trades.slice().reverse().forEach(t => {
        const row = document.createElement('tr');
        const actionBadge = t.action === 'BUY' ? '<span class="badge-buy">BUY</span>' : '<span class="badge-sell">SELL</span>';
        const profitClass = t.profit >= 0 ? 'highlight-green' : 'highlight-red';
        const sign = t.profit >= 0 ? '+' : '';

        row.innerHTML = `
            <td>#${t.ticket}</td>
            <td><strong>${t.symbol}</strong></td>
            <td>${actionBadge}</td>
            <td>${t.lots.toFixed(2)}</td>
            <td>${t.open_price.toFixed(3)}</td>
            <td>${t.close_price.toFixed(3)}</td>
            <td style="color: #8899a6;">${t.open_time}</td>
            <td style="color: #8899a6;">${t.close_time}</td>
            <td class="${profitClass}">${sign}¥${t.profit.toLocaleString()}</td>
            <td style="color: #8899a6; font-size: 11px;">${t.comment}</td>
        `;
        tbody.appendChild(row);
    });
}

function updateLiveChart(trades) {
    if (!equityChart || trades.length === 0) return;
    let running = 0;
    const labels = [];
    const points = [];

    trades.forEach((t, idx) => {
        running += t.profit;
        labels.push(`T${t.ticket}`);
        points.push(running);
    });

    equityChart.data.labels = labels;
    equityChart.data.datasets[0].data = points;
    equityChart.update();
}

async function fetchSignals() {
    try {
        const res = await fetch('/api/signals?limit=15');
        if (!res.ok) return;
        const signals = await res.json();
        renderSignals(signals);
    } catch (e) {
        console.error('Failed to fetch signals:', e);
    }
}

function renderSignals(signals) {
    const list = document.getElementById('signals-list');
    list.innerHTML = '';

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

    const regime = reg.regime ? reg.regime.toUpperCase() : 'CLEAR';
    badge.className = `regime-badge state-${regime.toLowerCase()}`;
    text.textContent = `REGIME: ${regime} (${reg.entry_allowed ? 'ENTRY OK' : 'BLOCKED'})`;

    document.querySelectorAll('.state-pill').forEach(pill => {
        pill.classList.remove('active');
    });
    const activePill = document.querySelector(`.state-pill.state-${regime.toLowerCase()}`);
    if (activePill) activePill.classList.add('active');
}

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

async function toggleKillSwitch() {
    const targetState = !currentKillSwitchState;
    const actionName = targetState ? '緊急停止（キルスイッチ発動）' : 'キルスイッチ解除（通常運用復帰）';
    
    if (!confirm(`システムを「${actionName}」にしますか？`)) {
        return;
    }

    try {
        const res = await fetch('/api/kill-switch', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                active: targetState,
                reason: targetState ? 'Manual Emergency Trigger from Web Cockpit' : 'Manual Normal Reset'
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
        badge.innerHTML = `<span>🚨 KILL: TRIGGERED</span>`;
        btn.textContent = '🔄 RESET';
        btn.style.background = '#445566';
    } else {
        badge.className = 'status-badge killswitch-badge';
        badge.innerHTML = `<span>KILL: NORMAL</span>`;
        btn.textContent = '🚨 KILL';
        btn.style.background = 'linear-gradient(135deg, #ff2244, #bb0022)';
    }
}

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

function connectWebSocket() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}/ws`;
    
    ws = new WebSocket(wsUrl);

    ws.onopen = () => {
        console.log('[WS] Connected to Go Native Real-time Hub');
        const indicator = document.getElementById('chart-refresh-status');
        if (indicator) {
            indicator.textContent = '● Real-time live connected';
            indicator.style.color = '#00ff88';
        }
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
            fetchMetrics();
            fetchSignals();
            fetchTrades();
        } catch (e) {
            console.error('WS parse error:', e);
        }
    };

    ws.onclose = () => {
        console.log('[WS] Disconnected. Reconnecting in 3s...');
        const indicator = document.getElementById('chart-refresh-status');
        if (indicator) {
            indicator.textContent = '○ Reconnecting...';
            indicator.style.color = '#ffaa00';
        }
        setTimeout(connectWebSocket, 3000);
    };
}
