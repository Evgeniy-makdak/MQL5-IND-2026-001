//+------------------------------------------------------------------+
//|                                            Cox_Probability_System.mq5 |
//|                                        Copyright 2026, Evgeniy Acteck |
//|                                        Version: 1.0                  |
//|                                        ТЗ № MQL5-IND-2026-001        |
//+------------------------------------------------------------------+
#property copyright     "Copyright 2026, Evgeniy Acteck"
#property link          "https://github.com/Evgeniy-makdak/MQL5-IND-2026-001"
#property version       "1.1"
#property description   "Cox Probability System (CPS) — байесовский индикатор вероятности"
#property description   "с энтропийным фильтром Шеннона."
#property description   "Не даёт торговых сигналов. Только визуализация."

//--- Индикатор в отдельном окне
#property indicator_separate_window
#property indicator_buffers   3
#property indicator_plots     2
#property indicator_minimum   0.0
#property indicator_maximum   1.0

//--- Plot 1: Signal Probability (сглаженная)
#property indicator_label1    "Signal Probability"
#property indicator_type1     DRAW_LINE
#property indicator_color1    clrDodgerBlue
#property indicator_style1    STYLE_SOLID
#property indicator_width1    2

//--- Plot 2: Entropy (сглаженная)
#property indicator_label2    "Entropy"
#property indicator_type2     DRAW_LINE
#property indicator_color2    clrOrangeRed
#property indicator_style2    STYLE_SOLID
#property indicator_width2    1

//+------------------------------------------------------------------+
//| ВХОДНЫЕ ПАРАМЕТРЫ (настраиваемые пользователем)                   |
//+------------------------------------------------------------------+
input group "=== Основные параметры ==="
input int      LookbackBars          = 200;            // Количество баров для априорных вероятностей (50–1000)
input int      SmoothingPeriod       = 14;             // Период сглаживания линий SMA (5–50)
input double   EntropyThreshold      = 0.85;           // Порог энтропии: сигнал разрешён при Entropy < этого (0.1–1.0)
                                                        // Подобрано для баланса: при MinProbabilityToTrade=0.70 фильтр пропускает
                                                        // уверенные тренды (H~0.81 при p=0.75), но блокирует слабые сигналы.
input double   MinProbabilityToTrade = 0.70;           // Минимальная пост-байесовская вероятность для сделки (0.51–0.95)
input int      UpdateIntervalTicks   = 50;             // Интервал полного пересчёта в тиках (10–500)

input group "=== Визуализация ==="
input bool     ShowEntropyZone       = true;           // Закрашивать фон зоны высокой энтропии
input color    SignalLineColor       = clrDodgerBlue;  // Цвет линии вероятности
input color    EntropyLineColor      = clrOrangeRed;   // Цвет линии энтропии
input color    HighEntropyBgColor    = clrLightGray;   // Цвет фона при энтропии выше порога

//+------------------------------------------------------------------+
//| ИНДИКАТОРНЫЕ БУФЕРЫ                                               |
//+------------------------------------------------------------------+
double SignalBuffer[];       // Буфер 0: сглаженная вероятность (PLOT 1)
double EntropyBuffer[];      // Буфер 1: сглаженная энтропия (PLOT 2)
double SignalRawBuffer[];    // Буфер 2: сырая вероятность (для отладки, не отображается)

//+------------------------------------------------------------------+
//| ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                                             |
//+------------------------------------------------------------------+
string   g_prefix;              // Префикс имён графических объектов
int      g_tickCounter;         // Счётчик тиков
datetime g_lastBarTime;         // Время последнего обработанного бара
int      g_subWindow;           // Номер подокна индикатора

//+------------------------------------------------------------------+
//| Log2 — логарифм по основанию 2                                     |
//+------------------------------------------------------------------+
double Log2(double x)
{
   if(x <= 0.0)
      return 0.0;
   return MathLog(x) / MathLog(2.0);
}

