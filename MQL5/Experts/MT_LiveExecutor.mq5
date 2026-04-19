//=========================  MT-LiveExecutor  =========================
// MT-LiveExecutor.mq5
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Constants ---
#define EA_MAGIC 123456

// --- Enums ---
enum Signal {BUY=1, SELL=-1, NONE=0};

// --- Structs ---
struct Rule {
   bool     active;
   int      tf;
   int      p1_handle, p2_handle;
   int      period1, period2;
   double   threshold1, threshold2;
   string   s1;
   Signal   intent; // BUY, SELL or NONE (filter)
};

// --- Global Variables ---
Rule p_rules[30];
int p_nRules = 0;
string p_lastPrompt = "";

// Strategy Parameters
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStart = 0;
int p_trailingStep = 10;
bool p_useMartingale = false;

// Time Filters
int p_startTimeSeconds = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;
datetime p_lastBarTime = 0;

// Internal State
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// --- Forward Declarations ---
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
double CalculaLote(double risco);
void EnviaOrdem(Signal s, string reason);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaCSV();
void GravaLog(string text);
void CalculaEstatisticas();
void AIOptimizer();
void ResetStrategy();

// Utility functions
double ExtraiNumero(string txt, int startPos=0);
double ExtraiValorApos(string txt, string keyword);
int PeriodoTexto(string nome);
string ExtractTime(string txt);

// Indicator signal functions
Signal CruzamentoMA(int rIdx, int shift);
Signal RSIThreshold(int rIdx, int shift);
Signal StochCross(int rIdx, int shift);
Signal BBounce(int rIdx, int shift);
Signal DailyBreak(int rIdx, int shift);
Signal DeltaAggression(int rIdx, int shift);
Signal VolumeCycle(int rIdx, int shift);
Signal AMA(int rIdx, int shift);
Signal Bar2Pattern(int rIdx, int shift);
Signal RSRelative(int rIdx, int shift);

// Helper
double GetBufferValue(int handle, int buffer, int shift);

// --- NLP Helpers ---

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

int PeriodoTexto(string nome) {
    StringToLower(nome);
    if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
    if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
    if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
    if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
    if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
    if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
    if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
    if(StringFind(nome, "minutos") >= 0 || StringFind(nome, "min") >= 0) {
        double m = ExtraiNumero(nome);
        if(m == 1) return PERIOD_M1;
        if(m == 5) return PERIOD_M5;
        if(m == 15) return PERIOD_M15;
        if(m == 30) return PERIOD_M30;
    }
    return PERIOD_CURRENT;
}

string ExtractTime(string txt) {
    string t = txt;
    StringReplace(t, "h", ":00");
    // Simple regex-like extraction for HH:MM
    int pos = StringFind(t, ":");
    if(pos > 0) {
        string hh = StringSubstr(t, pos-2, 2);
        string mm = StringSubstr(t, pos+1, 2);
        return hh + ":" + mm;
    }
    return "";
}

// --- Strategy Parser ---

