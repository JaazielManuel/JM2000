//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2023, Jules AI Agency |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2023, Jules AI Agency"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- DEFINES & CONSTANTS ---
#define EA_MAGIC 123456

// --- ENUMS ---
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

// --- STRUCTS ---
struct Rule {
    int      type;    // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
    int      intent;  // Signal enum
    ENUM_TIMEFRAMES tf;
    int      p1, p2, p3;
    double   d1, d2;
    int      handle1, handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        type = 0; intent = NONE; tf = PERIOD_CURRENT;
        p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0;
        handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
    }
};

// --- GLOBALS ---
Rule rules[20];
int nRules = 0;

double p_riskPercent = 1.0;
int    p_stopPoints = 0;
int    p_takePoints = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;
string p_startTime = "00:00";
bool   p_useMartingale = false;
int    p_beStart = 0;
int    p_bePlus = 0;
int    p_trailingStop = 0;
int    p_trailingStep = 0;
int    p_maxTrades = 3;

datetime lastPromptUpdate = 0;
datetime lastCSVUpdate = 0;

CTrade trade;

// --- UTILITIES ---

double ExtraiNumero(string text, int &pos) {
    string res = "";
    bool found = false;
    for(int i = pos; i < StringLen(text); i++) {
        ushort c = StringGetCharacter(text, i);
        if((c >= '0' && c <= '9') || c == '.') {
            res += CharToString((uchar)c);
            found = true;
        } else if(found) {
            pos = i;
            return StringToDouble(res);
        }
    }
    pos = StringLen(text);
    return StringToDouble(res);
}

double ExtraiValorApos(string text, string keyword) {
    string work = text;
    StringToLower(work);
    int p = StringFind(work, keyword);
    if(p < 0) return -1;
    int pos = p + StringLen(keyword);
    return ExtraiNumero(work, pos);
}

