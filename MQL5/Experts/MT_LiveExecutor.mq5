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

//--- defines
#define EA_MAGIC 123456

//--- enums
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };
enum ENUM_RULE_TYPE {
    TYPE_MA=1, TYPE_RSI=2, TYPE_STOCH=3, TYPE_BB=4, TYPE_BREAKOUT=5,
    TYPE_DELTA=6, TYPE_VOLUME=7, TYPE_AMA=8, TYPE_PATTERN=9, TYPE_RS=10
};

//--- structs
struct Rule {
    bool            active;
    ENUM_RULE_TYPE  type;
    int             tf;
    int             p1, p2, p3;
    double          d1, d2;
    string          s1;
    string          op;
    int             handle;
    int             handle2;
    ENUM_SIGNAL     intent;

    void Reset() {
        active = false;
        type = (ENUM_RULE_TYPE)0;
        tf = 0; p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0;
        s1 = ""; op = "";
        if(handle != INVALID_HANDLE && handle != 0) { IndicatorRelease(handle); }
        handle = INVALID_HANDLE;
        if(handle2 != INVALID_HANDLE && handle2 != 0) { IndicatorRelease(handle2); }
        handle2 = INVALID_HANDLE;
        intent = SIGNAL_NONE;
    }
};

//--- globals
Rule        g_rules_buy[20];
Rule        g_rules_sell[20];
int         g_nRulesBuy = 0;
int         g_nRulesSell = 0;

double      p_risk = 1.0;
int         p_maxTrades = 3;
int         p_stopPoints = 300;
int         p_takePoints = 500;
int         p_breakeven = 0;
int         p_breakevenProfit = 0;
int         p_trailingStop = 0;
int         p_startHour = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

double      g_peakEquity = 0;
double      g_maxDrawdown = 0;
int         g_winCount = 0;
int         g_lossCount = 0;
double      g_totalProfit = 0;

CTrade      trade;
CPositionInfo pos;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int ExtraiNumero(string txt, int startPos) {
    string res = "";
    bool found = false;
    for(int i = startPos; i < StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == '+' || c == '-') {
            res += CharToString((char)c);
            found = true;
        } else if(found) {
            break;
        }
    }
    return (int)StringToInteger(res);
}

double ExtraiDouble(string txt, int startPos) {
    string res = "";
    bool found = false;
    for(int i = startPos; i < StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == '+' || c == '-') {
            res += CharToString((char)c);
            found = true;
        } else if(found) {
            break;
        }
    }
    return StringToDouble(res);
}

int PeriodoTexto(string nome) {
    string t = nome;
    StringToLower(t);
    if(StringFind(t, "m1") >= 0 || StringFind(t, "1 min") >= 0) return PERIOD_M1;
    if(StringFind(t, "m5") >= 0 || StringFind(t, "5 min") >= 0) return PERIOD_M5;
    if(StringFind(t, "m15") >= 0 || StringFind(t, "15 min") >= 0) return PERIOD_M15;
    if(StringFind(t, "m30") >= 0 || StringFind(t, "30 min") >= 0) return PERIOD_M30;
    if(StringFind(t, "h1") >= 0 || StringFind(t, "1 hora") >= 0) return PERIOD_H1;
    if(StringFind(t, "h4") >= 0 || StringFind(t, "4 horas") >= 0) return PERIOD_H4;
    if(StringFind(t, "d1") >= 0 || StringFind(t, "diário") >= 0 || StringFind(t, "diario") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

double GetVal(int handle, int buffer, int shift) {
    double b[];
    ArraySetAsSeries(b, true);
    if(CopyBuffer(handle, buffer, shift, 1, b) <= 0) return 0;
    return b[0];
}

void GravaEstadoCSV(ulong ticket, string motivo) {
    int handle = FileOpen("states.csv", FILE_WRITE | FILE_READ | FILE_CSV | FILE_COMMON, ',');
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, ticket, TimeCurrent(), motivo);
        FileClose(handle);
    }
}

void GravaLog(string texto) {
    Print(texto);
    SendNotification(texto);
}

