//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

#define EA_MAGIC 123456

// --- Global Enums
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

// --- Structs
struct Rule {
    bool    active;
    int     type;
    int     intent;
    int     tf;
    int     p1, p2, p3;
    double  d1, d2;
    string  s1;
    int     handle1, handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        active = false;
        type = 0;
        intent = 0;
        tf = 0;
        p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0;
        s1 = "";
        handle1 = INVALID_HANDLE;
        handle2 = INVALID_HANDLE;
    }
};

// --- Globals
Rule        g_rules[20];
CTrade      g_trade;
CPositionInfo g_pos;
string      g_lastPrompt = "";
datetime    g_lastPromptTime = 0;

// Strategy Parameters
double      p_risk = 1.0;
int         p_stopLoss = 300;
int         p_takeProfit = 500;
int         p_maxTrades = 3;
int         p_beStart = 0;
int         p_bePlus = 0;
int         p_trailingStop = 0;
int         p_trailingStep = 10;
string      p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int         p_newsVeto = 20;

datetime    g_lastBar = 0;
long        g_lastAIOptimizer = 0;
datetime    g_lastCSVUpdate = 0;

// --- MT5-KNOWLEDGE-CORE Signals
Signal RT_MA(int handle, int shift=1) {
    double ma1 = GetBufferValue(handle, 0, shift);
    double ma2 = GetBufferValue(handle, 0, shift+1);
    double close1 = iClose(_Symbol, p_frequency, shift);
    double close2 = iClose(_Symbol, p_frequency, shift+1);
    if(close2 < ma2 && close1 > ma1) return BUY;
    if(close2 > ma2 && close1 < ma1) return SELL;
    return NONE;
}

Signal RT_RSI(int handle, double threshold, int intent, int shift=1) {
    double rsi1 = GetBufferValue(handle, 0, shift);
    double rsi2 = GetBufferValue(handle, 0, shift+1);
    if(intent == 1 && rsi2 < threshold && rsi1 > threshold) return BUY;
    if(intent == -1 && rsi2 > threshold && rsi1 < threshold) return SELL;
    return NONE;
}

Signal RT_Stoch(int handle, int shift=1) {
    double k1 = GetBufferValue(handle, 0, shift);
    double d1 = GetBufferValue(handle, 1, shift);
    double k2 = GetBufferValue(handle, 0, shift+1);
    double d2 = GetBufferValue(handle, 1, shift+1);
    if(k2 < d2 && k1 > d1) return BUY;
    if(k2 > d2 && k1 < d1) return SELL;
    return NONE;
}

Signal RT_Bands(int handle, int shift=1) {
    double upper = GetBufferValue(handle, 1, shift);
    double lower = GetBufferValue(handle, 2, shift);
    double close = iClose(_Symbol, p_frequency, shift);
    if(close < lower) return BUY;
    if(close > upper) return SELL;
    return NONE;
}

Signal RT_DailyBreak(int shift=1) {
    double hi = iHigh(_Symbol, PERIOD_D1, 1);
    double lo = iLow(_Symbol, PERIOD_D1, 1);
    double close = iClose(_Symbol, PERIOD_M1, shift);
    if(close > hi) return BUY;
    if(close < lo) return SELL;
    return NONE;
}

Signal RT_Delta(int seconds, int trigger) {
    MqlTick arr[];
    int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent()-seconds, TimeCurrent());
    long buy=0, sell=0;
    for(int i=0; i<n; i++) if(arr[i].flags & TICK_FLAG_BUY) buy++; else if(arr[i].flags & TICK_FLAG_SELL) sell++;
    long delta = buy - sell;
    if(delta > trigger) return BUY;
    if(delta < -trigger) return SELL;
    return NONE;
}

Signal RT_Volume(int len, int shift=1) {
    long vol[]; ArraySetAsSeries(vol, true);
    if(CopyVolume(_Symbol, p_frequency, shift, len, vol) < len) return NONE;
    int maxIdx = ArrayMaximum(vol);
    int minIdx = ArrayMinimum(vol);
    if(0 == minIdx) return BUY;
    if(0 == maxIdx) return SELL;
    return NONE;
}

Signal RT_AMA(int handle, int shift=1) {
    double ama1 = GetBufferValue(handle, 0, shift);
    double ama2 = GetBufferValue(handle, 0, shift+1);
    if(ama1 > ama2) return BUY;
    if(ama1 < ama2) return SELL;
    return NONE;
}

