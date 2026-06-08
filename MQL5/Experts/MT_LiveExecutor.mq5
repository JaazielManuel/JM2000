//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//=========================  MT5-KNOWLEDGE-CORE  =========================
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- DEFINES & ENUMS ----------
#define EA_MAGIC 123456
enum Signal {BUY=1, SELL=-1, NONE=0};

// ---------- STRUCTS ----------
struct Rule {
    bool     active;
    int      type;    // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: Breakout, 6: Delta, 7: VolCycle, 8: AMA, 9: 2Bar, 10: RelStrength
    int      intent;  // 1: BUY, -1: SELL
    int      tf;
    int      p1, p2, p3;
    double   d1, d2;
    string   s1;
    int      handle1, handle2;

    void Reset() {
        active = false;
        type = 0;
        intent = 0;
        tf = PERIOD_CURRENT;
        p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0;
        s1 = "";
        handle1 = INVALID_HANDLE;
        handle2 = INVALID_HANDLE;
    }
};

// ---------- GLOBALS ----------
Rule rules[50];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// Strategy Parameters
double p_risk = 1.0;
double p_sl = 0;
double p_tp = 0;
int p_maxTrades = 3;
double p_breakeven = 0;
double p_breakevenStep = 0;
double p_trailingStop = 0;
double p_trailingStep = 0;
int p_newsVeto = 20; // minutes
string p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool p_martingale = false;

// State
datetime lastBarTime = 0;
datetime lastCSVUpdate = 0;
datetime lastAIUpdate = 0;
string lastPrompt = "";

//+------------------------------------------------------------------+

// ---------- NLP PARSER ----------
void InterpretaPrompt(string prompt) {
    if(prompt == lastPrompt) return;
    lastPrompt = prompt;
    ResetStrategy();
    GravaLog("Interpretando: " + prompt);

    string cleanPrompt = prompt;
    StringReplace(cleanPrompt, " e ", ".");
    string segments[];
    int nSegments = StringSplit(cleanPrompt, '.', segments);

    int currentIntent = 0; // 1: BUY, -1: SELL
    int cursor = 0;

    for(int i=0; i<nSegments; i++) {
        string txt = segments[i];
        StringToLower(txt);
        StringTrimLeft(txt);
        StringTrimRight(txt);

        // Global Parameters
        cursor = 0;
        if(StringFind(txt, "risco") >= 0) p_risk = ExtraiNumero(txt, cursor);
        cursor = 0;
        if(StringFind(txt, "stop") >= 0) p_sl = ExtraiNumero(txt, cursor);
        cursor = 0;
        if(StringFind(txt, "take") >= 0) p_tp = ExtraiNumero(txt, cursor);
        cursor = 0;
        if(StringFind(txt, "máximo") >= 0) p_maxTrades = (int)ExtraiNumero(txt, cursor);
        cursor = 0;
        if(StringFind(txt, "notícias") >= 0) p_newsVeto = (int)ExtraiNumero(txt, cursor);
        cursor = 0;
        if(StringFind(txt, "martingale") >= 0) p_martingale = true;

        if(StringFind(txt, "cada") >= 0) p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(txt);

        // Time Filter
        if(StringFind(txt, "depois das") >= 0 || StringFind(txt, "início") >= 0) {
            int hPos = StringFind(txt, "h");
            if(hPos > 0) {
                int start = hPos - 1;
                while(start > 0 && StringSubstr(txt, start-1, 1) >= "0" && StringSubstr(txt, start-1, 1) <= "9") start--;
                p_startTime = StringSubstr(txt, start, hPos-start) + ":00";
            }
        }

        // Breakeven / Trailing
        if(StringFind(txt, "move stop") >= 0 || StringFind(txt, "break-even") >= 0) {
            cursor = 0;
            p_breakeven = ExtraiNumero(txt, cursor);
            p_breakevenStep = ExtraiNumero(txt, cursor);
        }
        if(StringFind(txt, "trailing") >= 0) {
            cursor = StringFind(txt, "trailing");
            p_trailingStop = ExtraiNumero(txt, cursor);
            p_trailingStep = ExtraiNumero(txt, cursor);
        }

        // Intent detection
        if(StringFind(txt, "compra") >= 0) currentIntent = 1;
        else if(StringFind(txt, "vende") >= 0) currentIntent = -1;

        if(currentIntent != 0) AddRule(txt, currentIntent);
    }
}