//+------------------------------------------------------------------+
//| NLP Parser                                                       |
//+------------------------------------------------------------------+
void AddRuleSpecific(string segment, ENUM_SIGNAL intent) {
    int nRules = 0;
    if(intent == SIGNAL_BUY) {
        if(g_nRulesBuy >= 20) return;
        nRules = g_nRulesBuy++;
        g_rules_buy[nRules].Reset();
        g_rules_buy[nRules].active = true;
        g_rules_buy[nRules].intent = intent;
        int tf = PeriodoTexto(segment);
        if(tf == PERIOD_CURRENT) tf = p_frequency;
        g_rules_buy[nRules].tf = tf;

        int pos;
        if((pos = StringFind(segment, "média")) >= 0) {
            g_rules_buy[nRules].type = TYPE_MA;
            g_rules_buy[nRules].p1 = ExtraiNumero(segment, pos + 5);
            if(StringFind(segment, "cruzar acima") >= 0) g_rules_buy[nRules].op = "cross_above";
            else if(StringFind(segment, "cruzar abaixo") >= 0) g_rules_buy[nRules].op = "cross_below";
            else if(StringFind(segment, "acima") >= 0) g_rules_buy[nRules].op = ">";
            else if(StringFind(segment, "abaixo") >= 0) g_rules_buy[nRules].op = "<";
            int ePos = StringFind(segment, " e ", pos + 5);
            if(ePos < 0) ePos = StringFind(segment, "/", pos + 5);
            if(ePos >= 0) g_rules_buy[nRules].p2 = ExtraiNumero(segment, ePos + 1);
            g_rules_buy[nRules].handle = iMA(_Symbol, (ENUM_TIMEFRAMES)g_rules_buy[nRules].tf, g_rules_buy[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
            if(g_rules_buy[nRules].p2 > 0) g_rules_buy[nRules].handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)g_rules_buy[nRules].tf, g_rules_buy[nRules].p2, 0, MODE_EMA, PRICE_CLOSE);
        } else if((pos = StringFind(segment, "rsi")) >= 0) {
            g_rules_buy[nRules].type = TYPE_RSI;
            g_rules_buy[nRules].p1 = ExtraiNumero(segment, pos + 3);
            if(StringFind(segment, "acima") >= 0) { g_rules_buy[nRules].op = ">"; g_rules_buy[nRules].d1 = ExtraiDouble(segment, StringFind(segment, "acima") + 5); }
            else if(StringFind(segment, "abaixo") >= 0) { g_rules_buy[nRules].op = "<"; g_rules_buy[nRules].d1 = ExtraiDouble(segment, StringFind(segment, "abaixo") + 6); }
            g_rules_buy[nRules].handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)g_rules_buy[nRules].tf, g_rules_buy[nRules].p1, PRICE_CLOSE);
        } else if((pos = StringFind(segment, "padrão")) >= 0) {
            g_rules_buy[nRules].type = TYPE_PATTERN;
        } else if((pos = StringFind(segment, "breakout")) >= 0) {
            g_rules_buy[nRules].type = TYPE_BREAKOUT;
        }
    } else {
        if(g_nRulesSell >= 20) return;
        nRules = g_nRulesSell++;
        g_rules_sell[nRules].Reset();
        g_rules_sell[nRules].active = true;
        g_rules_sell[nRules].intent = intent;
        int tf = PeriodoTexto(segment);
        if(tf == PERIOD_CURRENT) tf = p_frequency;
        g_rules_sell[nRules].tf = tf;
        int pos;
        if((pos = StringFind(segment, "média")) >= 0) {
            g_rules_sell[nRules].type = TYPE_MA;
            g_rules_sell[nRules].p1 = ExtraiNumero(segment, pos + 5);
            if(StringFind(segment, "cruzar acima") >= 0) g_rules_sell[nRules].op = "cross_above";
            else if(StringFind(segment, "cruzar abaixo") >= 0) g_rules_sell[nRules].op = "cross_below";
            else if(StringFind(segment, "acima") >= 0) g_rules_sell[nRules].op = ">";
            else if(StringFind(segment, "abaixo") >= 0) g_rules_sell[nRules].op = "<";
            int ePos = StringFind(segment, " e ", pos + 5);
            if(ePos < 0) ePos = StringFind(segment, "/", pos + 5);
            if(ePos >= 0) g_rules_sell[nRules].p2 = ExtraiNumero(segment, ePos + 1);
            g_rules_sell[nRules].handle = iMA(_Symbol, (ENUM_TIMEFRAMES)g_rules_sell[nRules].tf, g_rules_sell[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
            if(g_rules_sell[nRules].p2 > 0) g_rules_sell[nRules].handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)g_rules_sell[nRules].tf, g_rules_sell[nRules].p2, 0, MODE_EMA, PRICE_CLOSE);
        } else if((pos = StringFind(segment, "rsi")) >= 0) {
            g_rules_sell[nRules].type = TYPE_RSI;
            g_rules_sell[nRules].p1 = ExtraiNumero(segment, pos + 3);
            if(StringFind(segment, "acima") >= 0) { g_rules_sell[nRules].op = ">"; g_rules_sell[nRules].d1 = ExtraiDouble(segment, StringFind(segment, "acima") + 5); }
            else if(StringFind(segment, "abaixo") >= 0) { g_rules_sell[nRules].op = "<"; g_rules_sell[nRules].d1 = ExtraiDouble(segment, StringFind(segment, "abaixo") + 6); }
            g_rules_sell[nRules].handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)g_rules_sell[nRules].tf, g_rules_sell[nRules].p1, PRICE_CLOSE);
        } else if((pos = StringFind(segment, "padrão")) >= 0) {
            g_rules_sell[nRules].type = TYPE_PATTERN;
        } else if((pos = StringFind(segment, "breakout")) >= 0) {
            g_rules_sell[nRules].type = TYPE_BREAKOUT;
        }
    }
}

