//=========================  MT_LiveExecutor  =========================
// MetaTrader 5 Live Executor with Natural Language Processing
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- Constants & Defines ----------
#define EA_MAGIC 123456
#define MAX_RULES 20

// ---------- Enums ----------
enum Signal { BUY=1, SELL=-1, NONE=0 };

// ---------- Structs ----------
struct Rule {
    int      type;      // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
    int      intent;    // BUY or SELL
    int      tf;        // Timeframe
    int      p1, p2, p3;
    double   d1, d2;
    string   s1;
    int      handle1;
    int      handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        type = 0; intent = 0; tf = 0; p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
        handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
    }
};

// ---------- Globals ----------
Rule     rules[MAX_RULES];
int      nRules = 0;
string   p_strategy = "";
double   p_riskPercent = 1.0;
int      p_stopPoints = 0;
int      p_takePoints = 0;
int      p_maxTrades = 3;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
bool     p_useMartingale = false;
string   p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
datetime last_bar = 0;
datetime last_prompt_mod = 0;

CTrade         trade;
CPositionInfo  m_position;

// ---------- Utilities ----------

double ExtraiNumero(string text, int &pos) {
    string res = "";
    bool found = false;
    int len = StringLen(text);
    while(pos < len) {
        ushort c = StringGetCharacter(text, pos);
        if((c >= '0' && c <= '9') || c == '.') {
            res += ShortToString(c);
            found = true;
        } else if(found) break;
        pos++;
    }
    return StringToDouble(res);
}

double ExtraiValorApos(string text, string key) {
    int p = StringFind(text, key);
    if(p < 0) return -1;
    p += StringLen(key);
    return ExtraiNumero(text, p);
}

