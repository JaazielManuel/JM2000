//+------------------------------------------------------------------+
//|                                             MT_LiveExecutor.mq5 |
//|                                  Copyright 2026, Profit Master  |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Profit Master"
#property link      "https://www.mql5.com"
#property version   "9.50"
#property strict
#property description "Profit Master v8.0 - MT-LiveExecutor"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

//=========================  MT5-KNOWLEDGE-CORE  =========================

enum Signal {BUY=1, SELL=-1, NONE=0};
enum RuleType {MA_CROSS=1, RSI_THRESHOLD=2, STOCH_CROSS=3, BB_BOUNCE=4, DAILY_BREAK=5, DELTA_AGG=6, VOL_CYCLE=7, AMA_KAUFMAN=8, BAR_PATTERN=9, RS_RELATIVE=10};

struct Rule {
    bool            active;
    RuleType        type;
    ENUM_TIMEFRAMES timeframe;
    int             p1, p2, p3;
    double          d1, d2;
    string          s1;
    int             handle;
    int             handle2;
    bool            is_cross;
    Signal          intent;

    void Reset() {
        if(handle != INVALID_HANDLE) { IndicatorRelease(handle); handle = INVALID_HANDLE; }
        if(handle2 != INVALID_HANDLE) { IndicatorRelease(handle2); handle2 = INVALID_HANDLE; }
        active = false;
        type = (RuleType)0;
        timeframe = PERIOD_CURRENT;
        p1 = p2 = p3 = 0;
        d1 = d2 = 0;
        s1 = "";
        is_cross = false;
        intent = NONE;
    }
};

// Global variables
#define EA_MAGIC 20260101
#define PROMPT_FILE "MT_LiveExecutor_Prompt.txt"
#define UPDATE_VAR "MT_Executor_Prompt_Update"

Rule rules[30];
int nRules = 0;
input string InpPrompt = "A cada 15 minutos, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// Strategy parameters
double p_risk = 1.0;
int p_stopPoints = 0;
int p_takePoints = 0;
int p_newsVetoMins = 0;
int p_maxTrades = 100;
int p_frequency = 0;
int p_beTrigger = 0;
int p_bePoints = 0;
int p_trailingStop = 0;
bool p_martingale = false;
bool p_hedge = false;
bool p_notifications = false;
datetime p_startTime = 0;

// Internal state
datetime lastBarTime = 0;
int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbInfo;
int atrHandle = INVALID_HANDLE;