void InterpretaPrompt(string prompt) {
    string p = prompt;
    StringToLower(p);
    StringReplace(p, " e o ", ".");
    StringReplace(p, " e a ", ".");
    StringReplace(p, " e ", ".");
    StringReplace(p, "|", ".");
    StringReplace(p, "\n", ".");
    string segments[];
    int n = StringSplit(p, '.', segments);
    ENUM_SIGNAL currentIntent = SIGNAL_NONE;
    for(int i = 0; i < n; i++) {
        string seg = segments[i]; StringTrimLeft(seg); StringTrimRight(seg);
        if(seg == "") continue;
        if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SIGNAL_SELL;
        int pos;
        if((pos = StringFind(seg, "stop de")) >= 0) p_stopPoints = ExtraiNumero(seg, pos + 7);
        if((pos = StringFind(seg, "take de")) >= 0) p_takePoints = ExtraiNumero(seg, pos + 7);
        if((pos = StringFind(seg, "risco de")) >= 0) p_risk = ExtraiDouble(seg, pos + 8);
        if((pos = StringFind(seg, "máximo")) >= 0) p_maxTrades = ExtraiNumero(seg, pos + 6);
        if((pos = StringFind(seg, "move stop para entrada")) >= 0 || (pos = StringFind(seg, "breakeven")) >= 0) {
            int aoPos = StringFind(seg, "ao atingir");
            if(aoPos >= 0) p_breakeven = ExtraiNumero(seg, aoPos + 10);
            int maisPos = StringFind(seg, "entrada +");
            if(maisPos >= 0) p_breakevenProfit = ExtraiNumero(seg, maisPos + 9);
        }
        if((pos = StringFind(seg, "trailing")) >= 0 || (pos = StringFind(seg, "rastreio")) >= 0) p_trailingStop = ExtraiNumero(seg, pos + 8);
        if((pos = StringFind(seg, "depois das")) >= 0 || (pos = StringFind(seg, "após as")) >= 0) p_startHour = ExtraiNumero(seg, pos + 10);
        if((pos = StringFind(seg, "a cada")) >= 0) p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(seg);
        if(currentIntent != SIGNAL_NONE) AddRuleSpecific(seg, currentIntent);
    }
}

