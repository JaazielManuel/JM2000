//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

// --- Includes ---
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Defines ---
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- Enums ---
enum ENUM_SIGNAL { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = -1 };

// --- Structs ---
struct Rule {
    bool active;
    int type; // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: Breakout, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: Relative
    int tf;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    string rel_op; // Relational operator: ">", "<", "cross_above", "cross_below", etc.
    int handle;
    int handle2;
};

// --- Globals ---
Rule g_buyRules[MAX_RULES];
Rule g_sellRules[MAX_RULES];
int g_nBuyRules = 0;
int g_nSellRules = 0;

string p_prompt = "";
int p_frequency = PERIOD_M15;
int p_startHour = 0;
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
int p_breakevenTrigger = 0;
int p_breakevenProfit = 0;
int p_trailingStop = 0;

double g_peakEquity = 0;
double g_maxDrawdown = 0;
int g_winCount = 0;
int g_lossCount = 0;
double g_totalProfit = 0;

CTrade trade;

//=========================  MT5-KNOWLEDGE-CORE  =========================

// 1.1 MÉDIAS & CRUZAMENTOS (Type 1)
int GetMA(int handle, int shift, double &val) {
    double buffer[1];
    if (CopyBuffer(handle, 0, shift, 1, buffer) < 1) return -1;
    val = buffer[0];
    return 1;
}

// 1.2 RSI (Type 2)
int GetRSI(int handle, int shift, double &val) {
    double buffer[1];
    if (CopyBuffer(handle, 0, shift, 1, buffer) < 1) return -1;
    val = buffer[0];
    return 1;
}

// 1.3 ESTOCÁSTICO (Type 3)
int GetStoch(int handle, int mode, int shift, double &val) {
    double buffer[1];
    if (CopyBuffer(handle, mode, shift, 1, buffer) < 1) return -1;
    val = buffer[0];
    return 1;
}

// 1.4 BOLLINGER BANDS (Type 4)
int GetBands(int handle, int mode, int shift, double &val) {
    double buffer[1];
    if (CopyBuffer(handle, mode, shift, 1, buffer) < 1) return -1;
    val = buffer[0];
    return 1;
}

// 1.5 BREAKOUT DIÁRIO (Type 5)
double GetDailyHigh(int shift) { return iHigh(_Symbol, PERIOD_D1, shift); }
double GetDailyLow(int shift) { return iLow(_Symbol, PERIOD_D1, shift); }

// 1.6 DELTA DE AGRESSÃO (Type 6)
long GetDelta(int seconds) {
    MqlTick ticks[];
    int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, (TimeCurrent() - seconds) * 1000, TimeCurrent() * 1000);
    long buy = 0, sell = 0;
    for (int i = 0; i < n; i++) {
        if ((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
        else if ((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
    }
    return buy - sell;
}

// 1.7 CICLO DE VOLUME (Type 7)
long GetVolume(int tf, int shift) {
    long buffer[1];
    if (CopyTickVolume(_Symbol, (ENUM_TIMEFRAMES)tf, shift, 1, buffer) < 1) return -1;
    return buffer[0];
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Type 8)
int GetAMA(int handle, int shift, double &val) {
    double buffer[1];
    if (CopyBuffer(handle, 0, shift, 1, buffer) < 1) return -1;
    val = buffer[0];
    return 1;
}

// 1.9 PADRÃO DE 2 BARRAS (Type 9)
int GetBarPattern(int tf, int shift) {
    double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
    double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
    double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
    double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
    double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)tf, shift + 1);
    double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)tf, shift + 1);

    // Inside Bar
    if (h0 < h1 && l0 > l1) return (c0 > o0) ? 1 : -1;
    // Outside Bar
    if (h0 > h1 && l0 < l1) return (c0 > o0) ? -1 : 1;
    return 0;
}

// 1.10 FORÇA RELATIVA (Type 10)
double GetRelativeStrength(string bench, int period, int tf, int shift) {
    int h1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, period, PRICE_CLOSE);
    int h2 = iRSI(bench, (ENUM_TIMEFRAMES)tf, period, PRICE_CLOSE);
    double v1[1], v2[1];
    if (CopyBuffer(h1, 0, shift, 1, v1) < 1 || CopyBuffer(h2, 0, shift, 1, v2) < 1) {
        IndicatorRelease(h1); IndicatorRelease(h2);
        return 0;
    }
    IndicatorRelease(h1); IndicatorRelease(h2);
    return v1[0] - v2[0];
}

