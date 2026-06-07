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

//--- Global Constants
#define EA_MAGIC 123456

//--- Enums
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

//--- Structs
struct Rule {
    bool    active;
    int     type;       // 1: MA, 2: RSI, 3: Stoch, etc.
    int     tf;
    int     p1, p2, p3;
    double  d1, d2;
    string  s1;
    Signal  intent;     // BUY or SELL that this rule triggers
    int     handle1;
    int     handle2;

    void Reset() {
        active = false;
        type = 0;
        tf = PERIOD_CURRENT;
        p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0;
        s1 = "";
        intent = NONE;
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        handle1 = INVALID_HANDLE;
        handle2 = INVALID_HANDLE;
    }
};

//--- Global Parameters
Rule rules[20];
int nRules = 0;
double p_risk = 1.0;
double p_stopLoss = 0;
double p_takeProfit = 0;
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
int p_newsVeto = 20;
string p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

//--- Global Objects
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
}

//+------------------------------------------------------------------+
//| NLP Parser & Logic Setup                                         |
//+------------------------------------------------------------------+

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    GravaLog("Interpretando: " + prompt);

    string cleanPrompt = prompt;
    StringReplace(cleanPrompt, " e ", ".");
    StringReplace(cleanPrompt, ";", ".");

    string segments[];
    int nSegments = StringSplit(cleanPrompt, '.', segments);

    Signal currentIntent = NONE;

    for(int i = 0; i < nSegments; i++) {
        string seg = segments[i];
        StringToLower(seg);
        StringTrimLeft(seg);
        StringTrimRight(seg);

        if(seg == "") continue;

        // Context detection
        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

        // Global Parameters
        int cursor = 0;
        if(StringFind(seg, "risco") >= 0) p_risk = ExtraiNumero(seg, cursor);
        cursor = 0;
        if(StringFind(seg, "stop") >= 0) p_stopLoss = ExtraiNumero(seg, cursor);
        cursor = 0;
        if(StringFind(seg, "take") >= 0) p_takeProfit = ExtraiNumero(seg, cursor);
        cursor = 0;
        if(StringFind(seg, "máximo") >= 0) p_maxTrades = (int)ExtraiNumero(seg, cursor);

        cursor = 0;
        if(StringFind(seg, "atingir") >= 0) p_beStart = (int)ExtraiNumero(seg, cursor);
        if(StringFind(seg, "entrada") >= 0) p_bePlus = (int)ExtraiNumero(seg, cursor);

        cursor = 0;
        if(StringFind(seg, "trailing") >= 0) {
            p_trailingStop = (int)ExtraiNumero(seg, cursor);
            p_trailingStep = (int)ExtraiNumero(seg, cursor);
        }

        cursor = 0;
        if(StringFind(seg, "notícias") >= 0) p_newsVeto = (int)ExtraiNumero(seg, cursor);

        if(StringFind(seg, "cada") >= 0 || StringFind(seg, "tempo") >= 0) {
            p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(seg);
        }

        if(StringFind(seg, "depois das") >= 0 || StringFind(seg, "início") >= 0) {
            int pos = StringFind(seg, "das");
            if(pos < 0) pos = StringFind(seg, "início");
            p_startTime = StringSubstr(seg, pos + 4, 5);
        }

        // Add Rule if indicator found
        AddRule(seg, currentIntent);
    }
}

void ResetStrategy() {
    for(int i = 0; i < 20; i++) rules[i].Reset();
    nRules = 0;
}