//+------------------------------------------------------------------+
//| CalculatePriors — априорные вероятности для бара barIdx            |
//| (time‑series: 0 = текущий).                                       |
//| Просматриваем бары barIdx+1 .. barIdx+lookback (БОЛЕЕ СТАРЫЕ).    |
//+------------------------------------------------------------------+
void CalculatePriors(const double   &open[],
                     const double   &close[],
                     int             barIdx,
                     int             lookback,
                     double         &P_prior_up,
                     double         &P_prior_down,
                     int             rates_total)
{
   int upCount   = 0;
   int downCount = 0;

   int endIdx = MathMin(rates_total - 1, barIdx + lookback);

   for(int i = barIdx + 1; i <= endIdx; i++)
   {
      if(close[i] > open[i])
         upCount++;
      else if(close[i] < open[i])
         downCount++;
      // NoMove (close==open) — игнорируем
   }

   int total = upCount + downCount;
   if(total > 0)
   {
      P_prior_up   = (double)upCount   / (double)total;
      P_prior_down = (double)downCount / (double)total;
   }
   else
   {
      // Нет истории — нейтральные априорные
      P_prior_up   = 0.5;
      P_prior_down = 0.5;
   }
}

//+------------------------------------------------------------------+
//| CalculateLikelihood — P(E|up) и P(E|down) для бара barIdx         |
//| (time‑series: 0 = текущий).                                       |
//| Окно M = 6 фиксированное. Просматриваем barIdx+1 .. barIdx+6.     |
//| Для каждого бара j проверяем, совпадает ли направление бара j     |
//| с направлением СЛЕДУЮЩЕГО (более нового) бара j-1.                |
//+------------------------------------------------------------------+
void CalculateLikelihood(const double   &open[],
                         const double   &close[],
                         int             barIdx,
                         int             window,
                         double         &P_E_given_up,
                         double         &P_E_given_down,
                         int             rates_total)
{
   int upTotal        = 0;
   int upFollowUp     = 0;
   int downTotal      = 0;
   int downFollowDown = 0;

   int endIdx = MathMin(rates_total - 2, barIdx + window);  // -2 чтобы j-1 был в пределах

   for(int j = barIdx + 1; j <= endIdx; j++)
   {
      // Направление бара j
      int dirJ = 0;   // 0 = NoMove, +1 = Up, -1 = Down
      if(close[j] > open[j])
         dirJ = 1;
      else if(close[j] < open[j])
         dirJ = -1;

      if(dirJ == 0)
         continue;    // NoMove — не учитываем

      // Направление СЛЕДУЮЩЕГО (более нового) бара j-1
      int dirNext = 0;
      if(close[j - 1] > open[j - 1])
         dirNext = 1;
      else if(close[j - 1] < open[j - 1])
         dirNext = -1;

      if(dirNext == 0)
         continue;    // следующий бар — NoMove, пропускаем пару

      if(dirJ == 1)
      {
         upTotal++;
         if(dirNext == 1)
            upFollowUp++;
      }
      else  // dirJ == -1
      {
         downTotal++;
         if(dirNext == -1)
            downFollowDown++;
      }
   }

   P_E_given_up   = (upTotal   > 0) ? (double)upFollowUp   / (double)upTotal   : 0.5;
   P_E_given_down = (downTotal > 0) ? (double)downFollowDown / (double)downTotal : 0.5;
}

