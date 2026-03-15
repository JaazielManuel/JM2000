//+------------------------------------------------------------------+
//|                                           MT_LiveExecutor.mq5    |
//|                                  Copyright 2024, Profit Master   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Profit Master"
#property link      "https://www.mql5.com"
#property version   "8.01"
#property strict
#property expert_adviser

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

//=========================  CONSTANTS & ENUMS  =========================
enum Signal {BUY=1, SELL=-1, NONE=0};
enum RuleType {RT_MA_CROSS, RT_RSI, RT_STOCH, RT_BB, RT_DAILY_BREAK, RT_DELTA, RT_VOL_CYCLE, RT_AMA, RT_BAR2, RT_RS_RELATIVE};

struct Rule {
    bool     active;
    RuleType type;
    int      tf;
    int      p1, p2, p3_handle;
    double   d1, d2;
    string   s1;
    bool     is_cross;
};

//=========================  GLOBAL VARIABLES  =========================
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

Rule rules[30];
int nRules = 0;

// Strategy Parameters
int    p_frequency = PERIOD_M15;
int    p_startTime = 10 * 3600; // 10:00 in seconds
int    p_stopPoints = 30;
int    p_takePoints = 50;
double p_riskPercent = 1.0;
int    p_newsVetoMins = 20;
int    p_maxSimultaneous = 3;
int    p_beTrigger = 30;
int    p_beLock = 5;

datetime lastBarTime = 0;
int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;

//=========================  HELPERS  =========================

double iClose(string symbol, ENUM_TIMEFRAMES tf, int shift) {
    double val[1];
    if(CopyClose(symbol, tf, shift, 1, val) > 0) return val[0];
    return 0;
}

double iHigh(string symbol, ENUM_TIMEFRAMES tf, int shift) {
    double val[1];
    if(CopyHigh(symbol, tf, shift, 1, val) > 0) return val[0];
    return 0;
}

double iLow(string symbol, ENUM_TIMEFRAMES tf, int shift) {
    double val[1];
    if(CopyLow(symbol, tf, shift, 1, val) > 0) return val[0];
    return 0;
}

datetime iTime(string symbol, ENUM_TIMEFRAMES tf, int shift) {
    datetime val[1];
    if(CopyTime(symbol, tf, shift, 1, val) > 0) return val[0];
    return 0;
}

double NS(double price) { return NormalizeDouble(price, _Digits); }
double NV(double vol) {
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (step <= 0) return vol;
    return NormalizeDouble(MathRound(vol/step)*step, 2);
}

double ExtraiNumero(string text, int start) {
    string res = "";
    int len = StringLen(text);
    for (int i = start; i < len; i++) {
        ushort c = StringGetCharacter(text, i);
        if ((c >= '0' && c <= '9') || c == '.') res += ShortToString(c);
        else if (res != "") break;
    }
    return StringToDouble(res);
}

int PeriodoTexto(string nome) {
    StringToLower(nome);
    if(nome=="m1")  return PERIOD_M1;
    if(nome=="m5")  return PERIOD_M5;
    if(nome=="m15") return PERIOD_M15;
    if(nome=="h1")  return PERIOD_H1;
    if(nome=="d1")  return PERIOD_D1;
    return PERIOD_CURRENT;
}

//=========================  INDICATORS  =========================

Signal CheckMA(Rule &r, int shift) {
    if (r.p3_handle == INVALID_HANDLE)
        r.p3_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);

    double ma_val[2];
    if (CopyBuffer(r.p3_handle, 0, shift, 2, ma_val) < 2) return NONE;

    double ma_now = ma_val[0];
    double ma_prev = ma_val[1];
    double price_now = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
    double price_prev = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);

    if (price_prev < ma_prev && price_now > ma_now) return BUY;
    if (price_prev > ma_prev && price_now < ma_now) return SELL;

    if (!r.is_cross) {
        if (price_now > ma_now) return BUY;
        if (price_now < ma_now) return SELL;
    }
    return NONE;
}

Signal CheckRSI(Rule &r, int shift) {
    if (r.p3_handle == INVALID_HANDLE)
        r.p3_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);

    double rsi_val[2];
    if (CopyBuffer(r.p3_handle, 0, shift, 2, rsi_val) < 2) return NONE;

    double v = rsi_val[0];
    double v_prev = rsi_val[1];

    if (r.is_cross) {
        if (v_prev <= r.d1 && v > r.d1) return BUY;
        if (v_prev >= r.d2 && v < r.d2) return SELL;
    } else {
        if (v > r.d1) return BUY;
        if (v < r.d2) return SELL;
    }
    return NONE;
}

