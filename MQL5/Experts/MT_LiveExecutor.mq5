//=========================  MT-LiveExecutor  =========================
// Real-time strategy interpreter for MetaTrader 5
// Translated from Portuguese natural language prompts
// Optimized for Profit Master v8.0 standard (2026)
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- INPUTS ----------
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// ---------- ENUMS & STRUCTS ----------
enum ENUM_SIGNAL { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = -1 };

struct Rule {
    bool active;
    int type;
    ENUM_TIMEFRAMES timeframe;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle;
    int handle2;
};

struct StrategyRules {
    Rule rules[30];
    int nRules;
    ENUM_TIMEFRAMES interval;
    int startHour;
    double riskPercent;
    int stopLossPoints;
    int takeProfitPoints;
    int maxTrades;
    int newsVetoMinutes;
    int breakevenTriggerPoints;
    int breakevenProfitPoints;
    int trailingStopPoints;
    int trailingStepPoints;
    double martingaleMultiplier;
    bool isHedge;
    bool notificationsEnabled;
};

// ---------- GLOBAL VARIABLES ----------
StrategyRules currentStrategy;
int dynamicSafetyPoints = 2; // Self-correcting global variable
datetime lastSafetyDecay = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;
string currentPrompt = "";
datetime lastExecutionTime = 0;
MqlTick currentTick;

// ---------- BASE CORE FUNCTIONS (SIGNAL LIBRARY) ----------

