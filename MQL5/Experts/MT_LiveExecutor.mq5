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

//--- DEFINES
#define EA_MAGIC 123456

//--- ENUMS
enum Signal {BUY=1, SELL=-1, NONE=0};

//--- STRUCTS
struct Rule {
    bool     active;
    int      type;   // 1=MA, 2=RSI, 3=STOCH, 4=BB, 5=DAILY, 6=DELTA, 7=VOLUME, 8=AMA, 9=BAR2, 10=RELATIVE
    int      intent; // 1=BUY, -1=SELL
    ENUM_TIMEFRAMES tf;
    int      p1, p2, p3;
    double   d1, d2;
    string   s1;
    int      handle1, handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
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

//--- GLOBALS
Rule rules[20];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

string p_strategyName = "MT-LiveExecutor Strategy";
double p_riskPercent = 1.0;
int p_stopLoss = 300; // points
int p_takeProfit = 500; // points
int p_maxTrades = 3;
string p_startTime = "00:00";
bool p_martingale = false;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
int p_newsVeto = 20; // minutes
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime lastPromptUpdate = 0;
datetime lastAI = 0;
datetime lastCSV = 0;

//--- FUNCTIONS PROTOTYPES
void InterpretaPrompt(string prompt);
void AddRule(string txt, int intent);
Signal AvaliaTudo();
Signal AvaliaRegra(Rule &r);
void EnviaOrdem(Signal s, string reason);
void GerenciaPosicoes();
double CalculaLote(double risco);
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
void ResetStrategy();
double GetBufferValue(int handle, int buffer, int shift);
double ExtraiNumero(string txt, int &cursor);
ENUM_TIMEFRAMES PeriodoTexto(string nome);
bool IsTimeAllowed();
void CalculaStats();

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    trade.SetExpertMagicNumber(EA_MAGIC);
    symInfo.Name(_Symbol);

    EventSetTimer(1); // 1 second timer for prompt monitoring

    ResetStrategy();
    GravaLog("MT-LiveExecutor Iniciado.");

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    ResetStrategy();
    EventKillTimer();
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    GerenciaPosicoes();

    if(TimeCurrent() - lastCSV >= 5) {
        GravaCSV();
        lastCSV = TimeCurrent();
    }

