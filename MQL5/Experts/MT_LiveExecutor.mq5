//+------------------------------------------------------------------+
//|                                            MT_LiveExecutor.mq5   |
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
#define MAX_RULES 20

//--- ENUMS
enum ENUM_SIGNAL { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = 2 };

//--- STRUCTS
struct Rule {
    bool active;
    int type; // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: Breakout, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: RS
    ENUM_TIMEFRAMES tf;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle;
    int handle2;
    string relOp; // ">", "<", "cruzar_cima", "cruzar_baixo"

    void Reset() {
        if(handle != INVALID_HANDLE) IndicatorRelease(handle);
        if(handle2 != INVALID_HANDLE) IndicatorRelease(handle2);
        active = false;
        type = 0;
        tf = PERIOD_CURRENT;
        p1 = p2 = p3 = 0;
        d1 = d2 = 0;
        s1 = "";
        handle = INVALID_HANDLE;
        handle2 = INVALID_HANDLE;
        relOp = "";
    }
};

//--- GLOBALS
Rule g_rulesBuy[MAX_RULES];
Rule g_rulesSell[MAX_RULES];
int g_nRulesBuy = 0;
int g_nRulesSell = 0;

string g_lastPrompt = "";
datetime g_lastPromptCheck = 0;

double p_riskPercent = 1.0;
int p_stopLoss = 0;
int p_takeProfit = 0;
int p_maxTrades = 3;
int p_startHour = 0;
int p_breakeven = 0;
int p_breakevenStep = 0;
int p_trailingStop = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

double g_peakEquity = 0;
double g_maxDrawdown = 0;
int g_winCount = 0;
int g_lossCount = 0;
double g_totalProfit = 0;

CTrade g_trade;

//--- FUNCTIONS PROTOTYPES
void InterpretaPrompt(string prompt);
void ResetStrategy();
bool AvaliaTudo(ENUM_SIGNAL &signal);
bool AvaliaRegra(Rule &r, ENUM_SIGNAL intent);
void EnviaOrdem(ENUM_SIGNAL signal);
void GerenciaPosicoes();
double CalculaLote(int slPoints);
bool AguardaNoticias();
void CalculaStats();
void GravaLog(string text);
void GravaEstadoCSV(ulong ticket, double price, double sl, double tp, string reason);
double ExtraiNumero(string txt, string keyword, int &startPos);
int PeriodoTexto(string nome);
void AddRuleSpecific(string segment, ENUM_SIGNAL intent);
int AIPredict();

//--- HANDLERS
int OnInit() {
    g_trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(3600); // Hourly stats
    g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);

    // Initial check for prompt
    InterpretaPrompt("A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.");

    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    CalculaStats();
    ResetStrategy();
    EventKillTimer();
}

void OnTick() {
    // Check for new prompt every 1s
    if(GetTickCount() - g_lastPromptCheck > 1000) {
        g_lastPromptCheck = GetTickCount();
        if(FileIsExist("prompt.txt", FILE_COMMON)) {
            int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
            if(h != INVALID_HANDLE) {
                string p = FileReadString(h);
                FileClose(h);
                FileDelete("prompt.txt", FILE_COMMON);
                InterpretaPrompt(p);
            }
        }
    }

    if(TimeHour(TimeCurrent()) < p_startHour) return;
    if(AguardaNoticias()) return;

    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != lastBar) {
        lastBar = currentBar;
        ENUM_SIGNAL sig = SIGNAL_NONE;
        if(AvaliaTudo(sig)) {
            EnviaOrdem(sig);
        }
    }

    GerenciaPosicoes();
}

void OnTimer() {
    CalculaStats();
}