//+------------------------------------------------------------------+
//| UpdateBackground — отрисовка / удаление прямоугольников фона       |
//| Закрашиваем фон бара, если МГНОВЕННАЯ (не сглаженная) энтропия    |
//| превышает EntropyThreshold.                                       |
//+------------------------------------------------------------------+
void UpdateBackground(const datetime &time[],
                      const double   &rawEntropy[],
                      int             rates_total)
{
   if(!ShowEntropyZone)
   {
      // Удаляем все прямоугольники фона, если зона выключена
      int totalObjs = ObjectsTotal(0, g_subWindow, -1);
      for(int k = totalObjs - 1; k >= 0; k--)
      {
         string name = ObjectName(0, k, g_subWindow, -1);
         if(StringFind(name, g_prefix + "BG_") == 0)
            ObjectDelete(0, name);
      }
      return;
   }

   int maxBars = MathMin(rates_total, 500);   // не более 500 прямоугольников

   // Собираем информацию, для каких баров нужны прямоугольники
   bool needRect[];
   ArrayResize(needRect, maxBars);
   ArrayInitialize(needRect, false);

   for(int i = 0; i < maxBars - 1; i++)
   {
      if(rawEntropy[i] > EntropyThreshold)
         needRect[i] = true;
   }

   // Создаём / обновляем прямоугольники
   for(int i = 0; i < maxBars - 1; i++)
   {
      string rectName = g_prefix + "BG_" + IntegerToString(i);

      if(needRect[i])
      {
         // Время левой и правой границы бара
         datetime tLeft  = time[i];
         datetime tRight = (i > 0) ? time[i - 1] : (time[i] + PeriodSeconds());

         if(ObjectFind(0, rectName) < 0)
         {
            if(!ObjectCreate(0, rectName, OBJ_RECTANGLE, g_subWindow, tLeft, 0.0, tRight, 1.0))
               continue;
         }

         ObjectSetInteger(0, rectName, OBJPROP_TIME,  0, tLeft);
         ObjectSetDouble(0,  rectName, OBJPROP_PRICE, 0, 0.0);
         ObjectSetInteger(0, rectName, OBJPROP_TIME,  1, tRight);
         ObjectSetDouble(0,  rectName, OBJPROP_PRICE, 1, 1.0);

         ObjectSetInteger(0, rectName, OBJPROP_COLOR,     HighEntropyBgColor);
         ObjectSetInteger(0, rectName, OBJPROP_FILL,      true);
         ObjectSetInteger(0, rectName, OBJPROP_BACK,      true);    // за линиями
         ObjectSetInteger(0, rectName, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, rectName, OBJPROP_HIDDEN,    true);
      }
      else
      {
         // Удаляем прямоугольник, если он не нужен
         if(ObjectFind(0, rectName) >= 0)
            ObjectDelete(0, rectName);
      }
   }

   // Подчищаем прямоугольники за пределами maxBars
   int totalObjs = ObjectsTotal(0, g_subWindow, -1);
   for(int k = totalObjs - 1; k >= 0; k--)
   {
      string name = ObjectName(0, k, g_subWindow, -1);
      if(StringFind(name, g_prefix + "BG_") == 0)
      {
         string numStr = StringSubstr(name, StringLen(g_prefix + "BG_"));
         int barIdx = (int)StringToInteger(numStr);
         if(barIdx >= maxBars)
            ObjectDelete(0, name);
      }
   }
}

//+------------------------------------------------------------------+
//| Создание или обновление одной текстовой метки                      |
//+------------------------------------------------------------------+
void CreateOrUpdateLabel(string suffix, string text, int yOffset, color clr)
{
   string name = g_prefix + "Label_" + suffix;
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_LABEL, g_subWindow, 0, 0))
         return;
   }
   ObjectSetString(0,  name, OBJPROP_TEXT,     text);
   ObjectSetInteger(0, name, OBJPROP_CORNER,   CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 5);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yOffset);
   ObjectSetInteger(0, name, OBJPROP_COLOR,    clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  9);
   ObjectSetString(0,  name, OBJPROP_FONT,     "Arial");
}

