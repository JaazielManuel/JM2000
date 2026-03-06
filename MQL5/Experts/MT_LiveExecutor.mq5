//+------------------------------------------------------------------+
//|                                             MT_LiveExecutor.mq5  |
//|                                  Copyright 2026, Jules (Bolt)    |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Jules (Bolt)"
#property link      "https://www.mql5.com"
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

//--- ENUMS
enum ENUM_SIGNAL { SIGNAL_BUY = 1, SIGNAL_SELL = -1, SIGNAL_NONE = 0 };

//--- STRUCTS
struct Rule {
    bool         active;
    ENUM_TIMEFRAMES tf;
    int          p1, p2, p3;
    double       d1, d2;
    string       s1;
    int          handle;
    ENUM_SIGNAL (*func)(Rule&);
};

//--- INPUTS
input string InpPrompt = "A cada 15 minutos, compra se o preço cruzar acima da média de 20 e RSI(14) > 55. Stop 30, Take 50.";

//--- GLOBALS
CTrade         m_trade;
CPositionInfo  m_pos;
CSymbolInfo    m_symbol;
CAccountInfo   m_account;
Rule           rules[30];
int            nRules = 0;
string         lastPrompt = "";

// Strategy Parameters
int            p_stopPoints = 300;
int            p_takePoints = 500;
double         p_riskPercent = 1.0;
int            p_maxSimultaneous = 3;
int            p_startTimeHour = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

int            dynamicSafetyPoints = 0;
datetime       lastSafetyDecay = 0;
MqlTick        currentTick;
datetime       lastBarTime = 0;
datetime       lastTradeTime = 0;

//--- FUNCTIONS PROTOTYPES
void InterpretaPrompt(string prompt);
void AddRule(string txt);
ENUM_TIMEFRAMES PeriodoTexto(string nome);
double ExtraiNumero(string txt, string prefixo);

ENUM_SIGNAL CruzamentoMA(Rule &r);
ENUM_SIGNAL RSIThreshold(Rule &r);
ENUM_SIGNAL StochCross(Rule &r);
ENUM_SIGNAL BBounce(Rule &r);

ENUM_SIGNAL AvaliaTudo();
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
double CalculaLote(double riscoPercent, int stopPoints);
void AIOptimizer();
double NS(double price) { return NormalizeDouble(price, (int)m_symbol.Digits()); }
double NV(double vol) { return NormalizeDouble(vol, 2); }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    if(!m_symbol.Name(_Symbol)) return INIT_FAILED;
    m_symbol.Refresh();

    InterpretaPrompt(InpPrompt);
    lastPrompt = InpPrompt;
    lastSafetyDecay = TimeCurrent();

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    for(int i=0; i<nRules; i++) {
        if(rules[i].handle != INVALID_HANDLE) {
            IndicatorRelease(rules[i].handle);
        }
    }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES PeriodoTexto(string nome)
{
    nome = StringToLower(nome);
    if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
    if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
    if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
    if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
    if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
    return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, string prefixo)
{
    int pos = StringFind(txt, prefixo);
    if(pos < 0) return 0;
    string sub = StringSubstr(txt, pos + StringLen(prefixo));
    return StringToDouble(sub);
}

//+------------------------------------------------------------------+
//| Prompt Interpreter                                               |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt)
{
    // Clean up old handles
    for(int i=0; i<nRules; i++) {
        if(rules[i].handle != INVALID_HANDLE) IndicatorRelease(rules[i].handle);
    }

    ZeroMemory(rules);
    nRules = 0;

    // Default parameters
    p_stopPoints = 300;
    p_takePoints = 500;
    p_riskPercent = 1.0;
    p_maxSimultaneous = 3;
    p_startTimeHour = 0;
    p_frequency = PERIOD_CURRENT;

    string promptLower = StringToLower(prompt);

    // Extract Global Params
    p_stopPoints = (int)ExtraiNumero(promptLower, "stop de ");
    if(p_stopPoints == 0) p_stopPoints = (int)ExtraiNumero(promptLower, "stop ");

    p_takePoints = (int)ExtraiNumero(promptLower, "take de ");
    if(p_takePoints == 0) p_takePoints = (int)ExtraiNumero(promptLower, "take ");

    p_riskPercent = ExtraiNumero(promptLower, "risco de ");
    if(p_riskPercent == 0) p_riskPercent = 1.0;

    p_maxSimultaneous = (int)ExtraiNumero(promptLower, "máximo ");
    if(p_maxSimultaneous == 0) p_maxSimultaneous = 3;

    p_startTimeHour = (int)ExtraiNumero(promptLower, "depois das ");

    if(StringFind(promptLower, "a cada 15 minutos") >= 0) p_frequency = PERIOD_M15;
    else if(StringFind(promptLower, "a cada 5 minutos") >= 0) p_frequency = PERIOD_M5;

    string parts[];
    int n = StringSplit(prompt, '+', parts);
    if(n == 0) { // Try period or other separators
        n = StringSplit(prompt, '.', parts);
    }
    if(n == 0) { // Just one rule or comma
        n = StringSplit(prompt, ',', parts);
    }

    if(n > 0) {
        for(int i=0; i<n; i++) AddRule(parts[i]);
    } else {
        AddRule(prompt);
    }

    PrintFormat("MT-LiveExecutor: Prompt interpretado. %d regras ativas.", nRules);
}

