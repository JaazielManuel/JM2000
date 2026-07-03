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

#define EA_MAGIC 123456

// --- Enums ---
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };
enum ENUM_RULE_TYPE {
    TYPE_MA=1, TYPE_RSI=2, TYPE_STOCH=3, TYPE_BB=4, TYPE_BREAKOUT=5,
    TYPE_DELTA=6, TYPE_VOLUME=7, TYPE_AMA=8, TYPE_PATTERN=9, TYPE_RS=10
};

// --- Structs ---
struct Rule {
    bool active;
    ENUM_RULE_TYPE type;
    ENUM_SIGNAL intent; // BUY or SELL
    int tf;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    string op; // Operator: ">", "<", "cross_above", "cross_below"
    int handle;
    int handle2;
};

// --- Globals ---
Rule g_buyRules[20];
Rule g_sellRules[20];
int g_nBuyRules = 0;
int g_nSellRules = 0;

// Strategy parameters
double p_risk = 1.0;
int p_stopPoints = 0;
int p_takePoints = 0;
int p_breakeven = 0;
int p_breakevenProfit = 0;
int p_trailingStop = 0;
int p_startHour = 0;
int p_maxTrades = 3;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// Performance stats
double g_peakEquity = 0;
double g_maxDrawdown = 0;
int g_wins = 0;
int g_losses = 0;
double g_totalProfit = 0;

CTrade trade;

// Forward declarations
void ResetStrategy();
void InterpretaPrompt(string prompt);
void AddRuleSpecific(string segment, ENUM_SIGNAL intent);
double ExtraiNumero(string txt, int startPos=0);
int PeriodoTexto(string nome);
ENUM_SIGNAL AvaliaTudo();
bool AvaliaRegra(Rule &r);
void EnviaOrdem(ENUM_SIGNAL signal, double risk);
double CalculaLote(double riskPercent, int slPoints);
void GerenciaPosicoes();
void CalculaStats();
bool AguardaNoticias();
void GravaLog(string txt);
void GravaEstadoCSV(ulong ticket, string motivo);
ENUM_SIGNAL AIPredict();

// --- Event Handlers ---

int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(3600); // Hourly stats
    ResetStrategy();
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    CalculaStats();
    ResetStrategy();
    EventKillTimer();
}

void OnTick() {
    // 1. Check for real-time prompt updates
    static uint lastPromptCheck = 0;
    if(GetTickCount() - lastPromptCheck > 1000) {
        if(FileStringsTotal("prompt.txt", FILE_COMMON) > 0) {
            int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
            if(h != INVALID_HANDLE) {
                string prompt = FileReadString(h);
                FileClose(h);
                FileDelete("prompt.txt", FILE_COMMON);
                InterpretaPrompt(prompt);
            }
        }
        lastPromptCheck = GetTickCount();
    }

    // 2. Filter by hour
    MqlDateTime dt;
    TimeCurrent(dt);
    if(dt.hour < p_startHour) return;

    // 3. News veto
    if(AguardaNoticias()) return;

    // 4. Frequency check (New bar)
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != lastBar) {
        ENUM_SIGNAL sig = AvaliaTudo();
        if(sig != SIGNAL_NONE) {
            EnviaOrdem(sig, p_risk);
        }
        lastBar = currentBar;
    }

    // 5. Active position management
    GerenciaPosicoes();
}

void OnTimer() {
    CalculaStats();
}

// --- MT5-KNOWLEDGE-CORE (Signals) ---