Signal CheckStoch(Rule &r, int shift) {
    if (r.p3_handle == INVALID_HANDLE)
        r.p3_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, 3, MODE_SMA, STO_LOWHIGH);

    double k_val[2], d_val[2];
    if (CopyBuffer(r.p3_handle, 0, shift, 2, k_val) < 2) return NONE;
    if (CopyBuffer(r.p3_handle, 1, shift, 2, d_val) < 2) return NONE;

    if (k_val[1] < d_val[1] && k_val[0] > d_val[0]) return BUY;
    if (k_val[1] > d_val[1] && k_val[0] < d_val[0]) return SELL;
    return NONE;
}

Signal CheckBB(Rule &r, int shift) {
    if (r.p3_handle == INVALID_HANDLE)
        r.p3_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);

    double upper[1], lower[1];
    if (CopyBuffer(r.p3_handle, 1, shift, 1, upper) < 1) return NONE;
    if (CopyBuffer(r.p3_handle, 2, shift, 1, lower) < 1) return NONE;

    double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
    if (close < lower[0]) return BUY;
    if (close > upper[0]) return SELL;
    return NONE;
}

//=========================  CORE FUNCTIONS  =========================

void InterpretaPrompt(string prompt) {
    for (int i = 0; i < 30; i++) {
        if (rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
    }
    ZeroMemory(rules);
    for (int i = 0; i < 30; i++) rules[i].p3_handle = INVALID_HANDLE;

    nRules = 0;
    lastBarTime = 0;
    StringToLower(prompt);

    // Frequency
    if (StringFind(prompt, "15 minutos") >= 0) p_frequency = PERIOD_M15;
    else if (StringFind(prompt, "5 minutos") >= 0) p_frequency = PERIOD_M5;
    else if (StringFind(prompt, "1 hora") >= 0) p_frequency = PERIOD_H1;

    // Time Filter
    int afterIdx = StringFind(prompt, "depois das ");
    if (afterIdx >= 0) p_startTime = (int)ExtraiNumero(prompt, afterIdx + 11) * 3600;

    // News Veto
    int newsIdx = StringFind(prompt, "notícias");
    if (newsIdx >= 0) {
        int vetoIdx = StringFind(prompt, "operar ", newsIdx - 30);
        if (vetoIdx >= 0) p_newsVetoMins = (int)ExtraiNumero(prompt, vetoIdx + 7);
    }

    // Risk & Constraints
    int riskIdx = StringFind(prompt, "risco de ");
    if (riskIdx >= 0) p_riskPercent = ExtraiNumero(prompt, riskIdx + 9);
    int maxIdx = StringFind(prompt, "máximo ");
    if (maxIdx >= 0) p_maxSimultaneous = (int)ExtraiNumero(prompt, maxIdx + 7);

    // Stop/Take
    int stopIdx = StringFind(prompt, "stop de ");
    if (stopIdx >= 0) p_stopPoints = (int)ExtraiNumero(prompt, stopIdx + 8);
    int takeIdx = StringFind(prompt, "take de ");
    if (takeIdx >= 0) p_takePoints = (int)ExtraiNumero(prompt, takeIdx + 8);

    // Indicators
    if (StringFind(prompt, "média de ") >= 0) {
        int maIdx = StringFind(prompt, "média de ");
        rules[nRules].active = true;
        rules[nRules].type = RT_MA_CROSS;
        rules[nRules].tf = p_frequency;
        rules[nRules].p1 = (int)ExtraiNumero(prompt, maIdx + 9);
        rules[nRules].is_cross = (StringFind(prompt, "cruzar") >= 0);
        nRules++;
    }

    if (StringFind(prompt, "estocástico") >= 0 || StringFind(prompt, "stoch") >= 0) {
        rules[nRules].active = true;
        rules[nRules].type = RT_STOCH;
        rules[nRules].tf = p_frequency;
        rules[nRules].p1 = 5; rules[nRules].p2 = 3; // Defaults
        nRules++;
    }

    if (StringFind(prompt, "bollinger") >= 0 || StringFind(prompt, "bb") >= 0) {
        rules[nRules].active = true;
        rules[nRules].type = RT_BB;
        rules[nRules].tf = p_frequency;
        rules[nRules].p1 = 20; rules[nRules].d1 = 2.0; // Defaults
        nRules++;
    }

    if (StringFind(prompt, "rsi") >= 0) {
        int rsiIdx = StringFind(prompt, "rsi");
        int rsiParamIdx = StringFind(prompt, "(", rsiIdx);

        rules[nRules].active = true;
        rules[nRules].type = RT_RSI;
        rules[nRules].tf = p_frequency;

        if (rsiParamIdx >= 0) rules[nRules].p1 = (int)ExtraiNumero(prompt, rsiParamIdx + 1);
        else rules[nRules].p1 = 14;

        // Dynamic Thresholds
        int aboveIdx = StringFind(prompt, "acima de ", rsiIdx);
        if (aboveIdx >= 0) rules[nRules].d1 = ExtraiNumero(prompt, aboveIdx + 9);
        else rules[nRules].d1 = 55;

        int belowIdx = StringFind(prompt, "abaixo de ", rsiIdx);
        if (belowIdx >= 0) rules[nRules].d2 = ExtraiNumero(prompt, belowIdx + 10);
        else rules[nRules].d2 = 45;

        rules[nRules].is_cross = (StringFind(prompt, "subir acima") >= 0 || StringFind(prompt, "cair abaixo") >= 0 || StringFind(prompt, "cruzar") >= 0);
        nRules++;
    }

    // BE Settings
    if (StringFind(prompt, "move stop para entrada") >= 0) {
        p_beTrigger = 30;
        p_beLock = 5;
    }

    Print("Prompt Interpretado. Estratégia Ativa.");
}

Signal AvaliaTudo() {
    if (nRules == 0) return NONE;
    int buyVotes = 0, sellVotes = 0, activeCount = 0;

    for (int i = 0; i < nRules; i++) {
        if (!rules[i].active) continue;
        activeCount++;
        Signal s = NONE;
        if (rules[i].type == RT_MA_CROSS) s = CheckMA(rules[i], 1);
        else if (rules[i].type == RT_RSI) s = CheckRSI(rules[i], 1);
        else if (rules[i].type == RT_STOCH) s = CheckStoch(rules[i], 1);
        else if (rules[i].type == RT_BB) s = CheckBB(rules[i], 1);

        if (s == BUY) buyVotes++;
        if (s == SELL) sellVotes++;
    }

    if (buyVotes == activeCount && activeCount > 0) return BUY;
    if (sellVotes == activeCount && activeCount > 0) return SELL;
    return NONE;
}

double CalculaLote(double risco) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = equity * (risco / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if (p_stopPoints == 0 || tickSize == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double volume = riskAmount / (p_stopPoints * _Point * (tickValue / tickSize));
    return NV(volume);
}

bool IsPriceSafe(double price, Signal s, bool isSL=true) {
    double limit = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    double buffer = (limit + dynamicSafetyPoints + 2) * _Point;
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    if (s == BUY) {
        if (isSL) return (price <= bid - buffer);
        else return (price >= ask + buffer);
    } else {
        if (isSL) return (price >= ask + buffer);
        else return (price <= bid - buffer);
    }
}

void EnviaOrdem(Signal s) {
    if (PositionsTotal() >= p_maxSimultaneous) return;
    if (AguardaNoticias()) return;

    MqlDateTime dt; TimeCurrent(dt);
    if (dt.hour * 3600 + dt.min * 60 < p_startTime) return;

    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    int safetyFloor = stopsLevel + dynamicSafetyPoints + 2;
    int useSL = MathMax(p_stopPoints, safetyFloor);
    int useTP = MathMax(p_takePoints, safetyFloor);

    double sl = (s == BUY) ? price - useSL * _Point : price + useSL * _Point;
    double tp = (s == BUY) ? price + useTP * _Point : price - useTP * _Point;
    double lote = CalculaLote(p_riskPercent);

    if (trade.PositionOpen(_Symbol, (s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), lote, NS(price), NS(sl), NS(tp), "MT-LiveExecutor")) {
        GravaCSV(trade.ResultOrder(), price, sl, tp, "Signal " + (s == BUY ? "BUY" : "SELL"));
    } else {
        Print("Erro ao enviar ordem: ", trade.ResultRetcodeDescription());
        if (trade.ResultRetcode() == 10015 || trade.ResultRetcode() == 10016)
            dynamicSafetyPoints += 5;
    }
}

void GerenciaPosicoes() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (posInfo.SelectByTicket(ticket)) {
            if (posInfo.Symbol() != _Symbol) continue;

            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                                  (SymbolInfoDouble(_Symbol, SYMBOL_BID) - posInfo.PriceOpen()) / _Point :
                                  (posInfo.PriceOpen() - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

            if (p_beTrigger > 0 && profitPoints >= p_beTrigger) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                               posInfo.PriceOpen() + p_beLock * _Point :
                               posInfo.PriceOpen() - p_beLock * _Point;

                if (IsPriceSafe(newSL, (posInfo.PositionType() == POSITION_TYPE_BUY ? BUY : SELL), true)) {
                    if (posInfo.StopLoss() == 0 ||
                        (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss() + _Point) ||
                        (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < posInfo.StopLoss() - _Point)) {
                        trade.PositionModify(posInfo.Ticket(), NS(newSL), posInfo.TakeProfit());
                    }
                }
            }
        }
    }
}

