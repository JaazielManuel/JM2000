//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor.mq5
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- CONSTANTS & ENUMS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};
#define EA_MAGIC 123456

// ---------- STRUCTURES ----------
struct Rule {
   bool     active;
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   Signal   intent;     // BUY, SELL or NONE (filter)
};

// ---------- GLOBAL PARAMETERS ----------
Rule     p_rules[30];
int      p_nRules = 0;
double   p_riskPercent = 1.0;
int      p_stopPoints = 0;
int      p_takePoints = 0;
int      p_maxTrades = 3;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStart = 0;
int      p_trailingStep = 10;
bool     p_useMartingale = false;
string   p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;
datetime p_lastBarTime = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// ---------- UTILITIES ----------

double ExtraiNumero(string txt, int &endPos) {
    string res = "";
    bool found = false;
    int start = endPos;
    for(int i = start; i < StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.') {
            res += CharToString((uchar)c);
            found = true;
        } else if(found) {
            endPos = i;
            return StringToDouble(res);
        }
    }
    endPos = StringLen(txt);
    return found ? StringToDouble(res) : 0;
}

double ExtraiNumero(string txt) {
    int dummy = 0;
    return ExtraiNumero(txt, dummy);
}

double ExtraiValorApos(string txt, string chave) {
    int pos = StringFind(txt, chave);
    if(pos < 0) return 0;
    pos += StringLen(chave);
    return ExtraiNumero(txt, pos);
}

string ExtractTime(string txt) {
    int pos = StringFind(txt, "h");
    if(pos < 0) return "00:00";

    int start = pos;
    while(start > 0 && StringGetCharacter(txt, start-1) >= '0' && StringGetCharacter(txt, start-1) <= '9') start--;

    string hh = StringSubstr(txt, start, pos - start);
    string mm = "00";

    if(pos + 1 < StringLen(txt) && StringGetCharacter(txt, pos+1) == ':') {
        int mPos = pos + 2;
        mm = StringSubstr(txt, mPos, 2);
    } else if(pos + 1 < StringLen(txt) && StringGetCharacter(txt, pos+1) >= '0' && StringGetCharacter(txt, pos+1) <= '9') {
        mm = StringSubstr(txt, pos+1, 2);
    }

    if(StringLen(hh) == 1) hh = "0" + hh;
    if(StringLen(mm) == 1) mm = "0" + mm;

    return hh + ":" + mm;
}