void AddRule(string txt, Signal intent) {
    if(nRules >= 20) return;

    static int lastMA = 20;
    static int lastRSI = 14;

    bool added = false;
    Rule r;
    r.Reset();
    r.intent = intent;

    // 1. Moving Average
    if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
        int cursor = StringFind(txt, "média");
        if(cursor < 0) cursor = StringFind(txt, "ma");
        int per = (int)ExtraiNumero(txt, cursor);
        if(per <= 0) per = lastMA;
        lastMA = per;

        r.active = true;
        r.type = 1;
        r.p1 = per;
        r.tf = PeriodoTexto(txt);
        r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
        added = true;
    }

    // 2. RSI
    if(StringFind(txt, "rsi") >= 0) {
        int cursor = StringFind(txt, "rsi");
        int per = (int)ExtraiNumero(txt, cursor);
        if(per <= 0) per = lastRSI;
        lastRSI = per;
        double level = ExtraiNumero(txt, cursor);

        r.active = true;
        r.type = 2;
        r.p1 = per;
        r.d1 = level;
        r.tf = PeriodoTexto(txt);
        r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        added = true;
    }

    // 3. Estocástico
    if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
        r.active = true;
        r.type = 3;
        r.tf = PeriodoTexto(txt);
        r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
        added = true;
    }

    // 4. Bollinger Bands
    if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
        r.active = true;
        r.type = 4;
        r.p1 = 20; // period
        r.d1 = 2.0; // deviation
        r.tf = PeriodoTexto(txt);
        r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
        added = true;
    }

    // 5. Breakout Diário
    if(StringFind(txt, "breakout") >= 0 || StringFind(txt, "rompimento") >= 0) {
        r.active = true;
        r.type = 5;
        r.tf = PERIOD_D1;
        added = true;
    }

    // 6. Delta de Agressão
    if(StringFind(txt, "delta") >= 0 || StringFind(txt, "agressão") >= 0) {
        r.active = true;
        r.type = 6;
        r.p1 = 60; // seconds
        r.p2 = 300; // threshold
        added = true;
    }

    // 7. Ciclo de Volume
    if(StringFind(txt, "volume") >= 0) {
        r.active = true;
        r.type = 7;
        r.p1 = 12; // length
        r.tf = PeriodoTexto(txt);
        added = true;
    }

    // 8. AMA
    if(StringFind(txt, "ama") >= 0 || StringFind(txt, "adaptativa") >= 0) {
        r.active = true;
        r.type = 8;
        r.p1 = 10; // period
        r.tf = PeriodoTexto(txt);
        r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
        added = true;
    }

    // 9. Padrão de 2 barras
    if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "barras") >= 0) {
        r.active = true;
        r.type = 9;
        r.tf = PeriodoTexto(txt);
        added = true;
    }

    // 10. Força Relativa
    if(StringFind(txt, "relativa") >= 0 || StringFind(txt, "bench") >= 0) {
        r.active = true;
        r.type = 10;
        r.s1 = "US30";
        r.p1 = 14;
        r.tf = PeriodoTexto(txt);
        r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        r.handle2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        added = true;
    }

    if(added) {
        if(r.handle1 == INVALID_HANDLE) {
            GravaLog("Erro ao criar handle para regra " + IntegerToString(nRules));
            return;
        }
        rules[nRules] = r;
        nRules++;
    }
}