void ResetStrategy() {
    for(int i=0; i<p_nRules; i++) {
        if(p_rules[i].p1_handle != INVALID_HANDLE && p_rules[i].p1_handle != 0) IndicatorRelease(p_rules[i].p1_handle);
        if(p_rules[i].p2_handle != INVALID_HANDLE && p_rules[i].p2_handle != 0) IndicatorRelease(p_rules[i].p2_handle);
        p_rules[i].active = false;
    }
    p_nRules = 0;
    p_riskPercent = 1.0;
    p_stopPoints = 300;
    p_takePoints = 500;
    p_maxTrades = 3;
    p_beStart = 0; p_bePlus = 0;
    p_trailingStart = 0;
    p_useMartingale = false;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    p_lastPrompt = prompt;
    string p = prompt;
    StringToLower(p);

    // Global parameters
    if(StringFind(p, "risco de") >= 0) p_riskPercent = ExtraiValorApos(p, "risco de");
    if(StringFind(p, "stop de") >= 0) p_stopPoints = (int)ExtraiValorApos(p, "stop de");
    if(StringFind(p, "take de") >= 0) p_takePoints = (int)ExtraiValorApos(p, "take de");
    if(StringFind(p, "máximo") >= 0 && StringFind(p, "trades") >= 0) p_maxTrades = (int)ExtraiValorApos(p, "máximo");
    if(StringFind(p, "martingale") >= 0) p_useMartingale = true;

    // Break-even
    if(StringFind(p, "move stop para entrada") >= 0) {
        p_beStart = (int)ExtraiValorApos(p, "atingir +");
        p_bePlus = (int)ExtraiValorApos(p, "entrada +");
    }

    // Trailing
    if(StringFind(p, "trailing stop") >= 0) {
        p_trailingStart = (int)ExtraiValorApos(p, "trailing stop de");
    }

    // Time filter
    if(StringFind(p, "depois das") >= 0) {
        string tStr = ExtractTime(p);
        p_startTimeSeconds = (int)StringToTime(tStr) % 86400;
    }

    p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(p);

    // Normalize and split rules
    StringReplace(p, " e ", "|");
    StringReplace(p, ".", "|");
    StringReplace(p, ",", "|");

    string segments[];
    int nSegments = StringSplit(p, '|', segments);

    Signal currentIntent = NONE;

    for(int i=0; i<nSegments; i++) {
        string s = segments[i];
        if(StringFind(s, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

        if(p_nRules >= 30) break;

        bool added = false;

        // MA Rule
        if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0) {
            p_rules[p_nRules].period1 = (int)ExtraiNumero(s);
            if(p_rules[p_nRules].period1 == 0) p_rules[p_nRules].period1 = 20; // default

            // Check for crossover
            int slashPos = StringFind(s, "/");
            if(slashPos > 0) {
                p_rules[p_nRules].period2 = (int)ExtraiNumero(s, slashPos+1);
                p_rules[p_nRules].p1_handle = iMA(_Symbol, p_frequency, p_rules[p_nRules].period1, 0, MODE_EMA, PRICE_CLOSE);
                p_rules[p_nRules].p2_handle = iMA(_Symbol, p_frequency, p_rules[p_nRules].period2, 0, MODE_EMA, PRICE_CLOSE);
            } else {
                p_rules[p_nRules].p1_handle = iMA(_Symbol, p_frequency, p_rules[p_nRules].period1, 0, MODE_EMA, PRICE_CLOSE);
                p_rules[p_nRules].p2_handle = INVALID_HANDLE;
            }
            p_rules[p_nRules].active = true;
            p_rules[p_nRules].intent = currentIntent;
            p_rules[p_nRules].tf = p_frequency;
            p_rules[p_nRules].s1 = "ma";
            added = true;
        }

        // RSI Rule
        if(StringFind(s, "rsi") >= 0) {
            int rsiPos = StringFind(s, "rsi");
            p_rules[p_nRules].period1 = (int)ExtraiNumero(s, rsiPos + 3);
            if(p_rules[p_nRules].period1 == 0) p_rules[p_nRules].period1 = 14;

            // Re-extract if the first number was a small period and there's another number
            p_rules[p_nRules].threshold1 = ExtraiNumero(s, rsiPos + 6);
            if(p_rules[p_nRules].threshold1 == 0 || p_rules[p_nRules].threshold1 == p_rules[p_nRules].period1) {
                int dirPos = (StringFind(s, "acima") >= 0) ? StringFind(s, "acima") : StringFind(s, "abaixo");
                if(dirPos >= 0) p_rules[p_nRules].threshold1 = ExtraiNumero(s, dirPos);
            }

            p_rules[p_nRules].p1_handle = iRSI(_Symbol, p_frequency, p_rules[p_nRules].period1, PRICE_CLOSE);
            p_rules[p_nRules].active = true;
            p_rules[p_nRules].intent = currentIntent;
            p_rules[p_nRules].tf = p_frequency;
            p_rules[p_nRules].s1 = "rsi";
            added = true;
        }

        // Stochastic Rule
        if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
             p_rules[p_nRules].p1_handle = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
             p_rules[p_nRules].active = true;
             p_rules[p_nRules].intent = currentIntent;
             p_rules[p_nRules].s1 = "stoch";
             added = true;
        }

        if(added) p_nRules++;
    }
}

// --- Signal Evaluation ---

double GetBufferValue(int handle, int buffer, int shift) {
    double val[];
    ArraySetAsSeries(val, true);
    if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
    return 0;
}

Signal CruzamentoMA(int rIdx, int shift) {
    int h1 = p_rules[rIdx].p1_handle;
    int h2 = p_rules[rIdx].p2_handle;

    if(h2 != INVALID_HANDLE && h2 != 0) {
        // MA vs MA
        double f0 = GetBufferValue(h1, 0, shift);
        double s0 = GetBufferValue(h2, 0, shift);
        double f1 = GetBufferValue(h1, 0, shift+1);
        double s1 = GetBufferValue(h2, 0, shift+1);
        if(f1 <= s1 && f0 > s0) return BUY;
        if(f1 >= s1 && f0 < s0) return SELL;
    } else {
        // Price vs MA
        double close0 = iClose(_Symbol, p_rules[rIdx].tf, shift);
        double close1 = iClose(_Symbol, p_rules[rIdx].tf, shift+1);
        double ma0 = GetBufferValue(h1, 0, shift);
        double ma1 = GetBufferValue(h1, 0, shift+1);
        if(close1 <= ma1 && close0 > ma0) return BUY;
        if(close1 >= ma1 && close0 < ma0) return SELL;
    }
    return NONE;
}

