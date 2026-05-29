//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Sistema de Execução Direta via NLP
//========================================================================

#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Defines
#define EA_MAGIC 123456

// --- Enums
enum Signal {BUY=1, SELL=-1, NONE=0};

// --- Structs
struct Rule {
    int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS
    Signal   intent;     // BUY or SELL
    int      tf;
    int      p1, p2, p3;
    double   d1, d2;
    string   s1;
    int      handle1;
    int      handle2;
    bool     active;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        type = 0;
        intent = NONE;
        tf = PERIOD_CURRENT;
        p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0;
        s1 = "";
        handle1 = INVALID_HANDLE;
        handle2 = INVALID_HANDLE;
        active = false;
    }
};

// --- Globals
Rule rules[20];
int nRules = 0;
CTrade trade;
CPositionInfo pos;
CSymbolInfo sym;

string p_prompt = "";
string p_startTime = "00:00";
int p_maxTrades = 3;
double p_riskPercent = 1.0;
int p_stopLoss = 300;
int p_takeProfit = 500;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 10;
int p_newsVetoBuffer = 20;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime lastBar = 0;
datetime lastAI = 0;
datetime lastCSV = 0;

// --- Forward Declarations
void InterpretaPrompt(string prompt);
void AddRule(string txt, Signal currentIntent);
double ExtraiNumero(string txt, int &cursor);
void AvaliaTudo();
void EnviaOrdem(Signal s, string reason);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
void CalculaStats(double &winRate, double &drawdown, double &profitFactor);
double CalculaLote(double risco);
bool IsTimeAllowed();
int PeriodoTexto(string nome);
double GetBufferValue(int handle, int buffer, int shift);

// ... (Functions will be implemented in subsequent steps)

// --- NLP Parser Functions
void InterpretaPrompt(string prompt) {
    GravaLog("Interpretando prompt: " + prompt);
    for(int i=0; i<20; i++) rules[i].Reset();
    nRules = 0;

    string work = prompt;
    StringToLower(work);
    StringReplace(work, " e ", ".");

    string segments[];
    int nSeg = StringSplit(work, '.', segments);

    Signal currentIntent = NONE;

    for(int i=0; i<nSeg; i++) {
        string seg = segments[i];
        StringTrimLeft(seg); StringTrimRight(seg);
        if(seg == "") continue;

        if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

        // Settings parsing
        int cur = 0;
        if(StringFind(seg, "stop") >= 0) {
            cur = StringFind(seg, "stop") + 4;
            double v = ExtraiNumero(seg, cur);
            if(v > 0) p_stopLoss = (int)v;
        }
        if(StringFind(seg, "take") >= 0) {
            cur = StringFind(seg, "take") + 4;
            double v = ExtraiNumero(seg, cur);
            if(v > 0) p_takeProfit = (int)v;
        }
        if(StringFind(seg, "risco") >= 0) {
            cur = StringFind(seg, "risco") + 5;
            double v = ExtraiNumero(seg, cur);
            if(v > 0) p_riskPercent = v;
        }
        if(StringFind(seg, "máximo") >= 0) {
            cur = StringFind(seg, "máximo") + 6;
            double v = ExtraiNumero(seg, cur);
            if(v > 0) p_maxTrades = (int)v;
        }
        if(StringFind(seg, "depois das") >= 0 || StringFind(seg, "início") >= 0 || StringFind(seg, "começar") >= 0) {
            // Very simple time extraction (HH:MM or HHh)
            int hPos = StringFind(seg, "h");
            if(hPos > 0) {
                int hCur = hPos - 1;
                while(hCur >= 0 && StringGetCharacter(seg, hCur) >= '0' && StringGetCharacter(seg, hCur) <= '9') hCur--;
                string hStr = StringSubstr(seg, hCur + 1, hPos - hCur - 1);
                p_startTime = hStr + ":00";
            }
        }
        if(StringFind(seg, "atingir") >= 0) {
            cur = StringFind(seg, "atingir") + 7;
            p_beStart = (int)ExtraiNumero(seg, cur);
        }
        if(StringFind(seg, "entrada") >= 0) {
            cur = StringFind(seg, "entrada") + 7;
            p_bePlus = (int)ExtraiNumero(seg, cur);
        }
        if(StringFind(seg, "trailing") >= 0) {
            cur = StringFind(seg, "trailing") + 8;
            p_trailingStop = (int)ExtraiNumero(seg, cur);
            p_trailingStep = (int)ExtraiNumero(seg, cur);
        }
        if(StringFind(seg, "notícias") >= 0) {
            cur = StringFind(seg, "notícias") - 3;
            if(cur < 0) cur = 0;
            double v = ExtraiNumero(seg, cur);
            if(v > 0) p_newsVetoBuffer = (int)v;
        }

        // Timeframe extraction
        if(StringFind(seg, "minutos") >= 0 || StringFind(seg, "min") >= 0) {
            cur = 0;
            double v = ExtraiNumero(seg, cur);
            if(v == 1) p_frequency = PERIOD_M1;
            else if(v == 5) p_frequency = PERIOD_M5;
            else if(v == 15) p_frequency = PERIOD_M15;
            else if(v == 30) p_frequency = PERIOD_M30;
        }

        AddRule(seg, currentIntent);
    }
}