ENUM_TIMEFRAMES PeriodoTexto(string text) {
    string work = text;
    StringToLower(work);
    if(StringFind(work, "m1") >= 0 && StringFind(work, "m15") < 0) return PERIOD_M1;
    if(StringFind(work, "m5") >= 0 && StringFind(work, "m15") < 0) return PERIOD_M5;
    if(StringFind(work, "m15") >= 0) return PERIOD_M15;
    if(StringFind(work, "m30") >= 0) return PERIOD_M30;
    if(StringFind(work, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(work, "h4") >= 0)  return PERIOD_H4;
    if(StringFind(work, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

double GetBufferValue(int handle, int buffer, int shift) {
    double val[1];
    if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
    return val[0];
}

void ResetStrategy() {
    for(int i = 0; i < 20; i++) rules[i].Reset();
    nRules = 0;
    p_riskPercent = 1.0; p_stopPoints = 0; p_takePoints = 0;
    p_frequency = PERIOD_CURRENT; p_startTime = "00:00"; p_useMartingale = false;
    p_beStart = 0; p_bePlus = 0; p_trailingStop = 0; p_trailingStep = 0;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string work = prompt;
    StringToLower(work);

    // Global parameters
    double val;
    if((val = ExtraiValorApos(work, "risco de")) > 0) p_riskPercent = val;
    if((val = ExtraiValorApos(work, "stop de")) > 0) p_stopPoints = (int)val;
    if((val = ExtraiValorApos(work, "take de")) > 0) p_takePoints = (int)val;
    if((val = ExtraiValorApos(work, "máximo")) > 0) p_maxTrades = (int)val;
    if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

    p_frequency = PeriodoTexto(work);

    // Timing
    int pTime = StringFind(work, "depois das");
    if(pTime < 0) pTime = StringFind(work, "início");
    if(pTime < 0) pTime = StringFind(work, "começar");
    if(pTime >= 0) {
        int hPos = StringFind(work, "h", pTime);
        if(hPos >= 0 && hPos < pTime + 20) {
            int pos = pTime + 10;
            int h = (int)ExtraiNumero(work, pos);
            int m = 0;
            if(StringGetCharacter(work, pos) == ':') {
                pos++;
                m = (int)ExtraiNumero(work, pos);
            }
            p_startTime = StringFormat("%02d:%02d", h, m);
        }
    }

    // Trade Management
    if((val = ExtraiValorApos(work, "atingir")) > 0) p_beStart = (int)val;
    if((val = ExtraiValorApos(work, "entrada +")) > 0) p_bePlus = (int)val;
    if((val = ExtraiValorApos(work, "trailing")) > 0) {
        p_trailingStop = (int)val;
        p_trailingStep = (int)ExtraiValorApos(work, "passo");
        if(p_trailingStep < 0) p_trailingStep = 10;
    }

    // Rules
    string segments[];
    ushort sep = StringGetCharacter(".", 0);
    int nSeg = StringSplit(work, sep, segments);
    int currentIntent = NONE;

    for(int i = 0; i < nSeg && nRules < 20; i++) {
        string seg = segments[i];
        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

        if(currentIntent == NONE) continue;

        ENUM_TIMEFRAMES stf = PeriodoTexto(seg);
        if(stf == PERIOD_CURRENT) stf = p_frequency;

        // MA
        if(StringFind(seg, "média") >= 0) {
            int pos = StringFind(seg, "média");
            int p1 = (int)ExtraiNumero(seg, pos);
            if(p1 <= 0) p1 = 20;
            int h = iMA(_Symbol, stf, p1, 0, MODE_SMA, PRICE_CLOSE);
            if(h != INVALID_HANDLE) {
               rules[nRules].type = 1;
               rules[nRules].intent = currentIntent;
               rules[nRules].tf = stf;
               rules[nRules].p1 = p1;
               rules[nRules].handle1 = h;
               nRules++;
            }
        }
        // RSI
        else if(StringFind(seg, "rsi") >= 0) {
            int pos = StringFind(seg, "rsi");
            int p1 = (int)ExtraiNumero(seg, pos);
            double d1 = ExtraiNumero(seg, pos);
            if(d1 == 0) { d1 = p1; p1 = 14; } // Heuristic: if only one number, it's the threshold
            int h = iRSI(_Symbol, stf, p1, PRICE_CLOSE);
            if(h != INVALID_HANDLE) {
               rules[nRules].type = 2;
               rules[nRules].intent = currentIntent;
               rules[nRules].tf = stf;
               rules[nRules].p1 = p1;
               rules[nRules].d1 = d1;
               rules[nRules].handle1 = h;
               nRules++;
            }
        }
        // Stochastic
        else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
            int h = iStochastic(_Symbol, stf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            if(h != INVALID_HANDLE) {
               rules[nRules].type = 3;
               rules[nRules].intent = currentIntent;
               rules[nRules].tf = stf;
               rules[nRules].handle1 = h;
               nRules++;
            }
        }
        // BB
        else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bandas") >= 0) {
            int h = iBands(_Symbol, stf, 20, 0, 2.0, PRICE_CLOSE);
            if(h != INVALID_HANDLE) {
               rules[nRules].type = 4;
               rules[nRules].intent = currentIntent;
               rules[nRules].tf = stf;
               rules[nRules].handle1 = h;
               nRules++;
            }
        }
        // DailyBreak
        else if(StringFind(seg, "máxima") >= 0 || StringFind(seg, "mínima") >= 0 || StringFind(seg, "romper") >= 0) {
            rules[nRules].type = 5;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = PERIOD_D1;
            nRules++;
        }
        // Delta
        else if(StringFind(seg, "agressão") >= 0 || StringFind(seg, "delta") >= 0) {
            rules[nRules].type = 6;
            rules[nRules].intent = currentIntent;
            rules[nRules].p1 = 60; // default 60s
            rules[nRules].p2 = 300; // default threshold
            nRules++;
        }
        // Volume
        else if(StringFind(seg, "volume") >= 0) {
            rules[nRules].type = 7;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = stf;
            nRules++;
        }
        // AMA
        else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "kaufman") >= 0) {
            int h = iAMA(_Symbol, stf, 10, 2, 30, 0, PRICE_CLOSE);
            if(h != INVALID_HANDLE) {
               rules[nRules].type = 8;
               rules[nRules].intent = currentIntent;
               rules[nRules].tf = stf;
               rules[nRules].handle1 = h;
               nRules++;
            }
        }
        // Bar2
        else if(StringFind(seg, "padrão") >= 0 || StringFind(seg, "inside") >= 0) {
            rules[nRules].type = 9;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = stf;
            nRules++;
        }
        // RS
        else if(StringFind(seg, "força relativa") >= 0 || StringFind(seg, "bench") >= 0) {
            int h1 = iRSI(_Symbol, stf, 14, PRICE_CLOSE);
            int h2 = iRSI("US30", stf, 14, PRICE_CLOSE);
            if(h1 != INVALID_HANDLE && h2 != INVALID_HANDLE) {
               rules[nRules].type = 10;
               rules[nRules].intent = currentIntent;
               rules[nRules].tf = stf;
               rules[nRules].handle1 = h1;
               rules[nRules].handle2 = h2;
               nRules++;
            }
        }
        // AI
        else if(StringFind(seg, "previsão") >= 0 || StringFind(seg, "ia") >= 0) {
            int h = iATR(_Symbol, stf, 14);
            if(h != INVALID_HANDLE) {
               rules[nRules].type = 11;
               rules[nRules].intent = currentIntent;
               rules[nRules].tf = stf;
               rules[nRules].handle1 = h;
               nRules++;
            }
        }
    }
}

double CalculaLote(double riscoPercent) {
    double lot = 0;
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = capital * (riscoPercent / 100.0);

    int sl = (p_stopPoints > 0) ? p_stopPoints : 100;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(sl > 0) {
        lot = riskAmount / (sl * (tickValue / (tickSize / _Point)));
    }

    // Martingale
    if(p_useMartingale) {
        if(HistorySelect(TimeCurrent() - 86400, TimeCurrent())) {
            int total = HistoryDealsTotal();
            for(int i = total - 1; i >= 0; i--) {
                ulong ticket = HistoryDealGetTicket(i);
                if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                    if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
                    break;
                }
            }
        }
    }

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    lot = MathFloor(lot / step) * step;
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    return lot;
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl = PositionGetDouble(POSITION_SL);
            double tp = PositionGetDouble(POSITION_TP);

            int points = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (int)((currentPrice - openPrice) / _Point) : (int)((openPrice - currentPrice) / _Point);

            // Breakeven
            if(p_beStart > 0 && points >= p_beStart) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                    trade.PositionModify(PositionGetTicket(i), newSL, tp);
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && points >= p_trailingStop) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
                if(MathAbs(newSL - sl) >= p_trailingStep * _Point) {
                    if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSL > sl) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < sl || sl == 0))) {
                        trade.PositionModify(PositionGetTicket(i), newSL, tp);
                    }
                }
            }
        }
    }
}