Signal RSIThreshold(int rIdx, int shift) {
    double v0 = GetBufferValue(p_rules[rIdx].p1_handle, 0, shift);
    double thresh = p_rules[rIdx].threshold1;
    if(p_rules[rIdx].intent == BUY) {
        if(v0 > thresh) return BUY;
    } else if(p_rules[rIdx].intent == SELL) {
        if(v0 < thresh) return SELL;
    } else {
        if(v0 > 70) return SELL;
        if(v0 < 30) return BUY;
    }
    return NONE;
}

Signal StochCross(int rIdx, int shift) {
    double k0 = GetBufferValue(p_rules[rIdx].p1_handle, 0, shift);
    double d0 = GetBufferValue(p_rules[rIdx].p1_handle, 1, shift);
    double k1 = GetBufferValue(p_rules[rIdx].p1_handle, 0, shift+1);
    double d1 = GetBufferValue(p_rules[rIdx].p1_handle, 1, shift+1);
    if(k1 <= d1 && k0 > d0) return BUY;
    if(k1 >= d1 && k0 < d0) return SELL;
    return NONE;
}

Signal AvaliaTudo() {
    int buyLeg = 0, buyRules = 0;
    int sellLeg = 0, sellRules = 0;

    for(int i=0; i<p_nRules; i++) {
        Signal s = NONE;
        if(p_rules[i].s1 == "ma") s = CruzamentoMA(i, 1);
        else if(p_rules[i].s1 == "rsi") s = RSIThreshold(i, 1);
        else if(p_rules[i].s1 == "stoch") s = StochCross(i, 1);

        if(p_rules[i].intent == BUY || p_rules[i].intent == NONE) {
            buyRules++;
            if(s == BUY) buyLeg++;
            else if(p_rules[i].intent == NONE && s == SELL) buyLeg--; // Filter logic
        }
        if(p_rules[i].intent == SELL || p_rules[i].intent == NONE) {
            sellRules++;
            if(s == SELL) sellLeg++;
            else if(p_rules[i].intent == NONE && s == BUY) sellLeg--; // Filter logic
        }
    }

    if(buyRules > 0 && buyLeg == buyRules) return BUY;
    if(sellRules > 0 && sellLeg == sellRules) return SELL;

    return NONE;
}

// --- Trade Execution & Position Management ---

double CalculaLote(double riscoPercent) {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double marginFree = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    double riskAmount = capital * (riscoPercent / 100.0);

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

    // Normalize
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    if(lot < minLot) lot = minLot;
    if(lot > maxLot) lot = maxLot;

    // Margin check
    double marginRequired;
    if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginRequired)) return 0;
    if(marginRequired > marginFree) return 0;

    return lot;
}

void EnviaOrdem(Signal s, string reason) {
    if(s == NONE) return;

    // Max trades check
    int count = 0;
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) count++;
    }
    if(count >= p_maxTrades) return;

    double lot = CalculaLote(p_riskPercent);
    if(lot <= 0) {
        GravaLog("Erro ao calcular lote ou margem insuficiente.");
        return;
    }

    // Martingale
    if(p_useMartingale) {
        HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
        for(int i=HistoryDealsTotal()-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
                double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                if(profit < 0) lot *= 2;
                break;
            }
        }
    }

    double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
    double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;

    if(p_stopPoints == 0) sl = 0;
    if(p_takePoints == 0) tp = 0;

    trade.SetExpertMagicNumber(EA_MAGIC);
    bool res = (s == BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, reason) : trade.Sell(lot, _Symbol, price, sl, tp, reason);

    if(!res) {
        GravaLog("Erro ao enviar ordem: " + IntegerToString(trade.ResultRetcode()) + " - " + trade.ResultComment());
    } else {
        GravaLog("Ordem enviada: " + EnumToString(s) + " " + DoubleToString(lot, 2) + " motivo: " + reason);
    }
}

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
            double openPrice = posInfo.PriceOpen();
            double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double sl = posInfo.StopLoss();

            // Break-even
            if(p_beStart > 0) {
                double diff = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) : (openPrice - currentPrice);
                if(diff >= p_beStart * _Point) {
                    double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
                    if(sl == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > sl) || (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < sl)) {
                        trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    }
                }
            }

            // Trailing Stop
            if(p_trailingStart > 0) {
                double diff = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) : (openPrice - currentPrice);
                if(diff >= p_trailingStart * _Point) {
                    double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
                    if(sl == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > sl + p_trailingStep * _Point) || (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < sl - p_trailingStep * _Point)) {
                        trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    }
                }
            }
        }
    }
}

// --- Auxiliary Features ---