double ExtraiNumero(string txt, int &cursor) {
    string res = "";
    bool found = false;
    for(int i=cursor; i<StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') c = '.';
            res += ShortToString(c);
            found = true;
        } else if(found) {
            cursor = i;
            break;
        }
    }
    return StringToDouble(res);
}

void AddRule(string txt, Signal currentIntent) {
    if(nRules >= 20) return;

    int cur = 0;
    // 1. Média Móvel
    if(StringFind(txt, "média") >= 0) {
        cur = StringFind(txt, "média") + 5;
        rules[nRules].type = 1;
        rules[nRules].intent = currentIntent;
        rules[nRules].p1 = (int)ExtraiNumero(txt, cur); // period
        if(rules[nRules].p1 == 0) rules[nRules].p1 = 20;
        rules[nRules].handle1 = iMA(_Symbol, p_frequency, rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }

    // 2. RSI
    if(nRules < 20 && StringFind(txt, "rsi") >= 0) {
        cur = StringFind(txt, "rsi") + 3;
        rules[nRules].type = 2;
        rules[nRules].intent = currentIntent;
        double n1 = ExtraiNumero(txt, cur);
        double n2 = ExtraiNumero(txt, cur);

        if(n2 > 0) {
            rules[nRules].p1 = (int)n1; // period
            rules[nRules].d1 = n2;      // threshold
        } else {
            rules[nRules].p1 = 14;
            rules[nRules].d1 = n1;
        }

        rules[nRules].handle1 = iRSI(_Symbol, p_frequency, rules[nRules].p1, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }

    // 3. Estocástico
    if(nRules < 20 && StringFind(txt, "estocástico") >= 0) {
        rules[nRules].type = 3;
        rules[nRules].intent = currentIntent;
        rules[nRules].handle1 = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }

    // 4. Bollinger
    if(nRules < 20 && (StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0)) {
        rules[nRules].type = 4;
        rules[nRules].intent = currentIntent;
        rules[nRules].handle1 = iBands(_Symbol, p_frequency, 20, 0, 2.0, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }

    // 6. Delta Agression
    if(nRules < 20 && StringFind(txt, "delta") >= 0) {
        cur = StringFind(txt, "delta") + 5;
        rules[nRules].type = 6;
        rules[nRules].intent = currentIntent;
        rules[nRules].p1 = 60; // default 60s
        rules[nRules].p2 = (int)ExtraiNumero(txt, cur); // threshold
        rules[nRules].active = true;
        nRules++;
    }

    // 10. Força Relativa
    if(nRules < 20 && (StringFind(txt, "relativa") >= 0 || StringFind(txt, "comparado") >= 0)) {
        rules[nRules].type = 10;
        rules[nRules].intent = currentIntent;
        rules[nRules].s1 = "US30";
        rules[nRules].handle1 = iRSI(_Symbol, p_frequency, 14, PRICE_CLOSE);
        rules[nRules].handle2 = iRSI(rules[nRules].s1, p_frequency, 14, PRICE_CLOSE);
        if(rules[nRules].handle1 != INVALID_HANDLE && rules[nRules].handle2 != INVALID_HANDLE) {
            rules[nRules].active = true;
            nRules++;
        }
    }
}

int PeriodoTexto(string nome) {
    string n = nome; StringToLower(n);
    if(StringFind(n, "m1") >= 0 && StringFind(n, "m15") < 0) return PERIOD_M1;
    if(StringFind(n, "m5") >= 0 && StringFind(n, "m15") < 0) return PERIOD_M5;
    if(StringFind(n, "m15") >= 0) return PERIOD_M15;
    if(StringFind(n, "m30") >= 0) return PERIOD_M30;
    if(StringFind(n, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(n, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

// --- Signal Evaluation Logic
void AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;

        Signal s = AvaliaRegra(rules[i]);
        if(rules[i].intent == BUY) {
            buyRules++;
            if(s == BUY) buyVotes++;
        } else if(rules[i].intent == SELL) {
            sellRules++;
            if(s == SELL) sellVotes++;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) EnviaOrdem(BUY, "Confluência de compra");
    else if(sellRules > 0 && sellVotes == sellRules) EnviaOrdem(SELL, "Confluência de venda");
}

Signal AvaliaRegra(Rule &r) {
    if(r.type == 1) { // MA
        double ma1 = GetBufferValue(r.handle1, 0, 1);
        double ma2 = GetBufferValue(r.handle1, 0, 2);
        double c1 = iClose(_Symbol, p_frequency, 1);
        double c2 = iClose(_Symbol, p_frequency, 2);
        if(c2 < ma2 && c1 > ma1) return BUY;
        if(c2 > ma2 && c1 < ma1) return SELL;
    }
    else if(r.type == 2) { // RSI
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);
        if(rsi2 < r.d1 && rsi1 > r.d1) return BUY;
        if(rsi2 > r.d1 && rsi1 < r.d1) return SELL;
    }
    else if(r.type == 3) { // Stoch
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);
        if(k2 < d2 && k1 > d1) return BUY;
        if(k2 > d2 && k1 < d1) return SELL;
    }
    else if(r.type == 4) { // Bollinger
        double lower = GetBufferValue(r.handle1, 2, 1);
        double upper = GetBufferValue(r.handle1, 1, 1);
        double close = iClose(_Symbol, p_frequency, 1);
        if(close < lower) return BUY;
        if(close > upper) return SELL;
    }
    else if(r.type == 6) { // Delta
        MqlTick ticks[];
        int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buyVol = 0, sellVol = 0;
        for(int i=0; i<n; i++) {
            if((ticks[i].flags & TICK_FLAG_BUY) != 0) buyVol += (long)ticks[i].last;
            else if((ticks[i].flags & TICK_FLAG_SELL) != 0) sellVol += (long)ticks[i].last;
        }
        long delta = buyVol - sellVol;
        if(delta > r.p2) return BUY;
        if(delta < -r.p2) return SELL;
    }
    else if(r.type == 10) { // RS
        double rsiMain = GetBufferValue(r.handle1, 0, 1);
        double rsiBench = GetBufferValue(r.handle2, 0, 1);
        if(rsiMain > rsiBench + 5) return BUY;
        if(rsiMain < rsiBench - 5) return SELL;
    }
    return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
    double val[1];
    if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
    return 0;
}

// --- Trade Execution and Position Management
void EnviaOrdem(Signal s, string reason) {
    if(PositionsTotal() >= p_maxTrades) return;
    if(AguardaNoticias()) {
        GravaLog("Ordem vetada por notícias: " + reason);
        return;
    }

    double lote = CalculaLote(p_riskPercent);
    double sl = 0, tp = 0;
    double price = 0;

    if(s == BUY) {
        price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        sl = (p_stopLoss > 0) ? price - p_stopLoss * _Point : 0;
        tp = (p_takeProfit > 0) ? price + p_takeProfit * _Point : 0;
    } else {
        price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        sl = (p_stopLoss > 0) ? price + p_stopLoss * _Point : 0;
        tp = (p_takeProfit > 0) ? price - p_takeProfit * _Point : 0;
    }

    bool res = false;
    for(int i=0; i<3; i++) {
        if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, reason);
        else res = trade.Sell(lote, _Symbol, price, sl, tp, reason);

        if(res) break;

        uint ret = trade.ResultRetcode();
        if(ret != TRADE_RETCODE_REQUOTES && ret != TRADE_RETCODE_OFFQUOTES) break;

        price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
        Sleep(100);
    }

    if(res) {
        GravaLog("Ordem enviada: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2) + " Reason: " + reason);
        SendNotification("MT-LiveExecutor: " + reason);
        SendMail("MT-LiveExecutor: Nova Ordem", reason);
    } else {
        GravaLog("Falha ao enviar ordem: " + IntegerToString(trade.ResultRetcode()));
    }
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(pos.SelectByIndex(i)) {
            if(pos.Magic() != EA_MAGIC || pos.Symbol() != _Symbol) continue;

            double openPrice = pos.PriceOpen();
            double curPrice = (pos.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profitPoints = (pos.PositionType() == POSITION_TYPE_BUY) ? (curPrice - openPrice)/_Point : (openPrice - curPrice)/_Point;

            // Breakeven
            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (pos.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if(pos.StopLoss() == 0 || (pos.PositionType() == POSITION_TYPE_BUY && newSL > pos.StopLoss()) || (pos.PositionType() == POSITION_TYPE_SELL && newSL < pos.StopLoss())) {
                    trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (pos.PositionType() == POSITION_TYPE_BUY) ? curPrice - p_trailingStop * _Point : curPrice + p_trailingStop * _Point;
                if(MathAbs(newSL - pos.StopLoss()) >= p_trailingStep * _Point) {
                    if((pos.PositionType() == POSITION_TYPE_BUY && newSL > pos.StopLoss()) || (pos.PositionType() == POSITION_TYPE_SELL && (pos.StopLoss() == 0 || newSL < pos.StopLoss()))) {
                        trade.PositionModify(pos.Ticket(), newSL, pos.TakeProfit());
                    }
                }
            }
        }
    }
}

double CalculaLote(double riscoPercent) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskVal = equity * (riscoPercent / 100.0);
    double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(p_stopLoss == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    double lote = riskVal / (p_stopLoss * (tickVal / tickSize) * _Point / tickSize); // simplified
    // Standard formula: Lote = Risco / (SL_em_pontos * Valor_do_Ponto)
    lote = riskVal / (p_stopLoss * tickVal);

    return NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lote)), 2);
}

// --- Utility Functions
void GravaLog(string texto) {
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
        FileClose(handle);
    }
    Print(texto);
}

void GravaCSV() {
    if(TimeCurrent() - lastCSV < 5) return;
    lastCSV = TimeCurrent();

    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON, ',');
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit");
        for(int i=0; i<PositionsTotal(); i++) {
            if(pos.SelectByIndex(i)) {
                if(pos.Magic() == EA_MAGIC) {
                    FileWrite(handle, pos.Ticket(), pos.Symbol(), pos.PositionType(), pos.PriceOpen(), pos.StopLoss(), pos.TakeProfit(), pos.Profit());
                }
            }
        }
        FileClose(handle);
    }
}

