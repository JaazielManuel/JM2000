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
#include <Indicators\Indicators.mqh>

//+------------------------------------------------------------------+
//| 1. DATA STRUCTURES & ENUMS                                       |
//+------------------------------------------------------------------+

enum Signal { BUY = 1, SELL = -1, NONE = 0 };

enum RuleType {
    RULE_MA_CROSS,
    RULE_RSI_THRESHOLD,
    RULE_STOCH_CROSS,
    RULE_BB_BOUNCE,
    RULE_DAILY_BREAK,
    RULE_DELTA_AGG,
    RULE_VOLUME_CYCLE,
    RULE_AMA,
    RULE_BAR_PATTERN,
    RULE_RS_RELATIVE
};

struct Rule {
    bool     active;
    RuleType type;
    int      tf;
    int      p1, p2, p3;
    double   d1, d2;
    string   s1;
    Signal   intent; // Signal intended by this rule (BUY or SELL context)
    bool     is_cross; // True if it's a "crossover" event, false for "state"
    int      p1_handle, p2_handle, p3_handle;
};

//+------------------------------------------------------------------+
//| 2. GLOBAL PARAMETERS & STATE                                     |
//+------------------------------------------------------------------+

Rule rules[30];
int nRules = 0;

// Operational Parameters (Parsed from Prompt)
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_trailingStopPoints = 0;
int      p_breakEvenPoints = 0;
int      p_breakEvenProfit = 50;
int      p_maxSimultaneousTrades = 3;
int      p_newsVetoMinutes = 20;
bool     p_hedge = false;
bool     p_martingale = false;
string   p_startTime = "00:00";
long     p_startTimeSeconds = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// State Variables
int      dynamicSafetyPoints = 0;
datetime lastBarTime = 0;
datetime lastStateSave = 0;
string   lastPrompt = "";
const int EA_MAGIC = 20260101;

// MQL5 Objects
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

//+------------------------------------------------------------------+
//| 3. MT5-KNOWLEDGE-CORE: INDICATOR SIGNAL FUNCTIONS                |
//+------------------------------------------------------------------+

// 3.1 SMA/EMA CROSSOVER
Signal CheckMA(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE || r.p2_handle == INVALID_HANDLE) return NONE;
    double bufF[], bufS[];
    ArraySetAsSeries(bufF, true); ArraySetAsSeries(bufS, true);

    if(CopyBuffer(r.p1_handle, 0, shift, 2, bufF) <= 0) return NONE;
    if(CopyBuffer(r.p2_handle, 0, shift, 2, bufS) <= 0) return NONE;

    if(bufF[1] < bufS[1] && bufF[0] > bufS[0]) return BUY;
    if(bufF[1] > bufS[1] && bufF[0] < bufS[0]) return SELL;
    return NONE;
}

// 3.2 RSI THRESHOLD
Signal CheckRSI(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE) return NONE;
    double val[2];
    ArraySetAsSeries(val, true);
    if(CopyBuffer(r.p1_handle, 0, shift, 2, val) <= 0) return NONE;

    if(r.is_cross)
    {
        if(val[1] < r.d1 && val[0] >= r.d1) return BUY;
        if(val[1] > r.d2 && val[0] <= r.d2) return SELL;
    }
    else
    {
        if(val[0] > r.d1 && r.d1 > 0) return (r.intent == BUY ? BUY : NONE);
        if(val[0] < r.d2 && r.d2 > 0) return (r.intent == SELL ? SELL : NONE);
    }
    return NONE;
}

// 3.3 STOCHASTIC CROSSOVER
Signal CheckStoch(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE) return NONE;
    double k[2], d[2];
    ArraySetAsSeries(k, true); ArraySetAsSeries(d, true);
    if(CopyBuffer(r.p1_handle, 0, shift, 2, k) <= 0) return NONE;
    if(CopyBuffer(r.p1_handle, 1, shift, 2, d) <= 0) return NONE;

    if(k[1] < d[1] && k[0] > d[0]) return BUY;
    if(k[1] > d[1] && k[0] < d[0]) return SELL;
    return NONE;
}

// 3.4 BOLLINGER BANDS BOUNCE
Signal CheckBB(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE) return NONE;
    double up[1], low[1];
    if(CopyBuffer(r.p1_handle, 1, shift, 1, up) <= 0) return NONE;
    if(CopyBuffer(r.p1_handle, 2, shift, 1, low) <= 0) return NONE;

    double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);

    if(close < low[0]) return BUY;
    if(close > up[0]) return SELL;
    return NONE;
}