void AddRule(string txt, int intent) {
    if(nRules >= 50) return;
    Rule r;
    r.Reset();
    r.intent = intent;
    r.tf = PeriodoTexto(txt);

    bool added = false;
    int cursor = 0;

    // MA Cross
    if(StringFind(txt, "média") >= 0) {
        r.type = 1;
        cursor = StringFind(txt, "média") + 5;
        r.p1 = (int)ExtraiNumero(txt, cursor);
        if(r.p1 == 0) r.p1 = 20; // Default
        r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
        added = true;
    }

    // RSI
    if(StringFind(txt, "rsi") >= 0) {
        r.type = 2;
        cursor = StringFind(txt, "rsi") + 3;
        r.p1 = (int)ExtraiNumero(txt, cursor);
        if(r.p1 == 0) r.p1 = 14; // Default
        r.d1 = ExtraiNumero(txt, cursor); // Threshold
        r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
        added = true;
    }

    // Stoch
    if(StringFind(txt, "estocástico") >= 0) {
        r.type = 3;
        r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
        added = true;
    }

    // BB
    if(StringFind(txt, "bollinger") >= 0) {
        r.type = 4;
        r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
        added = true;
    }

    if(added) {
        r.active = true;
        rules[nRules] = r;
        nRules++;
    }
}

double ExtraiNumero(string txt, int &cursor) {
    string res = "";
    bool found = false;
    for(int i=cursor; i<StringLen(txt); i++) {
        string c = StringSubstr(txt, i, 1);
        if((c >= "0" && c <= "9") || c == "." || c == ",") {
            if(c == ",") c = ".";
            res += c;
            found = true;
        } else if(found) {
            cursor = i;
            break;
        }
    }
    return StringToDouble(res);
}

int PeriodoTexto(string txt) {
    if(StringFind(txt, "m1") >= 0 && StringFind(txt, "m15") < 0) return PERIOD_M1;
    if(StringFind(txt, "m5") >= 0) return PERIOD_M5;
    if(StringFind(txt, "m15") >= 0 || StringFind(txt, "15 min") >= 0) return PERIOD_M15;
    if(StringFind(txt, "h1") >= 0 || StringFind(txt, "60 min") >= 0) return PERIOD_H1;
    if(StringFind(txt, "d1") >= 0 || StringFind(txt, "diário") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

void ResetStrategy() {
    for(int i=0; i<nRules; i++) {
        if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
        if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
        rules[i].Reset();
    }
    nRules = 0;
}

// ---------- SIGNAL ENGINE ----------
Signal AvaliaTudo() {
    int buyVotes = 0;
    int sellVotes = 0;
    int totalBuyRules = 0;
    int totalSellRules = 0;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;
        int res = AvaliaRegra(rules[i]);
        if(rules[i].intent == 1) {
            totalBuyRules++;
            if(res == 1) buyVotes++;
        } else if(rules[i].intent == -1) {
            totalSellRules++;
            if(res == -1) sellVotes++;
        }
    }

    if(totalBuyRules > 0 && buyVotes == totalBuyRules) return BUY;
    if(totalSellRules > 0 && sellVotes == totalSellRules) return SELL;
    return NONE;
}

int AvaliaRegra(Rule &r) {
    double val1 = GetBufferValue(r.handle1, 0, 1);
    double val1_prev = GetBufferValue(r.handle1, 0, 2);
    double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
    double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);

    switch(r.type) {
        case 1: // MA Cross/Price Cross
            if(r.intent == 1 && close2 < val1_prev && close1 > val1) return 1;
            if(r.intent == -1 && close2 > val1_prev && close1 < val1) return -1;
            break;
        case 2: // RSI Threshold
            if(r.intent == 1 && val1_prev < r.d1 && val1 > r.d1) return 1;
            if(r.intent == -1 && val1_prev > r.d1 && val1 < r.d1) return -1;
            break;
        // Add other cases as needed
    }
    return 0;
}

double GetBufferValue(int handle, int buffer, int shift) {
    if(handle == INVALID_HANDLE || handle == 0) return 0;
    double res[];
    ArraySetAsSeries(res, true);
    if(CopyBuffer(handle, buffer, shift, 1, res) > 0) return res[0];
    return 0;
}

