//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Integrated Trading System
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. BIBLIOTECA COMPLETA DE ENTRADAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};
enum Intent {INT_BUY, INT_SELL, INT_NONE};

// Rule structure based on memories
struct Rule {
   bool     active;
   int      type; // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   Intent   intent;
};

// Position state for persistence
struct PositionState {
   long     ticket;
   string   symbol;
   int      type;
   double   volume;
   double   priceOpen;
   datetime time;
   double   sl;
   double   tp;
   double   profit;
   string   reason;
};

// Global parameters
Rule rules[30];
int nRules = 0;
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStart = 0;
int p_trailingStep = 10;
bool p_useMartingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
datetime lastBarTime = 0;
int EA_MAGIC = 123456;
string p_startTime = "00:00";

// Statistics and News variables
double p_winRate = 0;
double p_profitFactor = 0;
double p_drawdown = 0;
datetime p_nextNewsTime = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// Utility to release all handles
void ResetStrategy() {
    for(int i=0; i<30; i++) {
        if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) {
            IndicatorRelease(rules[i].handle1);
        }
        if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) {
            IndicatorRelease(rules[i].handle2);
        }
        rules[i].active = false;
        rules[i].handle1 = INVALID_HANDLE;
        rules[i].handle2 = INVALID_HANDLE;
    }
    nRules = 0;
    // Revert to defaults
    p_riskPercent = 1.0;
    p_stopPoints = 300;
    p_takePoints = 500;
    p_maxTrades = 3;
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStart = 0;
    p_trailingStep = 10;
    p_useMartingale = false;
}

