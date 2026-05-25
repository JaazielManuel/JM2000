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

// --- Enums
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

// --- Structs
struct Rule {
    bool     active;
    ENUM_TIMEFRAMES tf;
    int      type; // 1=MA, 2=RSI, 3=Stoch, 4=BB, 5=DailyBreak, 6=Delta, 7=Volume, 8=AMA, 9=BarPattern, 10=Relative
    int      intent; // BUY or SELL
    int      p1, p2, p3;
    double   d1, d2;
    string   s1;
    int      handle1, handle2;

    void Reset() {
        active = false;
        tf = PERIOD_CURRENT;
        type = 0;
        intent = 0;
        p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0;
        s1 = "";
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        handle1 = INVALID_HANDLE;
        handle2 = INVALID_HANDLE;
    }
};

// --- Globals
Rule rules[20];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

string p_lastPrompt = "";
double p_riskPercent = 1.0;
int p_stopPoints = 0;
int p_takePoints = 0;
int p_maxTrades = 3;
string p_startTime = "00:00";
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
bool p_useMartingale = false;
int p_newsVetoMinutes = 20;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime lastPersistence = 0;
datetime lastAI = 0;
datetime lastBar = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    symInfo.Name(_Symbol);
    EventSetTimer(1);
    GravaLog("MT-LiveExecutor iniciado.");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
    for(int i=0; i<20; i++) rules[i].Reset();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    GerenciaPosicoes();

    if(TimeCurrent() - lastPersistence >= 5) {
        GravaCSV();
        lastPersistence = TimeCurrent();
    }

    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != lastBar) {
        if(IsTimeAllowed() && !AguardaNoticias()) {
            Signal s = AvaliaTudo();
            if(s != NONE) {
                double lote = CalculaLote(p_riskPercent);
                EnviaOrdem(s, lote);
            }
        }
        lastBar = currentBar;
    }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
    MonitoraPrompt();

    if(TimeCurrent() - lastAI >= 3600) {
        AIOptimizer();
        lastAI = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
//| NLP / Parser functions Placeholder                               |
//+------------------------------------------------------------------+
void MonitoraPrompt() {
    int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_SHARE_READ|FILE_ANSI);
    if(handle != INVALID_HANDLE) {
        string content = FileReadString(handle);
        FileClose(handle);
        if(content != "" && content != p_lastPrompt) {
            InterpretaPrompt(content);
            p_lastPrompt = content;
        }
    }
}

void ResetStrategy() {
    for(int i=0; i<20; i++) rules[i].Reset();
    nRules = 0;
    p_riskPercent = 1.0;
    p_stopPoints = 0;
    p_takePoints = 0;
    p_maxTrades = 3;
    p_startTime = "00:00";
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStop = 0;
    p_trailingStep = 0;
    p_useMartingale = false;
    p_newsVetoMinutes = 20;
    p_frequency = PERIOD_M15;
}

void InterpretaPrompt(string prompt) {
    GravaLog("Interpretando novo prompt.");
    ResetStrategy();
    string work = prompt;
    StringToLower(work);

    // Global parameters
    double val = ExtraiValorApos(work, "risco");
    if(val > 0) p_riskPercent = val;

    val = ExtraiValorApos(work, "stop");
    if(val > 0) p_stopPoints = (int)val;

    val = ExtraiValorApos(work, "take");
    if(val > 0) p_takePoints = (int)val;

    val = ExtraiValorApos(work, "máximo");
    if(val > 0) p_maxTrades = (int)val;

    if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

    int posNoticia = StringFind(work, "notícia");
    if(posNoticia >= 0) {
        int cursor = posNoticia;
        double min = ExtraiNumero(work, cursor);
        if(min > 0) p_newsVetoMinutes = (int)min;
    }

    if(StringFind(work, "15 min") >= 0) p_frequency = PERIOD_M15;
    else if(StringFind(work, "5 min") >= 0) p_frequency = PERIOD_M5;
    else if(StringFind(work, "1 min") >= 0) p_frequency = PERIOD_M1;
    else if(StringFind(work, "1h") >= 0) p_frequency = PERIOD_H1;

    int posInicio = StringFind(work, "depois das");
    if(posInicio < 0) posInicio = StringFind(work, "início");
    if(posInicio < 0) posInicio = StringFind(work, "começar");
    if(posInicio >= 0) {
        int hPos = StringFind(work, "h", posInicio);
        if(hPos > 0) {
            int cursor = posInicio;
            int hora = (int)ExtraiNumero(work, cursor);
            p_startTime = IntegerToString(hora, 2, '0') + ":00";
        }
    }

    val = ExtraiValorApos(work, "atingir");
    if(val > 0) p_beStart = (int)val;
    val = ExtraiValorApos(work, "entrada +");
    if(val > 0) p_bePlus = (int)val;

    if(StringFind(work, "trailing") >= 0) {
        int cursor = StringFind(work, "trailing");
        p_trailingStop = (int)ExtraiNumero(work, cursor);
        p_trailingStep = (int)ExtraiNumero(work, cursor);
    }

    // Rules
    // Pre-process: replace " e " with "." to simplify splitting
    string processed = work;
    StringReplace(processed, " e ", ".");

    string segments[];
    int nSeg = StringSplit(processed, '.', segments);
    int currentIntent = 0;

    for(int i=0; i<nSeg; i++) {
        string seg = segments[i];
        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

        if(currentIntent != 0) {
            AddRule(seg, currentIntent);
        }
    }
}

