//=========================  MT5-LIVE-EXECUTOR  =========================
// Procedural, prompt-driven execution engine for MQL5
//========================================================================

#property copyright "Copyright 2024, Jules"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- DEFINES & ENUMS ----------
#define EA_MAGIC 123456
enum ENUM_SIGNAL { SIGNAL_BUY=1, SIGNAL_SELL=-1, SIGNAL_NONE=0 };

// ---------- GLOBALS ----------
struct Rule {
   bool     active;
   int      type;       // 1-10
   int      tf;         // Timeframe
   int      p1, p2, p3; // Periods/params
   double   d1, d2;     // Thresholds/params
   string   s1;         // Bench symbol or extra text
   int      handle1, handle2;

   void Reset() {
      active = false; type = 0; tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
      handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
   }
};

Rule g_buyRules[10];
Rule g_sellRules[10];
int g_nBuyRules = 0;
int g_nSellRules = 0;

void ResetStrategy() {
    for(int i = 0; i < 10; i++) {
        if(g_buyRules[i].handle1 != INVALID_HANDLE) IndicatorRelease(g_buyRules[i].handle1);
        if(g_buyRules[i].handle2 != INVALID_HANDLE) IndicatorRelease(g_buyRules[i].handle2);
        if(g_sellRules[i].handle1 != INVALID_HANDLE) IndicatorRelease(g_sellRules[i].handle1);
        if(g_sellRules[i].handle2 != INVALID_HANDLE) IndicatorRelease(g_sellRules[i].handle2);

        g_buyRules[i].Reset();
        g_sellRules[i].Reset();
    }
    g_nBuyRules = 0;
    g_nSellRules = 0;
}

// Global Strategy Parameters
double   p_risk = 1.0;
int      p_slPoints = 300;
int      p_tpPoints = 500;
int      p_maxTrades = 3;
int      p_breakeven = 300;
int      p_breakevenPlus = 50;
int      p_trailingStop = 0;
int      p_trailingStep = 50;
int      p_newsVeto = 20; // minutes
int      p_startHour = 0;
bool     p_martingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

CTrade   trade;

// ---------- UTILITIES ----------

double ExtraiNumero(string txt, int &cursor) {
    string res = "";
    bool found = false;
    int len = StringLen(txt);

    while(cursor < len) {
        ushort c = StringGetCharacter(txt, cursor);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') c = '.';
            res += ShortToString(c);
            found = true;
        } else if(found) {
            break;
        }
        cursor++;
    }
    return StringToDouble(res);
}

