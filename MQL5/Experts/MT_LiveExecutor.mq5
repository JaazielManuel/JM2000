//=========================  MT-LiveExecutor  =========================
// Executor de Estratégias em Tempo Real via Prompt de Linguagem Natural
//========================================================================

#property copyright "MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- DEFINES ---
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- ENUMS ---
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

// --- STRUCTS ---
struct Rule {
    bool    active;
    int     type;    // 1:MA, 2:RSI, 3:Stoch, 4:BB, 5:Breakout, 6:Delta, 7:Volume, 8:AMA, 9:2Bar, 10:Relative
    int     intent;  // Signal: BUY or SELL
    int     tf;
    int     p1, p2, p3;
    double  d1, d2;
    string  s1;
    long    handle1, handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease((int)handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease((int)handle2);
        active = false;
        type = 0; intent = 0; tf = 0;
        p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0; s1 = "";
        handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
    }
};

// --- GLOBALS ---
Rule rules[MAX_RULES];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;

// Parâmetros de Gestão
double p_risk = 1.0;
int p_stopLoss = 0;
int p_takeProfit = 0;
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
bool p_martingale = false;
datetime p_startTime = 0;
int p_newsVeto = 20; // minutos
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// --- NLP PARSER & RULES ---

void ResetStrategy() {
    for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
    nRules = 0;
    p_risk = 1.0; p_stopLoss = 0; p_takeProfit = 0; p_maxTrades = 3;
    p_beStart = 0; p_bePlus = 0; p_trailingStop = 0; p_trailingStep = 0;
    p_martingale = false; p_startTime = 0; p_newsVeto = 20;
    p_frequency = PERIOD_M15;
}

double ExtraiNumero(string txt, int &cursor) {
    string res = "";
    bool achou = false;
    for(int i=cursor; i<StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') c = '.';
            res += CharToString((char)c);
            achou = true;
        } else if(achou) {
            cursor = i;
            break;
        }
    }
    return StringToDouble(res);
}