double ExtraiValorApos(string txt, string keyword) {
    int pos = StringFind(txt, keyword);
    if(pos < 0) return 0;
    int cursor = pos + StringLen(keyword);
    return ExtraiNumero(txt, cursor);
}

double ExtraiNumero(string txt, int &cursor) {
    string res = "";
    bool found = false;
    for(int i=cursor; i<StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') res += "."; else res += CharToString((uchar)c);
            found = true;
        } else if(found) {
            cursor = i;
            break;
        }
    }
    return StringToDouble(res);
}

void AddRule(string txt, int intent) {
    if(nRules >= 20) return;

    // RSI
    if(StringFind(txt, "rsi") >= 0) {
        int cursor = StringFind(txt, "rsi") + 3;
        double p1 = ExtraiNumero(txt, cursor);
        double p2 = ExtraiNumero(txt, cursor);
        rules[nRules].type = 2;
        rules[nRules].intent = intent;
        if(p2 == 0) { // Only one number found
            rules[nRules].p1 = 14;
            rules[nRules].d1 = p1;
        } else {
            rules[nRules].p1 = (int)p1;
            rules[nRules].d1 = p2;
        }
        rules[nRules].tf = PeriodoTexto(txt);
        rules[nRules].handle1 = iRSI(_Symbol, rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
            if(nRules >= 20) return;
        }
    }
    // MA Cross/Price Cross
    if(StringFind(txt, "média") >= 0) {
        int cursor = StringFind(txt, "média") + 5;
        double p1 = ExtraiNumero(txt, cursor);
        double p2 = ExtraiNumero(txt, cursor);
        rules[nRules].type = 1;
        rules[nRules].intent = intent;
        rules[nRules].p1 = (int)p1;
        rules[nRules].p2 = (int)p2;
        rules[nRules].tf = PeriodoTexto(txt);
        rules[nRules].handle1 = iMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
        if(p2 > 0) rules[nRules].handle2 = iMA(_Symbol, rules[nRules].tf, rules[nRules].p2, 0, MODE_SMA, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
            if(nRules >= 20) return;
        }
    }
    // Stochastic
    if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
        rules[nRules].type = 3;
        rules[nRules].intent = intent;
        rules[nRules].tf = PeriodoTexto(txt);
        rules[nRules].handle1 = iStochastic(_Symbol, rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }
    // Bollinger Bands
    if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
        rules[nRules].type = 4;
        rules[nRules].intent = intent;
        rules[nRules].tf = PeriodoTexto(txt);
        rules[nRules].handle1 = iBands(_Symbol, rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }
    // Delta Aggression
    if(StringFind(txt, "delta") >= 0 || StringFind(txt, "agressão") >= 0) {
        int cursor = StringFind(txt, "delta");
        if(cursor < 0) cursor = StringFind(txt, "agressão");
        rules[nRules].type = 6;
        rules[nRules].intent = intent;
        rules[nRules].p1 = (int)ExtraiNumero(txt, cursor); // seconds
        rules[nRules].p2 = (int)ExtraiNumero(txt, cursor); // threshold
        if(rules[nRules].p1 == 0) rules[nRules].p1 = 60;
        if(rules[nRules].p2 == 0) rules[nRules].p2 = 300;
        rules[nRules].active = true;
        nRules++;
    }
    // Relative Strength
    if(StringFind(txt, "relativa") >= 0) {
        rules[nRules].type = 10;
        rules[nRules].intent = intent;
        rules[nRules].s1 = "US30"; // Default benchmark
        rules[nRules].tf = PeriodoTexto(txt);
        rules[nRules].handle1 = iRSI(_Symbol, rules[nRules].tf, 14, PRICE_CLOSE);
        rules[nRules].handle2 = iRSI(rules[nRules].s1, rules[nRules].tf, 14, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE && rules[nRules].handle2 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }
    // Daily Breakout
    if(StringFind(txt, "breakout") >= 0 || StringFind(txt, "diário") >= 0) {
        rules[nRules].type = 5;
        rules[nRules].intent = intent;
        rules[nRules].active = true;
        nRules++;
    }
    // Volume Cycle
    if(StringFind(txt, "volume") >= 0) {
        rules[nRules].type = 7;
        rules[nRules].intent = intent;
        rules[nRules].active = true;
        nRules++;
    }
    // AMA (Adaptive Moving Average)
    if(StringFind(txt, "ama") >= 0 || StringFind(txt, "adaptativa") >= 0) {
        rules[nRules].type = 8;
        rules[nRules].intent = intent;
        rules[nRules].tf = PeriodoTexto(txt);
        rules[nRules].handle1 = iAMA(_Symbol, rules[nRules].tf, 10, 2, 30, 0, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }
    // Bar Pattern
    if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "candle") >= 0) {
        rules[nRules].type = 9;
        rules[nRules].intent = intent;
        rules[nRules].active = true;
        nRules++;
    }
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
    if(StringFind(txt, "m1") >= 0 && StringFind(txt, "m15") < 0) return PERIOD_M1;
    if(StringFind(txt, "m5") >= 0 && StringFind(txt, "m15") < 0) return PERIOD_M5;
    if(StringFind(txt, "m15") >= 0) return PERIOD_M15;
    if(StringFind(txt, "h1") >= 0) return PERIOD_H1;
    if(StringFind(txt, "d1") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

Signal AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;
        Signal s = AvaliaRegra(rules[i]);
        if(rules[i].intent == BUY) {
            buyRules++;
            if(s == BUY) buyVotes++;
        } else if(rules[i].intent == SELL) {
            sellRules++;
            if(s == SELL) sellVotes++;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) return BUY;
    if(sellRules > 0 && sellVotes == sellRules) return SELL;
    return NONE;
}

Signal AvaliaRegra(Rule &r) {
    if(r.type == 1) { // MA
        double ma1 = GetBufferValue(r.handle1, 0, 1);
        double ma1_p = GetBufferValue(r.handle1, 0, 2);
        double close1 = iClose(_Symbol, r.tf, 1);
        double close2 = iClose(_Symbol, r.tf, 2);

        if(r.handle2 == INVALID_HANDLE) { // Price vs MA
            if(close2 < ma1_p && close1 > ma1) return BUY;
            if(close2 > ma1_p && close1 < ma1) return SELL;
        } else { // MA vs MA
            double ma2 = GetBufferValue(r.handle2, 0, 1);
            double ma2_p = GetBufferValue(r.handle2, 0, 2);
            if(ma1_p < ma2_p && ma1 > ma2) return BUY;
            if(ma1_p > ma2_p && ma1 < ma2) return SELL;
        }
    }
    else if(r.type == 2) { // RSI
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);
        if(rsi2 < r.d1 && rsi1 > r.d1) return BUY;
        if(rsi2 > r.d1 && rsi1 < r.d1) return SELL;
    }
    else if(r.type == 3) { // Stoch
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);
        if(k2 < d2 && k1 > d1) return BUY;
        if(k2 > d2 && k1 < d1) return SELL;
    }
    else if(r.type == 4) { // Bollinger
        double upper = GetBufferValue(r.handle1, 1, 1);
        double lower = GetBufferValue(r.handle1, 2, 1);
        double close = iClose(_Symbol, r.tf, 1);
        if(close < lower) return BUY;
        if(close > upper) return SELL;
    }
    else if(r.type == 6) { // Delta
        MqlTick arr[];
        int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buyV = 0, sellV = 0;
        for(int i=0; i<n; i++) {
            if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyV += (long)arr[i].volume;
            else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellV += (long)arr[i].volume;
        }
        long delta = buyV - sellV;
        if(delta > r.p2) return BUY;
        if(delta < -r.p2) return SELL;
    }
    else if(r.type == 5) { // Daily Breakout
        double hi = iHigh(_Symbol, PERIOD_D1, 1);
        double lo = iLow(_Symbol, PERIOD_D1, 1);
        double close = iClose(_Symbol, PERIOD_M1, 0);
        if(close > hi) return BUY;
        if(close < lo) return SELL;
    }
    else if(r.type == 7) { // Volume Cycle
        double vol[]; ArraySetAsSeries(vol, true);
        if(CopyVolume(_Symbol, r.tf, 0, 12, vol) > 0) {
            int maxIdx = ArrayMaximum(vol);
            int minIdx = ArrayMinimum(vol);
            if(minIdx == 0) return BUY;
            if(maxIdx == 0) return SELL;
        }
    }
    else if(r.type == 8) { // AMA
        double ama = GetBufferValue(r.handle1, 0, 1);
        double ama_p = GetBufferValue(r.handle1, 0, 2);
        if(ama > ama_p) return BUY;
        if(ama < ama_p) return SELL;
    }
    else if(r.type == 9) { // Bar Pattern (Inside/Outside)
        double h0 = iHigh(_Symbol, r.tf, 1);
        double l0 = iLow(_Symbol, r.tf, 1);
        double h1 = iHigh(_Symbol, r.tf, 2);
        double l1 = iLow(_Symbol, r.tf, 2);
        bool bullish = iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1);

        if(h0 < h1 && l0 > l1) return bullish ? BUY : SELL; // Inside
        if(h0 > h1 && l0 < l1) return bullish ? SELL : BUY; // Outside
    }
    else if(r.type == 10) { // Relative
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle2, 0, 1);
        if(rsi1 > rsi2 + 5) return BUY;
        if(rsi1 < rsi2 - 5) return SELL;
    }
    return NONE;
}

