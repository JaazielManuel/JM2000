//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Defines
#define EA_MAGIC 123456
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define LOG_FILE   "MT_LiveExecutor_Log.txt"
#define PROMPT_FILE "prompt.txt"
#define VETO_FILE   "news_veto.txt"
#define CALENDAR_FILE "calendar.txt"

// --- Enums
enum ENUM_SIGNAL { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = -1 };

// --- Structs
struct Rule {
    bool active;
    int type; // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: BarPattern, 10: Relative
    int tf;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle1, handle2;
    int intent; // SIGNAL_BUY or SIGNAL_SELL

    void Reset() {
        active = false;
        type = 0;
        tf = PERIOD_CURRENT;
        p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0;
        s1 = "";
        handle1 = INVALID_HANDLE;
        handle2 = INVALID_HANDLE;
        intent = SIGNAL_NONE;
    }
};

// --- Globals
Rule g_rules[50];
int g_nRules = 0;
CTrade g_trade;
CPositionInfo g_pos;
CSymbolInfo g_symbol;
CAccountInfo g_account;

string g_lastPrompt = "";
datetime g_lastPromptTime = 0;

// Strategy parameters parsed from prompt
double p_risk = 1.0;
int p_stopLoss = 0;
int p_takeProfit = 0;
int p_maxTrades = 3;
int p_breakeven = 0;
int p_breakevenPlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
bool p_martingale = false;
string p_startTime = "00:00";
int p_newsVeto = 20; // minutes
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime g_lastBar = 0;
datetime g_lastStateSave = 0;
datetime g_lastAI = 0;

// Indicators defaults
int lastMA = 20;
int lastRSI = 14;

// --- Forward declarations
void InterpretaPrompt(string prompt);
void ResetStrategy();
void GravaLog(string txt);
void GravaCSV();
void GerenciaPosicoes();
void EnviaOrdem(int signal, string reason);
int AvaliaTudo();
bool AguardaNoticias();
bool IsTimeAllowed();
double CalculaLote(double riskPercent, int slPoints);

//+------------------------------------------------------------------+
//| NLP Parser Functions                                             |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string lowerPrompt = prompt;
    StringToLower(lowerPrompt);
    StringReplace(lowerPrompt, " e ", ".");

    string segments[];
    int nSegments = StringSplit(lowerPrompt, '.', segments);

    int currentIntent = SIGNAL_NONE;

    for(int i = 0; i < nSegments; i++) {
        string seg = segments[i];
        StringTrimLeft(seg);
        StringTrimRight(seg);

        if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
        if(StringFind(seg, "vende") >= 0)  currentIntent = SIGNAL_SELL;

        // Timeframe extraction
        if(StringFind(seg, "cada") >= 0 || StringFind(seg, "gráfico") >= 0) {
            p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(seg);
        }

        // Start time
        if(StringFind(seg, "depois das") >= 0 || StringFind(seg, "início") >= 0 || StringFind(seg, "começar") >= 0) {
            int h=0, m=0;
            int pos = StringFind(seg, "das");
            if(pos >= 0) {
                string timeStr = StringSubstr(seg, pos + 4, 5);
                p_startTime = timeStr;
            }
        }

        // Global Parameters
        int pos;
        if((pos = StringFind(seg, "stop")) >= 0) p_stopLoss = (int)ExtraiNumero(seg, pos);
        if((pos = StringFind(seg, "take")) >= 0) p_takeProfit = (int)ExtraiNumero(seg, pos);
        if((pos = StringFind(seg, "risco")) >= 0) p_risk = ExtraiNumero(seg, pos);
        if((pos = StringFind(seg, "máximo")) >= 0) p_maxTrades = (int)ExtraiNumero(seg, pos);
        if((pos = StringFind(seg, "notícias")) >= 0) {
            p_newsVeto = (int)ExtraiNumero(seg, pos);
            if(p_newsVeto == 0) p_newsVeto = 20;
        }

        if(StringFind(seg, "martingale") >= 0) p_martingale = true;

        // Breakeven
        if((pos = StringFind(seg, "atingir")) >= 0 && StringFind(seg, "move stop") >= 0) {
            p_breakeven = (int)ExtraiNumero(seg, pos);
            p_breakevenPlus = (int)ExtraiNumero(seg, pos);
        }

        // Trailing
        if((pos = StringFind(seg, "trailing")) >= 0) {
            p_trailingStop = (int)ExtraiNumero(seg, pos);
            p_trailingStep = (int)ExtraiNumero(seg, pos);
        }

        // Add Indicator Rules
        if(currentIntent != SIGNAL_NONE) {
            AddRule(seg, currentIntent);
        }
    }

    GravaLog("Estratégia atualizada: " + prompt);
    g_lastPrompt = prompt;
}

