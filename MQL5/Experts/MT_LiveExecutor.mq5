//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Agente de Execução em Tempo Real
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\DealInfo.mqh>

// --- Enums ---
enum ENUM_RULE_TYPE {
    RT_NONE = 0,
    RT_MA = 1,
    RT_RSI = 2,
    RT_STOCH = 3,
    RT_BB = 4,
    RT_DAILYBREAK = 5,
    RT_DELTA = 6,
    RT_VOL = 7,
    RT_AMA = 8,
    RT_BAR2 = 9,
    RT_RS = 10,
    RT_AI = 11,
    RT_AI_PRED = 12
};

enum ENUM_SIGNAL {
    SIGNAL_BUY = 1,
    SIGNAL_SELL = -1,
    SIGNAL_NONE = 0
};

// --- Structs ---
struct Rule {
    ENUM_RULE_TYPE type;
    ENUM_SIGNAL intent;
    int tf;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle1, handle2;

    void Reset() {
        if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
        if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
        type = RT_NONE;
        intent = SIGNAL_NONE;
        tf = PERIOD_CURRENT;
        p1 = 0; p2 = 0; p3 = 0;
        d1 = 0; d2 = 0;
        s1 = "";
        handle1 = INVALID_HANDLE;
        handle2 = INVALID_HANDLE;
    }
};

// --- Globais de Estratégia ---
Rule rules[20];
int nRules = 0;
string p_fullPrompt = "";
datetime p_lastPromptUpdate = 0;

double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
bool p_useMartingale = false;
int p_magic = 123456;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
string p_startTime = "00:00";
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;

// --- Instâncias ---
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// --- Protótipos ---
void InterpretaPrompt(string prompt);
ENUM_SIGNAL AvaliaTudo();
void GerenciaPosicoes();
void GravaCSV();
void GravaLog(string txt);
void EnviaOrdem(ENUM_SIGNAL sig, string reason);
double CalculaLote();
bool AguardaNoticias();
void AIOptimizer();
double GetBufferValue(int handle, int buffer, int shift);
void ResetStrategy();

// --- NLP Helpers ---
double ExtraiNumero(string text, int &startPos) {
    string res = "";
    bool found = false;
    for(int i = startPos; i < StringLen(text); i++) {
        ushort c = StringGetCharacter(text, i);
        if((c >= '0' && c <= '9') || c == '.') {
            res += CharToString((char)c);
            found = true;
        } else if(found) {
            startPos = i;
            return StringToDouble(res);
        }
    }
    return StringToDouble(res);
}

double ExtraiValorApos(string prompt, string keyword) {
    int pos = StringFind(prompt, keyword);
    if(pos < 0) return -1;
    int start = pos + StringLen(keyword);
    return ExtraiNumero(prompt, start);
}

int PeriodoTexto(string prompt) {
    if(StringFind(prompt, "m1") >= 0 && StringFind(prompt, "m15") < 0) return PERIOD_M1;
    if(StringFind(prompt, "m5") >= 0 && StringFind(prompt, "m15") < 0) return PERIOD_M5;
    if(StringFind(prompt, "m15") >= 0) return PERIOD_M15;
    if(StringFind(prompt, "m30") >= 0) return PERIOD_M30;
    if(StringFind(prompt, "h1") >= 0) return PERIOD_H1;
    if(StringFind(prompt, "h4") >= 0) return PERIOD_H4;
    if(StringFind(prompt, "d1") >= 0) return PERIOD_D1;
    return PERIOD_CURRENT;
}