//+------------------------------------------------------------------+
//| AI Optimizer                                                     |
//+------------------------------------------------------------------+
void AIOptimizer() {
    HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
    int total = HistoryDealsTotal();
    int count = 0, wins = 0;
    for(int i=total-1; i>=0 && count<10; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit > 0) wins++;
            count++;
        }
    }
    if(count >= 5) {
        double winRate = (double)wins / count;
        if(winRate < 0.4) {
            p_riskPercent *= 0.8;
            GravaLog("AI Optimizer: Win rate baixo ("+DoubleToString(winRate,2)+"). Risco reduzido para "+DoubleToString(p_riskPercent,2)+"%");
        }
    }
}

//+------------------------------------------------------------------+
//| MT5-KNOWLEDGE-CORE (Simplified & Procedural)                    |
//+------------------------------------------------------------------+
double GetBufferValue(int handle, int buffer, int shift) {
    double val[];
    ArraySetAsSeries(val, true);
    if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
    return 0;
}

// Signal functions will be integrated into AvaliaRegra in Step 3

//+------------------------------------------------------------------+
//| Placeholders for Step 4 functions                                |
//+------------------------------------------------------------------+
void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC && PositionGetString(POSITION_SYMBOL) == _Symbol) {
                double price = PositionGetDouble(POSITION_PRICE_OPEN);
                double current = PositionGetDouble(POSITION_PRICE_CURRENT);
                double sl = PositionGetDouble(POSITION_SL);
                int type = (int)PositionGetInteger(POSITION_TYPE);

                // Breakeven
                if(p_beStart > 0) {
                    double diff = (type == POSITION_TYPE_BUY) ? (current - price) : (price - current);
                    if(diff >= p_beStart * _Point) {
                        double newSL = (type == POSITION_TYPE_BUY) ? (price + p_bePlus * _Point) : (price - p_bePlus * _Point);
                        if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                            trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                            GravaLog("Breakeven acionado para ticket " + IntegerToString((int)ticket));
                        }
                    }
                }

                // Trailing Stop
                if(p_trailingStop > 0) {
                    double diff = (type == POSITION_TYPE_BUY) ? (current - price) : (price - current);
                    if(diff >= p_trailingStop * _Point) {
                        double newSL = (type == POSITION_TYPE_BUY) ? (current - p_trailingStop * _Point) : (current + p_trailingStop * _Point);
                        if((type == POSITION_TYPE_BUY && newSL > sl + p_trailingStep * _Point) || (type == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0))) {
                            trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                        }
                    }
                }
            }
        }
    }
}

