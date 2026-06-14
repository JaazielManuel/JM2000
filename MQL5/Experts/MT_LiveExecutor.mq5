//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MetaTrader Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaTrader Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- CONSTANTS ---
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- ENUMS ---
enum Signal { BUY=1, SELL=-1, NONE=0 };

// --- STRUCTS ---
struct Rule {
    bool active;
    int type;        // 1: MA Cross, 2: RSI, 3: Stoch, 4: BB, 5: Breakout, 6: Delta, 7: Vol, 8: AMA, 9: Bar, 10: RS
    int intent;      // BUY or SELL
    int tf;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle1, handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE) IndicatorRelease(handle2);
        active = false; type = 0; intent = 0; tf = 0;
        p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
        handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
    }
};

// --- GLOBALS ---
Rule rules[MAX_RULES];
int nRules = 0;
string currentPrompt = "";
datetime lastPromptUpdate = 0;

// Strategy Parameters
double p_risk = 1.0;
int p_sl = 0;
int p_tp = 0;
int p_maxTrades = 3;
int p_breakeven = 0;
int p_breakevenPlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
string p_startTime = "00:00";
int p_newsVeto = 20; // minutes
int p_frequency = PERIOD_M15;
bool p_martingale = false;

// Objects
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;

// --- MANDATORY HANDLERS ---

int OnInit()
{
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);
    symInfo.Name(_Symbol);
    for(int i=0; i<MAX_RULES; i++) {
        rules[i].handle1 = INVALID_HANDLE;
        rules[i].handle2 = INVALID_HANDLE;
    }
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
    EventKillTimer();
    ResetStrategy();
}

void OnTick()
{
    GerenciaPosicoes();
    AIOptimizer();

    static datetime lastCSV = 0;
    if(TimeCurrent() - lastCSV > 5) {
        GravaCSV();
        lastCSV = TimeCurrent();
    }

    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
    if(currentBar != lastBar) {
        if(CheckTimeFilter()) {
            Signal s = AvaliaTudo();
            if(s != NONE) EnviaOrdem(s);
        }
        lastBar = currentBar;
    }
}

void OnTimer()
{
    int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE, FILE_COMMON);
        if(mod > lastPromptUpdate) {
            string prompt = "";
            while(!FileIsEnding(handle)) prompt += FileReadString(handle);
            FileClose(handle);

            InterpretaPrompt(prompt);
            lastPromptUpdate = mod;
            GravaLog("Novo prompt carregado: " + prompt);
        } else {
            FileClose(handle);
        }
    }
}

// --- LOGIC ---

void ResetStrategy() {
    for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
    nRules = 0;
}

void InterpretaPrompt(string prompt) {
    if(prompt == "") return;
    ResetStrategy();

    string p = prompt;
    StringToLower(p);
    StringReplace(p, " e ", ".");
    StringReplace(p, ";", ".");

    p_risk = ExtraiNumero(p, "risco", 1.0);
    p_sl = (int)ExtraiNumero(p, "stop", 0);
    p_tp = (int)ExtraiNumero(p, "take", 0);
    p_maxTrades = (int)ExtraiNumero(p, "máximo", 3);
    p_breakeven = (int)ExtraiNumero(p, "breakeven", 0);
    if(p_breakeven == 0) p_breakeven = (int)ExtraiNumero(p, "atingir +", 0);
    p_breakevenPlus = (int)ExtraiNumero(p, "entrada +", 0);
    p_trailingStop = (int)ExtraiNumero(p, "trailing", 0);
    if(p_trailingStop == 0) p_trailingStop = (int)ExtraiNumero(p, "rastreio", 0);
    p_trailingStep = (int)ExtraiNumero(p, "passo", 5);
    p_martingale = (StringFind(p, "martingale") >= 0);

    // Time parsing
    int tPos = StringFind(p, "depois das");
    if(tPos >= 0) {
        string tSub = StringSubstr(p, tPos + 10);
        StringTrimLeft(tSub);
        int h = (int)StringToInteger(tSub);
        p_startTime = (h < 10 ? "0" : "") + IntegerToString(h) + ":00";
    }

    if(StringFind(p, "1 minuto") >= 0 || StringFind(p, "m1") >= 0) p_frequency = PERIOD_M1;
    else if(StringFind(p, "5 minutos") >= 0 || StringFind(p, "m5") >= 0) p_frequency = PERIOD_M5;
    else if(StringFind(p, "15 minutos") >= 0 || StringFind(p, "m15") >= 0) p_frequency = PERIOD_M15;
    else if(StringFind(p, "1 hora") >= 0 || StringFind(p, "h1") >= 0) p_frequency = PERIOD_H1;

    string segments[];
    int n = StringSplit(p, '.', segments);
    int currentIntent = NONE;

    for(int i=0; i<n; i++) {
        string seg = segments[i];
        StringTrimLeft(seg); StringTrimRight(seg);
        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;
        if(currentIntent != NONE) AddRule(seg, currentIntent);
    }
}