// 1.1 MÉDIAS & CRUZAMENTOS
Signal CruzamentoMA(int handle1, int handle2, int shift=1)
{
   if(handle1 == INVALID_HANDLE) return NONE;

   double ma1[], ma2[];
   ArraySetAsSeries(ma1, true);
   ArraySetAsSeries(ma2, true);

   if(CopyBuffer(handle1, 0, shift, 2, ma1) <= 0) return NONE;

   if(handle2 != INVALID_HANDLE) {
      if(CopyBuffer(handle2, 0, shift, 2, ma2) <= 0) return NONE;
      if(ma1[1] < ma2[1] && ma1[0] > ma2[0]) return BUY;
      if(ma1[1] > ma2[1] && ma1[0] < ma2[0]) return SELL;
   } else {
      // Price vs MA
      double close[];
      ArraySetAsSeries(close, true);
      if(CopyClose(_Symbol, _Period, shift, 2, close) <= 0) return NONE;
      if(close[1] < ma1[1] && close[0] > ma1[0]) return BUY;
      if(close[1] > ma1[1] && close[0] < ma1[0]) return SELL;
   }
   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(int handle, double over, double under, Intent intent, int shift=1)
{
   if(handle == INVALID_HANDLE) return NONE;
   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(handle, 0, shift, 1, rsi) <= 0) return NONE;

   if(intent == INT_BUY && rsi[0] > under) return BUY;
   if(intent == INT_SELL && rsi[0] < over) return SELL;

   // Default threshold behavior
   if(rsi[0] > over) return SELL;
   if(rsi[0] < under) return BUY;
   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(int handle, int shift=1)
{
   if(handle == INVALID_HANDLE) return NONE;
   double k[], d[];
   ArraySetAsSeries(k, true);
   ArraySetAsSeries(d, true);
   if(CopyBuffer(handle, 0, shift, 2, k) <= 0) return NONE;
   if(CopyBuffer(handle, 1, shift, 2, d) <= 0) return NONE;

   if(k[1] < d[1] && k[0] > d[0]) return BUY;
   if(k[1] > d[1] && k[0] < d[0]) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BOUNCE
Signal BBounce(int handle, int shift=1)
{
   if(handle == INVALID_HANDLE) return NONE;
   double upper[], lower[], close[];
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   ArraySetAsSeries(close, true);

   if(CopyBuffer(handle, 1, shift, 1, upper) <= 0) return NONE;
   if(CopyBuffer(handle, 2, shift, 1, lower) <= 0) return NONE;
   if(CopyClose(_Symbol, _Period, shift, 1, close) <= 0) return NONE;

   if(close[0] < lower[0]) return BUY;
   if(close[0] > upper[0]) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(int shift=1)
{
   double hi = iHigh(NULL, PERIOD_D1, 1);
   double lo = iLow(NULL, PERIOD_D1, 1);
   double close = iClose(NULL, _Period, shift);
   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Kaufman)
Signal AMASignal(int handle, int shift=1)
{
   if(handle == INVALID_HANDLE) return NONE;
   double ama[];
   ArraySetAsSeries(ama, true);
   if(CopyBuffer(handle, 0, shift, 2, ama) <= 0) return NONE;
   if(ama[1] < ama[0]) return BUY;
   if(ama[1] > ama[0]) return SELL;
   return NONE;
}

// 1.11 AI PREDICTION (Memory based)
Signal AIPrediction(int shift=1) {
    double atr[];
    int atrHandle = iATR(_Symbol, _Period, 14);
    ArraySetAsSeries(atr, true);
    CopyBuffer(atrHandle, 0, shift, 1, atr);
    IndicatorRelease(atrHandle);

    double body = MathAbs(iClose(_Symbol, _Period, shift) - iOpen(_Symbol, _Period, shift));
    if(body > atr[0] * 1.5) {
        return (iClose(_Symbol, _Period, shift) > iOpen(_Symbol, _Period, shift)) ? BUY : SELL;
    }
    return NONE;
}

// 1.10 FORÇA RELATIVA ENTRE ATIVOS
Signal RSRelative(int handle1, int handle2, int shift=1)
{
   if(handle1 == INVALID_HANDLE || handle2 == INVALID_HANDLE) return NONE;
   double r1[], r2[];
   ArraySetAsSeries(r1, true); ArraySetAsSeries(r2, true);
   if(CopyBuffer(handle1, 0, shift, 1, r1) <= 0) return NONE;
   if(CopyBuffer(handle2, 0, shift, 1, r2) <= 0) return NONE;
   if(r1[0] > r2[0] + 5) return BUY;
   if(r1[0] < r2[0] - 5) return SELL;
   return NONE;
}

// --- Utilities ---

double ExtraiNumero(string texto, int startPos=0) {
    string res = "";
    bool found = false;
    for(int i=startPos; i<StringLen(texto); i++) {
        ushort c = StringGetCharacter(texto, i);
        if((c >= '0' && c <= '9') || c == '.') {
            res += CharToString((uchar)c);
            found = true;
        } else if(found) break;
    }
    return StringToDouble(res);
}

double ExtraiValorApos(string texto, string keyword) {
    int pos = StringFind(texto, keyword);
    if(pos < 0) return 0;
    return ExtraiNumero(texto, pos + StringLen(keyword));
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    nome = StringSubstr(nome, 0, 10);
    StringToLower(nome);
    if(StringFind(nome, "1 minuto") >= 0 || StringFind(nome, "m1") >= 0) return PERIOD_M1;
    if(StringFind(nome, "5 minutos") >= 0 || StringFind(nome, "m5") >= 0) return PERIOD_M5;
    if(StringFind(nome, "15 minutos") >= 0 || StringFind(nome, "m15") >= 0 || StringFind(nome, "15 min") >= 0) return PERIOD_M15;
    if(StringFind(nome, "30 minutos") >= 0 || StringFind(nome, "m30") >= 0) return PERIOD_M30;
    if(StringFind(nome, "1 hora") >= 0 || StringFind(nome, "h1") >= 0) return PERIOD_H1;
    if(StringFind(nome, "4 horas") >= 0 || StringFind(nome, "h4") >= 0) return PERIOD_H4;
    if(StringFind(nome, "diario") >= 0 || StringFind(nome, "d1") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

string ExtractTime(string text) {
    int pos = StringFind(text, "h");
    if(pos < 0) return "00:00";
    string h = "";
    for(int i=pos-1; i>=0; i--) {
        ushort c = StringGetCharacter(text, i);
        if(c >= '0' && c <= '9') h = CharToString((uchar)c) + h;
        else break;
    }
    string m = "00";
    if(pos + 1 < StringLen(text)) {
        ushort c1 = StringGetCharacter(text, pos+1);
        if(c1 >= '0' && c1 <= '9') {
            m = CharToString((uchar)c1);
            if(pos + 2 < StringLen(text)) {
                ushort c2 = StringGetCharacter(text, pos+2);
                if(c2 >= '0' && c2 <= '9') m += CharToString((uchar)c2);
            }
        }
    }
    if(StringLen(h) == 1) h = "0" + h;
    if(StringLen(m) == 1) m = "0" + m;
    return h + ":" + m;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    StringToLower(prompt);

    // Global parameters
    p_riskPercent = ExtraiValorApos(prompt, "risco de");
    if(p_riskPercent == 0) p_riskPercent = 1.0;

    p_stopPoints = (int)ExtraiValorApos(prompt, "stop de");
    if(p_stopPoints == 0) p_stopPoints = 300;

    p_takePoints = (int)ExtraiValorApos(prompt, "take de");
    if(p_takePoints == 0) p_takePoints = 500;

    p_maxTrades = (int)ExtraiValorApos(prompt, "máximo");
    if(p_maxTrades == 0) p_maxTrades = 3;

    if(StringFind(prompt, "martingale") >= 0) p_useMartingale = true;

    p_frequency = PeriodoTexto(prompt);

    // Position management
    p_beStart = (int)ExtraiValorApos(prompt, "atingir +");
    p_bePlus = (int)ExtraiValorApos(prompt, "entrada +");

    p_trailingStart = (int)ExtraiValorApos(prompt, "trailing"); // Simple extraction
    if(p_trailingStart == 0) p_trailingStart = (int)ExtraiValorApos(prompt, "atingir +"); // Compatibility

    p_startTime = ExtractTime(prompt);

    // Rules
    string segments[];
    string tempPrompt = prompt;
    StringReplace(tempPrompt, " e ", "|");
    StringReplace(tempPrompt, ".", "|");
    StringReplace(tempPrompt, ",", "|");
    ushort sep = StringGetCharacter("|", 0);
    StringSplit(tempPrompt, sep, segments);

    Intent currentIntent = INT_NONE;

    for(int i=0; i<ArraySize(segments); i++) {
        string s = segments[i];
        if(StringFind(s, "compra") >= 0) currentIntent = INT_BUY;
        else if(StringFind(s, "vende") >= 0) currentIntent = INT_SELL;

        if(nRules >= 30) break;

        // 1. Moving Average
        if(StringFind(s, " média ") >= 0 || StringFind(s, " ma ") >= 0 || StringFind(s, " ma/") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = 1;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = (int)p_frequency;

            int p1 = (int)ExtraiNumero(s);
            int p2 = 0;
            int slashPos = StringFind(s, "/");
            if(slashPos >= 0) p2 = (int)ExtraiNumero(s, slashPos + 1);

            if(p1 == 0) p1 = 20;
            rules[nRules].p1 = p1;
            rules[nRules].p2 = p2;

            rules[nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, p1, 0, MODE_SMA, PRICE_CLOSE);
            if(p2 > 0) rules[nRules].handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, p2, 0, MODE_SMA, PRICE_CLOSE);
            else rules[nRules].handle2 = INVALID_HANDLE;

            nRules++;
        }
        // 2. RSI
        else if(StringFind(s, "rsi") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = 2;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = (int)p_frequency;

            int p1 = (int)ExtraiNumero(s);
            if(p1 == 0 || p1 > 50) p1 = 14; // Simple heuristic for period
            rules[nRules].p1 = p1;

            double d1 = ExtraiValorApos(s, "acima de");
            if(d1 == 0) d1 = ExtraiValorApos(s, "sobre");
            if(d1 == 0) d1 = 70;

            double d2 = ExtraiValorApos(s, "abaixo de");
            if(d2 == 0) d2 = ExtraiValorApos(s, "under");
            if(d2 == 0) d2 = 30;

            rules[nRules].d1 = d1;
            rules[nRules].d2 = d2;
            rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, p1, PRICE_CLOSE);
            nRules++;
        }
        // 3. Stochastic
        else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = 3;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = (int)p_frequency;
            rules[nRules].handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            nRules++;
        }
        // 4. Bollinger Bands
        else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = 4;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = (int)p_frequency;
            rules[nRules].handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
            nRules++;
        }
        // 5. Daily Break
        else if(StringFind(s, "rompimento diário") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = 5;
            rules[nRules].intent = currentIntent;
            nRules++;
        }
        // 8. AMA
        else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = 8;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = (int)p_frequency;
            rules[nRules].handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 10, 2, 30, 0, PRICE_CLOSE);
            nRules++;
        }
        // 11. AI
        else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = 11;
            rules[nRules].intent = currentIntent;
            nRules++;
        }
        // 10. RS Relative
        else if(StringFind(s, "força relativa") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = 10;
            rules[nRules].intent = currentIntent;
            rules[nRules].tf = (int)p_frequency;
            rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 14, PRICE_CLOSE);
            rules[nRules].handle2 = iRSI("US30", (ENUM_TIMEFRAMES)rules[nRules].tf, 14, PRICE_CLOSE);
            nRules++;
        }
    }

    GravaLog("Estratégia atualizada: " + prompt);
}
Signal AvaliaTudo() {
    int buyLeg = 0;
    int sellLeg = 0;
    int buyActive = 0;
    int sellActive = 0;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;

        Signal s = NONE;
        switch(rules[i].type) {
            case 1: s = CruzamentoMA(rules[i].handle1, rules[i].handle2); break;
            case 2: s = RSIThreshold(rules[i].handle1, rules[i].d1, rules[i].d2, rules[i].intent); break;
            case 3: s = StochCross(rules[i].handle1); break;
            case 4: s = BBounce(rules[i].handle1); break;
            case 5: s = DailyBreak(); break;
            case 8: s = AMASignal(rules[i].handle1); break;
            case 10: s = RSRelative(rules[i].handle1, rules[i].handle2); break;
            case 11: s = AIPrediction(); break;
        }

        if(rules[i].intent == INT_BUY) {
            buyActive++;
            if(s == BUY) buyLeg++;
        } else if(rules[i].intent == INT_SELL) {
            sellActive++;
            if(s == SELL) sellLeg++;
        } else {
            // Neutral intent rules must agree with both
            buyActive++;
            sellActive++;
            if(s == BUY) buyLeg++;
            if(s == SELL) sellLeg++;
        }
    }

    if(buyActive > 0 && buyLeg == buyActive) return BUY;
    if(sellActive > 0 && sellLeg == sellActive) return SELL;

    return NONE;
}
double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = capital * riscoPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(p_stopPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = NormalizeDouble(lot / step, 0) * step;

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    return lot;
}