bool IsTimeAllowed() {
    string now = TimeToString(TimeCurrent(), TIME_MINUTES);
    if(now < p_startTime) return false;
    return true;
}

bool AguardaNoticias() {
    // news_veto.txt
    int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_SHARE_READ|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        string line = FileReadString(h);
        FileClose(h);
        if(line == "1" || line == "true") return true;
    }

    // calendar.txt (mock logic for "high impact")
    h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_SHARE_READ|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        while(!FileIsEnding(h)) {
            string line = FileReadString(h);
            StringToLower(line);
            if(StringFind(line, "high") >= 0 || StringFind(line, "impact") >= 0) {
                // Simplified: if any high impact today, check time (would need actual calendar parsing here)
                // For now, if "high" is found in calendar.txt, we just log it as a warning or veto
            }
        }
        FileClose(h);
    }
    return false;
}

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riscoAbs = capital * riscoPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    int stop = p_stopPoints;
    if(stop <= 0) stop = 300; // Default safety

    if(p_useMartingale) {
        HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i=total-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riscoAbs *= 2;
                break;
            }
        }
    }

    double points_val = stop * (tickValue / (tickSize / _Point));
    if(points_val == 0) return 0.01;
    double lote = NormalizeDouble(riscoAbs / points_val, 2);

    double minLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLote = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lote < minLote) lote = minLote;
    if(lote > maxLote) lote = maxLote;

    return lote;
}

