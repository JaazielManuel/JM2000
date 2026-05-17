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

//--- DEFINES
#define EA_MAGIC 123456
#define LOG_FILE "MT_LiveExecutor_Log.txt"
#define STATE_FILE "MT_LiveExecutor_State.csv"
#define PROMPT_FILE "prompt.txt"

//--- ENUMS
enum ENUM_SIGNAL { SIGNAL_BUY = 1, SIGNAL_SELL = -1, SIGNAL_NONE = 0 };

//--- STRUCTS
struct Rule {
    int      type;      // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
    int      intent;    // SIGNAL_BUY or SIGNAL_SELL
    int      tf;        // Timeframe
    int      p1, p2, p3; // Parameters
    double   d1, d2;     // Double parameters
    string   s1;        // String parameter
    int      handle1;
    int      handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        type = 0; intent = 0; tf = 0; p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
        handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
    }
};

//--- GLOBALS
Rule rules[20];
int nRules = 0;
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxPositions = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 10;
string p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool p_useMartingale = false;

datetime lastPromptModify = 0;
CTrade trade;

//--- FUNCTIONS PROTOTYPES
void InterpretaPrompt(string prompt);
double ExtraiValorApos(string texto, string chave);
double ExtraiNumero(string texto, int &pos);
ENUM_TIMEFRAMES PeriodoTexto(string nome);
void ResetStrategy();
void AvaliaTudo();
bool AvaliaRegra(Rule &r);
void EnviaOrdem(int type, double lot, string reason);
double CalculaLote(double riskPercent);
void GerenciaPosicoes();
void GravaLog(string text);
void GravaCSV();
bool IsTimeAllowed();
bool AguardaNoticias();
void AIOptimizer();
double GetBufferValue(int handle, int buffer, int shift);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);
    ResetStrategy();
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    static datetime lastCSV = 0;

    GerenciaPosicoes();

    if(TimeCurrent() - lastCSV >= 5) {
        GravaCSV();
        lastCSV = TimeCurrent();
    }

    // New bar logic
    static datetime lastBar = 0;
    datetime curBar = iTime(_Symbol, p_frequency, 0);
    if(curBar != lastBar) {
        if(IsTimeAllowed() && !AguardaNoticias()) {
            AvaliaTudo();
        }
        lastBar = curBar;
    }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
    // Check for prompt update
    datetime modif = (datetime)FileGetInteger(PROMPT_FILE, FILE_MODIFY_DATE, false);
    if(modif > lastPromptModify) {
        int h = FileOpen(PROMPT_FILE, FILE_READ|FILE_TXT|FILE_ANSI);
        if(h != INVALID_HANDLE) {
            string prompt = "";
            while(!FileIsEnding(h)) prompt += FileReadString(h);
            FileClose(h);

            InterpretaPrompt(prompt);
            lastPromptModify = modif;
            GravaLog("Novo prompt interpretado: " + prompt);
        }
    }

    // AI Optimizer hourly
    static datetime lastAI = 0;
    if(TimeCurrent() - lastAI >= 3600) {
        AIOptimizer();
        lastAI = TimeCurrent();
    }
}

