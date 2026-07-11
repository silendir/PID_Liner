//
//  PIDReverseSolver.m
//  PID_Liner
//
//  反向求解实现: LM + 数值雅可比, 直接优化 forward(PID,mech)→targetCurve
//

#import "PIDReverseSolver.h"
#import "BFPIDToSecondOrderMapper.h"  // BFForwardModelParams + predictedCurveWithParams
#import <math.h>

#pragma mark - 物理约束常量

static const double kPIDEpsilon = 1e-9;
static const double kFFNorm     = 120.0;   ///< FF 归一化基准 (BF 默认 FF=120)

#pragma mark - LM 超参数

static const NSInteger kMaxIter     = 100;
static const double    kRMSETol      = 1e-4;   ///< 收敛 RMSE 阈值
static const double    kLambdaInit   = 1e-3;
static const double    kLambdaUp     = 3.0;    ///< 拒绝步: 增阻尼
static const double    kLambdaDown   = 0.3;    ///< 接受步: 减阻尼
static const double    kJacStep      = 1e-6;   ///< 数值雅可比相对步长

#pragma mark - BFMechConstants

@implementation BFMechConstants

+ (instancetype)withKPlant:(double)kPlant tauM:(double)tauM dScale:(double)dScale {
    BFMechConstants *m = [[BFMechConstants alloc] init];
    m.kPlant = kPlant;
    m.tauM   = tauM;
    m.dScale = dScale;
    return m;
}

@end

#pragma mark - BFFilterConfig

@implementation BFFilterConfig

/// Butterworth Q 常量 (最大化平坦通带)
static const double kButterworthQ = 0.7071067811865476;

+ (instancetype)noFilter {
    BFFilterConfig *f = [[BFFilterConfig alloc] init];
    f.gyroLowpassHz  = 0.0;
    f.dtermLowpassHz = 0.0;
    f.q              = kButterworthQ;
    return f;
}

+ (instancetype)gyroLowpass:(double)hz {
    BFFilterConfig *f = [[BFFilterConfig alloc] init];
    f.gyroLowpassHz  = hz;       // 0 = 不滤波 (gyroLowpass:0 也合法)
    f.dtermLowpassHz = 0.0;
    f.q              = kButterworthQ;
    return f;
}

/// [3.3b] BF 真实 gyro 通道三级 PT1 链 (type=0, 来自 BBL header)
/// 001.bbl: gyro_lowpass=200 / gyro_lowpass2=250 / gyro_lowpass_dyn=200-500(随油门)
/// 任一级 h≤0 跳过该级; dyn 取定值 (阶跃统计平均, 油门混合, 取下限≈低油门)
+ (instancetype)gyroPT1Chain:(double)h1 h2:(double)h2 dyn:(double)hdyn {
    BFFilterConfig *f = [[BFFilterConfig alloc] init];
    f.gyroLowpassHz  = 0.0;
    f.dtermLowpassHz = 0.0;
    f.q              = kButterworthQ;
    f.gyroPT1Hz      = h1;    // gyro_lowpass (001:200)
    f.gyroPT1_2Hz    = h2;    // gyro_lowpass2 (001:250)
    f.gyroPT1DynHz   = hdyn;  // gyro_lowpass_dyn (001:200-500, 取定值)
    return f;
}

/// [3.3b-2b] BF 真实 dterm 通道三级 PT1 链 (type=0, 来自 BBL header)
/// 001.bbl: dterm_lowpass=150 / dterm_lowpass2=150 / dterm_lowpass_dyn=70-170(随油门)
/// 作用于 D 项信号 (陀螺导数), 每步内更新; 与 gyro 链 (整段后处理) 作用点不同
/// gyro 直通; 任一级 h≤0 跳过该级; dyn 取定值 (阶跃统计平均, 取中值≈120)
+ (instancetype)dtermPT1Chain:(double)h1 h2:(double)h2 dyn:(double)hdyn {
    BFFilterConfig *f = [[BFFilterConfig alloc] init];
    f.gyroLowpassHz  = 0.0;
    f.dtermLowpassHz = 0.0;
    f.q              = kButterworthQ;
    f.dtermPT1Hz     = h1;    // dterm_lowpass (001:150)
    f.dtermPT1_2Hz   = h2;    // dterm_lowpass2 (001:150)
    f.dtermPT1DynHz  = hdyn;  // dterm_lowpass_dyn (001:70-170, 取定值)
    return f;
}

