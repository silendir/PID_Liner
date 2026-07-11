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

#pragma mark - PIDReverseSolver

@implementation PIDReverseSolver

#pragma mark - 绝对 forward

+ (NSArray<NSNumber *> *)forwardCurveWithPID:(PIDValues *)pid
                               mechConstants:(BFMechConstants *)mech
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

    return [BFPIDToSecondOrderMapper predictedCurveWithParams:params length:length duration:duration];
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
                    length:(NSInteger)N
                  duration:(double)duration {
    NSArray<NSNumber *> *curve = [self forwardCurveWithPID:pid mechConstants:mech length:N duration:duration];
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
    [self.class fillForwardDouble:fwd0 fromPID:workPID mechConstants:mech length:N duration:duration];
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
            [self.class fillForwardDouble:fwdPert fromPID:workPID mechConstants:mech length:N duration:duration];
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
            [self.class fillForwardDouble:fwdPert fromPID:workPID mechConstants:mech length:N duration:duration];
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
