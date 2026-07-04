/*
 * INAV pid_autotune.c — 固定翼 Autotune 核心算法源码
 *
 * 来源: https://github.com/iNavFlight/inav/blob/master/src/main/flight/pid_autotune.c
 * 文件大小: 10,582 字节 (~300行)
 * 协议: GPL v3
 *
 * 采集日期: 2026-05-24
 * 说明: 仅保留核心算法，移除 #include 和黑盒日志等非核心代码
 */

// ============================================================
// 常量定义
// ============================================================

#define AUTOTUNE_FIXED_WING_MIN_FF                   10       // FF最小值
#define AUTOTUNE_FIXED_WING_MAX_FF                   255      // FF最大值
#define AUTOTUNE_FIXED_WING_MIN_ROLL_PITCH_RATE      40       // Roll/Pitch最小Rate (deg/s × 10)
#define AUTOTUNE_FIXED_WING_MIN_YAW_RATE             10       // Yaw最小Rate (deg/s × 10)
#define AUTOTUNE_FIXED_WING_MAX_RATE                 720      // 最大Rate (deg/s × 10)
#define AUTOTUNE_FIXED_WING_CONVERGENCE_RATE         10       // EMA收敛速率 (%)
#define AUTOTUNE_FIXED_WING_SAMPLE_INTERVAL          20       // 采样间隔 (ms)
#define AUTOTUNE_FIXED_WING_SAMPLES                  1000     // 移动平均窗口 (约20秒)
#define AUTOTUNE_FIXED_WING_MIN_SAMPLES              250      // 最小采样数才开始调整 (约5秒)

#define AUTOTUNE_SAVE_PERIOD                         5000     // 快照保存间隔 (ms)

// ============================================================
// 数据结构
// ============================================================

typedef enum {
    DEMAND_TOO_LOW,
    DEMAND_UNDERSHOOT,
    DEMAND_OVERSHOOT,
    TUNE_UPDATED,
} pidAutotuneState_e;

// 每轴的 Autotune 状态
typedef struct {
    float       gainFF;                 // 当前FF增益（会被持续更新）
    float       rate;                   // 当前最大角速率 (deg/s × 10)
    float       initialRate;            // 初始速率（安全回退用）
    float       absDesiredRateAccum;    // 期望角速率的移动平均
    float       absReachedRateAccum;    // 实际角速率的移动平均
    float       absPidOutputAccum;      // PID输出量的移动平均
    uint32_t    updateCount;            // 采样计数
} pidAutotuneData_t;

// 全局状态
static pidAutotuneData_t  tuneCurrent[XYZ_AXIS_COUNT];  // 当前调参状态
static pidAutotuneData_t  tuneSaved[XYZ_AXIS_COUNT];    // 保存的快照（用于退出恢复）
static timeMs_t           lastGainsUpdateTime;

// ============================================================
// 将调参结果应用到PID控制器
// ============================================================

void autotuneUpdateGains(pidAutotuneData_t * data)
{
    for (int axis = 0; axis < XYZ_AXIS_COUNT; axis++) {
        // 🔑 将FF增益写入PID配置
        pidBankMutable()->pid[axis].FF = lrintf(data[axis].gainFF);
        // 🔑 将速率写入控制配置
        ((controlConfig_t *)currentControlProfile)->stabilized.rates[axis] = lrintf(data[axis].rate / 10.0f);
    }
    schedulePidGainsUpdate();
}

// ============================================================
// 定期保存快照（每5秒）
// ============================================================

void autotuneCheckUpdateGains(void)
{
    const timeMs_t currentTimeMs = millis();

    if ((currentTimeMs - lastGainsUpdateTime) < AUTOTUNE_SAVE_PERIOD) {
        return;
    }

    // 保存当前状态，退出autotune时会恢复此快照
    memcpy(tuneSaved, tuneCurrent, sizeof(pidAutotuneData_t) * XYZ_AXIS_COUNT);
    autotuneUpdateGains(tuneSaved);
    lastGainsUpdateTime = currentTimeMs;
}

// ============================================================
// 启动 Autotune
// ============================================================