//--- NLP ENGINE
void InterpretaPrompt(string prompt) {
    ResetStrategy();
    g_lastPrompt = prompt;

    string p = prompt;
    StringReplace(p, " e ", ".");
    StringReplace(p, " e o ", ".");
    StringReplace(p, " e a ", ".");
    StringReplace(p, "|", ".");
    StringReplace(p, "\n", ".");

    string p_lower = p;
    StringToLower(p_lower);

    // Global params
    int dummy = 0;
    if(StringFind(p_lower, "risco de") >= 0) { dummy = 0; p_riskPercent = ExtraiNumero(p_lower, "risco de", dummy); }
    if(StringFind(p_lower, "stop de") >= 0) { dummy = 0; p_stopLoss = (int)ExtraiNumero(p_lower, "stop de", dummy); }
    if(StringFind(p_lower, "take de") >= 0) { dummy = 0; p_takeProfit = (int)ExtraiNumero(p_lower, "take de", dummy); }
    if(StringFind(p_lower, "máximo") >= 0) { dummy = 0; p_maxTrades = (int)ExtraiNumero(p_lower, "máximo", dummy); }

    if(StringFind(p_lower, "depois das") >= 0) { dummy = 0; p_startHour = (int)ExtraiNumero(p_lower, "depois das", dummy); }
    else if(StringFind(p_lower, "após as") >= 0) { dummy = 0; p_startHour = (int)ExtraiNumero(p_lower, "após as", dummy); }

    if(StringFind(p_lower, "move stop para entrada") >= 0 || StringFind(p_lower, "breakeven") >= 0) {
        int pos = 0;
        p_breakeven = (int)ExtraiNumero(p_lower, "ao atingir", pos);
        p_breakevenStep = (int)ExtraiNumero(p_lower, "entrada", pos);
    }

    dummy = 0;
    if(StringFind(p, "trailing") >= 0 || StringFind(p, "rastreio") >= 0) {
        p_trailingStop = (int)ExtraiNumero(p, "trailing", dummy);
        if(p_trailingStop == 0) {
            dummy = 0;
            p_trailingStop = (int)ExtraiNumero(p, "rastreio", dummy);
        }
    }

    string segments[];
    StringSplit(p, '.', segments);

    ENUM_SIGNAL currentIntent = SIGNAL_NONE;
    for(int i=0; i<ArraySize(segments); i++) {
        string seg = segments[i];
        StringToLower(seg);
        if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SIGNAL_SELL;

        if(currentIntent != SIGNAL_NONE) {
            AddRuleSpecific(seg, currentIntent);
        }
    }

    GravaLog("Novo prompt interpretado: " + prompt);
}