void ResetStrategy() {
    for(int i = 0; i < 20; i++) rules[i].Reset();
    nRules = 0;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string work = prompt;
    StringToLower(work);

    // Configurações Globais
    double r = ExtraiValorApos(work, "risco de ");
    if(r > 0) p_riskPercent = r;

    double sl = ExtraiValorApos(work, "stop de ");
    if(sl > 0) p_stopPoints = (int)sl;

    double tp = ExtraiValorApos(work, "take de ");
    if(tp > 0) p_takePoints = (int)tp;

    double mt = ExtraiValorApos(work, "máximo ");
    if(mt > 0) p_maxTrades = (int)mt;

    if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

    p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(work);

    // Breakeven e Trailing
    double beS = ExtraiValorApos(work, "atingir +");
    if(beS > 0) p_beStart = (int)beS;
    double beP = ExtraiValorApos(work, "entrada +");
    if(beP > 0) p_bePlus = (int)beP;

    double ts = ExtraiValorApos(work, "trailing de ");
    if(ts > 0) p_trailingStop = (int)ts;

    // Split de Regras
    string segments[];
    ushort sep = StringGetCharacter("|", 0);
    string temp = work;
    StringReplace(temp, " e ", "|");
    StringReplace(temp, ".", "|");
    StringReplace(temp, ",", "|");
    int nSeg = StringSplit(temp, sep, segments);

    ENUM_SIGNAL currentIntent = SIGNAL_NONE;

    for(int i = 0; i < nSeg && nRules < 20; i++) {
        string seg = segments[i];
        if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
        else if(StringFind(seg, "vende") >= 0) currentIntent = SIGNAL_SELL;

        if(currentIntent == SIGNAL_NONE) continue;

        Rule r;
        r.intent = currentIntent;
        r.tf = PeriodoTexto(seg);
        if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

        // MA
        if(StringFind(seg, " média") >= 0 || StringFind(seg, " ma ") >= 0) {
            r.type = RT_MA;
            int start = 0;
            r.p1 = (int)ExtraiNumero(seg, start);
            r.p2 = (int)ExtraiNumero(seg, start);
            if(r.p2 > 0) {
                r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
                r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
            } else {
                r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
            }
            rules[nRules++] = r;
        }
        // RSI
        else if(StringFind(seg, "rsi") >= 0) {
            r.type = RT_RSI;
            int start = 0;
            double v1 = ExtraiNumero(seg, start);
            double v2 = ExtraiNumero(seg, start);
            if(v2 > 0) { r.p1 = (int)v1; r.d1 = v2; }
            else { r.p1 = 14; r.d1 = v1; }
            r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
            rules[nRules++] = r;
        }
        // STOCH
        else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
            r.type = RT_STOCH;
            r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
            rules[nRules++] = r;
        }
        // BB
        else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bb") >= 0) {
            r.type = RT_BB;
            r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
            rules[nRules++] = r;
        }
        // AMA
        else if(StringFind(seg, "ama") >= 0 || StringFind(seg, "adaptativa") >= 0) {
            r.type = RT_AMA;
            r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, 10, 2, 30, PRICE_CLOSE);
            rules[nRules++] = r;
        }
    }
}

// --- Signal Evaluation ---
double GetBufferValue(int handle, int buffer, int shift) {
    double arr[];
    ArraySetAsSeries(arr, true);
    if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
    return 0;
}