// NLP Parser implementation
void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string work = prompt;
    StringToLower(work);

    // Global parameters
    double val;
    val = ExtraiValorApos(work, "risco de"); if(val > 0) p_riskPercent = val;
    val = ExtraiValorApos(work, "stop de"); if(val > 0) p_stopPoints = (int)val;
    val = ExtraiValorApos(work, "take de"); if(val > 0) p_takePoints = (int)val;
    val = ExtraiValorApos(work, "máximo"); if(val > 0) p_maxPositions = (int)val;
    val = ExtraiValorApos(work, "atingir +"); if(val > 0) p_beStart = (int)val;
    val = ExtraiValorApos(work, "entrada +"); if(val > 0) p_bePlus = (int)val;
    val = ExtraiValorApos(work, "trailing"); if(val > 0) p_trailingStop = (int)val;

    if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

    // Start time
    int startPos = StringFind(work, "depois das");
    if(startPos < 0) startPos = StringFind(work, "início");
    if(startPos >= 0) {
        int p = startPos;
        while(p < StringLen(work) && !((work[p]>='0' && work[p]<='9'))) p++;
        int pEnd = p;
        while(pEnd < StringLen(work) && ((work[pEnd]>='0' && work[pEnd]<='9') || work[pEnd]==':' || work[pEnd]=='h')) pEnd++;
        p_startTime = StringSubstr(work, p, pEnd - p);
        if(StringFind(p_startTime, "h") >= 0) StringReplace(p_startTime, "h", ":00");
    }

    // Global frequency
    p_frequency = PeriodoTexto(work);

    // Split into segments by period or conjunction
    string segments[];
    ushort sep = StringGetCharacter(".", 0);
    int nSeg = StringSplit(work, sep, segments);

    int currentIntent = SIGNAL_NONE;

    for(int i=0; i<nSeg; i++) {
        string s = segments[i];
        if(StringFind(s, "compra") >= 0) currentIntent = SIGNAL_BUY;
        if(StringFind(s, "vende") >= 0) currentIntent = SIGNAL_SELL;

        if(currentIntent == SIGNAL_NONE) continue;

        ENUM_TIMEFRAMES tf = PeriodoTexto(s);
        if(tf == PERIOD_CURRENT) tf = p_frequency;

        // MA
        if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0) {
            int pos = 0;
            int p1 = (int)ExtraiNumero(s, pos); if(p1 == 0) p1 = 20;
            int p2 = (int)ExtraiNumero(s, pos);

            rules[nRules].type = 1;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = tf;
            rules[nRules].p1 = p1;
            rules[nRules].p2 = p2;

            if(p2 > 0) rules[nRules].handle1 = iMA(_Symbol, tf, p1, 0, MODE_SMA, PRICE_CLOSE);
            if(p2 > 0) rules[nRules].handle2 = iMA(_Symbol, tf, p2, 0, MODE_SMA, PRICE_CLOSE);
            else rules[nRules].handle1 = iMA(_Symbol, tf, p1, 0, MODE_SMA, PRICE_CLOSE);

            nRules++;
        }

        // RSI
        if(StringFind(s, "rsi") >= 0) {
            int pos = 0;
            int p1 = (int)ExtraiNumero(s, pos); if(p1 == 0) p1 = 14;
            double d1 = ExtraiNumero(s, pos);

            // Heuristic: if p1 is threshold, use default period
            if(p1 >= 40 && d1 == 0) { d1 = p1; p1 = 14; }

            rules[nRules].type = 2;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = tf;
            rules[nRules].p1 = p1;
            rules[nRules].d1 = d1;
            rules[nRules].handle1 = iRSI(_Symbol, tf, p1, PRICE_CLOSE);
            nRules++;
        }

        // Stoch
        if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
            rules[nRules].type = 3;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = tf;
            rules[nRules].handle1 = iStochastic(_Symbol, tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            nRules++;
        }

        // Bollinger
        if(StringFind(s, "bollinger") >= 0 || StringFind(s, " bb ") >= 0) {
            rules[nRules].type = 4;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = tf;
            rules[nRules].handle1 = iBands(_Symbol, tf, 20, 0, 2.0, PRICE_CLOSE);
            nRules++;
        }

        // DailyBreak
        if(StringFind(s, "máxima") >= 0 || StringFind(s, "mínima") >= 0 || StringFind(s, "dailybreak") >= 0) {
            rules[nRules].type = 5;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = PERIOD_D1;
            nRules++;
        }

        // Delta
        if(StringFind(s, "delta") >= 0 || StringFind(s, "agressão") >= 0) {
            int pos = StringFind(s, "delta");
            if(pos < 0) pos = StringFind(s, "agressão");
            int p1 = (int)ExtraiNumero(s, pos); if(p1 == 0) p1 = 60;
            int p2 = (int)ExtraiNumero(s, pos); if(p2 == 0) p2 = 300;
            rules[nRules].type = 6;
            rules[nRules].intent = currentIntent;
            rules[nRules].p1 = p1;
            rules[nRules].p2 = p2;
            nRules++;
        }

        // Vol
        if(StringFind(s, "volume") >= 0) {
            rules[nRules].type = 7;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = tf;
            nRules++;
        }

        // AMA
        if(StringFind(s, "ama") >= 0) {
            rules[nRules].type = 8;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = tf;
            rules[nRules].handle1 = iAMA(_Symbol, tf, 10, 2, 30, 0, PRICE_CLOSE);
            nRules++;
        }

        // Bar2
        if(StringFind(s, "padrão") >= 0 || StringFind(s, "inside") >= 0 || StringFind(s, "outside") >= 0) {
            rules[nRules].type = 9;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = tf;
            nRules++;
        }

        if(nRules >= 20) break;
    }
}