// ---------- 2. MOTOR DE INTERPRETAÇÃO DE PROMPT ----------

void ResetStrategy() {
    for (int i = 0; i < g_nBuyRules; i++) {
        if (g_buyRules[i].handle != INVALID_HANDLE) IndicatorRelease(g_buyRules[i].handle);
        if (g_buyRules[i].handle2 != INVALID_HANDLE) IndicatorRelease(g_buyRules[i].handle2);
        g_buyRules[i].active = false;
        g_buyRules[i].handle = INVALID_HANDLE;
        g_buyRules[i].handle2 = INVALID_HANDLE;
    }
    for (int i = 0; i < g_nSellRules; i++) {
        if (g_sellRules[i].handle != INVALID_HANDLE) IndicatorRelease(g_sellRules[i].handle);
        if (g_sellRules[i].handle2 != INVALID_HANDLE) IndicatorRelease(g_sellRules[i].handle2);
        g_sellRules[i].active = false;
        g_sellRules[i].handle = INVALID_HANDLE;
        g_sellRules[i].handle2 = INVALID_HANDLE;
    }
    g_nBuyRules = 0;
    g_nSellRules = 0;
}

double ExtraiNumero(string txt, int startPos = 0) {
    if (startPos < 0) return 0.0;
    string res = "";
    bool found = false;
    for (int i = startPos; i < StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if ((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+') {
            res += CharToString((char)c);
            found = true;
        } else if (found) break;
    }
    return StringToDouble(res);
}

int PeriodoTexto(string nome) {
    string s = nome;
    StringToLower(s);
    if (StringFind(s, "m1") >= 0) return PERIOD_M1;
    if (StringFind(s, "m5") >= 0) return PERIOD_M5;
    if (StringFind(s, "m15") >= 0) return PERIOD_M15;
    if (StringFind(s, "m30") >= 0) return PERIOD_M30;
    if (StringFind(s, "h1") >= 0 || StringFind(s, "1 hora") >= 0) return PERIOD_H1;
    if (StringFind(s, "h4") >= 0) return PERIOD_H4;
    if (StringFind(s, "d1") >= 0 || StringFind(s, "diário") >= 0) return PERIOD_D1;
    return p_frequency;
}

void AddRuleSpecific(string segment, int intent) {
    Rule r;
    ZeroMemory(r);
    r.active = true;
    r.tf = PeriodoTexto(segment);
    r.handle = INVALID_HANDLE;
    r.handle2 = INVALID_HANDLE;

    // Moving Average (Type 1)
    if (StringFind(segment, "média") >= 0 || StringFind(segment, "ma") >= 0 || StringFind(segment, "ema") >= 0) {
        r.type = 1;
        int maPos = StringFind(segment, "média");
        if (maPos < 0) maPos = StringFind(segment, "ma");
        if (maPos < 0) maPos = StringFind(segment, "ema");
        r.p1 = (int)ExtraiNumero(segment, maPos);
        if (r.p1 <= 0) r.p1 = 20;

        int crossPos = StringFind(segment, "cruzar");
        if (crossPos >= 0) {
            if (StringFind(segment, "acima") >= 0) r.rel_op = "cross_above";
            else r.rel_op = "cross_below";
        } else {
            if (StringFind(segment, "acima") >= 0) r.rel_op = ">";
            else r.rel_op = "<";
        }

        // MA vs MA detection
        int secondMA = StringFind(segment, " e ", crossPos > 0 ? crossPos : 0);
        if (secondMA < 0) secondMA = StringFind(segment, "/", crossPos > 0 ? crossPos : 0);
        if (secondMA >= 0) {
            r.p2 = (int)ExtraiNumero(segment, secondMA);
            if (r.p2 > 0) {
                r.handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
                r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_SMA, PRICE_CLOSE);
            }
        }

        if (r.handle == INVALID_HANDLE) {
            r.handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
        }
    }
    // RSI (Type 2)
    else if (StringFind(segment, "rsi") >= 0) {
        r.type = 2;
        r.p1 = (int)ExtraiNumero(segment, StringFind(segment, "rsi"));
        if (r.p1 <= 0) r.p1 = 14;

        int opPos = StringFind(segment, "acima");
        if (opPos < 0) opPos = StringFind(segment, "abaixo");
        r.d1 = ExtraiNumero(segment, opPos);

        if (StringFind(segment, "subir") >= 0 || StringFind(segment, "cruzar acima") >= 0) r.rel_op = "cross_above";
        else if (StringFind(segment, "cair") >= 0 || StringFind(segment, "cruzar abaixo") >= 0) r.rel_op = "cross_below";
        else if (StringFind(segment, "acima") >= 0) r.rel_op = ">";
        else r.rel_op = "<";

        r.handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
    }
    // Stochastic (Type 3)
    else if (StringFind(segment, "estocástico") >= 0 || StringFind(segment, "stoch") >= 0) {
        r.type = 3;
        r.p1 = 5; r.p2 = 3; r.p3 = 3; // Defaults
        r.handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
        if (StringFind(segment, "cruzar") >= 0) r.rel_op = "cross_above"; // Signal cross
        else r.rel_op = ">";
    }
    // Bollinger Bands (Type 4)
    else if (StringFind(segment, "bollinger") >= 0 || StringFind(segment, "bandas") >= 0) {
        r.type = 4;
        r.p1 = 20; r.d1 = 2.0; // Defaults
        r.handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
        if (StringFind(segment, "baixo") >= 0 || StringFind(segment, "inferior") >= 0) r.rel_op = "lower";
        else r.rel_op = "upper";
    }
    // Pattern (Type 9)
    else if (StringFind(segment, "padrão") >= 0 || StringFind(segment, "candle") >= 0) {
        r.type = 9;
    }

    if (r.type > 0) {
        if (intent == 1) { g_buyRules[g_nBuyRules] = r; g_nBuyRules++; }
        else { g_sellRules[g_nSellRules] = r; g_nSellRules++; }
    }
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string p = prompt;
    StringToLower(p);

    StringReplace(p, " e o ", ".");
    StringReplace(p, " e a ", ".");
    StringReplace(p, " e ", ".");
    StringReplace(p, ",", ".");

    // Global parameters
    if (StringFind(p, "a cada") >= 0) p_frequency = PeriodoTexto(p);
    if (StringFind(p, "depois das") >= 0) p_startHour = (int)ExtraiNumero(p, StringFind(p, "depois das"));
    if (StringFind(p, "após as") >= 0) p_startHour = (int)ExtraiNumero(p, StringFind(p, "após as"));
    if (StringFind(p, "stop de") >= 0) p_stopPoints = (int)ExtraiNumero(p, StringFind(p, "stop de"));
    if (StringFind(p, "take de") >= 0) p_takePoints = (int)ExtraiNumero(p, StringFind(p, "take de"));
    if (StringFind(p, "risco de") >= 0) p_riskPercent = ExtraiNumero(p, StringFind(p, "risco de"));
    if (StringFind(p, "máximo") >= 0 && StringFind(p, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(p, StringFind(p, "máximo"));

    // Breakeven
    int bePos = StringFind(p, "ao atingir");
    if (bePos >= 0) {
        p_breakevenTrigger = (int)ExtraiNumero(p, bePos);
        p_breakevenProfit = (int)ExtraiNumero(p, StringFind(p, "entrada", bePos));
    }

    // Trailing
    if (StringFind(p, "trailing") >= 0 || StringFind(p, "rastreio") >= 0) {
        p_trailingStop = (int)ExtraiNumero(p, StringFind(p, "trailing") >= 0 ? StringFind(p, "trailing") : StringFind(p, "rastreio"));
    }

    // Segments parsing
    string segments[];
    ushort sep = '.';
    int n = StringSplit(p, sep, segments);

    int currentIntent = 0; // 1: BUY, -1: SELL
    for (int i = 0; i < n; i++) {
        string s = segments[i];
        if (StringFind(s, "compra") >= 0) currentIntent = 1;
        else if (StringFind(s, "vende") >= 0) currentIntent = -1;

        if (currentIntent != 0) {
            AddRuleSpecific(s, currentIntent);
        }
    }
}

// ---------- 3. DECISÃO FINAL ----------

bool AvaliaRegra(Rule &r, int shift) {
    if (!r.active) return false;
    double val1 = 0, val2 = 0;
    double prev1 = 0, prev2 = 0;

    switch (r.type) {
        case 1: // MA
            if (r.handle2 == INVALID_HANDLE) {
                GetMA(r.handle, shift, val1);
                GetMA(r.handle, shift + 1, prev1);
                double price = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
                double pPrice = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift + 1);
                if (r.rel_op == "cross_above") return (pPrice <= prev1 && price > val1);
                if (r.rel_op == "cross_below") return (pPrice >= prev1 && price < val1);
                if (r.rel_op == ">") return (price > val1);
                if (r.rel_op == "<") return (price < val1);
            } else {
                GetMA(r.handle, shift, val1);
                GetMA(r.handle2, shift, val2);
                GetMA(r.handle, shift + 1, prev1);
                GetMA(r.handle2, shift + 1, prev2);
                if (r.rel_op == "cross_above") return (prev1 <= prev2 && val1 > val2);
                if (r.rel_op == "cross_below") return (prev1 >= prev2 && val1 < val2);
                if (r.rel_op == ">") return (val1 > val2);
                if (r.rel_op == "<") return (val1 < val2);
            }
            break;

        case 2: // RSI
            GetRSI(r.handle, shift, val1);
            GetRSI(r.handle, shift + 1, prev1);
            if (r.rel_op == "cross_above") return (prev1 <= r.d1 && val1 > r.d1);
            if (r.rel_op == "cross_below") return (prev1 >= r.d1 && val1 < r.d1);
            if (r.rel_op == ">") return (val1 > r.d1);
            if (r.rel_op == "<") return (val1 < r.d1);
            break;

        case 3: // Stoch
            GetStoch(r.handle, 0, shift, val1); // K
            GetStoch(r.handle, 1, shift, val2); // D
            GetStoch(r.handle, 0, shift + 1, prev1);
            GetStoch(r.handle, 1, shift + 1, prev2);
            if (r.rel_op == "cross_above") return (prev1 <= prev2 && val1 > val2);
            if (r.rel_op == "cross_below") return (prev1 >= prev2 && val1 < val2);
            break;

        case 4: // BB
            GetBands(r.handle, 1, shift, val1); // Upper
            GetBands(r.handle, 2, shift, val2); // Lower
            double price_bb = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
            if (r.rel_op == "upper") return (price_bb > val1);
            if (r.rel_op == "lower") return (price_bb < val2);
            break;

        case 9: // Pattern
            int pat = GetBarPattern(r.tf, shift);
            if (pat == 1) return true; // Signal based on intent? Usually patterns return 1/-1.
            break;
    }
    return false;
}

ENUM_SIGNAL AvaliaTudo() {
    if (g_nBuyRules > 0) {
        bool allMatch = true;
        for (int i = 0; i < g_nBuyRules; i++) {
            if (!AvaliaRegra(g_buyRules[i], 0)) { allMatch = false; break; }
        }
        if (allMatch) return SIGNAL_BUY;
    }

    if (g_nSellRules > 0) {
        bool allMatch = true;
        for (int i = 0; i < g_nSellRules; i++) {
            if (!AvaliaRegra(g_sellRules[i], 0)) { allMatch = false; break; }
        }
        if (allMatch) return SIGNAL_SELL;
    }

    return SIGNAL_NONE;
}

// ---------- 4. EXECUTOR DE ORDEM E GESTÃO ----------

double CalculaLote(double riscoPercent, double slPoints) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAbs = equity * (riscoPercent / 100.0);
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if (slPoints <= 0) slPoints = p_stopPoints;
    if (slPoints <= 0) slPoints = 100; // fallback

    double lot = riskAbs / (slPoints * _Point * (tickVal / tickSize));

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if (lot < minLot) lot = minLot;
    if (lot > maxLot) lot = maxLot;

    return lot;
}