int PeriodoTexto(string txt) {
    if(StringFind(txt, "15 minutos") >= 0 || StringFind(txt, "m15") >= 0) return PERIOD_M15;
    if(StringFind(txt, "5 minutos") >= 0 || StringFind(txt, "m5") >= 0) return PERIOD_M5;
    if(StringFind(txt, "1 minuto") >= 0 || StringFind(txt, "m1") >= 0) return PERIOD_M1;
    if(StringFind(txt, "1 hora") >= 0 || StringFind(txt, "h1") >= 0) return PERIOD_H1;
    if(StringFind(txt, "diário") >= 0 || StringFind(txt, "d1") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

double GetBufferValue(int handle, int buffer, int shift) {
    double arr[];
    ArraySetAsSeries(arr, true);
    if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
    return 0;
}

// ---------- RESET STRATEGY ----------

void ResetStrategy() {
    for(int i = 0; i < p_nRules; i++) {
        if(p_rules[i].handle1 != INVALID_HANDLE && p_rules[i].handle1 != 0) IndicatorRelease(p_rules[i].handle1);
        if(p_rules[i].handle2 != INVALID_HANDLE && p_rules[i].handle2 != 0) IndicatorRelease(p_rules[i].handle2);
        p_rules[i].active = false;
    }
    p_nRules = 0;
    p_riskPercent = 1.0;
    p_stopPoints = 0;
    p_takePoints = 0;
    p_maxTrades = 3;
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStart = 0;
    p_useMartingale = false;
    p_startTime = "00:00";
}

// ---------- INDICATOR SIGNAL FUNCTIONS ----------

Signal CruzamentoMA(Rule &r, int shift) {
    double ma_curr = GetBufferValue(r.handle1, 0, shift);
    double ma_prev = GetBufferValue(r.handle1, 0, shift + 1);
    double price_curr = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
    double price_prev = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift + 1);

    if(r.handle2 != INVALID_HANDLE && r.handle2 != 0) {
        double ma2_curr = GetBufferValue(r.handle2, 0, shift);
        double ma2_prev = GetBufferValue(r.handle2, 0, shift + 1);
        if(ma_prev < ma2_prev && ma_curr > ma2_curr) return BUY;
        if(ma_prev > ma2_prev && ma_curr < ma2_curr) return SELL;
    } else {
        if(price_prev < ma_prev && price_curr > ma_curr) return BUY;
        if(price_prev > ma_prev && price_curr < ma_curr) return SELL;
    }
    return NONE;
}

Signal RSIThreshold(Rule &r, int shift) {
    double rsi = GetBufferValue(r.handle1, 0, shift);
    if(r.intent == BUY && rsi > r.d1) return BUY;
    if(r.intent == SELL && rsi < r.d1) return SELL;
    return NONE;
}

Signal StochCross(Rule &r, int shift) {
    double k_curr = GetBufferValue(r.handle1, 0, shift);
    double d_curr = GetBufferValue(r.handle1, 1, shift);
    double k_prev = GetBufferValue(r.handle1, 0, shift + 1);
    double d_prev = GetBufferValue(r.handle1, 1, shift + 1);
    if(k_prev < d_prev && k_curr > d_curr) return BUY;
    if(k_prev > d_prev && k_curr < d_curr) return SELL;
    return NONE;
}

Signal BBounce(Rule &r, int shift) {
    double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
    double upper = GetBufferValue(r.handle1, 1, shift);
    double lower = GetBufferValue(r.handle1, 2, shift);
    if(close < lower) return BUY;
    if(close > upper) return SELL;
    return NONE;
}

// ---------- NLP PARSER ----------

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string clean = prompt;
    StringToLower(clean);

    p_riskPercent = ExtraiValorApos(clean, "risco de");
    if(p_riskPercent == 0) p_riskPercent = 1.0;

    p_stopPoints = (int)ExtraiValorApos(clean, "stop de");
    p_takePoints = (int)ExtraiValorApos(clean, "take de");
    p_maxTrades = (int)ExtraiValorApos(clean, "máximo");
    if(p_maxTrades == 0) p_maxTrades = 3;

    p_startTime = ExtractTime(clean);
    p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(clean);

    if(StringFind(clean, "martingale") >= 0) p_useMartingale = true;

    int startPos = StringFind(clean, "atingir +");
    if(startPos >= 0) {
        p_beStart = (int)ExtraiNumero(clean, startPos);
        int plusPos = StringFind(clean, "entrada +", startPos);
        if(plusPos >= 0) p_bePlus = (int)ExtraiNumero(clean, plusPos);
    }

    p_trailingStart = (int)ExtraiValorApos(clean, "trailing stop de");

    string segments[];
    string delims = "|";
    string work = clean;
    StringReplace(work, " e ", "|");
    StringReplace(work, ".", "|");
    StringReplace(work, ",", "|");
    int nSeg = StringSplit(work, '|', segments);

    Signal currentIntent = NONE;

    for(int i = 0; i < nSeg; i++) {
        string s = segments[i];
        StringTrimLeft(s); StringTrimRight(s);
        if(StringLen(s) == 0) continue;

        if(StringFind(s, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

        if(p_nRules >= 30) break;
        Rule &r = p_rules[p_nRules];
        r.active = false;
        r.intent = currentIntent;
        r.tf = PeriodoTexto(s);
        if(r.tf == PERIOD_CURRENT) r.tf = (int)p_frequency;

        // MA
        if(StringFind(s, " média") >= 0 || StringFind(s, " ma ") >= 0) {
            r.type = 1;
            int pos = 0;
            r.p1 = (int)ExtraiNumero(s, pos);
            if(r.p1 == 0) r.p1 = 20;
            r.p2 = (int)ExtraiNumero(s, pos);
            r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
            if(r.p2 > 0) r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_SMA, PRICE_CLOSE);
            else r.handle2 = INVALID_HANDLE;
            r.active = true;
        }
        // RSI
        else if(StringFind(s, "rsi") >= 0) {
            r.type = 2;
            int pos = 0;
            int v1 = (int)ExtraiNumero(s, pos);
            int v2 = (int)ExtraiNumero(s, pos);
            if(v1 < 40) { r.p1 = v1; r.d1 = v2; }
            else { r.p1 = 14; r.d1 = v1; }
            r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
            r.active = true;
        }
        // Stochastic
        else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
            r.type = 3;
            r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            r.active = true;
        }
        // Bollinger
        else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
            r.type = 4;
            r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
            r.active = true;
        }
        // AI Signal
        else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
            r.type = 11;
            r.handle1 = iATR(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14);
            r.active = true;
        }

        if(r.active) p_nRules++;
    }
}