int AvaliaRegra(Rule &r) {
    if(r.type == 1) { // MA
        double ma1 = GetBufferValue(r.handle1, 0, 1);
        double ma2 = GetBufferValue(r.handle1, 0, 2);
        double c1 = iClose(_Symbol, r.tf, 1);
        double c2 = iClose(_Symbol, r.tf, 2);
        if(r.intent == BUY && c2 < ma2 && c1 > ma1) return 1;
        if(r.intent == SELL && c2 > ma2 && c1 < ma1) return 1;
    }
    else if(r.type == 2) { // RSI
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);
        if(r.intent == BUY && rsi2 < r.d1 && rsi1 > r.d1) return 1;
        if(r.intent == SELL && rsi2 > r.d1 && rsi1 < r.d1) return 1;
    }
    else if(r.type == 3) { // Stoch
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);
        if(r.intent == BUY && k2 < d2 && k1 > d1) return 1;
        if(r.intent == SELL && k2 > d2 && k1 < d1) return 1;
    }
    else if(r.type == 4) { // BB
        double close = iClose(_Symbol, r.tf, 1);
        double upper = GetBufferValue(r.handle1, 1, 1);
        double lower = GetBufferValue(r.handle1, 2, 1);
        if(r.intent == BUY && close < lower) return 1;
        if(r.intent == SELL && close > upper) return 1;
    }
    else if(r.type == 5) { // DailyBreak
        double hi = iHigh(_Symbol, PERIOD_D1, 1);
        double lo = iLow(_Symbol, PERIOD_D1, 1);
        double close = iClose(_Symbol, PERIOD_CURRENT, 0);
        if(r.intent == BUY && close > hi) return 1;
        if(r.intent == SELL && close < lo) return 1;
    }
    else if(r.type == 6) { // Delta
        MqlTick ticks[];
        int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buyVol = 0, sellVol = 0;
        for(int i = 0; i < n; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
            else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
        }
        long delta = buyVol - sellVol;
        if(r.intent == BUY && delta > r.p2) return 1;
        if(r.intent == SELL && delta < -r.p2) return 1;
    }
    else if(r.type == 7) { // Vol
        long v1 = iVolume(_Symbol, r.tf, 1);
        long v2 = iVolume(_Symbol, r.tf, 2);
        if(v1 > v2 * 1.5) return 1;
    }
    else if(r.type == 8) { // AMA
        double ama1 = GetBufferValue(r.handle1, 0, 1);
        double ama2 = GetBufferValue(r.handle1, 0, 2);
        if(r.intent == BUY && ama1 > ama2) return 1;
        if(r.intent == SELL && ama1 < ama2) return 1;
    }
    else if(r.type == 9) { // Bar2
        double h1 = iHigh(_Symbol, r.tf, 1); double l1 = iLow(_Symbol, r.tf, 1);
        double h2 = iHigh(_Symbol, r.tf, 2); double l2 = iLow(_Symbol, r.tf, 2);
        bool inside = (h1 < h2 && l1 > l2);
        bool outside = (h1 > h2 && l1 < l2);
        if(inside || outside) return 1;
    }
    else if(r.type == 10) { // RS (Simplified RSI compare)
        double rsiMain = GetBufferValue(r.handle1, 0, 1);
        double rsiBench = GetBufferValue(r.handle2, 0, 1);
        if(r.intent == BUY && rsiMain > rsiBench) return 1;
        if(r.intent == SELL && rsiMain < rsiBench) return 1;
    }
    else if(r.type == 11) { // AI (Candle vs ATR)
        double atr = GetBufferValue(r.handle1, 0, 1);
        double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
        bool bullish = iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1);
        if(body > atr * 1.5) {
            if(r.intent == BUY && bullish) return 1;
            if(r.intent == SELL && !bullish) return 1;
        }
    }
    return 0;
}

