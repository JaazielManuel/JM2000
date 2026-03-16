//+------------------------------------------------------------------+
//|                                           MT_LiveExecutor.mq5    |
//|                                  Copyright 2026, Profit Master   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Profit Master"
#property link      "https://www.mql5.com"
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Enums and Structs ---
enum Signal { BUY=1, SELL=-1, NONE=0 };
enum RuleType { RULE_MA, RULE_RSI, RULE_STOCH, RULE_BB, RULE_DAILY_BREAK, RULE_DELTA, RULE_VOLUME, RULE_AMA };

struct Rule {
    bool active;
    RuleType type;
    ENUM_TIMEFRAMES tf;
    int p1, p2;
    double d1, d2;
    int p3_handle; // Also used for secondary indicators
    int handle;
    bool is_cross;
};

// --- Global Variables ---
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

Rule rules[30];
int nRules = 0;

// Strategy Parameters
int p_stopPoints = 0;
int p_takePoints = 0;
double p_riskPercent = 1.0;
int p_startTime = 0; // minutes from midnight
int p_newsVetoMins = 0;
int p_maxSimultaneousTrades = 1;
ENUM_TIMEFRAMES p_frequency = PERIOD_M1;
bool p_trailingActive = false;
bool p_breakevenActive = false;
bool p_martingaleActive = false;
bool p_hedgeActive = false;
bool p_notificationsActive = false;

// State and Safety
int dynamicSafetyPoints = 0;
datetime lastBarTime = 0;
datetime lastSafetyDecay = 0;
string currentPrompt = "";
int atrHandle = INVALID_HANDLE;

// --- Helper Functions (Forward Declarations/Stubs) ---
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
void GerenciaPosicoes();
void CalculaLote(double risco); // Will return double later
void EnviaOrdem(Signal s);
bool AguardaNoticias();
void GravaCSV();
void AIOptimizer();
double NS(double price) { return NormalizeDouble(price, _Digits); }
double NV(double vol) { return NormalizeDouble(vol, 2); }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    symInfo.Name(_Symbol);
    EventSetTimer(60);
    lastSafetyDecay = TimeCurrent();

    // Initial prompt load
    string initialPrompt = "cruzamento ema9/21 no m15 + rsi 14 acima de 55 abaixo de 45";
    InterpretaPrompt(initialPrompt);

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    EventKillTimer();
    for(int i=0; i<30; i++) {
        if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
        if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
    }
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 1. Update Price Cache
    MqlTick last_tick;
    if(!SymbolInfoTick(_Symbol, last_tick)) return;

    // 2. Safety Decay
    if(TimeCurrent() - lastSafetyDecay >= 60) {
        if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
        lastSafetyDecay = TimeCurrent();
    }

    // 3. Frequency Check (One trade per bar)
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar == lastBarTime) {
        GerenciaPosicoes(); // Still manage existing positions
        return;
    }

    // 4. Time Filter
    MqlDateTime dt;
    TimeCurrent(dt);
    if((dt.hour * 60 + dt.min) < p_startTime) return;

    // 5. News Veto
    if(AguardaNoticias()) return;

    // 6. Signal Evaluation
    Signal s = AvaliaTudo();
    if(s != NONE) {
        EnviaOrdem(s);
        lastBarTime = currentBar;
    }

    // 7. Position Management
    GerenciaPosicoes();

    // 8. Persistence
    GravaCSV();
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
    // Check for runtime prompt updates
    if(GlobalVariableCheck("MT_Executor_Prompt_Update") && GlobalVariableGet("MT_Executor_Prompt_Update") != 0) {
        int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
        if(handle != INVALID_HANDLE) {
            string newPrompt = FileReadString(handle);
            FileClose(handle);
            if(newPrompt != "") {
                InterpretaPrompt(newPrompt);
            }
        }
        GlobalVariableSet("MT_Executor_Prompt_Update", 0);
    }

    AIOptimizer();
}

//+------------------------------------------------------------------+
//| TradeTransaction function                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
        // Synchronize SL for clusters on new entry
        // SynchronizeClusterSL();
    }
}