@end

#pragma mark - PIDReverseSolveResult

@implementation PIDReverseSolveResult
@end

#pragma mark - C 辅助: 解 n×n 线性方程组 (Gauss-Jordan 带主元, 原地)

/// 解 A·x = b, 解存入 b (原地修改 A, b)。n ∈ [1,4]。
/// ponytail: 矩阵最大 4×4, 手写通用 n×n 比硬编码 4×4 更短更不易错。
static void SolveLinearSystem(double *A, double *b, int n) {
    for (int col = 0; col < n; col++) {
        // 列主元选取
        int pivot = col;
        double maxVal = fabs(A[col * n + col]);
        for (int row = col + 1; row < n; row++) {
            double v = fabs(A[row * n + col]);
            if (v > maxVal) { maxVal = v; pivot = row; }
        }
        if (maxVal < 1e-18) { b[col] = 0.0; continue; }  // ponytail: 奇异列, step 置 0
        if (pivot != col) {
            for (int c = 0; c < n; c++) {
                double t = A[col * n + c]; A[col * n + c] = A[pivot * n + c]; A[pivot * n + c] = t;
            }
            double t = b[col]; b[col] = b[pivot]; b[pivot] = t;
        }
        double piv = A[col * n + col];
        for (int c = col; c < n; c++) A[col * n + c] /= piv;
        b[col] /= piv;
        for (int row = 0; row < n; row++) {
            if (row == col) continue;
            double factor = A[row * n + col];
            if (factor == 0.0) continue;
            for (int c = col; c < n; c++) A[row * n + c] -= factor * A[col * n + c];
            b[row] -= factor * b[col];
        }
    }
}

#pragma mark - C 辅助: biquad 低通 (RBJ cookbook, Direct Form I)

/// 对 in[0..n-1] 做 biquad lowpass, 输出 out (可与 in 同缓冲, 非法参数直通)
/// fs=采样率 Hz, fc=截止 Hz, Q=品质因数 (Butterworth=0.7071)
/// 数学: H(z)=(b0+b1·z⁻¹+b2·z⁻²)/(1+a1·z⁻¹+a2·z⁻²); DC 增益恒 1 → 稳态不变, 只抹瞬态
/// 物理对应: BF gyro_lowpass 涂抹真实响应上升沿 (高频被滤, 上升变缓)
static void ApplyBiquadLowpass(const double *in, double *out, NSInteger n,
                               double fs, double fc, double Q) {
    // 🔑 非法参数直通 (fc≥Nyquist 或负值无意义)
    if (n <= 0 || fs <= 0 || fc <= 0 || fc >= fs * 0.5 || Q <= 0) {
        if (in != out) for (NSInteger k = 0; k < n; k++) out[k] = in[k];
        return;
    }
    double w0    = 2.0 * M_PI * fc / fs;
    double cosw0 = cos(w0);
    double sinw0 = sin(w0);
    double alpha = sinw0 / (2.0 * Q);
    double a0    = 1.0 + alpha;
    double b0    = ((1.0 - cosw0) * 0.5) / a0;
    double b1    = (1.0 - cosw0) / a0;
    double b2    = ((1.0 - cosw0) * 0.5) / a0;
    double a1    = (-2.0 * cosw0) / a0;
    double a2    = (1.0 - alpha) / a0;

    double x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0;  // 初始状态: 阶跃前静止
    for (NSInteger k = 0; k < n; k++) {
        double x0 = in[k];
        double y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
        out[k] = y0;
        x2 = x1; x1 = x0;
        y2 = y1; y1 = y0;
    }
}

#pragma mark - C 辅助: PT1 低通 (BF pt1Filter 等价, type=0)