//+------------------------------------------------------------------+
//| UpdateLabel — текстовые метки в левом верхнем углу (4 строки)      |
//+------------------------------------------------------------------+
void UpdateLabel(double rawEntropy, double rawSignal)
{
   //--- Определяем, разрешена ли торговля
   string tradeAllowed = "NO";
   color  tradeColor   = clrDarkRed; // Красный для NO
   if(rawEntropy < EntropyThreshold)
   {
      double P_down = 1.0 - rawSignal;
      if(rawSignal >= MinProbabilityToTrade || P_down >= MinProbabilityToTrade)
      {
         tradeAllowed = "YES";
         tradeColor   = clrDarkGreen; // Тёмно-зелёный для YES
      }
   }

   //--- Сдвигаем метки ниже, чтобы не перекрывать системный заголовок MT5
   //    (терминал принудительно рисует значения буферов в левом верхнем углу)
   int yBase = 30;

   //--- Строка 1: Название системы
   CreateOrUpdateLabel("Title", "Cox Probability System v1.1", yBase, clrNavy);

   //--- Строка 2: Энтропия
   string entropyText = "Entropy RAW: " + DoubleToString(rawEntropy, 2) +
                        " | Threshold: " + DoubleToString(EntropyThreshold, 2);
   CreateOrUpdateLabel("Entropy", entropyText, yBase + 25, clrNavy);

   //--- Строка 3: Сигнал
   string signalText = "Signal: " + DoubleToString(rawSignal, 2) +
                       " | MinProb: " + DoubleToString(MinProbabilityToTrade, 2);
   CreateOrUpdateLabel("Signal", signalText, yBase + 50, clrNavy);

   //--- Строка 4: Разрешение торговли (цветной статус)
   CreateOrUpdateLabel("Trade", "Trade allowed: " + tradeAllowed, yBase + 75, tradeColor);
}

