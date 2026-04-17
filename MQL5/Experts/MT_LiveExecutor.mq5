//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - High-Performance Resident Strategy Executor
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\DealInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>

// --- Enums ---
enum ENUM_INTENT { INTENT_BUY, INTENT_SELL, INTENT_NONE };
enum Signal { BUY=1, SELL=-1, NONE=0 };

// --- Structs ---
struct Rule {
    bool         active;
    ENUM_TIMEFRAMES tf;
    int          p1, p2, p3;
    double       d1, d2;
    string       s1;
    int          p1_handle, p2_handle;
    ENUM_INTENT  intent;
    string       ruleName;
};

// --- Global Strategy Parameters ---
Rule        rules[30];
int         nRules = 0;
string      p_currentPrompt = "";
double      p_riskPercent = 1.0;
int         p_stopPoints = 0;
int         p_takePoints = 0;
int         p_maxTrades = 3;
int         p_beStart = 0;
int         p_bePlus = 0;
int         p_trailingStart = 0;
int         p_trailingStep = 10;
bool        p_useMartingale = false;
long        p_startTimeSeconds = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;
datetime    lastBarTime = 0;
uint        EA_MAGIC = 123456;

// --- Helper Classes ---
CTrade          trade;
CPositionInfo   m_position;
CSymbolInfo     m_symbol;
CAccountInfo    m_account;

// --- Forward Declarations ---
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
double CalculaLote(double risco);
void EnviaOrdem(Signal s, string reason);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
void CalculaEstatisticas();
void AIOptimizer();
void ResetStrategy();

// --- Event Handlers ---
int OnInit() {
    m_symbol.Name(_Symbol);
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);
    ResetStrategy();
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    EventKillTimer();
}

void OnTick() {
    // 1. Position management and state persistence (Priority)
    GerenciaPosicoes();

    static datetime lastCSV = 0;
    if(TimeCurrent() - lastCSV >= 5) {
        GravaCSV();
        lastCSV = TimeCurrent();
    }

    // 2. Frequency filter (Execution once per bar of specified frequency)
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar == lastBarTime) return;

    // 3. News and Time Entry filters
    if(AguardaNoticias()) return;

    MqlDateTime dt;
    TimeCurrent(dt);
    long nowSeconds = dt.hour * 3600 + dt.min * 60 + dt.sec;
    if(nowSeconds < p_startTimeSeconds) return;

    // 4. Signal Evaluation and Execution
    Signal s = AvaliaTudo();
    if(s != NONE) {
        EnviaOrdem(s, "Estrategia NLP");
        lastBarTime = currentBar;
    }
}

void OnTimer() {
    // Check for prompt updates
    static datetime lastPromptCheck = 0;
    if(TimeCurrent() - lastPromptCheck >= 1) {
        int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
        if(handle != INVALID_HANDLE) {
            string newPrompt = FileReadString(handle);
            FileClose(handle);
            if(newPrompt != p_currentPrompt && StringLen(newPrompt) > 0) {
                InterpretaPrompt(newPrompt);
            }
        }
        lastPromptCheck = TimeCurrent();
    }

    // Hourly optimization
    static datetime lastOpt = 0;
    if(TimeCurrent() - lastOpt >= 3600) {
        CalculaEstatisticas();
        AIOptimizer();
        lastOpt = TimeCurrent();
    }
}

// --- Implementation Placeholder ---
void ResetStrategy() {
    for(int i=0; i<30; i++) {
        if(rules[i].p1_handle != INVALID_HANDLE && rules[i].p1_handle != 0) IndicatorRelease(rules[i].p1_handle);
        if(rules[i].p2_handle != INVALID_HANDLE && rules[i].p2_handle != 0) IndicatorRelease(rules[i].p2_handle);
        rules[i].active = false;
        rules[i].p1_handle = INVALID_HANDLE;
        rules[i].p2_handle = INVALID_HANDLE;
    }
    nRules = 0;
    p_riskPercent = 1.0;
    p_stopPoints = 0;
    p_takePoints = 0;
    p_maxTrades = 3;
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStart = 0;
    p_trailingStep = 10;
    p_useMartingale = false;
    p_startTimeSeconds = 0;
    p_frequency = PERIOD_CURRENT;
    lastBarTime = 0;
}