double ExtraiNumero(string txt, int &cursor) {
    string res = "";
    bool found = false;
    for(int i = cursor; i < StringLen(txt); i++) {
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

int PeriodoTexto(string txt) {
    if(StringFind(txt, "m1") >= 0 && StringFind(txt, "m15") < 0 && StringFind(txt, "min") < 0) return PERIOD_M1;
    if(StringFind(txt, "m5") >= 0 && StringFind(txt, "m15") < 0 && StringFind(txt, "min") < 0) return PERIOD_M5;
    if(StringFind(txt, "m15") >= 0 || StringFind(txt, "15 min") >= 0) return PERIOD_M15;
    if(StringFind(txt, "m30") >= 0 || StringFind(txt, "30 min") >= 0) return PERIOD_M30;
    if(StringFind(txt, "m1") >= 0 || StringFind(txt, "1 min") >= 0) return PERIOD_M1;
    if(StringFind(txt, "m5") >= 0 || StringFind(txt, "5 min") >= 0) return PERIOD_M5;
    if(StringFind(txt, "h1") >= 0 || StringFind(txt, "1 hora") >= 0) return PERIOD_H1;
    if(StringFind(txt, "h4") >= 0 || StringFind(txt, "4 horas") >= 0) return PERIOD_H4;
    if(StringFind(txt, "d1") >= 0 || StringFind(txt, "diário") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

void GravaLog(string txt) {
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWrite(h, TimeToString(TimeCurrent()) + ": " + txt);
        FileClose(h);
    }
    Print(txt);
}

//+------------------------------------------------------------------+
//| Strategy Execution & Signal Engine                               |
//+------------------------------------------------------------------+

Signal AvaliaTudo() {
    if(nRules == 0) return NONE;

    bool hasBuyRules = false;
    bool hasSellRules = false;
    bool buyConfluence = true;
    bool sellConfluence = true;

    for(int i = 0; i < nRules; i++) {
        if(!rules[i].active) continue;

        Signal s = AvaliaRegra(rules[i]);

        if(rules[i].intent == BUY) {
            hasBuyRules = true;
            if(s != BUY) buyConfluence = false;
        } else if(rules[i].intent == SELL) {
            hasSellRules = true;
            if(s != SELL) sellConfluence = false;
        } else {
            // Rule without specific intent must match for both to pass
            if(s != BUY) buyConfluence = false;
            if(s != SELL) sellConfluence = false;
        }
    }

    if(hasBuyRules && buyConfluence) return BUY;
    if(hasSellRules && sellConfluence) return SELL;

    return NONE;
}

Signal AvaliaRegra(Rule &r) {
    switch(r.type) {
        case 1: // MA Cross
            double ma1 = GetBufferValue(r.handle1, 0, 1);
            double ma2 = GetBufferValue(r.handle1, 0, 2);
            double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double p2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            if(p2 < ma2 && p1 > ma1) return BUY;
            if(p2 > ma2 && p1 < ma1) return SELL;
            break;

        case 2: // RSI Threshold
            double rsi1 = GetBufferValue(r.handle1, 0, 1);
            double rsi2 = GetBufferValue(r.handle1, 0, 2);
            if(rsi2 < r.d1 && rsi1 >= r.d1) return BUY;
            if(rsi2 > r.d1 && rsi1 <= r.d1) return SELL;
            break;

        case 3: // Stoch Cross
            double k1 = GetBufferValue(r.handle1, 0, 1);
            double d1 = GetBufferValue(r.handle1, 1, 1);
            double k2 = GetBufferValue(r.handle1, 0, 2);
            double d2 = GetBufferValue(r.handle1, 1, 2);
            if(k2 < d2 && k1 > d1) return BUY;
            if(k2 > d2 && k1 < d1) return SELL;
            break;

        case 4: // Bollinger Bands
            double upper = GetBufferValue(r.handle1, 1, 1);
            double lower = GetBufferValue(r.handle1, 2, 1);
            double cl = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            if(cl < lower) return BUY;
            if(cl > upper) return SELL;
            break;

        case 5: // Daily Breakout
            double hi = iHigh(_Symbol, PERIOD_D1, 1);
            double lo = iLow(_Symbol, PERIOD_D1, 1);
            double c0 = iClose(_Symbol, PERIOD_M1, 0);
            if(c0 > hi) return BUY;
            if(c0 < lo) return SELL;
            break;

        case 6: // Delta Aggression
            MqlTick ticks[];
            int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, (TimeCurrent()-r.p1)*1000, TimeCurrent()*1000);
            long buyVol = 0, sellVol = 0;
            for(int j=0; j<n; j++) {
                if((ticks[j].flags & TICK_FLAG_BUY) != 0) buyVol += (long)ticks[j].volume;
                else if((ticks[j].flags & TICK_FLAG_SELL) != 0) sellVol += (long)ticks[j].volume;
            }
            long delta = buyVol - sellVol;
            if(delta > r.p2) return BUY;
            if(delta < -r.p2) return SELL;
            break;

        case 7: // Volume Cycle
            long vol[];
            CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1, vol);
            int maxIdx = ArrayMaximum(vol);
            int minIdx = ArrayMinimum(vol);
            if(minIdx == 0) return BUY;
            if(maxIdx == 0) return SELL;
            break;

        case 8: // AMA
            double ama1 = GetBufferValue(r.handle1, 0, 1);
            double ama2 = GetBufferValue(r.handle1, 0, 2);
            if(ama1 > ama2) return BUY;
            if(ama1 < ama2) return SELL;
            break;

        case 9: // 2-Bar Pattern (Inside/Outside)
            double h0=iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double l0=iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double h1=iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            double l1=iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            // Inside Bar
            if(h0 < h1 && l0 > l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) ? BUY : SELL;
            // Outside Bar
            if(h0 > h1 && l0 < l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) ? SELL : BUY;
            break;

        case 10: // Relative Strength
            double rs1 = GetBufferValue(r.handle1, 0, 1);
            double rs2 = GetBufferValue(r.handle2, 0, 1);
            if(rs1 > rs2 + 5) return BUY;
            if(rs1 < rs2 - 5) return SELL;
            break;
    }
    return NONE;
}

double GetBufferValue(int handle, int buffer, int index) {
    double val[];
    ArraySetAsSeries(val, true);
    if(CopyBuffer(handle, buffer, index, 1, val) > 0) return val[0];
    return 0;
}

void EnviaOrdem(Signal s) {
    if(s == NONE) return;
    if(PositionsTotal() >= p_maxTrades) return;
    if(AguardaNoticias()) return;
    if(!IsTimeAllowed()) return;

    double lote = CalculaLote(p_risk);
    double sl = 0, tp = 0;
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(s == BUY) {
        if(p_stopLoss > 0) sl = price - p_stopLoss * _Point;
        if(p_takeProfit > 0) tp = price + p_takeProfit * _Point;
        if(trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor Entry")) {
            GravaLog("Compra executada: " + DoubleToString(lote, 2) + " SL: " + DoubleToString(sl, 5) + " TP: " + DoubleToString(tp, 5));
            SendNotification("Compra MT-LiveExecutor em " + _Symbol);
        }
    } else {
        if(p_stopLoss > 0) sl = price + p_stopLoss * _Point;
        if(p_takeProfit > 0) tp = price - p_takeProfit * _Point;
        if(trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor Entry")) {
            GravaLog("Venda executada: " + DoubleToString(lote, 2) + " SL: " + DoubleToString(sl, 5) + " TP: " + DoubleToString(tp, 5));
            SendNotification("Venda MT-LiveExecutor em " + _Symbol);
        }
    }
}

double CalculaLote(double riscoPercent) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = equity * (riscoPercent / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    double lot = 0;
    if(p_stopLoss > 0) {
        lot = riskAmount / ((p_stopLoss * _Point / tickSize) * tickValue);
    } else {
        lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    }

    lot = MathFloor(lot / step) * step;
    double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minVol) lot = minVol;
    if(lot > maxVol) lot = maxVol;

    return lot;
}

