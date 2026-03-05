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
int atrHandle = INVALID_HANDLE;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;
string currentPrompt = "";
datetime lastExecutionTime = 0;
MqlTick currentTick;

// Optimization & Safety Globals
int      dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
int      tradeBurstCount = 0;
datetime lastBurstReset = 0;
double   avgSpread = 0;

// ---------- NORMALIZATION & SAFETY HELPERS ----------

double NS(double price) { return NormalizeDouble(price, _Digits); }

double NV(double volume) {
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (step <= 0) return volume;
    double vol = MathFloor(volume / step) * step;
    double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if (vol < minVol) vol = minVol;
    if (vol > maxVol) vol = maxVol;
    return NormalizeDouble(vol, 2);
}

bool IsPriceSafe(double price, ENUM_SIGNAL side) {
    double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double freezeLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
    double brokerMin = MathMax(stopsLevel, freezeLevel) + dynamicSafetyPoints + 1;
    double buffer = brokerMin * _Point;

    if (side == SIGNAL_BUY) {
        if (price < currentTick.ask + buffer) return false;
    } else if (side == SIGNAL_SELL) {
        if (price > currentTick.bid - buffer) return false;
    }
    return true;
}

void UpdateSafety() {
    if (TimeCurrent() - lastSafetyDecay >= 60) {
        if (dynamicSafetyPoints > 0) dynamicSafetyPoints--;
        lastSafetyDecay = TimeCurrent();
    }

    // Volatile Market Protection
    if (currentTick.ask > 0 && currentTick.bid > 0) {
        double currentSpread = (currentTick.ask - currentTick.bid) / _Point;
        if (avgSpread == 0) avgSpread = currentSpread;
        else avgSpread = avgSpread * 0.99 + currentSpread * 0.01;

        if (currentSpread > avgSpread * 3.0 && dynamicSafetyPoints < 100) {
            dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 2, 100);
        }
    }
}

bool CanTrade() {
    if (TimeCurrent() - lastBurstReset >= 1) {
        tradeBurstCount = 0;
        lastBurstReset = TimeCurrent();
    }
    if (tradeBurstCount >= 5) return false;
    tradeBurstCount++;
    return true;
}

// ---------- BASE CORE FUNCTIONS (SIGNAL LIBRARY) ----------

// 1. Price vs MA Cross (p2=0 means Price vs MA)
ENUM_SIGNAL CruzamentoMA(int &handle, int &handle2, int p1, int p2, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iMA(_Symbol, tf, p1, 0, MODE_SMA, PRICE_CLOSE);
    double ma[], p1_vals[], p2_vals[];
    ArraySetAsSeries(ma, true); ArraySetAsSeries(p1_vals, true); ArraySetAsSeries(p2_vals, true);

    if (p2 == 0) { // Price vs MA
        if (CopyBuffer(handle, 0, shift, 2, ma) < 2) return SIGNAL_NONE;
        double close[]; ArraySetAsSeries(close, true);
        if (CopyClose(_Symbol, tf, shift, 2, close) < 2) return SIGNAL_NONE;
        if (close[1] < ma[1] && close[0] > ma[0]) return SIGNAL_BUY;
        if (close[1] > ma[1] && close[0] < ma[0]) return SIGNAL_SELL;
    } else { // MA vs MA
        if (handle2 == INVALID_HANDLE) handle2 = iMA(_Symbol, tf, p2, 0, MODE_SMA, PRICE_CLOSE);
        if (CopyBuffer(handle, 0, shift, 2, p1_vals) < 2) return SIGNAL_NONE;
        if (CopyBuffer(handle2, 0, shift, 2, p2_vals) < 2) return SIGNAL_NONE;
        if (p1_vals[1] < p2_vals[1] && p1_vals[0] > p2_vals[0]) return SIGNAL_BUY;
        if (p1_vals[1] > p2_vals[1] && p1_vals[0] < p2_vals[0]) return SIGNAL_SELL;
    }
    return SIGNAL_NONE;
}