Signal AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i = 0; i < nRules; i++) {
        int res = AvaliaRegra(rules[i]);
        if(rules[i].intent == BUY) {
            buyRules++;
            buyVotes += res;
        } else if(rules[i].intent == SELL) {
            sellRules++;
            sellVotes += res;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) return BUY;
    if(sellRules > 0 && sellVotes == sellRules) return SELL;
    return NONE;
}

void EnviaOrdem(Signal s, double lote, int slPoints, int tpPoints) {
    if(s == NONE) return;

    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = 0, tp = 0;

    if(slPoints > 0) sl = (s == BUY) ? price - slPoints * _Point : price + slPoints * _Point;
    if(tpPoints > 0) tp = (s == BUY) ? price + tpPoints * _Point : price - tpPoints * _Point;

    // Margin Check
    double marginReq;
    ENUM_ORDER_TYPE orderType = (s == BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if(!OrderCalcMargin(orderType, _Symbol, lote, price, marginReq)) return;
    if(marginReq > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
        Print("Falta de margem: Necessário ", marginReq, " Disponível ", AccountInfoDouble(ACCOUNT_FREEMARGIN));
        return;
    }

    // Retry Logic
    for(int i = 0; i < 3; i++) {
        bool res = (s == BUY) ? trade.Buy(lote, _Symbol, price, sl, tp) : trade.Sell(lote, _Symbol, price, sl, tp);
        if(res) {
            uint ret = trade.ResultRetcode();
            if(ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_PLACED) {
                SendNotification(StringFormat("Trade Executado: %s %.2f @ %f", (s == BUY ? "BUY" : "SELL"), lote, price));
                SendMail("Trade Executado", StringFormat("Trade Executado: %s %.2f @ %f", (s == BUY ? "BUY" : "SELL"), lote, price));
                break;
            } else if(ret == TRADE_RETCODE_REQUOTES || ret == TRADE_RETCODE_OFFQUOTES) {
                Sleep(100);
                price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
                continue;
            } else break;
        } else break;
    }
}

bool AguardaNoticias() {
    int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
    if(h != INVALID_HANDLE) {
        string content = FileReadString(h);
        FileClose(h);
        if(StringFind(content, "VETO") >= 0) return true;
    }
    return false;
}

void GravaLog(string text) {
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWriteString(h, TimeToString(TimeCurrent()) + ": " + text + "\r\n");
        FileClose(h);
    }
}

