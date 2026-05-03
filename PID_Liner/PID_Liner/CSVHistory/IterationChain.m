//
//  IterationChain.m
//  PID_Liner
//
//  迭代闭环调参 — 迭代链数据模型实现
//

#import "IterationChain.h"

@implementation IterationChain

- (instancetype)init {
    self = [super init];
    if (self) {
        _chainId = [[NSUUID UUID] UUIDString];
        _records = [NSMutableArray array];
        _createdAt = [NSDate date];
        _initialSessionIndex = 0;
        _isConverged = NO;
    }
    return self;
}

- (NSInteger)currentIteration {
    return (NSInteger)self.records.count + 1;
}

- (nullable PIDTuningRecord *)latestRecord {
    return self.records.lastObject;
}

- (void)appendRecord:(PIDTuningRecord *)record {
    if (!record) return;
    [self.records addObject:record];
    if (record.isConverged) {
        self.isConverged = YES;
    }
}

#pragma mark - 序列化

- (NSDictionary *)toDictionary {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"chainId"] = self.chainId;
    d[@"craftName"] = self.craftName ?: @"";
    d[@"createdAt"] = @([self.createdAt timeIntervalSince1970]);
    d[@"initialCSVPath"] = self.initialCSVPath ?: @"";
    d[@"initialSessionIndex"] = @(self.initialSessionIndex);
    d[@"isConverged"] = @(self.isConverged);

    NSMutableArray *recordsArray = [NSMutableArray arrayWithCapacity:self.records.count];
    for (PIDTuningRecord *r in self.records) {
        [recordsArray addObject:[r toDictionary]];
    }
    d[@"records"] = recordsArray;

    return [d copy];
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    if (!dict) return nil;
    IterationChain *chain = [[IterationChain alloc] init];
    chain.chainId = dict[@"chainId"] ?: [[NSUUID UUID] UUIDString];
    chain.craftName = dict[@"craftName"] ?: @"";
    chain.createdAt = [NSDate dateWithTimeIntervalSince1970:[dict[@"createdAt"] doubleValue]];
    chain.initialCSVPath = dict[@"initialCSVPath"] ?: @"";
    chain.initialSessionIndex = [dict[@"initialSessionIndex"] integerValue];
    chain.isConverged = [dict[@"isConverged"] boolValue];

    NSArray *recordsArray = dict[@"records"];
    if (recordsArray) {
        chain.records = [NSMutableArray arrayWithCapacity:recordsArray.count];
        for (NSDictionary *rDict in recordsArray) {
            PIDTuningRecord *record = [PIDTuningRecord fromDictionary:rDict];
            if (record) {
                [chain.records addObject:record];
            }
        }
    }

    return chain;
}

@end