// 2. RSI Threshold (Crossover detector)
ENUM_SIGNAL RSIThreshold(int &handle, int period, double over, double under, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iRSI(_Symbol, tf, period, PRICE_CLOSE);
    double rsi[];
    ArraySetAsSeries(rsi, true);
    if (CopyBuffer(handle, 0, shift, 2, rsi) < 2) return SIGNAL_NONE;
    if (rsi[1] < under && rsi[0] >= under) return SIGNAL_BUY;
    if (rsi[1] > over && rsi[0] <= over) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 3. Stochastic Cross
ENUM_SIGNAL StochCross(int &handle, int k, int d, int slowing, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iStochastic(_Symbol, tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);
    double main[], signal[];
    ArraySetAsSeries(main, true); ArraySetAsSeries(signal, true);
    if (CopyBuffer(handle, 0, shift, 2, main) < 2) return SIGNAL_NONE;
    if (CopyBuffer(handle, 1, shift, 2, signal) < 2) return SIGNAL_NONE;
    if (main[1] < signal[1] && main[0] > signal[0]) return SIGNAL_BUY;
    if (main[1] > signal[1] && main[0] < signal[0]) return SIGNAL_SELL;
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

// 6. Delta Aggression
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

// 7. Volume Cycle
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

    // Inside Bar
    if (h0 < h1 && l0 > l1) return (c0 > o0) ? SIGNAL_BUY : SIGNAL_SELL;
    // Outside Bar
    if (h0 > h1 && l0 < l1) return (c0 > o0) ? SIGNAL_SELL : SIGNAL_BUY;
    return SIGNAL_NONE;
}

// 10. Relative Strength Force
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

double ExtraiNumero(string text, string keyword, int startSearch=0) {
    int pos = StringFind(text, keyword, startSearch);
    if (pos < 0) return -1;
    return GetNextNumber(text, pos + StringLen(keyword));
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    StringToLower(nome);
    // Ordered from longest to shortest strings to prevent false matches
    if (StringFind(nome, "15 min") >= 0 || StringFind(nome, "m15") >= 0) return PERIOD_M15;
    if (StringFind(nome, "30 min") >= 0 || StringFind(nome, "m30") >= 0) return PERIOD_M30;
    if (StringFind(nome, "5 min")  >= 0 || StringFind(nome, "m5")  >= 0) return PERIOD_M5;
    if (StringFind(nome, "1 min")  >= 0 || StringFind(nome, "m1")  >= 0) return PERIOD_M1;
    if (StringFind(nome, "4 horas") >= 0 || StringFind(nome, "h4") >= 0) return PERIOD_H4;
    if (StringFind(nome, "1 hora")  >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
    if (StringFind(nome, "diário") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
    StringToLower(prompt);

    // Release existing handles
    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
        if (currentStrategy.rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle2);
    }

    ZeroMemory(currentStrategy);
    currentStrategy.maxTrades = 100; // Default from memory
    currentStrategy.martingaleMultiplier = 1.0;

    Print("MT-LiveExecutor: Interpretando prompt: ", prompt);

    // Timeframe / Interval
    currentStrategy.interval = PeriodoTexto(prompt);

    // Start Hour
    double startHr = ExtraiNumero(prompt, "depois das ");
    if (startHr >= 0) currentStrategy.startHour = (int)startHr;

    // Signals Parsing

    // 1. Price vs MA
    double maPeriod = ExtraiNumero(prompt, "média de ");
    if (maPeriod > 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 1; r.p1 = (int)maPeriod; r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: Preço vs MA(", (int)maPeriod, ")");
    }

    // 2. RSI
    int rsiPos = StringFind(prompt, "rsi");
    if (rsiPos >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 2;
        r.p1 = (int)GetNextNumber(prompt, rsiPos + 3);
        if (r.p1 <= 0) r.p1 = 14;
        r.d1 = 70; r.d2 = 30; // Default

        double valAbove = ExtraiNumero(prompt, "acima de ", rsiPos);
        if (valAbove < 0) valAbove = ExtraiNumero(prompt, "superior a ", rsiPos);
        if (valAbove >= 0) r.d1 = valAbove;

        double valBelow = ExtraiNumero(prompt, "abaixo de ", rsiPos);
        if (valBelow < 0) valBelow = ExtraiNumero(prompt, "inferior a ", rsiPos);
        if (valBelow >= 0) r.d2 = valBelow;

        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        PrintFormat("Regra Adicionada: RSI(%d) níveis %.1f/%.1f", r.p1, r.d1, r.d2);
    }

    // 3. Stochastic
    if (StringFind(prompt, "estocástico") >= 0 || StringFind(prompt, "stoch") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 3; r.p1 = 5; r.p2 = 3; r.p3 = 3; // Defaults
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: Stochastic Cross");
    }

    // 4. Bollinger
    if (StringFind(prompt, "bollinger") >= 0 || StringFind(prompt, "bandas") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 4; r.p1 = 20; r.d1 = 2.0;
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: Bollinger Bounce");
    }

    // 5. Daily Break
    if (StringFind(prompt, "rompimento diário") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 5;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: Daily Breakout");
    }

    // 6. Delta
    if (StringFind(prompt, "delta") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 6;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: Delta Aggression");
    }

    // 7. Volume Cycle
    if (StringFind(prompt, "ciclo de volume") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 7; r.p1 = 12; // Default
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: Volume Cycle");
    }

    // 8. AMA
    if (StringFind(prompt, "ama") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 8; r.p1 = 10; r.p2 = 2; r.p3 = 30; // Defaults
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: AMA");
    }

    // 9. Bar Pattern
    if (StringFind(prompt, "padrão de barras") >= 0 || StringFind(prompt, "inside") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 9;
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: Bar Pattern");
    }

    // 10. Relative Strength
    if (StringFind(prompt, "força relativa") >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.handle2 = INVALID_HANDLE;
        r.active = true; r.type = 10; r.s1 = "US30"; // Default benchmark
        r.p1 = 14;
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
        Print("Regra Adicionada: Relative Strength vs US30");
    }

    // Money Management Parsing
    double sl = ExtraiNumero(prompt, "stop de ");
    if (sl >= 0) currentStrategy.stopLossPoints = (int)sl;

    double tp = ExtraiNumero(prompt, "take de ");
    if (tp >= 0) currentStrategy.takeProfitPoints = (int)tp;

    double risk = ExtraiNumero(prompt, "risco de ");
    if (risk >= 0) currentStrategy.riskPercent = risk;

    double maxT = ExtraiNumero(prompt, "máximo ");
    if (maxT >= 0) currentStrategy.maxTrades = (int)maxT;

    // News Filter
    if (StringFind(prompt, "notícias") >= 0) {
        int nPos = StringFind(prompt, " min");
        if (nPos >= 0) {
            int searchPos = nPos - 1;
            while(searchPos > 0 && (StringGetCharacter(prompt, searchPos) < '0' || StringGetCharacter(prompt, searchPos) > '9')) searchPos--;
            int endNum = searchPos + 1;
            while(searchPos > 0 && (StringGetCharacter(prompt, searchPos) >= '0' && StringGetCharacter(prompt, searchPos) <= '9')) searchPos--;
            currentStrategy.newsVetoMinutes = (int)StringToInteger(StringSubstr(prompt, searchPos, endNum - searchPos));
        } else currentStrategy.newsVetoMinutes = 20;
    }

    // Breakeven
    double beTrigger = ExtraiNumero(prompt, "atingir +");
    if (beTrigger >= 0) currentStrategy.breakevenTriggerPoints = (int)beTrigger;
    double beProfit = ExtraiNumero(prompt, "entrada +");
    if (beProfit >= 0) currentStrategy.breakevenProfitPoints = (int)beProfit;

    // Trailing Stop
    double tsPoints = ExtraiNumero(prompt, "trailing stop de ");
    if (tsPoints >= 0) {
        currentStrategy.trailingStopPoints = (int)tsPoints;
        currentStrategy.trailingStepPoints = 5; // Default
    }

    // Martingale
    if (StringFind(prompt, "martingale") >= 0) {
        currentStrategy.martingaleMultiplier = 2.0; // Default
        double mult = ExtraiNumero(prompt, "multiplicador ");
        if (mult > 0) currentStrategy.martingaleMultiplier = mult;
        PrintFormat("Martingale ativado: x%.1f", currentStrategy.martingaleMultiplier);
    }

    // Hedge
    if (StringFind(prompt, "hedge") >= 0) {
        currentStrategy.isHedge = true;
        Print("Modo Hedge ativado.");
    }

    // Notifications
    if (StringFind(prompt, "notificações") >= 0 || StringFind(prompt, "alertas") >= 0) {
        currentStrategy.notificationsEnabled = true;
        Print("Notificações via Push/Email ativadas.");
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

    if (currentStrategy.notificationsEnabled) {
        SendNotification("MT-LiveExecutor: " + text);
    }
}

void HandleTradeError(string action) {
    uint retCode = trade.ResultRetcode();
    int lastError = GetLastError();
    string msg = StringFormat("ERRO %s: RetCode=%u, LastError=%d", action, retCode, lastError);
    GravaLog(msg);

    // Increase safety on rejection to prevent flooding
    if (retCode == TRADE_RETCODE_REJECT || retCode == TRADE_RETCODE_INVALID_STOPS || retCode == 10017 /* FROZEN */) {
        dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
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
                if (event.importance == CALENDAR_IMPORTANCE_HIGH) {
                    GravaLog("Notícia de alto impacto detectada. Operação vetada.");
                    return true;
                }
            }
        }
    }
    return false;
}

void AIOptimizer() {
    if (atrHandle == INVALID_HANDLE) atrHandle = iATR(_Symbol, PERIOD_H1, 14);
    if (atrHandle == INVALID_HANDLE) return;
    double atr[];
    ArraySetAsSeries(atr, true);
    if (CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
        double currentAtr = atr[0];
        int suggestedSL = (int)(currentAtr / _Point);
        if (suggestedSL > currentStrategy.stopLossPoints * 1.5) {
            PrintFormat("MT-LiveExecutor AI Optimizer: Volatilidade alta (ATR: %.5f). Sugestão SL: %d pts.", currentAtr, suggestedSL);
        }
    }

    // Calculate Win Rate from history
    HistorySelect(TimeCurrent() - 30 * 86400, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, loss = 0;
    for (int i = 0; i < total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if (HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if (profit > 0) wins++;
            else if (profit < 0) loss++;
        }
    }
    if (wins + loss > 0) {
        double wr = (double)wins / (wins + loss) * 100.0;
        PrintFormat("MT-LiveExecutor AI: Win Rate atual: %.1f%%", wr);
    }
}

void SynchronizeClusterSL(ENUM_POSITION_TYPE type) {
    double bestSL = 0;
    bool first = true;

    for (int i = 0; i < PositionsTotal(); i++) {
        ulong ticket = PositionGetTicket(i);
        if (posInfo.SelectByTicket(ticket)) {
            if (posInfo.Magic() == 123456 && posInfo.Symbol() == _Symbol && posInfo.PositionType() == type) {
                double sl = posInfo.StopLoss();
                if (first) { bestSL = sl; first = false; }
                else {
                    if (type == POSITION_TYPE_BUY) bestSL = MathMax(bestSL, sl);
                    else if (type == POSITION_TYPE_SELL) bestSL = (sl == 0) ? bestSL : (bestSL == 0 ? sl : MathMin(bestSL, sl));
                }
            }
        }
    }

    if (bestSL == 0) return;

    for (int i = 0; i < PositionsTotal(); i++) {
        ulong ticket = PositionGetTicket(i);
        if (posInfo.SelectByTicket(ticket)) {
            if (posInfo.Magic() == 123456 && posInfo.Symbol() == _Symbol && posInfo.PositionType() == type) {
                if (NS(posInfo.StopLoss()) != NS(bestSL)) {
                    trade.PositionModify(ticket, NS(bestSL), posInfo.TakeProfit());
                }
            }
        }
    }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
    if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
        if (HistoryDealSelect(trans.deal)) {
            long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
            if (entry == DEAL_ENTRY_IN) {
                ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
                SynchronizeClusterSL(type);
            }
        }
    }
}

ENUM_SIGNAL AvaliaTudo() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if (dt.hour < currentStrategy.startHour) return SIGNAL_NONE;
    if (AguardaNoticias()) return SIGNAL_NONE;
    if (!currentStrategy.isHedge && PositionsTotal() >= currentStrategy.maxTrades) return SIGNAL_NONE;

    int buyVotes = 0, sellVotes = 0;
    int activeRules = 0;

    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (!currentStrategy.rules[i].active) continue;
        activeRules++;
        ENUM_SIGNAL s = SIGNAL_NONE;

        switch(currentStrategy.rules[i].type) {
            case 1: s = CruzamentoMA(currentStrategy.rules[i].handle, currentStrategy.rules[i].handle2, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].timeframe, 1); break;
            case 2: s = RSIThreshold(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].d1, currentStrategy.rules[i].d2, currentStrategy.rules[i].timeframe, 1); break;
            case 3: s = StochCross(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].p3, currentStrategy.rules[i].timeframe, 1); break;
            case 4: s = BBounce(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].d1, currentStrategy.rules[i].timeframe, 1); break;
            case 5: s = DailyBreak(1); break;
            case 6: s = DeltaAggression(60, 300); break;
            case 7: s = VolumeCycle(currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1); break;
            case 8: s = AMACheck(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].p3, currentStrategy.rules[i].timeframe, 1); break;
            case 9: s = Bar2Pattern(currentStrategy.rules[i].timeframe, 1); break;
            case 10: s = RSRelative(currentStrategy.rules[i].handle, currentStrategy.rules[i].handle2, currentStrategy.rules[i].s1, currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1); break;
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

    // Apply Martingale if last trade was loss
    if (currentStrategy.martingaleMultiplier > 1.0) {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());
        int total = HistoryDealsTotal();
        if (total > 0) {
            ulong lastTicket = HistoryDealGetTicket(total - 1);
            if (HistoryDealGetDouble(lastTicket, DEAL_PROFIT) < 0) {
                lot *= currentStrategy.martingaleMultiplier;
            }
        }
    }

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    lot = NormalizeDouble(lot, 2);
    if (lot < minLot) lot = minLot;
    if (lot > maxLot) lot = maxLot;
    return lot;
}