Signal RT_Bar2(int shift=1) {
    double h0=iHigh(_Symbol, p_frequency, shift);
    double l0=iLow(_Symbol, p_frequency, shift);
    double h1=iHigh(_Symbol, p_frequency, shift+1);
    double l1=iLow(_Symbol, p_frequency, shift+1);
    if(h0<h1 && l0>l1) return (iClose(_Symbol, p_frequency, shift) > iOpen(_Symbol, p_frequency, shift)) ? BUY : SELL;
    if(h0>h1 && l0<l1) return (iClose(_Symbol, p_frequency, shift) > iOpen(_Symbol, p_frequency, shift)) ? SELL : BUY;
    return NONE;
}

Signal RT_Relative(int h1, int h2, int shift=1) {
    double r1 = GetBufferValue(h1, 0, shift);
    double r2 = GetBufferValue(h2, 0, shift);
    if(r1 > r2 + 5) return BUY;
    if(r1 < r2 - 5) return SELL;
    return NONE;
}

// --- NLP Parser Functions
void InterpretaPrompt(string prompt) {
    if(prompt == "") return;
    ResetStrategy();
    g_lastPrompt = prompt;

    string work = prompt;
    StringReplace(work, " e ", ".");
    string segments[];
    StringSplit(work, '.', segments);

    int currentIntent = 0;

    for(int i=0; i<ArraySize(segments); i++) {
        string txt = segments[i];
        StringToLower(txt);
        StringTrimLeft(txt);
        StringTrimRight(txt);

        if(StringFind(txt, "compra") >= 0) currentIntent = 1;
        else if(StringFind(txt, "venda") >= 0 || StringFind(txt, "vende") >= 0) currentIntent = -1;

        int cursor = 0;
        if(StringFind(txt, "risco") >= 0) { cursor = StringFind(txt, "risco"); p_risk = ExtraiNumero(txt, cursor); }
        if(StringFind(txt, "stop") >= 0) { cursor = StringFind(txt, "stop"); p_stopLoss = (int)ExtraiNumero(txt, cursor); }
        if(StringFind(txt, "take") >= 0) { cursor = StringFind(txt, "take"); p_takeProfit = (int)ExtraiNumero(txt, cursor); }
        if(StringFind(txt, "máximo") >= 0) { cursor = StringFind(txt, "máximo"); p_maxTrades = (int)ExtraiNumero(txt, cursor); }

        if(StringFind(txt, "minutos") >= 0 || StringFind(txt, "min") >= 0) {
             cursor = 0;
             int m = (int)ExtraiNumero(txt, cursor);
             if(m == 1) p_frequency = PERIOD_M1;
             else if(m == 5) p_frequency = PERIOD_M5;
             else if(m == 15) p_frequency = PERIOD_M15;
             else if(m == 30) p_frequency = PERIOD_M30;
        }

        if(StringFind(txt, "depois das") >= 0 || StringFind(txt, "início") >= 0) {
            cursor = (StringFind(txt, "depois das") >= 0) ? StringFind(txt, "depois das") : StringFind(txt, "início");
            int h = (int)ExtraiNumero(txt, cursor);
            p_startTime = StringFormat("%02d:00", h);
        }

        if(StringFind(txt, "atingir") >= 0) { cursor = StringFind(txt, "atingir"); p_beStart = (int)ExtraiNumero(txt, cursor); }
        if(StringFind(txt, "entrada") >= 0) { cursor = StringFind(txt, "entrada"); p_bePlus = (int)ExtraiNumero(txt, cursor); }
        if(StringFind(txt, "trailing") >= 0) { cursor = StringFind(txt, "trailing"); p_trailingStop = (int)ExtraiNumero(txt, cursor); }
        if(StringFind(txt, "notícias") >= 0) { cursor = StringFind(txt, "notícias"); p_newsVeto = (int)ExtraiNumero(txt, cursor); }

        AddRule(txt, currentIntent);
    }
    GravaLog("Prompt interpretado: " + prompt);
}