// 3.5 DAILY BREAKOUT
Signal CheckDailyBreak(Rule &r, int shift=1)
{
    double hi = iHigh(_Symbol, PERIOD_D1, 1);
    double lo = iLow(_Symbol, PERIOD_D1, 1);
    double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);

    if(close > hi) return BUY;
    if(close < lo) return SELL;
    return NONE;
}

// 3.6 DELTA AGGRESSION
Signal CheckDelta(Rule &r)
{
    MqlTick ticks[];
    int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
    if(n <= 0) return NONE;
    long buyVol = 0, sellVol = 0;
    for(int i=0; i<n; i++)
    {
        if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
        else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
    }
    long delta = buyVol - sellVol;
    if(delta > r.p2) return BUY;
    if(delta < -r.p2) return SELL;
    return NONE;
}

// 3.7 VOLUME CYCLE
Signal CheckVolumeCycle(Rule &r, int shift=1)
{
    long vol[];
    ArraySetAsSeries(vol, true);
    if(CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, r.p1, vol) <= 0) return NONE;
    if(ArrayMaximum(vol) == 0) return SELL;
    if(ArrayMinimum(vol) == 0) return BUY;
    return NONE;
}

// 3.8 AMA
Signal CheckAMA(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE) return NONE;
    double val[2];
    ArraySetAsSeries(val, true);
    if(CopyBuffer(r.p1_handle, 0, shift, 2, val) <= 0) return NONE;
    if(val[0] > val[1]) return BUY;
    if(val[0] < val[1]) return SELL;
    return NONE;
}

// 3.9 BAR PATTERN
Signal CheckBarPattern(Rule &r, int shift=1)
{
    double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
    double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
    double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
    double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);

    if(h0 < h1 && l0 > l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) ? BUY : SELL);
    if(h0 > h1 && l0 < l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) ? SELL : BUY);
    return NONE;
}

// 3.10 RS RELATIVE
Signal CheckRS(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE || r.p2_handle == INVALID_HANDLE) return NONE;
    double rsi1[1], rsi2[1];
    if(CopyBuffer(r.p1_handle, 0, shift, 1, rsi1) <= 0) return NONE;
    if(CopyBuffer(r.p2_handle, 0, shift, 1, rsi2) <= 0) return NONE;
    if(rsi1[0] > rsi2[0] + 5) return BUY;
    if(rsi1[0] < rsi2[0] - 5) return SELL;
    return NONE;
}

//+------------------------------------------------------------------+
//| 4. NLP PARSER & SIGNAL CONSOLIDATION                             |
//+------------------------------------------------------------------+

void ResetStrategy()
{
    for(int i=0; i<nRules; i++)
    {
        if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
        if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
        if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
        rules[i].active = false;
    }
    nRules = 0;
    p_riskPercent = 1.0; p_stopPoints = 300; p_takePoints = 500;
    p_trailingStopPoints = 0; p_breakEvenPoints = 0;
    p_maxSimultaneousTrades = 3; p_newsVetoMinutes = 20;
    p_hedge = false; p_martingale = false;
    p_startTime = "00:00"; p_startTimeSeconds = 0;
    p_frequency = PERIOD_M15;
}

void AddRule(RuleType type, int tf, int p1, int p2, double d1, double d2, Signal intent, bool is_cross=false)
{
    int idx = -1;
    for(int i=0; i<nRules; i++)
        if(rules[i].type == type && rules[i].intent == intent) { idx = i; break; }

    if(idx == -1) { if(nRules >= 30) return; idx = nRules++; }

    rules[idx].active = true; rules[idx].type = type; rules[idx].tf = tf;
    rules[idx].p1 = p1; rules[idx].p2 = p2; rules[idx].d1 = d1; rules[idx].d2 = d2;
    rules[idx].intent = intent; rules[idx].is_cross = is_cross;

    if(type == RULE_MA_CROSS) {
        rules[idx].p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, p1, 0, MODE_EMA, PRICE_CLOSE);
        rules[idx].p2_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, p2, 0, MODE_EMA, PRICE_CLOSE);
    } else if(type == RULE_RSI_THRESHOLD) {
        rules[idx].p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, p1, PRICE_CLOSE);
    } else if(type == RULE_STOCH_CROSS) {
        rules[idx].p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)tf, p1, p2, 3, MODE_SMA, STO_LOWHIGH);
    } else if(type == RULE_BB_BOUNCE) {
        rules[idx].p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)tf, p1, 0, d1, PRICE_CLOSE);
    } else if(type == RULE_AMA) {
        rules[idx].p1_handle = iAMA(_Symbol, (ENUM_TIMEFRAMES)tf, p1, p2, 30, 0, PRICE_CLOSE);
    }
}