/// 对 in[0..n-1] 做一阶低通 (BF pt1FilterApply), 输出 out (可与 in 同缓冲, 原地安全)
/// fs=采样率 Hz, fc=截止 Hz
/// 数学: y[k] = y[k-1] + gain·(x[k] − y[k-1]); gain = dt/(RC+dt), RC = 1/(2π·fc)
/// DC 增益恒 1 → 稳态不变, 只抹瞬态 (与 biquad 同性质, 但一阶非二阶)
/// 物理对应: BF gyro_lowpass 真实类型 (001.bbl gyro_lowpass_type=0 → PT1)
static void ApplyPT1Lowpass(const double *in, double *out, NSInteger n,
                            double fs, double fc) {
    // 🔑 非法参数直通 (fc≥Nyquist 或非正无意义)
    if (n <= 0 || fs <= 0 || fc <= 0 || fc >= fs * 0.5) {
        if (in != out) for (NSInteger k = 0; k < n; k++) out[k] = in[k];
        return;
    }
    double dt   = 1.0 / fs;
    double RC   = 1.0 / (2.0 * M_PI * fc);
    double gain = dt / (RC + dt);
    if (gain > 1.0) gain = 1.0;  // ponytail: 物理约束 gain∈(0,1]
    double y = 0.0;  // 初始状态: 阶跃前静止 (与二阶起步 0 一致)
    for (NSInteger k = 0; k < n; k++) {
        y += gain * (in[k] - y);
        out[k] = y;
    }
}

#pragma mark - C 辅助: gyro 低通链公共逻辑 (3.3a/b 解析+时域 forward 共用)

/// 对 buf[0..N-1] 原地施加 gyro 低通链 (PT1链优先 > biquad > 直通)
/// 模拟 BF gyro 通道对响应上升沿的涂抹; 解析 forward 与时域 forward 共用此函数 (去重)
/// 返回 YES=已滤波 (buf 被修改); NO=直通 (filter=nil / 参数非法 / malloc失败)
static BOOL ApplyGyroLowpassChain(double *buf, NSInteger N, double fs, BFFilterConfig *filter) {
    if (!filter || N <= 2 || fs <= 0) return NO;

    // [3.3b] PT1 链: BF 真实 gyro 三级低通串联 (type=0, 线性可交换)
    double pt1Fcs[3] = {filter.gyroPT1Hz, filter.gyroPT1_2Hz, filter.gyroPT1DynHz};
    BOOL hasPT1 = NO;
    for (int s = 0; s < 3; s++) if (pt1Fcs[s] > 0 && pt1Fcs[s] < fs * 0.5) hasPT1 = YES;
    if (hasPT1) {
        for (int s = 0; s < 3; s++) {
            if (pt1Fcs[s] > 0 && pt1Fcs[s] < fs * 0.5) {
                ApplyPT1Lowpass(buf, buf, N, fs, pt1Fcs[s]);  // 原地串联
            }
        }
        return YES;
    }

    // [3.3a] biquad 单级 (合成对照资产, 保留)
    if (filter.gyroLowpassHz > 0 && filter.gyroLowpassHz < fs * 0.5) {
        double *out = (double *)malloc((size_t)N * sizeof(double));
        if (!out) return NO;  // ponytail: malloc 失败直通 (降级而非崩溃)
        double qVal = (filter.q > 0) ? filter.q : kButterworthQ;
        ApplyBiquadLowpass(buf, out, N, fs, filter.gyroLowpassHz, qVal);
        memcpy(buf, out, (size_t)N * sizeof(double));
        free(out);
        return YES;
    }
    return NO;
}

#pragma mark - C 辅助: 时域 PID 闭环积分 (3.3b-2a 骨架 / 2b D 路径三级低通)
//
// 物理模型 (纯 PD 与解析 forward 同特征方程; 加 dterm 滤波后 D 时变, 解析失效):
//   error    = setpoint - y                 (setpoint=1, 归一化阶跃)
//   output   = Kp·error + I_state − Kd_eff·dtermFB + ffImpulse
//              (dtermFB = PT1_chain(ẏ) [2b] 或 原始 ẏ [2a]; BF D-on-measurement)
//   plant:   τ_m·ÿ + ẏ = K_plant·output     →  ÿ = (K_plant·output − ẏ) / τ_m
//
// 特征方程 (纯PD无滤波): τ_m·s² + (1+K_plant·Kd_eff)·s + K_plant·Kp = 0
//   → ωn = √(K_plant·Kp/τ_m),  ζ = (1+K_plant·Kd_eff)/(2·τ_m·ωn)
//   与解析 forwardCurveWithPID: 完全一致 → 纯 PD (dtermFc 全 0) 时域对齐解析 h(t)
//
// I_state / ffImpulse / dtermFB 在单个 RK4 步内视为常数 (步前 Euler 更新 I 与三级 PT1)