// 1.1 MÉDIAS & CRUZAMENTOS
ENUM_SIGNAL CruzamentoMA(int fast, int slow, int tf, int shift, int h1, int h2) {
    double f1 = GetBufferValue(h1, 0, shift);
    double s1 = GetBufferValue(h2, 0, shift);
    double f2 = GetBufferValue(h1, 0, shift+1);
    double s2 = GetBufferValue(h2, 0, shift+1);
    if(f2 < s2 && f1 > s1) return SIGNAL_BUY;
    if(f2 > s2 && f1 < s1) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 1.2 RSI
ENUM_SIGNAL RSIThreshold(int period, double over, double under, int tf, int shift, int h) {
    double v = GetBufferValue(h, 0, shift);
    if(v > over) return SIGNAL_SELL;
    if(v < under) return SIGNAL_BUY;
    return SIGNAL_NONE;
}

// 1.3 ESTOCÁSTICO
ENUM_SIGNAL StochCross(int tf, int k, int d, int slowing, int shift, int h) {
    double k1 = GetBufferValue(h, 0, shift);
    double d1 = GetBufferValue(h, 1, shift);
    double k2 = GetBufferValue(h, 0, shift+1);
    double d2 = GetBufferValue(h, 1, shift+1);
    if(k2 < d2 && k1 > d1) return SIGNAL_BUY;
    if(k2 > d2 && k1 < d1) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 1.4 BOLLINGER BOUNCE
ENUM_SIGNAL BBounce(int period, double desv, int tf, int shift, int h) {
    double main = GetBufferValue(h, 0, shift);
    double upper = GetBufferValue(h, 1, shift);
    double lower = GetBufferValue(h, 2, shift);
    double close = iClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
    if(close < lower) return SIGNAL_BUY;
    if(close > upper) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 1.5 BREAKOUT DIÁRIO
ENUM_SIGNAL DailyBreak(int shift) {
    double hi = iHigh(_Symbol, PERIOD_D1, 1);
    double lo = iLow(_Symbol, PERIOD_D1, 1);
    double close = iClose(_Symbol, PERIOD_M1, shift);
    if(close > hi + SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)) return SIGNAL_BUY;
    if(close < lo - SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE)) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
ENUM_SIGNAL DeltaAggression(int seconds, int deltaTrigger) {
    MqlTick arr[];
    int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - seconds, TimeCurrent());
    long buy = 0, sell = 0;
    for(int i=0; i<n; i++) if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
    long delta = buy - sell;
    if(delta > deltaTrigger) return SIGNAL_BUY;
    if(delta < -deltaTrigger) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 1.7 CICLO DE VOLUME (Williams)
ENUM_SIGNAL VolumeCycle(int len, int tf, int shift) {
    long vol[];
    ArraySetAsSeries(vol, true);
    if(CopyVolume(_Symbol, (ENUM_TIMEFRAMES)tf, shift, len, vol) <= 0) return SIGNAL_NONE;
    int maxIdx = ArrayMaximum(vol);
    int minIdx = ArrayMinimum(vol);
    if(maxIdx == 0) return SIGNAL_SELL;
    if(minIdx == 0) return SIGNAL_BUY;
    return SIGNAL_NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Kaufman)
ENUM_SIGNAL AMA(int h, int shift) {
    double ama1 = GetBufferValue(h, 0, shift);
    double ama2 = GetBufferValue(h, 0, shift+1);
    if(ama2 < ama1) return SIGNAL_BUY;
    if(ama2 > ama1) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// 1.9 PADRÃO DE 2 BARRAS (inside / outside)
ENUM_SIGNAL Bar2Pattern(int tf, int shift) {
    double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
    double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
    double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)tf, shift+1);
    double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)tf, shift+1);
    double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)tf, shift);
    double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)tf, shift);

    if(h0 < h1 && l0 > l1) return (c0 > o0) ? SIGNAL_BUY : SIGNAL_SELL; // Inside
    if(h0 > h1 && l0 < l1) return (c0 > o0) ? SIGNAL_SELL : SIGNAL_BUY; // Outside
    return SIGNAL_NONE;
}