void AddRule(string txt, int intent) {
    if(g_nRules >= 50) return;
    Rule r;
    r.Reset();
    r.intent = intent;
    r.tf = PeriodoTexto(txt);

    // 1. Moving Average
    if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
        int cursor = StringFind(txt, "média");
        if(cursor < 0) cursor = StringFind(txt, "ma");
        r.type = 1;
        r.p1 = (int)ExtraiNumero(txt, cursor);
        if(r.p1 == 0) r.p1 = lastMA;
        lastMA = r.p1;
        r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) {
            r.active = true;
            g_rules[g_nRules++] = r;
        }
    }

    // 2. RSI
    if(StringFind(txt, "rsi") >= 0) {
        int cursor = StringFind(txt, "rsi") + 3;
        r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt);
        r.type = 2;
        r.p1 = (int)ExtraiNumero(txt, cursor);
        if(r.p1 == 0) r.p1 = lastRSI;
        lastRSI = r.p1;
        r.d1 = ExtraiNumero(txt, cursor); // threshold
        r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) {
            r.active = true;
            g_rules[g_nRules++] = r;
        }
    }

    // 3. Stochastic
    if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
        r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt);
        r.type = 3;
        r.p1 = 5; r.p2 = 3; r.p3 = 3;
        r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
        if(r.handle1 != INVALID_HANDLE) {
            r.active = true;
            g_rules[g_nRules++] = r;
        }
    }

    // 4. Bollinger Bands
    if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
        r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt);
        r.type = 4;
        r.p1 = 20; r.d1 = 2.0;
        r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) {
            r.active = true;
            g_rules[g_nRules++] = r;
        }
    }

    // 5. Daily Breakout
    if(StringFind(txt, "rompimento diário") >= 0 || StringFind(txt, "daily break") >= 0) {
        r.Reset(); r.intent = intent; r.tf = PERIOD_D1;
        r.type = 5;
        r.active = true;
        g_rules[g_nRules++] = r;
    }

    // 6. Delta Aggression
    if(StringFind(txt, "agressão") >= 0 || StringFind(txt, "delta") >= 0) {
        r.Reset(); r.intent = intent;
        r.type = 6;
        r.p1 = 60; r.p2 = 300;
        r.active = true;
        g_rules[g_nRules++] = r;
    }

    // 7. Volume Cycle
    if(StringFind(txt, "volume") >= 0) {
        r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt);
        r.type = 7;
        r.p1 = 12;
        r.active = true;
        g_rules[g_nRules++] = r;
    }

    // 8. AMA
    if(StringFind(txt, "ama") >= 0) {
        r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt);
        r.type = 8;
        r.p1 = 10; r.p2 = 2; r.p3 = 30;
        r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, 0, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) {
            r.active = true;
            g_rules[g_nRules++] = r;
        }
    }

    // 9. 2-Bar Pattern
    if(StringFind(txt, "padrão de barras") >= 0 || StringFind(txt, "inside bar") >= 0 || StringFind(txt, "outside bar") >= 0) {
        r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt);
        r.type = 9;
        r.active = true;
        g_rules[g_nRules++] = r;
    }

    // 10. Relative Strength
    if(StringFind(txt, "força relativa") >= 0) {
        r.Reset(); r.intent = intent; r.tf = PeriodoTexto(txt);
        r.type = 10;
        r.s1 = "US30"; r.p1 = 14;
        r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        r.handle2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE && r.handle2 != INVALID_HANDLE) {
            r.active = true;
            g_rules[g_nRules++] = r;
        }
    }
}

double ExtraiNumero(string txt, int &cursor) {
    string n = "";
    bool found = false;
    for(int i = cursor; i < StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') n += "."; else n += StringSubstr(txt, i, 1);
            found = true;
        } else if(found) {
            cursor = i;
            break;
        }
    }
    return StringToDouble(n);
}