    // Evaluate signals only on new bar of p_frequency
    static datetime lastBar = 0;
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar != lastBar) {
        if(IsTimeAllowed() && !AguardaNoticias()) {
            Signal s = AvaliaTudo();
            if(s != NONE) {
                EnviaOrdem(s, "Estratégia NLP");
            }
        }
        lastBar = currentBar;
    }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
    // Check for prompt updates
    string promptFile = "prompt.txt";
    if(FileIsExist(promptFile, FILE_COMMON)) {
        datetime modTime = (datetime)FileGetInteger(promptFile, FILE_MODIFY_DATE, FILE_COMMON);
        if(modTime > lastPromptUpdate) {
            int h = FileOpen(promptFile, FILE_READ|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
            if(h != INVALID_HANDLE) {
                string content = "";
                while(!FileIsEnding(h)) content += FileReadString(h);
                FileClose(h);

                if(content != "") {
                    InterpretaPrompt(content);
                    lastPromptUpdate = modTime;
                }
            }
        }
    }

    // AI Optimizer - every hour
    if(TimeCurrent() - lastAI >= 3600) {
        CalculaStats();
        lastAI = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
//| NLP Parser functions                                             |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt)
{
    ResetStrategy();
    GravaLog("Interpretando prompt: " + prompt);

    string work = prompt;
    StringToLower(work);
    StringReplace(work, " e ", ".");

    string segments[];
    int n = StringSplit(work, '.', segments);

    int currentIntent = 0; // 0=none, 1=buy, -1=sell

    for(int i=0; i<n; i++) {
        string txt = segments[i];
        StringTrimLeft(txt);
        StringTrimRight(txt);

        if(txt == "") continue;

        // Identify global parameters
        int cursor = 0;
        if(StringFind(txt, "risco") >= 0) {
            cursor = StringFind(txt, "risco");
            p_riskPercent = ExtraiNumero(txt, cursor);
        }
        if(StringFind(txt, "stop") >= 0 && StringFind(txt, "move") < 0) {
            cursor = StringFind(txt, "stop");
            p_stopLoss = (int)ExtraiNumero(txt, cursor);
        }
        if(StringFind(txt, "take") >= 0) {
            cursor = StringFind(txt, "take");
            p_takeProfit = (int)ExtraiNumero(txt, cursor);
        }
        if(StringFind(txt, "máximo") >= 0) {
            cursor = StringFind(txt, "máximo");
            p_maxTrades = (int)ExtraiNumero(txt, cursor);
        }
        if(StringFind(txt, "martingale") >= 0) p_martingale = true;

        if(StringFind(txt, "atingir") >= 0) {
            cursor = StringFind(txt, "atingir");
            p_beStart = (int)ExtraiNumero(txt, cursor);
            if(StringFind(txt, "entrada") >= 0) {
                cursor = StringFind(txt, "entrada");
                p_bePlus = (int)ExtraiNumero(txt, cursor);
            }
        }

        if(StringFind(txt, "trailing") >= 0) {
            cursor = StringFind(txt, "trailing");
            p_trailingStop = (int)ExtraiNumero(txt, cursor);
            p_trailingStep = 10; // default
        }

        if(StringFind(txt, "notícias") >= 0) {
            cursor = StringFind(txt, "notícias");
            p_newsVeto = (int)ExtraiNumero(txt, cursor);
            if(p_newsVeto == 0) p_newsVeto = 20;
        }

        if(StringFind(txt, "depois das") >= 0 || StringFind(txt, "início") >= 0 || StringFind(txt, "começar") >= 0) {
            int hPos = StringFind(txt, "h");
            if(hPos > 0) {
                int c = hPos - 2; if(c < 0) c = 0;
                double hh = ExtraiNumero(txt, c);
                p_startTime = IntegerToString((int)hh, 2, '0') + ":00";
            }
        }

        // Timeframe detection
        if(StringFind(txt, "minutos") >= 0 || StringFind(txt, "min") >= 0) {
            int c = 0;
            double tfVal = ExtraiNumero(txt, c);
            if(tfVal == 1) p_frequency = PERIOD_M1;
            else if(tfVal == 5) p_frequency = PERIOD_M5;
            else if(tfVal == 15) p_frequency = PERIOD_M15;
            else if(tfVal == 30) p_frequency = PERIOD_M30;
        }

        // Strategy Intent
        if(StringFind(txt, "compra") >= 0) currentIntent = 1;
        else if(StringFind(txt, "vende") >= 0) currentIntent = -1;

        if(currentIntent != 0) {
            AddRule(txt, currentIntent);
        }
    }

    GravaLog("Interpretação concluída. Regras: " + IntegerToString(nRules));
}

void AddRule(string txt, int intent)
{
    if(nRules >= 20) return;

    Rule r;
    r.Reset();
    r.intent = intent;
    r.tf = p_frequency;

    bool found = false;

    if(StringFind(txt, "média") >= 0) {
        r.type = 1;
        int cursor = StringFind(txt, "média") + 5;
        r.p1 = (int)ExtraiNumero(txt, cursor);
        if(r.p1 == 0) r.p1 = 20;
        r.handle1 = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) found = true;
    }

    if(StringFind(txt, "rsi") >= 0) {
        r.type = 2;
        int cursor = StringFind(txt, "rsi") + 3;
        double v1 = ExtraiNumero(txt, cursor);
        double v2 = ExtraiNumero(txt, cursor);

        if(v2 == 0) { // Only one number found
            r.p1 = 14; // default period
            r.d1 = v1; // threshold
        } else {
            r.p1 = (int)v1;
            r.d1 = v2;
        }
        r.handle1 = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) found = true;
    }

    if(StringFind(txt, "estocástico") >= 0) {
        r.type = 3;
        r.handle1 = iStochastic(_Symbol, r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
        if(r.handle1 != INVALID_HANDLE) found = true;
    }

    if(StringFind(txt, "bollinger") >= 0) {
        r.type = 4;
        r.handle1 = iBands(_Symbol, r.tf, 20, 0, 2.0, PRICE_CLOSE);
        if(r.handle1 != INVALID_HANDLE) found = true;
    }

    if(StringFind(txt, "delta") >= 0) {
        r.type = 6;
        int cursor = StringFind(txt, "delta") + 5;
        r.p1 = (int)ExtraiNumero(txt, cursor); if(r.p1 == 0) r.p1 = 60;
        r.p2 = (int)ExtraiNumero(txt, cursor); if(r.p2 == 0) r.p2 = 300;
        found = true;
    }

    if(found) {
        r.active = true;
        rules[nRules] = r;
        nRules++;
    }
}

double ExtraiNumero(string txt, int &cursor)
{
    string res = "";
    bool found = false;
    for(int i=cursor; i<StringLen(txt); i++) {
        ushort c = StringGetCharacter(txt, i);
        if((c >= '0' && c <= '9') || c == '.' || c == ',') {
            if(c == ',') res += "."; else res += ShortToString(c);
            found = true;
        } else if(found) {
            cursor = i;
            break;
        }
    }
    return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome)
{
    string n = nome;
    StringToLower(n);
    if(StringFind(n, "m15") >= 0) return PERIOD_M15;
    if(StringFind(n, "m1") >= 0)  return PERIOD_M1;
    if(StringFind(n, "m5") >= 0)  return PERIOD_M5;
    if(StringFind(n, "m30") >= 0) return PERIOD_M30;
    if(StringFind(n, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(n, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

//+------------------------------------------------------------------+
//| Signal Evaluation functions                                      |
//+------------------------------------------------------------------+
Signal AvaliaTudo()
{
    int buys = 0;
    int sells = 0;
    int buyRules = 0;
    int sellRules = 0;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;

        Signal s = AvaliaRegra(rules[i]);

        if(rules[i].intent == 1) {
            buyRules++;
            if(s == BUY) buys++;
        } else if(rules[i].intent == -1) {
            sellRules++;
            if(s == SELL) sells++;
        }
    }

    if(buyRules > 0 && buys == buyRules) return BUY;
    if(sellRules > 0 && sells == sellRules) return SELL;

    return NONE;
}

Signal AvaliaRegra(Rule &r)
{
    if(r.type == 1) { // MA
        double ma1 = GetBufferValue(r.handle1, 0, 1);
        double ma2 = GetBufferValue(r.handle1, 0, 2);
        double c1 = iClose(_Symbol, r.tf, 1);
        double c2 = iClose(_Symbol, r.tf, 2);

        if(r.intent == 1 && c2 < ma2 && c1 > ma1) return BUY;
        if(r.intent == -1 && c2 > ma2 && c1 < ma1) return SELL;
    }
    else if(r.type == 2) { // RSI
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);

        if(r.intent == 1 && rsi2 < r.d1 && rsi1 > r.d1) return BUY;
        if(r.intent == -1 && rsi2 > r.d1 && rsi1 < r.d1) return SELL;
    }
    else if(r.type == 3) { // Stochastic
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);

        if(r.intent == 1 && k2 < d2 && k1 > d1) return BUY;
        if(r.intent == -1 && k2 > d2 && k1 < d1) return SELL;
    }
    else if(r.type == 4) { // Bollinger Bands
        double up1 = GetBufferValue(r.handle1, 1, 1);
        double lo1 = GetBufferValue(r.handle1, 2, 1);
        double c1 = iClose(_Symbol, r.tf, 1);

        if(r.intent == 1 && c1 < lo1) return BUY;
        if(r.intent == -1 && c1 > up1) return SELL;
    }
    else if(r.type == 6) { // Delta Aggression
        MqlTick arr[];
        int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
        long buy = 0, sell = 0;
        for(int i=0; i<n; i++) if((arr[i].flags & TICK_FLAG_BUY) != 0) buy++; else if((arr[i].flags & TICK_FLAG_SELL) != 0) sell++;
        long delta = buy - sell;

        if(r.intent == 1 && delta > r.p2) return BUY;
        if(r.intent == -1 && delta < -r.p2) return SELL;
    }

    return NONE;
}

double GetBufferValue(int handle, int buffer, int shift)
{
    double arr[];
    ArraySetAsSeries(arr, true);
    if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
    return 0;
}

//+------------------------------------------------------------------+
//| Trade and Position Management                                    |
//+------------------------------------------------------------------+
void EnviaOrdem(Signal s, string reason)
{
    if(PositionsTotal() >= p_maxTrades) return;

    double lote = CalculaLote(p_riskPercent);
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (s == BUY) ? price - p_stopLoss * _Point : price + p_stopLoss * _Point;
    double tp = (s == BUY) ? price + p_takeProfit * _Point : price - p_takeProfit * _Point;

    bool res = false;
    for(int i=0; i<3; i++) {
        if(s == BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, reason);
        else res = trade.Sell(lote, _Symbol, price, sl, tp, reason);

        if(res) {
            GravaLog("Ordem enviada: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2));
            SendNotification("Trade Executado: " + EnumToString(s));
            break;
        } else {
            uint code = trade.ResultRetcode();
            if(code == TRADE_RETCODE_REQUOTES || code == TRADE_RETCODE_OFFQUOTES) {
                price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
                continue;
            }
            GravaLog("Erro ao enviar ordem: " + IntegerToString(code));
            break;
        }
    }
}

void GerenciaPosicoes()
{
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

            double openPrice = posInfo.PriceOpen();
            double curPrice = posInfo.PriceCurrent();
            double sl = posInfo.StopLoss();
            double profitPoints = MathAbs(curPrice - openPrice) / _Point;

            // Breakeven
            if(p_beStart > 0 && profitPoints >= p_beStart && sl != openPrice + (posInfo.PositionType() == POSITION_TYPE_BUY ? p_bePlus * _Point : -p_bePlus * _Point)) {
                double newSL = openPrice + (posInfo.PositionType() == POSITION_TYPE_BUY ? p_bePlus * _Point : -p_bePlus * _Point);
                trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
                double newSL = curPrice + (posInfo.PositionType() == POSITION_TYPE_BUY ? -p_trailingStop * _Point : p_trailingStop * _Point);
                if(posInfo.PositionType() == POSITION_TYPE_BUY && newSL > sl) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                else if(posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < sl || sl == 0)) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
        }
    }
}

double CalculaLote(double risco)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(p_martingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i=total-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
                double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                if(profit < 0) risco *= 2;
                break;
            }
        }
    }

    double riskAmount = balance * (risco / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(p_stopLoss == 0 || tickValue == 0) return 0.1;

    double lot = riskAmount / ((p_stopLoss * _Point / tickSize) * tickValue);
    return NormalizeDouble(lot, 2);
}