ENUM_SIGNAL AvaliaRegra(Rule &r) {
    if(r.type == RT_MA) {
        if(r.handle2 != INVALID_HANDLE) { // Cruzamento MA/MA
            double f1 = GetBufferValue(r.handle1, 0, 1);
            double s1 = GetBufferValue(r.handle2, 0, 1);
            double f2 = GetBufferValue(r.handle1, 0, 2);
            double s2 = GetBufferValue(r.handle2, 0, 2);
            if(f2 < s2 && f1 > s1) return SIGNAL_BUY;
            if(f2 > s2 && f1 < s1) return SIGNAL_SELL;
        } else { // Preço vs MA
            double ma1 = GetBufferValue(r.handle1, 0, 1);
            double ma2 = GetBufferValue(r.handle1, 0, 2);
            double c1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double c2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            if(c2 < ma2 && c1 > ma1) return SIGNAL_BUY;
            if(c2 > ma2 && c1 < ma1) return SIGNAL_SELL;
        }
    }
    else if(r.type == RT_RSI) {
        double rsi1 = GetBufferValue(r.handle1, 0, 1);
        double rsi2 = GetBufferValue(r.handle1, 0, 2);
        if(rsi2 < r.d1 && rsi1 > r.d1) return SIGNAL_BUY;
        if(rsi2 > r.d1 && rsi1 < r.d1) return SIGNAL_SELL;
    }
    else if(r.type == RT_STOCH) {
        double k1 = GetBufferValue(r.handle1, 0, 1);
        double d1 = GetBufferValue(r.handle1, 1, 1);
        double k2 = GetBufferValue(r.handle1, 0, 2);
        double d2 = GetBufferValue(r.handle1, 1, 2);
        if(k2 < d2 && k1 > d1) return SIGNAL_BUY;
        if(k2 > d2 && k1 < d1) return SIGNAL_SELL;
    }
    else if(r.type == RT_BB) {
        double upper = GetBufferValue(r.handle1, 1, 1);
        double lower = GetBufferValue(r.handle1, 2, 1);
        double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
        if(close < lower) return SIGNAL_BUY;
        if(close > upper) return SIGNAL_SELL;
    }
    else if(r.type == RT_AMA) {
        double ama1 = GetBufferValue(r.handle1, 0, 1);
        double ama2 = GetBufferValue(r.handle1, 0, 2);
        if(ama2 < ama1) return SIGNAL_BUY;
        if(ama2 > ama1) return SIGNAL_SELL;
    }
    return SIGNAL_NONE;
}

ENUM_SIGNAL AvaliaTudo() {
    int buyVotes = 0, sellVotes = 0;
    int buyRules = 0, sellRules = 0;

    for(int i = 0; i < nRules; i++) {
        ENUM_SIGNAL res = AvaliaRegra(rules[i]);
        if(rules[i].intent == SIGNAL_BUY) {
            buyRules++;
            if(res == SIGNAL_BUY) buyVotes++;
        } else if(rules[i].intent == SIGNAL_SELL) {
            sellRules++;
            if(res == SIGNAL_SELL) sellVotes++;
        }
    }

    if(buyRules > 0 && buyVotes == buyRules) return SIGNAL_BUY;
    if(sellRules > 0 && sellVotes == sellRules) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// --- Trade Execution ---
double CalculaLote() {
    double capital = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = capital * p_riskPercent / 100.0;
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));

    if(p_useMartingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        for(int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
               HistoryDealGetInteger(ticket, DEAL_MAGIC) == p_magic) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2.0;
                break;
            }
        }
    }

    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathFloor(lot / step) * step;
    return MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lot));
}

void EnviaOrdem(ENUM_SIGNAL sig, string reason) {
    if(sig == SIGNAL_NONE) return;

    double price = (sig == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl = (sig == SIGNAL_BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
    double tp = (sig == SIGNAL_BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;
    double lot = CalculaLote();

    double margin;
    if(!OrderCalcMargin((sig == SIGNAL_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lot, price, margin)) {
        GravaLog("Erro ao calcular margem.");
        return;
    }
    if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
        GravaLog("Margem insuficiente: Requerido " + DoubleToString(margin, 2) + " Disponível " + DoubleToString(AccountInfoDouble(ACCOUNT_FREEMARGIN), 2));
        return;
    }

    trade.SetExpertMagicNumber(p_magic);
    for(int i = 0; i < 3; i++) {
        bool res = (sig == SIGNAL_BUY) ? trade.Buy(lot, _Symbol, price, sl, tp, reason) : trade.Sell(lot, _Symbol, price, sl, tp, reason);
        if(res) {
            if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
                SendNotification("MT-LiveExecutor: " + reason + " em " + _Symbol);
                break;
            }
            if(trade.ResultRetcode() == TRADE_RETCODE_REQUOTES || trade.ResultRetcode() == TRADE_RETCODE_OFFQUOTES) {
                price = (sig == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
                continue;
            }
        }
        GravaLog("Erro ao enviar ordem: " + trade.ResultComment());
        break;
    }
}

void GerenciaPosicoes() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() != p_magic || posInfo.Symbol() != _Symbol) continue;

            double openPrice = posInfo.PriceOpen();
            double curPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double diff = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (curPrice - openPrice) : (openPrice - curPrice);
            int points = (int)(diff / _Point);

            // Breakeven
            if(p_beStart > 0 && points >= p_beStart) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (openPrice + p_bePlus * _Point) : (openPrice - p_bePlus * _Point);
                if(posInfo.StopLoss() == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss()) || (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < posInfo.StopLoss())) {
                    trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && points >= p_trailingStop) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (curPrice - p_trailingStop * _Point) : (curPrice + p_trailingStop * _Point);
                if(posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if(newSL > posInfo.StopLoss() + p_trailingStep * _Point) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                } else {
                    if(newSL < posInfo.StopLoss() - p_trailingStep * _Point || posInfo.StopLoss() == 0) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }
        }
    }
}