/// 单步 PT1 更新 (BF pt1FilterUpdate 等价), 原地更新 *state, 返回新状态
/// fc≤0 直通 (state=input); gain 物理约束 ∈(0,1], fc≥Nyquist 自然饱和到 1
/// ponytail: 时域 D 路径每步更新三级 PT1, 不能用整段版 ApplyPT1Lowpass
static inline double PT1Step(double input, double *state, double dt, double fc) {
    if (fc <= 0.0) { *state = input; return input; }  // 该级跳过 = 直通
    double RC   = 1.0 / (2.0 * M_PI * fc);
    double gain = dt / (RC + dt);
    if (gain > 1.0) gain = 1.0;
    *state += gain * (input - *state);
    return *state;
}

/// 状态 [y, v=ẏ] 的导数 (RK4 用)
/// dtermFB = D 项反馈信号 (已滤波或原始 v, 由调用方决定)
static void PIDPlantDeriv(double y, double v, double dtermFB,
                          double Kp, double Kd_eff, double I_state, double ffImpulse,
                          double K_plant, double tauM,
                          double *dy, double *dv) {
    double error  = 1.0 - y;
    double output = Kp * error + I_state - Kd_eff * dtermFB + ffImpulse;
    *dy = v;
    *dv = (K_plant * output - v) / tauM;
}

/// RK4 单步 (步内 I_state / ffImpulse / dtermFB 固定)
/// freezeD=YES 时 D 项用 dtermFrozen (BF 离散循环: D 每步算一次, 步内不变);
/// freezeD=NO 时 D 项跟踪各子步的 v (2a 纯 PD 对齐解析 h(t) 路径)
static void RK4Step(double *y, double *v, double dt,
                    double Kp, double Kd_eff, double I_state, double ffImpulse,
                    double K_plant, double tauM,
                    BOOL freezeD, double dtermFrozen) {
    double k1y, k1v, k2y, k2v, k3y, k3v, k4y, k4v;
    // 子步 1
    double d1 = freezeD ? dtermFrozen : *v;
    PIDPlantDeriv(*y, *v, d1, Kp,Kd_eff,I_state,ffImpulse, K_plant,tauM, &k1y,&k1v);
    // 子步 2
    double vs2 = *v + 0.5 * dt * k1v;
    double d2  = freezeD ? dtermFrozen : vs2;
    PIDPlantDeriv(*y + 0.5*dt*k1y, vs2, d2, Kp,Kd_eff,I_state,ffImpulse, K_plant,tauM, &k2y,&k2v);
    // 子步 3
    double vs3 = *v + 0.5 * dt * k2v;
    double d3  = freezeD ? dtermFrozen : vs3;
    PIDPlantDeriv(*y + 0.5*dt*k2y, vs3, d3, Kp,Kd_eff,I_state,ffImpulse, K_plant,tauM, &k3y,&k3v);
    // 子步 4
    double vs4 = *v + dt * k3v;
    double d4  = freezeD ? dtermFrozen : vs4;
    PIDPlantDeriv(*y + dt*k3y, vs4, d4, Kp,Kd_eff,I_state,ffImpulse, K_plant,tauM, &k4y,&k4v);

    *y += dt/6.0 * (k1y + 2.0*k2y + 2.0*k3y + k4y);
    *v += dt/6.0 * (k1v + 2.0*k2v + 2.0*k3v + k4v);
}

