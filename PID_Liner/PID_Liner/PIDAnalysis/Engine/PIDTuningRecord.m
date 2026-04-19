//
//  PIDTuningRecord.m
//  PID_Liner
//
//  迭代闭环调参 — 单轮调参记录数据模型
//

#import "PIDTuningRecord.h"

#pragma mark - PIDAxisTuningSnapshot

@implementation PIDAxisTuningSnapshot

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (self.recommendedPID) d[@"recommendedPID"] = [self.recommendedPID toDictionary];
    if (self.originalPID) d[@"originalPID"] = [self.originalPID toDictionary];
    if (self.actualFeatures) d[@"actualFeatures"] = [self featuresToDict:self.actualFeatures];
    if (self.predictedFeatures) d[@"predictedFeatures"] = [self featuresToDict:self.predictedFeatures];
    if (self.predictedCurve) d[@"predictedCurve"] = self.predictedCurve;
    return [d copy];
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    if (!dict) return nil;
    PIDAxisTuningSnapshot *s = [[PIDAxisTuningSnapshot alloc] init];
    if (dict[@"recommendedPID"]) {
        s.recommendedPID = [PIDValues fromDictionary:dict[@"recommendedPID"]];
    }
    if (dict[@"originalPID"]) {
        s.originalPID = [PIDValues fromDictionary:dict[@"originalPID"]];
    }
    if (dict[@"actualFeatures"]) {
        s.actualFeatures = [self featuresFromDict:dict[@"actualFeatures"]];
    }
    if (dict[@"predictedFeatures"]) {
        s.predictedFeatures = [self featuresFromDict:dict[@"predictedFeatures"]];
    }
    if (dict[@"predictedCurve"]) {
        s.predictedCurve = dict[@"predictedCurve"];
    }
    return s;
}

#pragma mark - 私有方法

- (NSDictionary *)featuresToDict:(PIDResponseFeatures *)features {
    return @{
        @"overshoot": @(features.overshoot),
        @"riseTime": @(features.riseTime),
        @"settlingTime": @(features.settlingTime),
        @"steadyState": @(features.steadyState),
        @"peakValue": @(features.peakValue),
        @"peakTime": @(features.peakTime),
        @"oscillationCount": @(features.oscillationCount)
    };
}

+ (PIDResponseFeatures *)featuresFromDict:(NSDictionary *)dict {
    PIDResponseFeatures *f = [[PIDResponseFeatures alloc] init];
    f.overshoot = [dict[@"overshoot"] doubleValue];
    f.riseTime = [dict[@"riseTime"] doubleValue];
    f.settlingTime = [dict[@"settlingTime"] doubleValue];
    f.steadyState = [dict[@"steadyState"] doubleValue];
    f.peakValue = [dict[@"peakValue"] doubleValue];
    f.peakTime = [dict[@"peakTime"] doubleValue];
    f.oscillationCount = [dict[@"oscillationCount"] integerValue];
    return f;
}

@end

#pragma mark - PIDTuningRecord

@implementation PIDTuningRecord

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"craftName"] = self.craftName ?: @"";
    d[@"iteration"] = @(self.iteration);
    d[@"createdAt"] = @([self.createdAt timeIntervalSince1970]);
    d[@"csvFileName"] = self.csvFileName ?: @"";
    if (self.rollSnapshot) d[@"rollSnapshot"] = [self.rollSnapshot toDictionary];
    if (self.pitchSnapshot) d[@"pitchSnapshot"] = [self.pitchSnapshot toDictionary];
    if (self.yawSnapshot) d[@"yawSnapshot"] = [self.yawSnapshot toDictionary];
    if (self.cliCommands) d[@"cliCommands"] = self.cliCommands;
    d[@"gainCorrection"] = @(self.gainCorrection);
    d[@"dampingCorrection"] = @(self.dampingCorrection);
    d[@"freqCorrection"] = @(self.freqCorrection);
    d[@"accuracy"] = @(self.accuracy);
    d[@"isConverged"] = @(self.isConverged);
    return [d copy];
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    if (!dict) return nil;
    PIDTuningRecord *r = [[PIDTuningRecord alloc] init];
    r.craftName = dict[@"craftName"] ?: @"";
    r.iteration = [dict[@"iteration"] integerValue];
    NSTimeInterval interval = [dict[@"createdAt"] doubleValue];
    r.createdAt = [NSDate dateWithTimeIntervalSince1970:interval];
    r.csvFileName = dict[@"csvFileName"] ?: @"";
    if (dict[@"rollSnapshot"]) {
        r.rollSnapshot = [PIDAxisTuningSnapshot fromDictionary:dict[@"rollSnapshot"]];
    }
    if (dict[@"pitchSnapshot"]) {
        r.pitchSnapshot = [PIDAxisTuningSnapshot fromDictionary:dict[@"pitchSnapshot"]];
    }
    if (dict[@"yawSnapshot"]) {
        r.yawSnapshot = [PIDAxisTuningSnapshot fromDictionary:dict[@"yawSnapshot"]];
    }
    r.cliCommands = dict[@"cliCommands"];
    r.gainCorrection = [dict[@"gainCorrection"] doubleValue];
    r.dampingCorrection = [dict[@"dampingCorrection"] doubleValue];
    r.freqCorrection = [dict[@"freqCorrection"] doubleValue];
    r.accuracy = [dict[@"accuracy"] doubleValue];
    r.isConverged = [dict[@"isConverged"] boolValue];
    return r;
}

- (nullable PIDAxisTuningSnapshot *)snapshotForAxis:(NSInteger)axisIndex {
    switch (axisIndex) {
        case 0: return self.rollSnapshot;
        case 1: return self.pitchSnapshot;
        case 2: return self.yawSnapshot;
        default: return nil;
    }
}

@end