// --- Support Functions ---
void GravaLog(string txt) {
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()) + ": " + txt);
        FileClose(handle);
    }
}

void GravaCSV() {
    int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV);
    if(handle != INVALID_HANDLE) {
        FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
        for(int i = 0; i < PositionsTotal(); i++) {
            if(posInfo.SelectByIndex(i)) {
                if(posInfo.Magic() == p_magic) {
                    FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                              posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(),
                              posInfo.Profit(), posInfo.Comment());
                }
            }
        }
        FileClose(handle);
    }
}

bool AguardaNoticias() {
    if(FileIsExist("news_veto.txt")) {
        int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT);
        if(handle != INVALID_HANDLE) {
            string content = FileReadString(handle);
            FileClose(handle);
            if(content == "1") return true;
        }
    }
    return false;
}

void AIOptimizer() {
    static datetime lastOpt = 0;
    if(TimeCurrent() - lastOpt < 3600) return;
    lastOpt = TimeCurrent();

    HistorySelect(TimeCurrent() - 86400, TimeCurrent());
    int total = HistoryDealsTotal();
    int wins = 0, count = 0;
    for(int i = total - 1; i >= 0 && count < 10; i--) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == p_magic) {
            count++;
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
        }
    }
    if(count >= 5) {
        double winRate = (double)wins / count;
        if(winRate < 0.4) p_riskPercent *= 0.8;
        else if(winRate > 0.7) p_riskPercent *= 1.1;
        p_riskPercent = MathMin(5.0, MathMax(0.1, p_riskPercent));
    }
}

// --- Event Handlers ---
int OnInit() {
    EventSetTimer(1);
    symInfo.Name(_Symbol);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
    EventKillTimer();
    ResetStrategy();
}

void OnTimer() {
    if(FileIsExist("prompt.txt")) {
        datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
        if(mod > p_lastPromptUpdate) {
            int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT);
            if(handle != INVALID_HANDLE) {
                p_fullPrompt = FileReadString(handle);
                FileClose(handle);
                InterpretaPrompt(p_fullPrompt);
                p_lastPromptUpdate = mod;
                GravaLog("Estratégia atualizada via prompt.txt");
            }
        }
    }
    AIOptimizer();
}

void OnTick() {
    GravaCSV();
    GerenciaPosicoes();

    static datetime lastBar = 0;
    datetime curBar = iTime(_Symbol, p_frequency, 0);
    if(curBar == lastBar) return;
    lastBar = curBar;

    string curTime = TimeToString(TimeCurrent(), TIME_MINUTES);
    if(curTime < p_startTime) return;

    if(AguardaNoticias()) {
        GravaLog("Veto de notícias ativo. Operação ignorada.");
        return;
    }

    int trades = 0;
    for(int i = 0; i < PositionsTotal(); i++) {
        if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() == p_magic && posInfo.Symbol() == _Symbol) trades++;
        }
    }
    if(trades >= p_maxTrades) return;

    ENUM_SIGNAL sig = AvaliaTudo();
    if(sig != SIGNAL_NONE) {
        EnviaOrdem(sig, "Sinal de Estratégia");
    }
}