double ExtraiValorApos(string texto, string chave) {
    int pos = StringFind(texto, chave);
    if(pos < 0) return 0;
    pos += StringLen(chave);
    int dummy = pos;
    return ExtraiNumero(texto, dummy);
}

double ExtraiNumero(string texto, int &pos) {
    while(pos < StringLen(texto) && !((texto[pos]>='0' && texto[pos]<='9') || texto[pos]=='.')) pos++;
    int start = pos;
    while(pos < StringLen(texto) && ((texto[pos]>='0' && texto[pos]<='9') || texto[pos]=='.')) pos++;
    if(start == pos) return 0;
    return StringToDouble(StringSubstr(texto, start, pos - start));
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    if(StringFind(nome, "m1") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M1;
    if(StringFind(nome, "m5") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M5;
    if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
    if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
    if(StringFind(nome, "h1") >= 0) return PERIOD_H1;
    if(StringFind(nome, "h4") >= 0) return PERIOD_H4;
    if(StringFind(nome, "d1") >= 0) return PERIOD_D1;
    if(StringFind(nome, "minutos") >= 0) {
        int p = StringFind(nome, "minutos") - 1;
        while(p >= 0 && nome[p] == ' ') p--;
        int end = p + 1;
        while(p >= 0 && (nome[p] >= '0' && nome[p] <= '9')) p--;
        int val = (int)StringToInteger(StringSubstr(nome, p + 1, end - p - 1));
        if(val == 1) return PERIOD_M1;
        if(val == 5) return PERIOD_M5;
        if(val == 15) return PERIOD_M15;
        if(val == 30) return PERIOD_M30;
    }
    return PERIOD_CURRENT;
}

void ResetStrategy() {
    for(int i=0; i<20; i++) rules[i].Reset();
    nRules = 0;
}

void AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i=0; i<nRules; i++) {
        if(rules[i].intent == SIGNAL_BUY) buyRules++;
        if(rules[i].intent == SIGNAL_SELL) sellRules++;

        if(AvaliaRegra(rules[i])) {
            if(rules[i].intent == SIGNAL_BUY) buyVotes++;
            if(rules[i].intent == SIGNAL_SELL) sellVotes++;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) {
        EnviaOrdem(ORDER_TYPE_BUY, CalculaLote(p_riskPercent), "Sinal de Compra");
    } else if(sellRules > 0 && sellVotes == sellRules) {
        EnviaOrdem(ORDER_TYPE_SELL, CalculaLote(p_riskPercent), "Sinal de Venda");
    }
}

bool AvaliaRegra(Rule &r) {
    if(r.type == 1) { // MA
        if(r.handle2 != INVALID_HANDLE) { // Cross
            double fast1 = GetBufferValue(r.handle1, 0, 1);
            double fast2 = GetBufferValue(r.handle1, 0, 2);
            double slow1 = GetBufferValue(r.handle2, 0, 1);
            double slow2 = GetBufferValue(r.handle2, 0, 2);
            if(r.intent == SIGNAL_BUY) return (fast2 <= slow2 && fast1 > slow1);
            if(r.intent == SIGNAL_SELL) return (fast2 >= slow2 && fast1 < slow1);
        } else { // Price Cross
            double ma1 = GetBufferValue(r.handle1, 0, 1);
            double ma2 = GetBufferValue(r.handle1, 0, 2);
            double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double p2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            if(r.intent == SIGNAL_BUY) return (p2 <= ma2 && p1 > ma1);
            if(r.intent == SIGNAL_SELL) return (p2 >= ma2 && p1 < ma1);
        }
    }
    if(r.type == 2) { // RSI
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);
        if(r.intent == SIGNAL_BUY) return (rsi2 <= r.d1 && rsi1 > r.d1);
        if(r.intent == SIGNAL_SELL) return (rsi2 >= r.d1 && rsi1 < r.d1);
    }
    if(r.type == 3) { // Stoch
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double d2 = GetBufferValue(r.handle1, 1, 2);
        if(r.intent == SIGNAL_BUY) return (k2 <= d2 && k1 > d1);
        if(r.intent == SIGNAL_SELL) return (k2 >= d2 && k1 < d1);
    }
    if(r.type == 4) { // BB
        double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double upper1 = GetBufferValue(r.handle1, 1, 1);
        double lower1 = GetBufferValue(r.handle1, 2, 1);
        if(r.intent == SIGNAL_BUY) return (close1 < lower1);
        if(r.intent == SIGNAL_SELL) return (close1 > upper1);
    }
    if(r.type == 5) { // DailyBreak
        double hi = iHigh(_Symbol, PERIOD_D1, 1);
        double lo = iLow(_Symbol, PERIOD_D1, 1);
        double close = iClose(_Symbol, PERIOD_M1, 0);
        if(r.intent == SIGNAL_BUY) return (close > hi);
        if(r.intent == SIGNAL_SELL) return (close < lo);
    }
    if(r.type == 6) { // Delta
        MqlTick arr[];
        int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buy = 0, sell = 0;
        for(int i=0; i<n; i++) if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
        long delta = buy - sell;
        if(r.intent == SIGNAL_BUY) return (delta > r.p2);
        if(r.intent == SIGNAL_SELL) return (delta < -r.p2);
    }
    if(r.type == 7) { // Vol
        long v1 = iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        long v2 = iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
        return (v1 > v2 * 1.5); // Threshold de pico de volume
    }
    if(r.type == 8) { // AMA
        double ama1 = GetBufferValue(r.handle1, 0, 1);
        double ama2 = GetBufferValue(r.handle1, 0, 2);
        if(r.intent == SIGNAL_BUY) return (ama1 > ama2);
        if(r.intent == SIGNAL_SELL) return (ama1 < ama2);
    }
    if(r.type == 9) { // Bar2 Pattern
        double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
        double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
        bool inside = (h0 < h1 && l0 > l1);
        bool outside = (h0 > h1 && l0 < l1);
        if(inside || outside) {
            bool bullish = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            if(r.intent == SIGNAL_BUY) return bullish;
            if(r.intent == SIGNAL_SELL) return !bullish;
        }
    }
    return false;
}