void autotuneStart(void)
{
    for (int axis = 0; axis < XYZ_AXIS_COUNT; axis++) {
        // 🔑 从当前PID配置读取初始FF和Rate
        tuneCurrent[axis].gainFF      = pidBank()->pid[axis].FF;
        tuneCurrent[axis].rate        = currentControlProfile->stabilized.rates[axis] * 10.0f;
        tuneCurrent[axis].initialRate = currentControlProfile->stabilized.rates[axis] * 10.0f;

        // 清零累积器
        tuneCurrent[axis].absDesiredRateAccum = 0;
        tuneCurrent[axis].absReachedRateAccum = 0;
        tuneCurrent[axis].absPidOutputAccum   = 0;
        tuneCurrent[axis].updateCount         = 0;
    }

    // 初始快照 = 当前值
    memcpy(tuneSaved, tuneCurrent, sizeof(pidAutotuneData_t) * XYZ_AXIS_COUNT);
    lastGainsUpdateTime = millis();
}

// ============================================================
// 状态机：激活/停止 Autotune
// ============================================================

void autotuneUpdateState(void)
{
    // 条件：AUTOTUNE模式开关打开 + 固定翼 + 已解锁
    if (isFwAutoModeActive(BOXAUTOTUNE) && STATE(AIRPLANE) && ARMING_FLAG(ARMED)) {
        if (!FLIGHT_MODE(AUTO_TUNE)) {
            autotuneStart();
            ENABLE_FLIGHT_MODE(AUTO_TUNE);
        } else {
            autotuneCheckUpdateGains();
        }
    } else {
        // 🔑 退出时恢复上次保存的快照
        if (FLIGHT_MODE(AUTO_TUNE)) {
            autotuneUpdateGains(tuneSaved);
        }
        DISABLE_FLIGHT_MODE(AUTO_TUNE);
    }
}

// ============================================================
// ★★★ 核心：固定翼 Autotune 算法 ★★★
// ============================================================