int PeriodoTexto(string txt) {
    if(StringFind(txt, "m1") >= 0 && StringFind(txt, "m15") < 0) return PERIOD_M1;
    if(StringFind(txt, "m5") >= 0 && StringFind(txt, "m50") < 0) return PERIOD_M5;
    if(StringFind(txt, "m15") >= 0) return PERIOD_M15;
    if(StringFind(txt, "m30") >= 0) return PERIOD_M30;
    if(StringFind(txt, "h1") >= 0) return PERIOD_H1;
    if(StringFind(txt, "h4") >= 0) return PERIOD_H4;
    if(StringFind(txt, "d1") >= 0) return PERIOD_D1;
    if(StringFind(txt, "minutos") >= 0 || StringFind(txt, "min") >= 0) {
        int c=0; double v = ExtraiNumero(txt, c);
        if(v == 1) return PERIOD_M1;
        if(v == 5) return PERIOD_M5;
        if(v == 15) return PERIOD_M15;
        if(v == 30) return PERIOD_M30;
    }
    return PERIOD_CURRENT;
}

void ResetStrategy() {
    for(int i = 0; i < g_nRules; i++) {
        if(g_rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(g_rules[i].handle1);
        if(g_rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(g_rules[i].handle2);
        g_rules[i].Reset();
    }
    g_nRules = 0;
    p_risk = 1.0; p_stopLoss = 0; p_takeProfit = 0;
    p_maxTrades = 3; p_breakeven = 0; p_trailingStop = 0;
    p_martingale = false; p_startTime = "00:00";
}

//+------------------------------------------------------------------+
//| Signal Engine                                                    |
//+------------------------------------------------------------------+
int AvaliaTudo() {
    int buyVotos = 0, sellVotos = 0;
    int buyRules = 0, sellRules = 0;

    for(int i = 0; i < g_nRules; i++) {
        if(!g_rules[i].active) continue;

        int signal = AvaliaRegra(g_rules[i]);
        if(g_rules[i].intent == SIGNAL_BUY) {
            buyRules++;
            if(signal == SIGNAL_BUY) buyVotos++;
        } else if(g_rules[i].intent == SIGNAL_SELL) {
            sellRules++;
            if(signal == SIGNAL_SELL) sellVotos++;
        }
    }

    if(buyRules > 0 && buyVotos == buyRules) return SIGNAL_BUY;
    if(sellRules > 0 && sellVotos == sellRules) return SIGNAL_SELL;

    return SIGNAL_NONE;
}

int AvaliaRegra(Rule &r) {
    double val1[3], val2[3];
    ArraySetAsSeries(val1, true);
    ArraySetAsSeries(val2, true);

    switch(r.type) {
        case 1: { // MA Cross
            double ma1 = GetBufferValue(r.handle1, 0, 1);
            double ma2 = GetBufferValue(r.handle1, 0, 2);
            double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            if(close2 < ma2 && close1 > ma1) return SIGNAL_BUY;
            if(close2 > ma2 && close1 < ma1) return SIGNAL_SELL;
            break;
        }
        case 2: { // RSI
            double rsi1 = GetBufferValue(r.handle1, 0, 1);
            double rsi2 = GetBufferValue(r.handle1, 0, 2);
            if(r.intent == SIGNAL_BUY && rsi2 < r.d1 && rsi1 > r.d1) return SIGNAL_BUY;
            if(r.intent == SIGNAL_SELL && rsi2 > r.d1 && rsi1 < r.d1) return SIGNAL_SELL;
            break;
        }
        case 3: { // Stoch
            double k1 = GetBufferValue(r.handle1, 0, 1);
            double d1 = GetBufferValue(r.handle1, 1, 1);
            double k2 = GetBufferValue(r.handle1, 0, 2);
            double d2 = GetBufferValue(r.handle1, 1, 2);
            if(k2 < d2 && k1 > d1) return SIGNAL_BUY;
            if(k2 > d2 && k1 < d1) return SIGNAL_SELL;
            break;
        }
        case 4: { // Bollinger
            double mid = GetBufferValue(r.handle1, 0, 1);
            double upper = GetBufferValue(r.handle1, 1, 1);
            double lower = GetBufferValue(r.handle1, 2, 1);
            double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            if(close < lower) return SIGNAL_BUY;
            if(close > upper) return SIGNAL_SELL;
            break;
        }
        case 5: { // Daily Break
            double high = iHigh(_Symbol, PERIOD_D1, 1);
            double low = iLow(_Symbol, PERIOD_D1, 1);
            double close = iClose(_Symbol, PERIOD_M1, 0);
            if(close > high) return SIGNAL_BUY;
            if(close < low) return SIGNAL_SELL;
            break;
        }
        case 6: { // Delta
            MqlTick ticks[];
            int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent()-r.p1, TimeCurrent());
            long buyVol = 0, sellVol = 0;
            for(int i=0; i<n; i++) {
                if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
                else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
            }
            if(buyVol - sellVol > r.p2) return SIGNAL_BUY;
            if(sellVol - buyVol > r.p2) return SIGNAL_SELL;
            break;
        }
        case 7: { // Volume
            long vol[];
            CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1, vol);
            int maxIdx = ArrayMaximum(vol);
            int minIdx = ArrayMinimum(vol);
            if(maxIdx == 0) return SIGNAL_SELL;
            if(minIdx == 0) return SIGNAL_BUY;
            break;
        }
        case 8: { // AMA
            double ama1 = GetBufferValue(r.handle1, 0, 1);
            double ama2 = GetBufferValue(r.handle1, 0, 2);
            if(ama1 > ama2) return SIGNAL_BUY;
            if(ama1 < ama2) return SIGNAL_SELL;
            break;
        }
        case 9: { // 2-Bar Pattern
            double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double h2 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            double l2 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            bool inside = (h1 < h2 && l1 > l2);
            bool outside = (h1 > h2 && l1 < l2);
            if(inside || outside) {
                if(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) return SIGNAL_BUY;
                else return SIGNAL_SELL;
            }
            break;
        }
        case 10: { // Relative RSI
            double rsi1 = GetBufferValue(r.handle1, 0, 1);
            double rsiBench = GetBufferValue(r.handle2, 0, 1);
            if(rsi1 > rsiBench + 5) return SIGNAL_BUY;
            if(rsi1 < rsiBench - 5) return SIGNAL_SELL;
            break;
        }
    }
    return SIGNAL_NONE;
}