//+------------------------------------------------------------------+
//| OnInit — инициализация индикатора                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Префикс для графических объектов
   g_prefix = "CPS_";

   //--- Привязка буферов
   SetIndexBuffer(0, SignalBuffer,    INDICATOR_DATA);
   SetIndexBuffer(1, EntropyBuffer,   INDICATOR_DATA);
   SetIndexBuffer(2, SignalRawBuffer, INDICATOR_DATA);

   //--- Перевод в time‑series (0 = текущий бар)
   ArraySetAsSeries(SignalBuffer,    true);
   ArraySetAsSeries(EntropyBuffer,   true);
   ArraySetAsSeries(SignalRawBuffer, true);

   //--- Инициализация буферов значением EMPTY_VALUE
   ArrayInitialize(SignalBuffer,    EMPTY_VALUE);
   ArrayInitialize(EntropyBuffer,   EMPTY_VALUE);
   ArrayInitialize(SignalRawBuffer, EMPTY_VALUE);

   //--- Настройки Plot 0: Signal Probability
   PlotIndexSetString(0,  PLOT_LABEL,      "Signal Probability");
   PlotIndexSetInteger(0, PLOT_DRAW_TYPE,  DRAW_LINE);
   PlotIndexSetInteger(0, PLOT_LINE_COLOR, SignalLineColor);
   PlotIndexSetInteger(0, PLOT_LINE_STYLE, STYLE_SOLID);
   PlotIndexSetInteger(0, PLOT_LINE_WIDTH, 2);

   //--- Настройки Plot 1: Entropy
   PlotIndexSetString(1,  PLOT_LABEL,      "Entropy");
   PlotIndexSetInteger(1, PLOT_DRAW_TYPE,  DRAW_LINE);
   PlotIndexSetInteger(1, PLOT_LINE_COLOR, EntropyLineColor);
   PlotIndexSetInteger(1, PLOT_LINE_STYLE, STYLE_SOLID);
   PlotIndexSetInteger(1, PLOT_LINE_WIDTH, 1);

   //--- Горизонтальные уровни (4 шт.)
   IndicatorSetInteger(INDICATOR_LEVELS, 4);

   // Уровень 0: MinProbabilityToTrade (зелёный пунктир)
   IndicatorSetDouble(INDICATOR_LEVELVALUE,  0, MinProbabilityToTrade);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR,  0, clrGreen);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE,  0, STYLE_DASH);
   IndicatorSetInteger(INDICATOR_LEVELWIDTH,  0, 1);

   // Уровень 1: нейтралитет 0.50 (серый тонкий)
   IndicatorSetDouble(INDICATOR_LEVELVALUE,  1, 0.50);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR,  1, clrGray);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE,  1, STYLE_SOLID);
   IndicatorSetInteger(INDICATOR_LEVELWIDTH,  1, 1);

   // Уровень 2: EntropyThreshold (красная ТОЛСТАЯ СПЛОШНАЯ линия — "стена энтропии")
   // Отличается от остальных уровней, чтобы визуально подчеркнуть: это фильтр, а не зона входа.
   IndicatorSetDouble(INDICATOR_LEVELVALUE,  2, EntropyThreshold);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR,  2, clrRed);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE,  2, STYLE_SOLID);
   IndicatorSetInteger(INDICATOR_LEVELWIDTH,  2, 2);

   // Уровень 3: зона продаж 0.30 (тёмно-красный пунктир, симметрично MinProbabilityToTrade)
   IndicatorSetDouble(INDICATOR_LEVELVALUE,  3, 1.0 - MinProbabilityToTrade);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR,  3, clrCrimson);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE,  3, STYLE_DASH);
   IndicatorSetInteger(INDICATOR_LEVELWIDTH,  3, 1);

   //--- Убираем стандартный заголовок индикатора, чтобы не перекрывал текстовые метки
   IndicatorSetString(INDICATOR_SHORTNAME, "");

   //--- Определяем подокно
   g_subWindow = ChartWindowFind();

   //--- Сброс счётчиков
   g_tickCounter  = 0;
   g_lastBarTime  = 0;

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit — деинициализация                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Удаляем текстовые метки (4 строки)
   ObjectDelete(0, g_prefix + "Label_Title");
   ObjectDelete(0, g_prefix + "Label_Entropy");
   ObjectDelete(0, g_prefix + "Label_Signal");
   ObjectDelete(0, g_prefix + "Label_Trade");

   //--- Удаляем все прямоугольники фона
   int totalObjs = ObjectsTotal(0, g_subWindow, -1);
   for(int k = totalObjs - 1; k >= 0; k--)
   {
      string name = ObjectName(0, k, g_subWindow, -1);
      if(StringFind(name, g_prefix + "BG_") == 0)
         ObjectDelete(0, name);
   }

   Comment("");
}

