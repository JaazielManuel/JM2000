//========================================================================
// MT-LiveExecutor - Agente de Execução ao Vivo em MQL5
//========================================================================

#property copyright "MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- DEFINES
#define EA_MAGIC 123456
#define MAX_RULES 20

//--- ENUMS
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

//--- STRUCTS
struct Rule {
    int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
    int      intent;     // BUY or SELL
    uint     tf;         // Timeframe
    int      p1, p2, p3; // Integer parameters
    double   d1, d2;     // Double parameters
    string   s1;         // String parameter (benchmark symbol)
    int      handle1;    // Indicator handle 1
    int      handle2;    // Indicator handle 2

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        type = 0; intent = 0; tf = 0; p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
        handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
    }
};

//--- GLOBALS
Rule rules[MAX_RULES];
int nRules = 0;

double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_maxTrades = 3;
string p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool   p_useMartingale = false;

int    p_beStart = 0;
int    p_bePlus = 0;
int    p_trailingStop = 0;
int    p_trailingStep = 0;

datetime lastPromptModify = 0;
datetime lastAI = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

//--- UTILITIES
double ExtraiValorApos(string txt, string chave) {
    int pos = StringFind(txt, chave);
    if(pos < 0) return -1;
    int start = pos + StringLen(chave);
    while(start < StringLen(txt) && (StringGetCharacter(txt, start) < '0' || StringGetCharacter(txt, start) > '9') && StringGetCharacter(txt, start) != '.') start++;
    if(start >= StringLen(txt)) return -1;
    return StringToDouble(StringSubstr(txt, start));
}