double GetBufferValue(int handle, int bufferNum, int shift) {
    double buffer[];
    ArraySetAsSeries(buffer, true);
    if(CopyBuffer(handle, bufferNum, shift, 1, buffer) > 0) return buffer[0];
    return 0;
}

//+------------------------------------------------------------------+
//| Trade and Management Functions                                   |
//+------------------------------------------------------------------+
void EnviaOrdem(int signal, string reason) {
    if(signal == SIGNAL_NONE) return;
    if(PositionsTotal() >= p_maxTrades) return;
    if(AguardaNoticias()) return;
    if(!IsTimeAllowed()) return;

    double lote = CalculaLote(p_risk, p_stopLoss);
    double sl = 0, tp = 0;
    double price = (signal == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(signal == SIGNAL_BUY) {
        if(p_stopLoss > 0) sl = price - p_stopLoss * _Point;
        if(p_takeProfit > 0) tp = price + p_takeProfit * _Point;
        if(g_trade.Buy(lote, _Symbol, price, sl, tp, reason)) {
            GravaLog("COMPRA executada: " + reason + " Lote: " + DoubleToString(lote, 2));
            SendNotification("MT-LiveExecutor: COMPRA " + _Symbol);
        }
    } else {
        if(p_stopLoss > 0) sl = price + p_stopLoss * _Point;
        if(p_takeProfit > 0) tp = price - p_takeProfit * _Point;
        if(g_trade.Sell(lote, _Symbol, price, sl, tp, reason)) {
            GravaLog("VENDA executada: " + reason + " Lote: " + DoubleToString(lote, 2));
            SendNotification("MT-LiveExecutor: VENDA " + _Symbol);
        }
    }
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                                  (SymbolInfoDouble(_Symbol, SYMBOL_BID) - PositionGetDouble(POSITION_PRICE_OPEN)) / _Point :
                                  (PositionGetDouble(POSITION_PRICE_OPEN) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

            // Breakeven
            if(p_breakeven > 0 && profitPoints >= p_breakeven) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                               PositionGetDouble(POSITION_PRICE_OPEN) + p_breakevenPlus * _Point :
                               PositionGetDouble(POSITION_PRICE_OPEN) - p_breakevenPlus * _Point;

                if(PositionGetDouble(POSITION_SL) == 0 ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSL > PositionGetDouble(POSITION_SL)) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < PositionGetDouble(POSITION_SL) || PositionGetDouble(POSITION_SL) == 0))) {
                    g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                               SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_trailingStop * _Point :
                               SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_trailingStop * _Point;

                if(MathAbs(newSL - PositionGetDouble(POSITION_SL)) > p_trailingStep * _Point) {
                    g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

double CalculaLote(double riskPercent, int slPoints) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAbs = capital * riskPercent / 100.0;

    if(p_martingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAbs *= 2;
                break;
            }
        }
    }

    if(slPoints <= 0) slPoints = 100;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double lote = riskAbs / (slPoints * _Point * (tickVal / tickSize));

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lote = MathFloor(lote / step) * step;
    double minLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lote < minLote) lote = minLote;
    if(lote > maxLote) lote = maxLote;

    return lote;
}