// ---------- DECISION & EXECUTION ----------

Signal AvaliaTudo() {
    int buyVoto = 0, sellVoto = 0;
    int buyRules = 0, sellRules = 0;

    for(int i = 0; i < p_nRules; i++) {
        Rule &r = p_rules[i];
        if(!r.active) continue;

        Signal s = NONE;
        if(r.type == 1) s = CruzamentoMA(r, 1);
        else if(r.type == 2) s = RSIThreshold(r, 1);
        else if(r.type == 3) s = StochCross(r, 1);
        else if(r.type == 4) s = BBounce(r, 1);
        else if(r.type == 11) s = AISignal(r, 1);

        if(r.intent == BUY || r.intent == NONE) {
            buyRules++;
            if(s == BUY) buyVoto++;
        }
        if(r.intent == SELL || r.intent == NONE) {
            sellRules++;
            if(s == SELL) sellVoto++;
        }
    }

    if(buyRules > 0 && buyVoto == buyRules) return BUY;
    if(sellRules > 0 && sellVoto == sellRules) return SELL;
    return NONE;
}

Signal AISignal(Rule &r, int shift) {
    double atr = GetBufferValue(r.handle1, 0, shift);
    double body = MathAbs(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) - iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift));
    if(body > atr * 1.5) {
        if(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift)) return BUY;
        else return SELL;
    }
    return NONE;
}

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = capital * riscoPercent / 100.0;

    if(p_stopPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = NormalizeDouble(lot / step, 0) * step;

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    return lot;
}

void EnviaOrdem(Signal s, string reason) {
    if(s == NONE) return;

    int total = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) total++;
    }
    if(total >= p_maxTrades) return;

    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = CalculaLote(p_riskPercent);

    // Margin check
    double margin;
    if(!OrderCalcMargin((s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lot, price, margin)) return;
    if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
        GravaLog("Insufficient margin for trade");
        return;
    }
    if(p_useMartingale) {
        // Martingale logic: check last deal
        HistorySelect(0, TimeCurrent());
        for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
                break;
            }
        }
    }

    double sl = 0, tp = 0;

    bool res = false;
    if(s == BUY) {
        if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price + p_takePoints * _Point;
        res = trade.Buy(lot, _Symbol, price, sl, tp, reason);
    } else {
        if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
        if(p_takePoints > 0) tp = price - p_takePoints * _Point;
        res = trade.Sell(lot, _Symbol, price, sl, tp, reason);
    }

    if(!res) {
        GravaLog("Order error: " + (string)trade.ResultRetcode() + " - " + trade.ResultComment());
    } else {
        SendNotification("MT-LiveExecutor executed " + (s == BUY ? "BUY" : "SELL") + " on " + _Symbol);
    }
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(!posInfo.SelectByIndex(i) || posInfo.Magic() != EA_MAGIC) continue;

        double curSL = posInfo.StopLoss();
        double openPrice = posInfo.PriceOpen();
        double curPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        // Break-even
        if(p_beStart > 0) {
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
                if(curPrice >= openPrice + p_beStart * _Point && (curSL < openPrice || curSL == 0)) {
                    trade.PositionModify(posInfo.Ticket(), openPrice + p_bePlus * _Point, posInfo.TakeProfit());
                }
            } else {
                if(curPrice <= openPrice - p_beStart * _Point && (curSL > openPrice || curSL == 0)) {
                    trade.PositionModify(posInfo.Ticket(), openPrice - p_bePlus * _Point, posInfo.TakeProfit());
                }
            }
        }

        // Trailing Stop
        if(p_trailingStart > 0) {
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
                if(curPrice >= openPrice + p_trailingStart * _Point) {
                    double newSL = curPrice - p_trailingStart * _Point;
                    if(newSL > curSL + p_trailingStep * _Point || curSL == 0) {
                        trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    }
                }
            } else {
                if(curPrice <= openPrice - p_trailingStart * _Point) {
                    double newSL = curPrice + p_trailingStart * _Point;
                    if(newSL < curSL - p_trailingStep * _Point || curSL == 0) {
                        trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    }
                }
            }
        }
    }
}