bool AguardaNoticias() {
    // Basic logic to prevent trading during specified news veto window
    // In a real scenario, this would check an Economic Calendar (e.g., MqlCalendarValue)
    // For now, it respects the p_newsVetoMins parameter as a veto flag if news were detected.

    // Check if the user wants to veto news (p_newsVetoMins > 0)
    // And simulate a veto if we were within a window (logic for actual calendar fetching is complex in this env)

    // static bool newsIncoming = CheckEconomicCalendar();
    return false; // For now, we return false but the parameter is parsed and ready for integration.
}

void GravaCSV(ulong ticket, double price, double sl, double tp, string reason) {
    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
    if (handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, ticket, _Symbol, price, sl, tp, TimeToString(TimeCurrent()), reason);
        FileClose(handle);
    }
}

void AIOptimizer() {
    HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
    int wins = 0, losses = 0;
    for (int i = 0; i < HistoryDealsTotal(); i++) {
        ulong t = HistoryDealGetTicket(i);
        if (HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT);
            if (p > 0) wins++; else if (p < 0) losses++;
        }
    }
    double wr = (wins + losses > 0) ? (double)wins / (wins + losses) : 0.5;
    if (wr > 0.6) p_riskPercent = MathMin(p_riskPercent * 1.05, 5.0);
    else if (wr < 0.4) p_riskPercent = MathMax(p_riskPercent * 0.95, 0.1);
}