bool IsTimeAllowed() {
    datetime now = TimeCurrent();
    string currentTime = TimeToString(now, TIME_MINUTES);
    return (currentTime >= p_startTime);
}

//+------------------------------------------------------------------+
//| Position Management & Utilities                                  |
//+------------------------------------------------------------------+

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

            double profitPoints = PositionGetDouble(POSITION_PROFIT) / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) / _Point;
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            double type = PositionGetInteger(POSITION_TYPE);

            // Breakeven
            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if((type == POSITION_TYPE_BUY && currentSL < newSL) || (type == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_trailingStop * _Point : SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_trailingStop * _Point;
                if(MathAbs(newSL - currentSL) > p_trailingStep * _Point) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

bool AguardaNoticias() {
    // 1. Check direct veto file
    int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string status = FileReadString(h);
        FileClose(h);
        if(status == "1") return true;
    }

    // 2. Check calendar (pseudo-logic for Agent implementation)
    h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        while(!FileIsEnding(h)) {
            string line = FileReadString(h);
            // Format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
            if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
                string parts[];
                StringSplit(line, ';', parts);
                datetime newsTime = StringToTime(parts[0]);
                if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) {
                    FileClose(h);
                    return true;
                }
            }
        }
        FileClose(h);
    }

    return false;
}

void GravaCSV() {
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(PositionSelectByTicket(PositionGetTicket(i))) {
                if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
                    FileWrite(h, PositionGetInteger(POSITION_TICKET),
                              PositionGetString(POSITION_SYMBOL),
                              PositionGetInteger(POSITION_TYPE),
                              PositionGetDouble(POSITION_PRICE_OPEN),
                              PositionGetDouble(POSITION_SL),
                              PositionGetDouble(POSITION_TP),
                              PositionGetDouble(POSITION_PROFIT));
                }
            }
        }
        FileClose(h);
    }
}

//+------------------------------------------------------------------+
//| AI Forecasting & Optimization (Placeholders)                    |
//+------------------------------------------------------------------+

double AIPredict() {
    // Placeholder for AI model inference
    return 0.5; // Neutral
}

void AIOptimizer() {
    // Placeholder for strategy parameter optimization
    GravaLog("Executando AIOptimizer...");
}

//+------------------------------------------------------------------+
//| Main Event Handlers                                              |
//+------------------------------------------------------------------+

void OnTick() {
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);

    GerenciaPosicoes();

    static datetime lastSave = 0;
    if(TimeCurrent() - lastSave > 5) {
        GravaCSV();
        lastSave = TimeCurrent();
    }

    if(currentBar != lastBar) {
        Signal s = AvaliaTudo();
        if(s != NONE) EnviaOrdem(s);
        lastBar = currentBar;
    }
}

void OnTimer() {
    // Check for prompt updates
    int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string newPrompt = FileReadString(h);
        FileClose(h);
        if(newPrompt != "" && newPrompt != "PROCESSED") {
            InterpretaPrompt(newPrompt);
            int wh = FileOpen("prompt.txt", FILE_WRITE|FILE_TXT|FILE_COMMON);
            FileWriteString(wh, "PROCESSED");
            FileClose(wh);
        }
    }

    static datetime lastAI = 0;
    if(TimeCurrent() - lastAI > 3600) {
        AIOptimizer();
        lastAI = TimeCurrent();
    }
}