void AddRuleSpecific(string segment, ENUM_SIGNAL intent) {
    if(intent == SIGNAL_BUY && g_nRulesBuy >= MAX_RULES) return;
    if(intent == SIGNAL_SELL && g_nRulesSell >= MAX_RULES) return;

    Rule r;
    // Zero-initialize by calling Reset (which handles handle release but here they are INVALID_HANDLE anyway)
    r.active = false;
    r.handle = INVALID_HANDLE;
    r.handle2 = INVALID_HANDLE;
    r.tf = p_frequency;

    int pos = 0;
    // MA
    if((pos = StringFind(segment, "média")) >= 0) {
        r.type = 1;
        int p_pos = pos;
        r.p1 = (int)ExtraiNumero(segment, "média de", p_pos);
        if(r.p1 == 0) {
           p_pos = pos;
           r.p1 = (int)ExtraiNumero(segment, "média", p_pos);
        }
        if(r.p1 == 0) r.p1 = 20; // Default

        if(StringFind(segment, "cruzar acima") >= 0) r.relOp = "cruzar_cima";
        else if(StringFind(segment, "cruzar abaixo") >= 0) r.relOp = "cruzar_baixo";
        r.handle = iMA(_Symbol, r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
        r.active = true;
    }
    // RSI
    else if((pos = StringFind(segment, "rsi")) >= 0) {
        r.type = 2;
        int p_pos = pos;
        // Try to find period in parentheses first
        int openP = StringFind(segment, "(", pos);
        int closeP = StringFind(segment, ")", pos);
        if(openP > 0 && closeP > openP) {
            string periodStr = StringSubstr(segment, openP+1, closeP-openP-1);
            r.p1 = (int)StringToInteger(periodStr);
        } else {
            // Check if there is a number immediately after RSI before any action keywords
            r.p1 = (int)ExtraiNumero(segment, "rsi", p_pos);
            // If the number found is suspiciously like a level, and no other number exists, reset
            if(r.p1 > 100) r.p1 = 14;
        }
        if(r.p1 == 0) r.p1 = 14;

        if(StringFind(segment, "acima") >= 0 || StringFind(segment, "subir") >= 0) {
            r.relOp = ">";
            int pos2 = pos;
            r.d1 = ExtraiNumero(segment, "acima", pos2);
            if(r.d1 == 0) { pos2 = pos; r.d1 = ExtraiNumero(segment, "subir", pos2); }
        } else if(StringFind(segment, "abaixo") >= 0 || StringFind(segment, "cair") >= 0) {
            r.relOp = "<";
            int pos2 = pos;
            r.d1 = ExtraiNumero(segment, "abaixo", pos2);
            if(r.d1 == 0) { pos2 = pos; r.d1 = ExtraiNumero(segment, "cair", pos2); }
        }
        r.handle = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
        r.active = true;
    }
    // Stoch
    else if((pos = StringFind(segment, "estocástico")) >= 0) {
        r.type = 3;
        r.p1 = 5; r.p2 = 3; r.p3 = 3; // Defaults
        r.handle = iStochastic(_Symbol, r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
        r.active = true;
    }
    // BB
    else if((pos = StringFind(segment, "bollinger")) >= 0) {
        r.type = 4;
        r.p1 = 20; r.d1 = 2.0;
        r.handle = iBands(_Symbol, r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
        r.active = true;
    }
    // Breakout
    else if((pos = StringFind(segment, "breakout")) >= 0) {
        r.type = 5;
        r.active = true;
    }
    // Delta
    else if((pos = StringFind(segment, "delta")) >= 0) {
        r.type = 6;
        r.p1 = 300;
        r.active = true;
    }
    // Volume
    else if((pos = StringFind(segment, "volume")) >= 0) {
        r.type = 7;
        r.p1 = 12;
        r.active = true;
    }
    // AMA
    else if((pos = StringFind(segment, "ama")) >= 0) {
        r.type = 8;
        r.p1 = 10;
        r.handle = iAMA(_Symbol, r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
        r.active = true;
    }
    // Pattern
    else if((pos = StringFind(segment, "padrão")) >= 0) {
        r.type = 9;
        r.active = true;
    }
    // Relative Strength
    else if((pos = StringFind(segment, "força relativa")) >= 0) {
        r.type = 10;
        r.s1 = "US30";
        r.handle = iRSI(_Symbol, r.tf, 14, PRICE_CLOSE);
        r.handle2 = iRSI(r.s1, r.tf, 14, PRICE_CLOSE);
        r.active = true;
    }

    if(r.active) {
        if(intent == SIGNAL_BUY) {
            g_rulesBuy[g_nRulesBuy] = r;
            g_nRulesBuy++;
        } else {
            g_rulesSell[g_nRulesSell] = r;
            g_nRulesSell++;
        }
    }
}

void ResetStrategy() {
    for(int i=0; i<MAX_RULES; i++) {
        g_rulesBuy[i].Reset();
        g_rulesSell[i].Reset();
    }
    g_nRulesBuy = 0;
    g_nRulesSell = 0;
}

//--- SIGNAL ENGINE
bool AvaliaTudo(ENUM_SIGNAL &signal) {
    bool buyMet = (g_nRulesBuy > 0);
    for(int i=0; i<g_nRulesBuy; i++) {
        if(!AvaliaRegra(g_rulesBuy[i], SIGNAL_BUY)) { buyMet = false; break; }
    }

    bool sellMet = (g_nRulesSell > 0);
    for(int i=0; i<g_nRulesSell; i++) {
        if(!AvaliaRegra(g_rulesSell[i], SIGNAL_SELL)) { sellMet = false; break; }
    }

    if(buyMet) { signal = SIGNAL_BUY; return true; }
    if(sellMet) { signal = SIGNAL_SELL; return true; }

    return false;
}

bool AvaliaRegra(Rule &r, ENUM_SIGNAL intent) {
    if(!r.active) return false;

    double val[3];
    switch(r.type) {
        case 1: // MA
            if(CopyBuffer(r.handle, 0, 0, 3, val) < 3) return false;
            double close1 = iClose(_Symbol, r.tf, 1);
            double close2 = iClose(_Symbol, r.tf, 2);
            if(r.relOp == "cruzar_cima") return (close2 < val[2] && close1 > val[1]);
            if(r.relOp == "cruzar_baixo") return (close2 > val[2] && close1 < val[1]);
            break;

        case 2: // RSI
            if(CopyBuffer(r.handle, 0, 0, 1, val) < 1) return false;
            if(r.relOp == ">") return val[0] > r.d1;
            if(r.relOp == "<") return val[0] < r.d1;
            break;

        case 3: // Stoch
            double k[2], d[2];
            if(CopyBuffer(r.handle, 0, 0, 2, k) < 2) return false;
            if(CopyBuffer(r.handle, 1, 0, 2, d) < 2) return false;
            if(intent == SIGNAL_BUY) return (k[1] < d[1] && k[0] > d[0]);
            if(intent == SIGNAL_SELL) return (k[1] > d[1] && k[0] < d[0]);
            break;

        case 4: // BB
            double up[1], lo[1];
            if(CopyBuffer(r.handle, 1, 0, 1, up) < 1) return false;
            if(CopyBuffer(r.handle, 2, 0, 1, lo) < 1) return false;
            double c = iClose(_Symbol, r.tf, 0);
            if(intent == SIGNAL_BUY) return c < lo[0];
            if(intent == SIGNAL_SELL) return c > up[0];
            break;

        case 5: // Breakout
            double hi_d = iHigh(_Symbol, PERIOD_D1, 1);
            double low_d = iLow(_Symbol, PERIOD_D1, 1);
            double cur_m = iClose(_Symbol, PERIOD_M1, 0);
            if(intent == SIGNAL_BUY) return cur_m > hi_d;
            if(intent == SIGNAL_SELL) return cur_m < low_d;
            break;

        case 6: // Delta
            MqlTick ticks[];
            int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent()-60, TimeCurrent());
            long b_count=0, s_count=0;
            for(int i=0; i<n; i++) if(ticks[i].flags & TICK_FLAG_BUY) b_count++; else s_count++;
            if(intent == SIGNAL_BUY) return (b_count-s_count) > r.p1;
            if(intent == SIGNAL_SELL) return (s_count-b_count) > r.p1;
            break;

        case 7: // Volume
            long vol[];
            if(CopyVolume(_Symbol, r.tf, 0, r.p1, vol) < r.p1) return false;
            int maxIdx = ArrayMaximum(vol);
            int minIdx = ArrayMinimum(vol);
            if(intent == SIGNAL_BUY) return minIdx == 0;
            if(intent == SIGNAL_SELL) return maxIdx == 0;
            break;

        case 8: // AMA
            if(CopyBuffer(r.handle, 0, 0, 2, val) < 2) return false;
            if(intent == SIGNAL_BUY) return val[0] > val[1];
            if(intent == SIGNAL_SELL) return val[0] < val[1];
            break;

        case 9: // Pattern (Inside/Outside)
            double h0=iHigh(_Symbol, r.tf, 0), l0=iLow(_Symbol, r.tf, 0);
            double h1=iHigh(_Symbol, r.tf, 1), l1=iLow(_Symbol, r.tf, 1);
            bool inside = (h0 < h1 && l0 > l1);
            bool outside = (h0 > h1 && l0 < l1);
            bool bullish = iClose(_Symbol, r.tf, 0) > iOpen(_Symbol, r.tf, 0);
            if(inside || outside) {
                if(intent == SIGNAL_BUY) return bullish;
                if(intent == SIGNAL_SELL) return !bullish;
            }
            break;

        case 10: // RS
            double rsi1[1], rsi2[1];
            if(CopyBuffer(r.handle, 0, 0, 1, rsi1) < 1) return false;
            if(CopyBuffer(r.handle2, 0, 0, 1, rsi2) < 1) return false;
            if(intent == SIGNAL_BUY) return rsi1[0] > rsi2[0] + 5;
            if(intent == SIGNAL_SELL) return rsi1[0] < rsi2[0] - 5;
            break;
    }
    return false;
}

//--- TRADE MANAGEMENT
void EnviaOrdem(ENUM_SIGNAL signal) {
    int openTrades = 0;
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionGetTicket(i)) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) openTrades++;
        }
    }
    if(openTrades >= p_maxTrades) return;

    double price = (signal == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = 0, tp = 0;
    double lot = CalculaLote(p_stopLoss);

    if(signal == SIGNAL_BUY) {
        if(p_stopLoss > 0) sl = price - p_stopLoss * _Point;
        if(p_takeProfit > 0) tp = price + p_takeProfit * _Point;
        for(int i=0; i<3; i++) {
            if(g_trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor Buy")) {
                GravaEstadoCSV(g_trade.ResultOrder(), price, sl, tp, "Signal Buy");
                break;
            }
            price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }
    } else {
        if(p_stopLoss > 0) sl = price + p_stopLoss * _Point;
        if(p_takeProfit > 0) tp = price - p_takeProfit * _Point;
        for(int i=0; i<3; i++) {
            if(g_trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor Sell")) {
                GravaEstadoCSV(g_trade.ResultOrder(), price, sl, tp, "Signal Sell");
                break;
            }
            price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        }
    }
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            if(!PositionSelectByTicket(ticket)) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double curPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl = PositionGetDouble(POSITION_SL);
            double tp = PositionGetDouble(POSITION_TP);

            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (curPrice - openPrice)/_Point : (openPrice - curPrice)/_Point;

            bool modified = false;

            // Breakeven
            if(p_breakeven > 0 && profitPoints >= p_breakeven) {
                double newSl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_breakevenStep*_Point : openPrice - p_breakevenStep*_Point;
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSl > sl) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSl < sl || sl == 0))) {
                    sl = newSl;
                    modified = true;
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? curPrice - p_trailingStop*_Point : curPrice + p_trailingStop*_Point;
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSl > sl) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSl < sl || sl == 0))) {
                    sl = newSl;
                    modified = true;
                }
            }

            if(modified) {
                if(g_trade.PositionModify(ticket, sl, tp)) {
                    GravaEstadoCSV(ticket, openPrice, sl, tp, "Modified (BE/TS)");
                }
            }
        }
    }
}