//+------------------------------------------------------------------+
//| OnCalculate — основной цикл расчёта индикатора                     |
//+------------------------------------------------------------------+
int OnCalculate(const int       rates_total,
                const int       prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
//--- Проверка достаточности данных
   if(rates_total < LookbackBars + SmoothingPeriod + 10)
      return(0);

//--- Перевод ценовых массивов в time‑series (0 = текущий бар)
   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(open,  true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

//--- Определяем стартовый индекс для расчёта
   int start = 0;
   bool forceFullRecalc = false;

   if(prev_calculated == 0)
   {
      // Первый запуск — полный расчёт
      start           = 0;
      forceFullRecalc = true;
      g_tickCounter   = 0;
   }
   else if(time[0] != g_lastBarTime)
   {
      // Новый бар — полный пересчёт из-за сдвига SMA-окна
      start           = 0;
      forceFullRecalc = true;
      g_tickCounter   = 0;
   }
   else
   {
      // Тот же бар (тик)
      g_tickCounter++;

      if(g_tickCounter >= UpdateIntervalTicks)
      {
         // Полный пересчёт статистики по интервалу тиков
         g_tickCounter   = 0;
         start           = 0;
         forceFullRecalc = true;
      }
      else
      {
         // Частичный пересчёт: только последние бары (для SMA)
         start = MathMax(0, rates_total - SmoothingPeriod - 10);
      }
   }

   g_lastBarTime = time[0];

//--- Вспомогательный массив для МГНОВЕННОЙ (сырой) энтропии
//    Используется для фильтрации фона (не сглаженная).
   double rawEntropy[];
   ArrayResize(rawEntropy, rates_total);
   ArraySetAsSeries(rawEntropy, true);
   ArrayInitialize(rawEntropy, 1.0);   // по умолчанию — макс. неопределённость

//--- Основной цикл расчёта сырых значений
//    ВСЕГДА считаем с бара 0, чтобы rawEntropy[0] была актуальна
//    для фона и текстовой метки (это быстро).
//    Но SignalRawBuffer заполняем только с start для оптимизации.
   int limit = rates_total - 1;

   for(int i = 0; i <= limit; i++)
   {
      //--- 3.1. Априорные вероятности (на основании баров СТАРШЕ bar i)
      double P_prior_up, P_prior_down;
      CalculatePriors(open, close, i, LookbackBars,
                      P_prior_up, P_prior_down, rates_total);

      //--- 3.2. Функция правдоподобия (окно M = 6)
      int    M = 6;
      double P_E_given_up, P_E_given_down;
      CalculateLikelihood(open, close, i, M,
                          P_E_given_up, P_E_given_down, rates_total);

      //--- 3.3. Байесовское обновление (апостериорная вероятность)
      double numerator   = P_E_given_up * P_prior_up;
      double denominator = P_E_given_up * P_prior_up +
                           P_E_given_down * P_prior_down;

      double P_up_post;
      if(denominator > 0.0)
         P_up_post = numerator / denominator;
      else
         P_up_post = 0.5;   // нет данных — нейтрально

      // Защита от выхода за [0, 1] из-за погрешностей
      if(P_up_post > 1.0) P_up_post = 1.0;
      if(P_up_post < 0.0) P_up_post = 0.0;

      //--- Сохраняем сырую вероятность (всегда, чтобы буфер был полным)
      SignalRawBuffer[i] = P_up_post;

      //--- 3.4. Энтропия Шеннона
      double H;
      if(P_up_post <= 0.0 || P_up_post >= 1.0)
         H = 0.0;
      else
      {
         double p = P_up_post;
         H = -p * Log2(p) - (1.0 - p) * Log2(1.0 - p);
      }

      rawEntropy[i] = H;
   }

//--- 4. Сглаживание SMA (применяется ТОЛЬКО для отображения)
//    SMA[i] = среднее(raw[i] .. raw[i + SmoothingPeriod - 1])
//    (time‑series: индексы растут = более старые бары)
   for(int i = start; i <= limit; i++)
   {
      int    smoothStart = i;
      int    smoothEnd   = MathMin(rates_total - 1, i + SmoothingPeriod - 1);
      int    count       = smoothEnd - smoothStart + 1;
      double sumSignal   = 0.0;
      double sumEntropy  = 0.0;

      for(int j = smoothStart; j <= smoothEnd; j++)
      {
         sumSignal  += SignalRawBuffer[j];
         sumEntropy += rawEntropy[j];
      }

      if(count > 0)
      {
         SignalBuffer[i]  = sumSignal  / (double)count;
         EntropyBuffer[i] = sumEntropy / (double)count;
      }
      else
      {
         SignalBuffer[i]  = SignalRawBuffer[i];
         EntropyBuffer[i] = rawEntropy[i];
      }
   }

//--- 5.3. Закраска фона (использует МГНОВЕННУЮ энтропию, не сглаженную)
   UpdateBackground(time, rawEntropy, rates_total);

//--- 5.4. Текстовая метка в левом верхнем углу
   double currentRawSignal  = (rates_total > 0) ? SignalRawBuffer[0] : 0.5;
   double currentRawEntropy = (rates_total > 0) ? rawEntropy[0]        : 1.0;
   UpdateLabel(currentRawEntropy, currentRawSignal);

//--- Возвращаем количество обработанных баров
   return(rates_total);
}
//+------------------------------------------------------------------+