string TextoMinusculo(string txt) {
    string res = txt;
    StringToLower(res);
    return res;
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
    txt = TextoMinusculo(txt);
    if(StringFind(txt, "m15") >= 0) return PERIOD_M15;
    if(StringFind(txt, "m1") >= 0)  return PERIOD_M1;
    if(StringFind(txt, "m5") >= 0)  return PERIOD_M5;
    if(StringFind(txt, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(txt, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

void AddRule(string txt, int intent) {
    if(nRules >= MAX_RULES) return;

    static int lastMA = 20;
    static int lastRSI = 14;

    Rule r; r.Reset();
    r.intent = intent;
    txt = TextoMinusculo(txt);
    r.tf = PeriodoTexto(txt);

    if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
        r.type = 1;
        int c = StringFind(txt, "média");
        if(c < 0) c = StringFind(txt, "ma");
        int val = (int)ExtraiNumero(txt, c);
        if(val > 0) lastMA = val;
        r.p1 = lastMA;
        r.active = true;
    }
    else if(StringFind(txt, "rsi") >= 0) {
        r.type = 2;
        int c = StringFind(txt, "rsi");
        int per = (int)ExtraiNumero(txt, c);
        if(per > 0) lastRSI = per;
        r.p1 = lastRSI;
        r.d1 = ExtraiNumero(txt, c);     // threshold
        r.active = true;
    }
    else if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
        r.type = 3;
        r.active = true;
    }
    else if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
        r.type = 4;
        r.active = true;
    }

    if(r.active) {
        rules[nRules] = r;
        nRules++;
    }
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string original = prompt;
    prompt = TextoMinusculo(prompt);

    // Globais
    int c = 0;
    if((c = StringFind(prompt, "risco de")) >= 0) p_risk = ExtraiNumero(prompt, c);
    if((c = StringFind(prompt, "stop de")) >= 0) p_stopLoss = (int)ExtraiNumero(prompt, c);
    if((c = StringFind(prompt, "take de")) >= 0) p_takeProfit = (int)ExtraiNumero(prompt, c);
    if((c = StringFind(prompt, "máximo")) >= 0) p_maxTrades = (int)ExtraiNumero(prompt, c);
    if(StringFind(prompt, "martingale") >= 0) p_martingale = true;

    if((c = StringFind(prompt, "atingir")) >= 0) p_beStart = (int)ExtraiNumero(prompt, c);
    if((c = StringFind(prompt, "entrada +")) >= 0) p_bePlus = (int)ExtraiNumero(prompt, c);

    if((c = StringFind(prompt, "trailing")) >= 0) {
        p_trailingStop = (int)ExtraiNumero(prompt, c);
        p_trailingStep = 10; // Default step
    }

    // Horário
    if((c = StringFind(prompt, "depois das")) >= 0) {
        int hora = (int)ExtraiNumero(prompt, c);
        p_startTime = (datetime)(hora * 3600);
    }

    // Frequência
    p_frequency = PeriodoTexto(prompt);

    // Regras
    string parts[];
    StringReplace(prompt, " e ", ".");
    int n = StringSplit(prompt, '.', parts);
    int currentIntent = 0;

    for(int i=0; i<n; i++) {
        string segment = parts[i];
        if(StringFind(segment, "compra") >= 0) currentIntent = BUY;
        if(StringFind(segment, "vende") >= 0) currentIntent = SELL;

        if(currentIntent != 0) AddRule(segment, currentIntent);
    }

    GravaLog("Estratégia Interpretada: " + original);
}

// --- SIGNAL EVALUATION ---

double GetBufferValue(long handle, int buffer, int shift) {
    double val[1];
    if(CopyBuffer((int)handle, buffer, shift, 1, val) < 0) return 0;
    return val[0];
}

Signal AvaliaRegra(Rule &r) {
    if(!r.active) return NONE;

    if(r.type == 1) { // Média Móvel
        if(r.handle1 == INVALID_HANDLE || r.handle1 == 0)
            r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);

        double ma1 = GetBufferValue(r.handle1, 0, 1);
        double ma2 = GetBufferValue(r.handle1, 0, 2);
        double c1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        double c2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);

        if(r.intent == BUY && c2 < ma2 && c1 > ma1) return BUY;
        if(r.intent == SELL && c2 > ma2 && c1 < ma1) return SELL;
    }

    if(r.type == 2) { // RSI
        if(r.handle1 == INVALID_HANDLE || r.handle1 == 0)
            r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);

        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);

        if(r.intent == BUY && rsi2 < r.d1 && rsi1 > r.d1) return BUY;
        if(r.intent == SELL && rsi2 > r.d1 && rsi1 < r.d1) return SELL;
    }

    return NONE;
}

Signal AvaliaTudo() {
    if(nRules == 0) return NONE;

    bool buySignal = true;
    bool sellSignal = true;
    bool hasBuy = false;
    bool hasSell = false;

    for(int i=0; i<nRules; i++) {
        Signal s = AvaliaRegra(rules[i]);
        if(rules[i].intent == BUY) {
            hasBuy = true;
            if(s != BUY) buySignal = false;
        }
        if(rules[i].intent == SELL) {
            hasSell = true;
            if(s != SELL) sellSignal = false;
        }
    }

    if(hasBuy && buySignal) return BUY;
    if(hasSell && sellSignal) return SELL;

    return NONE;
}

// --- TRADE EXECUTION ---

double CalculaLote(double riscoPercent) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = equity * (riscoPercent / 100.0);

    if(p_martingale) {
        HistorySelect(TimeCurrent()-86400, TimeCurrent());
        int total = HistoryDealsTotal();
        if(total > 0) {
            ulong ticket = HistoryDealGetTicket(total-1);
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2;
        }
    }

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    int sl_points = (p_stopLoss > 0) ? p_stopLoss : 100;
    double lot = riskAmount / ((sl_points * _Point / tickSize) * tickValue);

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    lot = MathMax(minLot, MathMin(maxLot, lot));

    return NormalizeDouble(lot, 2);
}