int ExtraiNumero(string txt, int &pos) {
    while(pos < StringLen(txt) && (StringGetCharacter(txt, pos) < '0' || StringGetCharacter(txt, pos) > '9')) pos++;
    if(pos >= StringLen(txt)) return -1;
    int start = pos;
    while(pos < StringLen(txt) && ((StringGetCharacter(txt, pos) >= '0' && StringGetCharacter(txt, pos) <= '9') || StringGetCharacter(txt, pos) == '.')) pos++;
    return (int)StringToInteger(StringSubstr(txt, start, pos - start));
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    StringToLower(nome);
    if(StringFind(nome, "m1") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M1;
    if(StringFind(nome, "m5") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M5;
    if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
    if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
    if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
    if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

//--- NLP PARSER
void InterpretaPrompt(string prompt) {
    StringToLower(prompt);

    // Clear old rules
    for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
    nRules = 0;

    // Global parameters
    double r = ExtraiValorApos(prompt, "risco de");
    if(r > 0) p_riskPercent = r;

    double stop = ExtraiValorApos(prompt, "stop de");
    if(stop > 0) p_stopPoints = (int)stop;

    double take = ExtraiValorApos(prompt, "take de");
    if(take > 0) p_takePoints = (int)take;

    double maxT = ExtraiValorApos(prompt, "máximo");
    if(maxT > 0) p_maxTrades = (int)maxT;

    if(StringFind(prompt, "martingale") >= 0) p_useMartingale = true;

    // Timeframe global
    if(StringFind(prompt, "1 minuto") >= 0 || StringFind(prompt, "m1") >= 0) p_frequency = PERIOD_M1;
    else if(StringFind(prompt, "5 minutos") >= 0 || StringFind(prompt, "m5") >= 0) p_frequency = PERIOD_M5;
    else if(StringFind(prompt, "15 minutos") >= 0 || StringFind(prompt, "m15") >= 0) p_frequency = PERIOD_M15;
    else if(StringFind(prompt, "30 minutos") >= 0 || StringFind(prompt, "m30") >= 0) p_frequency = PERIOD_M30;
    else if(StringFind(prompt, "1 hora") >= 0 || StringFind(prompt, "h1") >= 0) p_frequency = PERIOD_H1;

    // Start time
    int tPos = StringFind(prompt, "depois das");
    if(tPos < 0) tPos = StringFind(prompt, "início");
    if(tPos >= 0) {
        int hPos = tPos;
        int h = ExtraiNumero(prompt, hPos);
        if(h >= 0) {
            int m = 0;
            if(StringGetCharacter(prompt, hPos) == ':' || StringGetCharacter(prompt, hPos) == 'h') {
                hPos++;
                m = ExtraiNumero(prompt, hPos);
                if(m < 0) m = 0;
            }
            p_startTime = StringFormat("%02d:%02d", h, m);
        }
    }

    // Breakeven & Trailing
    double beAt = ExtraiValorApos(prompt, "atingir +");
    if(beAt > 0) {
        p_beStart = (int)beAt;
        p_bePlus = (int)ExtraiValorApos(prompt, "entrada +");
    }

    double ts = ExtraiValorApos(prompt, "trailing stop");
    if(ts > 0) {
        p_trailingStop = (int)ts;
        p_trailingStep = (int)ExtraiValorApos(prompt, "passo");
        if(p_trailingStep <= 0) p_trailingStep = 10;
    }

    // Split rules by period/connector
    string segments[];
    ushort sep = StringGetCharacter(".", 0);
    int nSegments = StringSplit(prompt, sep, segments);

    int currentIntent = NONE;

    for(int i = 0; i < nSegments && nRules < MAX_RULES; i++) {
        string seg = segments[i];
        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

        if(currentIntent == NONE) continue;

        // MA Rule
        if(StringFind(seg, "média") >= 0) {
            rules[nRules].type = 1;
            rules[nRules].intent = currentIntent;
            int pos = StringFind(seg, "média");
            rules[nRules].p1 = ExtraiNumero(seg, pos);
            if(rules[nRules].p1 <= 0) rules[nRules].p1 = 20;
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            rules[nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
            if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
        }

        // RSI Rule
        if(StringFind(seg, "rsi") >= 0) {
            rules[nRules].type = 2;
            rules[nRules].intent = currentIntent;
            int pos = StringFind(seg, "rsi");
            int val1 = ExtraiNumero(seg, pos);
            int val2 = ExtraiNumero(seg, pos);
            if(val2 > 0) {
                rules[nRules].p1 = val1;
                rules[nRules].d1 = val2;
            } else {
                rules[nRules].p1 = 14;
                rules[nRules].d1 = val1;
            }
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
            if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
        }

        // Stoch Rule
        if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
            rules[nRules].type = 3;
            rules[nRules].intent = currentIntent;
            rules[nRules].p1 = 5; rules[nRules].p2 = 3; rules[nRules].p3 = 3; // Default
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            rules[nRules].handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
        }

        // BB Rule
        if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bb") >= 0) {
            rules[nRules].type = 4;
            rules[nRules].intent = currentIntent;
            rules[nRules].p1 = 20; rules[nRules].d1 = 2.0; // Default
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            rules[nRules].handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
            if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
        }

        // DailyBreak Rule
        if(StringFind(seg, "breakout diário") >= 0 || StringFind(seg, "máxima/mínima de ontem") >= 0) {
            rules[nRules].type = 5;
            rules[nRules].intent = currentIntent;
            nRules++;
        }

        // Delta Rule
        if(StringFind(seg, "delta") >= 0 || StringFind(seg, "agressão") >= 0) {
            rules[nRules].type = 6;
            rules[nRules].intent = currentIntent;
            int pos = StringFind(seg, "delta");
            rules[nRules].p1 = 60; // seconds
            rules[nRules].p2 = 300; // threshold
            int val = ExtraiNumero(seg, pos);
            if(val > 0) rules[nRules].p2 = val;
            nRules++;
        }

        // Vol Rule
        if(StringFind(seg, "volume") >= 0) {
            rules[nRules].type = 7;
            rules[nRules].intent = currentIntent;
            rules[nRules].p1 = 12; // period
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            nRules++;
        }

        // AMA Rule
        if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
            rules[nRules].type = 8;
            rules[nRules].intent = currentIntent;
            rules[nRules].p1 = 10; rules[nRules].p2 = 2; rules[nRules].p3 = 30;
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            rules[nRules].handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 10, 2, 30, 0, PRICE_CLOSE);
            if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
        }

        // Bar2 Rule
        if(StringFind(seg, "inside") >= 0 || StringFind(seg, "outside") >= 0 || StringFind(seg, "padrão de 2 barras") >= 0) {
            rules[nRules].type = 9;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            nRules++;
        }

        // RS Rule
        if(StringFind(seg, "força relativa") >= 0 || StringFind(seg, "rs") >= 0) {
            rules[nRules].type = 10;
            rules[nRules].intent = currentIntent;
            rules[nRules].p1 = 14;
            rules[nRules].s1 = "US30"; // Default benchmark
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 14, PRICE_CLOSE);
            rules[nRules].handle2 = iRSI("US30", (ENUM_TIMEFRAMES)rules[nRules].tf, 14, PRICE_CLOSE);
            if(rules[nRules].handle1 != INVALID_HANDLE && rules[nRules].handle2 != INVALID_HANDLE) nRules++;
        }

        // AI Rule
        if(StringFind(seg, "ia") >= 0 || StringFind(seg, "inteligência") >= 0 || StringFind(seg, "previsão") >= 0) {
            rules[nRules].type = 11;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = PeriodoTexto(seg);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;
            rules[nRules].handle1 = iATR(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 14);
            if(rules[nRules].handle1 != INVALID_HANDLE) nRules++;
        }
    }
}