double ExtractNumber(string txt, string keyword)
{
    int pos = StringFind(txt, keyword);
    if(pos < 0) return 0;
    pos += StringLen(keyword);
    string res = "";
    while(pos < StringLen(txt))
    {
        ushort c = StringGetCharacter(txt, pos);
        if((c >= '0' && c <= '9') || c == '.') res += ShortToString(c);
        else if(res != "") break;
        pos++;
    }
    return StringToDouble(res);
}

string ExtractTime(string txt, string keyword)
{
    int pos = StringFind(txt, keyword);
    if(pos < 0) return "00:00";
    pos += StringLen(keyword);
    string res = "";
    while(pos < StringLen(txt))
    {
        ushort c = StringGetCharacter(txt, pos);
        if((c >= '0' && c <= '9') || c == ':' || c == 'h') res += ShortToString(c);
        else if(res != "") break;
        pos++;
    }
    StringReplace(res, "h", ":00");
    if(StringFind(res, ":") == StringLen(res)-1) res += "00";
    return res;
}

long StringToTimeSeconds(string timeStr)
{
    string parts[];
    if(StringSplit(timeStr, ':', parts) < 2) return 0;
    return (long)StringToInteger(parts[0]) * 3600 + (long)StringToInteger(parts[1]) * 60;
}

ENUM_TIMEFRAMES MinutesToTimeframe(int m)
{
    if(m <= 1) return PERIOD_M1; if(m <= 5) return PERIOD_M5;
    if(m <= 15) return PERIOD_M15; if(m <= 30) return PERIOD_M30;
    if(m <= 60) return PERIOD_H1; if(m <= 240) return PERIOD_H4;
    return PERIOD_D1;
}

void InterpretaPrompt(string prompt)
{
    if(prompt == "" || prompt == lastPrompt) return;
    ResetStrategy();
    lastPrompt = prompt;
    string pLower = prompt; StringToLower(pLower);
    StringReplace(pLower, " e ", "|"); StringReplace(pLower, " + ", "|");
    string segments[];
    int nSegs = StringSplit(pLower, '|', segments);
    for(int i=0; i<nSegs; i++) {
        string s = segments[i]; StringTrimLeft(s); StringTrimRight(s);
        if(StringFind(s, "cada ") >= 0) p_frequency = MinutesToTimeframe((int)ExtractNumber(s, "cada "));
        if(StringFind(s, "depois das ") >= 0) { p_startTime = ExtractTime(s, "depois das "); p_startTimeSeconds = StringToTimeSeconds(p_startTime); }
        if(StringFind(s, "stop de ") >= 0) p_stopPoints = (int)ExtractNumber(s, "stop de ");
        if(StringFind(s, "take de ") >= 0) p_takePoints = (int)ExtractNumber(s, "take de ");
        if(StringFind(s, "risco de ") >= 0) p_riskPercent = ExtractNumber(s, "risco de ");
        if(StringFind(s, "máximo ") >= 0) p_maxSimultaneousTrades = (int)ExtractNumber(s, "máximo ");
        if(StringFind(s, "move stop para entrada") >= 0) { p_breakEvenPoints = (int)ExtractNumber(s, "atingir +"); p_breakEvenProfit = (int)ExtractNumber(s, "entrada +"); }
        if(StringFind(s, "média") >= 0) {
            int p1 = (int)ExtractNumber(s, "média ");
            if(p1 == 0) p1 = 20; // Default
            int p2 = 0;
            if(StringFind(s, "/") >= 0) p2 = (int)ExtractNumber(s, "/");
            else p2 = p1 * 2;
            Signal intent = (StringFind(s, "compra") >= 0 ? BUY : (StringFind(s, "vende") >= 0 ? SELL : NONE));
            if(intent == NONE) {
                // Infer intent from context if not explicitly in segment
                if(StringFind(pLower, "compra") < StringFind(pLower, s) && StringFind(pLower, "vende") > StringFind(pLower, s)) intent = BUY;
                else intent = SELL;
            }
            AddRule(RULE_MA_CROSS, PERIOD_CURRENT, p1, p2, 0, 0, intent, true);
        }
        if(StringFind(s, "rsi") >= 0) {
            int per = (int)ExtractNumber(s, "rsi ("); if(per == 0) per = (int)ExtractNumber(s, "rsi ");
            if(per == 0) per = 14; // Default
            bool cross = (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0 || StringFind(s, "cruzar") >= 0);
            double val = ExtractNumber(s, "de ");
            Signal intent = (StringFind(s, "compra") >= 0 ? BUY : (StringFind(s, "vende") >= 0 ? SELL : NONE));
            if(StringFind(s, "acima") >= 0 || intent == BUY) AddRule(RULE_RSI_THRESHOLD, PERIOD_CURRENT, per, 0, val, 0, BUY, cross);
            else if(StringFind(s, "abaixo") >= 0 || intent == SELL) AddRule(RULE_RSI_THRESHOLD, PERIOD_CURRENT, per, 0, 0, val, SELL, cross);
        }
    }
}