void AddRule(string txt, int intent) {
    int idx = -1;
    for(int i=0; i<20; i++) if(!g_rules[i].active) { idx = i; break; }
    if(idx == -1) return;

    int cursor = 0;
    if(StringFind(txt, "média") >= 0) {
        cursor = StringFind(txt, "média");
        g_rules[idx].active = true; g_rules[idx].type = 1; g_rules[idx].intent = intent;
        g_rules[idx].p1 = (int)ExtraiNumero(txt, cursor);
        g_rules[idx].handle1 = iMA(_Symbol, p_frequency, g_rules[idx].p1, 0, MODE_EMA, PRICE_CLOSE);
    }
    else if(StringFind(txt, "rsi") >= 0) {
        cursor = StringFind(txt, "rsi");
        g_rules[idx].active = true; g_rules[idx].type = 2; g_rules[idx].intent = intent;
        g_rules[idx].p1 = (int)ExtraiNumero(txt, cursor);
        g_rules[idx].d1 = ExtraiNumero(txt, cursor);
        g_rules[idx].handle1 = iRSI(_Symbol, p_frequency, g_rules[idx].p1, PRICE_CLOSE);
    }
    else if(StringFind(txt, "estocástico") >= 0) {
        cursor = StringFind(txt, "estocástico");
        g_rules[idx].active = true; g_rules[idx].type = 3; g_rules[idx].intent = intent;
        g_rules[idx].p1 = (int)ExtraiNumero(txt, cursor); // K
        g_rules[idx].p2 = (int)ExtraiNumero(txt, cursor); // D
        g_rules[idx].p3 = (int)ExtraiNumero(txt, cursor); // Slowing
        g_rules[idx].handle1 = iStochastic(_Symbol, p_frequency, g_rules[idx].p1, g_rules[idx].p2, g_rules[idx].p3, MODE_SMA, STO_LOWHIGH);
    }
    else if(StringFind(txt, "bollinger") >= 0) {
        cursor = StringFind(txt, "bollinger");
        g_rules[idx].active = true; g_rules[idx].type = 4; g_rules[idx].intent = intent;
        g_rules[idx].p1 = (int)ExtraiNumero(txt, cursor); // Period
        g_rules[idx].d1 = ExtraiNumero(txt, cursor);      // Dev
        g_rules[idx].handle1 = iBands(_Symbol, p_frequency, g_rules[idx].p1, 0, g_rules[idx].d1, PRICE_CLOSE);
    }
    else if(StringFind(txt, "breakout") >= 0) {
        g_rules[idx].active = true; g_rules[idx].type = 5; g_rules[idx].intent = intent;
    }
    else if(StringFind(txt, "delta") >= 0) {
        cursor = StringFind(txt, "delta");
        g_rules[idx].active = true; g_rules[idx].type = 6; g_rules[idx].intent = intent;
        g_rules[idx].p1 = (int)ExtraiNumero(txt, cursor); // seconds
        g_rules[idx].p2 = (int)ExtraiNumero(txt, cursor); // trigger
    }
    else if(StringFind(txt, "volume") >= 0) {
        cursor = StringFind(txt, "volume");
        g_rules[idx].active = true; g_rules[idx].type = 7; g_rules[idx].intent = intent;
        g_rules[idx].p1 = (int)ExtraiNumero(txt, cursor); // len
    }
    else if(StringFind(txt, "ama") >= 0) {
        cursor = StringFind(txt, "ama");
        g_rules[idx].active = true; g_rules[idx].type = 8; g_rules[idx].intent = intent;
        g_rules[idx].p1 = (int)ExtraiNumero(txt, cursor); // len
        g_rules[idx].handle1 = iAMA(_Symbol, p_frequency, g_rules[idx].p1, 2, 30, 0, PRICE_CLOSE);
    }
    else if(StringFind(txt, "padrão") >= 0) {
        g_rules[idx].active = true; g_rules[idx].type = 9; g_rules[idx].intent = intent;
    }
    else if(StringFind(txt, "força") >= 0) {
        cursor = StringFind(txt, "força");
        g_rules[idx].active = true; g_rules[idx].type = 10; g_rules[idx].intent = intent;
        g_rules[idx].s1 = "US30"; // benchmark
        g_rules[idx].handle1 = iRSI(_Symbol, p_frequency, 14, PRICE_CLOSE);
        g_rules[idx].handle2 = iRSI(g_rules[idx].s1, p_frequency, 14, PRICE_CLOSE);
    }

    if(g_rules[idx].active && g_rules[idx].handle1 == INVALID_HANDLE && g_rules[idx].type != 5 && g_rules[idx].type != 6 && g_rules[idx].type != 7 && g_rules[idx].type != 9) {
        g_rules[idx].active = false;
    }
}