int PeriodoTexto(string txt) {
    string t = txt;
    StringToLower(t);
    if(StringFind(t, "m15") >= 0) return PERIOD_M15;
    if(StringFind(t, "m1") >= 0)  return PERIOD_M1;
    if(StringFind(t, "m5") >= 0)  return PERIOD_M5;
    if(StringFind(t, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(t, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

void AddRule(string txt, ENUM_SIGNAL intent) {
    Rule r; r.Reset();
    string segment = txt;
    StringToLower(segment);

    static int lastMA = 20;
    static int lastRSI = 14;

    if(StringFind(segment, "média") >= 0 || StringFind(segment, "media") >= 0 || StringFind(segment, "ma") >= 0) {
        r.type = 1; // MA Cross
        int cursor = StringFind(segment, "média");
        if(cursor < 0) cursor = StringFind(segment, "media");
        if(cursor < 0) cursor = StringFind(segment, "ma");

        double p = ExtraiNumero(segment, cursor);
        if(p > 0) lastMA = (int)p;
        r.p1 = lastMA;
        r.p2 = 0; // Preço cruza a média (p2=0) ou cruzamento de 2 médias (p2>0)
        r.active = true;
    }

    if(StringFind(segment, "rsi") >= 0) {
        r.type = 2; // RSI
        int cursor = StringFind(segment, "rsi");
        double p = ExtraiNumero(segment, cursor);
        if(p > 0) lastRSI = (int)p;
        r.p1 = lastRSI;
        r.d1 = ExtraiNumero(segment, cursor); // over/under
        if(r.d1 == 0) r.d1 = (intent == SIGNAL_BUY) ? 30 : 70;
        r.active = true;
    }

    if(StringFind(segment, "estocástico") >= 0 || StringFind(segment, "stoch") >= 0) {
        r.type = 3; r.p1 = 5; r.p2 = 3; r.p3 = 3; r.active = true;
    }

    if(StringFind(segment, "bollinger") >= 0 || StringFind(segment, "bands") >= 0) {
        r.type = 4; r.p1 = 20; r.d1 = 2.0; r.active = true;
    }

    if(StringFind(segment, "breakout") >= 0) {
        r.type = 5; r.active = true;
    }

    if(StringFind(segment, "delta") >= 0 || StringFind(segment, "agressão") >= 0) {
        r.type = 6; r.p1 = 60; r.p2 = 300; r.active = true;
    }

    if(StringFind(segment, "volume") >= 0 || StringFind(segment, "ciclo") >= 0) {
        r.type = 7; r.p1 = 12; r.active = true;
    }

    if(StringFind(segment, "ama") >= 0) {
        r.type = 8; r.p1 = 10; r.active = true;
    }

    if(StringFind(segment, "padrão") >= 0 || StringFind(segment, "barras") >= 0) {
        r.type = 9; r.active = true;
    }

    if(StringFind(segment, "força relativa") >= 0 || StringFind(segment, "bench") >= 0) {
        r.type = 10; r.p1 = 14; r.s1 = "US30"; r.active = true;
    }

    if(r.active) {
        r.tf = PeriodoTexto(segment);
        if(intent == SIGNAL_BUY && g_nBuyRules < 10) g_buyRules[g_nBuyRules++] = r;
        if(intent == SIGNAL_SELL && g_nSellRules < 10) g_sellRules[g_nSellRules++] = r;
    }
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();

    string cleanPrompt = prompt;
    StringReplace(cleanPrompt, "|", ".");
    StringReplace(cleanPrompt, "\n", ".");

    string segments[];
    StringSplit(cleanPrompt, '.', segments);

    ENUM_SIGNAL currentIntent = SIGNAL_NONE;

    for(int i=0; i<ArraySize(segments); i++) {
        string s = segments[i];
        StringTrimLeft(s); StringTrimRight(s);
        string lowerS = s; StringToLower(lowerS);

        if(StringFind(lowerS, "compra") >= 0) currentIntent = SIGNAL_BUY;
        if(StringFind(lowerS, "vende") >= 0) currentIntent = SIGNAL_SELL;

        // Global params
        int cursor = 0;
        if(StringFind(lowerS, "stop") >= 0) {
            cursor = StringFind(lowerS, "stop");
            p_slPoints = (int)ExtraiNumero(lowerS, cursor);
        }
        if(StringFind(lowerS, "take") >= 0) {
            cursor = StringFind(lowerS, "take");
            p_tpPoints = (int)ExtraiNumero(lowerS, cursor);
        }
        if(StringFind(lowerS, "risco") >= 0) {
            cursor = StringFind(lowerS, "risco");
            p_risk = ExtraiNumero(lowerS, cursor);
        }
        if(StringFind(lowerS, "máximo") >= 0) {
            cursor = StringFind(lowerS, "máximo");
            p_maxTrades = (int)ExtraiNumero(lowerS, cursor);
        }
        if(StringFind(lowerS, "notícia") >= 0) {
            cursor = StringFind(lowerS, "notícia");
            p_newsVeto = (int)ExtraiNumero(lowerS, cursor);
        }
        if(StringFind(lowerS, "após as") >= 0) {
            cursor = StringFind(lowerS, "após as");
            p_startHour = (int)ExtraiNumero(lowerS, cursor);
        }

        if(currentIntent != SIGNAL_NONE) {
            AddRule(s, currentIntent);
        }
    }
}

double GetBufferValue(int handle, int buffer, int shift) {
    double arr[];
    ArraySetAsSeries(arr, true);
    if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
    return 0;
}

ENUM_SIGNAL AvaliaRegra(Rule &r) {
    if(!r.active) return SIGNAL_NONE;

    // Allocate handles if needed
    if(r.handle1 == INVALID_HANDLE) {
        if(r.type == 1) r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
        if(r.type == 2) r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        if(r.type == 3) r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
        if(r.type == 4) r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
        if(r.type == 8) r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
        if(r.type == 10) {
            r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
            r.handle2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        }
    }

    double val1, val2, p_close, p_open, p_high, p_low;

    switch(r.type) {
        case 1: // MA Cross
            val1 = GetBufferValue(r.handle1, 0, 0);
            val2 = GetBufferValue(r.handle1, 0, 1);
            p_close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            double prev_close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            if(prev_close < val2 && p_close > val1) return SIGNAL_BUY;
            if(prev_close > val2 && p_close < val1) return SIGNAL_SELL;
            break;

        case 2: // RSI
            val1 = GetBufferValue(r.handle1, 0, 0);
            if(val1 < r.d1) return SIGNAL_BUY;
            if(val1 > r.d1) return SIGNAL_SELL;
            break;

        case 3: // Stochastic
            val1 = GetBufferValue(r.handle1, 0, 0); // Main
            val2 = GetBufferValue(r.handle1, 1, 0); // Signal
            if(val1 > val2) return SIGNAL_BUY;
            if(val1 < val2) return SIGNAL_SELL;
            break;

        case 4: // Bollinger Bands
            val1 = GetBufferValue(r.handle1, 1, 0); // Upper
            val2 = GetBufferValue(r.handle1, 2, 0); // Lower
            p_close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            if(p_close < val2) return SIGNAL_BUY;
            if(p_close > val1) return SIGNAL_SELL;
            break;

        case 5: // Daily Breakout
            p_high = iHigh(_Symbol, PERIOD_D1, 1);
            p_low = iLow(_Symbol, PERIOD_D1, 1);
            p_close = iClose(_Symbol, PERIOD_M1, 0);
            if(p_close > p_high) return SIGNAL_BUY;
            if(p_close < p_low) return SIGNAL_SELL;
            break;

        case 8: // AMA
            val1 = GetBufferValue(r.handle1, 0, 0);
            val2 = GetBufferValue(r.handle1, 0, 1);
            if(val1 > val2) return SIGNAL_BUY;
            if(val1 < val2) return SIGNAL_SELL;
            break;

        case 9: // 2-Bar Patterns
            p_high = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            p_low = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            p_close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            p_open = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            // Inside Bar
            if(p_high < h1 && p_low > l1) return (p_close > p_open) ? SIGNAL_BUY : SIGNAL_SELL;
            // Outside Bar
            if(p_high > h1 && p_low < l1) return (p_close > p_open) ? SIGNAL_SELL : SIGNAL_BUY;
            break;
    }

    return SIGNAL_NONE;
}

ENUM_SIGNAL AvaliaTudo() {
    int buyVotos = 0, sellVotos = 0;

    for(int i=0; i<g_nBuyRules; i++) {
        if(AvaliaRegra(g_buyRules[i]) == SIGNAL_BUY) buyVotos++;
    }
    for(int i=0; i<g_nSellRules; i++) {
        if(AvaliaRegra(g_sellRules[i]) == SIGNAL_SELL) sellVotos++;
    }

    if(g_nBuyRules > 0 && buyVotos == g_nBuyRules) return SIGNAL_BUY;
    if(g_nSellRules > 0 && sellVotos == g_nSellRules) return SIGNAL_SELL;

    return SIGNAL_NONE;
}

void GravaLog(string texto) {
    Print(texto);
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
        FileClose(handle);
    }
}

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riscoAbs = capital * riscoPercent / 100.0;

    if(p_martingale) {
        if(HistorySelect(0, TimeCurrent())) {
            int total = HistoryDealsTotal();
            for(int i = total - 1; i >= 0; i--) {
                ulong ticket = HistoryDealGetTicket(i);
                if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                    if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riscoAbs *= 2.0;
                    break;
                }
            }
        }
    }

    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double slPoints = (p_slPoints > 0) ? p_slPoints : 300;

    double lot = riscoAbs / (slPoints * _Point * (tickVal / tickSize));

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    return lot;
}

void EnviaOrdem(ENUM_SIGNAL s, double risk) {
    if(s == SIGNAL_NONE) return;
    if(PositionsTotal() >= p_maxTrades) return;

    double lot = CalculaLote(risk);
    double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = 0, tp = 0;

    if(s == SIGNAL_BUY) {
        sl = price - p_slPoints * _Point;
        tp = price + p_tpPoints * _Point;
        if(trade.Buy(lot, _Symbol, price, sl, tp)) {
            GravaLog("Compra enviada. Lote: " + DoubleToString(lot, 2));
        }
    } else {
        sl = price + p_slPoints * _Point;
        tp = price - p_tpPoints * _Point;
        if(trade.Sell(lot, _Symbol, price, sl, tp)) {
            GravaLog("Venda enviada. Lote: " + DoubleToString(lot, 2));
        }
    }
}

bool AguardaNoticias() {
    // Check news_veto.txt
    int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string val = FileReadString(h);
        FileClose(h);
        if(val == "1") return true;
    }
    return false;
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
            double sl = PositionGetDouble(POSITION_SL);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

            // Breakeven
            if(p_breakeven > 0) {
                if(type == POSITION_TYPE_BUY && currentPrice > openPrice + p_breakeven * _Point) {
                    if(sl < openPrice) {
                        trade.PositionModify(ticket, openPrice + p_breakevenPlus * _Point, PositionGetDouble(POSITION_TP));
                    }
                }
                if(type == POSITION_TYPE_SELL && currentPrice < openPrice - p_breakeven * _Point) {
                    if(sl > openPrice || sl == 0) {
                        trade.PositionModify(ticket, openPrice - p_breakevenPlus * _Point, PositionGetDouble(POSITION_TP));
                    }
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0) {
                if(type == POSITION_TYPE_BUY && currentPrice > openPrice + p_trailingStop * _Point) {
                    double newSL = currentPrice - p_trailingStop * _Point;
                    if(newSL > sl + p_trailingStep * _Point) {
                        trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                    }
                }
                if(type == POSITION_TYPE_SELL && currentPrice < openPrice - p_trailingStop * _Point) {
                    double newSL = currentPrice + p_trailingStop * _Point;
                    if(newSL < sl - p_trailingStep * _Point || sl == 0) {
                        trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                    }
                }
            }
        }
    }
}

int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);

    // Initial strategy
    InterpretaPrompt("Compra se média 20 no m15 cruzar acima. Vende se média 20 no m15 cruzar abaixo. Stop 300, Take 500, Risco 1.0.");

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
}

void OnTick() {
    // Check start hour
    MqlDateTime dt;
    TimeCurrent(dt);
    if(dt.hour < p_startHour) return;

    // New bar frequency check
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar == lastBar) return;
    lastBar = currentBar;

    if(AguardaNoticias()) return;

    ENUM_SIGNAL s = AvaliaTudo();
    if(s != SIGNAL_NONE) {
        EnviaOrdem(s, p_risk);
    }
}

void OnTimer() {
    GerenciaPosicoes();

    // Real-time updates via prompt.txt
    if(FileIsExist("prompt.txt", FILE_COMMON)) {
        int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
        if(h != INVALID_HANDLE) {
            string newPrompt = FileReadString(h);
            FileClose(h);
            FileDelete("prompt.txt", FILE_COMMON);

            GravaLog("Novo prompt detectado: " + newPrompt);
            InterpretaPrompt(newPrompt);
        }
    }
}