int PeriodoTexto(string text) {
    string work = text;
    StringToLower(work);
    if(StringFind(work, "m15") >= 0) return PERIOD_M15;
    if(StringFind(work, "m1") >= 0 && StringFind(work, "m15") < 0)  return PERIOD_M1;
    if(StringFind(work, "m5") >= 0 && StringFind(work, "m15") < 0)  return PERIOD_M5;
    if(StringFind(work, "m30") >= 0) return PERIOD_M30;
    if(StringFind(work, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(work, "h4") >= 0)  return PERIOD_H4;
    if(StringFind(work, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

void ResetStrategy() {
    for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
    nRules = 0;
}

// ---------- Forward Declarations ----------
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
void EnviaOrdem(int tipo, double price, double sl, double tp, string reason);
void GerenciaPosicoes();
void GravaCSV();
void GravaLog(string text);
bool IsTimeAllowed();
bool AguardaNoticias();
void AIOptimizer();
double CalculaLote(double risco);

// ---------- MQL5 Event Handlers ----------

int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);
    InterpretaPrompt(""); // Initial load
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    EventKillTimer();
    for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
}

void OnTimer() {
    // Check for prompt updates
    string path = "prompt.txt";
    datetime mod = (datetime)FileGetInteger(path, FILE_MODIFY_DATE, false);
    if(mod != last_prompt_mod) {
        last_prompt_mod = mod;
        InterpretaPrompt("");
    }

    // AI Optimizer hourly
    static datetime lastAI = 0;
    if(TimeCurrent() - lastAI >= 3600) {
        AIOptimizer();
        lastAI = TimeCurrent();
    }
}

void OnTick() {
    // 1. Persistence
    GravaCSV();

    // 2. Position Management
    GerenciaPosicoes();

    // 3. Signal evaluation on new bar
    datetime current_bar = iTime(_Symbol, p_frequency, 0);
    if(current_bar != last_bar) {
        if(IsTimeAllowed() && !AguardaNoticias()) {
            Signal s = AvaliaTudo();
            if(s != NONE) {
                double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
                double sl = 0, tp = 0;
                if(s == BUY) {
                    sl = (p_stopPoints > 0) ? price - p_stopPoints * _Point : 0;
                    tp = (p_takePoints > 0) ? price + p_takePoints * _Point : 0;
                } else {
                    sl = (p_stopPoints > 0) ? price + p_stopPoints * _Point : 0;
                    tp = (p_takePoints > 0) ? price - p_takePoints * _Point : 0;
                }
                EnviaOrdem(s, price, sl, tp, "Signal " + EnumToString(p_frequency));
            }
        }
        last_bar = current_bar;
    }
}

// ---------- NLP Parser ----------

void InterpretaPrompt(string prompt) {
    string p = prompt;
    if(p == "") {
        int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
        if(h != INVALID_HANDLE) {
            p = FileReadString(h);
            FileClose(h);
        }
    }
    if(p == "") return;

    ResetStrategy();
    string work = p;
    StringToLower(work);

    // Global parameters
    double v;
    v = ExtraiValorApos(work, "risco de"); if(v > 0) p_riskPercent = v;
    v = ExtraiValorApos(work, "stop de"); if(v > 0) p_stopPoints = (int)v;
    v = ExtraiValorApos(work, "take de"); if(v > 0) p_takePoints = (int)v;
    v = ExtraiValorApos(work, "máximo"); if(v > 0) p_maxTrades = (int)v;

    if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

    v = ExtraiValorApos(work, "atingir"); if(v > 0) p_beStart = (int)v;
    v = ExtraiValorApos(work, "entrada +"); if(v > 0) p_bePlus = (int)v;
    v = ExtraiValorApos(work, "trailing"); if(v > 0) p_trailingStop = (int)v;
    p_trailingStep = 10;

    int startPos = StringFind(work, "depois das");
    if(startPos >= 0) {
        startPos += 10;
        int h_val = (int)ExtraiNumero(work, startPos);
        int m_val = 0;
        if(StringGetCharacter(work, startPos) == ':') {
            startPos++;
            m_val = (int)ExtraiNumero(work, startPos);
        }
        p_startTime = StringFormat("%02d:%02d", h_val, m_val);
    }

    p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(work);
    if(p_frequency == PERIOD_CURRENT) p_frequency = PERIOD_M15;

    // Split segments
    StringReplace(work, " e ", "|");
    StringReplace(work, ".", "|");
    StringReplace(work, ",", "|");

    string segments[];
    ushort sep = StringGetCharacter("|", 0);
    int total = StringSplit(work, sep, segments);

    int currentIntent = NONE;
    for(int i=0; i<total; i++) {
        string s = segments[i];
        if(StringFind(s, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

        if(currentIntent == NONE) continue;
        if(nRules >= MAX_RULES) break;

        Rule r;
        r.Reset();
        r.intent = currentIntent;
        r.tf = PeriodoTexto(s);
        if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

        bool found = false;
        // Moving Average
        if(StringFind(s, "média") >= 0 || StringFind(s, " ma ") >= 0 || StringFind(s, " ma/") >= 0) {
            r.type = 1;
            int pos = 0;
            r.p1 = (int)ExtraiNumero(s, pos);
            if(r.p1 == 0) r.p1 = 20;
            r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
            found = true;
        }
        // RSI
        else if(StringFind(s, "rsi") >= 0) {
            r.type = 2;
            int pos = StringFind(s, "rsi") + 3;
            int v1 = (int)ExtraiNumero(s, pos);
            int v2 = (int)ExtraiNumero(s, pos);
            if(v2 == 0) {
                if(v1 >= 40) { r.p1 = 14; r.d1 = v1; }
                else { r.p1 = v1; r.d1 = (r.intent == BUY) ? 30 : 70; }
            } else {
                r.p1 = v1; r.d1 = v2;
            }
            r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
            found = true;
        }
        // Stochastic
        else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
            r.type = 3;
            r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            found = true;
        }
        // Bollinger Bands
        else if(StringFind(s, "bollinger") >= 0 || StringFind(s, " bb ") >= 0) {
            r.type = 4;
            r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
            found = true;
        }
        // Daily Break
        else if(StringFind(s, "rompimento") >= 0 && StringFind(s, "máxima") >= 0) {
            r.type = 5;
            found = true;
        }
        // Delta
        else if(StringFind(s, "delta") >= 0) {
            r.type = 6;
            int pos = StringFind(s, "delta") + 5;
            r.p1 = (int)ExtraiNumero(s, pos);
            r.p2 = (int)ExtraiNumero(s, pos);
            if(r.p1 == 0) r.p1 = 60;
            if(r.p2 == 0) r.p2 = 300;
            found = true;
        }
        // Vol
        else if(StringFind(s, "volume") >= 0) {
            r.type = 7;
            found = true;
        }
        // AMA
        else if(StringFind(s, "ama") >= 0) {
            r.type = 8;
            r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, 10, 2, 30, 0, PRICE_CLOSE);
            found = true;
        }
        // Bar2
        else if(StringFind(s, "padrão") >= 0 || StringFind(s, "barra") >= 0) {
            r.type = 9;
            found = true;
        }
        // RS
        else if(StringFind(s, "força") >= 0) {
            r.type = 10;
            r.s1 = "US30"; // Default benchmark
            r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
            r.handle2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
            found = true;
        }
        // AI
        else if(StringFind(s, "ia") >= 0 || StringFind(s, "previsão") >= 0) {
            r.type = 11;
            r.handle1 = iATR(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14);
            found = true;
        }

        if(found) {
            rules[nRules] = r;
            nRules++;
        }
    }
}

// ---------- Signal Evaluation ----------

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
        double c1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double c2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
        if(r.intent == BUY && c2 < ma2 && c1 > ma1) return BUY;
        if(r.intent == SELL && c2 > ma2 && c1 < ma1) return SELL;
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
        double close = iClose(_Symbol, PERIOD_M1, 1);
        if(r.intent == BUY && close > hi) return BUY;
        if(r.intent == SELL && close < lo) return SELL;
    }
    else if(r.type == 6) { // Delta
        MqlTick ticks[];
        int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buyVol = 0, sellVol = 0;
        for(int i=0; i<n; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buyVol += (long)ticks[i].volume;
            else if((ticks[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sellVol += (long)ticks[i].volume;
        }
        long delta = buyVol - sellVol;
        if(r.intent == BUY && delta > r.p2) return BUY;
        if(r.intent == SELL && delta < -r.p2) return SELL;
    }
    else if(r.type == 7) { // Vol
        long v1 = iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        long v2 = iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
        if(v1 > v2 * 1.5) return (r.intent == BUY) ? BUY : SELL;
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
        double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);

        bool inside = (h0 < h1 && l0 > l1);
        bool outside = (h0 > h1 && l0 < l1);

        if(inside) {
            if(r.intent == BUY && c0 > o0) return BUY;
            if(r.intent == SELL && c0 < o0) return SELL;
        } else if(outside) {
            if(r.intent == BUY && c0 < o0) return BUY; // Contrarian or specific logic
            if(r.intent == SELL && c0 > o0) return SELL;
        }
    }
    else if(r.type == 10) { // RS
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle2, 0, 1);
        if(r.intent == BUY && rsi1 > rsi2 + 5) return BUY;
        if(r.intent == SELL && rsi1 < rsi2 - 5) return SELL;
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
    int buyVotes = 0, buyTotal = 0;
    int sellVotes = 0, sellTotal = 0;

    for(int i=0; i<nRules; i++) {
        Signal s = AvaliaRegra(rules[i]);
        if(rules[i].intent == BUY) {
            buyTotal++;
            if(s == BUY) buyVotes++;
        } else if(rules[i].intent == SELL) {
            sellTotal++;
            if(s == SELL) sellVotes++;
        }
    }

    if(buyTotal > 0 && buyVotes == buyTotal) return BUY;
    if(sellTotal > 0 && sellVotes == sellTotal) return SELL;

    return NONE;
}
// ---------- Trade Execution ----------

double CalculaLote(double riscoPercent) {
    double risk = riscoPercent;
    if(p_useMartingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                if(profit < 0) risk *= 2.0;
                break;
            }
        }
    }

    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAbs = capital * (risk / 100.0);
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    int slPoints = p_stopPoints;
    if(slPoints <= 0) slPoints = 300; // Safety default

    double lot = riskAbs / (slPoints * (tickVal / (tickSize / _Point)));
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    return lot;
}