// --- NLP Utilities ---
double ExtraiNumero(string txt, int startPos=0) {
    string res = "";
    bool found = false;
    for(int i=startPos; i<StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.') {
            res += CharToString((uchar)c);
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
    int pos = StringFind(txt, "h");
    if(pos < 0) return "";
    string h = "", m = "00";
    int i = pos - 1;
    while(i >= 0 && StringGetCharacter(txt, i) >= '0' && StringGetCharacter(txt, i) <= '9') {
        h = CharToString((uchar)StringGetCharacter(txt, i)) + h;
        i--;
    }
    if(StringGetCharacter(txt, pos+1) == ':' || (StringGetCharacter(txt, pos+1) >= '0' && StringGetCharacter(txt, pos+1) <= '9')) {
       int start = (StringGetCharacter(txt, pos+1) == ':') ? pos+2 : pos+1;
       m = "";
       for(int j=start; j<StringLen(txt); j++) {
           ushort c = StringGetCharacter(txt, j);
           if(c >= '0' && c <= '9') m += CharToString((uchar)c);
           else break;
       }
    }
    if(StringLen(h) == 0) return "";
    return h + ":" + m;
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
    string t = txt; StringToLower(t);
    if(StringFind(t, "30 minutos") >= 0 || StringFind(t, "m30") >= 0) return PERIOD_M30;
    if(StringFind(t, "15 minutos") >= 0 || StringFind(t, "m15") >= 0) return PERIOD_M15;
    if(StringFind(t, "5 minutos") >= 0  || StringFind(t, "m5") >= 0)  return PERIOD_M5;
    if(StringFind(t, "1 minuto") >= 0   || StringFind(t, "m1") >= 0)  return PERIOD_M1;
    if(StringFind(t, "1 hora") >= 0     || StringFind(t, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(t, "diário") >= 0     || StringFind(t, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    p_currentPrompt = prompt;
    string p = prompt; StringToLower(p);

    // Global parameters
    p_riskPercent = ExtraiValorApos(p, "risco de");
    if(p_riskPercent == 0) p_riskPercent = 1.0;

    p_stopPoints = (int)ExtraiValorApos(p, "stop de");
    p_takePoints = (int)ExtraiValorApos(p, "take de");
    p_maxTrades = (int)ExtraiValorApos(p, "máximo");
    if(p_maxTrades == 0) p_maxTrades = 3;

    p_beStart = (int)ExtraiValorApos(p, "atingir +");
    p_bePlus = (int)ExtraiValorApos(p, "entrada +");

    p_trailingStart = (int)ExtraiValorApos(p, "trailing de");
    if(StringFind(p, "martingale") >= 0) p_useMartingale = true;

    string startTime = ExtractTime(p);
    if(startTime != "") {
        p_startTimeSeconds = StringToTime(startTime) % 86400;
    }

    p_frequency = PeriodoTexto(p);

    // Split rules
    string segments[];
    string tempP = p;
    StringReplace(tempP, " e ", "|");
    StringReplace(tempP, ".", "|");
    StringReplace(tempP, ",", "|");
    int nS = StringSplit(tempP, '|', segments);

    ENUM_INTENT currentIntent = INTENT_NONE;
    for(int i=0; i<nS; i++) {
        string s = segments[i]; StringTrimLeft(s); StringTrimRight(s);
        if(StringLen(s) < 3) continue;

        if(StringFind(s, "compra") >= 0) currentIntent = INTENT_BUY;
        else if(StringFind(s, "vende") >= 0) currentIntent = INTENT_SELL;

        if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0 || StringFind(s, " ma/") >= 0) {
            rules[nRules].active = true;
            rules[nRules].ruleName = "MA";
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = PeriodoTexto(s);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

            rules[nRules].p1 = (int)ExtraiNumero(s);
            if(rules[nRules].p1 == 0) rules[nRules].p1 = 20;

            // Check for second MA
            int slashPos = StringFind(s, "/");
            if(slashPos >= 0) rules[nRules].p2 = (int)ExtraiNumero(s, slashPos+1);

            if(rules[nRules].p2 > 0)
                rules[nRules].p1_handle = iMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
            else
                rules[nRules].p1_handle = iMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);

            if(rules[nRules].p2 > 0)
                rules[nRules].p2_handle = iMA(_Symbol, rules[nRules].tf, rules[nRules].p2, 0, MODE_EMA, PRICE_CLOSE);

            nRules++;
        }

        if(StringFind(s, "rsi") >= 0) {
            rules[nRules].active = true;
            rules[nRules].ruleName = "RSI";
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = PeriodoTexto(s);
            if(rules[nRules].tf == PERIOD_CURRENT) rules[nRules].tf = p_frequency;

            rules[nRules].p1 = (int)ExtraiNumero(s);
            if(rules[nRules].p1 == 0) rules[nRules].p1 = 14;

            rules[nRules].d1 = ExtraiValorApos(s, "acima de");
            if(rules[nRules].d1 == 0) rules[nRules].d1 = ExtraiValorApos(s, "maior que");

            rules[nRules].d2 = ExtraiValorApos(s, "abaixo de");
            if(rules[nRules].d2 == 0) rules[nRules].d2 = ExtraiValorApos(s, "menor que");

            rules[nRules].p1_handle = iRSI(_Symbol, rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
            nRules++;
        }

        if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
            rules[nRules].active = true;
            rules[nRules].ruleName = "STOCH";
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = PeriodoTexto(s);
            rules[nRules].p1_handle = iStochastic(_Symbol, rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            nRules++;
        }

        if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
            rules[nRules].active = true;
            rules[nRules].ruleName = "BB";
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = PeriodoTexto(s);
            rules[nRules].p1_handle = iBands(_Symbol, rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
            nRules++;
        }

        if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
            rules[nRules].active = true;
            rules[nRules].ruleName = "AI";
            rules[nRules].intent = currentIntent;
            nRules++;
        }
    }
    GravaLog("Novo prompt interpretado: " + prompt);
}

// --- Signal Helper ---
double GetBufferValue(int handle, int buffer, int shift) {
    double arr[]; ArraySetAsSeries(arr, true);
    if(CopyBuffer(handle, buffer, shift, 1, arr) <= 0) return 0;
    return arr[0];
}

// --- Signal Functions ---
Signal CruzamentoMA(int p1_h, int p2_h, int shift) {
    if(p1_h == INVALID_HANDLE) return NONE;

    if(p2_h != INVALID_HANDLE) {
        double f1 = GetBufferValue(p1_h, 0, shift);
        double s1 = GetBufferValue(p2_h, 0, shift);
        double f2 = GetBufferValue(p1_h, 0, shift+1);
        double s2 = GetBufferValue(p2_h, 0, shift+1);
        if(f2 < s2 && f1 > s1) return BUY;
        if(f2 > s2 && f1 < s1) return SELL;
    } else {
        double f1 = GetBufferValue(p1_h, 0, shift);
        double f2 = GetBufferValue(p1_h, 0, shift+1);
        double c1 = iClose(_Symbol, PERIOD_CURRENT, shift);
        double c2 = iClose(_Symbol, PERIOD_CURRENT, shift+1);
        if(c2 < f2 && c1 > f1) return BUY;
        if(c2 > f2 && c1 < f1) return SELL;
    }
    return NONE;
}

Signal RSIThreshold(int handle, double over, double under, ENUM_INTENT intent, int shift) {
    if(handle == INVALID_HANDLE) return NONE;
    double r1 = GetBufferValue(handle, 0, shift);
    double r2 = GetBufferValue(handle, 0, shift+1);

    if(intent == INTENT_BUY) {
        if(r2 <= under && r1 > under) return BUY;
        if(over > 0 && r2 <= over && r1 > over) return BUY;
    } else if(intent == INTENT_SELL) {
        if(r2 >= over && r1 < over) return SELL;
        if(under > 0 && r2 >= under && r1 < under) return SELL;
    }
    return NONE;
}

Signal StochCross(int handle, int shift) {
    if(handle == INVALID_HANDLE) return NONE;
    double k1 = GetBufferValue(handle, 0, shift);
    double d1 = GetBufferValue(handle, 1, shift);
    double k2 = GetBufferValue(handle, 0, shift+1);
    double d2 = GetBufferValue(handle, 1, shift+1);
    if(k2 < d2 && k1 > d1) return BUY;
    if(k2 > d2 && k1 < d1) return SELL;
    return NONE;
}

Signal BBounce(int handle, int shift) {
    if(handle == INVALID_HANDLE) return NONE;
    double low = GetBufferValue(handle, 2, shift);
    double high = GetBufferValue(handle, 1, shift);
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    if(close < low) return BUY;
    if(close > high) return SELL;
    return NONE;
}

Signal RT_AI_PRED(int shift) {
    double atr = iATR(_Symbol, PERIOD_CURRENT, 14);
    double body = MathAbs(iClose(_Symbol, PERIOD_CURRENT, shift) - iOpen(_Symbol, PERIOD_CURRENT, shift));
    if(body > 1.5 * GetBufferValue((int)atr, 0, shift)) {
        return (iClose(_Symbol, PERIOD_CURRENT, shift) > iOpen(_Symbol, PERIOD_CURRENT, shift)) ? BUY : SELL;
    }
    return NONE;
}

// --- Decision Engine ---
Signal AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;
        Signal s = NONE;

        if(rules[i].ruleName == "MA") s = CruzamentoMA(rules[i].p1_handle, rules[i].p2_handle, 1);
        else if(rules[i].ruleName == "RSI") s = RSIThreshold(rules[i].p1_handle, rules[i].d1, rules[i].d2, rules[i].intent, 1);
        else if(rules[i].ruleName == "STOCH") s = StochCross(rules[i].p1_handle, 1);
        else if(rules[i].ruleName == "BB") s = BBounce(rules[i].p1_handle, 1);
        else if(rules[i].ruleName == "AI") s = RT_AI_PRED(1);

        if(rules[i].intent == INTENT_BUY || rules[i].intent == INTENT_NONE) {
            buyRules++;
            if(s == BUY) buyVotes++;
        }
        if(rules[i].intent == INTENT_SELL || rules[i].intent == INTENT_NONE) {
            sellRules++;
            if(s == SELL) sellVotes++;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) return BUY;
    if(sellRules > 0 && sellVotes == sellRules) return SELL;
    return NONE;
}

// --- Execution & Risk ---
double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double marginFree = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    double riskAmount = capital * (riscoPercent / 100.0);

    if(p_stopPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double pointsValue = tickValue / (tickSize / _Point);

    double lot = riskAmount / (p_stopPoints * pointsValue);

    // Normalize
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    // Margin check
    double marginRequired = 0;
    if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired)) return 0;
    if(marginRequired > marginFree) lot = marginFree / marginRequired * lot * 0.9;

    return NormalizeDouble(lot, 2);
}