void AddRule(string txt)
{
    txt = StringToLower(txt);

    // MA Cross
    if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
        if(nRules >= 30) return;
        Rule r;
        r.active = true;
        r.tf = PeriodoTexto(txt);
        r.handle = INVALID_HANDLE;
        r.p1 = (int)ExtraiNumero(txt, "média de ");
        if(r.p1 == 0) r.p1 = (int)ExtraiNumero(txt, "ma");
        if(r.p1 == 0) r.p1 = 20;

        r.p2 = 0;
        int slashPos = StringFind(txt, "/");
        if(slashPos > 0) r.p2 = (int)StringToInteger(StringSubstr(txt, slashPos+1));

        r.func = &CruzamentoMA;
        rules[nRules++] = r;
    }

    // RSI
    if(StringFind(txt, "rsi") >= 0) {
        if(nRules >= 30) return;
        Rule r;
        r.active = true;
        r.tf = PeriodoTexto(txt);
        r.handle = INVALID_HANDLE;
        r.p1 = (int)ExtraiNumero(txt, "rsi(");
        if(r.p1 == 0) r.p1 = (int)ExtraiNumero(txt, "rsi ");
        if(r.p1 == 0) r.p1 = 14;

        r.d1 = ExtraiNumero(txt, "> ");
        if(r.d1 == 0) r.d1 = ExtraiNumero(txt, "acima de ");
        if(r.d1 == 0) r.d1 = ExtraiNumero(txt, "subir acima de ");
        if(r.d1 == 0) r.d1 = 55;

        r.d2 = ExtraiNumero(txt, "< ");
        if(r.d2 == 0) r.d2 = ExtraiNumero(txt, "abaixo de ");
        if(r.d2 == 0) r.d2 = ExtraiNumero(txt, "cair abaixo de ");
        if(r.d2 == 0) r.d2 = 45;

        r.func = &RSIThreshold;
        rules[nRules++] = r;
    }
}

//+------------------------------------------------------------------+
//| Signals Implementation                                           |
//+------------------------------------------------------------------+
ENUM_SIGNAL CruzamentoMA(Rule &r)
{
    if(r.handle == INVALID_HANDLE) {
        r.handle = iMA(_Symbol, r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
    }

    double ma[2], close[2];
    if(CopyBuffer(r.handle, 0, 0, 2, ma) < 2) return SIGNAL_NONE;
    if(CopyClose(_Symbol, r.tf, 0, 2, close) < 2) return SIGNAL_NONE;

    if(close[1] <= ma[1] && close[0] > ma[0]) return SIGNAL_BUY;
    if(close[1] >= ma[1] && close[0] < ma[0]) return SIGNAL_SELL;

    return SIGNAL_NONE;
}

ENUM_SIGNAL RSIThreshold(Rule &r)
{
    if(r.handle == INVALID_HANDLE) {
        r.handle = iRSI(_Symbol, r.tf, r.p1, PRICE_CLOSE);
    }

    double rsi[2];
    if(CopyBuffer(r.handle, 0, 0, 2, rsi) < 2) return SIGNAL_NONE;

    // Logic based on prompt entry thresholds
    if(rsi[1] <= r.d1 && rsi[0] > r.d1) return SIGNAL_BUY;  // RSI rising above entry threshold
    if(rsi[1] >= r.d2 && rsi[0] < r.d2) return SIGNAL_SELL; // RSI falling below entry threshold

    return SIGNAL_NONE;
}

ENUM_SIGNAL StochCross(Rule &r) { return SIGNAL_NONE; }
ENUM_SIGNAL BBounce(Rule &r) { return SIGNAL_NONE; }

//+------------------------------------------------------------------+
//| Final Decision                                                   |
//+------------------------------------------------------------------+
ENUM_SIGNAL AvaliaTudo()
{
    int buyVotes = 0, sellVotes = 0;
    int totalActive = 0;

    for(int i=0; i<nRules; i++) {
        if(rules[i].active && rules[i].func != NULL) {
            totalActive++;
            ENUM_SIGNAL s = rules[i].func(rules[i]);
            if(s == SIGNAL_BUY) buyVotes++;
            if(s == SIGNAL_SELL) sellVotes++;
        }
    }

    if(totalActive == 0) return SIGNAL_NONE;

    // Unanimous or majority logic
    if(buyVotes == totalActive) return SIGNAL_BUY;
    if(sellVotes == totalActive) return SIGNAL_SELL;

    return SIGNAL_NONE;
}

//+------------------------------------------------------------------+
//| Trade Management                                                 |
//+------------------------------------------------------------------+
void GerenciaPosicoes()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(ticket > 0 && m_pos.SelectByTicket(ticket)) {
            if(m_pos.Symbol() == _Symbol) {
                // Breakeven logic
                double priceIn = m_pos.PriceOpen();
                double currentPrice = (m_pos.PositionType() == POSITION_TYPE_BUY) ? currentTick.bid : currentTick.ask;
                double points = (m_pos.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - priceIn) : (priceIn - currentPrice);
                points /= _Point;

                if(points >= 30 && m_pos.StopLoss() != NS(priceIn + (m_pos.PositionType() == POSITION_TYPE_BUY ? 5 : -5) * _Point)) {
                    double newSL = NS(priceIn + (m_pos.PositionType() == POSITION_TYPE_BUY ? 5 : -5) * _Point);
                    if(m_trade.PositionModify(m_pos.Ticket(), newSL, m_pos.TakeProfit())) {
                        GravaLog(StringFormat("Breakeven acionado para ticket %d", m_pos.Ticket()));
                    }
                }
            }
        }
    }
}

