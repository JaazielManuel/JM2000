//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Enums and Structs ---
enum Signal { BUY=1, SELL=-1, NONE=0 };
enum RuleType { RT_MA, RT_RSI, RT_STOCH, RT_BB, RT_DAILY, RT_DELTA, RT_VOL, RT_AMA, RT_BAR, RT_RS };

struct Rule {
    bool active;
    RuleType type;
    Signal intent; // BUY, SELL, or NONE (filter)
    int tf;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle1, handle2;
};

// --- Global Variables ---
Rule g_rules[30];
int g_nRules = 0;
CTrade g_trade;
int EA_MAGIC = 20260101;

// Strategy parameters
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStart = 0;
int p_trailingStep = 10;
bool p_useMartingale = false;
bool p_hedge = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int p_startTimeSeconds = 36000; // 10:00

// --- Utilities ---

double ExtraiNumero(string txt, int startPos=0) {
    string res = "";
    bool found = false;
    for(int i=startPos; i<StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            res += (c == ',') ? "." : StringSubstr(txt, i, 1);
            found = true;
        } else if(found) break;
    }
    return StringToDouble(res);
}

double ExtraiValorApos(string txt, string keyword) {
    int pos = StringFind(txt, keyword);
    if(pos < 0) return 0;
    return ExtraiNumero(txt, pos + StringLen(keyword));
}

string ExtractTime(string txt) {
    string h = "", m = "00";
    int pos = StringFind(txt, "h");
    if(pos > 0) {
        h = StringSubstr(txt, 0, pos);
        if(StringLen(txt) > pos+1) m = StringSubstr(txt, pos+1);
    } else {
        pos = StringFind(txt, ":");
        if(pos > 0) {
            h = StringSubstr(txt, 0, pos);
            m = StringSubstr(txt, pos+1);
        }
    }
    return h + ":" + m;
}

int PeriodoTexto(string nome) {
    nome = StringSubstr(nome, 0); // copy
    StringToLower(nome);
    if(StringFind(nome, "15 min") >= 0 || StringFind(nome, "m15") >= 0) return PERIOD_M15;
    if(StringFind(nome, "5 min") >= 0 || StringFind(nome, "m5") >= 0) return PERIOD_M5;
    if(StringFind(nome, "1 min") >= 0 || StringFind(nome, "m1") >= 0) return PERIOD_M1;
    if(StringFind(nome, "30 min") >= 0 || StringFind(nome, "m30") >= 0) return PERIOD_M30;
    if(StringFind(nome, "hora") >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
    if(StringFind(nome, "diário") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

void GravaLog(string texto) {
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto);
        FileClose(h);
    }
    Print(texto);
}

void GravaCSV(string ticket, string symbol, string type, double price, double sl, double tp) {
    static datetime lastWrite = 0;
    if(TimeCurrent() - lastWrite < 5) return;
    lastWrite = TimeCurrent();
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWrite(h, ticket, symbol, type, price, sl, tp, TimeToString(TimeCurrent()));
        FileClose(h);
    }
}

void CalculaEstatisticas() {
    HistorySelect(TimeCurrent()-86400*30, TimeCurrent());
    int total = 0, wins = 0;
    double profit = 0, loss = 0, maxDD = 0, peak = AccountInfoDouble(ACCOUNT_BALANCE);

    for(int i=0; i<HistoryDealsTotal(); i++) {
        ulong t = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT);
            total++;
            if(p > 0) { wins++; profit += p; }
            else loss += MathAbs(p);

            double balance = AccountInfoDouble(ACCOUNT_BALANCE);
            if(balance > peak) peak = balance;
            double dd = (peak - balance);
            if(dd > maxDD) maxDD = dd;
        }
    }

    double winRate = (total > 0) ? (double)wins/total*100.0 : 0;
    double pf = (loss > 0) ? profit/loss : profit;

    string stats = StringFormat("Stats: trades=%d, winrate=%.1f%%, PF=%.2f, MaxDD=%.2f", total, winRate, pf, maxDD);
    GravaLog(stats);
    if(total > 0 && total % 5 == 0) SendNotification(stats);
}

// --- Technical Indicators ---

Signal CruzamentoMA(int handle1, int handle2, int shift=1) {
    double f[], s[];
    ArraySetAsSeries(f, true); ArraySetAsSeries(s, true);
    if(CopyBuffer(handle1, 0, shift, 2, f) <= 0) return NONE;
    if(CopyBuffer(handle2, 0, shift, 2, s) <= 0) return NONE;
    if(f[1] < s[1] && f[0] > s[0]) return BUY;
    if(f[1] > s[1] && f[0] < s[0]) return SELL;
    return NONE;
}