Signal AvaliaTudo()
{
    int bVotes=0, sVotes=0, bRules=0, sRules=0;
    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;
        Signal s = NONE;
        switch(rules[i].type) {
            case RULE_MA_CROSS: s=CheckMA(rules[i]); break;
            case RULE_RSI_THRESHOLD: s=CheckRSI(rules[i]); break;
            case RULE_STOCH_CROSS: s=CheckStoch(rules[i]); break;
            case RULE_BB_BOUNCE: s=CheckBB(rules[i]); break;
            case RULE_DAILY_BREAK: s=CheckDailyBreak(rules[i]); break;
            case RULE_DELTA_AGG: s=CheckDelta(rules[i]); break;
            case RULE_VOLUME_CYCLE: s=CheckVolumeCycle(rules[i]); break;
            case RULE_AMA: s=CheckAMA(rules[i]); break;
            case RULE_BAR_PATTERN: s=CheckBarPattern(rules[i]); break;
            case RULE_RS_RELATIVE: s=CheckRS(rules[i]); break;
        }
        if(rules[i].intent == BUY) { bRules++; if(s == BUY) bVotes++; }
        if(rules[i].intent == SELL) { sRules++; if(s == SELL) sVotes++; }
    }
    if(bRules > 0 && bVotes == bRules) return BUY;
    if(sRules > 0 && sVotes == sRules) return SELL;
    return NONE;
}

//+------------------------------------------------------------------+
//| 5. TRADE EXECUTION & POSITION MANAGEMENT                         |
//+------------------------------------------------------------------+

void EnviaOrdem(Signal s, double vol, double sl_pts, double tp_pts)
{
    if(s == NONE || PositionsTotal() >= p_maxSimultaneousTrades) return;
    if(!p_hedge) {
        for(int i=PositionsTotal()-1; i>=0; i--)
            if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC)
                if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) || (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY))
                    trade.PositionClose(posInfo.Ticket());
    }
    double price = (s == BUY ? symbolInfo.Ask() : symbolInfo.Bid());
    double sl = 0, tp = 0;
    double safety = symbolInfo.StopsLevel() + dynamicSafetyPoints + 1;
    if(sl_pts > 0) sl = (s == BUY ? price - MathMax(sl_pts, safety) * _Point : price + MathMax(sl_pts, safety) * _Point);
    if(tp_pts > 0) tp = (s == BUY ? price + tp_pts * _Point : price - tp_pts * _Point);
    if(s == BUY) trade.Buy(vol, _Symbol, price, sl, tp); else trade.Sell(vol, _Symbol, price, sl, tp);
}

double CalculaLote()
{
    double riskAbs = accountInfo.Equity() * p_riskPercent / 100.0;
    double volume = riskAbs / (MathMax(p_stopPoints, 10) * (symbolInfo.TickValue() / (symbolInfo.TickSize() / _Point)));
    if(p_martingale) {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());
        for(int i=HistoryDealsTotal()-1; i>=0; i--) {
            ulong t = HistoryDealGetTicket(i);
            if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) volume *= 2;
                break;
            }
        }
    }
    return NormalizeDouble(MathMax(volume, symbolInfo.LotsMin()), 2);
}