void EnviaOrdem(Signal s, double risco, string reason) {
    if(s == NONE) return;

    int total = 0;
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol)
            total++;
    }
    if(total >= p_maxTrades) return;

    if(AguardaNoticias()) return;

    // Time check
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    string currentTime = StringFormat("%02d:%02d", dt.hour, dt.min);
    if(currentTime < p_startTime) return;

    double lote = CalculaLote(risco);

    // Margin check
    double margin;
    ENUM_ORDER_TYPE orderType = (s == BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
    if(!OrderCalcMargin(orderType, _Symbol, lote, SymbolInfoDouble(_Symbol, (s == BUY) ? SYMBOL_ASK : SYMBOL_BID), margin)) {
        GravaLog("Erro CalcMargin");
        return;
    }
    if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
        GravaLog("Margem insuficiente");
        return;
    }

    // Martingale logic
    if(p_useMartingale) {
        HistorySelect(TimeCurrent()-86400, TimeCurrent());
        for(int i=HistoryDealsTotal()-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                if(profit < 0) lote *= 2.0;
                break;
            }
        }
    }

    double sl = 0, tp = 0;
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

    if(s == BUY) {
        if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price + p_takePoints * _Point;
        if(!trade.Buy(lote, _Symbol, price, sl, tp, reason)) {
            GravaLog("Erro Compra: " + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultComment());
        } else {
            SendNotification("Compra executada: " + reason);
        }
    } else {
        if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price - p_takePoints * _Point;
        if(!trade.Sell(lote, _Symbol, price, sl, tp, reason)) {
            GravaLog("Erro Venda: " + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultComment());
        } else {
            SendNotification("Venda executada: " + reason);
        }
    }
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
            double openPrice = posInfo.PriceOpen();
            double currentSL = posInfo.StopLoss();
            double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;

            // Break-even
            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }

            // Trailing Stop
            if(p_trailingStart > 0 && profitPoints >= p_trailingStart) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > currentSL + p_trailingStep * _Point) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < currentSL - p_trailingStep * _Point || currentSL == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }
        }
    }
}