void EnviaOrdem(ENUM_SIGNAL type, double price, double sl, double tp, double lot) {
    trade.SetExpertMagicNumber(EA_MAGIC);
    bool res = false;
    string stype = (type == SIGNAL_BUY) ? "BUY" : "SELL";

    for (int i = 0; i < 3; i++) {
        if (type == SIGNAL_BUY) res = trade.Buy(lot, _Symbol, price, sl, tp);
        else res = trade.Sell(lot, _Symbol, price, sl, tp);

        if (res) {
            GravaLog("Ordem de " + stype + " executada: " + DoubleToString(trade.ResultPrice(), _Digits));
            GravaEstadoCSV(trade.ResultOrder(), "ENTRY_" + stype);
            break;
        } else {
            // GravaLog("Erro ao enviar " + stype + ": " + IntegerToString(trade.ResultRetcode()));
            if (trade.ResultRetcode() == 10004 || trade.ResultRetcode() == 10006) { // Requote or off-quote
                price = (type == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
            } else break;
        }
    }
}

void GerenciaPosicoes() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if (PositionSelectByTicket(ticket)) {
            if (PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
            double sl = PositionGetDouble(POSITION_SL);
            long type = PositionGetInteger(POSITION_TYPE);

            double profitPoints = (type == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

            // Breakeven
            if (p_breakevenTrigger > 0 && profitPoints >= p_breakevenTrigger) {
                double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_breakevenProfit * _Point : openPrice - p_breakevenProfit * _Point;
                if ((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                    if (trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP))) {
                        GravaEstadoCSV(ticket, "BREAKEVEN");
                    }
                }
            }

            // Trailing Stop
            if (p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (type == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
                if ((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                    if (trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP))) {
                        GravaEstadoCSV(ticket, "TRAILING");
                    }
                }
            }
        }
    }
}