Signal RSIThreshold(int handle, double over, double under, Signal intent, int shift=1) {
    double v[]; ArraySetAsSeries(v, true);
    if(CopyBuffer(handle, 0, shift, 1, v) <= 0) return NONE;
    if(intent == BUY && v[0] > under) return BUY;
    if(intent == SELL && v[0] < over) return SELL;
    if(intent == NONE) {
        if(v[0] > over) return SELL;
        if(v[0] < under) return BUY;
    }
    return NONE;
}

Signal StochCross(int handle, int shift=1) {
    double k[], d[];
    ArraySetAsSeries(k, true); ArraySetAsSeries(d, true);
    CopyBuffer(handle, 0, shift, 2, k);
    CopyBuffer(handle, 1, shift, 2, d);
    if(k[1] < d[1] && k[0] > d[0]) return BUY;
    if(k[1] > d[1] && k[0] < d[0]) return SELL;
    return NONE;
}

Signal BBounce(int handle, int shift=1) {
    double up[], lo[], cl[];
    ArraySetAsSeries(up, true); ArraySetAsSeries(lo, true); ArraySetAsSeries(cl, true);
    CopyBuffer(handle, 1, shift, 1, up);
    CopyBuffer(handle, 2, shift, 1, lo);
    CopyClose(_Symbol, PERIOD_CURRENT, shift, 1, cl);
    if(cl[0] < lo[0]) return BUY;
    if(cl[0] > up[0]) return SELL;
    return NONE;
}

Signal DailyBreak(int shift=1) {
    double hi = iHigh(_Symbol, PERIOD_D1, 1);
    double lo = iLow(_Symbol, PERIOD_D1, 1);
    double cl = iClose(_Symbol, PERIOD_CURRENT, shift);
    if(cl > hi) return BUY;
    if(cl < lo) return SELL;
    return NONE;
}

Signal DeltaAggression(int seconds=60, int deltaTrigger=300) {
    MqlTick arr[];
    int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent()-seconds, TimeCurrent());
    long buy=0, sell=0;
    for(int i=0; i<n; i++) {
        if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
        else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
    }
    long delta = buy - sell;
    if(delta > deltaTrigger) return BUY;
    if(delta < -deltaTrigger) return SELL;
    return NONE;
}

Signal VolumeCycle(int len=12, ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int shift=1) {
    long vol[]; ArraySetAsSeries(vol, true);
    CopyVolume(_Symbol, tf, shift, len, vol);
    int maxIdx = ArrayMaximum(vol);
    int minIdx = ArrayMinimum(vol);
    if(maxIdx == 0) return SELL;
    if(minIdx == 0) return BUY;
    return NONE;
}

Signal AMACross(int handle, int shift=1) {
    double ama[], p[];
    ArraySetAsSeries(ama, true); ArraySetAsSeries(p, true);
    CopyBuffer(handle, 0, shift, 2, ama);
    if(ama[1] < ama[0]) return BUY;
    if(ama[1] > ama[0]) return SELL;
    return NONE;
}

Signal BarPattern(ENUM_TIMEFRAMES tf=PERIOD_CURRENT, int shift=1) {
    double h0=iHigh(_Symbol, tf, shift), l0=iLow(_Symbol, tf, shift);
    double h1=iHigh(_Symbol, tf, shift+1), l1=iLow(_Symbol, tf, shift+1);
    double c0=iClose(_Symbol, tf, shift), o0=iOpen(_Symbol, tf, shift);
    if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL; // Inside
    if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY; // Outside
    return NONE;
}

Signal RSRelative(string bench, int len, ENUM_TIMEFRAMES tf, int shift=1) {
    double r1 = iRSI(_Symbol, tf, len, PRICE_CLOSE);
    double r2 = iRSI(bench, tf, len, PRICE_CLOSE);
    if(r1 > r2 + 5) return BUY;
    if(r1 < r2 - 5) return SELL;
    return NONE;
}

// --- NLP Parser ---