double CalculaLote(int slPoints) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAbs = equity * p_riskPercent / 100.0;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(slPoints <= 0) slPoints = 100; // Default if no SL

    double lot = riskAbs / (slPoints * _Point * (tickVal / tickSize));
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    lot = MathMax(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
    lot = MathMin(lot, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX));
    return lot;
}

//--- UTILS
bool AguardaNoticias() {
    if(!FileIsExist("calendar.txt", FILE_COMMON)) return false;
    int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h == INVALID_HANDLE) return false;

    // datetime now = TimeCurrent();
    bool veto = false;
    while(!FileIsEnding(h)) {
        // string line = FileReadString(h);
        // Expecting format: datetime,impact
        // Simplified for this simulation
    }
    FileClose(h);

    if(FileIsExist("news_veto.txt", FILE_COMMON)) {
        int hv = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
        if(hv != INVALID_HANDLE) {
            if(FileReadString(hv) == "true") veto = true;
            FileClose(hv);
        }
    }

    return veto;
}

void CalculaStats() {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity > g_peakEquity) g_peakEquity = equity;
    double dd = (g_peakEquity - equity) / g_peakEquity * 100.0;
    if(dd > g_maxDrawdown) g_maxDrawdown = dd;

    // In a real EA, we would iterate history to count wins/losses
    // For this script, we'll just log current snapshot
    GravaLog(StringFormat("Stats - Equity: %.2f, MaxDD: %.2f%%, Profit: %.2f", equity, g_maxDrawdown, g_totalProfit));
}