double ExtraiNumero(string txt, int &cursor) {
    string res = ""; bool found = false;
    for(int i=cursor; i<StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') res += "."; else res += CharToString((char)c);
            found = true;
        } else if(found) { cursor = i; break; }
        if(i == StringLen(txt)-1 && found) cursor = StringLen(txt);
    }
    return StringToDouble(res);
}

// --- Signal Evaluation
Signal AvaliaTudo() {
    int buyVotes = 0; int sellVotes = 0;
    int activeBuyRules = 0; int activeSellRules = 0;

    for(int i=0; i<20; i++) {
        if(g_rules[i].active) {
            Signal s = AvaliaRegra(g_rules[i]);
            if(g_rules[i].intent == 1) { activeBuyRules++; if(s == BUY) buyVotes++; }
            else if(g_rules[i].intent == -1) { activeSellRules++; if(s == SELL) sellVotes++; }
        }
    }
    if(activeBuyRules > 0 && buyVotes == activeBuyRules) return BUY;
    if(activeSellRules > 0 && sellVotes == activeSellRules) return SELL;
    return NONE;
}

Signal AvaliaRegra(Rule &r) {
    switch(r.type) {
        case 1: return RT_MA(r.handle1);
        case 2: return RT_RSI(r.handle1, r.d1, r.intent);
        case 3: return RT_Stoch(r.handle1);
        case 4: return RT_Bands(r.handle1);
        case 5: return RT_DailyBreak();
        case 6: return RT_Delta(r.p1, r.p2);
        case 7: return RT_Volume(r.p1);
        case 8: return RT_AMA(r.handle1);
        case 9: return RT_Bar2();
        case 10: return RT_Relative(r.handle1, r.handle2);
    }
    return NONE;
}

double GetBufferValue(int handle, int buffer_num, int shift) {
    double buffer[]; ArraySetAsSeries(buffer, true);
    if(CopyBuffer(handle, buffer_num, shift, 1, buffer) > 0) return buffer[0];
    return 0;
}

// --- Trade Management
void EnviaOrdem(Signal s, double price, double sl_points, double tp_points, double risk_percent) {
    if(PositionsTotal() >= p_maxTrades) return;
    if(AguardaNoticias()) return;

    double lote = CalculaLote(risk_percent, sl_points);
    if(lote <= 0) return;

    if(s == BUY) {
        double sl = (sl_points > 0) ? (price - sl_points * _Point) : 0;
        double tp = (tp_points > 0) ? (price + tp_points * _Point) : 0;
        for(int i=0; i<3; i++) {
            if(g_trade.Buy(lote, _Symbol, price, sl, tp)) { GravaLog("Compra executada"); SendNotification("Compra em " + _Symbol); break; }
            if(g_trade.ResultRetcode() != TRADE_RETCODE_REQUOTES && g_trade.ResultRetcode() != TRADE_RETCODE_OFFQUOTES) break;
            price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }
    } else if(s == SELL) {
        double sl = (sl_points > 0) ? (price + sl_points * _Point) : 0;
        double tp = (tp_points > 0) ? (price - tp_points * _Point) : 0;
        for(int i=0; i<3; i++) {
            if(g_trade.Sell(lote, _Symbol, price, sl, tp)) { GravaLog("Venda executada"); SendNotification("Venda em " + _Symbol); break; }
            if(g_trade.ResultRetcode() != TRADE_RETCODE_REQUOTES && g_trade.ResultRetcode() != TRADE_RETCODE_OFFQUOTES) break;
            price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        }
    }
}