bool AguardaNoticias() {
    int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(handle == INVALID_HANDLE) return false;

    string content = FileReadString(handle);
    FileClose(handle);

    if(content == "1") return true;

    datetime newsTime = StringToTime(content);
    if(newsTime > 0) {
        datetime now = TimeCurrent();
        if(now >= newsTime - 20*60 && now <= newsTime + 20*60) return true;
    }

    return false;
}

void GravaCSV() {
    static datetime lastWrite = 0;
    if(TimeCurrent() - lastWrite < 5) return;
    lastWrite = TimeCurrent();

    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i=0; i<PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
                FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                          posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit(), posInfo.Comment());
            }
        }
        FileClose(handle);
    }
}

void GravaLog(string text) {
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()) + ": " + text);
        FileClose(handle);
    }
    Print(text);
}

void CalculaEstatisticas() {
    HistorySelect(0, TimeCurrent());
    int total = 0, wins = 0;
    double profit = 0, loss = 0;

    for(int i=0; i<HistoryDealsTotal(); i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(p != 0) {
                total++;
                if(p > 0) { wins++; profit += p; }
                else loss -= p;
            }
        }
    }

    double winRate = (total > 0) ? (double)wins / total * 100.0 : 0;
    double pf = (loss > 0) ? profit / loss : profit;

    GravaLog("Stats - Trades: " + (string)total + " WinRate: " + DoubleToString(winRate, 2) + "% PF: " + DoubleToString(pf, 2));
}

void AIOptimizer() {
    // Basic heuristic optimizer
    HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
    int total = 0, wins = 0;
    for(int i=0; i<HistoryDealsTotal(); i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(p != 0) { total++; if(p > 0) wins++; }
        }
    }

    if(total >= 10) {
        double wr = (double)wins / total;
        if(wr < 0.40) p_riskPercent = MathMax(0.1, p_riskPercent * 0.8);
        else if(wr > 0.60) p_riskPercent = MathMin(2.0, p_riskPercent * 1.2);
        GravaLog("AIOptimizer: Adjusted risk to " + DoubleToString(p_riskPercent, 2) + "% based on WR " + DoubleToString(wr*100, 1) + "%");
    }
}

// --- Event Handlers ---

int OnInit() {
    EventSetTimer(1);
    symInfo.Name(_Symbol);
    ResetStrategy();
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
}

void OnTick() {
    if(p_nRules == 0) return;

    // Bar check
    datetime currentBar = iTime(_Symbol, p_frequency, 0);
    if(currentBar == p_lastBarTime) return;
    p_lastBarTime = currentBar;

    // Time & News filters
    if(TimeCurrent() % 86400 < p_startTimeSeconds) return;
    if(AguardaNoticias()) return;

    Signal s = AvaliaTudo();
    if(s != NONE) EnviaOrdem(s, "Signal Triggered");
}

void OnTimer() {
    // Check for prompt updates
    int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        string prompt = FileReadString(handle);
        FileClose(handle);
        if(prompt != "" && prompt != p_lastPrompt) {
            GravaLog("Novo prompt detectado: " + prompt);
            InterpretaPrompt(prompt);
        }
    }

    GerenciaPosicoes();
    GravaCSV();

    static int hourCounter = 0;
    if(++hourCounter >= 3600) {
        hourCounter = 0;
        CalculaEstatisticas();
        AIOptimizer();
    }
}

Signal BBounce(int rIdx, int shift) {
    double close0 = iClose(_Symbol, p_rules[rIdx].tf, shift);
    double upper = GetBufferValue(p_rules[rIdx].p1_handle, 1, shift);
    double lower = GetBufferValue(p_rules[rIdx].p1_handle, 2, shift);
    if(close0 < lower) return BUY;
    if(close0 > upper) return SELL;
    return NONE;
}

Signal DailyBreak(int rIdx, int shift) {
    double hi = iHigh(_Symbol, PERIOD_D1, 1);
    double lo = iLow(_Symbol, PERIOD_D1, 1);
    double close = iClose(_Symbol, p_rules[rIdx].tf, shift);
    if(close > hi) return BUY;
    if(close < lo) return SELL;
    return NONE;
}

Signal DeltaAggression(int rIdx, int shift) {
    // Mock implementation for demonstration
    return NONE;
}

Signal VolumeCycle(int rIdx, int shift) {
    return NONE;
}

Signal AMA(int rIdx, int shift) {
    double ama0 = GetBufferValue(p_rules[rIdx].p1_handle, 0, shift);
    double ama1 = GetBufferValue(p_rules[rIdx].p1_handle, 0, shift+1);
    if(ama0 > ama1) return BUY;
    if(ama0 < ama1) return SELL;
    return NONE;
}

Signal Bar2Pattern(int rIdx, int shift) {
    return NONE;
}

Signal RSRelative(int rIdx, int shift) {
    return NONE;
}