void EnviaOrdem(int tipo, double price, double sl, double tp, string reason) {
    int count = 0;
    for(int i=0; i<PositionsTotal(); i++) {
        if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC && m_position.Symbol() == _Symbol)
            count++;
    }
    if(count >= p_maxTrades) return;

    double volume = CalculaLote(p_riskPercent);

    // Margin check
    double margin;
    ENUM_ORDER_TYPE ordType = (tipo == BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if(!OrderCalcMargin(ordType, _Symbol, volume, price, margin)) {
        GravaLog("Failed to calculate margin");
        return;
    }
    if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
        GravaLog(StringFormat("Insufficient margin: need %.2f, have %.2f", margin, AccountInfoDouble(ACCOUNT_FREEMARGIN)));
        return;
    }

    bool res = false;
    for(int attempt=0; attempt<3; attempt++) {
        if(tipo == BUY) res = trade.Buy(volume, _Symbol, price, sl, tp, reason);
        else res = trade.Sell(volume, _Symbol, price, sl, tp, reason);

        if(res) {
            uint ret = trade.ResultRetcode();
            if(ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_PLACED) {
                GravaLog("Order sent: " + reason);
                SendNotification("Trade executed: " + reason);
                break;
            }
            if(ret == TRADE_RETCODE_REQUOTES || ret == TRADE_RETCODE_OFFQUOTES) {
                price = (tipo == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
                continue;
            }
        }
    }
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC && m_position.Symbol() == _Symbol) {
            double open = m_position.PriceOpen();
            double cur = m_position.PriceCurrent();
            double sl = m_position.StopLoss();
            double tp = m_position.TakeProfit();
            long type = m_position.PositionType();

            double profitPoints = (type == POSITION_TYPE_BUY) ? (cur - open)/_Point : (open - cur)/_Point;

            // Breakeven
            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (type == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
                if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                    trade.PositionModify(m_position.Ticket(), newSL, tp);
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (type == POSITION_TYPE_BUY) ? cur - p_trailingStop * _Point : cur + p_trailingStop * _Point;
                if(MathAbs(newSL - sl) > p_trailingStep * _Point) {
                    if((type == POSITION_TYPE_BUY && newSL > sl) || (type == POSITION_TYPE_SELL && (newSL < sl || sl == 0))) {
                        trade.PositionModify(m_position.Ticket(), newSL, tp);
                    }
                }
            }
        }
    }
}