// ---------- TRADE & POSITION MANAGEMENT ----------
void EnviaOrdem(Signal s) {
    if(s == NONE) return;
    if(PositionsTotal() >= p_maxTrades) return;
    if(AguardaNoticias()) return;

    double lote = CalculaLote(p_risk);
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = 0, tp = 0;

    if(p_sl > 0) sl = (s == BUY) ? price - p_sl * _Point : price + p_sl * _Point;
    if(p_tp > 0) tp = (s == BUY) ? price + p_tp * _Point : price - p_tp * _Point;

    trade.SetExpertMagicNumber(EA_MAGIC);
    bool res = false;
    if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
    else res = trade.Sell(lote, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");

    if(res) {
        GravaLog("Ordem enviada: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2));
        SendNotification("MT-LiveExecutor: Ordem de " + EnumToString(s) + " executada.");
    } else {
        GravaLog("Erro ao enviar ordem: " + IntegerToString(trade.ResultRetcode()));
    }
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

            double currentProfitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                (SymbolInfoDouble(_Symbol, SYMBOL_BID) - posInfo.PriceOpen()) / _Point :
                (posInfo.PriceOpen() - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

            // Breakeven
            if(p_breakeven > 0 && currentProfitPoints >= p_breakeven) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                    posInfo.PriceOpen() + p_breakevenStep * _Point :
                    posInfo.PriceOpen() - p_breakevenStep * _Point;

                if(posInfo.StopLoss() == 0 ||
                   (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss()) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < posInfo.StopLoss() || posInfo.StopLoss() == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && currentProfitPoints >= p_trailingStop) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                    SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_trailingStop * _Point :
                    SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_trailingStop * _Point;

                if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss() + p_trailingStep * _Point) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < posInfo.StopLoss() - p_trailingStep * _Point || posInfo.StopLoss() == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }
        }
    }
}

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riscoAbs = capital * riscoPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double slPoints = (p_sl > 0) ? p_sl : 100;

    double lote = riscoAbs / (slPoints * tickValue);

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lote = MathFloor(lote / step) * step;

    double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lote < minVol) lote = minVol;
    if(lote > maxVol) lote = maxVol;

    return lote;
}

// ---------- UTILITIES ----------
void GravaLog(string texto) {
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
        FileClose(handle);
    }
}

void GravaCSV() {
    if(TimeCurrent() - lastCSVUpdate < 5) return;
    lastCSVUpdate = TimeCurrent();

    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON, ';');
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "Lote", "PriceOpen", "SL", "TP", "Profit");
        for(int i=0; i<PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i)) {
                if(posInfo.Magic() == EA_MAGIC) {
                    FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
                }
            }
        }
        FileClose(handle);
    }
}

bool AguardaNoticias() {
    // news_veto.txt
    int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string status = FileReadString(h);
        FileClose(h);
        if(status == "1") return true;
    }

    // calendar.txt
    h = FileOpen("calendar.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        datetime now = TimeCurrent();
        while(!FileIsEnding(h)) {
            string line = FileReadString(h);
            // Expected format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
            string parts[];
            if(StringSplit(line, ';', parts) >= 3) {
                datetime newsTime = StringToTime(parts[0]);
                string impact = parts[2];
                StringToLower(impact);
                if((impact == "high" || impact == "alto") &&
                   MathAbs((long)now - (long)newsTime) < p_newsVeto * 60) {
                    FileClose(h);
                    return true;
                }
            }
        }
        FileClose(h);
    }
    return false;
}

void CalculaStats() {
    double winRate = 0, drawdown = 0, profitFactor = 0;
    // Account history scan logic here
}

bool IsTimeAllowed() {
    string currentTime = TimeToString(TimeCurrent(), TIME_MINUTES);
    return (currentTime >= p_startTime);
}

// ---------- MQL5 EVENT HANDLERS ----------
int OnInit() {
    EventSetTimer(1);
    GravaLog("MT-LiveExecutor Iniciado.");
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
    GravaLog("MT-LiveExecutor Desligado. Motivo: " + IntegerToString(reason));
}

void OnTick() {
    GerenciaPosicoes();
    GravaCSV();

    // Check for new bar
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != lastBarTime) {
        lastBarTime = currentBar;
        if(IsTimeAllowed()) {
            Signal s = AvaliaTudo();
            if(s != NONE) EnviaOrdem(s);
        }
    }
}

void OnTimer() {
    // Read prompt.txt for real-time updates
    int h = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        string prompt = FileReadString(h);
        FileClose(h);
        if(prompt != "" && prompt != lastPrompt) {
            InterpretaPrompt(prompt);
        }
    }

    // AIOptimizer placeholder
    if(TimeCurrent() - lastAIUpdate >= 3600) {
        lastAIUpdate = TimeCurrent();
        // AIPredict and optimize...
    }
}