bool AguardaNoticias() {
    // Check veto file
    int h = FileOpen(VETO_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string content = FileReadString(h);
        FileClose(h);
        if(StringFind(content, "VETO=1") >= 0) return true;
    }

    // Check calendar
    h = FileOpen(CALENDAR_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        while(!FileIsEnding(h)) {
            string line = FileReadString(h);
            string parts[];
            if(StringSplit(line, ';', parts) >= 4) {
                datetime newsTime = StringToTime(parts[0]);
                if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60 && (parts[2] == "High" || parts[2] == "Alto")) {
                    FileClose(h);
                    return true;
                }
            }
        }
        FileClose(h);
    }

    return false;
}

bool IsTimeAllowed() {
    datetime now = TimeCurrent();
    string nowStr = TimeToString(now, TIME_MINUTES);
    return (nowStr >= p_startTime);
}

void CalculaStats() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, losses = 0;
    double profit = 0, drawdown = 0, maxBalance = AccountInfoDouble(ACCOUNT_BALANCE);

    for(int i = 0; i < total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            profit += p;
            if(p > 0) wins++; else if(p < 0) losses++;
        }
    }
    // Simple log of stats
    // GravaLog("Stats - Wins: " + (string)wins + " Losses: " + (string)losses);
}

//+------------------------------------------------------------------+
//| Event Handlers and Persistence                                   |
//+------------------------------------------------------------------+
int OnInit() {
    g_trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);
    GravaLog("MT-LiveExecutor Iniciado.");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    ResetStrategy();
    EventKillTimer();
    GravaLog("MT-LiveExecutor Finalizado.");
}

void OnTick() {
    GerenciaPosicoes();

    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != g_lastBar) {
        int signal = AvaliaTudo();
        if(signal != SIGNAL_NONE) {
            EnviaOrdem(signal, "Sinal Estratégico");
        }
        g_lastBar = currentBar;
    }

    if(TimeCurrent() - g_lastStateSave >= 5) {
        GravaCSV();
        g_lastStateSave = TimeCurrent();
    }
}

void OnTimer() {
    // Watch for prompt updates
    int h = FileOpen(PROMPT_FILE, FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        datetime lastMod = (datetime)FileGetInteger(h, FILE_MODIFY_DATE);
        if(lastMod > g_lastPromptTime) {
            string prompt = FileReadString(h);
            InterpretaPrompt(prompt);
            g_lastPromptTime = lastMod;
        }
        FileClose(h);
    }

    // AI Optimizer task placeholder
    if(TimeCurrent() - g_lastAI >= 3600) {
        // AIOptimizer();
        g_lastAI = TimeCurrent();
    }
}

void GravaCSV() {
    int h = FileOpen(STATE_FILE, FILE_WRITE|FILE_CSV|FILE_COMMON, ';');
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "PriceOpen", "SL", "TP", "Profit");
        for(int i = 0; i < PositionsTotal(); i++) {
            ulong ticket = PositionGetTicket(i);
            if(PositionSelectByTicket(ticket)) {
                if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
                    FileWrite(h, ticket, _Symbol, PositionGetInteger(POSITION_TYPE),
                              PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL),
                              PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT));
                }
            }
        }
        FileClose(h);
    }
}

void GravaLog(string txt) {
    int h = FileOpen(LOG_FILE, FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWrite(h, TimeToString(TimeLocal(), TIME_DATE|TIME_SECONDS) + ": " + txt);
        FileClose(h);
    }
    Print(txt);
}