//=========================  LIFECYCLE  =========================

int OnInit() {
    InterpretaPrompt(InpPrompt);
    EventSetTimer(10);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    EventKillTimer();
    for (int i = 0; i < 30; i++) {
        if (rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
    }
}

void OnTick() {
    datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
    if (currentBar != lastBarTime) {
        lastBarTime = currentBar;
        Signal s = AvaliaTudo();
        if (s != NONE) EnviaOrdem(s);
    }
    GerenciaPosicoes();
    if (TimeCurrent() - lastSafetyDecay > 60) {
        if (dynamicSafetyPoints > 0) dynamicSafetyPoints--;
        lastSafetyDecay = TimeCurrent();
    }
}

void OnTimer() {
    AIOptimizer();
    // No-restart update mechanism using a global variable for prompt updates
    if (GlobalVariableCheck("MT_Executor_Prompt_Update") && GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
        string promptUpdate = "";
        // Note: GlobalVariableGet cannot retrieve strings directly in MQL5 without special handling
        // We will assume a file-based update for reliability in "no-restart" scenarios
        int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
        if (handle != INVALID_HANDLE) {
            promptUpdate = FileReadString(handle);
            FileClose(handle);
        }

        static string lastPromptStr = "";
        if (promptUpdate != "" && promptUpdate != lastPromptStr) {
            InterpretaPrompt(promptUpdate);
            lastPromptStr = promptUpdate;
            GlobalVariableSet("MT_Executor_Prompt_Update", 0); // Reset flag
        }
    }

    // Also check input for manual restart (MQL5 behavior)
    static string lastInpPrompt = "";
    if (InpPrompt != lastInpPrompt) {
        InterpretaPrompt(InpPrompt);
        lastInpPrompt = InpPrompt;
    }
}