// ---------- 5. AUXILIARES E LIFECYCLE ----------

void GravaLog(string txt) {
    Print(txt);
}

void GravaEstadoCSV(ulong ticket, string action) {
    int handle = FileOpen("states.csv", FILE_WRITE | FILE_READ | FILE_CSV | FILE_COMMON, ',');
    if (handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, ticket, TimeToString(TimeCurrent()), action, Symbol(), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP));
        FileClose(handle);
    }
}

bool AguardaNoticias() {
    int h1 = FileOpen("calendar.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    int h2 = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    bool veto = false;
    if (h1 != INVALID_HANDLE) { veto = true; FileClose(h1); }
    if (h2 != INVALID_HANDLE) { veto = true; FileClose(h2); }
    return veto;
}

ENUM_SIGNAL AIPredict() {
    int h = FileOpen("signal_ai.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    ENUM_SIGNAL s = SIGNAL_NONE;
    if (h != INVALID_HANDLE) {
        string content = FileReadString(h);
        if (content == "BUY") s = SIGNAL_BUY;
        else if (content == "SELL") s = SIGNAL_SELL;
        FileClose(h);
    }
    return s;
}

void CalculaStats() {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if (equity > g_peakEquity) g_peakEquity = equity;
    if (g_peakEquity > 0) {
        double dd = (g_peakEquity - equity) / g_peakEquity * 100.0;
        if (dd > g_maxDrawdown) g_maxDrawdown = dd;
    }
}

// --- Event Handlers ---

int OnInit() {
    EventSetTimer(3600);
    p_prompt = "A cada 15 minutos, compra se média 20 cruzar acima e rsi 14 acima de 55. Vende se média 20 cruzar abaixo e rsi 14 abaixo de 45. Stop de 300 pontos, take de 500 pontos. Risco de 1.0 %. Máximo 3 trades. Ao atingir +300 pontos, move stop para entrada +50 pontos.";
    InterpretaPrompt(p_prompt);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    ResetStrategy();
    CalculaStats();
}

void OnTick() {
    // Check for prompt update
    if (FileIsExist("prompt.txt", FILE_COMMON)) {
        int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
        if (h != INVALID_HANDLE) {
            p_prompt = FileReadString(h);
            FileClose(h);
            FileDelete("prompt.txt", FILE_COMMON);
            InterpretaPrompt(p_prompt);
        }
    }

    if (AguardaNoticias()) return;

    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if (dt.hour < p_startHour) return;

    GerenciaPosicoes();

    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
    if (currentBar == lastBar) return;
    lastBar = currentBar;

    int openTrades = 0;
    for (int i = 0; i < PositionsTotal(); i++) {
        if (PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) openTrades++;
    }
    if (openTrades >= p_maxTrades) return;

    ENUM_SIGNAL sig = AvaliaTudo();
    if (sig != SIGNAL_NONE) {
        double price = (sig == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
        double sl = (sig == SIGNAL_BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
        double tp = (sig == SIGNAL_BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;
        double lot = CalculaLote(p_riskPercent, p_stopPoints);
        EnviaOrdem(sig, price, sl, tp, lot);
    }
}

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result) {
    if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {
        if (HistoryDealSelect(trans.deal)) {
            long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
            if (magic == EA_MAGIC) {
                double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                if (profit > 0) g_winCount++;
                else if (profit < 0) g_lossCount++;
                g_totalProfit += profit;
                GravaEstadoCSV(HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID), (profit >= 0) ? "EXIT_PROFIT" : "EXIT_LOSS");
                CalculaStats();
            }
        }
    }
}

void OnTimer() {
    CalculaStats();
}