/// 时域 PID 闭环仿真主循环 (RK4), 输出 out[0..N-1]
/// out[k] = 第 k 步积分前的 y (对应 t=k·dt, 与解析 h(t) 采样对齐)
/// ffImpulse 仅 k=0 注入 (阶跃 setpoint 微分 = 冲激, 过 plant 平滑)
/// I_state 带 anti-windup 限幅 (±2·Kp, 防积分饱和失稳)
/// D 路径三级 PT1 (dtermFc1/2/3, 来自 BF dterm_lowpass/2/dyn): 每步前用当前 v
///   更新三级状态, 步内 D 冻结 (BF 离散行为); 全 0 = 无滤波, D 跟踪 v (2a 对齐)
static void SimulatePIDTimeDomain(double *out, NSInteger N, double dt,
                                  double Kp, double Ki, double Kd_eff, double Kff_norm,
                                  double K_plant, double tauM,
                                  double dtermFc1, double dtermFc2, double dtermFc3) {
    double y = 0.0, v = 0.0;                    // 初始静止 (阶跃前)
    double I_state = 0.0;
    double I_limit = fabs(Kp) * 2.0;            // ponytail: anti-windup 上限
    BOOL hasI  = (Ki > 1e-9);
    BOOL hasFF = (Kff_norm > 1e-9);
    BOOL hasDtermFilter = (dtermFc1 > 0.0 || dtermFc2 > 0.0 || dtermFc3 > 0.0);
    double d1 = 0.0, d2 = 0.0, d3 = 0.0;        // 三级 PT1 状态 (初始静止)

    for (NSInteger k = 0; k < N; k++) {
        // FF 前馈: 仅第 0 步注入 Kff_norm·Δsetpoint (BF 离散循环: 单位阶跃 Δsetpoint=1,
        //   FF 输出 = Kff·1, 一轮; 不除 dt — 2a 曾误用 Kff/dt 连续冲激框架致峰值 5.96)
        double ffImpulse = (k == 0 && hasFF) ? Kff_norm : 0.0;
        // I 积分 (Euler 步前更新, 限幅)
        if (hasI) {
            double err = 1.0 - y;
            I_state += Ki * err * dt;
            if (I_state >  I_limit) I_state =  I_limit;
            if (I_state < -I_limit) I_state = -I_limit;
        }
        // D 路径: 三级 PT1 滤波陀螺导数 v (BF D-on-measurement), 步内冻结
        double dtermFB;
        if (hasDtermFilter) {
            PT1Step(v, &d1, dt, dtermFc1);  // stage 1 (fc≤0 直通)
            PT1Step(d1, &d2, dt, dtermFc2); // stage 2
            PT1Step(d2, &d3, dt, dtermFc3); // stage 3
            dtermFB = d3;
        } else {
            dtermFB = v;  // 无滤波: RK4 子步内由 freezeD=NO 跟踪 v (2a 对齐)
        }
        out[k] = y;                             // 记录 (步前, 对齐解析 t=k·dt)
        RK4Step(&y, &v, dt, Kp, Kd_eff, I_state, ffImpulse, K_plant, tauM,
                hasDtermFilter, dtermFB);
    }
}

#pragma mark - PIDReverseSolver

@implementation PIDReverseSolver

#pragma mark - 绝对 forward

+ (NSArray<NSNumber *> *)forwardCurveWithPID:(PIDValues *)pid
                               mechConstants:(BFMechConstants *)mech
                                       length:(NSInteger)length
                                     duration:(double)duration {
    // 旧接口转调带滤波版 (nil=不滤波, 向后兼容 3.1/3.2 现有测试)
    return [self forwardCurveWithPID:pid mechConstants:mech filterConfig:nil
                              length:length duration:duration];
}