void EnviaOrdem(int type, double lot, string reason) {
    MqlTick last_tick;
    SymbolInfoTick(_Symbol, last_tick);
    double price = (type == ORDER_TYPE_BUY) ? last_tick.ask : last_tick.bid;
    double sl = 0, tp = 0;

    if(type == ORDER_TYPE_BUY) {
        sl = (p_stopPoints > 0) ? price - p_stopPoints * _Point : 0;
        tp = (p_takePoints > 0) ? price + p_takePoints * _Point : 0;
    } else {
        sl = (p_stopPoints > 0) ? price + p_stopPoints * _Point : 0;
        tp = (p_takePoints > 0) ? price - p_takePoints * _Point : 0;
    }

    // Margin check
    double margin;
    if(!OrderCalcMargin(type, _Symbol, lot, price, margin)) {
        GravaLog("Erro ao calcular margem.");
        return;
    }
    if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
        GravaLog("Margem insuficiente: " + DoubleToString(margin, 2) + " > " + DoubleToString(AccountInfoDouble(ACCOUNT_FREEMARGIN), 2));
        return;
    }

    // Positions limit
    int count = 0;
    for(int i=0; i<PositionsTotal(); i++) {
        if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
    }
    if(count >= p_maxPositions) {
        GravaLog("Limite de posições atingido.");
        return;
    }

    for(int i=0; i<3; i++) {
        if(type == ORDER_TYPE_BUY) {
            if(trade.Buy(lot, _Symbol, price, sl, tp, reason)) {
                GravaLog("Compra executada: " + reason + " Lote: " + DoubleToString(lot, 2));
                SendNotification("Compra executada em " + _Symbol);
                break;
            }
        } else {
            if(trade.Sell(lot, _Symbol, price, sl, tp, reason)) {
                GravaLog("Venda executada: " + reason + " Lote: " + DoubleToString(lot, 2));
                SendNotification("Venda executada em " + _Symbol);
                break;
            }
        }
        int code = trade.ResultRetcode();
        if(code != TRADE_RETCODE_REQUOTES && code != TRADE_RETCODE_OFFQUOTES) break;
        SymbolInfoTick(_Symbol, last_tick);
        price = (type == ORDER_TYPE_BUY) ? last_tick.ask : last_tick.bid;
    }
}