bool AguardaNoticias()
{
    // Simplified news filter using MQL5 Calendar
    MqlCalendarValue values[];
    datetime from = TimeCurrent() - 20 * 60;
    datetime to = TimeCurrent() + 20 * 60;

    if(CalendarValueHistory(values, from, to, _Symbol)) {
        for(int i=0; i<ArraySize(values); i++) {
            if(values[i].importance == CALENDAR_IMPORTANCE_HIGH) return true;
        }
    }
    return false;
}

void AIOptimizer()
{
    // Heuristic for volatility adjustment
    int atrHandle = iATR(_Symbol, PERIOD_H1, 14);
    double atr[];
    if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
        PrintFormat("AI Optimizer: ATR H1 atual é %.5f. Sugerindo stop condizente.", atr[0]);
    }
    IndicatorRelease(atrHandle);
}

void GravaLog(string texto)
{
    int handle = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()), texto);
        FileClose(handle);
    }
    Print("LOG: ", texto);
}

double CalculaLote(double riscoPercent, int stopPoints)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * (riscoPercent / 100.0);
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(stopPoints <= 0) stopPoints = 300; // default points

    double lot = riskAmount / (stopPoints * _Point * (tickValue / tickSize));
    return NV(lot);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!SymbolInfoTick(_Symbol, currentTick)) return;

    // Check for prompt update
    if(InpPrompt != lastPrompt) {
        InterpretaPrompt(InpPrompt);
        lastPrompt = InpPrompt;
        lastBarTime = 0; // Reset bar detection for new logic
    }

    // Safety points decay
    if(TimeCurrent() - lastSafetyDecay >= 60) {
        if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
        lastSafetyDecay = TimeCurrent();
    }

    // New Bar detection based on requested frequency
    ENUM_TIMEFRAMES activeTF = (p_frequency == PERIOD_CURRENT) ? PERIOD_M1 : p_frequency;
    datetime barTime = iTime(_Symbol, activeTF, 0);
    if(barTime == lastBarTime && p_frequency != PERIOD_CURRENT) return; // Wait for next candle if frequency is set

    // Time Filter
    MqlDateTime dt;
    TimeCurrent(dt);
    if(dt.hour < p_startTimeHour) return;

    // News Filter
    if(AguardaNoticias()) return;

    // Final check for max trades
    if(PositionsTotal() >= p_maxSimultaneous) return;

    ENUM_SIGNAL signal = AvaliaTudo();
    if(signal != SIGNAL_NONE && barTime != lastBarTime) { // One trade per bar if frequency specified
        double lot = CalculaLote(p_riskPercent, p_stopPoints);
        double sl = 0, tp = 0;

        int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
        int safetyBuffer = stopLevel + dynamicSafetyPoints + 2;

        if(signal == SIGNAL_BUY) {
            sl = NS(currentTick.ask - MathMax(p_stopPoints, safetyBuffer) * _Point);
            tp = NS(currentTick.ask + p_takePoints * _Point);
            if(m_trade.Buy(lot, _Symbol, currentTick.ask, sl, tp)) {
                GravaLog("Compra executada via sinal de prompt");
                lastBarTime = barTime;
                lastTradeTime = TimeCurrent();
            } else {
                PrintFormat("Erro na compra: %d. Aumentando safety points.", m_trade.ResultRetcode());
                dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
            }
        }
        else if(signal == SIGNAL_SELL) {
            sl = NS(currentTick.bid + MathMax(p_stopPoints, safetyBuffer) * _Point);
            tp = NS(currentTick.bid - p_takePoints * _Point);
            if(m_trade.Sell(lot, _Symbol, currentTick.bid, sl, tp)) {
                GravaLog("Venda executada via sinal de prompt");
                lastBarTime = barTime;
                lastTradeTime = TimeCurrent();
            } else {
                PrintFormat("Erro na venda: %d. Aumentando safety points.", m_trade.ResultRetcode());
                dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
            }
        }
    }

    GerenciaPosicoes();
}