+ (NSArray<NSNumber *> *)forwardCurveWithPID:(PIDValues *)pid
                               mechConstants:(BFMechConstants *)mech
                               filterConfig:(BFFilterConfig *)filter
                                       length:(NSInteger)length
                                     duration:(double)duration {
    // 🔑 输入校验
    if (!pid || !mech || length < 2 || duration <= 0) return @[@0.0];
    if (mech.tauM <= 0 || mech.kPlant < 0) {
        NSLog(@"⚠️ [ReverseSolver.forward] 机械常数非法 kPlant=%.4g tauM=%.4g", mech.kPlant, mech.tauM);
        return @[@0.0];
    }

    double p = fmax(pid.p, kPIDEpsilon);
    double i = pid.i;
    double d = pid.d;
    double ff = pid.ff;

    // 特征方程 → 二阶参数 (推导见 .h)
    double wn   = sqrt(mech.kPlant * p / mech.tauM);
    double zeta = (1.0 + mech.kPlant * d * mech.dScale) / (2.0 * mech.tauM * wn);

    BFForwardModelParams *params = [BFForwardModelParams new];
    params.gain          = 1.0;
    params.naturalFreq   = wn;
    params.dampingRatio  = zeta;
    params.integralTau   = (i > kPIDEpsilon) ? (p / i) : 0.0;
    params.feedforwardScale = ff / kFFNorm;

    NSArray<NSNumber *> *raw = [BFPIDToSecondOrderMapper predictedCurveWithParams:params
                                                                            length:length
                                                                          duration:duration];

    // 3.3a/3.3b: 过 gyro 低通链 (公共函数 ApplyGyroLowpassChain, 与时域 forward 共用)
    if (filter && raw.count > 2) {
        double fs = (double)(length - 1) / duration;  // 与 predictedCurve 的 dt 一致
        NSInteger n = (NSInteger)raw.count;
        double *buf = (double *)malloc((size_t)n * sizeof(double));
        if (buf) {
            for (NSInteger k = 0; k < n; k++) buf[k] = raw[k].doubleValue;
            ApplyGyroLowpassChain(buf, n, fs, filter);  // 原地; 失败/直通不影响正确性
            NSMutableArray<NSNumber *> *filtered = [NSMutableArray arrayWithCapacity:n];
            for (NSInteger k = 0; k < n; k++) [filtered addObject:@(buf[k])];
            free(buf);
            return [filtered copy];
        }
        // ponytail: malloc 失败回退 raw (降级而非崩溃)
    }
    return raw;
}

#pragma mark - [3.3b-2a] 时域数值积分 forward (物理 PID 闭环)

+ (NSArray<NSNumber *> *)forwardCurveTimeDomainWithPID:(PIDValues *)pid
                                          mechConstants:(BFMechConstants *)mech
                                          filterConfig:(BFFilterConfig *)filter
                                                 length:(NSInteger)length
                                               duration:(double)duration {
    // 🔑 输入校验 (与解析版一致)
    if (!pid || !mech || length < 2 || duration <= 0) return @[@0.0];
    if (mech.tauM <= 0 || mech.kPlant < 0) {
        NSLog(@"⚠️ [ReverseSolver.tdForward] 机械常数非法 kPlant=%.4g tauM=%.4g", mech.kPlant, mech.tauM);
        return @[@0.0];
    }

    NSInteger N = length;
    double dt = duration / (double)(N - 1);

    // 控制器系数 (Kd_eff = D·dScale, 与解析特征方程一致)
    double Kp       = fmax(pid.p, kPIDEpsilon);
    double Ki       = pid.i;
    double Kd_eff   = pid.d * mech.dScale;
    double Kff_norm = pid.ff / kFFNorm;

    double *buf = (double *)malloc((size_t)N * sizeof(double));
    if (!buf) return @[@0.0];

    // D 路径三级 PT1 截止 (来自 filter, 全 0 = 无滤波走 2a 对齐路径)
    double dFc1 = filter.dtermPT1Hz;
    double dFc2 = filter.dtermPT1_2Hz;
    double dFc3 = filter.dtermPT1DynHz;

    // RK4 时域积分 (物理 PID 闭环 + 二阶 plant, D 路径三级 PT1)
    SimulatePIDTimeDomain(buf, N, dt, Kp, Ki, Kd_eff, Kff_norm, mech.kPlant, mech.tauM,
                          dFc1, dFc2, dFc3);

    // gyro 低通链 (与解析版同语义, 共用公共函数)
    if (filter) {
        double fs = 1.0 / dt;
        ApplyGyroLowpassChain(buf, N, fs, filter);
    }

    NSMutableArray<NSNumber *> *curve = [NSMutableArray arrayWithCapacity:N];
    for (NSInteger k = 0; k < N; k++) [curve addObject:@(buf[k])];
    free(buf);
    return [curve copy];
}

#pragma mark - 内部: PIDValues 与 double[4] 互转

+ (void)applyCur:(const double *)cur toPID:(PIDValues *)pid {
    pid.p  = cur[0];
    pid.i  = cur[1];
    pid.d  = cur[2];
    pid.ff = cur[3];
}