//--- SIGNAL EVALUATION
double GetBufferValue(int handle, int buffer, int shift) {
    double res[];
    ArraySetAsSeries(res, true);
    if(CopyBuffer(handle, buffer, shift, 1, res) > 0) return res[0];
    return 0;
}

Signal AvaliaRegra(Rule &r) {
    if(r.type == 1) { // MA
        double ma1 = GetBufferValue(r.handle1, 0, 1);
        double ma2 = GetBufferValue(r.handle1, 0, 2);
        double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
        if(r.intent == BUY && close2 < ma2 && close1 > ma1) return BUY;
        if(r.intent == SELL && close2 > ma2 && close1 < ma1) return SELL;
    }
    else if(r.type == 2) { // RSI
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);
        if(r.intent == BUY && rsi2 < r.d1 && rsi1 > r.d1) return BUY;
        if(r.intent == SELL && rsi2 > r.d1 && rsi1 < r.d1) return SELL;
    }
    else if(r.type == 3) { // Stoch
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);
        if(r.intent == BUY && k2 < d2 && k1 > d1) return BUY;
        if(r.intent == SELL && k2 > d2 && k1 < d1) return SELL;
    }
    else if(r.type == 4) { // BB
        double upper = GetBufferValue(r.handle1, 1, 1);
        double lower = GetBufferValue(r.handle1, 2, 1);
        double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        if(r.intent == BUY && close < lower) return BUY;
        if(r.intent == SELL && close > upper) return SELL;
    }
    else if(r.type == 5) { // DailyBreak
        double hi = iHigh(_Symbol, PERIOD_D1, 1);
        double lo = iLow(_Symbol, PERIOD_D1, 1);
        double close = iClose(_Symbol, PERIOD_CURRENT, 0);
        if(r.intent == BUY && close > hi) return BUY;
        if(r.intent == SELL && close < lo) return SELL;
    }
    else if(r.type == 6) { // Delta
        MqlTick ticks[];
        int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buyVol = 0, sellVol = 0;
        for(int i=0; i<n; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) != 0) buyVol += (long)ticks[i].volume;
            else if((ticks[i].flags & TICK_FLAG_SELL) != 0) sellVol += (long)ticks[i].volume;
        }
        long delta = buyVol - sellVol;
        if(r.intent == BUY && delta > r.p2) return BUY;
        if(r.intent == SELL && delta < -r.p2) return SELL;
    }
    else if(r.type == 7) { // Vol
        long vol[];
        CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1 + 1, vol);
        if(ArraySize(vol) < r.p1 + 1) return NONE;
        long currentVol = vol[r.p1];
        long maxVol = 0;
        for(int i=0; i<r.p1; i++) if(vol[i] > maxVol) maxVol = vol[i];
        if(currentVol > maxVol) return (Signal)r.intent;
    }
    else if(r.type == 8) { // AMA
        double ama1 = GetBufferValue(r.handle1, 0, 1);
        double ama2 = GetBufferValue(r.handle1, 0, 2);
        if(r.intent == BUY && ama1 > ama2) return BUY;
        if(r.intent == SELL && ama1 < ama2) return SELL;
    }
    else if(r.type == 9) { // Bar2
        double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
        double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
        bool inside = h0 < h1 && l0 > l1;
        bool outside = h0 > h1 && l0 < l1;
        if(inside || outside) {
            bool bullish = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            if(r.intent == BUY && bullish) return BUY;
            if(r.intent == SELL && !bullish) return SELL;
        }
    }
    else if(r.type == 10) { // RS
        double rsi_main = GetBufferValue(r.handle1, 0, 1);
        double rsi_bench = GetBufferValue(r.handle2, 0, 1);
        if(r.intent == BUY && rsi_main > rsi_bench + 5) return BUY;
        if(r.intent == SELL && rsi_main < rsi_bench - 5) return SELL;
    }
    else if(r.type == 11) { // AI
        double atr = GetBufferValue(r.handle1, 0, 1);
        double body = MathAbs(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) - iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1));
        bool bullish = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        if(body > 1.5 * atr) {
            if(r.intent == BUY && bullish) return BUY;
            if(r.intent == SELL && !bullish) return SELL;
        }
    }
    return NONE;
}