void GerenciaPosicoes() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (posInfo.SelectByTicket(ticket)) {
            if (posInfo.Magic() != 123456 || posInfo.Symbol() != _Symbol) continue;

            double openPrice = posInfo.PriceOpen();
            double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentTick.bid : currentTick.ask;
            double stopLoss = posInfo.StopLoss();
            double takeProfit = posInfo.TakeProfit();

            double noiseThreshold = 1.0 * _Point;

            // Breakeven logic
            if (currentStrategy.breakevenTriggerPoints > 0) {
                if (posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if (currentPrice >= openPrice + currentStrategy.breakevenTriggerPoints * _Point) {
                        double newSL = NS(openPrice + currentStrategy.breakevenProfitPoints * _Point);
                        if (newSL > stopLoss + noiseThreshold) trade.PositionModify(ticket, newSL, takeProfit);
                    }
                } else if (posInfo.PositionType() == POSITION_TYPE_SELL) {
                    if (currentPrice <= openPrice - currentStrategy.breakevenTriggerPoints * _Point) {
                        double newSL = NS(openPrice - currentStrategy.breakevenProfitPoints * _Point);
                        if (newSL < stopLoss - noiseThreshold || stopLoss == 0) trade.PositionModify(ticket, newSL, takeProfit);
                    }
                }
            }

            // Trailing Stop logic
            if (currentStrategy.trailingStopPoints > 0) {
                if (posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if (currentPrice > openPrice + currentStrategy.trailingStopPoints * _Point) {
                        double newSL = NS(currentPrice - currentStrategy.trailingStopPoints * _Point);
                        if (newSL > stopLoss + MathMax(currentStrategy.trailingStepPoints * _Point, noiseThreshold))
                            trade.PositionModify(ticket, newSL, takeProfit);
                    }
                } else if (posInfo.PositionType() == POSITION_TYPE_SELL) {
                    if (currentPrice < openPrice - currentStrategy.trailingStopPoints * _Point) {
                        double newSL = NS(currentPrice + currentStrategy.trailingStopPoints * _Point);
                        if (newSL < stopLoss - MathMax(currentStrategy.trailingStepPoints * _Point, noiseThreshold) || stopLoss == 0)
                            trade.PositionModify(ticket, newSL, takeProfit);
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
    Print("MT-LiveExecutor: Inicializado. Aguardando prompt...");
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    for (int i = 0; i < 30; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) {
            IndicatorRelease(currentStrategy.rules[i].handle);
            currentStrategy.rules[i].handle = INVALID_HANDLE;
        }
        if (currentStrategy.rules[i].handle2 != INVALID_HANDLE) {
            IndicatorRelease(currentStrategy.rules[i].handle2);
            currentStrategy.rules[i].handle2 = INVALID_HANDLE;
        }
    }

    // Release ATR handle from AIOptimizer
    if (atrHandle != INVALID_HANDLE) {
        IndicatorRelease(atrHandle);
        atrHandle = INVALID_HANDLE;
    }

    Print("MT-LiveExecutor: Desativado.");
}

void OnTick() {
    static string lastPrompt = "";
    if (InpPrompt != lastPrompt) {
        InterpretaPrompt(InpPrompt);
        lastPrompt = InpPrompt;
    }

    if (!SymbolInfoTick(_Symbol, currentTick)) return;
    UpdateSafety();

    bool isNewBar = false;
    datetime currentBarTime = iTime(_Symbol, currentStrategy.interval, 0);
    if (currentBarTime != lastExecutionTime) {
        isNewBar = true;
        lastExecutionTime = currentBarTime;
    }

    if (isNewBar) {
        ENUM_SIGNAL sig = AvaliaTudo();
        if (sig != SIGNAL_NONE && CanTrade()) {
            double lot = NV(CalculaLote(currentStrategy.riskPercent));
            double sl = 0, tp = 0;
            double price = (sig == SIGNAL_BUY) ? currentTick.ask : currentTick.bid;

            double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
            double safetyFloor = (stopsLevel + dynamicSafetyPoints + 1);

            if (sig == SIGNAL_BUY) {
                int slPts = (int)MathMax(currentStrategy.stopLossPoints, safetyFloor);
                if (slPts > 0) sl = price - slPts * _Point;
                if (currentStrategy.takeProfitPoints > 0) tp = price + currentStrategy.takeProfitPoints * _Point;

                if (IsPriceSafe(price, sig)) {
                    if (trade.Buy(lot, _Symbol, price, NS(sl), NS(tp), "MT-LiveExecutor BUY"))
                        GravaLog(StringFormat("COMPRA: Lote %.2f, Preço %.5f, SL %.5f, TP %.5f", lot, price, sl, tp));
                    else
                        HandleTradeError("COMPRA");
                }
            } else {
                int slPts = (int)MathMax(currentStrategy.stopLossPoints, safetyFloor);
                if (slPts > 0) sl = price + slPts * _Point;
                if (currentStrategy.takeProfitPoints > 0) tp = price - currentStrategy.takeProfitPoints * _Point;

                if (IsPriceSafe(price, sig)) {
                    if (trade.Sell(lot, _Symbol, price, NS(sl), NS(tp), "MT-LiveExecutor SELL"))
                        GravaLog(StringFormat("VENDA: Lote %.2f, Preço %.5f, SL %.5f, TP %.5f", lot, price, sl, tp));
                    else
                        HandleTradeError("VENDA");
                }
            }
        }
    }

    GerenciaPosicoes();

    static datetime lastAIUpdate = 0;
    if (TimeCurrent() - lastAIUpdate > 3600) {
        AIOptimizer();
        lastAIUpdate = TimeCurrent();
    }
}