/// forward 结果写入 C double 数组 (LM 主循环用, 避免反复 NSNumber 解包)
+ (void)fillForwardDouble:(double *)out
                   fromPID:(PIDValues *)pid
              mechConstants:(BFMechConstants *)mech
              filterConfig:(BFFilterConfig *)filter
                    length:(NSInteger)N
                  duration:(double)duration {
    NSArray<NSNumber *> *curve = [self forwardCurveWithPID:pid mechConstants:mech filterConfig:filter length:N duration:duration];
    NSInteger n = MIN(N, (NSInteger)curve.count);
    for (NSInteger k = 0; k < n; k++) out[k] = curve[k].doubleValue;
    for (NSInteger k = n; k < N; k++) out[k] = 0.0;
}

#pragma mark - 反解主流程 (LM)

- (nullable PIDReverseSolveResult *)solveFromTargetCurve:(NSArray<NSNumber *> *)target
                                            initialGuess:(PIDValues *)initialGuess
                                           mechConstants:(BFMechConstants *)mech
                                                  fitMask:(PIDReverseFitMask)fitMask
                                                   length:(NSInteger)length
                                                 duration:(double)duration {
    // 旧接口转调带滤波版 (nil=不滤波, 向后兼容 3.1/3.2 现有测试)
    return [self solveFromTargetCurve:target initialGuess:initialGuess
                         mechConstants:mech filterConfig:nil
                               fitMask:fitMask length:length duration:duration];
}