void AddRule(string txt, int intent) {
    if(nRules >= MAX_RULES) return;
    static int lastMA = 20;
    static int lastRSI = 14;

    // 1. MA
    if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 1;
        r.p1 = (int)ExtraiNumero(txt, "média", lastMA); if(r.p1 == 0) r.p1 = (int)ExtraiNumero(txt, "ma", lastMA);
        lastMA = r.p1; r.tf = p_frequency;
        r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
    }
    // 2. RSI
    if(StringFind(txt, "rsi") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 2;
        r.p1 = (int)ExtraiNumero(txt, "rsi", lastRSI); lastRSI = r.p1;
        r.d1 = ExtraiNumero(txt, "acima de", 55); r.d2 = ExtraiNumero(txt, "abaixo de", 45);
        r.tf = p_frequency; r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
    }
    // 3. Stoch
    if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 3;
        r.p1 = (int)ExtraiNumero(txt, "k", 5); r.p2 = (int)ExtraiNumero(txt, "d", 3);
        r.tf = p_frequency; r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, 3, MODE_SMA, STO_LOWHIGH);
        if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
    }
    // 4. BB
    if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 4;
        r.p1 = 20; r.d1 = 2.0; r.tf = p_frequency;
        r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
    }
    // 5. Daily Breakout
    if(StringFind(txt, "breakout") >= 0 || StringFind(txt, "diário") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 5;
        r.tf = PERIOD_D1; rules[nRules++] = r;
    }
    // 6. Delta
    if(StringFind(txt, "delta") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 6;
        r.p1 = 60; r.p2 = 300; rules[nRules++] = r;
    }
    // 7. Volume
    if(StringFind(txt, "volume") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 7;
        r.p1 = 12; r.tf = p_frequency; rules[nRules++] = r;
    }
    // 8. AMA
    if(StringFind(txt, "ama") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 8;
        r.p1 = 10; r.tf = p_frequency;
        r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) rules[nRules++] = r;
    }
    // 9. Bar Patterns
    if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "candle") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 9;
        r.tf = p_frequency; rules[nRules++] = r;
    }
    // 10. Relative Strength
    if(StringFind(txt, "força") >= 0 || StringFind(txt, "bench") >= 0) {
        Rule r; r.Reset(); r.active = true; r.intent = intent; r.type = 10;
        r.s1 = "US30"; r.p1 = 14; r.tf = p_frequency;
        r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        r.handle2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE && r.handle2 != INVALID_HANDLE) rules[nRules++] = r;
    }
}

double ExtraiNumero(string txt, string keyword, double defaultVal) {
    int pos = StringFind(txt, keyword);
    if(pos < 0) return defaultVal;
    int start = pos + StringLen(keyword);
    int len = StringLen(txt);
    string res = ""; bool started = false;
    for(int i=start; i<len; i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') c = '.';
            res += ShortToString(c); started = true;
        } else if(started) break;
    }
    return (res == "") ? defaultVal : StringToDouble(res);
}

bool CheckTimeFilter() {
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    int h = (int)StringToInteger(StringSubstr(p_startTime, 0, 2));
    int m = (int)StringToInteger(StringSubstr(p_startTime, 3, 2));
    return (dt.hour > h || (dt.hour == h && dt.min >= m));
}

// --- ENGINE ---

Signal AvaliaTudo() {
    if(nRules == 0) return NONE;
    int buyRules = 0, sellRules = 0, buyVotos = 0, sellVotos = 0;
    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;
        Signal s = AvaliaRegra(rules[i]);
        if(rules[i].intent == BUY) { buyRules++; if(s == BUY) buyVotos++; }
        else if(rules[i].intent == SELL) { sellRules++; if(s == SELL) sellVotos++; }
    }
    if(buyRules > 0 && buyVotos == buyRules) return BUY;
    if(sellRules > 0 && sellVotos == sellRules) return SELL;
    return NONE;
}