// 1.10 FORÇA RELATIVA ENTRE ATIVOS
ENUM_SIGNAL RSRelative(int h1, int h2, int shift) {
    double r1 = GetBufferValue(h1, 0, shift);
    double r2 = GetBufferValue(h2, 0, shift);
    if(r1 > r2 + 5) return SIGNAL_BUY;
    if(r1 < r2 - 5) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// Helper to get buffer value
double GetBufferValue(int handle, int bufferNum, int shift) {
    double buffer[];
    ArraySetAsSeries(buffer, true);
    if(CopyBuffer(handle, bufferNum, shift, 1, buffer) > 0) return buffer[0];
    return 0;
}

void ResetStrategy() {
    for(int i=0; i<20; i++) {
        if(g_buyRules[i].handle != INVALID_HANDLE) IndicatorRelease(g_buyRules[i].handle);
        if(g_buyRules[i].handle2 != INVALID_HANDLE) IndicatorRelease(g_buyRules[i].handle2);
        if(g_sellRules[i].handle != INVALID_HANDLE) IndicatorRelease(g_sellRules[i].handle);
        if(g_sellRules[i].handle2 != INVALID_HANDLE) IndicatorRelease(g_sellRules[i].handle2);
    }
    ZeroMemory(g_buyRules);
    ZeroMemory(g_sellRules);
    for(int i=0; i<20; i++) {
        g_buyRules[i].handle = INVALID_HANDLE;
        g_buyRules[i].handle2 = INVALID_HANDLE;
        g_sellRules[i].handle = INVALID_HANDLE;
        g_sellRules[i].handle2 = INVALID_HANDLE;
    }
    g_nBuyRules = 0;
    g_nSellRules = 0;

    // Reset params to defaults
    p_risk = 1.0;
    p_stopPoints = 0;
    p_takePoints = 0;
    p_breakeven = 0;
    p_breakevenProfit = 0;
    p_trailingStop = 0;
    p_startHour = 0;
    p_maxTrades = 3;
    p_frequency = PERIOD_M15;
}

// --- NLP Parser & NLP Normalization ---

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string p = prompt;
    StringToLower(p);

    // Normalization
    StringReplace(p, " e ", ".");
    StringReplace(p, " e o ", ".");
    StringReplace(p, " e a ", ".");
    StringReplace(p, "|", ".");
    StringReplace(p, "\n", ".");

    // Global parameters parsing
    if(StringFind(p, "stop de ") >= 0) p_stopPoints = (int)ExtraiNumero(p, StringFind(p, "stop de "));
    if(StringFind(p, "take de ") >= 0) p_takePoints = (int)ExtraiNumero(p, StringFind(p, "take de "));
    if(StringFind(p, "risco de ") >= 0) p_risk = ExtraiNumero(p, StringFind(p, "risco de "));
    if(StringFind(p, "máximo ") >= 0 && StringFind(p, " trades") >= 0) p_maxTrades = (int)ExtraiNumero(p, StringFind(p, "máximo "));
    if(StringFind(p, "depois das ") >= 0) p_startHour = (int)ExtraiNumero(p, StringFind(p, "depois das "));
    if(StringFind(p, "após as ") >= 0) p_startHour = (int)ExtraiNumero(p, StringFind(p, "após as "));

    // Breakeven
    if(StringFind(p, "breakeven") >= 0 || StringFind(p, "move stop para entrada") >= 0) {
        p_breakeven = (int)ExtraiNumero(p, StringFind(p, "ao atingir"));
        p_breakevenProfit = (int)ExtraiNumero(p, StringFind(p, "entrada +"));
    }

    // Trailing
    if(StringFind(p, "trailing") >= 0 || StringFind(p, "rastreio") >= 0) {
        p_trailingStop = (int)ExtraiNumero(p, StringFind(p, "trailing"));
        if(p_trailingStop == 0) p_trailingStop = (int)ExtraiNumero(p, StringFind(p, "rastreio"));
    }

    // Frequency
    if(StringFind(p, "a cada ") >= 0) {
        int val = (int)ExtraiNumero(p, StringFind(p, "a cada "));
        if(StringFind(p, "minutos") >= 0) {
            if(val <= 1) p_frequency = PERIOD_M1;
            else if(val <= 5) p_frequency = PERIOD_M5;
            else if(val <= 15) p_frequency = PERIOD_M15;
            else if(val <= 30) p_frequency = PERIOD_M30;
        } else if(StringFind(p, "hora") >= 0) p_frequency = PERIOD_H1;
    }

    // Split into segments
    string segments[];
    int n = StringSplit(p, '.', segments);
    ENUM_SIGNAL currentIntent = SIGNAL_NONE;

    for(int i=0; i<n; i++) {
        string seg = segments[i];
        StringTrimLeft(seg); StringTrimRight(seg);
        if(seg == "") continue;

        if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
        else if(StringFind(seg, "venda") >= 0) currentIntent = SIGNAL_SELL;

        if(currentIntent != SIGNAL_NONE) {
            AddRuleSpecific(seg, currentIntent);
        }
    }
    GravaLog("Estratégia interpretada: " + prompt);
}