//+------------------------------------------------------------------+
//| Signal Engine                                                    |
//+------------------------------------------------------------------+
bool AvaliaRegra(Rule &r) {
    double v1, v1_prev, v2, v2_prev;
    double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
    double close_prev = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);

    switch(r.type) {
        case TYPE_MA:
            v1 = GetVal(r.handle, 0, 0);
            v1_prev = GetVal(r.handle, 0, 1);
            if(r.handle2 != INVALID_HANDLE) {
                v2 = GetVal(r.handle2, 0, 0);
                v2_prev = GetVal(r.handle2, 0, 1);
                if(r.op == "cross_above") return (v1_prev < v2_prev && v1 > v2);
                if(r.op == "cross_below") return (v1_prev > v2_prev && v1 < v2);
                if(r.op == ">") return (v1 > v2);
                if(r.op == "<") return (v1 < v2);
            } else {
                if(r.op == "cross_above") return (close_prev < v1_prev && close > v1);
                if(r.op == "cross_below") return (close_prev > v1_prev && close < v1);
                if(r.op == ">") return (close > v1);
                if(r.op == "<") return (close < v1);
            }
            break;

        case TYPE_RSI:
            v1 = GetVal(r.handle, 0, 0);
            v1_prev = GetVal(r.handle, 0, 1);
            if(r.op == ">") return (v1 > r.d1);
            if(r.op == "<") return (v1 < r.d1);
            break;

        case TYPE_PATTERN:
            double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            bool isInside = (h0 < h1 && l0 > l1);
            bool isOutside = (h0 > h1 && l0 < l1);
            if(isInside || isOutside) {
                if(r.intent == SIGNAL_BUY) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0));
                if(r.intent == SIGNAL_SELL) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) < iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0));
            }
            break;

        case TYPE_BREAKOUT:
            double daily_hi = iHigh(_Symbol, PERIOD_D1, 1);
            double daily_lo = iLow(_Symbol, PERIOD_D1, 1);
            if(r.intent == SIGNAL_BUY) return (close > daily_hi);
            if(r.intent == SIGNAL_SELL) return (close < daily_lo);
            break;

        default: break;
    }
    return false;
}

ENUM_SIGNAL AvaliaTudo() {
    if(g_nRulesBuy > 0) {
        bool allBuy = true;
        for(int i = 0; i < g_nRulesBuy; i++) {
            if(!AvaliaRegra(g_rules_buy[i])) { allBuy = false; break; }
        }
        if(allBuy) return SIGNAL_BUY;
    }

    if(g_nRulesSell > 0) {
        bool allSell = true;
        for(int i = 0; i < g_nRulesSell; i++) {
            if(!AvaliaRegra(g_rules_sell[i])) { allSell = false; break; }
        }
        if(allSell) return SIGNAL_SELL;
    }

    return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| Trade Management                                                 |
//+------------------------------------------------------------------+
double CalculaLote(double riscoPercent, int slPoints) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riscoAbs = capital * riscoPercent / 100.0;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if(slPoints <= 0) slPoints = 300;
    double lote = riscoAbs / (slPoints * _Point * (tickVal / tickSize));
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lote = MathFloor(lote / step) * step;
    double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lote < minVol) lote = minVol;
    if(lote > maxVol) lote = maxVol;
    return lote;
}

void EnviaOrdem(ENUM_SIGNAL tipo, double preco, double sl, double tp, double lote, string motivo) {
    bool res = false;
    for(int i = 0; i < 3; i++) {
        if(tipo == SIGNAL_BUY) {
            preco = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            res = trade.Buy(lote, _Symbol, preco, sl, tp, motivo);
        } else if(tipo == SIGNAL_SELL) {
            preco = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            res = trade.Sell(lote, _Symbol, preco, sl, tp, motivo);
        }
        if(res && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED)) {
            GravaEstadoCSV(trade.ResultOrder(), motivo);
            break;
        }
        Sleep(100);
    }
}