bool AguardaNoticias() {
    int file = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(file == INVALID_HANDLE) return false;

    string content = FileReadString(file);
    FileClose(file);

    if(content == "1") return true;

    datetime newsTime = StringToTime(content);
    if(newsTime > 0) {
        if(TimeCurrent() >= newsTime - 1200 && TimeCurrent() <= newsTime + 1200) return true;
    }

    return false;
}
void GravaLog(string texto) {
    int file = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
    if(file != INVALID_HANDLE) {
        FileSeek(file, 0, SEEK_END);
        FileWrite(file, TimeToString(TimeCurrent()) + ": " + texto);
        FileClose(file);
    }
}

void GravaCSV() {
    static datetime lastWrite = 0;
    if(TimeCurrent() - lastWrite < 5) return;
    lastWrite = TimeCurrent();

    int file = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
    if(file != INVALID_HANDLE) {
        FileWrite(file, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i=0; i<PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
                FileWrite(file, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                          posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(),
                          posInfo.Profit(), posInfo.Comment());
            }
        }
        FileClose(file);
    }
}

void CalculaEstatisticas() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, losses = 0;
    double grossProfit = 0, grossLoss = 0;

    for(int i=0; i<total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit > 0) { wins++; grossProfit += profit; }
            else if(profit < 0) { losses++; grossLoss -= profit; }
        }
    }

    if(wins + losses > 0) p_winRate = (double)wins / (wins + losses);
    if(grossLoss > 0) p_profitFactor = grossProfit / grossLoss;
    else p_profitFactor = grossProfit;
}

int OnInit() {
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);
   ResetStrategy();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void OnTick() {
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      lastBarTime = currentBar;
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s, p_riskPercent, "Signal " + EnumToString(s));
   }

   GerenciaPosicoes();
   GravaCSV();
}

void OnTimer() {
    // Check for new prompt
    int file = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(file != INVALID_HANDLE) {
        string prompt = FileReadString(file);
        FileClose(file);

        static string lastPrompt = "";
        if(prompt != "" && prompt != lastPrompt) {
            InterpretaPrompt(prompt);
            lastPrompt = prompt;
        }
    }

    // Periodic stats update
    static datetime lastStats = 0;
    if(TimeCurrent() - lastStats > 3600) {
        CalculaEstatisticas();
        lastStats = TimeCurrent();

        // AIOptimizer heuristic
        if(p_winRate < 0.4 && p_riskPercent > 0.5) p_riskPercent -= 0.1;
        if(p_winRate > 0.6 && p_profitFactor > 1.5 && p_riskPercent < 2.0) p_riskPercent += 0.1;
    }
}