// ---------- AUXILIARY MECHANISMS ----------

bool AguardaNoticias() {
    int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(handle == INVALID_HANDLE) return false;

    string content = FileReadString(handle);
    FileClose(handle);

    if(content == "1") return true;

    datetime eventTime = StringToTime(content);
    if(eventTime > 0) {
        if(TimeCurrent() >= eventTime - 20 * 60 && TimeCurrent() <= eventTime + 20 * 60) return true;
    }

    return false;
}

void GravaLog(string texto) {
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
        FileClose(handle);
    }
}

void GravaCSV() {
    static datetime lastWrite = 0;
    if(TimeCurrent() < lastWrite + 5) return;
    lastWrite = TimeCurrent();

    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
                FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                          posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(),
                          posInfo.Profit(), posInfo.Comment());
            }
        }
        FileClose(handle);
    }
}

void CalculaEstatisticas() {
    HistorySelect(0, TimeCurrent());
    int wins = 0, losses = 0, total = 0;
    double grossProfit = 0, grossLoss = 0, netProfit = 0;

    for(int i = 0; i < HistoryDealsTotal(); i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit != 0) {
                total++;
                netProfit += profit;
                if(profit > 0) { wins++; grossProfit += profit; }
                else { losses++; grossLoss += MathAbs(profit); }
            }
        }
    }

    double winRate = (total > 0) ? (double)wins / total * 100.0 : 0;
    double pf = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;

    PrintFormat("Stats: Net=%.2f, WinRate=%.1f%%, PF=%.2f", netProfit, winRate, pf);
}

void AIOptimizer() {
    HistorySelect(0, TimeCurrent());
    int total = 0, wins = 0;
    double grossProfit = 0, grossLoss = 0;
    for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit == 0) continue;
            total++;
            if(profit > 0) { wins++; grossProfit += profit; }
            else { grossLoss += MathAbs(profit); }
            if(total >= 10) break;
        }
    }

    if(total >= 10) {
        double wr = (double)wins / total;
        double pf = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;

        if(wr < 0.40) p_riskPercent *= 0.9;
        else if(wr > 0.60 && pf > 1.5) p_riskPercent *= 1.1;

        if(p_riskPercent > 2.0) p_riskPercent = 2.0;
        if(p_riskPercent < 0.1) p_riskPercent = 0.1;
    }
}

// ---------- MQL5 HANDLERS ----------

int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    EventSetTimer(1);

    // Initial prompt read
    int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        string prompt = FileReadString(handle);
        FileClose(handle);
        InterpretaPrompt(prompt);
    }

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
}

void OnTick() {
    if(TimeCurrent() < StringToTime(TimeToString(TimeCurrent(), TIME_DATE) + " " + p_startTime)) return;
    if(AguardaNoticias()) return;

    datetime curBar = iTime(_Symbol, p_frequency, 0);
    if(curBar != p_lastBarTime) {
        p_lastBarTime = curBar;
        Signal s = AvaliaTudo();
        if(s != NONE) EnviaOrdem(s, "Prompt Entry");
    }

    GerenciaPosicoes();
    GravaCSV();
}

void OnTimer() {
    static datetime lastPromptCheck = 0;
    if(TimeCurrent() >= lastPromptCheck + 2) {
        lastPromptCheck = TimeCurrent();
        int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
        if(handle != INVALID_HANDLE) {
            string prompt = FileReadString(handle);
            FileClose(handle);
            static string lastPrompt = "";
            if(prompt != lastPrompt) {
                lastPrompt = prompt;
                InterpretaPrompt(prompt);
                GravaLog("Strategy updated via prompt.txt");
            }
        }
    }

    static datetime lastHour = 0;
    if(TimeCurrent() >= lastHour + 3600) {
        lastHour = TimeCurrent();
        CalculaEstatisticas();
        AIOptimizer();
    }
}