double CalculaLote(double riskPercent, double slPoints) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAbs = capital * riskPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(slPoints <= 0) slPoints = p_stopLoss;
    if(slPoints <= 0) return 0.01;
    double lote = riskAbs / ((slPoints * _Point / tickSize) * tickValue);
    lote = NormalizeDouble(lote, 2);
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    if(lote < minLot) lote = minLot;
    return lote;
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(g_pos.SelectByIndex(i) && g_pos.Magic() == EA_MAGIC && g_pos.Symbol() == _Symbol) {
            double price = g_pos.PriceCurrent(); double openPrice = g_pos.PriceOpen();
            double sl = g_pos.StopLoss(); double profitPoints = (g_pos.PositionType() == POSITION_TYPE_BUY) ? (price - openPrice)/_Point : (openPrice - price)/_Point;
            if(p_beStart > 0 && profitPoints >= p_beStart && (sl == 0 || (g_pos.PositionType() == POSITION_TYPE_BUY ? sl < openPrice : sl > openPrice))) {
                g_trade.PositionModify(g_pos.Ticket(), openPrice + (g_pos.PositionType() == POSITION_TYPE_BUY ? p_bePlus : -p_bePlus) * _Point, g_pos.TakeProfit());
            }
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (g_pos.PositionType() == POSITION_TYPE_BUY) ? (price - p_trailingStop * _Point) : (price + p_trailingStop * _Point);
                if(sl == 0 || (g_pos.PositionType() == POSITION_TYPE_BUY ? newSL > sl + p_trailingStep * _Point : newSL < sl - p_trailingStep * _Point))
                    g_trade.PositionModify(g_pos.Ticket(), newSL, g_pos.TakeProfit());
            }
        }
    }
}

// --- Utility Functions
bool IsTimeAllowed() {
    MqlDateTime dt; TimeCurrent(dt);
    string now = StringFormat("%02d:%02d", dt.hour, dt.min);
    return (now >= p_startTime);
}

void GravaLog(string texto) {
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto); FileClose(h); }
    Print(texto);
}

void GravaCSV() {
    if(TimeCurrent() - g_lastCSVUpdate < 5) return;
    g_lastCSVUpdate = TimeCurrent();
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "Lots", "OpenPrice", "Profit");
        for(int i=0; i<PositionsTotal(); i++) if(g_pos.SelectByIndex(i)) FileWrite(h, g_pos.Ticket(), g_pos.Symbol(), g_pos.PositionType(), g_pos.Volume(), g_pos.PriceOpen(), g_pos.Profit());
        FileClose(h);
    }
}

void CalculaStats() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0; double profit = 0, loss = 0;
    for(int i=0; i<total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(p > 0) { wins++; profit += p; } else if(p < 0) loss -= p;
        }
    }
    GravaLog(StringFormat("Stats: Wins %d, Profit Factor %.2f", wins, (loss > 0 ? profit/loss : profit)));
}

bool AguardaNoticias() {
    int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h == INVALID_HANDLE) return false;
    bool veto = false;
    while(!FileIsEnding(h)) {
        string line = FileReadString(h);
        if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            // Assume format HH:MM - Event
            int cursor = 0; double eventH = ExtraiNumero(line, cursor);
            double eventM = ExtraiNumero(line, cursor);
            datetime eventTime = (datetime)((TimeCurrent()/(24*3600))*(24*3600) + eventH*3600 + eventM*60);
            if(MathAbs(TimeCurrent() - eventTime) < p_newsVeto * 60) { veto = true; break; }
        }
    }
    FileClose(h);
    return veto;
}

void AIPredict() {
    // Advanced AI forecasting logic placeholder
}

void ResetStrategy() { for(int i=0; i<20; i++) g_rules[i].Reset(); }

// --- Event Handlers
int OnInit() { g_trade.SetExpertMagicNumber(EA_MAGIC); EventSetTimer(1); GravaLog("MT-LiveExecutor Iniciado."); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { EventKillTimer(); ResetStrategy(); }
void OnTimer() {
    int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) { string prompt = FileReadString(h); FileClose(h); if(prompt != g_lastPrompt) InterpretaPrompt(prompt); }
    if(TimeCurrent() - g_lastAIOptimizer > 3600) { g_lastAIOptimizer = TimeCurrent(); CalculaStats(); AIPredict(); }
}
void OnTick() {
    GerenciaPosicoes(); GravaCSV();
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != g_lastBar) {
        g_lastBar = currentBar;
        if(IsTimeAllowed()) {
            Signal s = AvaliaTudo();
            if(s == BUY) EnviaOrdem(BUY, SymbolInfoDouble(_Symbol, SYMBOL_ASK), p_stopLoss, p_takeProfit, p_risk);
            else if(s == SELL) EnviaOrdem(SELL, SymbolInfoDouble(_Symbol, SYMBOL_BID), p_stopLoss, p_takeProfit, p_risk);
        }
    }
}