void EnviaOrdem(Signal s, string reason) {
    if(s == NONE) return;

    int count = 0;
    for(int i=0; i<PositionsTotal(); i++) {
        if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC) count++;
    }
    if(count >= p_maxTrades) return;

    double lot = CalculaLote(p_riskPercent);
    if(p_useMartingale) {
       HistorySelect(0, TimeCurrent());
       int total = HistoryDealsTotal();
       if(total > 0) {
          CDealInfo deal;
          for(int i=total-1; i>=0; i--) {
             if(deal.SelectByIndex(i) && deal.Magic() == EA_MAGIC && deal.Symbol() == _Symbol) {
                if(deal.Profit() < 0) lot *= 2;
                break;
             }
          }
       }
    }

    double sl = 0, tp = 0;
    if(s == BUY) {
        double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price + p_takePoints * _Point;
        if(trade.Buy(lot, _Symbol, price, sl, tp, reason)) {
            GravaLog("COMPRA executada: " + DoubleToString(lot, 2) + " " + _Symbol + " Motivo: " + reason);
        }
    } else if(s == SELL) {
        double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price - p_takePoints * _Point;
        if(trade.Sell(lot, _Symbol, price, sl, tp, reason)) {
            GravaLog("VENDA executada: " + DoubleToString(lot, 2) + " " + _Symbol + " Motivo: " + reason);
        }
    }
}