void EnviaOrdem(Signal s, double lote) {
    if(PositionsTotal() >= p_maxTrades) return;

    double sl = 0, tp = 0;
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    if(s == BUY) {
        if(p_stopLoss > 0) sl = bid - p_stopLoss * _Point;
        if(p_takeProfit > 0) tp = ask + p_takeProfit * _Point;

        for(int i=0; i<3; i++) {
            if(trade.Buy(lote, _Symbol, ask, sl, tp, "MT-LiveExecutor")) break;
            int code = trade.ResultRetcode();
            if(code != TRADE_RETCODE_REQUOTES && code != TRADE_RETCODE_OFFQUOTES) break;
            ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
        }
    }
    else if(s == SELL) {
        if(p_stopLoss > 0) sl = ask + p_stopLoss * _Point;
        if(p_takeProfit > 0) tp = bid - p_takeProfit * _Point;

        for(int i=0; i<3; i++) {
            if(trade.Sell(lote, _Symbol, bid, sl, tp, "MT-LiveExecutor")) break;
            int code = trade.ResultRetcode();
            if(code != TRADE_RETCODE_REQUOTES && code != TRADE_RETCODE_OFFQUOTES) break;
            bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        }
    }

    if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
        GravaLog("Ordem Executada: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2));
    } else {
        GravaLog("Erro na Ordem: " + trade.ResultRetcodeDescription());
    }
}

// --- POSITION MANAGEMENT & NEWS ---

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

            double openPrice = posInfo.PriceOpen();
            double curPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (curPrice - openPrice)/_Point : (openPrice - curPrice)/_Point;

            if(p_beStart > 0 && profitPoints >= p_beStart) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                if(posInfo.StopLoss() == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss()) || (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < posInfo.StopLoss())) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }

            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? curPrice - p_trailingStop * _Point : curPrice + p_trailingStop * _Point;
                if(MathAbs(newSL - posInfo.StopLoss()) >= p_trailingStep * _Point) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }
        }
    }
}

bool AguardaNoticias() {
    int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        string veto = FileReadString(handle);
        FileClose(handle);
        if(veto == "1" || veto == "true") return true;
    }
    return false;
}

bool IsTimeAllowed() {
    if(p_startTime == 0) return true;
    datetime now = TimeCurrent();
    datetime today = now - (now % 86400);
    return (now >= today + p_startTime);
}

// --- LOGGING & STATE ---

void GravaLog(string txt) {
    Print(txt);
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()) + ": " + txt);
        FileClose(handle);
    }
}

void GravaCSV() {
    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "PriceOpen", "SL", "TP", "Profit");
        for(int i=0; i<PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i)) {
                if(posInfo.Magic() == EA_MAGIC) {
                    FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(),
                              posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
                }
            }
        }
        FileClose(handle);
    }
}

void CalculaStats() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, losses = 0;
    double netProfit = 0;

    for(int i=0; i<total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            netProfit += profit;
            if(profit > 0) wins++;
            else if(profit < 0) losses++;
        }
    }

    double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
    GravaLog("Stats - Profit: " + DoubleToString(netProfit, 2) + " WinRate: " + DoubleToString(winRate, 2) + "%");
}

// --- EVENT HANDLERS ---

int OnInit() {
    trade.SetExpertMagicNumber(EA_MAGIC);
    symInfo.Name(_Symbol);
    EventSetTimer(1);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
    EventKillTimer();
}

void OnTick() {
    GerenciaPosicoes();

    static datetime lastCSV = 0;
    if(TimeCurrent() - lastCSV >= 5) {
        GravaCSV();
        lastCSV = TimeCurrent();
        CalculaStats();
    }

    static datetime lastBar = 0;
    datetime curBar = iTime(_Symbol, p_frequency, 0);
    if(curBar == lastBar) return;
    lastBar = curBar;

    if(AguardaNoticias()) return;
    if(!IsTimeAllowed()) return;

    Signal s = AvaliaTudo();
    if(s != NONE) {
        double lote = CalculaLote(p_risk);
        EnviaOrdem(s, lote);
    }
}

void OnTimer() {
    static datetime lastCheck = 0;
    if(TimeCurrent() - lastCheck < 1) return;
    lastCheck = TimeCurrent();

    int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        string prompt = FileReadString(handle);
        FileClose(handle);
        static string lastPrompt = "";
        if(prompt != lastPrompt && prompt != "") {
            InterpretaPrompt(prompt);
            lastPrompt = prompt;
        }
    }
}
