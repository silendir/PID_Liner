//
//  PIDCurveDiagnostic.m
//  PID_Liner
//
//  第3层：曲线特征 → 诊断 → 评分
//

#import "PIDCurveDiagnostic.h"

#pragma mark - PIDIssue

@implementation PIDIssue
@end

#pragma mark - PIDAxisDiagnosis

@implementation PIDAxisDiagnosis
@end

#pragma mark - PIDCurveDiagnostic

@implementation PIDCurveDiagnostic

+ (instancetype)diagnoseWithFeatures:(NSArray<PIDResponseFeatures *> *)features {
    PIDCurveDiagnostic *diagnostic = [[PIDCurveDiagnostic alloc] init];
    NSArray<NSString *> *axisNames = @[@"Roll", @"Pitch", @"Yaw"];
    NSMutableArray<PIDAxisDiagnosis *> *diagnoses = [NSMutableArray arrayWithCapacity:3];

    double totalScore = 0.0;
    NSInteger validAxes = 0;

    for (NSInteger i = 0; i < MIN(features.count, (NSUInteger)3); i++) {
        PIDResponseFeatures *feat = features[i];
        if (!feat) continue;

        PIDAxisDiagnosis *axisDiag = [self diagnoseAxis:feat
                                               axisIndex:i
                                                axisName:axisNames[i]];
        [diagnoses addObject:axisDiag];
        totalScore += axisDiag.score;
        validAxes++;
    }

    diagnostic.axisDiagnoses = [diagnoses copy];
    diagnostic.overallScore = validAxes > 0 ? totalScore / validAxes : 0.0;
    diagnostic.summary = [self generateSummary:diagnostic];

    NSLog(@"📊 [诊断评分] 综合=%.0f分 | %@",
          diagnostic.overallScore, diagnostic.summary);

    return diagnostic;
}

#pragma mark - 单轴诊断