// --- Position Management ---
void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC) {
            double currentPrice = (m_position.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double openPrice = m_position.PriceOpen();
            double currentSL = m_position.StopLoss();
            double profitPoints = (m_position.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;

            // Break-even
            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (m_position.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if((m_position.PositionType() == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
                   (m_position.PositionType() == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
                    trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
                }
            }

            // Trailing Stop
            if(p_trailingStart > 0 && profitPoints >= p_trailingStart) {
                double newSL = (m_position.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
                if((m_position.PositionType() == POSITION_TYPE_BUY && newSL > currentSL + p_trailingStep * _Point) ||
                   (m_position.PositionType() == POSITION_TYPE_SELL && (newSL < currentSL - p_trailingStep * _Point || currentSL == 0))) {
                    trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
                }
            }
        }
    }
}

// --- Safety & Filters ---
bool AguardaNoticias() {
    int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        string val = FileReadString(handle);
        FileClose(handle);
        if(val == "1") return true;
        datetime newsTime = (datetime)StringToTime(val);
        if(newsTime > 0 && MathAbs(TimeCurrent() - newsTime) < 1200) return true; // 20 min window
    }
    return false;
}

// --- Logging & State ---
void GravaLog(string texto) {
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
        FileClose(handle);
    }
    Print(texto);
}

void GravaCSV() {
    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i=0; i<PositionsTotal(); i++) {
            if(m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC) {
                FileWrite(handle, m_position.Ticket(), m_position.Symbol(), m_position.PositionType(), m_position.Volume(),
                          m_position.PriceOpen(), m_position.Time(), m_position.StopLoss(), m_position.TakeProfit(),
                          m_position.Profit(), m_position.Comment());
            }
        }
        FileClose(handle);
    }
}