bool AguardaNoticias() {
    // 1. Check direct veto file
    int h1 = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h1 != INVALID_HANDLE) {
        string veto = FileReadString(h1);
        FileClose(h1);
        if(StringFind(veto, "TRUE") >= 0) return true;
    }

    // 2. Check calendar file for 'high-impact'
    int h2 = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h2 != INVALID_HANDLE) {
        while(!FileIsEnding(h2)) {
            string line = FileReadString(h2);
            if(StringFind(line, "HIGH") >= 0) {
                // Simplified time check
                FileClose(h2);
                return true;
            }
        }
        FileClose(h2);
    }
    return false;
}

void CalculaStats(double &winRate, double &drawdown, double &profitFactor) {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, loss = 0;
    double grossProfit = 0, grossLoss = 0;
    double maxBalance = 0, currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double maxDD = 0;

    for(int i=0; i<total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit > 0) { wins++; grossProfit += profit; }
            else if(profit < 0) { loss++; grossLoss += MathAbs(profit); }
        }
    }

    winRate = (wins + loss > 0) ? (double)wins / (wins + loss) * 100.0 : 0;
    profitFactor = (grossLoss > 0) ? grossProfit / grossLoss : grossProfit;
    drawdown = 0; // Simplified
}

bool IsTimeAllowed() {
    string now = TimeToString(TimeCurrent(), TIME_MINUTES);
    return (now >= p_startTime);
}