void GerenciaPosicoes()
{
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
            double cur = (posInfo.PositionType() == POSITION_TYPE_BUY ? symbolInfo.Bid() : symbolInfo.Ask());
            int pfts = (int)(MathAbs(cur - posInfo.PriceOpen()) / _Point);
            bool isB = (posInfo.PositionType() == POSITION_TYPE_BUY);
            if(p_breakEvenPoints > 0 && pfts >= p_breakEvenPoints) {
                double tSL = (isB ? posInfo.PriceOpen() + p_breakEvenProfit * _Point : posInfo.PriceOpen() - p_breakEvenProfit * _Point);
                if((isB && (posInfo.StopLoss() < tSL || posInfo.StopLoss() == 0)) || (!isB && (posInfo.StopLoss() > tSL || posInfo.StopLoss() == 0)))
                    trade.PositionModify(posInfo.Ticket(), tSL, posInfo.TakeProfit());
            }
            if(p_trailingStopPoints > 0 && pfts >= p_trailingStopPoints) {
                double tSL = (isB ? cur - p_trailingStopPoints * _Point : cur + p_trailingStopPoints * _Point);
                if((isB && tSL > posInfo.StopLoss()) || (!isB && (tSL < posInfo.StopLoss() || posInfo.StopLoss() == 0)))
                    trade.PositionModify(posInfo.Ticket(), tSL, posInfo.TakeProfit());
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 6. AUXILIARY SYSTEMS (NEWS, LOGS, STATS)                         |
//+------------------------------------------------------------------+

bool AguardaNoticias()
{
    int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) { string c = FileReadString(h); FileClose(h); if(c == "1") return true; }
    MqlCalendarValue v[];
    if(CalendarValueHistory(v, TimeCurrent() - p_newsVetoMinutes * 60, TimeCurrent() + p_newsVetoMinutes * 60) > 0)
        for(int i=0; i<ArraySize(v); i++) { MqlCalendarEvent e; if(CalendarEventById(v[i].event_id, e)) if(e.importance == CALENDAR_IMPORTANCE_HIGH) return true; }
    return false;
}

void GravaLog(string t) { Print("MT-LiveExecutor: ", t); }

void GravaCSV()
{
    if(TimeCurrent() - lastStateSave < 5) return; lastStateSave = TimeCurrent();
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Time");
        for(int i=0; i<PositionsTotal(); i++)
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC)
                FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Time());
        FileClose(h);
    }
}

void AIOptimizer()
{
    HistorySelect(0, TimeCurrent()); int w=0, l=0;
    for(int i=0; i<HistoryDealsTotal(); i++) {
        ulong t = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT);
            if(p > 0) w++; else if(p < 0) l++;
        }
    }
    if(l > w * 1.5) dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
    else if(TimeCurrent() % 60 == 0) dynamicSafetyPoints = MathMax(dynamicSafetyPoints - 1, 0);
}

//+------------------------------------------------------------------+
//| 7. CORE LIFECYCLE HANDLERS                                       |
//+------------------------------------------------------------------+

int OnInit() { trade.SetExpertMagicNumber(EA_MAGIC); symbolInfo.Name(_Symbol); EventSetTimer(5); return(INIT_SUCCEEDED); }
void OnDeinit(const int r) { EventKillTimer(); ResetStrategy(); }

void OnTick()
{
    GerenciaPosicoes(); GravaCSV();
    datetime cb = iTime(_Symbol, p_frequency, 0); if(cb == lastBarTime) return; lastBarTime = cb;
    if(AguardaNoticias()) return;
    MqlDateTime dt; TimeCurrent(dt); if(dt.hour * 3600 + dt.min * 60 < p_startTimeSeconds) return;
    Signal s = AvaliaTudo(); if(s != NONE) EnviaOrdem(s, CalculaLote(), p_stopPoints, p_takePoints);
}

void OnTimer()
{
    double f = 0;
    if(GlobalVariableGet("MT_Executor_Prompt_Update", f) && f > 0) {
        int h = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
        if(h != INVALID_HANDLE) { string p = FileReadString(h); FileClose(h); InterpretaPrompt(p); GlobalVariableSet("MT_Executor_Prompt_Update", 0); }
    }
    AIOptimizer();
}