Signal AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i = 0; i < nRules; i++) {
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

//--- TRADE EXECUTION
double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riscoAbs = capital * riscoPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(p_stopPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double lote = riscoAbs / (p_stopPoints * (tickValue / (tickSize / _Point)));

    // Martingale
    if(p_useMartingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lote *= 2.0;
                break;
            }
        }
    }

    double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lote = MathFloor(lote / stepVol) * stepVol;
    if(lote < minVol) lote = minVol;
    if(lote > maxVol) lote = maxVol;
    return lote;
}

bool EnviaOrdem(Signal s, double lote) {
    if(s == NONE) return false;
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
    double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

    trade.SetExpertMagicNumber(EA_MAGIC);

    bool res = false;
    for(int i=0; i<3; i++) {
        if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor");
        else res = trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor");

        if(res && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
            GravaLog(StringFormat("Ordem %s enviada: %.2f lotes", (s == BUY ? "BUY" : "SELL"), lote));
            SendNotification(StringFormat("Trade Executado: %s %.2f", (s == BUY ? "BUY" : "SELL"), lote));
            return true;
        }

        uint ret = trade.ResultRetcode();
        if(ret != TRADE_RETCODE_REQUOTES && ret != TRADE_RETCODE_OFFQUOTES) break;
        price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    }

    GravaLog("Erro ao enviar ordem: " + trade.ResultComment());
    return false;
}

//--- POSITION MANAGEMENT
void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC && PositionGetString(POSITION_SYMBOL) == _Symbol) {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

            // Breakeven
            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                double currentSL = PositionGetDouble(POSITION_SL);
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
                double currentSL = PositionGetDouble(POSITION_SL);
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (newSL > currentSL + p_trailingStep * _Point)) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < currentSL - p_trailingStep * _Point || currentSL == 0))) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

//--- UTILITIES CONTINUED
bool AguardaNoticias() {
    if(FileIsExist("news_veto.txt")) {
        int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT);
        string content = FileReadString(h);
        FileClose(h);
        if(StringFind(content, "VETO") >= 0) return true;
    }
    return false;
}

bool IsTimeAllowed() {
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    string currentTime = StringFormat("%02d:%02d", dt.hour, dt.min);
    return (currentTime >= p_startTime);
}

void GravaLog(string texto) {
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWriteString(h, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
        FileClose(h);
    }
    Print(texto);
}

void GravaCSV() {
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "Lots", "Profit");
        for(int i=0; i<PositionsTotal(); i++) {
            ulong ticket = PositionGetTicket(i);
            if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
                FileWrite(h, ticket, PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PROFIT));
            }
        }
        FileClose(h);
    }
}

//--- AI OPTIMIZER
void CalculaStats() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, losses = 0;
    double profit = 0;
    for(int i = 0; i < total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            profit += p;
            if(p > 0) wins++;
            else if(p < 0) losses++;
        }
    }
    double wr = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
    GravaLog(StringFormat("Stats: WR %.2f, Profit %.2f", wr, profit));
}

void AIOptimizer() {
    if(TimeCurrent() - lastAI < 3600) return;
    lastAI = TimeCurrent();

    HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
    int total = HistoryDealsTotal();
    int lastWins = 0, count = 0;
    for(int i = total - 1; i >= 0 && count < 10; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) lastWins++;
            count++;
        }
    }

    if(count >= 5 && (double)lastWins / count < 0.4) {
        p_riskPercent *= 0.5;
        GravaLog("AI Optimizer: Win rate baixo, reduzindo risco para " + DoubleToString(p_riskPercent, 2));
    }
}

//--- EVENT HANDLERS
int OnInit() {
    EventSetTimer(1);
    symInfo.Name(_Symbol);
    accInfo.Login();
    trade.SetExpertMagicNumber(EA_MAGIC);

    GravaLog("MT-LiveExecutor Iniciado");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
    GravaLog("MT-LiveExecutor Finalizado");
}

void OnTimer() {
    // Monitor prompt.txt
    datetime modify = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
    if(modify != lastPromptModify) {
        lastPromptModify = modify;
        int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT);
        if(h != INVALID_HANDLE) {
            string prompt = FileReadString(h);
            FileClose(h);
            InterpretaPrompt(prompt);
            GravaLog("Novo prompt interpretado: " + prompt);
        }
    }

    AIOptimizer();
    GravaCSV();
}

void OnTick() {
    GerenciaPosicoes();

    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar == lastBar) return;
    lastBar = currentBar;

    if(!IsTimeAllowed()) return;
    if(AguardaNoticias()) return;
    if(PositionsTotal() >= p_maxTrades) return;

    Signal s = AvaliaTudo();
    if(s != NONE) {
        double lote = CalculaLote(p_riskPercent);
        EnviaOrdem(s, lote);
    }
}