// Legacy MQL4 wrappers for compatibility
double iClose(string symbol, int tf, int shift) {
   double res[1];
   if(CopyClose(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iOpen(string symbol, int tf, int shift) {
   double res[1];
   if(CopyOpen(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iHigh(string symbol, int tf, int shift) {
   double res[1];
   if(CopyHigh(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}
double iLow(string symbol, int tf, int shift) {
   double res[1];
   if(CopyLow(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}
datetime iTime(string symbol, int tf, int shift) {
   datetime res[1];
   if(CopyTime(symbol, (ENUM_TIMEFRAMES)tf, shift, 1, res) > 0) return res[0];
   return 0;
}

// 1.1 MÉDIAS & CRUZAMENTOS
Signal CruzamentoMA(int handle1, int handle2, int shift=1)
{
   double f[2], s[2]; // f[0]=current, f[1]=previous
   if(CopyBuffer(handle1, 0, shift, 2, f) <= 0) return NONE;
   if(handle2 != INVALID_HANDLE) {
      if(CopyBuffer(handle2, 0, shift, 2, s) <= 0) return NONE;
   } else {
      // Comparison with Price
      if(CopyClose(_Symbol, PERIOD_CURRENT, shift, 2, s) <= 0) return NONE;
   }

   if(f[1] < s[1] && f[0] > s[0]) return BUY;
   if(f[1] > s[1] && f[0] < s[0]) return SELL;
   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(int handle, double over, double under, bool is_cross, int shift=1)
{
   double v[2]; // v[0]=current, v[1]=previous
   if(CopyBuffer(handle, 0, shift, 2, v) <= 0) return NONE;

   if(is_cross) {
      if(v[1] <= under && v[0] > under) return BUY;
      if(v[1] >= over && v[0] < over) return SELL;
   } else {
      // Detected trend/reversion logic based on threshold levels
      if(over > under) { // Standard
         if(v[1] < under) return BUY;
         if(v[1] > over) return SELL;
      } else { // Inverted logic
         if(v[1] > under) return BUY;
         if(v[1] < over) return SELL;
      }
   }
   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(int handle, int shift=1)
{
   double k[2], d[2]; // [0]=current, [1]=previous
   if(CopyBuffer(handle, 0, shift, 2, k) <= 0) return NONE;
   if(CopyBuffer(handle, 1, shift, 2, d) <= 0) return NONE;

   if(k[1] < d[1] && k[0] > d[0]) return BUY;
   if(k[1] > d[1] && k[0] < d[0]) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BOUNCE
Signal BBounce(int handle, int shift=1)
{
   double up[1], lo[1], cl[1];
   if(CopyBuffer(handle, 1, shift, 1, up) <= 0) return NONE;
   if(CopyBuffer(handle, 2, shift, 1, lo) <= 0) return NONE;
   if(CopyClose(_Symbol, PERIOD_CURRENT, shift, 1, cl) <= 0) return NONE;

   if(cl[0] < lo[0]) return BUY;
   if(cl[0] > up[0]) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(int shift=1)
{
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
Signal DeltaAggression(int seconds=60, int deltaTrigger=300)
{
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

// 1.7 CICLO DE VOLUME
Signal VolumeCycle(int len=12, int shift=1)
{
   long vol[];
   if(CopyVolume(_Symbol, PERIOD_CURRENT, shift, len, vol) <= 0) return NONE;
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   if(maxIdx == 0) return SELL;
   if(minIdx == 0) return BUY;
   return NONE;
}

// 1.8 AMA (Kaufman)
Signal AMA(int handle, int shift=1)
{
   double v[2]; // [0]=current, [1]=previous
   if(CopyBuffer(handle, 0, shift, 2, v) <= 0) return NONE;
   if(v[1] < v[0]) return BUY;
   if(v[1] > v[0]) return SELL;
   return NONE;
}

// 1.9 PADRÃO DE 2 BARRAS
Signal Bar2Pattern(int shift=1)
{
   double h0=iHigh(_Symbol, PERIOD_CURRENT, shift);
   double l0=iLow(_Symbol, PERIOD_CURRENT, shift);
   double h1=iHigh(_Symbol, PERIOD_CURRENT, shift+1);
   double l1=iLow(_Symbol, PERIOD_CURRENT, shift+1);
   double c0=iClose(_Symbol, PERIOD_CURRENT, shift);
   double o0=iOpen(_Symbol, PERIOD_CURRENT, shift);

   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;
   return NONE;
}


//+------------------------------------------------------------------+
//| HELPERS                                                          |
//+------------------------------------------------------------------+

double ExtraiNumero(string text, int startPos) {
    string res = "";
    bool started = false;
    for(int i = startPos; i < StringLen(text); i++) {
        ushort c = StringGetCharacter(text, i);
        if((c >= '0' && c <= '9') || c == '.' || c == '+' || c == '-') {
            res += StringSubstr(text, i, 1);
            started = true;
        } else if(started) {
            break;
        }
    }
    return StringToDouble(res);
}

int PeriodoTexto(string nome) {
    string n = nome; StringToLower(n);
    if(StringFind(n, "m15") >= 0 || StringFind(n, "15 min") >= 0) return PERIOD_M15;
    if(StringFind(n, "m30") >= 0 || StringFind(n, "30 min") >= 0) return PERIOD_M30;
    if(StringFind(n, "m1") >= 0 || StringFind(n, "1 min") >= 0)  return PERIOD_M1;
    if(StringFind(n, "m5") >= 0 || StringFind(n, "5 min") >= 0)  return PERIOD_M5;
    if(StringFind(n, "h4") >= 0 || StringFind(n, "4 horas") >= 0) return PERIOD_H4;
    if(StringFind(n, "h1") >= 0 || StringFind(n, "1 hora") >= 0)  return PERIOD_H1;
    if(StringFind(n, "d1") >= 0 || StringFind(n, "diário") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

ENUM_TIMEFRAMES MinutesToTimeframe(int mins) {
   if(mins <= 1) return PERIOD_M1;
   if(mins <= 5) return PERIOD_M5;
   if(mins <= 15) return PERIOD_M15;
   if(mins <= 30) return PERIOD_M30;
   if(mins <= 60) return PERIOD_H1;
   if(mins <= 240) return PERIOD_H4;
   return PERIOD_D1;
}

//+------------------------------------------------------------------+
//| ResetStrategy                                                    |
//+------------------------------------------------------------------+

void ResetStrategy() {
    for(int i=0; i<30; i++) {
        rules[i].Reset();
    }
    nRules = 0;
    lastBarTime = 0;
    p_risk = 1.0;
    p_stopPoints = 0;
    p_takePoints = 0;
    p_newsVetoMins = 0;
    p_maxTrades = 100;
    p_frequency = PERIOD_CURRENT;
    p_beTrigger = 0;
    p_bePoints = 0;
    p_trailingStop = 0;
    p_martingale = false;
    p_hedge = false;
    p_notifications = false;
    p_startTime = 0;
    if(atrHandle != INVALID_HANDLE) { IndicatorRelease(atrHandle); atrHandle = INVALID_HANDLE; }
}

//+------------------------------------------------------------------+
//| SIGNAL EVALUATION ENGINE                                         |
//+------------------------------------------------------------------+

Signal AvaliaRegra(int idx) {
    if(idx < 0 || idx >= 30 || !rules[idx].active) return NONE;

    ENUM_TIMEFRAMES tf = rules[idx].timeframe;
    int h = rules[idx].handle;
    int h2 = rules[idx].handle2;
    int p1 = rules[idx].p1;
    int p2 = rules[idx].p2;
    double d1 = rules[idx].d1;
    double d2 = rules[idx].d2;
    bool cross = rules[idx].is_cross;

    switch(rules[idx].type) {
        case MA_CROSS: {
            double ma[2], comp[2];
            if(CopyBuffer(h, 0, 1, 2, ma) < 2) return NONE;
            if(h2 != INVALID_HANDLE) {
                if(CopyBuffer(h2, 0, 1, 2, comp) < 2) return NONE;
            } else {
                if(CopyClose(_Symbol, tf, 1, 2, comp) < 2) return NONE;
            }
            if(ma[1] <= comp[1] && ma[0] > comp[0]) return BUY;
            if(ma[1] >= comp[1] && ma[0] < comp[0]) return SELL;
            break;
        }
        case RSI_THRESHOLD: {
            double rsi[2];
            if(CopyBuffer(h, 0, 1, 2, rsi) < 2) return NONE;
            if(cross) {
                if(rsi[1] <= d1 && rsi[0] > d1) return BUY;
                if(rsi[1] >= d2 && rsi[0] < d2) return SELL;
            } else {
                if(rsi[0] > d1) return BUY;
                if(rsi[0] < d2) return SELL;
            }
            break;
        }
        case STOCH_CROSS: {
            double k[2], d[2];
            if(CopyBuffer(h, 0, 1, 2, k) < 2) return NONE;
            if(CopyBuffer(h, 1, 1, 2, d) < 2) return NONE;
            if(k[1] <= d[1] && k[0] > d[0]) return BUY;
            if(k[1] >= d[1] && k[0] < d[0]) return SELL;
            break;
        }
        case BB_BOUNCE: {
            double up[1], lo[1], cl[1];
            if(CopyBuffer(h, 1, 1, 1, up) < 1) return NONE;
            if(CopyBuffer(h, 2, 1, 1, lo) < 1) return NONE;
            if(CopyClose(_Symbol, tf, 1, 1, cl) < 1) return NONE;
            if(cl[0] < lo[0]) return BUY;
            if(cl[0] > up[0]) return SELL;
            break;
        }
        case DAILY_BREAK: {
            double hi = iHigh(_Symbol, PERIOD_D1, 1);
            double lo = iLow(_Symbol, PERIOD_D1, 1);
            double cl = iClose(_Symbol, tf, 1);
            if(cl > hi) return BUY;
            if(cl < lo) return SELL;
            break;
        }
        case BAR_PATTERN: {
            double h0 = iHigh(_Symbol, tf, 1);
            double l0 = iLow(_Symbol, tf, 1);
            double h1 = iHigh(_Symbol, tf, 2);
            double l1 = iLow(_Symbol, tf, 2);
            double c0 = iClose(_Symbol, tf, 1);
            double o0 = iOpen(_Symbol, tf, 1);
            if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL; // Inside Bar
            if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY; // Outside Bar
            break;
        }
        case RS_RELATIVE: {
            double r1[1], r2[1];
            if(CopyBuffer(h, 0, 1, 1, r1) < 1) return NONE;
            if(CopyBuffer(h2, 0, 1, 1, r2) < 1) return NONE;
            if(r1[0] > r2[0] + 5) return BUY;
            if(r1[0] < r2[0] - 5) return SELL;
            break;
        }
        case DELTA_AGG: {
            return DeltaAggression(p1, (int)d1);
        }
        case VOL_CYCLE: {
            return VolumeCycle(p1);
        }
        case AMA_KAUFMAN: {
            double ama[2];
            if(CopyBuffer(h, 0, 1, 2, ama) < 2) return NONE;
            if(ama[0] > ama[1]) return BUY;
            if(ama[0] < ama[1]) return SELL;
            break;
        }
    }
    return NONE;
}

void AddRuleSpecific(RuleType type, int p1, int p2, double d1, double d2, string s1, ENUM_TIMEFRAMES tf, Signal intent, bool cross) {
    if(nRules >= 30) return;
    int idx = nRules;
    rules[idx].Reset();
    rules[idx].active = true;
    rules[idx].type = type;
    rules[idx].p1 = p1; rules[idx].p2 = p2;
    rules[idx].d1 = d1; rules[idx].d2 = d2;
    rules[idx].s1 = s1;
    rules[idx].timeframe = tf;
    rules[idx].intent = intent;
    rules[idx].is_cross = cross;

    switch(type) {
        case MA_CROSS:
            rules[idx].handle = iMA(_Symbol, tf, p1, 0, MODE_SMA, PRICE_CLOSE);
            if(p2 > 0) rules[idx].handle2 = iMA(_Symbol, tf, p2, 0, MODE_SMA, PRICE_CLOSE);
            break;
        case RSI_THRESHOLD:
            rules[idx].handle = iRSI(_Symbol, tf, p1, PRICE_CLOSE);
            break;
        case STOCH_CROSS:
            rules[idx].handle = iStochastic(_Symbol, tf, p1, p2, 3, MODE_SMA, STO_LOWHIGH);
            break;
        case BB_BOUNCE:
            rules[idx].handle = iBands(_Symbol, tf, p1, 0, d1, PRICE_CLOSE);
            break;
        case RS_RELATIVE:
            rules[idx].handle = iRSI(_Symbol, tf, p1, PRICE_CLOSE);
            rules[idx].handle2 = iRSI(s1, tf, p1, PRICE_CLOSE);
            break;
        case AMA_KAUFMAN:
            rules[idx].handle = iAMA(_Symbol, tf, p1, 2, 30, 0, PRICE_CLOSE);
            break;
    }
    nRules++;
}

//+------------------------------------------------------------------+
//| InterpretaPrompt                                                 |
//+------------------------------------------------------------------+

void InterpretaPrompt(string prompt) {
    StringToLower(prompt);
    ResetStrategy();

    string normalized = prompt;
    StringReplace(normalized, "|", ".");
    StringReplace(normalized, "\n", ".");
    StringReplace(normalized, " e ", ".");
    StringReplace(normalized, " + ", ".");

    string segments[];
    int nSegments = StringSplit(normalized, '.', segments);
    Signal currentIntent = NONE;
    ENUM_TIMEFRAMES currentTF = PERIOD_CURRENT;

    // Detect global timeframe first
    currentTF = PeriodoTexto(prompt);
    p_frequency = currentTF;

    for(int i = 0; i < nSegments; i++) {
        string seg = segments[i];
        StringTrimLeft(seg); StringTrimRight(seg);
        if(StringLen(seg) == 0) continue;

        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

        // Indicators
        int pos = -1;

        // MA
        pos = StringFind(seg, "média");
        if(pos < 0) pos = StringFind(seg, "ma");
        if(pos >= 0) {
            int p1 = (int)ExtraiNumero(seg, pos + 5);
            if(p1 <= 0) p1 = 20;
            bool cross = (StringFind(seg, "cruzar") >= 0);
            AddRuleSpecific(MA_CROSS, p1, 0, 0, 0, "", currentTF, currentIntent, cross);
        }

        // RSI
        pos = StringFind(seg, "rsi");
        if(pos >= 0) {
            int p1 = (int)ExtraiNumero(seg, pos + 3);
            if(p1 <= 0) p1 = 14;
            double d1 = 70, d2 = 30;
            int pAcima = StringFind(seg, "acima de");
            int pAbaixo = StringFind(seg, "abaixo de");
            if(pAcima >= 0) d1 = ExtraiNumero(seg, pAcima + 8);
            if(pAbaixo >= 0) d2 = ExtraiNumero(seg, pAbaixo + 9);
            bool cross = (StringFind(seg, "subir") >= 0 || StringFind(seg, "cair") >= 0 || StringFind(seg, "cruzar") >= 0);
            AddRuleSpecific(RSI_THRESHOLD, p1, 0, d1, d2, "", currentTF, currentIntent, cross);
        }

        // Stoch
        pos = StringFind(seg, "estocástico");
        if(pos < 0) pos = StringFind(seg, "stoch");
        if(pos >= 0) {
            AddRuleSpecific(STOCH_CROSS, 5, 3, 0, 0, "", currentTF, currentIntent, true);
        }

        // Bollinger
        pos = StringFind(seg, "bollinger");
        if(pos < 0) pos = StringFind(seg, "bandas");
        if(pos >= 0) {
            AddRuleSpecific(BB_BOUNCE, 20, 0, 2.0, 0, "", currentTF, currentIntent, false);
        }

        // Breakout
        if(StringFind(seg, "rompimento") >= 0 || StringFind(seg, "breakout") >= 0) {
            AddRuleSpecific(DAILY_BREAK, 0, 0, 0, 0, "", currentTF, currentIntent, true);
        }

        // Pattern
        if(StringFind(seg, "padrão") >= 0 || StringFind(seg, "inside") >= 0 || StringFind(seg, "outside") >= 0) {
            AddRuleSpecific(BAR_PATTERN, 0, 0, 0, 0, "", currentTF, currentIntent, true);
        }
    }

    // Parameters
    int pRisco = StringFind(prompt, "risco de");
    if(pRisco >= 0) p_risk = ExtraiNumero(prompt, pRisco + 8);

    int pStop = StringFind(prompt, "stop de");
    if(pStop >= 0) p_stopPoints = (int)ExtraiNumero(prompt, pStop + 7);

    int pTake = StringFind(prompt, "take de");
    if(pTake >= 0) p_takePoints = (int)ExtraiNumero(prompt, pTake + 7);

    int pMax = StringFind(prompt, "máximo");
    if(pMax >= 0) p_maxTrades = (int)ExtraiNumero(prompt, pMax + 6);

    int pNews = StringFind(prompt, "notícias");
    if(pNews >= 0) p_newsVetoMins = 20;

    int pBeTrig = StringFind(prompt, "atingir");
    if(pBeTrig >= 0) p_beTrigger = (int)ExtraiNumero(prompt, pBeTrig + 7);
    int pBePts = StringFind(prompt, "entrada");
    if(pBePts >= 0) p_bePoints = (int)ExtraiNumero(prompt, pBePts + 7);

    if(StringFind(prompt, "trailing") >= 0 || StringFind(prompt, "rastreio") >= 0) p_trailingStop = 30;

    if(StringFind(prompt, "martingale") >= 0) p_martingale = true;
    if(StringFind(prompt, "hedge") >= 0) p_hedge = true;

    int pStart = StringFind(prompt, "depois das");
    if(pStart < 0) pStart = StringFind(prompt, "após as");
    if(pStart >= 0) {
        int h = (int)ExtraiNumero(prompt, pStart + 10);
        MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
        dt.hour = h; dt.min = 0; dt.sec = 0;
        p_startTime = StructToTime(dt);
    }

    PrintFormat("Estratégia: %d regras, Risco: %.1f%%, TF: %s", nRules, p_risk, EnumToString(p_frequency));
}

//+------------------------------------------------------------------+
//| TRADING LOGIC                                                    |
//+------------------------------------------------------------------+

Signal AvaliaTudo() {
    if(nRules == 0) return NONE;

    int buyRules = 0, buyVotes = 0;
    int sellRules = 0, sellVotes = 0;

    for(int i=0; i<nRules; i++) {
        Signal s = AvaliaRegra(i);

        if(rules[i].intent == BUY || rules[i].intent == NONE) {
            buyRules++;
            if(s == BUY) buyVotes++;
        }
        if(rules[i].intent == SELL || rules[i].intent == NONE) {
            sellRules++;
            if(s == SELL) sellVotes++;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) return BUY;
    if(sellRules > 0 && sellVotes == sellRules) return SELL;

    return NONE;
}

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riscoAbs = capital * riscoPercent / 100.0;
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    int slPoints = (p_stopPoints > 0) ? p_stopPoints : 100;
    double lot = riscoAbs / (slPoints * _Point * (tickVal / tickSize));

    // Martingale
    if(p_martingale) {
        HistorySelect(TimeCurrent() - 86400, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong t = HistoryDealGetTicket(i);
            if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol) {
                if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) lot *= 2.0;
                break;
            }
        }
    }

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    return MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), lot));
}

bool IsPriceSafe(double price, bool isSL = false) {
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safetyBuffer = (stopsLevel + dynamicSafetyPoints + 2) * _Point;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(MathAbs(price - bid) < safetyBuffer || MathAbs(price - ask) < safetyBuffer) return false;
   return true;
}

void EnviaOrdem(Signal s) {
    if(s == NONE) return;

    // Check concurrent trades by MAGIC
    int count = 0;
    for(int i=0; i<PositionsTotal(); i++) {
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) count++;
    }
    if(count >= p_maxTrades) return;

    double lote = CalculaLote(p_risk);
    double sl = 0, tp = 0;

    for(int attempt=0; attempt<3; attempt++) {
        double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(s == BUY) {
            if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
            if(p_takePoints > 0) tp = price + p_takePoints * _Point;
            if(sl != 0 && !IsPriceSafe(sl, true)) sl = price - (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * _Point;
            sl = NormalizeDouble(sl, _Digits);
            tp = NormalizeDouble(tp, _Digits);
            if(trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor")) break;
        } else {
            if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
            if(p_takePoints > 0) tp = price - p_takePoints * _Point;
            if(sl != 0 && !IsPriceSafe(sl, true)) sl = price + (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 2) * _Point;
            sl = NormalizeDouble(sl, _Digits);
            tp = NormalizeDouble(tp, _Digits);
            if(trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor")) break;
        }

        uint retcode = trade.ResultRetcode();
        if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED) break;

        PrintFormat("Tentativa %d falhou: %s", attempt+1, trade.ResultRetcodeDescription());
        Sleep(100);
    }

    if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
        GravaLog((s == BUY ? "COMPRA" : "VENDA") + " EXECUTADA");
        GravaEstadoCSV();
    }
}

void SynchronizeClusterSL(long type) {
   double targetSL = 0;
   // Find the SL of the most recent position of the same type
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_TYPE) == type) {
         targetSL = PositionGetDouble(POSITION_SL);
         break;
      }
   }
   if(targetSL <= 0) return;

   for(int i=0; i<PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_TYPE) == type) {
         if(MathAbs(PositionGetDouble(POSITION_SL) - targetSL) > _Point) {
            trade.PositionModify(ticket, NormalizeDouble(targetSL, _Digits), PositionGetDouble(POSITION_TP));
         }
      }
   }
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(posInfo.Symbol() != _Symbol || posInfo.Magic() != EA_MAGIC) continue;

            double openPrice = posInfo.PriceOpen();
            double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl = posInfo.StopLoss();
            double tp = posInfo.TakeProfit();

            // Breakeven
            if(p_beTrigger > 0) {
                double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
                if(profitPoints >= p_beTrigger) {
                    double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePoints * _Point : openPrice - p_bePoints * _Point;
                    newSL = NormalizeDouble(newSL, _Digits);
                    if((posInfo.PositionType() == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (posInfo.PositionType() == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                        if(trade.PositionModify(ticket, newSL, tp)) GravaEstadoCSV();
                    }
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0) {
                double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;
                if(profitPoints > p_trailingStop) {
                    double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
                    newSL = NormalizeDouble(newSL, _Digits);
                    if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > sl) || (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < sl || sl == 0))) {
                        if(trade.PositionModify(ticket, newSL, tp)) GravaEstadoCSV();
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| AUXILIARY FEATURES                                               |
//+------------------------------------------------------------------+

bool AguardaNoticias() {
   // 1. External file veto (Common folder)
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
   }

   // 2. Internal calendar fallback
   if(p_newsVetoMins == 0) return false;
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - p_newsVetoMins * 60;
   datetime to = TimeCurrent() + p_newsVetoMins * 60;

   if(CalendarValueHistory(values, from, to)) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}

void GravaEstadoCSV() {
    int h = FileOpen("states.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Profit");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
                FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
            }
        }
        FileClose(h);
    }
}

void CalculaStats() {
    HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, losses = 0;
    double totalProf = 0, totalLoss = 0, maxDD = 0, curDD = 0, balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double peak = balance;

    for(int i = 0; i < total; i++) {
        ulong t = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT);
            if(p > 0) { wins++; totalProf += p; }
            else if(p < 0) { losses++; totalLoss += MathAbs(p); }
            balance += p;
            if(balance > peak) peak = balance;
            curDD = peak - balance;
            if(curDD > maxDD) maxDD = curDD;
        }
    }
    double wr = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
    double pf = (totalLoss > 0) ? totalProf / totalLoss : totalProf;
    GravaLog(StringFormat("Stats: WR: %.1f%%, PF: %.2f, MaxDD: %.2f", wr, pf, maxDD));
}

void GravaLog(string texto) {
    string t = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
    PrintFormat("[%s] MT-LiveExecutor: %s", t, texto);
    int h = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWrite(h, t, texto);
        FileClose(h);
    }
    if(p_notifications) SendNotification("MT-LiveExecutor: " + texto);
}

void AIOptimizer() {
    // ATR optimization
    if(atrHandle == INVALID_HANDLE) atrHandle = iATR(_Symbol, p_frequency, 14);
    double atr[1];
    if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
        int sug = (int)(atr[0] * 1.5 / _Point);
        if(p_stopPoints > 0 && sug > p_stopPoints * 1.5) {
            PrintFormat("IA Sugestão: Volatilidade alta (ATR: %.5f). Sugestão SL: %d pts", atr[0], sug);
        }
    }
}

//+------------------------------------------------------------------+
//| LIFECYCLE HANDLERS                                               |
//+------------------------------------------------------------------+

int OnInit() {
    symbInfo.Name(_Symbol);
    trade.SetExpertMagicNumber(EA_MAGIC);
    InterpretaPrompt(InpPrompt);
    EventSetTimer(1);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    CalculaStats();
    for(int i = 0; i < 30; i++) rules[i].Reset();
    if(atrHandle != INVALID_HANDLE) { IndicatorRelease(atrHandle); atrHandle = INVALID_HANDLE; }
    EventKillTimer();
    Print("MT-LiveExecutor: Encerrado.");
}

void OnTick() {
    if(TimeCurrent() < p_startTime) return;
    if(AguardaNoticias()) return;

    datetime curBar = iTime(_Symbol, p_frequency, 0);
    if(curBar != lastBarTime) {
        Signal s = AvaliaTudo();
        if(s != NONE) {
            EnviaOrdem(s);
            lastBarTime = curBar;
        }
    }
    GerenciaPosicoes();
}

void OnTimer() {
    static uint lastPromptCheck = 0;
    static uint lastStatsUpdate = 0;
    uint now = GetTickCount();

    if(now - lastPromptCheck > 1000) {
        int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
        if(h != INVALID_HANDLE) {
            string p = FileReadString(h);
            FileClose(h);
            FileDelete("prompt.txt", FILE_COMMON);
            if(StringLen(p) > 0) InterpretaPrompt(p);
        }
        lastPromptCheck = now;
    }

    if(now - lastStatsUpdate > 3600000) {
        CalculaStats();
        AIOptimizer();
        lastStatsUpdate = now;
    }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_IN) {
            long type = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            SynchronizeClusterSL(type);
         }
      }
   }
}