void AddRuleSpecific(string segment, ENUM_SIGNAL intent) {
    Rule r;
    ZeroMemory(r);
    r.active = false;
    r.intent = intent;
    r.tf = p_frequency;

    int pos = -1;

    // MA
    if((pos = StringFind(segment, "média")) >= 0 || (pos = StringFind(segment, "ema")) >= 0) {
        r.active = true;
        r.type = TYPE_MA;
        r.p1 = (int)ExtraiNumero(segment, pos);
        if(r.p1 == 0) {
            if(intent == SIGNAL_SELL && g_nBuyRules > 0) r.p1 = g_buyRules[0].p1;
            else r.p1 = 20;
        }
        r.handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);

        // Check for second period (MA crossover)
        int posSlash = StringFind(segment, "/", pos);
        if(posSlash >= 0) {
            r.p2 = (int)ExtraiNumero(segment, posSlash);
            if(r.p2 > 0) r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
        }

        if(StringFind(segment, "cruzar acima") >= 0 || StringFind(segment, "cruzamento") >= 0) r.op = "cross_above";
        else if(StringFind(segment, "cruzar abaixo") >= 0) r.op = "cross_below";
        else if(StringFind(segment, "acima") >= 0) r.op = ">";
        else if(StringFind(segment, "abaixo") >= 0) r.op = "<";
    }

    // RSI
    else if((pos = StringFind(segment, "rsi")) >= 0) {
        r.active = true;
        r.type = TYPE_RSI;
        r.p1 = (int)ExtraiNumero(segment, pos);
        if(r.p1 == 0) r.p1 = 14;
        r.d1 = ExtraiNumero(segment, StringFind(segment, "acima", pos));
        if(r.d1 == 0) r.d1 = ExtraiNumero(segment, StringFind(segment, "abaixo", pos));
        if(r.d1 == 0) r.d1 = ExtraiNumero(segment, StringFind(segment, "subir acima", pos));
        if(r.d1 == 0) r.d1 = ExtraiNumero(segment, StringFind(segment, "cair abaixo", pos));

        r.handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        if(StringFind(segment, "acima") >= 0 || StringFind(segment, "subir") >= 0) r.op = ">";
        else if(StringFind(segment, "abaixo") >= 0 || StringFind(segment, "cair") >= 0) r.op = "<";
    }

    // Patterns
    else if((pos = StringFind(segment, "padrão")) >= 0) {
        r.active = true;
        r.type = TYPE_PATTERN;
    }

    // Breakout
    else if((pos = StringFind(segment, "breakout")) >= 0) {
        r.active = true;
        r.type = TYPE_BREAKOUT;
    }

    if(r.active) {
        if(intent == SIGNAL_BUY && g_nBuyRules < 20) {
            g_buyRules[g_nBuyRules] = r;
            g_nBuyRules++;
        } else if(intent == SIGNAL_SELL && g_nSellRules < 20) {
            g_sellRules[g_nSellRules] = r;
            g_nSellRules++;
        }
    }
}

double ExtraiNumero(string txt, int startPos=0) {
    string res = "";
    bool found = false;
    for(int i=startPos; i<StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',' || c == '-' || c == '+') {
            if(c == ',') c = '.';
            res += ShortToString(c);
            found = true;
        } else if(found) break;
    }
    return StringToDouble(res);
}

int PeriodoTexto(string nome) {
    StringToLower(nome);
    if(StringFind(nome, "m15") >= 0) return PERIOD_M15; // Order matters: m15 before m1
    if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
    if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
    if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
    if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

// --- Signal Confluence Engine ---

ENUM_SIGNAL AvaliaTudo() {
    // BUY check
    bool allBuy = (g_nBuyRules > 0);
    for(int i=0; i<g_nBuyRules; i++) {
        if(!AvaliaRegra(g_buyRules[i])) { allBuy = false; break; }
    }
    if(allBuy) return SIGNAL_BUY;

    // SELL check
    bool allSell = (g_nSellRules > 0);
    for(int i=0; i<g_nSellRules; i++) {
        if(!AvaliaRegra(g_sellRules[i])) { allSell = false; break; }
    }
    if(allSell) return SIGNAL_SELL;

    return SIGNAL_NONE;
}

bool AvaliaRegra(Rule &r) {
    if(!r.active) return false;

    if(r.type == TYPE_MA) {
        if(r.op == "cross_above") {
            if(r.handle2 != INVALID_HANDLE) return CruzamentoMA(r.p1, r.p2, r.tf, 0, r.handle, r.handle2) == SIGNAL_BUY;
            // Price cross above MA
            double m1 = GetBufferValue(r.handle, 0, 1);
            double m0 = GetBufferValue(r.handle, 0, 0);
            double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double p0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            return (p1 <= m1 && p0 > m0);
        }
        if(r.op == "cross_below") {
            if(r.handle2 != INVALID_HANDLE) return CruzamentoMA(r.p1, r.p2, r.tf, 0, r.handle, r.handle2) == SIGNAL_SELL;
            // Price cross below MA
            double m1 = GetBufferValue(r.handle, 0, 1);
            double m0 = GetBufferValue(r.handle, 0, 0);
            double p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double p0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            return (p1 >= m1 && p0 < m0);
        }
        double v = GetBufferValue(r.handle, 0, 0);
        double price = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
        if(r.op == ">") return price > v;
        if(r.op == "<") return price < v;
    }

    if(r.type == TYPE_RSI) {
        double v = GetBufferValue(r.handle, 0, 0);
        if(r.op == ">") return v > r.d1;
        if(r.op == "<") return v < r.d1;
    }

    if(r.type == TYPE_PATTERN) {
        ENUM_SIGNAL sig = Bar2Pattern(r.tf, 0);
        return sig == r.intent;
    }

    if(r.type == TYPE_BREAKOUT) {
        ENUM_SIGNAL sig = DailyBreak(0);
        return sig == r.intent;
    }

    return false;
}

// --- Trade Execution & Management ---

void EnviaOrdem(ENUM_SIGNAL signal, double risk) {
    if(signal == SIGNAL_NONE) return;

    // Max trades check
    int open = 0;
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) open++;
        }
    }
    if(open >= p_maxTrades) return;

    double lote = CalculaLote(risk, p_stopPoints);
    double sl = 0, tp = 0;
    double price = (signal == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(signal == SIGNAL_BUY) {
        if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price + p_takePoints * _Point;
        for(int i=0; i<3; i++) {
            if(trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor BUY")) {
                if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
                    GravaEstadoCSV(trade.ResultOrder(), "BUY signal");
                    break;
                }
            }
            price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }
    } else {
        if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price - p_takePoints * _Point;
        for(int i=0; i<3; i++) {
            if(trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor SELL")) {
                if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
                    GravaEstadoCSV(trade.ResultOrder(), "SELL signal");
                    break;
                }
            }
            price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        }
    }
}