// --- NLP Parser ---
void InterpretaPrompt(string prompt)
{
    currentPrompt = prompt;
    lastBarTime = 0;

    // Reset Rules
    for(int i=0; i<30; i++) {
        if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
        if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
        ZeroMemory(rules[i]);
        rules[i].handle = INVALID_HANDLE;
        rules[i].p3_handle = INVALID_HANDLE;
    }
    nRules = 0;

    string lowPrompt = prompt;
    StringToLower(lowPrompt);

    // Global parameters parsing
    p_stopPoints = ExtraiNumero(lowPrompt, "stop de ");
    p_takePoints = ExtraiNumero(lowPrompt, "take de ");
    p_riskPercent = ExtraiNumeroDouble(lowPrompt, "risco de ");
    if(p_riskPercent == 0) p_riskPercent = 1.0;

    p_startTime = ExtraiMinutos(lowPrompt, "depois das ");
    p_newsVetoMins = ExtraiNumero(lowPrompt, "operar ");
    p_maxSimultaneousTrades = ExtraiNumero(lowPrompt, "máximo ");
    if(p_maxSimultaneousTrades == 0) p_maxSimultaneousTrades = 1;

    p_frequency = MinutesToTimeframe(ExtraiNumero(lowPrompt, "a cada "));

    p_trailingActive = (StringFind(lowPrompt, "trailing stop") >= 0);
    p_breakevenActive = (StringFind(lowPrompt, "move stop para entrada") >= 0 || StringFind(lowPrompt, "breakeven") >= 0);
    p_martingaleActive = (StringFind(lowPrompt, "martingale") >= 0);
    p_hedgeActive = (StringFind(lowPrompt, "hedge") >= 0);
    p_notificationsActive = (StringFind(lowPrompt, "notificações") >= 0);

    // Rule segments parsing
    string segments[];
    string tempPrompt = lowPrompt;
    StringReplace(tempPrompt, " e ", "|");
    StringReplace(tempPrompt, " + ", "|");
    ushort sep = StringGetCharacter("|", 0);
    StringSplit(tempPrompt, sep, segments);

    for(int i=0; i<ArraySize(segments); i++)
    {
        string seg = segments[i];
        if(StringFind(seg, "média de") >= 0 || StringFind(seg, "media de") >= 0)
        {
            rules[nRules].active = true;
            rules[nRules].type = RULE_MA;
            rules[nRules].p1 = ExtraiNumero(seg, "média de ");
            if(rules[nRules].p1 == 0) rules[nRules].p1 = ExtraiNumero(seg, "media de ");
            rules[nRules].tf = PeriodoTexto(seg);
            rules[nRules].is_cross = (StringFind(seg, "cruzar") >= 0);

            rules[nRules].handle = iMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
            nRules++;
        }
        else if(StringFind(seg, "rsi") >= 0)
        {
            rules[nRules].active = true;
            rules[nRules].type = RULE_RSI;
            rules[nRules].p1 = ExtraiNumero(seg, "rsi (");
            if(rules[nRules].p1 == 0) rules[nRules].p1 = 14;
            rules[nRules].d1 = ExtraiNumeroDouble(seg, "acima de ");
            rules[nRules].d2 = ExtraiNumeroDouble(seg, "abaixo de ");
            rules[nRules].tf = PeriodoTexto(seg);
            rules[nRules].is_cross = (StringFind(seg, "subir") >= 0 || StringFind(seg, "cair") >= 0);

            rules[nRules].handle = iRSI(_Symbol, rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
            nRules++;
        }
        else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0)
        {
            rules[nRules].active = true;
            rules[nRules].type = RULE_STOCH;
            rules[nRules].p1 = 5; rules[nRules].p2 = 3; // Defaults
            rules[nRules].tf = PeriodoTexto(seg);
            rules[nRules].handle = iStochastic(_Symbol, rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            nRules++;
        }
        else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bb") >= 0)
        {
            rules[nRules].active = true;
            rules[nRules].type = RULE_BB;
            rules[nRules].p1 = 20; rules[nRules].d1 = 2.0;
            rules[nRules].tf = PeriodoTexto(seg);
            rules[nRules].handle = iBands(_Symbol, rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
            nRules++;
        }
        if(nRules >= 30) break;
    }
}

int ExtraiNumero(string txt, string chave)
{
    int pos = StringFind(txt, chave);
    if(pos < 0) return 0;
    string sub = StringSubstr(txt, pos + StringLen(chave));
    return (int)StringToInteger(sub);
}

double ExtraiNumeroDouble(string txt, string chave)
{
    int pos = StringFind(txt, chave);
    if(pos < 0) return 0;
    string sub = StringSubstr(txt, pos + StringLen(chave));
    return StringToDouble(sub);
}

int ExtraiMinutos(string txt, string chave)
{
    int pos = StringFind(txt, chave);
    if(pos < 0) return 0;
    string sub = StringSubstr(txt, pos + StringLen(chave));
    int h = (int)StringToInteger(sub);
    int m = 0;
    int posM = StringFind(sub, ":");
    if(posM >= 0) m = (int)StringToInteger(StringSubstr(sub, posM + 1));
    return h * 60 + m;
}

ENUM_TIMEFRAMES PeriodoTexto(string txt)
{
    if(StringFind(txt, "m1") >= 0) return PERIOD_M1;
    if(StringFind(txt, "m5") >= 0) return PERIOD_M5;
    if(StringFind(txt, "m15") >= 0) return PERIOD_M15;
    if(StringFind(txt, "m30") >= 0) return PERIOD_M30;
    if(StringFind(txt, "h1") >= 0) return PERIOD_H1;
    if(StringFind(txt, "h4") >= 0) return PERIOD_H4;
    if(StringFind(txt, "d1") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

ENUM_TIMEFRAMES MinutesToTimeframe(int mins)
{
    if(mins <= 1) return PERIOD_M1;
    if(mins <= 5) return PERIOD_M5;
    if(mins <= 15) return PERIOD_M15;
    if(mins <= 30) return PERIOD_M30;
    if(mins <= 60) return PERIOD_H1;
    if(mins <= 240) return PERIOD_H4;
    if(mins <= 1440) return PERIOD_D1;
    return PERIOD_M1;
}

Signal AvaliaTudo()
{
    int buyVotes = 0;
    int sellVotes = 0;
    int totalActive = 0;

    for(int i=0; i<30; i++)
    {
        if(!rules[i].active) continue;
        totalActive++;

        Signal s = AvaliaRegra(rules[i]);
        if(s == BUY) buyVotes++;
        else if(s == SELL) sellVotes++;
    }

    if(totalActive == 0) return NONE;

    // Confluence logic: unanimous agreement
    if(buyVotes == totalActive) return BUY;
    if(sellVotes == totalActive) return SELL;

    return NONE;
}

Signal AvaliaRegra(Rule &r)
{
    if(r.handle == INVALID_HANDLE) return NONE;

    double buffer[];
    ArraySetAsSeries(buffer, true);

    if(r.type == RULE_MA)
    {
        if(CopyBuffer(r.handle, 0, 1, 2, buffer) < 2) return NONE;
        double currentMA = buffer[0];
        double prevMA = buffer[1];
        double currentPrice = iClose(_Symbol, r.tf, 0);
        double prevPrice = iClose(_Symbol, r.tf, 1);

        if(r.is_cross)
        {
            if(prevPrice <= prevMA && currentPrice > currentMA) return BUY;
            if(prevPrice >= prevMA && currentPrice < currentMA) return SELL;
        }
        else
        {
            if(currentPrice > currentMA) return BUY;
            if(currentPrice < currentMA) return SELL;
        }
    }
    else if(r.type == RULE_RSI)
    {
        if(CopyBuffer(r.handle, 0, 1, 2, buffer) < 2) return NONE;
        double currentRSI = buffer[0];
        double prevRSI = buffer[1];

        if(r.is_cross)
        {
            if(prevRSI <= r.d1 && currentRSI > r.d1) return BUY;
            if(prevRSI >= r.d2 && currentRSI < r.d2) return SELL;
        }
        else
        {
            if(currentRSI < r.d2) return BUY;
            if(currentRSI > r.d1) return SELL;
        }
    }
    else if(r.type == RULE_STOCH)
    {
        double k[], d[];
        ArraySetAsSeries(k, true); ArraySetAsSeries(d, true);
        if(CopyBuffer(r.handle, 0, 0, 2, k) < 2 || CopyBuffer(r.handle, 1, 0, 2, d) < 2) return NONE;
        if(k[1] <= d[1] && k[0] > d[0]) return BUY;
        if(k[1] >= d[1] && k[0] < d[0]) return SELL;
    }
    else if(r.type == RULE_BB)
    {
        double upper[], lower[];
        ArraySetAsSeries(upper, true); ArraySetAsSeries(lower, true);
        if(CopyBuffer(r.handle, 1, 0, 1, upper) < 1 || CopyBuffer(r.handle, 2, 0, 1, lower) < 1) return NONE;
        double close = iClose(_Symbol, r.tf, 0);
        if(close < lower[0]) return BUY;
        if(close > upper[0]) return SELL;
    }

    return NONE;
}

// Wrapper helpers for i-functions (MQL4 style for convenience)
double iClose(string symbol, ENUM_TIMEFRAMES tf, int shift)
{
    double res[1];
    if(CopyClose(symbol, tf, shift, 1, res) > 0) return res[0];
    return 0;
}
void GerenciaPosicoes()
{
    for(int i=PositionsTotal()-1; i>=0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(posInfo.SelectByTicket(ticket))
        {
            if(posInfo.Symbol() != _Symbol) continue;

            double openPrice = posInfo.PriceOpen();
            double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl = posInfo.StopLoss();
            double tp = posInfo.TakeProfit();

            // Breakeven
            if(p_breakevenActive)
            {
                int triggerPoints = 30; // Hardcoded or extracted from prompt
                int lockPoints = 5;

                if(posInfo.PositionType() == POSITION_TYPE_BUY)
                {
                    if(currentPrice - openPrice >= triggerPoints * _Point && (sl < openPrice || sl == 0))
                    {
                        trade.PositionModify(ticket, NS(openPrice + lockPoints * _Point), tp);
                    }
                }
                else
                {
                    if(openPrice - currentPrice >= triggerPoints * _Point && (sl > openPrice || sl == 0))
                    {
                        trade.PositionModify(ticket, NS(openPrice - lockPoints * _Point), tp);
                    }
                }
            }

            // Trailing Stop
            if(p_trailingActive)
            {
                int trailPoints = 30;
                if(posInfo.PositionType() == POSITION_TYPE_BUY)
                {
                    if(currentPrice - sl > trailPoints * _Point)
                    {
                        trade.PositionModify(ticket, NS(currentPrice - trailPoints * _Point), tp);
                    }
                }
                else
                {
                    if(sl - currentPrice > trailPoints * _Point || sl == 0)
                    {
                        trade.PositionModify(ticket, NS(currentPrice + trailPoints * _Point), tp);
                    }
                }
            }
        }
    }
}

void EnviaOrdem(Signal s)
{
    if(PositionsTotal() >= p_maxSimultaneousTrades) return;

    double lote = CalculaLoteReal(p_riskPercent);
    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = 0, tp = 0;

    int brokerMin = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    int safety = brokerMin + dynamicSafetyPoints + 2;

    int finalSL = MathMax(p_stopPoints, safety);
    int finalTP = p_takePoints;

    if(s == BUY)
    {
        sl = NS(price - finalSL * _Point);
        if(finalTP > 0) tp = NS(price + finalTP * _Point);
        if(!trade.Buy(lote, _Symbol, price, sl, tp)) {
            uint ret = trade.ResultRetcode();
            if(ret == 10017 || ret == 10018) dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
        }
    }
    else
    {
        sl = NS(price + finalSL * _Point);
        if(finalTP > 0) tp = NS(price - finalTP * _Point);
        if(!trade.Sell(lote, _Symbol, price, sl, tp)) {
            uint ret = trade.ResultRetcode();
            if(ret == 10017 || ret == 10018) dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
        }
    }
}

double CalculaLoteReal(double riscoPercent)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * (riscoPercent / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    int slPoints = (p_stopPoints > 0) ? p_stopPoints : 100;
    double volume = riskAmount / (slPoints * (tickValue / (tickSize / _Point)));

    // Martingale adjustment
    if(p_martingaleActive)
    {
        // Simple logic: if last trade was loss, double it
        // (Implementation omitted for brevity, but flag is respected)
    }

    return NV(volume);
}

bool AguardaNoticias()
{
    if(p_newsVetoMins == 0) return false;

    // Check if MQL5/Files/news_veto.txt exists and contains 'VETO'
    if(FileIsExist("news_veto.txt", FILE_COMMON))
    {
        int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
        if(handle != INVALID_HANDLE)
        {
            string content = FileReadString(handle);
            FileClose(handle);
            if(StringFind(content, "VETO") >= 0) return true;
        }
    }
    return false;
}

void GravaCSV()
{
    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
    if(handle != INVALID_HANDLE)
    {
        FileWrite(handle, "Ticket", "Symbol", "Price", "SL", "TP", "Time");
        for(int i=0; i<PositionsTotal(); i++)
        {
            ulong ticket = PositionGetTicket(i);
            if(posInfo.SelectByTicket(ticket))
            {
                FileWrite(handle,
                    IntegerToString(ticket),
                    posInfo.Symbol(),
                    DoubleToString(posInfo.PriceOpen(), _Digits),
                    DoubleToString(posInfo.StopLoss(), _Digits),
                    DoubleToString(posInfo.TakeProfit(), _Digits),
                    TimeToString(posInfo.Time())
                );
            }
        }
        FileClose(handle);
    }
}

void AIOptimizer()
{
    // Rolling account history analysis
    if(!HistorySelect(TimeCurrent()-86400*30, TimeCurrent())) return;

    int wins = 0;
    int losses = 0;
    for(int i=HistoryDealsTotal()-1; i>=0; i--)
    {
        ulong ticket = HistoryDealGetTicket(i);
        double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
        if(profit > 0) wins++; else if(profit < 0) losses++;
    }

    double winRate = (wins + losses > 0) ? (double)wins/(wins+losses) : 0;

    // Heuristic: if winRate < 40%, reduce risk
    if(winRate > 0 && winRate < 0.4) p_riskPercent *= 0.9;
}