Signal AvaliaRegra(Rule &r) {
    if(r.type == 1) { // MA
        double ma0 = GetBufferValue(r.handle1, 0, 0); double ma1 = GetBufferValue(r.handle1, 0, 1);
        double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0); double c1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        if(r.intent == BUY) return (c1 <= ma1 && c0 > ma0) || (c0 > ma0) ? BUY : NONE;
        if(r.intent == SELL) return (c1 >= ma1 && c0 < ma0) || (c0 < ma0) ? SELL : NONE;
    }
    if(r.type == 2) { // RSI
        double rsi = GetBufferValue(r.handle1, 0, 0);
        if(r.intent == BUY && rsi > r.d1) return BUY;
        if(r.intent == SELL && rsi < r.d2) return SELL;
    }
    if(r.type == 3) { // Stoch
        double k = GetBufferValue(r.handle1, 0, 0), d = GetBufferValue(r.handle1, 1, 0);
        return (k > d) ? BUY : SELL;
    }
    if(r.type == 4) { // BB
        double base = GetBufferValue(r.handle1, 0, 0), up = GetBufferValue(r.handle1, 1, 0), lo = GetBufferValue(r.handle1, 2, 0);
        double c = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
        if(c < lo) return BUY; if(c > up) return SELL;
    }
    if(r.type == 5) { // Breakout
        double hi = iHigh(_Symbol, PERIOD_D1, 1), lo = iLow(_Symbol, PERIOD_D1, 1), c = iClose(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
        if(c > hi) return BUY; if(c < lo) return SELL;
    }
    if(r.type == 6) { // Delta
        MqlTick arr[]; int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long b = 0, s = 0; for(int i=0; i<n; i++) if(arr[i].flags&TICK_FLAG_BUY) b++; else s++;
        long delta = b - s; if(delta > r.p2) return BUY; if(delta < -r.p2) return SELL;
    }
    if(r.type == 7) { // Volume
        long v[]; ArraySetAsSeries(v, true); CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1, v);
        int max = ArrayMaximum(v), min = ArrayMinimum(v);
        if(max == 0) return SELL; if(min == 0) return BUY;
    }
    if(r.type == 8) { // AMA
        double ama = GetBufferValue(r.handle1, 0, 0), p = GetBufferValue(r.handle1, 0, 1);
        return (p < ama) ? BUY : SELL;
    }
    if(r.type == 9) { // 2-Bar Pattern
        double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0), l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
        double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1), l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        if(h0 < h1 && l0 > l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0)) ? BUY : SELL;
        if(h0 > h1 && l0 < l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0)) ? SELL : BUY;
    }
    if(r.type == 10) { // RS
        double r1 = GetBufferValue(r.handle1, 0, 0), r2 = GetBufferValue(r.handle2, 0, 0);
        if(r1 > r2 + 5) return BUY; if(r1 < r2 - 5) return SELL;
    }
    return NONE;
}

double GetBufferValue(int handle, int buffer, int index) {
    double val[1]; if(CopyBuffer(handle, buffer, index, 1, val) < 0) return 0; return val[0];
}

// --- TRADE ---

void EnviaOrdem(Signal s) {
    if(PositionsTotal() >= p_maxTrades || AguardaNoticias()) return;
    double lote = CalculaLote(p_risk);
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (p_sl > 0) ? ((s == BUY) ? price - p_sl * _Point : price + p_sl * _Point) : 0;
    double tp = (p_tp > 0) ? ((s == BUY) ? price + p_tp * _Point : price - p_tp * _Point) : 0;
    if(s == BUY) trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor");
    else trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor");
    GravaLog("Ordem enviada: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2));
}

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY), risk = capital * riscoPercent / 100.0;
    if(p_martingale) {
        HistorySelect(0, TimeCurrent());
        for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
            ulong t = HistoryDealGetTicket(i);
            if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) risk *= 2;
                break;
            }
        }
    }
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), slPoints = (p_sl > 0) ? p_sl : 100;
    double lot = risk / (slPoints * _Point * (tickVal / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)));
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lot));
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
            double open = posInfo.PriceOpen(), cur = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl = posInfo.StopLoss(), tp = posInfo.TakeProfit(), pips = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (cur - open)/_Point : (open - cur)/_Point;
            if(p_breakeven > 0 && pips >= p_breakeven) {
                double nSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? open + p_breakevenPlus * _Point : open - p_breakevenPlus * _Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && (sl < nSL || sl == 0)) || (posInfo.PositionType() == POSITION_TYPE_SELL && (sl > nSL || sl == 0))) trade.PositionModify(posInfo.Ticket(), nSL, tp);
            }
            if(p_trailingStop > 0 && pips >= p_trailingStop) {
                double nSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? cur - p_trailingStop * _Point : cur + p_trailingStop * _Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && nSL > sl + p_trailingStep * _Point) || (posInfo.PositionType() == POSITION_TYPE_SELL && (nSL < sl - p_trailingStep * _Point || sl == 0))) trade.PositionModify(posInfo.Ticket(), nSL, tp);
            }
        }
    }
}

// --- HELPERS ---

void GravaLog(string msg) {
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWrite(h, TimeToString(TimeCurrent()) + ": " + msg); FileClose(h); }
}

void GravaCSV() {
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "Lote", "PriceOpen", "SL", "TP", "Profit");
        for(int i=0; i<PositionsTotal(); i++) if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
        FileClose(h);
    }
}

bool AguardaNoticias() {
    if(FileIsExist("news_veto.txt", FILE_COMMON)) return true;
    int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h == INVALID_HANDLE) return false;
    while(!FileIsEnding(h)) {
        string parts[]; StringSplit(FileReadString(h), ';', parts);
        if(ArraySize(parts) > 0 && (StringFind(parts[2], "High") >= 0 || StringFind(parts[2], "Alto") >= 0) && MathAbs(TimeCurrent() - StringToTime(parts[0])) < p_newsVeto * 60) { FileClose(h); return true; }
    }
    FileClose(h); return false;
}

void AIOptimizer() { static datetime lastOpt = 0; if(TimeCurrent() - lastOpt > 3600) lastOpt = TimeCurrent(); }