double CalculaLote(double riskPercent, int slPoints) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riscoAbs = capital * riskPercent / 100.0;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(slPoints <= 0) slPoints = 300; // Default safety

    double lot = riscoAbs / (slPoints * _Point * (tickVal / tickSize));
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
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double curPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double points = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (curPrice - openPrice) / _Point : (openPrice - curPrice) / _Point;

            // Breakeven
            if(p_breakeven > 0 && points >= p_breakeven) {
                double sl = PositionGetDouble(POSITION_SL);
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_breakevenProfit * _Point : openPrice - p_breakevenProfit * _Point;
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                    GravaEstadoCSV(ticket, "Breakeven adjusted");
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && points >= p_trailingStop) {
                double sl = PositionGetDouble(POSITION_SL);
                double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? curPrice - p_trailingStop * _Point : curPrice + p_trailingStop * _Point;
                if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) ||
                   (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                    trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                }
            }
        }
    }
}

void CalculaStats() {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity > g_peakEquity) g_peakEquity = equity;
    if(g_peakEquity > 0) {
        double dd = (g_peakEquity - equity) / g_peakEquity * 100.0;
        if(dd > g_maxDrawdown) g_maxDrawdown = dd;
    }
    // Summary in log
    GravaLog(StringFormat("Stats: Equity=%.2f, MaxDD=%.2f%%, Peak=%.2f", equity, g_maxDrawdown, g_peakEquity));
}

bool AguardaNoticias() {
    int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string veto = FileReadString(h);
        FileClose(h);
        if(veto == "true" || veto == "1") return true;
    }
    return false;
}

void GravaLog(string txt) {
    Print(txt);
    SendNotification(txt);
}

void GravaEstadoCSV(ulong ticket, string motivo) {
    int h = FileOpen("states.csv", FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        if(PositionSelectByTicket(ticket)) {
            string line = StringFormat("%llu,%s,%.5f,%.5f,%.5f,%s,%s\n",
                ticket, _Symbol, PositionGetDouble(POSITION_PRICE_OPEN),
                PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP),
                TimeToString(TimeCurrent()), motivo);
            FileWriteString(h, line);
        }
        FileClose(h);
    }
}

ENUM_SIGNAL AIPredict() {
    int h = FileOpen("signal_ai.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string s = FileReadString(h);
        FileClose(h);
        if(s == "BUY") return SIGNAL_BUY;
        if(s == "SELL") return SIGNAL_SELL;
    }
    return SIGNAL_NONE;
}

// Utility to count lines in a file
int FileStringsTotal(string filename, int flags) {
    int h = FileOpen(filename, FILE_READ|FILE_TXT|flags);
    if(h == INVALID_HANDLE) return 0;
    int count = 0;
    while(!FileIsEnding(h)) {
        FileReadString(h);
        count++;
    }
    FileClose(h);
    return count;
}