// --- MQL5 Event Handlers
int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    trade.SetDeviationInPoints(30);
    trade.SetTypeFilling(ORDER_FILLING_IOC);

    EventSetTimer(1);
    GravaLog("MT-LiveExecutor iniciado.");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    for(int i=0; i<20; i++) rules[i].Reset();
    EventKillTimer();
    GravaLog("MT-LiveExecutor finalizado.");
}

void OnTick() {
    GerenciaPosicoes();
    GravaCSV();

    if(!IsTimeAllowed()) return;

    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != lastBar) {
        lastBar = currentBar;
        AvaliaTudo();
    }
}

void OnTimer() {
    // 1. Check for prompt updates
    int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string newPrompt = FileReadString(h);
        FileClose(h);
        if(newPrompt != p_prompt && newPrompt != "") {
            p_prompt = newPrompt;
            InterpretaPrompt(p_prompt);
        }
    }

    // 2. AI Optimizer (Hourly)
    if(TimeCurrent() - lastAI >= 3600) {
        lastAI = TimeCurrent();
        double wr, dd, pf;
        CalculaStats(wr, dd, pf);
        if(wr < 40 && wr > 0) {
            p_riskPercent *= 0.8;
            GravaLog("AI Optimizer: Reduzindo risco devido a win rate baixo: " + DoubleToString(wr, 1) + "%");
        }
    }
}