// --- Stats & Optimization ---
double g_winRate = 0, g_profitFactor = 0, g_drawdown = 0;

void CalculaEstatisticas() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    double profit = 0, loss = 0;
    int wins = 0, losses = 0;

    for(int i=0; i<total; i++) {
        CDealInfo deal;
        if(deal.SelectByIndex(i) && deal.Magic() == EA_MAGIC) {
            double p = deal.Profit();
            if(p > 0) { profit += p; wins++; }
            if(p < 0) { loss += MathAbs(p); losses++; }
        }
    }

    if(wins + losses > 0) g_winRate = (double)wins / (wins + losses);
    if(loss > 0) g_profitFactor = profit / loss;
    GravaLog("Stats: WinRate=" + DoubleToString(g_winRate, 2) + " PF=" + DoubleToString(g_profitFactor, 2));
}

void AIOptimizer() {
    if(g_winRate < 0.4 && g_winRate > 0) {
        p_riskPercent *= 0.8;
        GravaLog("AI: Reduzindo risco devido a baixa performance.");
    } else if(g_winRate > 0.6 && g_profitFactor > 1.5) {
        p_riskPercent = MathMin(p_riskPercent * 1.2, 2.0);
        GravaLog("AI: Aumentando risco devido a alta performance.");
    }
}

// --- Additional Signal Functions from Knowledge Core ---

Signal DailyBreak(int shift) {
    static datetime today = 0;
    static double hi = 0, lo = 0;
    datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
    if(currentDay != today) {
        today = currentDay;
        hi = iHigh(_Symbol, PERIOD_D1, 1);
        lo = iLow(_Symbol, PERIOD_D1, 1);
    }
    double close = iClose(_Symbol, PERIOD_CURRENT, shift);
    if(close > hi + _Point) return BUY;
    if(close < lo - _Point) return SELL;
    return NONE;
}

Signal DeltaAggression(int seconds, int deltaTrigger) {
    MqlTick arr[];
    int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - seconds, TimeCurrent());
    long buy = 0, sell = 0;
    for(int i = 0; i < n; i++) {
        if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
        else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
    }
    long delta = buy - sell;
    if(delta > deltaTrigger) return BUY;
    if(delta < -deltaTrigger) return SELL;
    return NONE;
}

Signal VolumeCycle(int len, ENUM_TIMEFRAMES tf, int shift) {
    long vol[]; ArraySetAsSeries(vol, true);
    if(CopyVolume(_Symbol, tf, shift, len, vol) < len) return NONE;
    int maxIdx = ArrayMaximum(vol);
    int minIdx = ArrayMinimum(vol);
    if(maxIdx == 0) return SELL;
    if(minIdx == 0) return BUY;
    return NONE;
}

Signal Bar2Pattern(ENUM_TIMEFRAMES tf, int shift) {
    double h0 = iHigh(_Symbol, tf, shift);
    double l0 = iLow(_Symbol, tf, shift);
    double h1 = iHigh(_Symbol, tf, shift + 1);
    double l1 = iLow(_Symbol, tf, shift + 1);
    double c0 = iClose(_Symbol, tf, shift);
    double o0 = iOpen(_Symbol, tf, shift);
    if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
    if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;
    return NONE;
}