void GravaLog(string text) {
    Print(text);
    SendNotification(text);
}

void GravaEstadoCSV(ulong ticket, double price, double sl, double tp, string reason) {
    int h = FileOpen("states.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWrite(h, ticket, price, sl, tp, TimeToString(TimeCurrent()), reason);
        FileClose(h);
    }
}

double ExtraiNumero(string txt, string keyword, int &startPos) {
    int pos = StringFind(txt, keyword, startPos);
    if(pos < 0) return 0;

    string sub = StringSubstr(txt, pos + StringLen(keyword));
    string res = "";
    bool foundDigit = false;
    for(int i=0; i<StringLen(sub); i++) {
        ushort c = StringGetCharacter(sub, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',' || c == '-' || c == '+') {
            if(c == ',') res += ".";
            else res += CharToString((uchar)c);
            foundDigit = true;
        } else if(foundDigit) {
            break;
        }
    }
    startPos = pos + StringLen(keyword) + StringLen(res);
    return StringToDouble(res);
}

int PeriodoTexto(string nome) {
    StringToLower(nome);
    // Use specific logic to prevent timeframe collisions (e.g., m1 and m15)
    if(nome == "m15") return PERIOD_M15;
    if(nome == "m1") return PERIOD_M1;
    if(nome == "m5") return PERIOD_M5;
    if(nome == "h1") return PERIOD_H1;
    if(nome == "d1") return PERIOD_D1;
    return PERIOD_CURRENT;
}

int AIPredict() {
    if(!FileIsExist("signal_ai.txt", FILE_COMMON)) return 0;
    int h = FileOpen("signal_ai.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h == INVALID_HANDLE) return 0;
    string s = FileReadString(h);
    FileClose(h);
    if(s == "BUY") return 1;
    if(s == "SELL") return -1;
    return 0;
}
