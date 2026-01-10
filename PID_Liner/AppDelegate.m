//
//  AppDelegate.m
//  PID_Liner
//
//  Created by 梁隽 on 2025/11/13.
//

#import "AppDelegate.h"
#import <SVProgressHUD/SVProgressHUD.h>

@interface AppDelegate ()

@end

@implementation AppDelegate


- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // 🔥 配置 SVProgressHUD
    [SVProgressHUD setDefaultStyle:SVProgressHUDStyleDark];  // 深色风格，适配各种背景
    [SVProgressHUD setDefaultMaskType:SVProgressHUDMaskTypeClear];  // 清除遮罩类型
    [SVProgressHUD setMinimumDismissTimeInterval:0.5];  // 最小显示时间

    return YES;
}


#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // Called when a new scene session is being created.
    // Use this method to select a configuration to create the new scene with.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
    // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
    // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}


@end