- (nullable PIDReverseSolveResult *)solveFromTargetCurve:(NSArray<NSNumber *> *)target
                                            initialGuess:(PIDValues *)initialGuess
                                           mechConstants:(BFMechConstants *)mech
                                            filterConfig:(BFFilterConfig *)filter
                                                  fitMask:(PIDReverseFitMask)fitMask
                                                   length:(NSInteger)length
                                                 duration:(double)duration {
    // 🔑 输入校验
    if (!target || !initialGuess || !mech) return nil;
    if (length < 2 || duration <= 0 || target.count < 2) return nil;
    if (mech.tauM <= 0 || mech.kPlant < 0) return nil;
    if (fitMask == 0) return nil;  // 无参数可拟合

    const NSInteger N = length;

    // 收集参与拟合的参数索引 (P=0,I=1,D=2,FF=3)
    int fitIdx[4] = {0};
    int nFit = 0;
    int bits[4] = { PIDReverseFitP, PIDReverseFitI, PIDReverseFitD, PIDReverseFitFF };
    for (int j = 0; j < 4; j++) {
        if (fitMask & bits[j]) fitIdx[nFit++] = j;
    }

    // target → C double 数组
    double *tgt = (double *)malloc(N * sizeof(double));
    if (!tgt) return nil;
    for (NSInteger k = 0; k < N; k++) tgt[k] = (k < (NSInteger)target.count) ? target[k].doubleValue : 0.0;

    // 当前解向量 cur[4] ← initialGuess
    double cur[4] = { initialGuess.p, initialGuess.i, initialGuess.d, initialGuess.ff };

    // 工作缓冲
    double *fwd0    = (double *)malloc(N * sizeof(double));
    double *fwdPert = (double *)malloc(N * sizeof(double));
    double *r0      = (double *)malloc(N * sizeof(double));
    double *diff    = (double *)malloc((size_t)N * nFit * sizeof(double));  // J[i*nFit+jj]
    if (!fwd0 || !fwdPert || !r0 || !diff) {
        free(tgt); free(fwd0); free(fwdPert); free(r0); free(diff);
        return nil;
    }

    PIDValues *workPID = [PIDValues new];

    // 初始残差 + cost
    [PIDReverseSolver applyCur:cur toPID:workPID];
    [self.class fillForwardDouble:fwd0 fromPID:workPID mechConstants:mech filterConfig:filter length:N duration:duration];
    double cost = 0.0;
    for (NSInteger k = 0; k < N; k++) { r0[k] = fwd0[k] - tgt[k]; cost += r0[k] * r0[k]; }

    double lambda = kLambdaInit;
    NSInteger iter = 0;
    BOOL converged = (sqrt(cost / N) < kRMSETol);

    while (!converged && iter < kMaxIter) {
        iter++;

        // ---- 数值雅可比: 对每个 fit 参数扰动, 填 diff 列 ----
        for (int jj = 0; jj < nFit; jj++) {
            int j = fitIdx[jj];
            double h = kJacStep * fmax(fabs(cur[j]), 1.0);
            double save = cur[j];
            cur[j] = save + h;
            [PIDReverseSolver applyCur:cur toPID:workPID];
            [self.class fillForwardDouble:fwdPert fromPID:workPID mechConstants:mech filterConfig:filter length:N duration:duration];
            cur[j] = save;
            // J[:][jj] = (fwdPert - fwd0) / h
            for (NSInteger k = 0; k < N; k++) {
                diff[k * nFit + jj] = (fwdPert[k] - fwd0[k]) / h;
            }
        }

        // ---- 构造 JᵀJ (AtA) 与 Jᵀr (grad) ----
        double AtA[16] = {0};   // max 4×4
        double grad[4] = {0};
        for (int a = 0; a < nFit; a++) {
            for (int b = a; b < nFit; b++) {
                double s = 0.0;
                for (NSInteger k = 0; k < N; k++) s += diff[k * nFit + a] * diff[k * nFit + b];
                AtA[a * nFit + b] = s;
                AtA[b * nFit + a] = s;  // 对称
            }
            double g = 0.0;
            for (NSInteger k = 0; k < N; k++) g += diff[k * nFit + a] * r0[k];
            grad[a] = g;
        }

        // ---- LM 试步: (AtA + λ·diag) · step = -grad ----
        double trialLambda = lambda;
        BOOL accepted = NO;
        for (int retry = 0; retry < 12; retry++) {
            double AtAtrial[16];
            memcpy(AtAtrial, AtA, sizeof(double) * nFit * nFit);
            for (int a = 0; a < nFit; a++) AtAtrial[a * nFit + a] *= (1.0 + trialLambda);

            double step[4] = {0};
            memcpy(step, grad, sizeof(double) * nFit);
            for (int a = 0; a < nFit; a++) step[a] = -step[a];  // 解 -grad

            SolveLinearSystem(AtAtrial, step, nFit);  // step ← 解

            // 试新解
            double trialCur[4];
            memcpy(trialCur, cur, sizeof(double) * 4);
            for (int jj = 0; jj < nFit; jj++) trialCur[fitIdx[jj]] += step[jj];

            // 负值保护 (PID 物理非负)
            for (int j = 0; j < 4; j++) if (trialCur[j] < 0) trialCur[j] = kPIDEpsilon;

            [PIDReverseSolver applyCur:trialCur toPID:workPID];
            [self.class fillForwardDouble:fwdPert fromPID:workPID mechConstants:mech filterConfig:filter length:N duration:duration];
            double newCost = 0.0;
            for (NSInteger k = 0; k < N; k++) {
                double dr = fwdPert[k] - tgt[k];
                newCost += dr * dr;
            }

            if (newCost < cost) {
                // 接受步
                memcpy(cur, trialCur, sizeof(double) * 4);
                cost = newCost;
                lambda = fmax(trialLambda * kLambdaDown, 1e-12);
                // 更新 r0/fwd0 为新解
                memcpy(fwd0, fwdPert, sizeof(double) * N);
                for (NSInteger k = 0; k < N; k++) r0[k] = fwd0[k] - tgt[k];
                accepted = YES;
                break;
            }
            trialLambda *= kLambdaUp;  // 拒绝, 增阻尼重试
        }

        if (!accepted) break;  // 阻尼加到极限仍无法下降, 停

        if (sqrt(cost / N) < kRMSETol) converged = YES;
    }

    // 组装结果
    PIDValues *solved = [PIDValues new];
    [PIDReverseSolver applyCur:cur toPID:solved];

    PIDReverseSolveResult *result = [PIDReverseSolveResult new];
    result.solvedPID  = solved;
    result.finalRMSE  = sqrt(cost / N);
    result.iterations = iter;
    result.converged  = converged;

    free(tgt); free(fwd0); free(fwdPert); free(r0); free(diff);
    return result;
}

@end