void ResetStrategy() {
    for(int i=0; i<g_nRules; i++) {
        if(g_rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(g_rules[i].handle1);
        if(g_rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(g_rules[i].handle2);
    }
    g_nRules = 0;
    p_riskPercent = 1.0;
    p_stopPoints = 300;
    p_takePoints = 500;
    p_maxTrades = 3;
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStart = 0;
    p_useMartingale = false;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    StringToLower(prompt);
    string segments[];
    int nSeg = StringSplit(prompt, ',', segments);
    if(nSeg == 0) { segments[0] = prompt; nSeg = 1; }

    Signal currentIntent = NONE;

    for(int i=0; i<nSeg; i++) {
        string s = segments[i];
        StringTrimLeft(s); StringTrimRight(s);

        if(StringFind(s, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

        if(StringFind(s, "média") >= 0 || StringFind(s, "ma") >= 0 || StringFind(s, "ema") >= 0) {
            g_rules[g_nRules].active = true;
            g_rules[g_nRules].type = RT_MA;
            g_rules[g_nRules].intent = currentIntent;
            int maPos = StringFind(s, "média");
            if(maPos < 0) maPos = StringFind(s, "ma");
            if(maPos < 0) maPos = StringFind(s, "ema");
            g_rules[g_nRules].p1 = (int)ExtraiNumero(s, maPos);
            if(g_rules[g_nRules].p1 == 0) g_rules[g_nRules].p1 = 20;
            // Shorthand for crossover like 9/21
            int slash = StringFind(s, "/");
            if(slash > 0) {
                g_rules[g_nRules].p2 = (int)ExtraiNumero(s, slash+1);
                g_rules[g_nRules].handle1 = iMA(_Symbol, p_frequency, g_rules[g_nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
                g_rules[g_nRules].handle2 = iMA(_Symbol, p_frequency, g_rules[g_nRules].p2, 0, MODE_EMA, PRICE_CLOSE);
            } else {
                g_rules[g_nRules].handle1 = iMA(_Symbol, p_frequency, g_rules[g_nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
                g_rules[g_nRules].handle2 = INVALID_HANDLE; // Price vs MA
            }
            g_nRules++;
        }
        else if(StringFind(s, "rsi") >= 0) {
            g_rules[g_nRules].active = true;
            g_rules[g_nRules].type = RT_RSI;
            g_rules[g_nRules].intent = currentIntent;
            int rsiPos = StringFind(s, "rsi");
            g_rules[g_nRules].p1 = (int)ExtraiNumero(s, rsiPos);
            if(g_rules[g_nRules].p1 == 0) g_rules[g_nRules].p1 = 14;
            g_rules[g_nRules].d1 = 70; g_rules[g_nRules].d2 = 30; // Defaults
            if(StringFind(s, "acima de") >= 0 || StringFind(s, "acima") >= 0) g_rules[g_nRules].d2 = ExtraiValorApos(s, "acima");
            if(StringFind(s, "abaixo de") >= 0 || StringFind(s, "abaixo") >= 0) g_rules[g_nRules].d1 = ExtraiValorApos(s, "abaixo");
            g_rules[g_nRules].handle1 = iRSI(_Symbol, p_frequency, g_rules[g_nRules].p1, PRICE_CLOSE);
            g_nRules++;
        }
        else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
            g_rules[g_nRules].active = true; g_rules[g_nRules].type = RT_STOCH;
            g_rules[g_nRules].intent = currentIntent;
            g_rules[g_nRules].handle1 = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            g_nRules++;
        }
        else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
            g_rules[g_nRules].active = true; g_rules[g_nRules].type = RT_BB;
            g_rules[g_nRules].intent = currentIntent;
            g_rules[g_nRules].handle1 = iBands(_Symbol, p_frequency, 20, 0, 2.0, PRICE_CLOSE);
            g_nRules++;
        }
        else if(StringFind(s, "rompimento diário") >= 0) {
            g_rules[g_nRules].active = true; g_rules[g_nRules].type = RT_DAILY;
            g_rules[g_nRules].intent = currentIntent;
            g_nRules++;
        }
        else if(StringFind(s, "delta") >= 0) {
            g_rules[g_nRules].active = true; g_rules[g_nRules].type = RT_DELTA;
            g_rules[g_nRules].intent = currentIntent;
            g_rules[g_nRules].p1 = 60; g_rules[g_nRules].d1 = 300;
            g_nRules++;
        }
        else if(StringFind(s, "volume") >= 0) {
            g_rules[g_nRules].active = true; g_rules[g_nRules].type = RT_VOL;
            g_rules[g_nRules].intent = currentIntent;
            g_rules[g_nRules].p1 = (int)ExtraiValorApos(s, "volume");
            if(g_rules[g_nRules].p1 == 0) g_rules[g_nRules].p1 = 12;
            g_nRules++;
        }
        else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) {
            g_rules[g_nRules].active = true; g_rules[g_nRules].type = RT_AMA;
            g_rules[g_nRules].intent = currentIntent;
            g_rules[g_nRules].handle1 = iAMA(_Symbol, p_frequency, 10, 2, 30, 0, PRICE_CLOSE);
            g_nRules++;
        }
        else if(StringFind(s, "padrão barras") >= 0) {
            g_rules[g_nRules].active = true; g_rules[g_nRules].type = RT_BAR;
            g_rules[g_nRules].intent = currentIntent;
            g_nRules++;
        }
    }

    // Global parameters
    if(StringFind(prompt, "stop de") >= 0) p_stopPoints = (int)ExtraiNumero(StringSubstr(prompt, StringFind(prompt, "stop de")+7));
    if(StringFind(prompt, "take de") >= 0) p_takePoints = (int)ExtraiNumero(StringSubstr(prompt, StringFind(prompt, "take de")+7));
    if(StringFind(prompt, "risco de") >= 0) p_riskPercent = ExtraiNumero(StringSubstr(prompt, StringFind(prompt, "risco de")+8));
    if(StringFind(prompt, "máximo") >= 0) p_maxTrades = (int)ExtraiNumero(StringSubstr(prompt, StringFind(prompt, "máximo")+6));

    int bePos = StringFind(prompt, "move stop para entrada");
    if(bePos >= 0) {
        p_beStart = (int)ExtraiNumero(StringSubstr(prompt, bePos-10)); // Heuristic
        p_bePlus = (int)ExtraiNumero(StringSubstr(prompt, bePos+22));
    }

    if(StringFind(prompt, "martingale") >= 0) p_useMartingale = true;
    if(StringFind(prompt, "hedge") >= 0) p_hedge = true;

    int hPos = StringFind(prompt, "depois das ");
    if(hPos >= 0) {
        string tStr = ExtractTime(StringSubstr(prompt, hPos+11, 5));
        string parts[];
        if(StringSplit(tStr, ':', parts) >= 2) {
            p_startTimeSeconds = (int)StringToInteger(parts[0])*3600 + (int)StringToInteger(parts[1])*60;
        }
    }

    p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(prompt);
}

// --- Trade Logic ---

double CalculaLote(double stopPoints) {
    if(stopPoints <= 0) stopPoints = p_stopPoints;
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = capital * p_riskPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    // Martingale logic
    double lotMultiplier = 1.0;
    if(p_useMartingale) {
        HistorySelect(TimeCurrent()-86400, TimeCurrent());
        for(int i=HistoryDealsTotal()-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lotMultiplier = 2.0;
                break;
            }
        }
    }

    double lot = (riskAmount / (stopPoints * (tickValue / (tickSize / _Point)))) * lotMultiplier;
    return NormalizeDouble(MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)), 2);
}

void EnviaOrdem(Signal s) {
    if(PositionsTotal() >= p_maxTrades) return;

    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (s == BUY) ? price - p_stopPoints*_Point : price + p_stopPoints*_Point;
    double tp = (s == BUY) ? price + p_takePoints*_Point : price - p_takePoints*_Point;
    double lot = CalculaLote(p_stopPoints);

    if(!p_hedge) {
        for(int i=PositionsTotal()-1; i>=0; i--) {
            if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetString(POSITION_SYMBOL) == _Symbol) {
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && s == SELL) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && s == BUY)) {
                    g_trade.PositionClose(PositionGetTicket(i));
                }
            }
        }
    }

    double marginNeeded;
    if(!OrderCalcMargin((s==BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL), _Symbol, lot, price, marginNeeded)) {
        GravaLog("Erro ao calcular margem."); return;
    }
    if(marginNeeded > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
        GravaLog("Margem insuficiente para abrir posição."); return;
    }

    bool res = false;
    if(s == BUY) res = g_trade.Buy(lot, _Symbol, price, sl, tp, "MT-Live");
    else res = g_trade.Sell(lot, _Symbol, price, sl, tp, "MT-Live");

    if(res) {
        GravaLog("Ordem enviada com sucesso: " + EnumToString(s));
        SendNotification("Execução MT-Live: " + EnumToString(s) + " em " + _Symbol);
    } else {
        GravaLog("Erro ao enviar ordem: " + (string)g_trade.ResultRetcode() + " - " + g_trade.ResultRetcodeDescription());
    }
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profitPoints = MathAbs(currentPrice - openPrice) / _Point;

            // Break-even
            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_bePlus*_Point : openPrice - p_bePlus*_Point;
                if(PositionGetDouble(POSITION_SL) != newSL) g_trade.PositionModify(PositionGetTicket(i), newSL, PositionGetDouble(POSITION_TP));
            }

            // Trailing Stop
            if(p_trailingStart > 0 && profitPoints >= p_trailingStart) {
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart*_Point : currentPrice + p_trailingStart*_Point;
                if(MathAbs(newSL - PositionGetDouble(POSITION_SL)) > p_trailingStep*_Point) {
                    g_trade.PositionModify(PositionGetTicket(i), newSL, PositionGetDouble(POSITION_TP));
                }
            }

            GravaCSV(IntegerToString(PositionGetTicket(i)), _Symbol, EnumToString((Signal)PositionGetInteger(POSITION_TYPE)), openPrice, PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP));
        }
    }
}