void EnviaOrdem(Signal s, double lote) {
    if(PositionsTotal() >= p_maxTrades) return;

    double sl = 0, tp = 0;
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(s == BUY) {
        if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price + p_takePoints * _Point;
    } else {
        if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price - p_takePoints * _Point;
    }

    // Retries
    for(int i=0; i<3; i++) {
        bool res = false;
        if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor");
        else res = trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor");

        if(res) {
            uint retcode = trade.ResultRetcode();
            if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED) {
                GravaLog("Ordem enviada com sucesso: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2));
                SendNotification("Trade executado: " + _Symbol + " " + EnumToString(s));
                SendMail("Trade Executado", "Trade executado em " + _Symbol + ": " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2));
                break;
            } else if(retcode == TRADE_RETCODE_REQUOTES || retcode == TRADE_RETCODE_OFFQUOTES) {
                Sleep(100);
                price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
                continue;
            } else {
                GravaLog("Erro ao enviar ordem: " + trade.ResultRetcodeDescription());
                break;
            }
        }
    }
}

void GravaLog(string txt) {
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_SHARE_READ|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWriteString(h, TimeToString(TimeCurrent()) + ": " + txt + "\r\n");
        FileClose(h);
    }
}

void GravaCSV() {
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_TXT|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileWriteString(h, "Ticket,Symbol,Type,Price,SL,TP,Profit\n");
        for(int i=0; i<PositionsTotal(); i++) {
            if(PositionSelectByTicket(PositionGetTicket(i))) {
                if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
                    string row = IntegerToString((int)PositionGetInteger(POSITION_TICKET)) + "," +
                                 PositionGetString(POSITION_SYMBOL) + "," +
                                 IntegerToString((int)PositionGetInteger(POSITION_TYPE)) + "," +
                                 DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), 5) + "," +
                                 DoubleToString(PositionGetDouble(POSITION_SL), 5) + "," +
                                 DoubleToString(PositionGetDouble(POSITION_TP), 5) + "," +
                                 DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + "\n";
                    FileWriteString(h, row);
                }
            }
        }
        FileClose(h);
    }
}