double CalculaLote(double riskPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = capital * riskPercent / 100.0;
    if(p_stopPoints <= 0) return 0.01;

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

    // Martingale
    if(p_useMartingale) {
        HistorySelect(0, TimeCurrent());
        for(int i=HistoryDealsTotal()-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
                break;
            }
        }
    }

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;
    return NormalizeDouble(lot, 2);
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
                double open = PositionGetDouble(POSITION_PRICE_OPEN);
                double cur = PositionGetDouble(POSITION_PRICE_CURRENT);
                double sl = PositionGetDouble(POSITION_SL);
                int type = (int)PositionGetInteger(POSITION_TYPE);

                // Breakeven
                if(p_beStart > 0) {
                    double diff = (type == POSITION_TYPE_BUY) ? (cur - open) : (open - cur);
                    if(diff >= p_beStart * _Point) {
                        double newSL = (type == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
                        if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                            trade.PositionModify(PositionGetTicket(i), newSL, PositionGetDouble(POSITION_TP));
                        }
                    }
                }

                // Trailing
                if(p_trailingStop > 0) {
                    double diff = (type == POSITION_TYPE_BUY) ? (cur - open) : (open - cur);
                    if(diff >= p_trailingStop * _Point) {
                        double newSL = (type == POSITION_TYPE_BUY) ? cur - p_trailingStop * _Point : cur + p_trailingStop * _Point;
                        if((type == POSITION_TYPE_BUY && newSL > sl + p_trailingStep * _Point) || (type == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0))) {
                            trade.PositionModify(PositionGetTicket(i), newSL, PositionGetDouble(POSITION_TP));
                        }
                    }
                }
            }
        }
    }
}

double GetBufferValue(int handle, int buffer, int shift) {
    double res[];
    ArraySetAsSeries(res, true);
    if(CopyBuffer(handle, buffer, shift, 1, res) > 0) return res[0];
    return 0;
}

void GravaLog(string text) {
    int h = FileOpen(LOG_FILE, FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWriteString(h, TimeToString(TimeCurrent()) + ": " + text + "\n");
        FileClose(h);
    }
}

void GravaCSV() {
    int h = FileOpen(STATE_FILE, FILE_WRITE|FILE_CSV|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i=0; i<PositionsTotal(); i++) {
            if(PositionSelectByTicket(PositionGetTicket(i))) {
                if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
                    FileWrite(h,
                        PositionGetInteger(POSITION_TICKET),
                        PositionGetString(POSITION_SYMBOL),
                        PositionGetInteger(POSITION_TYPE),
                        PositionGetDouble(POSITION_VOLUME),
                        PositionGetDouble(POSITION_PRICE_OPEN),
                        TimeToString(PositionGetInteger(POSITION_TIME)),
                        PositionGetDouble(POSITION_SL),
                        PositionGetDouble(POSITION_TP),
                        PositionGetDouble(POSITION_PROFIT),
                        PositionGetString(POSITION_COMMENT)
                    );
                }
            }
        }
        FileClose(h);
    }
}

bool IsTimeAllowed() {
    string now = TimeToString(TimeCurrent(), TIME_MINUTES);
    return (now >= p_startTime);
}

bool AguardaNoticias() {
    // Check binary veto
    int hVeto = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
    if(hVeto != INVALID_HANDLE) {
        string content = FileReadString(hVeto);
        FileClose(hVeto);
        if(StringFind(content, "true") >= 0) return true;
    }

    // Check calendar for 20 min window
    int hCal = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_ANSI);
    if(hCal != INVALID_HANDLE) {
        while(!FileIsEnding(hCal)) {
            string line = FileReadString(hCal);
            datetime eventTime = StringToTime(line);
            if(eventTime > 0) {
                long diff = MathAbs(TimeCurrent() - eventTime);
                if(diff <= 20 * 60) {
                    FileClose(hCal);
                    return true;
                }
            }
        }
        FileClose(hCal);
    }
    return false;
}

void AIOptimizer() {
    HistorySelect(0, TimeCurrent());
    int total = 0, wins = 0;
    for(int i=HistoryDealsTotal()-1; i>=0 && total < 10; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            total++;
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
        }
    }

    if(total >= 5) {
        double winRate = (double)wins / total;
        if(winRate < 0.4) {
            p_riskPercent *= 0.8;
            GravaLog("AIOptimizer: WinRate baixo (" + DoubleToString(winRate, 2) + "). Risco reduzido para " + DoubleToString(p_riskPercent, 2));
        }
    }
}