bool IsTimeAllowed()
{
    datetime now = TimeCurrent();
    string curTime = TimeToString(now, TIME_MINUTES);
    return (curTime >= p_startTime);
}

bool AguardaNoticias()
{
    // News veto via file
    if(FileIsExist("news_veto.txt", FILE_COMMON)) {
        int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
        if(h != INVALID_HANDLE) {
            string content = FileReadString(h);
            FileClose(h);
            if(content == "1" || content == "true") return true;
        }
    }

    // Calendar check (simplified)
    if(FileIsExist("calendar.txt", FILE_COMMON)) {
        int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
        if(h != INVALID_HANDLE) {
            while(!FileIsEnding(h)) {
                string line = FileReadString(h);
                if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
                    // Extract time and compare with veto window
                    int cursor = 0;
                    double hh = ExtraiNumero(line, cursor);
                    double mm = ExtraiNumero(line, cursor);
                    // ... comparison logic ...
                }
            }
            FileClose(h);
        }
    }

    return false;
}

void GravaLog(string texto)
{
    Print(texto);
    int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON|FILE_SHARE_READ);
    if(h != INVALID_HANDLE) {
        FileSeek(h, 0, SEEK_END);
        FileWriteString(h, TimeToString(TimeCurrent()) + ": " + texto + "\n");
        FileClose(h);
    }
}

void GravaCSV()
{
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON|FILE_ANSI);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit");
        for(int i=0; i<PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
                FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
            }
        }
        FileClose(h);
    }
}

void CalculaStats()
{
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, losses = 0;
    double netProfit = 0;

    for(int i=0; i<total; i++) {
        ulong t = HistoryDealGetTicket(i);
        if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT);
            netProfit += p;
            if(p > 0) wins++; else if(p < 0) losses++;
        }
    }

    double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100 : 0;
    GravaLog("Stats Atualizadas - WinRate: " + DoubleToString(winRate, 2) + "% NetProfit: " + DoubleToString(netProfit, 2));
}

void ResetStrategy() {
    for(int i=0; i<20; i++) rules[i].Reset();
    nRules = 0;
    // Reset global params to defaults
    p_riskPercent = 1.0;
    p_stopLoss = 300;
    p_takeProfit = 500;
    p_maxTrades = 3;
    p_startTime = "00:00";
    p_martingale = false;
    p_beStart = 0;
    p_bePlus = 0;
    p_trailingStop = 0;
    p_trailingStep = 0;
}