void GravaCSV() {
    if(TimeCurrent() - lastCSVUpdate < 5) return;
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Symbol", "Ticket", "Type", "Lots", "PriceOpen", "SL", "TP", "Profit");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(PositionSelectByTicket(PositionGetTicket(i))) {
                if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
                    FileWrite(h, PositionGetString(POSITION_SYMBOL), PositionGetTicket(i), PositionGetInteger(POSITION_TYPE),
                              PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN),
                              PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT));
                }
            }
        }
        FileClose(h);
        lastCSVUpdate = TimeCurrent();
    }
}

void AIOptimizer() {
    if(!HistorySelect(TimeCurrent() - 36000, TimeCurrent())) return;
    int total = HistoryDealsTotal();
    int wins = 0, count = 0;
    for(int i = total - 1; i >= 0 && count < 10; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            count++;
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
        }
    }
    if(count >= 5 && (double)wins / count < 0.4) {
        p_riskPercent *= 0.8;
        GravaLog("AI Optimizer: Risco reduzido para " + DoubleToString(p_riskPercent, 2));
    }
}

bool IsTimeAllowed() {
    string now = TimeToString(TimeCurrent(), TIME_MINUTES);
    return (now >= p_startTime);
}

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   GerenciaPosicoes();
   GravaCSV();

   if(!IsTimeAllowed() || AguardaNoticias() || PositionsTotal() >= p_maxTrades) return;

   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBar) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         double lote = CalculaLote(p_riskPercent);
         EnviaOrdem(s, lote, p_stopPoints, p_takePoints);
         GravaLog(StringFormat("Sinal detectado: %d. Ordem enviada.", s));
      }
      lastBar = currentBar;
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Prompt update
   datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(mod > lastPromptUpdate) {
      int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(h != INVALID_HANDLE) {
         string prompt = FileReadString(h);
         FileClose(h);
         InterpretaPrompt(prompt);
         lastPromptUpdate = mod;
         GravaLog("Estratégia atualizada via prompt.txt");
      }
   }

   // AI Optimizer every hour
   static datetime lastAI = 0;
   if(TimeCurrent() - lastAI > 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}
//+------------------------------------------------------------------+