void autotuneFixedWingUpdate(
    const flight_dynamics_index_t axis,
    float desiredRate,      // 期望角速率（setpoint）
    float reachedRate,      // 实际角速率（gyro）
    float pidOutput         // PID控制器输出
)
{
    float maxRateSetting   = tuneCurrent[axis].rate;
    float gainFF           = tuneCurrent[axis].gainFF;
    float maxDesiredRate   = maxRateSetting;

    const float pidSumLimit = getPidSumLimit(axis);

    // 取绝对值
    const float absDesiredRate = fabsf(desiredRate);
    const float absReachedRate = fabsf(reachedRate);
    const float absPidOutput   = fabsf(pidOutput);

    // 🔑 方向一致性检查：响应方向必须与指令一致
    const bool correctDirection = (desiredRate > 0) == (reachedRate > 0);

    float rateFullStick;

    bool gainsUpdated = false;
    bool ratesUpdated = false;

    const timeMs_t currentTimeMs = millis();
    static timeMs_t previousSampleTimeMs = 0;
    const timeDelta_t timeSincePreviousSample = currentTimeMs - previousSampleTimeMs;

    // ANGLE模式下使用不同的最大速率
    if (FLIGHT_MODE(ANGLE_MODE)) {
        float maxDesiredRateInAngleMode =
            DECIDEGREES_TO_DEGREES(pidProfile()->max_angle_inclination[axis] * 1.0f)
            * pidBank()->pid[PID_LEVEL].P
            * FP_PID_LEVEL_P_MULTIPLIER;
        maxDesiredRate = MIN(maxRateSetting, maxDesiredRateInAngleMode);
    }

    // 🔑 摇杆输入比例
    const float stickInput = absDesiredRate / maxDesiredRate;

    // ============================================================
    // 采样条件：摇杆够大 + 方向正确 + 时间间隔足够
    // ============================================================
    if ((stickInput > (pidAutotuneConfig()->fw_min_stick / 100.0f))
        && correctDirection
        && (timeSincePreviousSample >= AUTOTUNE_FIXED_WING_SAMPLE_INTERVAL)) {

        // ── 更新采样计数 ──
        tuneCurrent[axis].updateCount++;

        // ========================================================
        // 🔑 移动平均计算（EMA变体，窗口=1000）
        // ========================================================
        tuneCurrent[axis].absDesiredRateAccum +=
            (absDesiredRate - tuneCurrent[axis].absDesiredRateAccum)
            / MIN(tuneCurrent[axis].updateCount, (uint32_t)AUTOTUNE_FIXED_WING_SAMPLES);

        tuneCurrent[axis].absReachedRateAccum +=
            (absReachedRate - tuneCurrent[axis].absReachedRateAccum)
            / MIN(tuneCurrent[axis].updateCount, (uint32_t)AUTOTUNE_FIXED_WING_SAMPLES);

        tuneCurrent[axis].absPidOutputAccum +=
            (absPidOutput - tuneCurrent[axis].absPidOutputAccum)
            / MIN(tuneCurrent[axis].updateCount, (uint32_t)AUTOTUNE_FIXED_WING_SAMPLES);

        // ========================================================
        // 🔑 每25个采样 & 至少250个采样后触发更新
        // ========================================================
        if ((tuneCurrent[axis].updateCount & 25) == 0
            && tuneCurrent[axis].updateCount >= AUTOTUNE_FIXED_WING_MIN_SAMPLES) {

            // ── Rate 发现（非ANGLE模式、非FIXED模式） ──
            if (pidAutotuneConfig()->fw_rate_adjustment != FIXED
                && !FLIGHT_MODE(ANGLE_MODE)) {

                // 目标舵面偏转 = 80%（默认）的PID输出限制
                float pidSumTarget =
                    (pidAutotuneConfig()->fw_max_rate_deflection / 100.0f) * pidSumLimit;

                // 推算满舵能达到的最大角速率
                // rateFullStick = (目标偏转 / 平均PID输出) × 平均实际速率
                rateFullStick =
                    pidSumTarget
                    / tuneCurrent[axis].absPidOutputAccum
                    * tuneCurrent[axis].absReachedRateAccum;

                // 步进调整（每次 +/− 10 deg/s）
                if (rateFullStick > (maxRateSetting + 10.0f)) {
                    maxRateSetting += 10.0f;
                } else if (rateFullStick < (maxRateSetting - 10.0f)) {
                    maxRateSetting -= 10.0f;
                }

                // 安全限制
                uint16_t minRate = (axis == FD_YAW)
                    ? AUTOTUNE_FIXED_WING_MIN_YAW_RATE
                    : AUTOTUNE_FIXED_WING_MIN_ROLL_PITCH_RATE;

                uint16_t maxRate = (pidAutotuneConfig()->fw_rate_adjustment == AUTO)
                    ? AUTOTUNE_FIXED_WING_MAX_RATE
                    : MAX(tuneCurrent[axis].initialRate, minRate);

                tuneCurrent[axis].rate = constrainf(maxRateSetting, minRate, maxRate);
                ratesUpdated = true;
            }

            // ====================================================
            // ★★★ FF增益更新 — 核心收敛公式 ★★★
            // ====================================================
            //
            // targetFF = mean(|PID_Output|) / mean(|ReachedRate|) × 31.0
            //
            // gainFF   = gainFF + (targetFF - gainFF) × 0.10
            //           ↑ EMA 收敛，每步仅向目标靠近10%
            //
            // constrain(gainFF, 10, 255)
            //
            gainFF +=
                (tuneCurrent[axis].absPidOutputAccum
                 / tuneCurrent[axis].absReachedRateAccum
                 * FP_PID_RATE_FF_MULTIPLIER          // = 31.0f
                 - gainFF)
                * (AUTOTUNE_FIXED_WING_CONVERGENCE_RATE / 100.0f);  // = 0.10

            tuneCurrent[axis].gainFF =
                constrainf(gainFF, AUTOTUNE_FIXED_WING_MIN_FF, AUTOTUNE_FIXED_WING_MAX_FF);

            gainsUpdated = true;
        }

        // 重置采样定时器
        previousSampleTimeMs = currentTimeMs;
    }

    // ========================================================
    // 应用更新到PID控制器
    // ========================================================
    if (gainsUpdated) {
        autotuneUpdateGains(tuneCurrent);
        // ... 黑盒日志记录 ...
        gainsUpdated = false;
    }

    if (ratesUpdated) {
        autotuneUpdateGains(tuneCurrent);
        // ... 黑盒日志记录 + debug输出 ...
        ratesUpdated = false;
    }
}