// 1. Price vs MA Cross
ENUM_SIGNAL PriceCrossMA(int &handle, int period, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iMA(_Symbol, tf, period, 0, MODE_SMA, PRICE_CLOSE);
    double ma[], close[];
    ArraySetAsSeries(ma, true); ArraySetAsSeries(close, true);
    if (CopyBuffer(handle, 0, shift, 2, ma) < 2) return SIGNAL_NONE;
    if (CopyClose(_Symbol, tf, shift, 2, close) < 2) return SIGNAL_NONE;
    if (close[1] <= ma[1] && close[0] > ma[0]) return SIGNAL_BUY;
    if (close[1] >= ma[1] && close[0] < ma[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 1b. MA Cross (Fast vs Slow)
ENUM_SIGNAL MACross(int &handleFast, int &handleSlow, int fast, int slow, ENUM_TIMEFRAMES tf, int shift) {
    if (handleFast == INVALID_HANDLE) handleFast = iMA(_Symbol, tf, fast, 0, MODE_EMA, PRICE_CLOSE);
    if (handleSlow == INVALID_HANDLE) handleSlow = iMA(_Symbol, tf, slow, 0, MODE_EMA, PRICE_CLOSE);
    double f[], s[];
    ArraySetAsSeries(f, true); ArraySetAsSeries(s, true);
    if (CopyBuffer(handleFast, 0, shift, 2, f) < 2) return SIGNAL_NONE;
    if (CopyBuffer(handleSlow, 0, shift, 2, s) < 2) return SIGNAL_NONE;
    if (f[1] <= s[1] && f[0] > s[0]) return SIGNAL_BUY;
    if (f[1] >= s[1] && f[0] < s[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 2. RSI Level Check
ENUM_SIGNAL RSICheck(int &handle, int period, double buyLevel, double sellLevel, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iRSI(_Symbol, tf, period, PRICE_CLOSE);
    double rsi[];
    ArraySetAsSeries(rsi, true);
    if (CopyBuffer(handle, 0, shift, 2, rsi) < 2) return SIGNAL_NONE;

    // Se buyLevel > 50 e sellLevel < 50, assumimos lógica de cruzamento (Trend)
    if (buyLevel > 50 && sellLevel < 50) {
        if (rsi[1] <= buyLevel && rsi[0] > buyLevel) return SIGNAL_BUY;
        if (rsi[1] >= sellLevel && rsi[0] < sellLevel) return SIGNAL_SELL;
    }
    // Caso contrário, lógica de níveis fixos (Counter-trend ou sobrecompra/venda)
    else {
        if (rsi[0] < buyLevel) return SIGNAL_BUY;
        if (rsi[0] > sellLevel) return SIGNAL_SELL;
    }
    return SIGNAL_NONE;
}

// 3. Stochastic Cross
ENUM_SIGNAL StochCross(int &handle, int k, int d, int slowing, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iStochastic(_Symbol, tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);
    double main[], signal[];
    ArraySetAsSeries(main, true); ArraySetAsSeries(signal, true);
    if (CopyBuffer(handle, 0, shift, 2, main) < 2) return SIGNAL_NONE;
    if (CopyBuffer(handle, 1, shift, 2, signal) < 2) return SIGNAL_NONE;
    if (main[1] <= signal[1] && main[0] > signal[0]) return SIGNAL_BUY;
    if (main[1] >= signal[1] && main[0] < signal[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 4. Bollinger Bounce
ENUM_SIGNAL BBounce(int &handle, int period, double deviation, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iBands(_Symbol, tf, period, 0, deviation, PRICE_CLOSE);
    double upper[], lower[], close[];
    ArraySetAsSeries(upper, true); ArraySetAsSeries(lower, true); ArraySetAsSeries(close, true);
    if (CopyBuffer(handle, 1, shift, 1, upper) < 1) return SIGNAL_NONE;
    if (CopyBuffer(handle, 2, shift, 1, lower) < 1) return SIGNAL_NONE;
    if (CopyClose(_Symbol, tf, shift, 1, close) < 1) return SIGNAL_NONE;
    if (close[0] < lower[0]) return SIGNAL_BUY;
    if (close[0] > upper[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 5. Daily Breakout
ENUM_SIGNAL DailyBreak(int shift) {
    double hi = iHigh(_Symbol, PERIOD_D1, 1);
    double lo = iLow(_Symbol, PERIOD_D1, 1);
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    if (close > hi) return SIGNAL_BUY;
    if (close < lo) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 6. Delta Aggression (Microestrutura)
ENUM_SIGNAL DeltaAggression(int seconds, int deltaTrigger) {
    MqlTick ticks[];
    int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, (long)((TimeCurrent() - seconds) * 1000), (long)(TimeCurrent() * 1000));
    if (n <= 0) return SIGNAL_NONE;
    long buy = 0, sell = 0;
    for (int i = 0; i < n; i++) {
        if ((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
        else if ((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
    }
    long delta = buy - sell;
    if (delta > deltaTrigger) return SIGNAL_BUY;
    if (delta < -deltaTrigger) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 7. Volume Cycle (Williams)
ENUM_SIGNAL VolumeCycle(int period, ENUM_TIMEFRAMES tf, int shift) {
    long vol[];
    ArraySetAsSeries(vol, true);
    if (CopyTickVolume(_Symbol, tf, shift, period, vol) < period) return SIGNAL_NONE;
    int maxIdx = ArrayMaximum(vol);
    int minIdx = ArrayMinimum(vol);
    if (maxIdx == 0) return SIGNAL_SELL;
    if (minIdx == 0) return SIGNAL_BUY;
    return SIGNAL_NONE;
}

// 8. AMA (Adaptive Moving Average)
ENUM_SIGNAL AMACheck(int &handle, int period, int fast, int slow, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iAMA(_Symbol, tf, period, fast, slow, 0, PRICE_CLOSE);
    double ama[];
    ArraySetAsSeries(ama, true);
    if (CopyBuffer(handle, 0, shift, 2, ama) < 2) return SIGNAL_NONE;
    if (ama[0] > ama[1]) return SIGNAL_BUY;
    if (ama[0] < ama[1]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 9. Bar Pattern (Inside/Outside)
ENUM_SIGNAL Bar2Pattern(ENUM_TIMEFRAMES tf, int shift) {
    double h0 = iHigh(_Symbol, tf, shift);
    double l0 = iLow(_Symbol, tf, shift);
    double c0 = iClose(_Symbol, tf, shift);
    double o0 = iOpen(_Symbol, tf, shift);
    double h1 = iHigh(_Symbol, tf, shift + 1);
    double l1 = iLow(_Symbol, tf, shift + 1);

    if (h0 < h1 && l0 > l1) return (c0 > o0) ? SIGNAL_BUY : SIGNAL_SELL;
    if (h0 > h1 && l0 < l1) return (c0 > o0) ? SIGNAL_SELL : SIGNAL_BUY;
    return SIGNAL_NONE;
}

// 10. Relative Strength
ENUM_SIGNAL RSRelative(int &handle1, int &handle2, string bench, int period, ENUM_TIMEFRAMES tf, int shift) {
    if (handle1 == INVALID_HANDLE) handle1 = iRSI(_Symbol, tf, period, PRICE_CLOSE);
    if (handle2 == INVALID_HANDLE) handle2 = iRSI(bench, tf, period, PRICE_CLOSE);
    double rsi1[], rsi2[];
    ArraySetAsSeries(rsi1, true); ArraySetAsSeries(rsi2, true);
    if (CopyBuffer(handle1, 0, shift, 1, rsi1) < 1) return SIGNAL_NONE;
    if (CopyBuffer(handle2, 0, shift, 1, rsi2) < 1) return SIGNAL_NONE;
    if (rsi1[0] > rsi2[0] + 5) return SIGNAL_BUY;
    if (rsi1[0] < rsi2[0] - 5) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// ---------- INTERPRETER ----------

double GetNextNumber(string text, int startPos) {
    string res = ""; bool started = false;
    for(int i=startPos; i<StringLen(text); i++) {
        ushort c = StringGetCharacter(text, i);
        if((c >= '0' && c <= '9') || c == '.') { res += StringSubstr(text, i, 1); started = true; }
        else if(started) break;
    }
    return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    StringToLower(nome);
    if (StringFind(nome, "m15") >= 0) return PERIOD_M15; // Ordem importa para não confundir m1 com m15
    if (StringFind(nome, "m30") >= 0) return PERIOD_M30;
    if (StringFind(nome, "m1") >= 0 || StringFind(nome, "1 min") >= 0) return PERIOD_M1;
    if (StringFind(nome, "m5") >= 0 || StringFind(nome, "5 min") >= 0) return PERIOD_M5;
    if (StringFind(nome, "h1") >= 0 || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
    if (StringFind(nome, "h4") >= 0 || StringFind(nome, "4 horas") >= 0) return PERIOD_H4;
    if (StringFind(nome, "d1") >= 0 || StringFind(nome, "diário") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
    StringToLower(prompt);

    // Release existing handles
    for (int i = 0; i < 30; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
        if (currentStrategy.rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle2);
    }

    ZeroMemory(currentStrategy);
    for(int i=0; i<30; i++) {
        currentStrategy.rules[i].handle = INVALID_HANDLE;
        currentStrategy.rules[i].handle2 = INVALID_HANDLE;
    }
    currentStrategy.maxTrades = 100;
    currentStrategy.martingaleMultiplier = 1.0;

    Print("MT-LiveExecutor: Interpretando prompt: ", prompt);

    currentStrategy.interval = PeriodoTexto(prompt);

    // Start Hour
    int pos = StringFind(prompt, "depois das ");
    if (pos < 0) pos = StringFind(prompt, "após as ");
    if (pos >= 0) currentStrategy.startHour = (int)GetNextNumber(prompt, pos + 11);

    // Parsing Rules
    // 1. Price vs MA
    pos = StringFind(prompt, "média de ");
    if (pos >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 1; r.p1 = (int)GetNextNumber(prompt, pos + 9);
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    // 1b. MA Cross
    if (StringFind(prompt, "cruzamento de médias") >= 0 || StringFind(prompt, "cruzamento ema") >= 0) {
        int f=0, s=0;
        if (StringScan(prompt, "%*s médias %d/%d", f, s) >= 2 || StringScan(prompt, "%*s ema %d/%d", f, s) >= 2) {
            Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE; r.active = true; r.type = 11; r.p1 = f; r.p2 = s;
            r.timeframe = currentStrategy.interval; currentStrategy.rules[currentStrategy.nRules++] = r;
        }
    }

    // 2. RSI
    pos = StringFind(prompt, "rsi");
    if (pos >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 2; r.p1 = (int)GetNextNumber(prompt, pos + 3);
        if (r.p1 <= 0) r.p1 = 14;
        r.d1 = 70; r.d2 = 30; // Defaults
        int pAbove = StringFind(prompt, "acima de ", pos);
        if (pAbove < 0) pAbove = StringFind(prompt, "superior a ", pos);
        if (pAbove >= 0 && pAbove < pos + 30) r.d1 = GetNextNumber(prompt, pAbove + 9);
        int pBelow = StringFind(prompt, "abaixo de ", pos);
        if (pBelow < 0) pBelow = StringFind(prompt, "inferior a ", pos);
        if (pBelow >= 0 && pBelow < pos + 30) r.d2 = GetNextNumber(prompt, pBelow + 10);
        r.timeframe = currentStrategy.interval; currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    // 3. Stochastic
    if (StringFind(prompt, "estocástico") >= 0 || StringFind(prompt, "stochastic") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 3; r.p1 = 5; r.p2 = 3; r.p3 = 3;
        r.timeframe = currentStrategy.interval; currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    // 4. Bollinger
    if (StringFind(prompt, "bollinger") >= 0 || StringFind(prompt, "bandas") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 4; r.p1 = 20; r.d1 = 2.0;
        r.timeframe = currentStrategy.interval; currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    // 6. Delta
    if (StringFind(prompt, "delta") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 6;
        currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    // 8. AMA
    if (StringFind(prompt, "ama") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 8; r.p1 = 10; r.p2 = 2; r.p3 = 30;
        r.timeframe = currentStrategy.interval; currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    // Money Management
    pos = StringFind(prompt, "stop de ");
    if (pos >= 0) currentStrategy.stopLossPoints = (int)GetNextNumber(prompt, pos + 8);
    pos = StringFind(prompt, "take de ");
    if (pos >= 0) currentStrategy.takeProfitPoints = (int)GetNextNumber(prompt, pos + 8);
    pos = StringFind(prompt, "risco de ");
    if (pos >= 0) currentStrategy.riskPercent = GetNextNumber(prompt, pos + 9);
    pos = StringFind(prompt, "máximo ");
    if (pos >= 0) currentStrategy.maxTrades = (int)GetNextNumber(prompt, pos + 7);

    // News Filter
    if (StringFind(prompt, "notícias") >= 0) {
        pos = StringFind(prompt, " min");
        if (pos >= 0) {
            int search = pos - 1;
            while(search > 0 && (StringGetCharacter(prompt, search) < '0' || StringGetCharacter(prompt, search) > '9')) search--;
            int end = search + 1;
            while(search > 0 && (StringGetCharacter(prompt, search) >= '0' && StringGetCharacter(prompt, search) <= '9')) search--;
            currentStrategy.newsVetoMinutes = (int)StringToInteger(StringSubstr(prompt, search, end - search));
        } else currentStrategy.newsVetoMinutes = 20;
    }

    // Breakeven
    pos = StringFind(prompt, "atingir +");
    if (pos >= 0) currentStrategy.breakevenTriggerPoints = (int)GetNextNumber(prompt, pos + 9);
    pos = StringFind(prompt, "entrada +");
    if (pos >= 0) currentStrategy.breakevenProfitPoints = (int)GetNextNumber(prompt, pos + 9);

    // Trailing Stop
    pos = StringFind(prompt, "trailing stop de ");
    if (pos >= 0) {
        currentStrategy.trailingStopPoints = (int)GetNextNumber(prompt, pos + 17);
        currentStrategy.trailingStepPoints = 5;
    }

    // Martingale
    if (StringFind(prompt, "martingale") >= 0) {
        currentStrategy.martingaleMultiplier = 2.0;
        pos = StringFind(prompt, "multiplicador ");
        if (pos >= 0) currentStrategy.martingaleMultiplier = GetNextNumber(prompt, pos + 14);
    }

    PrintFormat("MT-LiveExecutor: Configuração carregada. Risco: %.1f%%, SL: %d, TP: %d, BE: +%d/+%d, TS: %d",
                currentStrategy.riskPercent, currentStrategy.stopLossPoints, currentStrategy.takeProfitPoints,
                currentStrategy.breakevenTriggerPoints, currentStrategy.breakevenProfitPoints, currentStrategy.trailingStopPoints);
}

// ---------- DECISION & EXECUTION ----------

void GravaLog(string text) {
    string timeStr = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
    PrintFormat("[%s] MT-LiveExecutor: %s", timeStr, text);

    int handle = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ);
    if (handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, timeStr, text);
        FileClose(handle);
    }
}

void HandleTradeError(string action) {
    uint retCode = trade.ResultRetcode();
    int lastError = GetLastError();
    string msg = StringFormat("ERRO %s: RetCode=%u, LastError=%d", action, retCode, lastError);
    GravaLog(msg);
    if (retCode == 10017 || retCode == 10018) { // Frozen or invalid stops
        dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 2, 100);
    }
}

bool IsPriceSafe(double price, ENUM_SIGNAL side, bool isSL = false) {
    double stopsLevel = symbolInfo.StopsLevel();
    double minDistance = (stopsLevel + dynamicSafetyPoints + 1) * _Point;
    if (side == SIGNAL_BUY) {
        if (isSL) return (price <= currentTick.bid - minDistance);
        else return (price >= currentTick.ask + minDistance);
    } else {
        if (isSL) return (price >= currentTick.ask + minDistance);
        else return (price <= currentTick.bid - minDistance);
    }
}

bool AguardaNoticias() {
    if (currentStrategy.newsVetoMinutes <= 0) return false;
    MqlCalendarValue values[];
    datetime from = TimeCurrent() - currentStrategy.newsVetoMinutes * 60;
    datetime to = TimeCurrent() + currentStrategy.newsVetoMinutes * 60;
    if (CalendarValueHistory(values, from, to)) {
        for (int i = 0; i < ArraySize(values); i++) {
            MqlCalendarEvent event;
            if (CalendarEventById(values[i].event_id, event)) {
                if (event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
            }
        }
    }
    return false;
}

void AIOptimizer() {
    static int atrHandle = INVALID_HANDLE;
    if (atrHandle == INVALID_HANDLE) atrHandle = iATR(_Symbol, PERIOD_H1, 14);
    double atr[];
    ArraySetAsSeries(atr, true);
    if (CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
        PrintFormat("MT-LiveExecutor AI: Volatilidade (ATR): %.5f. Sugestão SL: %d pts.", atr[0], (int)(atr[0]/_Point));
    }

    // Estatísticas avançadas
    HistorySelect(TimeCurrent() - 30*86400, TimeCurrent());
    int total = HistoryDealsTotal();
    double profit = 0, loss = 0, maxEquity = 0, currentEquity = 0, maxDD = 0;
    int winCount = 0, lossCount = 0;

    for(int i=0; i<total; i++) {
        ulong t = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_COMMISSION) + HistoryDealGetDouble(t, DEAL_SWAP);
            currentEquity += p;
            if (currentEquity > maxEquity) maxEquity = currentEquity;
            double dd = maxEquity - currentEquity;
            if (dd > maxDD) maxDD = dd;

            if (p > 0) { profit += p; winCount++; }
            else if (p < 0) { loss += MathAbs(p); lossCount++; }
        }
    }
    double pf = (loss > 0) ? profit / loss : profit;
    double wr = (winCount + lossCount > 0) ? (double)winCount / (winCount + lossCount) * 100 : 0;

    PrintFormat("MT-LiveExecutor Stats: WinRate: %.1f%%, Profit Factor: %.2f, MaxDrawdown: %.2f", wr, pf, maxDD);

    // Heurística IA: Ajuste dinâmico de risco
    if (wr < 45 && currentStrategy.riskPercent > 0.5) {
        Print("MT-LiveExecutor AI: WinRate baixo. Sugestão: Reduzir risco para 0.5%.");
    } else if (wr > 60 && currentStrategy.riskPercent < 2.0) {
        Print("MT-LiveExecutor AI: Performance sólida. Sugestão: Aumentar risco para 2.0%.");
    }
}

ENUM_SIGNAL AvaliaCondicoes() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if (dt.hour < currentStrategy.startHour) return SIGNAL_NONE;
    if (AguardaNoticias()) return SIGNAL_NONE;
    if (PositionsTotal() >= currentStrategy.maxTrades) return SIGNAL_NONE;

    int buyVotes = 0, sellVotes = 0, activeRules = 0;
    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (!currentStrategy.rules[i].active) continue;
        activeRules++;
        ENUM_SIGNAL s = SIGNAL_NONE;
        switch(currentStrategy.rules[i].type) {
            case 1: s = PriceCrossMA(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1); break;
            case 2: s = RSICheck(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].d1, currentStrategy.rules[i].d2, currentStrategy.rules[i].timeframe, 1); break;
            case 3: s = StochCross(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].p3, currentStrategy.rules[i].timeframe, 1); break;
            case 4: s = BBounce(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].d1, currentStrategy.rules[i].timeframe, 1); break;
            case 5: s = DailyBreak(1); break;
            case 6: s = DeltaAggression(60, 300); break;
            case 7: s = VolumeCycle(currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1); break;
            case 8: s = AMACheck(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].p3, currentStrategy.rules[i].timeframe, 1); break;
            case 9: s = Bar2Pattern(currentStrategy.rules[i].timeframe, 1); break;
            case 10: s = RSRelative(currentStrategy.rules[i].handle, currentStrategy.rules[i].handle2, currentStrategy.rules[i].s1, currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1); break;
            case 11: s = MACross(currentStrategy.rules[i].handle, currentStrategy.rules[i].handle2, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].timeframe, 1); break;
        }
        if (s == SIGNAL_BUY) buyVotes++;
        if (s == SIGNAL_SELL) sellVotes++;
    }
    if (activeRules > 0) {
        if (buyVotes == activeRules) return SIGNAL_BUY;
        if (sellVotes == activeRules) return SIGNAL_SELL;
    }
    return SIGNAL_NONE;
}

double CalculaLote(double riskPercent) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskMoney = equity * (riskPercent / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    int slPoints = (currentStrategy.stopLossPoints > 0) ? currentStrategy.stopLossPoints : 100;
    double lot = riskMoney / ((slPoints * _Point) * (tickValue / tickSize));
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    lot = NormalizeDouble(lot, 2);
    return MathMax(lot, minLot);
}

void UpdateSafety() {
    if (TimeCurrent() - lastSafetyDecay > 60) {
        if (dynamicSafetyPoints > 2) dynamicSafetyPoints--;
        lastSafetyDecay = TimeCurrent();
    }
}

void GerenciaPosicoes() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (posInfo.SelectByIndex(i)) {
            if (posInfo.Symbol() != _Symbol || posInfo.Magic() != 123456) continue;
            double open = posInfo.PriceOpen();
            double cur = posInfo.PriceCurrent();
            double sl = posInfo.StopLoss();
            double tp = posInfo.TakeProfit();

            // Breakeven logic
            if (currentStrategy.breakevenTriggerPoints > 0) {
                if (posInfo.PositionType() == POSITION_TYPE_BUY && cur >= open + currentStrategy.breakevenTriggerPoints * _Point) {
                    double newSL = NormalizeDouble(open + currentStrategy.breakevenProfitPoints * _Point, _Digits);
                    if (sl < newSL) trade.PositionModify(posInfo.Ticket(), newSL, tp);
                } else if (posInfo.PositionType() == POSITION_TYPE_SELL && cur <= open - currentStrategy.breakevenTriggerPoints * _Point) {
                    double newSL = NormalizeDouble(open - currentStrategy.breakevenProfitPoints * _Point, _Digits);
                    if (sl > newSL || sl == 0) trade.PositionModify(posInfo.Ticket(), newSL, tp);
                }
            }

            // Trailing Stop logic
            if (currentStrategy.trailingStopPoints > 0) {
                if (posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if (cur > open + currentStrategy.trailingStopPoints * _Point) {
                        double newSL = NormalizeDouble(cur - currentStrategy.trailingStopPoints * _Point, _Digits);
                        if (newSL > sl + currentStrategy.trailingStepPoints * _Point) trade.PositionModify(posInfo.Ticket(), newSL, tp);
                    }
                } else if (posInfo.PositionType() == POSITION_TYPE_SELL) {
                    if (cur < open - currentStrategy.trailingStopPoints * _Point) {
                        double newSL = NormalizeDouble(cur + currentStrategy.trailingStopPoints * _Point, _Digits);
                        if ((newSL < sl - currentStrategy.trailingStepPoints * _Point) || sl == 0) trade.PositionModify(posInfo.Ticket(), newSL, tp);
                    }
                }
            }
        }
    }
}

// ---------- SCRIPT LIFECYCLE ----------

int OnInit() {
    symbolInfo.Name(_Symbol);
    trade.SetExpertMagicNumber(123456);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    for (int i = 0; i < 30; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
        if (currentStrategy.rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle2);
    }
}

void OnTick() {
    static string lastPrompt = "";
    if (InpPrompt != lastPrompt) { InterpretaPrompt(InpPrompt); lastPrompt = InpPrompt; }
    if (!SymbolInfoTick(_Symbol, currentTick)) return;

    datetime currentBarTime = iTime(_Symbol, currentStrategy.interval, 0);
    if (currentBarTime != lastExecutionTime) {
        lastExecutionTime = currentBarTime;
        ENUM_SIGNAL sig = AvaliaCondicoes();
        if (sig != SIGNAL_NONE) {
            double lot = CalculaLote(currentStrategy.riskPercent);
            double price = (sig == SIGNAL_BUY) ? currentTick.ask : currentTick.bid;
            double sl = 0, tp = 0;
            if (sig == SIGNAL_BUY) {
                sl = price - currentStrategy.stopLossPoints * _Point;
                tp = price + currentStrategy.takeProfitPoints * _Point;
                if (trade.Buy(lot, _Symbol, price, sl, tp)) GravaLog("COMPRA EXECUTADA"); else HandleTradeError("COMPRA");
            } else {
                sl = price + currentStrategy.stopLossPoints * _Point;
                tp = price - currentStrategy.takeProfitPoints * _Point;
                if (trade.Sell(lot, _Symbol, price, sl, tp)) GravaLog("VENDA EXECUTADA"); else HandleTradeError("VENDA");
            }
        }
    }
    GerenciaPosicoes();
    UpdateSafety();
    if (TimeCurrent() % 3600 == 0) AIOptimizer();
}