bool AguardaNoticias() {
    int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string content = FileReadString(h);
        FileClose(h);
        if(content == "1") return true;
        datetime newsTime = StringToTime(content);
        if(newsTime > 0 && MathAbs(TimeCurrent() - newsTime) < 1200) return true;
    }
    return false;
}

// --- Main Engine ---

Signal AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i=0; i<g_nRules; i++) {
        if(!g_rules[i].active) continue;

        Signal s = NONE;
        switch(g_rules[i].type) {
            case RT_MA:
                if(g_rules[i].handle2 != INVALID_HANDLE) s = CruzamentoMA(g_rules[i].handle1, g_rules[i].handle2);
                else {
                    double ma[], pr[];
                    ArraySetAsSeries(ma, true); ArraySetAsSeries(pr, true);
                    CopyBuffer(g_rules[i].handle1, 0, 1, 2, ma);
                    CopyClose(_Symbol, p_frequency, 1, 2, pr);
                    if(pr[1] < ma[1] && pr[0] > ma[0]) s = BUY;
                    if(pr[1] > ma[1] && pr[0] < ma[0]) s = SELL;
                }
                break;
            case RT_RSI:   s = RSIThreshold(g_rules[i].handle1, g_rules[i].d1, g_rules[i].d2, g_rules[i].intent); break;
            case RT_STOCH: s = StochCross(g_rules[i].handle1); break;
            case RT_BB:    s = BBounce(g_rules[i].handle1); break;
            case RT_DAILY: s = DailyBreak(); break;
            case RT_DELTA: s = DeltaAggression(g_rules[i].p1, (int)g_rules[i].d1); break;
            case RT_VOL:   s = VolumeCycle(g_rules[i].p1, (ENUM_TIMEFRAMES)g_rules[i].tf); break;
            case RT_AMA:   s = AMACross(g_rules[i].handle1); break;
            case RT_BAR:   s = BarPattern((ENUM_TIMEFRAMES)g_rules[i].tf); break;
            case RT_RS:    s = RSRelative(g_rules[i].s1, g_rules[i].p1, (ENUM_TIMEFRAMES)g_rules[i].tf); break;
        }

        if(g_rules[i].intent == BUY) { buyRules++; if(s == BUY) buyVotes++; }
        else if(g_rules[i].intent == SELL) { sellRules++; if(s == SELL) sellVotes++; }
        else { // Neutral filter
            if(s == BUY) buyVotes++;
            if(s == SELL) sellVotes++;
            buyRules++; sellRules++;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) return BUY;
    if(sellRules > 0 && sellVotes == sellRules) return SELL;
    return NONE;
}

int OnInit() {
    g_trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);
    GravaLog("MT-LiveExecutor Inicializado.");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
    GravaLog("MT-LiveExecutor Finalizado.");
}

void OnTick() {
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);

    GerenciaPosicoes();

    if(currentBar != lastBar) {
        lastBar = currentBar;
        CalculaEstatisticas();

        if(TimeCurrent() % 86400 < p_startTimeSeconds) return;
        if(AguardaNoticias()) return;

        Signal s = AvaliaTudo();
        if(s != NONE) EnviaOrdem(s);
    }
}

void OnTimer() {
    static string lastPrompt = "";
    int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string currentPrompt = FileReadString(h);
        FileClose(h);
        if(currentPrompt != lastPrompt && currentPrompt != "") {
            lastPrompt = currentPrompt;
            InterpretaPrompt(currentPrompt);
            GravaLog("Nova estratégia carregada: " + currentPrompt);
            // Clear prompt file to signal read
            h = FileOpen("prompt.txt", FILE_WRITE|FILE_TXT|FILE_COMMON);
            FileWrite(h, "");
            FileClose(h);
        }
    }
}