+ (PIDAxisDiagnosis *)diagnoseAxis:(PIDResponseFeatures *)features
                          axisIndex:(NSInteger)axisIndex
                           axisName:(NSString *)axisName {
    PIDAxisDiagnosis *diagnosis = [[PIDAxisDiagnosis alloc] init];
    diagnosis.axisIndex = axisIndex;
    diagnosis.axisName = axisName;
    diagnosis.features = features;

    NSMutableArray<PIDIssue *> *issues = [NSMutableArray array];

    // ===== 评分算法 =====
    // 基础分100，每个问题扣分
    double score = 100.0;

    // 1. 超调量检查
    //    超调 > 20%: 严重 (P过高)
    //    超调 10%~20%: 中等 (P略高)
    //    超调 < 5%: 优秀
    if (features.overshoot > 0.20) {
        double severity = MIN(1.0, (features.overshoot - 0.20) / 0.30 + 0.5);
        double penalty = MIN(40.0, features.overshoot * 200.0);
        score -= penalty;
        PIDIssue *issue = [[PIDIssue alloc] init];
        issue.issueType = @"overshoot";
        issue.severity = severity;
        issue.localizedDesc = [NSString stringWithFormat:@"%@超调%.0f%%过大，P增益偏高",
                               axisName, features.overshoot * 100.0];
        issue.suggestedAction = @"P × 0.7";
        [issues addObject:issue];
    } else if (features.overshoot > 0.10) {
        score -= features.overshoot * 100.0;
        PIDIssue *issue = [[PIDIssue alloc] init];
        issue.issueType = @"overshoot";
        issue.severity = 0.3;
        issue.localizedDesc = [NSString stringWithFormat:@"%@超调%.0f%%略高",
                               axisName, features.overshoot * 100.0];
        issue.suggestedAction = @"P × 0.85";
        [issues addObject:issue];
    }

    // 2. 上升时间检查
    //    > 80ms: 响应迟缓
    //    40~80ms: 正常
    //    < 40ms: 优秀
    if (features.riseTime > 80.0) {
        double penalty = (features.riseTime - 40.0) * 0.5;
        score -= penalty;
        PIDIssue *issue = [[PIDIssue alloc] init];
        issue.issueType = @"slow_response";
        issue.severity = MIN(1.0, (features.riseTime - 80.0) / 80.0 + 0.3);
        issue.localizedDesc = [NSString stringWithFormat:@"%@上升时间%.0fms过长，响应迟缓",
                               axisName, features.riseTime];
        issue.suggestedAction = @"P × 1.2 或 FF × 1.3";
        [issues addObject:issue];
    } else if (features.riseTime > 40.0) {
        score -= (features.riseTime - 40.0) * 0.2;
    }

    // 3. 建立时间检查
    //    > 150ms: 不稳定
    //    80~150ms: 正常
    //    < 80ms: 优秀
    if (features.settlingTime > 150.0) {
        double penalty = (features.settlingTime - 80.0) * 0.3;
        score -= penalty;
        PIDIssue *issue = [[PIDIssue alloc] init];
        issue.issueType = @"oscillation";
        issue.severity = MIN(1.0, (features.settlingTime - 150.0) / 100.0 + 0.3);
        issue.localizedDesc = [NSString stringWithFormat:@"%@建立时间%.0fms过长，存在振荡",
                               axisName, features.settlingTime];
        issue.suggestedAction = @"D × 1.15";
        [issues addObject:issue];
    }

    // 4. 震荡次数检查
    if (features.oscillationCount > 3) {
        double penalty = (features.oscillationCount - 2) * 5.0;
        score -= penalty;
        PIDIssue *issue = [[PIDIssue alloc] init];
        issue.issueType = @"oscillation";
        issue.severity = MIN(1.0, (features.oscillationCount - 3) * 0.2 + 0.3);
        issue.localizedDesc = [NSString stringWithFormat:@"%@震荡%ld次，D增益不足",
                               axisName, (long)features.oscillationCount];
        issue.suggestedAction = @"D × 1.2";
        [issues addObject:issue];
    }

    // 5. 稳态值检查
    //    稳态值过低 → I 不足
    if (fabs(features.steadyState) < 0.3 && fabs(features.peakValue) > 0.5) {
        score -= 10.0;
        PIDIssue *issue = [[PIDIssue alloc] init];
        issue.issueType = @"low_i";
        issue.severity = 0.4;
        issue.localizedDesc = [NSString stringWithFormat:@"%@稳态值%.2f偏低，I增益可能不足",
                               axisName, features.steadyState];
        issue.suggestedAction = @"I × 1.15";
        [issues addObject:issue];
    }

    // 确保分数在 [0, 100] 范围内
    score = MAX(0.0, MIN(100.0, score));

    diagnosis.score = score;
    diagnosis.issues = [issues copy];

    NSLog(@"📊 [诊断] %@: %.0f分 (%ld个问题)",
          axisName, score, (long)issues.count);
    for (PIDIssue *issue in issues) {
        NSLog(@"  ⚠️ %@ (严重度%.0f%%): %@", issue.issueType, issue.severity * 100, issue.localizedDesc);
    }

    return diagnosis;
}

#pragma mark - 摘要生成

+ (NSString *)generateSummary:(PIDCurveDiagnostic *)diagnostic {
    double score = diagnostic.overallScore;

    // 统计问题数量
    NSInteger totalIssues = 0;
    NSInteger highSeverityIssues = 0;
    for (PIDAxisDiagnosis *axis in diagnostic.axisDiagnoses) {
        totalIssues += axis.issues.count;
        for (PIDIssue *issue in axis.issues) {
            if (issue.severity > 0.5) {
                highSeverityIssues++;
            }
        }
    }

    if (score >= 80) {
        return [NSString stringWithFormat:@"PID调参良好(%.0f分)，%ld个轻微问题",
                score, (long)totalIssues];
    } else if (score >= 60) {
        return [NSString stringWithFormat:@"PID需要微调(%.0f分)，%ld个问题需关注",
                score, (long)totalIssues];
    } else if (score >= 40) {
        return [NSString stringWithFormat:@"PID需要调整(%.0f分)，%ld个问题其中%ld个较严重",
                score, (long)totalIssues, (long)highSeverityIssues];
    } else {
        return [NSString stringWithFormat:@"PID需要大幅调整(%.0f分)，%ld个严重问题",
                score, (long)highSeverityIssues];
    }
}

@end