void EnviaOrdem(string tipo, double preco, double sl, double tp, double lote) {
    ENUM_SIGNAL s = SIGNAL_NONE;
    if(tipo == "BUY" || tipo == "compra") s = SIGNAL_BUY;
    if(tipo == "SELL" || tipo == "venda") s = SIGNAL_SELL;
    EnviaOrdem(s, preco, sl, tp, lote, "External Command");
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl = PositionGetDouble(POSITION_SL);
            double tp = PositionGetDouble(POSITION_TP);

            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

            // Breakeven
            if(p_breakeven > 0 && profitPoints >= p_breakeven) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_breakevenProfit * _Point : openPrice - p_breakevenProfit * _Point;
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                    trade.PositionModify(ticket, newSL, tp);
                    GravaLog("Breakeven acionado para #" + IntegerToString(ticket));
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                    trade.PositionModify(ticket, newSL, tp);
                }
            }
        }
    }
}

void CalculaStats() {
    g_totalProfit = AccountInfoDouble(ACCOUNT_PROFIT);
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity > g_peakEquity) g_peakEquity = equity;
    if(g_peakEquity > 0) {
        double dd = (g_peakEquity - equity) / g_peakEquity * 100.0;
        if(dd > g_maxDrawdown) g_maxDrawdown = dd;
    }
}

//+------------------------------------------------------------------+
//| Supporting Features                                              |
//+------------------------------------------------------------------+
bool AguardaNoticias() {
    int handle = FileOpen("calendar.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(handle == INVALID_HANDLE) handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        if(FileSize(handle) > 0) { FileClose(handle); return true; }
        FileClose(handle);
    }
    return false;
}

double AIPredict() {
    int handle = FileOpen("signal_ai.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    double sig = 0;
    if(handle != INVALID_HANDLE) {
        sig = StringToDouble(FileReadString(handle));
        FileClose(handle);
    }
    return sig;
}

void ResetStrategy() {
    for(int i = 0; i < 20; i++) {
        g_rules_buy[i].Reset();
        g_rules_sell[i].Reset();
    }
    g_nRulesBuy = 0;
    g_nRulesSell = 0;
}

//+------------------------------------------------------------------+
//| Event Handlers                                                   |
//+------------------------------------------------------------------+
int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(3600);
    g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    for(int i = 0; i < 20; i++) {
        g_rules_buy[i].handle = INVALID_HANDLE;
        g_rules_buy[i].handle2 = INVALID_HANDLE;
        g_rules_sell[i].handle = INVALID_HANDLE;
        g_rules_sell[i].handle2 = INVALID_HANDLE;
        g_rules_buy[i].Reset();
        g_rules_sell[i].Reset();
    }
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    EventKillTimer();
    CalculaStats();
    ResetStrategy();
}

void OnTick() {
    static uint lastCheck = 0;
    if(GetTickCount() - lastCheck > 1000) {
        lastCheck = GetTickCount();
        if(FileIsExist("prompt.txt", FILE_COMMON)) {
            int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
            if(h != INVALID_HANDLE) {
                string p = "";
                while(!FileIsEnding(h)) p += FileReadString(h);
                FileClose(h);
                FileDelete("prompt.txt", FILE_COMMON);
                ResetStrategy();
                InterpretaPrompt(p);
                GravaLog("Novo prompt interpretado: " + p);
            }
        }
    }

    if(AguardaNoticias()) return;

    MqlDateTime dt;
    TimeCurrent(dt);
    if(dt.hour < p_startHour) return;

    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != lastBar) {
        lastBar = currentBar;

        ENUM_SIGNAL sig = AvaliaTudo();
        if(sig != SIGNAL_NONE) {
            int count = 0;
            for(int i = 0; i < PositionsTotal(); i++) {
                if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
            }
            if(count < p_maxTrades) {
                double lote = CalculaLote(p_risk, p_stopPoints);
                double sl = 0, tp = 0;
                double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
                double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
                if(sig == SIGNAL_BUY) {
                    sl = bid - p_stopPoints * _Point;
                    tp = ask + p_takePoints * _Point;
                    EnviaOrdem(SIGNAL_BUY, ask, sl, tp, lote, "NLP Buy Signal");
                } else if(sig == SIGNAL_SELL) {
                    sl = ask + p_stopPoints * _Point;
                    tp = bid - p_takePoints * _Point;
                    EnviaOrdem(SIGNAL_SELL, bid, sl, tp, lote, "NLP Sell Signal");
                }
            }
        }
    }

    GerenciaPosicoes();
}

void OnTimer() {
    CalculaStats();
}