bool IsTimeAllowed() {
    string curTime = TimeToString(TimeCurrent(), TIME_MINUTES);
    if(curTime < p_startTime) return false;
    return true;
}

bool AguardaNoticias() {
    if(FileIsExist("news_veto.txt")) {
        int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
        if(h != INVALID_HANDLE) {
            string content = FileReadString(h);
            FileClose(h);
            if(StringFind(content, "VETO") >= 0) return true;
        }
    }
    return false;
}

void GravaCSV() {
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i=0; i<PositionsTotal(); i++) {
            if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC) {
                FileWrite(h,
                    m_position.Ticket(),
                    m_position.Symbol(),
                    m_position.PositionType(),
                    m_position.Volume(),
                    m_position.PriceOpen(),
                    m_position.Time(),
                    m_position.StopLoss(),
                    m_position.TakeProfit(),
                    m_position.Profit(),
                    m_position.Comment()
                );
            }
        }
        FileClose(h);
    }
}

void GravaLog(string text) {
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWriteString(h, TimeToString(TimeCurrent()) + ": " + text + "\r\n");
        FileClose(h);
    }
    Print(text);
}

void AIOptimizer() {
    HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, count = 0;
    for(int i = total - 1; i >= 0 && count < 10; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit > 0) wins++;
            count++;
        }
    }
    if(count >= 5) {
        double winRate = (double)wins / count;
        if(winRate < 0.4) {
            p_riskPercent *= 0.9;
            GravaLog(StringFormat("AI Optimization: Low win rate (%.2f). Reducing risk to %.2f%%", winRate, p_riskPercent));
        }
    }
}
